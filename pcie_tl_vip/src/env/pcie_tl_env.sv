//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Top-level Environment
//-----------------------------------------------------------------------------

class pcie_tl_env extends uvm_env;
    `uvm_component_utils(pcie_tl_env)

    //--- Configuration ---
    pcie_tl_env_config     cfg;

    //--- Agents ---
    pcie_tl_rc_agent       rc_agent;     // alias -> rc_agents[0]
    pcie_tl_ep_agent       ep_agent;

    //--- Per-root agents/managers/scoreboards (multi-USP). [0] aliases above. ---
    pcie_tl_rc_agent          rc_agents[];
    pcie_tl_if_adapter        rc_adapters[];
    pcie_tl_tag_manager       tag_mgrs[];
    pcie_tl_fc_manager        fc_mgrs[];
    pcie_tl_ordering_engine   ord_engs[];
    pcie_tl_cfg_space_manager cfg_mgrs[];
    pcie_tl_scoreboard        scbs[];

    //--- Shared components (codec/bw_shaper stay single/shared) ---
    pcie_tl_codec              codec;
    pcie_tl_fc_manager         fc_mgr;    // alias -> fc_mgrs[0]
    pcie_tl_tag_manager        tag_mgr;   // alias -> tag_mgrs[0]
    pcie_tl_ordering_engine    ord_eng;   // alias -> ord_engs[0]
    pcie_tl_cfg_space_manager  cfg_mgr;   // alias -> cfg_mgrs[0]
    pcie_tl_bw_shaper          bw_shaper;

    //--- Verification components ---
    pcie_tl_scoreboard         scb;       // alias -> scbs[0]
    pcie_tl_coverage_collector cov;

    //--- Adapters ---
    pcie_tl_if_adapter         rc_adapter;  // alias -> rc_adapters[0]
    pcie_tl_if_adapter         ep_adapter;  // alias -> ep_adapters[0] (non-switch multi-EP)

    //--- Link Delay Models ---
    pcie_tl_link_delay_model   rc2ep_delay;
    pcie_tl_link_delay_model   ep2rc_delay;

    //--- Multi-EP: switch mode (num_ds_ports) OR non-switch (num_ep) ---
    pcie_tl_switch         sw;
    pcie_tl_ep_agent       ep_agents[];
    pcie_tl_if_adapter     ep_adapters[];

    //--- Function Manager (SR-IOV) ---
    pcie_tl_func_manager   func_mgr_sriov;

    //--- Virtual Sequencer ---
    pcie_tl_virtual_sequencer  v_seqr;

    //--- Unified Memory handles (host_mem_api base; populated from config_db when use_unified_mem=1) ---
    host_mem_api    host_mem;
    host_mem_api    dev_mem[16];

    // BDF-indexed device contexts are only built when global device policy is
    // supplied.  Existing tests that do not use global-cfg keep this map empty.
    pcie_tl_func_context device_contexts[bit [15:0]];
    pcie_tl_device_cfg_adapter device_cfg_adapter;

    //--- Legacy RC auto-response observation ---
    // Legacy CplD objects are written directly to the scoreboard rather than
    // injected back through an adapter.  This port exposes that stream to
    // verification consumers without changing the legacy transport path.
    uvm_analysis_port #(pcie_tl_tlp) legacy_rc_cpl_ap;

    // FULL_VIP/Serial bridge 下，EP monitor 收到的请求不能再通过本环境
    // 的 TLM loopback FIFO 转发。这里为每个 EP monitor 建立 analysis FIFO，
    // run_phase 会把 FIFO 中的请求交给对应的 pcie_tl_ep_driver。
    // 该数组只在 bridge_required=1 且 EP agent 存在时创建，TL-only 旧路径
    // 不会额外创建组件，也不会改变原有时序。
    uvm_tlm_analysis_fifo #(pcie_tl_tlp) bridge_ep_rx_fifos[];

    // FULL_VIP/Serial bridge 下，EP 发往 RC 的请求也必须有一个独立入口。
    // RC monitor 仍然把 Completion 交给 rc_driver.completion_analysis_imp；
    // 这个 FIFO 只消费 EP-originated Memory/Config/IO request，并调用 RC
    // driver 的 responder 生成反向 Completion。TL-only 模式不创建该数组。
    uvm_tlm_analysis_fifo #(pcie_tl_tlp) bridge_rc_rx_fifos[];

    // 该状态跨越 build/connect/apply_config 三个阶段，不能声明为局部变量。
    bit bridge_required;

    // Return the Nth Endpoint policy context in declaration order.  The graph
    // remains authoritative; this helper only provides a stable mapping from
    // dynamically created EP agents to their independent config image.
    function pcie_tl_func_context configured_ep_context(int ep_index);
        int ordinal;

        ordinal = 0;
        configured_ep_context = null;
        foreach (cfg.device_cfgs[i]) begin
            if ((cfg.device_cfgs[i] != null) &&
                (cfg.device_cfgs[i].role == PCIE_DEVICE_EP)) begin
                if (ordinal == ep_index) begin
                    if (device_contexts.exists(cfg.device_cfgs[i].bdf))
                        configured_ep_context =
                            device_contexts[cfg.device_cfgs[i].bdf];
                    return configured_ep_context;
                end
                ordinal++;
            end
        end
    endfunction

    function new(string name = "pcie_tl_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    //=========================================================================
    // Build Phase
    //=========================================================================
    function void build_phase(uvm_phase phase);
        int  nu;            // root (USP) count
        int  n_mgr;         // manager-set count (>=1 so EP-only still has managers)
        int  tag_bit;       // physical VIP/DUT tag width selected by +TAG_BIT
        bit  ns_multi_ep;   // non-switch multi-EP (num_ep>1) -> ep_agents[] array
        super.build_phase(phase);

        bridge_required = 1'b0;
        void'(uvm_config_db#(bit)::get(
            this, "", "pcie_svt_bridge_required", bridge_required));

        legacy_rc_cpl_ap = new("legacy_rc_cpl_ap", this);

        // 1. Get or create config
        if (!uvm_config_db#(pcie_tl_env_config)::get(this, "", "cfg", cfg)) begin
            cfg = pcie_tl_env_config::type_id::create("cfg");
            `uvm_info("ENV", "No config found in config_db, using defaults", UVM_MEDIUM)
        end

        if (cfg.device_cfgs.size() != 0) begin
            device_cfg_adapter = pcie_tl_device_cfg_adapter::type_id::create(
                "device_cfg_adapter");
            foreach (cfg.device_cfgs[i]) begin
                pcie_tl_func_context context;
                string device_errors[$];
                if (cfg.device_cfgs[i] == null)
                    `uvm_fatal("DEVICE_CFG", $sformatf(
                        "device policy %0d is null", i))
                context = pcie_tl_func_context::type_id::create(
                    $sformatf("device_context_%0d", i));
                if (!device_cfg_adapter.apply_device_cfg(
                      cfg.device_cfgs[i], context, device_errors))
                    `uvm_fatal("DEVICE_CFG", $sformatf(
                        "device '%s' translation failed: %s",
                        cfg.device_cfgs[i].device_id,
                        (device_errors.size() == 0) ?
                          "unspecified adapter error" : device_errors[0]))
                if (device_contexts.exists(context.bdf))
                    `uvm_fatal("DEVICE_CFG", $sformatf(
                        "duplicate device BDF 0x%04h", context.bdf))
                device_contexts[context.bdf] = context;
            end
        end

        // An explicit TAG_BIT overrides test defaults for the physical VIP
        // requester. No plusarg keeps standalone test behavior unchanged.
        if ($value$plusargs("TAG_BIT=%d", tag_bit)) begin
            if (tag_bit != 8 && tag_bit != 10)
                `uvm_fatal("ENV", $sformatf(
                    "TAG_BIT must be 8 or 10, got %0d", tag_bit))
            cfg.extended_tag_enable = (tag_bit == 10);
            cfg.max_outstanding     = (tag_bit == 10) ? 1024 : 256;
        end

        // 2pre. Switch enabled: init switch_cfg defaults FIRST so num_usp/dsp_owner
        //       are valid before per-root managers/agents are created below.
        if (cfg.switch_enable && cfg.switch_cfg != null)
            cfg.switch_cfg.init_defaults();

        // Root count (USP): switch -> num_usp; else num_rc (0 when RC disabled).
        nu = (cfg.switch_enable && cfg.switch_cfg != null) ? cfg.switch_cfg.num_usp
                                                           : (cfg.rc_agent_enable ? cfg.num_rc : 0);
        // Manager sets: >=1 so a no-RC (EP-only) env still has shared managers.
        n_mgr = (nu > 0) ? nu : 1;
        // Non-switch multi-EP: build ep_agents[]/ep_adapters[] (num_ep independent links).
        ns_multi_ep = (!cfg.switch_enable) && cfg.ep_agent_enable && (cfg.num_ep > 1);

        // 2. Create shared components (codec/bw_shaper single; managers per-root below)
        codec     = pcie_tl_codec::type_id::create("codec");
        bw_shaper = pcie_tl_bw_shaper::type_id::create("bw_shaper", this);

        // 2b. Per-root managers (n_mgr) + RC adapters (nu). Aliases -> [0] after.
        tag_mgrs    = new[n_mgr];
        fc_mgrs     = new[n_mgr];
        ord_engs    = new[n_mgr];
        cfg_mgrs    = new[n_mgr];
        for (int r = 0; r < n_mgr; r++) begin
            tag_mgrs[r] = pcie_tl_tag_manager::type_id::create($sformatf("tag_mgr_%0d", r));
            fc_mgrs[r]  = pcie_tl_fc_manager::type_id::create($sformatf("fc_mgr_%0d", r));
            ord_engs[r] = pcie_tl_ordering_engine::type_id::create($sformatf("ord_eng_%0d", r));
            cfg_mgrs[r] = pcie_tl_cfg_space_manager::type_id::create($sformatf("cfg_mgr_%0d", r));
        end
        rc_adapters = new[nu];
        for (int r = 0; r < nu; r++) begin
            // 可选 SVT bridge 在 TL env 建树前注入，确保 Agent 持有同一适配器。
            if (!uvm_config_db#(pcie_tl_if_adapter)::get(
                  this, "", $sformatf("pcie_svt_bridge_rc_adapter_%0d", r),
                  rc_adapters[r])) begin
                // 适配器允许由工厂覆盖生成（例如 SVT adapter）。因此即使
                // bridge_required=1，也不能要求调用方预先传入一个实例；
                // 统一走 factory create，SVT adapter 再于 connect 阶段绑定
                // 正式 Mapper。
                rc_adapters[r] = pcie_tl_if_adapter::type_id::create(
                    $sformatf("rc_adapter_%0d", r), this);
            end
        end
        // Aliases -> [0] (managers always exist; rc_adapter only when a root exists)
        tag_mgr    = tag_mgrs[0];
        fc_mgr     = fc_mgrs[0];
        ord_eng    = ord_engs[0];
        cfg_mgr    = cfg_mgrs[0];
        if (nu > 0) rc_adapter = rc_adapters[0];

        // 3. Single EP adapter for the direct-mode / switch-dangling path.
        //    Non-switch multi-EP builds its own ep_adapters[] in block 4a instead;
        //    a no-EP (RC-only) env creates none (all EP derefs are guarded).
        if (cfg.switch_enable || (cfg.ep_agent_enable && !ns_multi_ep))
            begin
                // 与 RC 侧一致，允许生产集成在 build 前注入外部适配器。
                // 这样真实 DUT 的 EP 方向也能使用 SVT/PIPE adapter，而
                // 未注入时仍保持原有 TL-only 工厂行为。
                if (!uvm_config_db#(pcie_tl_if_adapter)::get(
                      this, "", "pcie_svt_bridge_ep_adapter_0", ep_adapter)) begin
                    ep_adapter = pcie_tl_if_adapter::type_id::create(
                        "ep_adapter", this);
                end
            end

        // 3b. Create link delay models
        rc2ep_delay = pcie_tl_link_delay_model::type_id::create("rc2ep_delay", this);
        ep2rc_delay = pcie_tl_link_delay_model::type_id::create("ep2rc_delay", this);

        // 4. Create RC agents (one per root; rc_agent_%0d). Alias rc_agent -> [0].
        if (nu > 0) begin
            rc_agents = new[nu];
            for (int r = 0; r < nu; r++) begin
                uvm_config_db#(uvm_active_passive_enum)::set(
                    this, $sformatf("rc_agent_%0d", r), "is_active", cfg.rc_is_active);
                rc_agents[r] = pcie_tl_rc_agent::type_id::create(
                    $sformatf("rc_agent_%0d", r), this);
            end
            rc_agent = rc_agents[0];
        end

        // 4a. EP agents. Non-switch multi-EP -> independent ep_agent_%0d links
        //     (aliases -> [0]); otherwise the single direct-mode ep_agent (main path,
        //     also the switch-mode dangling agent). Switch ports are built in 4b.
        if (ns_multi_ep) begin
            ep_agents   = new[cfg.num_ep];
            ep_adapters = new[cfg.num_ep];
            for (int i = 0; i < cfg.num_ep; i++) begin
                uvm_config_db#(uvm_active_passive_enum)::set(
                    this, $sformatf("ep_agent_%0d", i), "is_active", cfg.ep_is_active);
                ep_agents[i]   = pcie_tl_ep_agent::type_id::create(
                    $sformatf("ep_agent_%0d", i), this);
                if (!uvm_config_db#(pcie_tl_if_adapter)::get(
                      this, "", $sformatf("pcie_svt_bridge_ep_adapter_%0d", i),
                      ep_adapters[i])) begin
                    ep_adapters[i] = pcie_tl_if_adapter::type_id::create(
                        $sformatf("ep_adapter_%0d", i), this);
                end
            end
            ep_agent   = ep_agents[0];
            ep_adapter = ep_adapters[0];
        end else if (cfg.ep_agent_enable) begin
            uvm_config_db#(uvm_active_passive_enum)::set(this, "ep_agent", "is_active", cfg.ep_is_active);
            ep_agent = pcie_tl_ep_agent::type_id::create("ep_agent", this);
        end

        // 4c. SR-IOV mode: create function manager
        if (cfg.sriov_enable) begin
            func_mgr_sriov = pcie_tl_func_manager::type_id::create("func_mgr_sriov");
            func_mgr_sriov.set_tag_bit(cfg.extended_tag_enable ? 10 : 8);
            func_mgr_sriov.build(cfg.num_pfs, cfg.max_vfs_per_pf,
                                  cfg.pf_vendor_id, cfg.pf_device_id, cfg.vf_device_id);
            if (cfg.default_num_vfs > 0) begin
                for (int pf = 0; pf < cfg.num_pfs; pf++)
                    func_mgr_sriov.enable_vfs(pf, cfg.default_num_vfs);
            end
        end

        // 4b. Switch mode: create switch + N EP agents (one per DS port)
        if (cfg.switch_enable && cfg.switch_cfg != null) begin
            int n = cfg.switch_cfg.num_ds_ports;
            // init_defaults() already called at top of build_phase (2pre).

            sw = pcie_tl_switch::type_id::create("sw", this);
            sw.sw_cfg = cfg.switch_cfg;

            ep_agents  = new[n];
            ep_adapters = new[n];
            for (int i = 0; i < n; i++) begin
                uvm_config_db#(uvm_active_passive_enum)::set(
                    this, $sformatf("ep_agent_%0d", i), "is_active", cfg.ep_is_active);
                ep_agents[i]  = pcie_tl_ep_agent::type_id::create(
                    $sformatf("ep_agent_%0d", i), this);
                if (!uvm_config_db#(pcie_tl_if_adapter)::get(
                      this, "", $sformatf("pcie_svt_bridge_ep_adapter_%0d", i),
                      ep_adapters[i])) begin
                    ep_adapters[i] = pcie_tl_if_adapter::type_id::create(
                        $sformatf("ep_adapter_%0d", i), this);
                end
            end
        end

        // 5. Create verification components (one scoreboard per manager set; alias scb -> scbs[0])
        if (cfg.scb_enable) begin
            scbs = new[n_mgr];
            for (int r = 0; r < n_mgr; r++)
                scbs[r] = pcie_tl_scoreboard::type_id::create($sformatf("scb_%0d", r), this);
            scb = scbs[0];
        end

        cov = pcie_tl_coverage_collector::type_id::create("cov", this);

        // FULL_VIP bridge 的 EP 请求入口。数组长度与实际 EP agent 一一
        // 对应：普通 direct/multi-EP 使用 num_ep，switch 使用 DS port 数。
        // FIFO 必须在 build_phase 创建，避免 connect_phase 动态创建 UVM 对象。
        if (bridge_required && cfg.ep_agent_enable) begin
            int bridge_ep_count;
            bridge_ep_count = (cfg.switch_enable && (cfg.switch_cfg != null)) ?
                              cfg.switch_cfg.num_ds_ports : cfg.num_ep;
            if (bridge_ep_count > 0) begin
                bridge_ep_rx_fifos = new[bridge_ep_count];
                foreach (bridge_ep_rx_fifos[i]) begin
                    bridge_ep_rx_fifos[i] = new(
                        $sformatf("bridge_ep_rx_fifo_%0d", i), this);
                end
            end
        end

        // RC ingress FIFO 与实际 USP 数量一致。多 Root/Switch 场景下每个
        // RC monitor 必须保持独立 FIFO，防止不同 Root 的请求互相消费。
        if (bridge_required && cfg.rc_agent_enable && (nu > 0)) begin
            bridge_rc_rx_fifos = new[nu];
            foreach (bridge_rc_rx_fifos[i]) begin
                bridge_rc_rx_fifos[i] = new(
                    $sformatf("bridge_rc_rx_fifo_%0d", i), this);
            end
        end

        // 6. Virtual sequencer
        v_seqr = pcie_tl_virtual_sequencer::type_id::create("v_seqr", this);

        // 7. Apply configuration
        apply_config();
    endfunction

    //=========================================================================
    // Connect Phase
    //=========================================================================
    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        // 1. Inject shared components into RC agents (one per root, indexed managers/adapters)
        foreach (rc_agents[r]) begin
            if (rc_agents[r] == null) continue;
            rc_agents[r].fc_mgr    = fc_mgrs[r];
            rc_agents[r].tag_mgr   = tag_mgrs[r];
            rc_agents[r].ord_eng   = ord_engs[r];
            rc_agents[r].cfg_mgr   = cfg_mgrs[r];
            rc_agents[r].bw_shaper = bw_shaper;
            rc_agents[r].codec     = codec;
            rc_agents[r].adapter   = rc_adapters[r];
            rc_agents[r].inject_shared_components();
        end

        // 1b. EP injection: non-switch multi-EP wires every independent link
        //     (shared managers); otherwise the single direct-mode / switch-dangling agent.
        if (!cfg.switch_enable && ep_agents.size() > 0) begin
            foreach (ep_agents[i]) begin
                int mi = (i < fc_mgrs.size()) ? i : 0;  // per-pair managers (RC[i]<->EP[i]); shared [0] if fewer roots
                if (ep_agents[i] == null) continue;
                ep_agents[i].fc_mgr    = fc_mgrs[mi];
                ep_agents[i].tag_mgr   = tag_mgrs[mi];
                ep_agents[i].ord_eng   = ord_engs[mi];
                begin
                    pcie_tl_func_context ep_context;
                    ep_context = configured_ep_context(i);
                    ep_agents[i].cfg_mgr = (ep_context == null) ?
                        cfg_mgrs[mi] : ep_context.cfg_mgr;
                end
                ep_agents[i].bw_shaper = bw_shaper;
                ep_agents[i].codec     = codec;
                ep_agents[i].adapter   = ep_adapters[i];
                // Bridge 模式下，EP Completion 由环境 FIFO 交给 EP driver；
                // 关闭 monitor 内置的全局 registry fold，避免 payload 重复。
                ep_agents[i].external_completion_driver_enable = bridge_required;
                ep_agents[i].inject_shared_components();
                if (ep_agents[i].ep_driver != null) begin
                    ep_agents[i].ep_driver.mps_bytes       = int'(cfg.max_payload_size);
                    ep_agents[i].ep_driver.rcb_bytes       = int'(cfg.read_completion_boundary);
                    ep_agents[i].ep_driver.use_unified_mem = cfg.use_unified_mem;
                    if (cfg.sriov_enable && func_mgr_sriov != null) begin
                        ep_agents[i].func_manager           = func_mgr_sriov;
                        ep_agents[i].ep_driver.func_manager = func_mgr_sriov;
                    end
                end
            end
        end else if (ep_agent != null) begin
            ep_agent.fc_mgr    = fc_mgr;
            ep_agent.tag_mgr   = tag_mgr;
            ep_agent.ord_eng   = ord_eng;
            begin
                pcie_tl_func_context ep_context;
                ep_context = configured_ep_context(0);
                ep_agent.cfg_mgr = (ep_context == null) ?
                    cfg_mgr : ep_context.cfg_mgr;
            end
            ep_agent.bw_shaper = bw_shaper;
            ep_agent.codec     = codec;
            ep_agent.adapter   = ep_adapter;
            ep_agent.external_completion_driver_enable = bridge_required;
            ep_agent.inject_shared_components();
            if (ep_agent.ep_driver != null) begin
                ep_agent.ep_driver.mps_bytes = int'(cfg.max_payload_size);
                ep_agent.ep_driver.rcb_bytes = int'(cfg.read_completion_boundary);
                ep_agent.ep_driver.use_unified_mem = cfg.use_unified_mem;
                // mem assignment deferred to unified-mem distribution block below
                if (cfg.sriov_enable && func_mgr_sriov != null) begin
                    ep_agent.func_manager = func_mgr_sriov;
                    ep_agent.ep_driver.func_manager = func_mgr_sriov;
                end
            end
        end

        // 2. Adapter codec injection (per-root RC adapters; EP adapter(s))
        foreach (rc_adapters[r]) begin
            rc_adapters[r].codec  = codec;
            rc_adapters[r].fc_mgr = fc_mgrs[r];
        end
        if (!cfg.switch_enable && ep_adapters.size() > 0) begin
            foreach (ep_adapters[i]) begin
                if (ep_adapters[i] == null) continue;
                ep_adapters[i].codec  = codec;
                ep_adapters[i].fc_mgr = fc_mgr;
            end
        end else if (ep_adapter != null) begin
            ep_adapter.codec  = codec;
            ep_adapter.fc_mgr = fc_mgr;
        end

        // 3. RC monitor -> per-root scoreboard + coverage; v_seqr per-root arrays
        foreach (rc_agents[r]) begin
            if (rc_agents[r] == null) continue;
            if (scbs.size() > r && scbs[r] != null)
                rc_agents[r].monitor.tlp_ap.connect(scbs[r].rc_imp);
            rc_agents[r].monitor.tlp_ap.connect(cov.analysis_export);
            // 外部 SVT bridge 的 Completion 不经过 env loopback；将 monitor
            // 观察到的 Completion 交回 RC driver，完成 pending/tag 清理。
            if (bridge_required && (rc_agents[r].rc_driver != null))
                rc_agents[r].monitor.tlp_ap.connect(
                    rc_agents[r].rc_driver.completion_analysis_imp);
            if (bridge_required)
                rc_agents[r].external_completion_driver_enable = 1'b1;
            if (bridge_required)
                rc_agents[r].monitor.external_completion_driver_enable = 1'b1;
            if (bridge_required && (bridge_rc_rx_fifos.size() > r) &&
                (bridge_rc_rx_fifos[r] != null))
                rc_agents[r].monitor.tlp_ap.connect(
                    bridge_rc_rx_fifos[r].analysis_export);
            v_seqr.rc_seqr_arr.push_back(rc_agents[r].sequencer);
        end
        if (rc_agents.size() > 0 && rc_agents[0] != null)
            v_seqr.rc_seqr = rc_agents[0].sequencer;

        // 4. EP monitor -> scb[0] + coverage. Non-switch multi-EP wires every link;
        //    otherwise the single direct-mode / switch-dangling agent.
        if (!cfg.switch_enable && ep_agents.size() > 0) begin
            foreach (ep_agents[i]) begin
                int si = (i < scbs.size()) ? i : 0;   // pair i -> scbs[i] (matches RC[i])
                if (ep_agents[i] == null) continue;
                if (scbs.size() > si && scbs[si] != null)
                    ep_agents[i].monitor.tlp_ap.connect(scbs[si].ep_imp);
                ep_agents[i].monitor.tlp_ap.connect(cov.analysis_export);
                if (bridge_required && (bridge_ep_rx_fifos.size() > i) &&
                    (bridge_ep_rx_fifos[i] != null))
                    ep_agents[i].monitor.tlp_ap.connect(
                        bridge_ep_rx_fifos[i].analysis_export);
                v_seqr.ep_seqr_arr.push_back(ep_agents[i].sequencer);
            end
            if (ep_agents[0] != null)
                v_seqr.ep_seqr = ep_agents[0].sequencer;
        end else if (ep_agent != null) begin
            if (scb != null)
                ep_agent.monitor.tlp_ap.connect(scb.ep_imp);
            ep_agent.monitor.tlp_ap.connect(cov.analysis_export);
            if (bridge_required && (bridge_ep_rx_fifos.size() > 0) &&
                (bridge_ep_rx_fifos[0] != null))
                ep_agent.monitor.tlp_ap.connect(
                    bridge_ep_rx_fifos[0].analysis_export);
            v_seqr.ep_seqr_arr.push_back(ep_agent.sequencer);
            v_seqr.ep_seqr = ep_agent.sequencer;
        end

        // 5. Virtual sequencer shared refs (alias managers -> root 0)
        v_seqr.fc_mgr  = fc_mgr;
        v_seqr.tag_mgr = tag_mgr;

        // 6. Coverage shared component references
        cov.fc_mgr  = fc_mgr;
        cov.tag_mgr = tag_mgr;

        // 7. Switch mode wiring: each EP[i] uses the managers of its owning root,
        //    and its monitor feeds the owning root's scoreboard.
        if (cfg.switch_enable && sw != null) begin
            for (int i = 0; i < cfg.switch_cfg.num_ds_ports; i++) begin
                int owner = cfg.switch_cfg.dsp_owner[i];   // owning USP/root index
                ep_agents[i].fc_mgr    = sw.dsp[i].fc_mgr;
                ep_agents[i].tag_mgr   = tag_mgrs[owner];
                ep_agents[i].ord_eng   = ord_engs[owner];
                begin
                    pcie_tl_func_context ep_context;
                    ep_context = configured_ep_context(i);
                    ep_agents[i].cfg_mgr = (ep_context == null) ?
                        cfg_mgrs[owner] : ep_context.cfg_mgr;
                end
                ep_agents[i].bw_shaper = bw_shaper;
                ep_agents[i].codec     = codec;
                ep_agents[i].adapter   = ep_adapters[i];
                ep_agents[i].external_completion_driver_enable = bridge_required;
                ep_agents[i].inject_shared_components();
                if (ep_agents[i].ep_driver != null) begin
                    ep_agents[i].ep_driver.mps_bytes        = int'(cfg.max_payload_size);
                    ep_agents[i].ep_driver.rcb_bytes        = int'(cfg.read_completion_boundary);
                    ep_agents[i].ep_driver.use_unified_mem  = cfg.use_unified_mem;
                    // mem handle assigned in unified-mem distribution block below
                    if (cfg.sriov_enable && func_mgr_sriov != null)
                        ep_agents[i].ep_driver.func_manager = func_mgr_sriov;
                end
                ep_adapters[i].mode   = cfg.if_mode;
                ep_adapters[i].codec  = codec;
                ep_adapters[i].fc_mgr = sw.dsp[i].fc_mgr;

                // EP[i] monitor -> owning root's scoreboard + coverage; v_seqr ep arr
                if (scbs.size() > owner && scbs[owner] != null)
                    ep_agents[i].monitor.tlp_ap.connect(scbs[owner].ep_imp);
                ep_agents[i].monitor.tlp_ap.connect(cov.analysis_export);
                if (bridge_required && (bridge_ep_rx_fifos.size() > i) &&
                    (bridge_ep_rx_fifos[i] != null))
                    ep_agents[i].monitor.tlp_ap.connect(
                        bridge_ep_rx_fifos[i].analysis_export);
                v_seqr.ep_seqr_arr.push_back(ep_agents[i].sequencer);
            end
        end

        // 8. Completion timeout (per-root RC drivers)
        foreach (rc_agents[r])
            if (rc_agents[r] != null && rc_agents[r].rc_driver != null)
                rc_agents[r].rc_driver.cpl_timeout_ns = cfg.cpl_timeout_ns;

        // 9. RC driver scalar injection (per-root)
        foreach (rc_agents[r]) begin
            if (rc_agents[r] == null || rc_agents[r].rc_driver == null) continue;
            rc_agents[r].rc_driver.mps_bytes       = int'(cfg.max_payload_size);
            rc_agents[r].rc_driver.rcb_bytes       = int'(cfg.read_completion_boundary);
            rc_agents[r].rc_driver.use_unified_mem = cfg.use_unified_mem;
        end

        // 10. Unified-memory distribution: correct per-agent handles from config_db
        //     Gated by use_unified_mem (default 0) — OFF path leaves mem=null (unchanged)
        if (cfg.use_unified_mem) begin
            int nep;
            nep = (cfg.switch_enable && cfg.switch_cfg != null)
                  ? cfg.switch_cfg.num_ds_ports
                  : (cfg.ep_agent_enable ? cfg.num_ep : 0);

            // RC ← host_mem
            if (uvm_config_db#(host_mem_api)::get(this, "", "host_mem", host_mem)) begin
                host_mem.init_region(64'h0, 64'hFFFF_FFFF,
                                     cfg.mem_alloc_mode, cfg.mem_granule);
                if (cfg.mem_access_mode == PCIE_TL_MEM_PREMAP)
                    void'(host_mem.alloc(cfg.premap_size, cfg.mem_granule));
                if (rc_agent != null && rc_agent.rc_driver != null)
                    rc_agent.rc_driver.mem = host_mem;
            end

            // EP[i] ← dev_mem[i]
            for (int i = 0; i < nep; i++) begin
                host_mem_api dm;
                if (uvm_config_db#(host_mem_api)::get(this, "",
                                                       $sformatf("dev_mem_%0d", i), dm)) begin
                    dm.init_region(64'h0, 64'hFFFF_FFFF,
                                   cfg.mem_alloc_mode, cfg.mem_granule);
                    if (cfg.mem_access_mode == PCIE_TL_MEM_PREMAP)
                        void'(dm.alloc(cfg.premap_size, cfg.mem_granule));
                    dev_mem[i] = dm;
                    if (i < ep_agents.size()) begin
                        if (ep_agents[i] != null && ep_agents[i].ep_driver != null)
                            ep_agents[i].ep_driver.mem = dm;
                    end else if (i == 0 && !cfg.switch_enable) begin
                        if (ep_agent != null && ep_agent.ep_driver != null)
                            ep_agent.ep_driver.mem = dm;
                    end
                end
            end
        end
    endfunction

    //=========================================================================
    // Run Phase: TLM loopback bridge
    //=========================================================================
    task run_phase(uvm_phase phase);
        // FULL_VIP bridge 的 Serial/PIPE 传输由 SVT HDL interconnect 完成；
        // 这里仅补上“EP monitor -> EP driver”的业务层入口。它与 TLM
        // loopback 互斥，避免同一请求被重复响应。
        if (bridge_required && cfg.ep_auto_response &&
            (bridge_ep_rx_fifos.size() > 0)) begin
            if (cfg.switch_enable && (sw != null)) begin
                fork
                    for (int i = 0; i < bridge_ep_rx_fifos.size(); i++) begin
                        automatic int idx = i;
                        fork
                            bridge_ep_request_loop_index(idx);
                        join_none
                    end
                join_none
            end
            else if (ep_agents.size() > 0) begin
                fork
                    for (int i = 0; i < bridge_ep_rx_fifos.size(); i++) begin
                        automatic int idx = i;
                        if ((idx < ep_agents.size()) &&
                            (ep_agents[idx] != null)) begin
                            fork
                                bridge_ep_request_loop_index(idx);
                            join_none
                        end
                    end
                join_none
            end
            else if (ep_agent != null) begin
                fork
                    bridge_ep_request_loop_single();
                join_none
            end
        end

        // 外部 FULL_VIP transport 的反向请求路径：EP requester 产生的
        // Memory Read/Write 到达 RC monitor 后，由 RC driver 的统一内存
        // responder 生成 Completion，再经 RC adapter 返回 SVT Serial。
        // Completion 本身已由 completion_analysis_imp 处理，因此该循环
        // 明确跳过 completion 类 TLP，避免重复匹配和释放 tag。
        if (bridge_required && cfg.rc_agent_enable &&
            (bridge_rc_rx_fifos.size() > 0)) begin
            fork
                for (int r = 0; r < bridge_rc_rx_fifos.size(); r++) begin
                    automatic int idx = r;
                    fork
                        bridge_rc_request_loop_index(idx);
                    join_none
                end
            join_none
        end

        // SVT bridge 模式由 pcie_svt_if_adapter 直接驱动外部 SVT
        // transport。此时不能再启动本环境的 TLM loopback，否则会有一条
        // 永远等待 rc_adapter.tlm_tx_fifo 的“幽灵”路径，并且可能与
        // Serial/PIPE 返回事务竞争同一个 adapter FIFO。
        if ((cfg.if_mode == TLM_MODE) && !bridge_required &&
            (rc_agent != null)) begin
            if (cfg.switch_enable && sw != null) begin
                // Switch mode: RC[r] <-> Switch <-> EP[N]
                fork
                    for (int r = 0; r < rc_agents.size(); r++) begin
                        automatic int rr = r;
                        fork
                            rc_to_switch_loopback(rr);
                            switch_to_rc_loopback(rr);
                        join_none
                    end
                    for (int i = 0; i < cfg.switch_cfg.num_ds_ports; i++) begin
                        automatic int idx = i;
                        fork
                            switch_to_ep_loopback(idx);
                            ep_to_switch_loopback(idx);
                        join_none
                    end
                join_none
            end else if (!cfg.switch_enable && ep_adapters.size() > 0) begin
                // Non-switch multi-agent: independent RC[i] <-> EP[i] TLM pairs
                fork
                    for (int i = 0; i < ep_adapters.size(); i++) begin
                        automatic int ii = i;
                        if (ii < rc_agents.size() && rc_agents[ii] != null &&
                            ep_agents[ii] != null) begin
                            fork
                                tlm_loopback_rc_to_ep_pair(ii);
                                tlm_loopback_ep_to_rc_pair(ii);
                            join_none
                        end
                    end
                join_none
            end else if (ep_agent != null) begin
                // Direct mode: RC <-> EP (existing)
                fork
                    tlm_loopback_rc_to_ep();
                    tlm_loopback_ep_to_rc();
                join_none
            end
        end
    endtask

    // Direct/single-EP bridge request dispatcher.
    protected task bridge_ep_request_loop_single();
        pcie_tl_tlp tlp;
        forever begin
            bridge_ep_rx_fifos[0].get(tlp);
            if ((ep_agent != null) && (ep_agent.ep_driver != null) &&
                (tlp != null) &&
                (tlp.get_category() == TLP_CAT_COMPLETION)) begin
                pcie_tl_cpl_tlp cpl;
                if ($cast(cpl, tlp))
                    ep_agent.ep_driver.handle_completion(cpl);
            end
            else if ((ep_agent != null) && (ep_agent.ep_driver != null) &&
                     (tlp != null) &&
                     (tlp.kind inside {TLP_MEM_RD, TLP_MEM_RD_LK, TLP_MEM_WR,
                                        TLP_CFG_RD0, TLP_CFG_WR0,
                                        TLP_CFG_RD1, TLP_CFG_WR1,
                                        TLP_IO_RD, TLP_IO_WR})) begin
                `uvm_info("ENV_BRIDGE", $sformatf(
                    "FULL_VIP EP request -> ep_driver: %s",
                    tlp.convert2string()), UVM_HIGH)
                ep_agent.ep_driver.handle_request(tlp);
            end
        end
    endtask

    // Indexed dispatcher used by non-switch multi-EP and switch DS ports.
    protected task bridge_ep_request_loop_index(int idx);
        pcie_tl_tlp tlp;
        forever begin
            bridge_ep_rx_fifos[idx].get(tlp);
            if ((idx < ep_agents.size()) && (ep_agents[idx] != null) &&
                (ep_agents[idx].ep_driver != null) && (tlp != null) &&
                (tlp.get_category() == TLP_CAT_COMPLETION)) begin
                pcie_tl_cpl_tlp cpl;
                if ($cast(cpl, tlp))
                    ep_agents[idx].ep_driver.handle_completion(cpl);
            end
            else if ((idx < ep_agents.size()) && (ep_agents[idx] != null) &&
                     (ep_agents[idx].ep_driver != null) && (tlp != null) &&
                     (tlp.kind inside {TLP_MEM_RD, TLP_MEM_RD_LK, TLP_MEM_WR,
                                        TLP_CFG_RD0, TLP_CFG_WR0,
                                        TLP_CFG_RD1, TLP_CFG_WR1,
                                        TLP_IO_RD, TLP_IO_WR})) begin
                `uvm_info("ENV_BRIDGE", $sformatf(
                    "FULL_VIP EP[%0d] request -> ep_driver: %s",
                    idx, tlp.convert2string()), UVM_HIGH)
                ep_agents[idx].ep_driver.handle_request(tlp);
            end
        end
    endtask

    // Consume requests arriving at one RC from an external SVT transport.
    // The responder intentionally runs in the environment task context so the
    // RC driver can use its normal tag/memory/completion implementation.
    protected task bridge_rc_request_loop_index(int idx);
        pcie_tl_tlp tlp;
        forever begin
            bridge_rc_rx_fifos[idx].get(tlp);
            if ((idx < rc_agents.size()) && (rc_agents[idx] != null) &&
                (rc_agents[idx].rc_driver != null) && (tlp != null) &&
                (tlp.get_category() != TLP_CAT_COMPLETION) &&
                (tlp.kind inside {TLP_MEM_RD, TLP_MEM_RD_LK, TLP_MEM_WR,
                                   TLP_CFG_RD0, TLP_CFG_WR0,
                                   TLP_CFG_RD1, TLP_CFG_WR1,
                                   TLP_IO_RD, TLP_IO_WR,
                                   TLP_ATOMIC_FETCHADD, TLP_ATOMIC_SWAP,
                                   TLP_ATOMIC_CAS})) begin
                `uvm_info("ENV_BRIDGE", $sformatf(
                    "FULL_VIP RC[%0d] request -> rc_driver: %s",
                    idx, tlp.convert2string()), UVM_HIGH)
                rc_agents[idx].rc_driver.handle_request(tlp);
            end
        end
    endtask

    //=========================================================================
    // TLM Loopback: RC tx -> EP rx, then EP auto-responds
    //=========================================================================
    protected task tlm_loopback_rc_to_ep();
        pcie_tl_tlp tlp;
        forever begin
            rc_adapter.tlm_tx_fifo.get(tlp);
            `uvm_info("ENV_LOOP", $sformatf("RC->EP: %s", tlp.convert2string()), UVM_HIGH)

            // Register non-posted requests in scoreboard IMMEDIATELY (before delay)
            // so completions can match even if they arrive before the EP monitor sees the request
            if (scb != null && tlp.requires_completion())
                scb.register_pending(tlp);

            rc2ep_delay.forward(tlp, ep_adapter.tlm_rx_fifo);
            replenish_credits(tlp);
            if (ep_agent.ep_driver != null &&
                tlp.get_category() == TLP_CAT_COMPLETION) begin
                // CplD for an EP-originated request (e.g. DMA read): fold
                // read-back data onto the request object so the EP seq can read it.
                pcie_tl_cpl_tlp cpl;
                if ($cast(cpl, tlp)) ep_agent.ep_driver.handle_completion(cpl);
            end
            else if (cfg.ep_auto_response && ep_agent.ep_driver != null) begin
                // Keep endpoint request handling in ingress order. A posted
                // write must update the EP model before a following read is
                // handled on this same TLM link.
                ep_agent.ep_driver.handle_request(tlp);
            end
        end
    endtask

    //=========================================================================
    // TLM Loopback: EP tx -> RC rx (completions and DMA)
    //=========================================================================
    protected task tlm_loopback_ep_to_rc();
        pcie_tl_tlp tlp;
        forever begin
            ep_adapter.tlm_tx_fifo.get(tlp);
            `uvm_info("ENV_LOOP", $sformatf("EP->RC: %s", tlp.convert2string()), UVM_HIGH)
            ep2rc_delay.forward(tlp, rc_adapter.tlm_rx_fifo);
            replenish_credits(tlp);
            if (tlp.get_category() == TLP_CAT_COMPLETION) begin
                // Write completion to scoreboard IMMEDIATELY (before tag is freed/reused)
                if (scb != null)
                    scb.write_rc(tlp);
                // Then handle in RC driver (may free tag)
                if (rc_agent.rc_driver != null) begin
                    pcie_tl_cpl_tlp cpl;
                    if ($cast(cpl, tlp))
                        void'(rc_agent.rc_driver.handle_completion(cpl));
                end
            end
            // RC auto-response for EP-originated requests.
            // Unified-memory path: handle MRd/MRdLk/Atomic AND posted MWr (the posted-MWr
            // gap fix: MWr is not requires_completion() so the old branch silently dropped it).
            // Legacy path: rc_auto_respond for requires_completion() only (unchanged).
            else if (cfg.use_unified_mem && rc_agent != null && rc_agent.rc_driver != null &&
                     (tlp.requires_completion() || tlp.kind == TLP_MEM_WR)) begin
                // Register in scoreboard only for non-posted (completion will be matched)
                if (scb != null && tlp.requires_completion())
                    scb.register_pending(tlp);
                begin
                    automatic pcie_tl_tlp req_copy = tlp;
                    fork
                        rc_agent.rc_driver.handle_request(req_copy);
                    join_none
                end
            end else if (tlp.requires_completion()) begin
                // Legacy (non-unified) path: rc_auto_respond for EP DMA reads
                if (scb != null)
                    scb.register_pending(tlp);
                begin
                    automatic pcie_tl_tlp req_copy = tlp;
                    fork
                        rc_auto_respond(req_copy, ep_agent.ep_driver, 0, 0);
                    join_none
                end
            end
        end
    endtask

    //=========================================================================
    // Non-switch pair loopback: RC[i] tx -> EP[i] rx (+ EP auto-response)
    //=========================================================================
    protected task tlm_loopback_rc_to_ep_pair(int i);
        pcie_tl_tlp tlp;
        int mi = (i < fc_mgrs.size()) ? i : 0;
        forever begin
            rc_adapters[i].tlm_tx_fifo.get(tlp);
            if (scbs.size() > i && scbs[i] != null && tlp.requires_completion())
                scbs[i].register_pending(tlp);
            rc2ep_delay.forward(tlp, ep_adapters[i].tlm_rx_fifo);
            replenish_port_credits(fc_mgrs[mi], tlp);
            if (ep_agents[i].ep_driver != null &&
                tlp.get_category() == TLP_CAT_COMPLETION) begin
                // CplD for an EP-originated request: fold read-back data onto
                // the request object so the EP seq can read it.
                pcie_tl_cpl_tlp cpl;
                if ($cast(cpl, tlp)) ep_agents[i].ep_driver.handle_completion(cpl);
            end
            else if (cfg.ep_auto_response && ep_agents[i].ep_driver != null) begin
                // Keep endpoint request handling in ingress order per link.
                ep_agents[i].ep_driver.handle_request(tlp);
            end
        end
    endtask

    //=========================================================================
    // Non-switch pair loopback: EP[i] tx -> RC[i] rx (completions + unified DMA)
    //=========================================================================
    protected task tlm_loopback_ep_to_rc_pair(int i);
        pcie_tl_tlp tlp;
        int mi = (i < fc_mgrs.size()) ? i : 0;
        forever begin
            ep_adapters[i].tlm_tx_fifo.get(tlp);
            ep2rc_delay.forward(tlp, rc_adapters[i].tlm_rx_fifo);
            replenish_port_credits(fc_mgrs[mi], tlp);
            if (tlp.get_category() == TLP_CAT_COMPLETION) begin
                if (scbs.size() > i && scbs[i] != null)
                    scbs[i].write_rc(tlp);
                if (rc_agents[i].rc_driver != null) begin
                    pcie_tl_cpl_tlp cpl;
                    if ($cast(cpl, tlp))
                        void'(rc_agents[i].rc_driver.handle_completion(cpl));
                end
            end
            // Unified-memory path: route EP->host requests to RC[i] responder.
            else if (cfg.use_unified_mem && rc_agents[i].rc_driver != null &&
                     (tlp.requires_completion() || tlp.kind == TLP_MEM_WR)) begin
                if (scbs.size() > i && scbs[i] != null && tlp.requires_completion())
                    scbs[i].register_pending(tlp);
                begin
                    automatic pcie_tl_tlp req_copy = tlp;
                    fork
                        rc_agents[i].rc_driver.handle_request(req_copy);
                    join_none
                end
            end else if (tlp.requires_completion()) begin
                if (scbs.size() > i && scbs[i] != null)
                    scbs[i].register_pending(tlp);
                begin
                    automatic pcie_tl_tlp req_copy = tlp;
                    automatic pcie_tl_ep_driver requester_driver =
                        ep_agents[i].ep_driver;
                    fork
                        rc_auto_respond(req_copy, requester_driver, i, 0);
                    join_none
                end
            end
        end
    endtask

    //=========================================================================
    // RC auto-response: generate completion for EP DMA reads
    //=========================================================================
    protected task rc_auto_respond(
        pcie_tl_tlp req, pcie_tl_ep_driver requester_driver,
        int root_index, bit switch_origin);
        pcie_tl_mem_tlp mem_req;
        pcie_tl_cpl_tlp cpl;
        pcie_tl_ep_driver resolved_requester_driver;
        switch_np_key_t switch_key;
        int ingress_port;
        int endpoint_index;
        int total_bytes, chunk, remaining, received;
        bit [63:0] cur_addr;
        int mps_bytes, rcb_bytes;

        if (!$cast(mem_req, req)) return;
        if (req.kind != TLP_MEM_RD && req.kind != TLP_MEM_RD_LK) return;

        if ((root_index < 0) || (root_index >= tag_mgrs.size()))
            `uvm_fatal("ENV_LEGACY_CPL", $sformatf(
                "invalid root index %0d for %0d tag managers",
                root_index, tag_mgrs.size()))

        resolved_requester_driver = requester_driver;
        if (switch_origin) begin
            if ((sw == null) || (cfg.switch_cfg == null))
                `uvm_fatal("ENV_LEGACY_CPL",
                           "switch-origin request has no switch")
            switch_key = switch_np_key(req.requester_id, req.tag);
            if (!sw.outstanding_ingress.exists(switch_key))
                `uvm_fatal("ENV_LEGACY_CPL", $sformatf(
                    "no switch ingress for requester=%04h tag=%03h",
                    req.requester_id, req.tag))
            ingress_port = sw.outstanding_ingress[switch_key];
            endpoint_index = ingress_port - cfg.switch_cfg.num_usp;
            if ((endpoint_index < 0) ||
                (endpoint_index >= ep_agents.size()) ||
                (endpoint_index >= cfg.switch_cfg.dsp_owner.size()) ||
                (cfg.switch_cfg.dsp_owner[endpoint_index] != root_index) ||
                (ep_agents[endpoint_index] == null) ||
                (ep_agents[endpoint_index].ep_driver == null)) begin
                `uvm_fatal("ENV_LEGACY_CPL", $sformatf(
                    {"invalid switch completion destination root=%0d ",
                     "ingress=%0d endpoint=%0d"},
                    root_index, ingress_port, endpoint_index))
            end
            resolved_requester_driver = ep_agents[endpoint_index].ep_driver;
        end
        else if (resolved_requester_driver == null) begin
            `uvm_fatal("ENV_LEGACY_CPL",
                       "direct request has no requester EP driver")
        end

        mps_bytes = int'(cfg.max_payload_size);
        rcb_bytes = int'(cfg.read_completion_boundary);
        total_bytes = (req.length == 0) ? 4096 : req.length * 4;
        remaining   = total_bytes;
        cur_addr    = mem_req.addr;
        received    = 0;

        while (remaining > 0) begin
            int bytes_to_rcb, len_dw;

            // Every Completion must end at or before the next RCB boundary.
            bytes_to_rcb = rcb_bytes - (cur_addr % rcb_bytes);
            if (bytes_to_rcb == 0) bytes_to_rcb = rcb_bytes;
            chunk = mps_bytes;
            if (bytes_to_rcb < chunk) chunk = bytes_to_rcb;
            if (chunk > remaining) chunk = remaining;
            len_dw = (chunk + 3) / 4;

            cpl = pcie_tl_cpl_tlp::type_id::create("rc_auto_cpl");
            cpl.kind         = TLP_CPLD;
            cpl.fmt          = FMT_3DW_WITH_DATA;
            cpl.type_f       = TLP_TYPE_CPL;
            cpl.tc           = req.tc;
            cpl.attr         = req.attr;
            cpl.length       = (len_dw == 1024) ? 0 : len_dw[9:0];
            cpl.requester_id = req.requester_id;
            cpl.tag          = req.tag;
            cpl.completer_id = 16'h0000;  // RC BDF
            cpl.cpl_status   = CPL_STATUS_SC;
            cpl.bcm          = 0;
            cpl.byte_count   = remaining[11:0];
            cpl.lower_addr   = cur_addr[6:0];
            cpl.payload      = new[chunk];
            foreach (cpl.payload[i])
                cpl.payload[i] = 8'hAA;  // Fill pattern

            // Observation only: legacy completions deliberately bypass the
            // adapter/monitor transport, so publish before the direct
            // scoreboard write without changing functional behavior.
            legacy_rc_cpl_ap.write(cpl);

            // Preserve legacy observation-before-scoreboard ordering, then
            // use the requesting EP driver's normal read-back foldback path.
            if (scbs.size() > root_index && scbs[root_index] != null)
                scbs[root_index].write_ep(cpl);
            resolved_requester_driver.handle_completion(cpl);

            cur_addr  += chunk;
            remaining -= chunk;
            received  += chunk;
        end

        if (switch_origin)
            sw.outstanding_ingress.delete(switch_key);
        tag_mgrs[root_index].free_tag(req.tag, req.requester_id[2:0]);
    endtask

    //=========================================================================
    // Switch Mode Loopback Tasks
    //=========================================================================

    // RC[r] tx -> Switch USP[r] rx
    protected task rc_to_switch_loopback(int r);
        pcie_tl_tlp tlp;
        forever begin
            rc_adapters[r].tlm_tx_fifo.get(tlp);
            if (scbs[r] != null && tlp.requires_completion())
                scbs[r].register_pending(tlp);
            replenish_credits(tlp);  // Return RC-side FC credits (TLP delivered to switch)
            sw.usps[r].rx_fifo.put(tlp);
        end
    endtask

    // Switch USP[r] tx -> RC[r] rx
    protected task switch_to_rc_loopback(int r);
        pcie_tl_tlp tlp;
        forever begin
            sw.usps[r].tx_fifo.get(tlp);
            rc_adapters[r].tlm_rx_fifo.put(tlp);
            replenish_credits(tlp);
            if (tlp.get_category() == TLP_CAT_COMPLETION) begin
                if (scbs[r] != null)
                    scbs[r].write_rc(tlp);
                if (rc_agents[r].rc_driver != null) begin
                    pcie_tl_cpl_tlp cpl;
                    if ($cast(cpl, tlp))
                        void'(rc_agents[r].rc_driver.handle_completion(cpl));
                end
            end
            // Unified-memory path: route EP->host memory requests to RC responder.
            // Gated by use_unified_mem (default 0) — legacy/OFF behavior is unchanged.
            else if (cfg.use_unified_mem && rc_agents[r] != null && rc_agents[r].rc_driver != null &&
                     (tlp.kind inside {TLP_MEM_WR, TLP_MEM_RD, TLP_MEM_RD_LK,
                                       TLP_ATOMIC_FETCHADD, TLP_ATOMIC_SWAP, TLP_ATOMIC_CAS})) begin
                if (scbs[r] != null && tlp.requires_completion())
                    scbs[r].register_pending(tlp);
                begin
                    automatic pcie_tl_tlp req_copy = tlp;
                    fork
                        rc_agents[r].rc_driver.handle_request(req_copy);
                    join_none
                end
            end else if (tlp.requires_completion()) begin
                if (scbs[r] != null)
                    scbs[r].register_pending(tlp);
                begin
                    automatic pcie_tl_tlp req_copy = tlp;
                    fork
                        rc_auto_respond(req_copy, null, r, 1);
                    join_none
                end
            end
        end
    endtask

    // Switch DSP[i] tx -> EP[i] rx (+ EP auto-response)
    protected task switch_to_ep_loopback(int idx);
        pcie_tl_tlp tlp;
        forever begin
            sw.dsp[idx].tx_fifo.get(tlp);
            ep_adapters[idx].tlm_rx_fifo.put(tlp);
            replenish_credits(tlp);
            if (ep_agents[idx].ep_driver != null &&
                tlp.get_category() == TLP_CAT_COMPLETION) begin
                // CplD for an EP-originated request: fold read-back data onto
                // the request object so the EP seq can read it.
                pcie_tl_cpl_tlp cpl;
                if ($cast(cpl, tlp)) ep_agents[idx].ep_driver.handle_completion(cpl);
            end
            else if (cfg.ep_auto_response && ep_agents[idx].ep_driver != null) begin
                if (tlp.kind inside {TLP_MEM_RD, TLP_MEM_RD_LK, TLP_MEM_WR,
                                     TLP_CFG_RD0, TLP_CFG_WR0, TLP_IO_RD, TLP_IO_WR}) begin
                    // The DSP ingress FIFO is ordered; preserve that order
                    // while applying requests to its endpoint model.
                    ep_agents[idx].ep_driver.handle_request(tlp);
                end
            end
        end
    endtask

    // EP[i] tx -> Switch DSP[i] rx
    protected task ep_to_switch_loopback(int idx);
        pcie_tl_tlp tlp;
        forever begin
            ep_adapters[idx].tlm_tx_fifo.get(tlp);
            // Replenish EP's per-port FC credits (TLP delivered to switch)
            replenish_port_credits(sw.dsp[idx].fc_mgr, tlp);
            sw.dsp[idx].rx_fifo.put(tlp);
        end
    endtask

    //=========================================================================
    // Replenish FC credits after TLP delivery (TLM mode only)
    //=========================================================================
    protected function void replenish_credits(pcie_tl_tlp tlp);
        int data_credits;
        if (!cfg.fc_enable || cfg.infinite_credit) return;
        data_credits = tlp.get_data_credits();
        case (tlp.get_category())
            TLP_CAT_POSTED: begin
                fc_mgr.return_credit(FC_POSTED_HDR, 1);
                fc_mgr.return_credit(FC_POSTED_DATA, data_credits);
            end
            TLP_CAT_NON_POSTED: begin
                fc_mgr.return_credit(FC_NONPOSTED_HDR, 1);
                fc_mgr.return_credit(FC_NONPOSTED_DATA, data_credits);
            end
            TLP_CAT_COMPLETION: begin
                fc_mgr.return_credit(FC_CPL_HDR, 1);
                fc_mgr.return_credit(FC_CPL_DATA, data_credits);
            end
        endcase
    endfunction

    //=========================================================================
    // Replenish per-port FC credits (for switch mode)
    //=========================================================================
    protected function void replenish_port_credits(pcie_tl_fc_manager port_fc, pcie_tl_tlp tlp);
        int data_credits;
        if (!port_fc.fc_enable || port_fc.infinite_credit) return;
        data_credits = tlp.get_data_credits();
        case (tlp.get_category())
            TLP_CAT_POSTED: begin
                port_fc.return_credit(FC_POSTED_HDR, 1);
                port_fc.return_credit(FC_POSTED_DATA, data_credits);
            end
            TLP_CAT_NON_POSTED: begin
                port_fc.return_credit(FC_NONPOSTED_HDR, 1);
                port_fc.return_credit(FC_NONPOSTED_DATA, data_credits);
            end
            TLP_CAT_COMPLETION: begin
                port_fc.return_credit(FC_CPL_HDR, 1);
                port_fc.return_credit(FC_CPL_DATA, data_credits);
            end
        endcase
    endfunction

    //=========================================================================
    // Apply configuration to all components
    //=========================================================================
    function void apply_config();
        // FC (per-root)
        foreach (fc_mgrs[r]) begin
            fc_mgrs[r].fc_enable       = cfg.fc_enable;
            fc_mgrs[r].infinite_credit = cfg.infinite_credit;
            fc_mgrs[r].init_credits(cfg.init_ph_credit, cfg.init_pd_credit,
                                    cfg.init_nph_credit, cfg.init_npd_credit,
                                    cfg.init_cplh_credit, cfg.init_cpld_credit);
        end

        // BW Shaper (shared)
        bw_shaper.shaper_enable = cfg.shaper_enable;
        bw_shaper.avg_rate      = cfg.avg_rate;
        bw_shaper.burst_size    = cfg.burst_size;

        // Tag (per-root)
        foreach (tag_mgrs[r]) begin
            tag_mgrs[r].extended_tag_enable = cfg.extended_tag_enable;
            tag_mgrs[r].phantom_func_enable = cfg.phantom_func_enable;
            tag_mgrs[r].max_outstanding     = cfg.max_outstanding;
            tag_mgrs[r].init_pool(0, cfg.extended_tag_enable, cfg.phantom_func_enable);
        end

        // Ordering (per-root)
        foreach (ord_engs[r]) begin
            ord_engs[r].relaxed_ordering_enable  = cfg.relaxed_ordering_enable;
            ord_engs[r].id_based_ordering_enable = cfg.id_based_ordering_enable;
            ord_engs[r].bypass_ordering          = cfg.bypass_ordering;
        end

        // Coverage
        cov.cov_enable          = cfg.cov_enable;
        cov.tlp_basic_enable    = cfg.tlp_basic_cov;
        cov.fc_state_enable     = cfg.fc_state_cov;
        cov.tag_usage_enable    = cfg.tag_usage_cov;
        cov.ordering_enable     = cfg.ordering_cov;
        cov.error_inject_enable = cfg.error_inject_cov;
        cov.sriov_enable      = cfg.sriov_enable;
        cov.prefix_cov_enable = cfg.prefix_enable;

        // Scoreboard (per-root)
        foreach (scbs[r]) begin
            if (scbs[r] == null) continue;
            scbs[r].ordering_check_enable   = cfg.ordering_check_enable;
            scbs[r].completion_check_enable = cfg.completion_check_enable;
            scbs[r].data_integrity_enable   = cfg.data_integrity_enable;
            scbs[r].prefix_check_enable     = cfg.prefix_enable;
            scbs[r].strict_check            = cfg.scb_strict_check;
        end

        // Adapter mode (per-root RC; single + array EP adapters, all null-safe)
        foreach (rc_adapters[r]) begin
            // SVT forward 模式必须保持 SV_IF_MODE，monitor 才会把外部
            // Completion 交回 RC driver；普通 TL-only 仍沿用 cfg.if_mode。
            rc_adapters[r].mode = bridge_required ? SV_IF_MODE : cfg.if_mode;
        end
        if (ep_adapter != null)
            ep_adapter.mode = bridge_required ? SV_IF_MODE : cfg.if_mode;
        foreach (ep_adapters[i])
            if (ep_adapters[i] != null)
                ep_adapters[i].mode = bridge_required ? SV_IF_MODE : cfg.if_mode;

        // Config space init (per-root)
        foreach (cfg_mgrs[r]) begin
            cfg_mgrs[r].init_type0_header();
            cfg_mgrs[r].init_pcie_capability(
                8'h40, cfg.max_payload_size, cfg.max_read_request_size,
                cfg.read_completion_boundary, cfg.extended_tag_enable);
        end

        // Link Delay
        rc2ep_delay.enable          = cfg.link_delay_enable;
        rc2ep_delay.latency_min_ns  = cfg.rc2ep_latency_min_ns;
        rc2ep_delay.latency_max_ns  = cfg.rc2ep_latency_max_ns;
        rc2ep_delay.update_interval = cfg.link_delay_update_interval;

        ep2rc_delay.enable          = cfg.link_delay_enable;
        ep2rc_delay.latency_min_ns  = cfg.ep2rc_latency_min_ns;
        ep2rc_delay.latency_max_ns  = cfg.ep2rc_latency_max_ns;
        ep2rc_delay.update_interval = cfg.link_delay_update_interval;

    endfunction

endclass
