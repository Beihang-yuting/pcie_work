//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Top-level Environment
//-----------------------------------------------------------------------------

class pcie_tl_env extends uvm_env;
    `uvm_component_utils(pcie_tl_env)

    //--- Configuration ---
    pcie_tl_env_config     cfg;

    // 后端无关的全局配置。TL-only 用户不需要提供该对象；SVT 或其他
    // transport provider 通过它选择实际启用的物理链路。
    pcie_global_cfg        global_cfg;
    pcie_tl_backend_provider backend_provider;
    pcie_tl_backend_factory  backend_factory;

    // 拓扑配置是可选的编排入口。存在 topology_cfg 时，环境在创建任何
    // agent 之前把后端无关拓扑转换成原生 pcie_tl_env_config；没有该
    // 对象时，继续走历史的直接 cfg 注入路径。
    pcie_topology_cfg      topology_cfg;
    pcie_tl_topology_adapter topology_adapter;

    // 标记本次 build 是否由 topology_cfg 产生 native cfg。该标记用于
    // 阻止后续历史 cfg lookup 把刚完成的拓扑转换结果覆盖掉。
    protected bit          topology_cfg_active;

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
    // Resolved RC Root -> shared Host manager handles.  The array is sized to
    // the actual RC count; no fixed HDL/VIP maximum is introduced here.
    host_mem_api    host_mem_by_root[];
    host_mem_api    dev_mem[16];

    // 设备上下文表只在提供全局 device 策略时构建；不用 global-cfg 的旧
    // 测试保持空表。key 是"域限定 BDF"字符串（见 device_context_key）：
    // 不同 Host/segment 是独立枚举空间，允许相同 BDF，只有同域重复才
    // 是错误。
    pcie_tl_func_context device_contexts[string];
    pcie_tl_device_cfg_adapter device_cfg_adapter;

    // 生成域限定的 device context 查找 key；委托给 pcie_device_cfg 的
    // 公共 context_key()，测试与 env 共用同一格式。
    protected function string device_context_key(pcie_device_cfg device);
        return device.context_key();
    endfunction

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

    // 在 build_phase 完成 provider 创建后记录其是否被成功接入。该状态
    // 只用于诊断，不改变历史 cfg 注入路径。
    bit backend_provider_active;

    // 返回某个物理 agent 槽位对应的 Endpoint 策略上下文。topology
    // adapter 激活时，EP 槽位遵循规范 link/端口顺序，可能与全局 device
    // 记录的声明顺序不同。优先通过 adapter 的物理节点 ID 关联；对没有
    // graph 节点元数据的 cfg-only/旧调用者保留历史的声明顺序扫描。
    function pcie_tl_func_context configured_ep_context(int ep_index);
        string canonical_node_id;
        int ordinal;

        configured_ep_context = null;

        canonical_node_id = "";
        if (topology_adapter != null) begin
            if (cfg.switch_enable &&
                (ep_index >= 0) &&
                (ep_index < topology_adapter.switch_ep_node_ids.size())) begin
                canonical_node_id = topology_adapter.switch_ep_node_ids[ep_index];
            end
            else if (!cfg.switch_enable &&
                     (ep_index >= 0) &&
                     (ep_index < topology_adapter.direct_ep_node_ids.size())) begin
                canonical_node_id = topology_adapter.direct_ep_node_ids[ep_index];
            end
        end

        // Global/DPU 投影通过稳定的 device_id 或显式 physical_node_id
        // 识别物理 Endpoint。当一个节点拥有多条 PF/VF 记录时，首个匹配
        // 是 PF/基础 function 上下文；全部记录仍可经 device_contexts
        // 访问。
        if (canonical_node_id != "") begin
            foreach (cfg.device_cfgs[i]) begin
                pcie_device_cfg device;

                device = cfg.device_cfgs[i];
                if ((device == null) || (device.role != PCIE_DEVICE_EP))
                    continue;
                if (!((device.device_id == canonical_node_id) ||
                      ((device.physical_node_id != "") &&
                       (device.physical_node_id == canonical_node_id))))
                    continue;
                if (device_contexts.exists(device_context_key(device))) begin
                    configured_ep_context =
                        device_contexts[device_context_key(device)];
                    return configured_ep_context;
                end
            end

            // topology adapter 一旦激活，规范节点匹配失败就是配置错
            // 误，而不是把物理槽位压回声明顺序的许可。返回 null 保留
            // 调用方既有的缺上下文回退（共享 manager），并避免把
            // EP_A 的配置分给 EP_M。
            return configured_ep_context;
        end

        // 历史回退：没有 topology adapter 的调用者保留原有的声明顺序
        // 契约。
        if (topology_adapter != null)
            return configured_ep_context;
        ordinal = 0;
        foreach (cfg.device_cfgs[i]) begin
            if ((cfg.device_cfgs[i] != null) &&
                (cfg.device_cfgs[i].role == PCIE_DEVICE_EP)) begin
                if (ordinal == ep_index) begin
                    if (device_contexts.exists(
                          device_context_key(cfg.device_cfgs[i])))
                        configured_ep_context = device_contexts[
                            device_context_key(cfg.device_cfgs[i])];
                    return configured_ep_context;
                end
                ordinal++;
            end
        end
    endfunction

    // 将 global/device policy 中的 Root 元数据映射到 TL EP agent 顺序。
    // 一个物理 Endpoint 可以拥有多个 PF/VF 记录，但这些记录必须属于
    // 同一个 Root，否则同一 agent 的 flow-control/config manager 归属会
    // 产生歧义。
    protected function void derive_ep_root_bindings(
        pcie_tl_env_config policy_cfg,
        output string errors[$]);
        int endpoint_count;
        int root_count;

        errors.delete();
        if (policy_cfg == null)
            return;

        endpoint_count = policy_cfg.switch_enable &&
                         (policy_cfg.switch_cfg != null) ?
                         policy_cfg.switch_cfg.num_ds_ports : policy_cfg.num_ep;
        root_count = policy_cfg.switch_enable &&
                     (policy_cfg.switch_cfg != null) ?
                     policy_cfg.switch_cfg.num_usp : policy_cfg.num_rc;

        for (int ep_index = 0; ep_index < endpoint_count; ep_index++) begin
            string node_id;
            bit found_root;
            int mapped_root;
            int expected_root;

            node_id = policy_cfg.switch_enable ?
                      ((ep_index < topology_adapter.switch_ep_node_ids.size()) ?
                       topology_adapter.switch_ep_node_ids[ep_index] : "") :
                      ((ep_index < topology_adapter.direct_ep_node_ids.size()) ?
                       topology_adapter.direct_ep_node_ids[ep_index] : "");
            found_root = 1'b0;
            mapped_root = 0;

            foreach (policy_cfg.device_cfgs[device_index]) begin
                pcie_device_cfg device;

                device = policy_cfg.device_cfgs[device_index];
                if ((device == null) || (device.role != PCIE_DEVICE_EP))
                    continue;
                if (!((device.device_id == node_id) ||
                      ((device.physical_node_id != "") &&
                       (device.physical_node_id == node_id))))
                    continue;
                if (!device.root_index_valid)
                    continue;

                if (!found_root) begin
                    found_root = 1'b1;
                    mapped_root = int'(device.root_index);
                end
                else if (mapped_root != int'(device.root_index)) begin
                    errors.push_back($sformatf(
                        "EP%0d physical node '%s' has conflicting Root metadata",
                        ep_index, node_id));
                end
            end

            if (!found_root)
                continue;
            if ((mapped_root < 0) || (mapped_root >= root_count)) begin
                errors.push_back($sformatf(
                    "EP%0d maps to invalid Root%0d (Root count=%0d)",
                    ep_index, mapped_root, root_count));
                continue;
            end

            if (policy_cfg.switch_enable &&
                (policy_cfg.switch_cfg != null)) begin
                expected_root = policy_cfg.switch_cfg.dsp_owner[ep_index];
                if (mapped_root != expected_root)
                    errors.push_back($sformatf(
                        "Switch DSP%0d maps to Root%0d but dsp_owner requires Root%0d",
                        ep_index, mapped_root, expected_root));
            end

            begin
                string why;
                if (!policy_cfg.bind_ep_root(ep_index, mapped_root, why))
                    errors.push_back({"EP Root mapping failed: ", why});
            end
        end
    endfunction

    // 统一处理 graph-driven 配置。该阶段只负责把 topology/global policy
    // 投影成 native cfg；真正的 agent、manager、memory 初始化仍由下面的
    // pcie_tl_env build/connect 流程完成，因此不会产生第二个环境层次。
    protected function bit prepare_topology_cfg(output string errors[$]);
        pcie_tl_env_config translated_cfg;
        pcie_tl_env_config policy_cfg;
        errors.delete();
        topology_cfg_active = 1'b0;
        if (!uvm_config_db#(pcie_topology_cfg)::get(
                this, "", "topology_cfg", topology_cfg)) begin
            // 生产集成可以只发布 global_cfg；其中的 authoritative topology
            // 自动作为 TL graph 输入。没有任何 graph 时才回退历史 cfg-only
            // 路径，保证旧 test 不需要修改。
            if ((global_cfg == null) || (global_cfg.topology == null))
                return 1'b1;
            topology_cfg = global_cfg.topology;
        end
        if (topology_cfg == null) begin
            errors.push_back("non-null topology_cfg is required");
            return 1'b0;
        end

        topology_cfg.validate(errors);
        if (errors.size() != 0)
            return 1'b0;

        topology_adapter = pcie_tl_topology_adapter::type_id::create(
            "topology_adapter");
        translated_cfg = topology_adapter.translate(topology_cfg, errors);
        if ((translated_cfg == null) || (errors.size() != 0))
            return 1'b0;

        if (!uvm_config_db#(pcie_tl_env_config)::get(
                this, "", "tl_policy_cfg", policy_cfg) ||
            (policy_cfg == null)) begin
            policy_cfg = pcie_tl_env_config::type_id::create(
                "default_tl_policy_cfg");
        end

        if (global_cfg != null) begin
            policy_cfg.device_cfgs.delete();
            foreach (global_cfg.devices[i])
                policy_cfg.device_cfgs.push_back(global_cfg.devices[i]);
        end

        // policy_cfg 保留 flow-control、scoreboard、memory 等行为配置；
        // topology translation 只覆盖决定 native agent 数量/交换结构的字段。
        policy_cfg.rc_agent_enable = translated_cfg.rc_agent_enable;
        policy_cfg.ep_agent_enable = translated_cfg.ep_agent_enable;
        policy_cfg.num_rc = translated_cfg.num_rc;
        policy_cfg.num_ep = translated_cfg.num_ep;
        policy_cfg.switch_enable = translated_cfg.switch_enable;
        policy_cfg.switch_cfg = translated_cfg.switch_cfg;

        derive_ep_root_bindings(policy_cfg, errors);
        if (errors.size() != 0)
            return 1'b0;

        cfg = policy_cfg;
        topology_cfg_active = 1'b1;
        return 1'b1;
    endfunction

    // Return the Root selected for one dynamically created Endpoint agent.
    // The topology preparation above fills ep_root_by_index using physical
    // link/DSP order; the config object also supports the legacy direct path
    // where root_index metadata is stored on device_cfgs itself.
    function int configured_ep_root_index(int ep_index, int fallback_root);
        return cfg.configured_ep_root_index(ep_index, fallback_root);
    endfunction

    // 返回某个角色槽位的权威物理 link ID。这里刻意*不是*扫描 use_svt
    // 链路：直连/Switch 拓扑中间的 DUT 拥有槽位必须保留其物理序号。
    protected function string provider_link_id(
        pcie_device_role_e role,
        int role_index);
        provider_link_id = "";
        if (global_cfg == null)
            return provider_link_id;
        provider_link_id = global_cfg.canonical_link_id(role, role_index);
    endfunction

    // 在非 TL provider 激活时解析一个物理槽位。只有映射畸形/缺失才返
    // 回 0。返回 1 且 adapter==null 表示该槽位刻意归外部 DUT 所有、必
    // 须保持 null；此模式下不允许任何 TL-only 回退。
    protected function bit resolve_provider_slot(
        pcie_device_role_e role,
        int role_index,
        output string link_id,
        output pcie_tl_if_adapter adapter,
        output bit provider_owned,
        output string error_text);
        pcie_link_cfg link;

        link_id = "";
        adapter = null;
        provider_owned = 1'b0;
        error_text = "";
        if (!backend_provider_active)
            return 1'b1;
        if (global_cfg == null) begin
            error_text = "active backend provider has no global_cfg";
            return 1'b0;
        end

        link_id = provider_link_id(role, role_index);
        if (link_id == "") begin
            error_text = $sformatf(
                "no canonical %s link for physical slot %0d",
                (role == PCIE_DEVICE_RC) ? "RC" : "EP", role_index);
            return 1'b0;
        end
        link = global_cfg.find_link(link_id);
        if (link == null) begin
            error_text = $sformatf(
                "canonical link '%s' is absent from global_cfg", link_id);
            return 1'b0;
        end
        if (!link.enabled) begin
            // 策略禁用的边仍留在物理槽位表中，更高槽位永不重编号；但
            // 本次构建刻意不给它 provider/TL agent。
            provider_owned = 1'b0;
            return 1'b1;
        end

        // svt_role 标识链路的哪一端被模拟。即使链路置了 use_svt，对端
        // 仍是真实 DUT，因此刻意不给它 TL agent/adapter。
        provider_owned = link.use_svt && link.svt_role_valid &&
                         (link.svt_role == role);
        if (!provider_owned)
            return 1'b1;

        adapter = backend_provider.get_adapter_for_link(link_id);
        if (adapter == null) begin
            error_text = $sformatf(
                "provider-owned %s link '%s' has no adapter",
                (role == PCIE_DEVICE_RC) ? "RC" : "EP", link_id);
            return 1'b0;
        end
        return 1'b1;
    endfunction

    // 供 connect_phase 诊断使用：稀疏物理数组出现 null 表项时判断该槽
    // 是否应归 provider。它复刻 resolve_provider_slot 的所有权判定，但
    // 不制造 adapter、不改状态。
    protected function bit strict_slot_provider_owned(
        pcie_device_role_e role,
        int role_index);
        string link_id;
        pcie_link_cfg link;

        strict_slot_provider_owned = 1'b0;
        if (!backend_provider_active || (global_cfg == null))
            return strict_slot_provider_owned;
        link_id = global_cfg.canonical_link_id(role, role_index);
        if (link_id == "")
            return strict_slot_provider_owned;
        link = global_cfg.find_link(link_id);
        if (link == null)
            return strict_slot_provider_owned;
        strict_slot_provider_owned = link.enabled && link.use_svt &&
                                     link.svt_role_valid &&
                                     (link.svt_role == role);
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
        string topology_errors[$];

        super.build_phase(phase);

        // 先读取 global_cfg，再执行 topology translation。这样生产 test
        // 只需发布一个 global_cfg；TL-only 旧 test 没有该对象时完全不受
        // 影响，仍然通过 cfg config-db 获取本地策略。
        void'(uvm_config_db#(pcie_global_cfg)::get(
            this, "", "global_cfg", global_cfg));

        // 拓扑编排必须早于“Get or create config”，否则 native 路径会先
        // 创建默认 1RC+1EP，导致 graph 配置无法覆盖实际 agent 数量。
        if (!prepare_topology_cfg(topology_errors)) begin
            string message;
            message = "";
            foreach (topology_errors[i])
                message = {message, (i == 0) ? "" : "; ", topology_errors[i]};
            `uvm_fatal("TOPO_ENV", message)
            return;
        end

        bridge_required = 1'b0;
        backend_provider_active = 1'b0;
        void'(uvm_config_db#(bit)::get(
            this, "", "pcie_svt_bridge_required", bridge_required));

        legacy_rc_cpl_ap = new("legacy_rc_cpl_ap", this);

        // 1. Get or create config
        if (!topology_cfg_active) begin
            if (!uvm_config_db#(pcie_tl_env_config)::get(this, "", "cfg", cfg) ||
                (cfg == null)) begin
                cfg = pcie_tl_env_config::type_id::create("cfg");
                if (cfg == null) begin
                    `uvm_fatal("ENV", "pcie_tl_env_config factory returned null")
                    return;
                end
                `uvm_info("ENV", "No config found in config_db, using defaults", UVM_MEDIUM)
            end
        end
        if (cfg == null) begin
            `uvm_fatal("ENV", "pcie_tl_env has null cfg after topology preparation")
            return;
        end

        // SVT/其他外部 transport provider 在 TL adapter 创建前完成。TL
        // 环境只依赖中性 provider 契约，因此本文件不需要包含 SVT package。
        if ((global_cfg != null) &&
            (global_cfg.backend != PCIE_BACKEND_TL_ONLY)) begin
            string backend_errors[$];

            global_cfg.validate(backend_errors);
            if (backend_errors.size() != 0) begin
                foreach (backend_errors[i])
                    `uvm_fatal("BACKEND_CFG", backend_errors[i])
                return;
            end

            if (!uvm_config_db#(pcie_tl_backend_provider)::get(
                  this, "", "pcie_tl_backend_provider", backend_provider) ||
                (backend_provider == null)) begin
                if (!uvm_config_db#(pcie_tl_backend_factory)::get(
                      this, "", "pcie_tl_backend_factory", backend_factory) ||
                    (backend_factory == null)) begin
                    `uvm_fatal("BACKEND_CFG", {
                      "global_cfg 选择了非 TL_ONLY backend，但未提供 ",
                      "pcie_tl_backend_provider 或 pcie_tl_backend_factory"})
                    return;
                end
                else begin
                    backend_provider = backend_factory.create_backend(
                        "backend_provider");
                end
            end

            if (backend_provider == null)
                `uvm_fatal("BACKEND_CFG", "backend factory 返回了空 provider")
            if (backend_provider == null)
                return;

            if (backend_provider != null) begin
                if (!backend_provider.build_backend(
                      this, global_cfg, cfg, backend_errors)) begin
                    if (backend_errors.size() == 0)
                        `uvm_fatal("BACKEND_BUILD",
                            "backend provider build failed without diagnostics")
                    foreach (backend_errors[i])
                        `uvm_fatal("BACKEND_BUILD", backend_errors[i])
                    backend_provider_active = 1'b0;
                    return;
                end
                if (!backend_provider.validate_link_adapter_mapping(
                      backend_errors)) begin
                    if (backend_errors.size() == 0)
                        `uvm_fatal("BACKEND_MAP",
                            "backend provider mapping validation failed without diagnostics")
                    foreach (backend_errors[i])
                        `uvm_fatal("BACKEND_MAP", backend_errors[i])
                    backend_provider_active = 1'b0;
                    return;
                end
                backend_provider_active = 1'b1;
                // global_cfg.svt_bridge_enable 是公共配置层提供的显式
                // override。provider.bridge_required 仍表示 transport 自身
                // 的硬性需求；两者取 OR，既允许 SVT provider 自动打开桥，
                // 也允许用户对自定义 provider 明确要求桥接。该处理仅在
                // 非 TL_ONLY backend 分支执行，不会污染旧 TL-only 路径。
                bridge_required |= global_cfg.svt_bridge_enable;
                bridge_required |= backend_provider.bridge_required;

                // TL requester/responder agent 只为 provider 实际拥有的
                // SVT/transport 方向创建。比如 SVT RC + DUT EP 只创建
                // RC TL agent；DUT RC + SVT EP 则只创建 EP TL agent。
                if (backend_provider.get_rc_adapter_count() != 0)
                    cfg.rc_agent_enable = 1'b1;
                else
                    cfg.rc_agent_enable = 1'b0;
                if (backend_provider.get_ep_adapter_count() != 0)
                    cfg.ep_agent_enable = 1'b1;
                else
                    cfg.ep_agent_enable = 1'b0;
            end
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
                // 同域 BDF 重复才是错误；跨 Host/segment 允许同 BDF。
                if (device_contexts.exists(
                      device_context_key(cfg.device_cfgs[i])))
                    `uvm_fatal("DEVICE_CFG", $sformatf(
                        "duplicate device BDF 0x%04h in domain h%0d.s%0d",
                        context.bdf, cfg.device_cfgs[i].domain_host_id,
                        cfg.device_cfgs[i].domain_segment_id))
                device_contexts[device_context_key(cfg.device_cfgs[i])] =
                    context;
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

        // RC agent 槽位是 provider 拥有的 transport 槽位。Switch 模式
        // 下即使所有 RC 都归外部 DUT，也保留全部物理 USP manager 槽
        // 位，但只有存在至少一个 provider RC 时才分配 RC agent。这样
        // EP→dsp_owner 的 manager 接线保持有效，又不会为 DUT root 凭
        // 空制造 RC adapter。
        if (cfg.switch_enable && (cfg.switch_cfg != null)) begin
            nu = cfg.rc_agent_enable ? cfg.switch_cfg.num_usp : 0;
            n_mgr = (cfg.switch_cfg.num_usp > 0) ? cfg.switch_cfg.num_usp : 1;
        end
        else begin
            nu = cfg.rc_agent_enable ? cfg.num_rc : 0;
            // 混合 provider 直连拓扑激活时，EP 槽位可能映射到不同的外
            // 部 RC root。即使没有任何 RC adapter 归 provider，也按物理
            // root 各保留一个 manager；provider 一个不占时只抑制 RC
            // agent/adapter 数组。
            if (backend_provider_active)
                n_mgr = (cfg.num_rc > 0) ? cfg.num_rc : 1;
            else
                n_mgr = (nu > 0) ? nu : 1;
        end
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
            string slot_id;
            string map_error;
            bit provider_owned;

            if (backend_provider_active) begin
                // 严格 provider 模式先解析物理槽位。null 结果只在对端/
                // DUT 一侧才是刻意的；这里不允许任何位置或 factory
                // 回退。
                if (!resolve_provider_slot(PCIE_DEVICE_RC, r, slot_id,
                                            rc_adapters[r], provider_owned,
                                            map_error)) begin
                    `uvm_fatal("BACKEND_MAP", map_error)
                    return;
                end
            end
            else begin
                // 历史 TL-only 路径：保留 config-db 注入与历史的
                // factory 默认 adapter 创建。
                if (!uvm_config_db#(pcie_tl_if_adapter)::get(
                      this, "", $sformatf("pcie_svt_bridge_rc_adapter_%0d", r),
                      rc_adapters[r])) begin
                    rc_adapters[r] = pcie_tl_if_adapter::type_id::create(
                        $sformatf("rc_adapter_%0d", r), this);
                end
            end
        end
        // Aliases -> [0] (managers always exist; rc_adapter only when a root exists)
        tag_mgr    = tag_mgrs[0];
        fc_mgr     = fc_mgrs[0];
        ord_eng    = ord_engs[0];
        cfg_mgr    = cfg_mgrs[0];
        rc_adapter = null;
        foreach (rc_adapters[r]) begin
            if (rc_adapters[r] != null) begin
                rc_adapter = rc_adapters[r];
                break;
            end
        end

        // 3. Single EP adapter for the direct-mode / switch-dangling path.
        //    Non-switch multi-EP builds its own ep_adapters[] in block 4a instead;
        //    a no-EP (RC-only) env creates none (all EP derefs are guarded).
        if ((!backend_provider_active && cfg.switch_enable) ||
            (!cfg.switch_enable && cfg.ep_agent_enable && !ns_multi_ep))
            begin
                string slot_id;
                string map_error;
                bit provider_owned;

                ep_adapter = null;
                if (backend_provider_active) begin
                    if (!resolve_provider_slot(PCIE_DEVICE_EP, 0, slot_id,
                                                ep_adapter, provider_owned,
                                                map_error)) begin
                        `uvm_fatal("BACKEND_MAP", map_error)
                        return;
                    end
                end
                else if (!uvm_config_db#(pcie_tl_if_adapter)::get(
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
                if (backend_provider_active && (rc_adapters[r] == null)) begin
                    // 物理 RC 槽位属于外部 DUT（provider 拥有对端）。
                    // 槽位留在按拓扑定长的数组里，但不创建 TL agent。
                    if (strict_slot_provider_owned(PCIE_DEVICE_RC, r)) begin
                        `uvm_fatal("BACKEND_MAP", $sformatf(
                            "provider-owned RC slot %0d has no adapter", r))
                        return;
                    end
                    continue;
                end
                uvm_config_db#(uvm_active_passive_enum)::set(
                    this, $sformatf("rc_agent_%0d", r), "is_active", cfg.rc_is_active);
                rc_agents[r] = pcie_tl_rc_agent::type_id::create(
                    $sformatf("rc_agent_%0d", r), this);
            end
            rc_agent = null;
            foreach (rc_agents[r]) begin
                if (rc_agents[r] != null) begin
                    rc_agent = rc_agents[r];
                    break;
                end
            end
        end

        // 4a. EP agents. Non-switch multi-EP -> independent ep_agent_%0d links
        //     (aliases -> [0]); otherwise the single direct-mode ep_agent (main path,
        //     also the switch-mode dangling agent). Switch ports are built in 4b.
        if (ns_multi_ep) begin
            ep_agents   = new[cfg.num_ep];
            ep_adapters = new[cfg.num_ep];
            for (int i = 0; i < cfg.num_ep; i++) begin
                if (backend_provider_active) begin
                    string slot_id;
                    string map_error;
                    bit provider_owned;

                    if (!resolve_provider_slot(PCIE_DEVICE_EP, i, slot_id,
                                                ep_adapters[i], provider_owned,
                                                map_error)) begin
                        `uvm_fatal("BACKEND_MAP", map_error)
                        return;
                    end
                    if (!provider_owned) begin
                        // 刻意保留的外部 DUT 物理槽位。
                        ep_agents[i] = null;
                        continue;
                    end
                end
                uvm_config_db#(uvm_active_passive_enum)::set(
                    this, $sformatf("ep_agent_%0d", i), "is_active", cfg.ep_is_active);
                ep_agents[i]   = pcie_tl_ep_agent::type_id::create(
                    $sformatf("ep_agent_%0d", i), this);
                if (!backend_provider_active &&
                    !uvm_config_db#(pcie_tl_if_adapter)::get(
                      this, "", $sformatf("pcie_svt_bridge_ep_adapter_%0d", i),
                      ep_adapters[i])) begin
                    ep_adapters[i] = pcie_tl_if_adapter::type_id::create(
                        $sformatf("ep_adapter_%0d", i), this);
                end
            end
            ep_agent = null;
            ep_adapter = null;
            foreach (ep_agents[i]) begin
                if (ep_agents[i] != null) begin
                    ep_agent = ep_agents[i];
                    ep_adapter = ep_adapters[i];
                    break;
                end
            end
        end else if (cfg.ep_agent_enable &&
                     (!cfg.switch_enable || !backend_provider_active)) begin
            // 严格 provider 模式下 cfg.ep_agent_enable 隐含存在 provider
            // 拥有的 EP 槽位，因此先解析标量 adapter 再创建 agent；
            // 历史模式沿用原 factory 路径。
            if (backend_provider_active && (ep_adapter == null)) begin
                `uvm_fatal("BACKEND_MAP",
                           "EP agent enabled but no provider adapter resolved")
                return;
            end
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
                if (backend_provider_active) begin
                    string slot_id;
                    string map_error;
                    bit provider_owned;

                    if (!resolve_provider_slot(PCIE_DEVICE_EP, i, slot_id,
                                                ep_adapters[i], provider_owned,
                                                map_error)) begin
                        `uvm_fatal("BACKEND_MAP", map_error)
                        return;
                    end
                    if (!provider_owned) begin
                        // 真实 Switch/DUT 下游端口由保留的 null 槽位表
                        // 示；不得给它挂接合成的 TL EP agent。
                        ep_agents[i] = null;
                        continue;
                    end
                end
                uvm_config_db#(uvm_active_passive_enum)::set(
                    this, $sformatf("ep_agent_%0d", i), "is_active", cfg.ep_is_active);
                ep_agents[i]  = pcie_tl_ep_agent::type_id::create(
                    $sformatf("ep_agent_%0d", i), this);
                if (!backend_provider_active &&
                    !uvm_config_db#(pcie_tl_if_adapter)::get(
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
            if (rc_agents[r] == null) begin
                if (backend_provider_active &&
                    strict_slot_provider_owned(PCIE_DEVICE_RC, r))
                    `uvm_fatal("BACKEND_MAP", $sformatf(
                        "provider-owned RC slot %0d has no TL agent", r))
                continue;
            end
            if ((r >= rc_adapters.size()) || (rc_adapters[r] == null)) begin
                `uvm_fatal("ENV", $sformatf(
                    "RC%0d has no adapter during connect", r))
                continue;
            end
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
                int mi;

                if (ep_agents[i] == null) begin
                    if (backend_provider_active &&
                        strict_slot_provider_owned(PCIE_DEVICE_EP, i))
                        `uvm_fatal("BACKEND_MAP", $sformatf(
                            "provider-owned EP slot %0d has no TL agent", i))
                    continue;
                end
                mi = configured_ep_root_index(i, i);
                if ((mi < 0) || (mi >= fc_mgrs.size()))
                    `uvm_fatal("ROOT_MAP", $sformatf(
                        "EP%0d maps to invalid Root%0d (Root count=%0d)",
                        i, mi, fc_mgrs.size()))
                if ((i >= ep_adapters.size()) || (ep_adapters[i] == null)) begin
                    `uvm_fatal("ENV", $sformatf(
                        "EP%0d has no adapter during connect", i))
                    continue;
                end
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
            if (ep_adapter == null) begin
                `uvm_fatal("ENV", "EP agent has no adapter during connect")
                return;
            end
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
            if (rc_adapters[r] == null) begin
                if (!backend_provider_active ||
                    strict_slot_provider_owned(PCIE_DEVICE_RC, r))
                    `uvm_fatal("ENV", $sformatf(
                        "RC adapter %0d is null during connect", r))
                continue;
            end
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
        v_seqr.rc_seqr = null;
        foreach (rc_agents[r]) begin
            if (rc_agents[r] != null) begin
                v_seqr.rc_seqr = rc_agents[r].sequencer;
                break;
            end
        end

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
            v_seqr.ep_seqr = null;
            foreach (ep_agents[i]) begin
                if (ep_agents[i] != null) begin
                    v_seqr.ep_seqr = ep_agents[i].sequencer;
                    break;
                end
            end
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
                int mapped_owner;
                if ((i >= sw.dsp.size()) || (sw.dsp[i] == null)) begin
                    `uvm_fatal("SWITCH", $sformatf(
                        "Switch DSP%0d is missing its native port", i))
                    continue;
                end
                if ((i >= ep_agents.size()) || (ep_agents[i] == null) ||
                    (i >= ep_adapters.size()) || (ep_adapters[i] == null)) begin
                    if (backend_provider_active &&
                        !strict_slot_provider_owned(PCIE_DEVICE_EP, i))
                        continue;
                    `uvm_fatal("SWITCH", $sformatf(
                        "Switch DSP%0d missing provider EP agent/adapter", i))
                    continue;
                end
                mapped_owner = configured_ep_root_index(i, owner);
                if (mapped_owner != owner)
                    `uvm_fatal("ROOT_MAP", $sformatf(
                        "Switch DSP%0d maps to Root%0d but dsp_owner requires Root%0d",
                        i, mapped_owner, owner))
                owner = mapped_owner;
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
                // 保留 apply_config() 做出的外部 transport 决定。Switch
                // 专用接线阶段不得把 SVT/Serial adapter 降级回
                // TLM_MODE。
                ep_adapters[i].mode   = bridge_required ? SV_IF_MODE : cfg.if_mode;
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

        // 10. Unified-memory distribution.  DPU-aware multi-Root callers must
        // bind every Root explicitly in cfg.host_mem_by_root.  Only the legacy
        // single-Root path may obtain host_mem from config-db.
        if (cfg.use_unified_mem) begin
            int nep;
            string memory_errors[$];
            // Track handles rather than Host IDs: two independent managers may
            // legally expose the same logical ID in a test, while one shared
            // manager can be referenced by several Roots.  PREMAP must allocate
            // once per object identity, not once per array slot.
            host_mem_api premap_managers[$];
            nep = (cfg.switch_enable && cfg.switch_cfg != null)
                  ? cfg.switch_cfg.num_ds_ports
                  : (cfg.ep_agent_enable ? cfg.num_ep : 0);

            void'(cfg.validate_host_memory_bindings(rc_agents.size(),
                                                     memory_errors));
            foreach (memory_errors[index])
                `uvm_fatal("HOST_MEM_BIND", memory_errors[index])

            host_mem_by_root = new[rc_agents.size()];
            for (int unsigned root = 0; root < rc_agents.size(); root++) begin
                host_mem_api manager;

                // Explicit bindings take precedence.  A single Root remains
                // compatible with the historic config-db injection contract.
                if (cfg.host_mem_by_root.exists(root)) begin
                    manager = cfg.host_mem_by_root[root];
                end else if ((rc_agents.size() == 1) &&
                             uvm_config_db#(host_mem_api)::get(
                               this, "", "host_mem", manager)) begin
                    // legacy fallback
                end else begin
                    manager = null;
                end
                host_mem_by_root[root] = manager;

                if (manager == null) begin
                    if (rc_agents[root] != null)
                        `uvm_fatal("HOST_MEM_BIND", $sformatf(
                          "RC Root%0d has no Host memory manager", root))
                    continue;
                end
                if (manager.get_host_id() !=
                    ((cfg.host_mem_by_root.exists(root)) ?
                     cfg.host_id_by_root[root] : manager.get_host_id()))
                    `uvm_fatal("HOST_MEM_BIND", $sformatf(
                      "RC Root%0d Host memory manager ID mismatch", root))

                // An already initialized shared manager belongs to another
                // subsystem and must not be reset or reinitialized here.
                if (!manager.is_initialized()) begin
                    manager.init_region(64'h0, 64'hFFFF_FFFF,
                                        cfg.mem_alloc_mode, cfg.mem_granule);
                end
                if (!manager.is_initialized())
                    `uvm_fatal("HOST_MEM_BIND", $sformatf(
                      "RC Root%0d Host memory manager initialization failed",
                      root))
                if (cfg.mem_access_mode == PCIE_TL_MEM_PREMAP) begin
                    bit already_premapped;
                    already_premapped = 1'b0;
                    foreach (premap_managers[previous]) begin
                        if (premap_managers[previous] == manager)
                            already_premapped = 1'b1;
                    end
                    if (!already_premapped) begin
                        void'(manager.alloc(cfg.premap_size, cfg.mem_granule));
                        premap_managers.push_back(manager);
                    end
                end
                if ((rc_agents[root] != null) &&
                    (rc_agents[root].rc_driver != null))
                    rc_agents[root].rc_driver.mem = manager;
                if (root == 0)
                    host_mem = manager;
            end

            // EP[i] ← dev_mem[i]
            for (int i = 0; i < nep; i++) begin
                host_mem_api dm;
                if (uvm_config_db#(host_mem_api)::get(this, "",
                                                       $sformatf("dev_mem_%0d", i), dm)) begin
                    // EP/device memory remains independently injectable, but
                    // follows the same no-reinit and one-PREMAP-per-manager
                    // rules as RC Host memory when a caller shares a handle.
                    if (!dm.is_initialized()) begin
                        dm.init_region(64'h0, 64'hFFFF_FFFF,
                                       cfg.mem_alloc_mode, cfg.mem_granule);
                    end
                    if (!dm.is_initialized())
                        `uvm_fatal("DEV_MEM_BIND", $sformatf(
                          "EP%0d device memory manager initialization failed", i))
                    if (cfg.mem_access_mode == PCIE_TL_MEM_PREMAP) begin
                        bit already_premapped;
                        already_premapped = 1'b0;
                        foreach (premap_managers[previous]) begin
                            if (premap_managers[previous] == dm)
                                already_premapped = 1'b1;
                        end
                        if (!already_premapped) begin
                            void'(dm.alloc(cfg.premap_size, cfg.mem_granule));
                            premap_managers.push_back(dm);
                        end
                    end
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
                        if ((rr < rc_adapters.size()) &&
                            (rc_agents[rr] != null) &&
                            (rc_adapters[rr] != null)) begin
                            fork
                                rc_to_switch_loopback(rr);
                                switch_to_rc_loopback(rr);
                            join_none
                        end
                    end
                    for (int i = 0; i < cfg.switch_cfg.num_ds_ports; i++) begin
                        automatic int idx = i;
                        if ((idx < ep_agents.size()) && (ep_agents[idx] != null) &&
                            (idx < ep_adapters.size()) &&
                            (ep_adapters[idx] != null)) begin
                            fork
                                switch_to_ep_loopback(idx);
                                ep_to_switch_loopback(idx);
                            join_none
                        end
                    end
                join_none
            end else if (!cfg.switch_enable && ep_adapters.size() > 0) begin
                // Non-switch multi-agent: independent RC[i] <-> EP[i] TLM pairs
                fork
                    for (int i = 0; i < ep_adapters.size(); i++) begin
                        automatic int ii = i;
                        if (ii < rc_agents.size() && rc_agents[ii] != null &&
                            ii < rc_adapters.size() && rc_adapters[ii] != null &&
                            ep_agents[ii] != null &&
                            ii < ep_adapters.size() && ep_adapters[ii] != null) begin
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
        int total_wire_bytes, chunk, remaining_wire_bytes;
        int remaining_valid_bytes, wire_offset;
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
        total_wire_bytes      = pcie_tl_mem_dw_count(mem_req) * 4;
        remaining_wire_bytes  = total_wire_bytes;
        remaining_valid_bytes = pcie_tl_mem_valid_bytes(mem_req);
        wire_offset            = 0;
        cur_addr               = pcie_tl_mem_wire_addr(mem_req);

        while (remaining_wire_bytes > 0) begin
            int bytes_to_rcb, len_dw;
            int valid_in_chunk, first_valid;
            bit [63:0] first_valid_addr;

            // Every Completion must end at or before the next RCB boundary.
            bytes_to_rcb = rcb_bytes - (cur_addr % rcb_bytes);
            if (bytes_to_rcb == 0) bytes_to_rcb = rcb_bytes;
            chunk = mps_bytes;
            if (bytes_to_rcb < chunk) chunk = bytes_to_rcb;
            if (chunk > remaining_wire_bytes) chunk = remaining_wire_bytes;
            chunk = (chunk / 4) * 4;
            if (chunk == 0) chunk = remaining_wire_bytes;
            len_dw            = chunk / 4;
            valid_in_chunk    = pcie_tl_mem_valid_bytes_in_range(
                mem_req, wire_offset, chunk);
            first_valid       = pcie_tl_mem_first_valid_in_range(
                mem_req, wire_offset, chunk);
            first_valid_addr  = cur_addr + first_valid;

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
            cpl.byte_count   = remaining_valid_bytes[11:0];
            cpl.lower_addr   = first_valid_addr[6:0];
            cpl.payload      = new[chunk];
            foreach (cpl.payload[i]) begin
                // 历史 responder 没有后备 manager。使能 lane 保持历史的
                // AA 图案，禁用 lane 保持 wire 上可见的零值。
                cpl.payload[i] = pcie_tl_mem_lane_enabled(
                    mem_req, wire_offset + i) ? 8'hAA : 8'h00;
            end

            // Observation only: legacy completions deliberately bypass the
            // adapter/monitor transport, so publish before the direct
            // scoreboard write without changing functional behavior.
            legacy_rc_cpl_ap.write(cpl);

            // Preserve legacy observation-before-scoreboard ordering, then
            // use the requesting EP driver's normal read-back foldback path.
            if (scbs.size() > root_index && scbs[root_index] != null)
                scbs[root_index].write_ep(cpl);
            resolved_requester_driver.handle_completion(cpl);

            cur_addr              += chunk;
            wire_offset           += chunk;
            remaining_wire_bytes  -= chunk;
            remaining_valid_bytes -= valid_in_chunk;
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
            if (rc_adapters[r] != null) begin
                // SVT forward 模式必须保持 SV_IF_MODE，monitor 才会把外部
                // Completion 交回 RC driver；普通 TL-only 仍沿用 cfg.if_mode。
                rc_adapters[r].mode = bridge_required ? SV_IF_MODE : cfg.if_mode;
                if (bridge_required && (rc_adapters[r].vif == null))
                    `uvm_info("ENV_BRIDGE_DIAG", $sformatf(
                        "%s RC adapter %0d entered SV_IF_MODE without vif",
                        get_full_name(), r), UVM_NONE)
            end
        end
        if (ep_adapter != null) begin
            ep_adapter.mode = bridge_required ? SV_IF_MODE : cfg.if_mode;
            if (bridge_required && (ep_adapter.vif == null))
                `uvm_info("ENV_BRIDGE_DIAG", $sformatf(
                    "%s scalar EP adapter entered SV_IF_MODE without vif",
                    get_full_name()), UVM_NONE)
        end
        foreach (ep_adapters[i]) begin
            if (ep_adapters[i] != null) begin
                ep_adapters[i].mode = bridge_required ? SV_IF_MODE : cfg.if_mode;
                if (bridge_required && (ep_adapters[i].vif == null))
                    `uvm_info("ENV_BRIDGE_DIAG", $sformatf(
                        "%s EP adapter %0d entered SV_IF_MODE without vif",
                        get_full_name(), i), UVM_NONE)
            end
        end

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
