//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Environment Configuration
//-----------------------------------------------------------------------------

typedef enum bit { PCIE_TL_MEM_PER_BUFFER = 1'b0, PCIE_TL_MEM_PREMAP = 1'b1 } pcie_tl_mem_access_mode_e;

class pcie_tl_env_config extends uvm_object;
    `uvm_object_utils(pcie_tl_env_config)

    //--- Role ---
    bit                       rc_agent_enable  = 1;
    bit                       ep_agent_enable  = 1;
    uvm_active_passive_enum   rc_is_active     = UVM_ACTIVE;
    uvm_active_passive_enum   ep_is_active     = UVM_ACTIVE;

    //--- Non-switch multi-agent: independent RC/EP links, each its own 4-channel
    //    adapter. Default 1/1 -> identical to legacy 1RC+1EP. In switch mode the
    //    RC count comes from switch_cfg.num_usp and EP from num_ds_ports instead
    //    (num_rc/num_ep are ignored under switch_enable). ---
    int                       num_rc           = 1;
    int                       num_ep           = 1;

    // Optional backend-neutral device images.  Empty preserves all legacy
    // behavior; populated arrays are translated into independent TL contexts.
    pcie_device_cfg            device_cfgs[$];

    //--- Interface mode ---
    pcie_tl_if_mode_e         if_mode          = TLM_MODE;

    //--- FC ---
    bit                       fc_enable        = 1;
    bit                       infinite_credit  = 0;
    int                       init_ph_credit   = 32;
    int                       init_pd_credit   = 256;
    int                       init_nph_credit  = 32;
    int                       init_npd_credit  = 256;
    int                       init_cplh_credit = 32;
    int                       init_cpld_credit = 256;

    //--- Bandwidth shaper ---
    bit                       shaper_enable    = 0;
    real                      avg_rate         = 0.0;
    int                       burst_size       = 4096;

    //--- Tag ---
    bit                       extended_tag_enable  = 1;
    bit                       phantom_func_enable  = 0;
    int                       max_outstanding      = 1024;

    //--- PCIe Capability parameters ---
    mps_e                     max_payload_size         = MPS_256;
    mrrs_e                    max_read_request_size    = MRRS_512;
    rcb_e                     read_completion_boundary = RCB_64;
    bit                       no_snoop_enable          = 0;

    //--- Ordering ---
    bit                       relaxed_ordering_enable    = 1;
    bit                       id_based_ordering_enable   = 1;
    bit                       bypass_ordering            = 0;

    //--- Coverage (all default OFF) ---
    bit                       cov_enable          = 0;
    bit                       tlp_basic_cov       = 0;
    bit                       fc_state_cov        = 0;
    bit                       tag_usage_cov       = 0;
    bit                       ordering_cov        = 0;
    bit                       error_inject_cov    = 0;

    //--- Scoreboard ---
    bit                       scb_enable              = 1;
    bit                       ordering_check_enable   = 1;
    bit                       completion_check_enable = 1;
    bit                       data_integrity_enable   = 1;
    bit                       scb_strict_check        = 1;  // 0: injected-error tests (stress) downgrade SCB FAIL->warn

    //--- EP auto-response ---
    bit                       ep_auto_response   = 1;
    int                       response_delay_min = 0;
    int                       response_delay_max = 10;

    //--- Completion Timeout ---
    int                       cpl_timeout_ns     = 50000;

    //--- Link Delay ---
    bit                       link_delay_enable              = 0;
    int                       rc2ep_latency_min_ns           = 0;
    int                       rc2ep_latency_max_ns           = 0;
    int                       ep2rc_latency_min_ns           = 0;
    int                       ep2rc_latency_max_ns           = 0;
    int                       link_delay_update_interval     = 16;

    //--- Switch ---
    bit                    switch_enable = 0;
    pcie_tl_switch_config  switch_cfg;

    //--- SR-IOV / Function ---
    bit              sriov_enable         = 0;
    int              num_pfs              = 1;
    int              max_vfs_per_pf       = 256;
    int              default_num_vfs      = 0;
    bit [15:0]       pf_vendor_id         = 16'hABCD;
    bit [15:0]       pf_device_id         = 16'h1234;
    bit [15:0]       vf_device_id         = 16'h1235;
    bit              ari_enable           = 0;

    //--- TLP Prefix ---
    bit              prefix_enable        = 0;
    bit              pasid_enable         = 0;
    int              pasid_width          = 20;
    bit              pasid_exe_supported  = 0;
    bit              pasid_priv_supported = 0;
    bit              ext_tph_enable       = 0;
    bit              ide_enable           = 0;
    bit              mriov_enable         = 0;
    int              max_e2e_prefix       = 4;

    //--- Unified Memory (default OFF — no behavior change) ---
    bit                          use_unified_mem  = 1'b0;
    pcie_tl_mem_access_mode_e    mem_access_mode  = PCIE_TL_MEM_PER_BUFFER;
    bit [63:0]                   premap_base      = 64'h0;
    int unsigned                 premap_size      = 32'h0100_0000; // 16MB
    alloc_mode_e                 mem_alloc_mode   = MODE_BUDDY;     // from host_mem_pkg
    int unsigned                 mem_granule      = 16;

    // Root-specific Host memory bindings are owned by the caller (for example
    // dpu-common/pcie_work).  A dynamic array is used so the configuration can
    // describe exactly the active RC count without allocating a fixed maximum.
    host_mem_api                 host_mem_by_root[int unsigned];
    int unsigned                 host_id_by_root[int unsigned];

    // Endpoint 到物理 Root 的显式映射。默认为空时保持历史行为：
    // EP[i] 使用 Root[i]（超出 Root 数量时回退 Root0）。DPU 适配层在
    // topology/link 顺序与 DPU 声明顺序不一致时填充此表。
    int unsigned                 ep_root_by_index[int unsigned];

    // Bind one logical Host memory manager to one physical PCIe Root.  The
    // manager is shared by all users of that Host; pcie_tl_env never replaces
    // it with an implicit private manager in a multi-Root configuration.
    function bit bind_host_memory(
        int unsigned root_index,
        int unsigned host_id,
        host_mem_api mem,
        output string why);
        why = "";
        if (mem == null) begin
            why = $sformatf("Root%0d Host%0d memory manager is null",
                           root_index, host_id);
            return 1'b0;
        end
        if (mem.get_host_id() != host_id) begin
            why = $sformatf(
                "Root%0d binding requested Host%0d but manager reports Host%0d",
                root_index, host_id, mem.get_host_id());
            return 1'b0;
        end
        if (host_mem_by_root.exists(root_index)) begin
            why = $sformatf("Root%0d Host memory is already bound", root_index);
            return 1'b0;
        end
        host_mem_by_root[root_index] = mem;
        host_id_by_root[root_index] = host_id;
        return 1'b1;
    endfunction

    // 记录一个 Endpoint agent 到 Root 的绑定，防止同一 agent 被重复
    // 指向不同 Root。Root 范围检查在环境已知实际 Root 数量后完成。
    function bit bind_ep_root(
        int unsigned ep_index,
        int unsigned root_index,
        output string why);
        why = "";
        if (ep_root_by_index.exists(ep_index)) begin
            why = $sformatf("EP%0d Root mapping is already bound", ep_index);
            return 1'b0;
        end
        ep_root_by_index[ep_index] = root_index;
        return 1'b1;
    endfunction

    // 查询 Endpoint 的 Root。显式映射优先；直接使用 pcie_tl_env、未经过
    // topology adapter 的旧测试仍可从 device_cfgs 中读取 root_index 元数据。
    function int configured_ep_root_index(
        int ep_index,
        int fallback_root);
        int ordinal;

        if (ep_root_by_index.exists(ep_index))
            return int'(ep_root_by_index[ep_index]);

        ordinal = 0;
        foreach (device_cfgs[i]) begin
            if ((device_cfgs[i] != null) &&
                (device_cfgs[i].role == PCIE_DEVICE_EP)) begin
                if (ordinal == ep_index) begin
                    if (device_cfgs[i].root_index_valid)
                        return int'(device_cfgs[i].root_index);
                    return fallback_root;
                end
                ordinal++;
            end
        end
        return fallback_root;
    endfunction

    // Multi-Root mode requires one explicit binding per active Root.  Single
    // Root mode may use the legacy config-db host_mem fallback in the env when
    // no explicit binding is supplied.  If the caller supplies any explicit
    // map, however, its cardinality must still equal the active Root count;
    // this prevents a stray Root1 entry from being silently ignored in a
    // single-Root test.
    function bit validate_host_memory_bindings(
        int unsigned root_count,
        output string errors[$]);
        errors.delete();
        if (!use_unified_mem)
            return 1'b1;
        if ((host_mem_by_root.num() != 0) &&
            (host_mem_by_root.num() != root_count))
            errors.push_back($sformatf(
                "unified Host binding count must equal Root count %0d, got %0d",
                root_count, host_mem_by_root.num()));
        if (root_count > 1) begin
            for (int unsigned root = 0; root < root_count; root++) begin
                if (!host_mem_by_root.exists(root))
                    errors.push_back($sformatf(
                        "unified multi-Root mode is missing Root%0d Host binding",
                        root));
            end
        end
        foreach (host_mem_by_root[root]) begin
            if (host_mem_by_root[root] == null) begin
                errors.push_back($sformatf(
                    "Root%0d Host memory manager is null", root));
            end else if (!host_id_by_root.exists(root)) begin
                errors.push_back($sformatf(
                    "Root%0d binding has no declared Host ID", root));
            end else if (host_mem_by_root[root].get_host_id() !=
                         host_id_by_root[root]) begin
                errors.push_back($sformatf(
                    "Root%0d manager Host ID %0d does not match declared Host%0d",
                    root, host_mem_by_root[root].get_host_id(),
                    host_id_by_root[root]));
            end
        end
        return errors.size() == 0;
    endfunction

    function new(string name = "pcie_tl_env_config");
        super.new(name);
    endfunction

endclass
