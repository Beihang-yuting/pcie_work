/*
 * 所属层次：pcie_tl_vip/src/env；PCIe TL 环境的原生配置对象。
 * 文件职责：保存拓扑输入、组件行为策略及借用的 Host 内存绑定；由环境在 build/connect 使用。
 * 主要依赖：pcie_tl_pkg 中的 UVM、PCIe 类型、Host 内存和设备配置；AIP 为可选编译依赖。
 * 所有权与生命周期：调用方创建并持有本对象，环境借用；Host 内存和 device/switch 句柄不转移所有权。
 * 参数加载只由调用方在环境 build 前显式执行，不创建/替换绑定对象，不进行运行期重建。
 */

typedef enum bit { PCIE_TL_MEM_PER_BUFFER = 1'b0, PCIE_TL_MEM_PREMAP = 1'b1 } pcie_tl_mem_access_mode_e;

// 将行为参数留在原生配置类中，避免测试层镜像字段与生产消费点漂移。
// load_params 仅覆盖已有消费点的行为字段；拓扑、角色、设备身份和内存所有权继续由调用方配置。
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

`ifdef AIP_CMDLINE_SV
    // 功能：检查获胜的整数输入原文，不抽样、不推进时间。
    // AIP 旧标量路径允许有符号数转无符号；必须在任何窄化前拒绝负数字面量，
    // 包括 -(2^64-1) 等可能回绕成小正数的输入。整数语法的减号只表示负值。
    // real 不经过此函数，保证合法负指数（例如 1e-3）仍然可用。
    local function void check_nonnegative_input(string	path, string	field_name);
        string	raw;

        raw = aip_cmdline#(int unsigned)::get_cmdline_string(field_name, path);
        if (aip_str::str_find(raw, "-") >= 0)
            $fatal(1, "PCIE_CFG_PARAMS: %s.%s requires a nonnegative integer: %s",
                   path, field_name, raw);
    endfunction

    // 功能：按 1 bit 类型读取布尔字段；所有候选的格式/位宽由 AIP 校验，禁止 2 截断为 0。
    // 当前值是缺省值，原文检查不消费 RNG，get_single_value 是唯一一次抽样。
    local function bit load_bool_param(string	path, string	field_name, bit	current);
        bit	value;

        check_nonnegative_input(path, field_name);
        aip_cmdline#(bit)::get_single_value(field_name, path, current, value, `__FILE__, `__LINE__);
        return value;
    endfunction

    // 功能：加载非负 int 行为字段；先按完整 32 bit 无符号值解析，再验证有符号 int 的范围。
    // 输入 lower_bound 为业务最小值；越界立即终止，不先截断再判断，不静默修正配置。
    local function int load_int_param(string	path, string	field_name,
                                      int	current, int	lower_bound = 0);
        int unsigned	value;

        check_nonnegative_input(path, field_name);
        aip_cmdline#(int unsigned)::get_single_value(field_name, path,
            current, value, `__FILE__, `__LINE__);
        if ((value > 32'h7fff_ffff) || (value < lower_bound))
            $fatal(1, "PCIE_CFG_PARAMS: %s.%s must be in [%0d,2147483647], got %0d",
                   path, field_name, lower_bound, value);
        return int'(value);
    endfunction
`endif

    // 功能：显式加载本配置的行为参数，默认根路径 pcie_cfg；允许调用方传入任意路径。
    // 当前字段值作为缺省值；只读取真实生产消费字段，不加载拓扑/角色/接口模式、
    // SR-IOV/BDF/BAR、内存分配策略/对象绑定、switch/device_cfgs 或尚未接通的字段。
    // AIP 只按 AIP_CMDLINE_SV 可选启用；未编译时整个函数为空操作，构造函数不自动调用。
    // 必须在环境 build 前调用：此函数不向已创建组件 apply，不承诺运行期重配置。
    // 每字段仅求值一次，重复调用表示显式重新抽样；调用方负责避免重复加载同一对象。
    // 非法类型/范围或跨字段组合立即 fatal；环境后续的历史 TAG_BIT plusarg 仍保留原优先级。
    function void load_params(string	path = "pcie_cfg");
`ifdef AIP_CMDLINE_SV
        bit [63:0]	rate_bits;

        // FC 的六类初始 credit 允许为零，保留无 credit 的背压测试能力。
        fc_enable        = load_bool_param(path, "fc_enable", fc_enable);
        infinite_credit  = load_bool_param(path, "infinite_credit", infinite_credit);
        init_ph_credit   = load_int_param(path, "init_ph_credit", init_ph_credit);
        init_pd_credit   = load_int_param(path, "init_pd_credit", init_pd_credit);
        init_nph_credit  = load_int_param(path, "init_nph_credit", init_nph_credit);
        init_npd_credit  = load_int_param(path, "init_npd_credit", init_npd_credit);
        init_cplh_credit = load_int_param(path, "init_cplh_credit", init_cplh_credit);
        init_cpld_credit = load_int_param(path, "init_cpld_credit", init_cpld_credit);

        // avg_rate 单位沿用 shaper 的 bytes/ns；使用 real 专用 API，不以整数路径解析。
        shaper_enable = load_bool_param(path, "shaper_enable", shaper_enable);
        aip_cmdline_real::get_single_value("avg_rate", path, avg_rate, avg_rate, `__FILE__, `__LINE__);
        rate_bits = $realtobits(avg_rate);
        if ((rate_bits[62:52] == 11'h7ff) || (avg_rate < 0.0))
            $fatal(1, "PCIE_CFG_PARAMS: %s.avg_rate must be finite and nonnegative", path);
        burst_size = load_int_param(path, "burst_size", burst_size, 1);
        if (shaper_enable && !(avg_rate > 0.0))
            $fatal(1, "PCIE_CFG_PARAMS: %s.avg_rate must be positive when shaper_enable=1", path);

        // Tag pool 的现有实现使用 8/10 bit Tag，加载后的 outstanding 不能超过实际池容量。
        extended_tag_enable = load_bool_param(path, "extended_tag_enable", extended_tag_enable);
        phantom_func_enable = load_bool_param(path, "phantom_func_enable", phantom_func_enable);
        max_outstanding     = load_int_param(path, "max_outstanding", max_outstanding, 1);
        if (max_outstanding > (extended_tag_enable ? 1024 : 256))
            $fatal(1, "PCIE_CFG_PARAMS: %s.max_outstanding exceeds %0d-bit Tag capacity",
                   path, extended_tag_enable ? 10 : 8);

        // 使用原有枚举名解析，所有候选必须是合法成员；不接受裸数值强制转换。
        `aip_enum(path, mps_e, max_payload_size, max_payload_size)
        `aip_enum(path, mrrs_e, max_read_request_size, max_read_request_size)
        `aip_enum(path, rcb_e, read_completion_boundary, read_completion_boundary)
        if ((max_payload_size.name() == "") || (max_read_request_size.name() == "") ||
            (read_completion_boundary.name() == ""))
            $fatal(1, "PCIE_CFG_PARAMS: %s contains an invalid MPS/MRRS/RCB enum", path);

        // 排序、覆盖率和 scoreboard 字段由环境原有 apply_config/build 消费。
        relaxed_ordering_enable  = load_bool_param(path, "relaxed_ordering_enable", relaxed_ordering_enable);
        id_based_ordering_enable = load_bool_param(path, "id_based_ordering_enable", id_based_ordering_enable);
        bypass_ordering          = load_bool_param(path, "bypass_ordering", bypass_ordering);
        cov_enable               = load_bool_param(path, "cov_enable", cov_enable);
        tlp_basic_cov            = load_bool_param(path, "tlp_basic_cov", tlp_basic_cov);
        fc_state_cov             = load_bool_param(path, "fc_state_cov", fc_state_cov);
        tag_usage_cov            = load_bool_param(path, "tag_usage_cov", tag_usage_cov);
        ordering_cov             = load_bool_param(path, "ordering_cov", ordering_cov);
        error_inject_cov         = load_bool_param(path, "error_inject_cov", error_inject_cov);
        scb_enable               = load_bool_param(path, "scb_enable", scb_enable);
        ordering_check_enable    = load_bool_param(path, "ordering_check_enable", ordering_check_enable);
        completion_check_enable  = load_bool_param(path, "completion_check_enable", completion_check_enable);
        data_integrity_enable    = load_bool_param(path, "data_integrity_enable", data_integrity_enable);
        scb_strict_check         = load_bool_param(path, "scb_strict_check", scb_strict_check);

        // EP 是否自动应答由原生环境消费；REAL_DUT 等上层执行模式仍须检查自己的契约。
        // response_delay_min/max 尚未从 cfg 传入 EP driver，因此刻意不作为公开参数。
        ep_auto_response = load_bool_param(path, "ep_auto_response", ep_auto_response);
        cpl_timeout_ns   = load_int_param(path, "cpl_timeout_ns", cpl_timeout_ns, 1);

        // 双向链路允许零延迟，更新间隔必须为正；先读齐参数再检查每一方向的范围。
        link_delay_enable          = load_bool_param(path, "link_delay_enable", link_delay_enable);
        rc2ep_latency_min_ns       = load_int_param(path, "rc2ep_latency_min_ns", rc2ep_latency_min_ns);
        rc2ep_latency_max_ns       = load_int_param(path, "rc2ep_latency_max_ns", rc2ep_latency_max_ns);
        ep2rc_latency_min_ns       = load_int_param(path, "ep2rc_latency_min_ns", ep2rc_latency_min_ns);
        ep2rc_latency_max_ns       = load_int_param(path, "ep2rc_latency_max_ns", ep2rc_latency_max_ns);
        link_delay_update_interval = load_int_param(path, "link_delay_update_interval",
                                                   link_delay_update_interval, 1);
        if (rc2ep_latency_min_ns > rc2ep_latency_max_ns)
            $fatal(1, "PCIE_CFG_PARAMS: %s.rc2ep_latency_min_ns exceeds rc2ep_latency_max_ns", path);
        if (ep2rc_latency_min_ns > ep2rc_latency_max_ns)
            $fatal(1, "PCIE_CFG_PARAMS: %s.ep2rc_latency_min_ns exceeds ep2rc_latency_max_ns", path);
`endif
    endfunction

    // 功能：将一个逻辑 Host 内存管理器借用到物理 Root，不改变其所有权或创建副本。
    // 输入 Root/Host 身份及现有 manager；失败时返回 0 和 why，空句柄、Host 身份不符
    // 或重复 Root 均拒绝；成功后同 Host 的使用者继续共享同一 manager。
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

    // 功能：验证启用统一内存后的 Root 绑定基数及 Host 身份，输出全部错误，不修改对象。
    // 多 Root 必须逐一显式绑定；单 Root 无显式映射时允许环境沿用历史 host_mem 回退。
    // 只要提供了显式映射，数量就必须等于实际 Root 数，避免单 Root 静默忽略多余绑定。
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

    // 功能：仅设置 UVM 对象名并保留字段缺省值；不读取参数、不创建绑定资源。
    function new(string	name = "pcie_tl_env_config");
        super.new(name);
    endfunction

endclass
