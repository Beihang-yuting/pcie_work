//------------------------------------------------------------------------------
// svt_pcie_integration/uvm/adapter：SVT backend 专用配置。
//
// 该对象只存在于 SVT integration package 中。拓扑、BDF、BAR 和 Host
// binding 仍由 pcie_global_cfg / pcie_tl_env_config 管理；本对象只保存
// Synopsys SVT transport 所需的参数，避免把 vendor 类型泄漏到 TL-only
// package。
// 由 pcie_svt_adapter_pkg 包含，依赖 UVM 与项目 link/transport 类型。
// test 创建本对象并在 build 前经 config_db 发布；backend 持有句柄直到仿真
// 结束。link_override 属于本配置对象，copy 时深拷贝以隔离各条链路的策略。
//------------------------------------------------------------------------------

class pcie_svt_link_override_cfg extends uvm_object;
  // 链路覆盖以 link_id 为 key，只有 has_* 置位时才覆盖全局默认值。
  bit has_transport;
  pcie_svt_transport_e transport;

  bit has_max_gen;
  int unsigned max_gen;

  bit has_fast_link_training;
  bit fast_link_training;

  bit has_equalization;
  bit enable_equalization;

  // 链路级 EQ mode 覆盖。0 表示按该链 Gen 自动选择（不是继承全局 mode），
  // 1/2/3 对应完整 EQ / 仅 Phase 0、1 / No-EQ；has_eq_mode=1 才覆盖。
  bit has_eq_mode;
  int unsigned eq_mode;

  bit has_link_timeout;
  time link_timeout;

  `uvm_object_utils(pcie_svt_link_override_cfg)

  // 构造函数：仅透传名字，字段保持声明默认值。
  function new(string name = "pcie_svt_link_override_cfg");
    super.new(name);
  endfunction

  // 深拷贝全部 has_*/值字段；rhs 类型不符时报 fatal（配置复制失败不可
  // 继续构建 backend）。
  virtual function void do_copy(uvm_object rhs);
    pcie_svt_link_override_cfg source;

    super.do_copy(rhs);

    if (!$cast(source, rhs)) begin
      `uvm_fatal("SVT_CFG_COPY", "SVT link override 类型不匹配")
      return;
    end

    has_transport          = source.has_transport;
    transport              = source.transport;
    has_max_gen            = source.has_max_gen;
    max_gen                = source.max_gen;
    has_fast_link_training = source.has_fast_link_training;
    fast_link_training     = source.fast_link_training;
    has_equalization       = source.has_equalization;
    enable_equalization    = source.enable_equalization;
    has_eq_mode            = source.has_eq_mode;
    eq_mode                = source.eq_mode;
    has_link_timeout       = source.has_link_timeout;
    link_timeout           = source.link_timeout;
  endfunction
endclass

class pcie_svt_backend_cfg extends uvm_object;
  // --------------------------------------------------------------------------
  // Transport 与链路训练策略。
  // --------------------------------------------------------------------------
  bit enable = 1'b1;
  pcie_svt_transport_e transport = PCIE_SVT_TRANSPORT_SERIAL;
  pcie_svt_backend_mode_e backend_mode = PCIE_SVT_BACKEND_FULL_VIP;

  int unsigned default_max_gen = 4;
  // 0 表示跟随每条链路的 effective max_gen；4/5 表示显式声明
  // Device PCIe 协议版本。允许 spec=5 但最高速率仍为 Gen4，用于
  // 对齐一些 Gen5-capable DUT 在 16 GT/s 下的 No-EQ capability/TS 语义。
  // 不允许 spec 低于 max_gen，否则速率广告与 Device capability 矛盾。
  int unsigned pcie_spec_version = 0;
  // Gen4 显式直达开关；fast_link_training 保留旧配置兼容，与本字段 OR。
  // 不需要同时置 1。fast 可按 link 覆盖，但不能用 0 否定全局 direct=1。
  bit direct_gen4_enable = 1'b0;
  bit fast_link_training = 1'b0;

  // --------------------------------------------------------------------------
  // 物理层均衡（EQ）策略。
  // --------------------------------------------------------------------------
  bit enable_equalization = 1'b1;
  // 0：保留 Gen4 Full / Gen5 Bypass 的旧自动策略；1：完整 Phase 0~3；
  // 2：仅 Phase 0/1（Gen4/Gen5 均为 FULL 枚举 + phase=1）；3：No-EQ。
  // 显式 mode 不再强制直达 Gen4，该维度只由 direct/fast 请求控制。
  // 总开关关闭时仍保留旧兼容行为：忽略 mode 并清零直达。
  int unsigned eq_mode = 0;
  // 仅保留既有配置名和默认值；当前不能用此字段控制 EQ，设 0 会被
  // validate 拒绝。应使用 enable_equalization/eq_mode；它也不是 SVT
  // API 的 direct-speed-up 参数（后者由 direct/fast 请求及总开关生成）。
  bit full_equalization_required = 1'b1;

  // EQ TS1 广播值与 preset 映射表直接对应 R-2020.12 PL cfg。
  // active SVT 在 Phase 1 中发送这些值；8G/16G/32G 必须分开，
  // 因为无后缀字段只用于 8 GT/s，不会自动覆盖 16 GT/s。固定
  // 数组保留 32 lane/16 preset 的逐项配置能力；x4/x8/x16 链路只消费
  // 实际活动 lane。默认值与 VIP 原生值一致，升级 backend 不会改变
  // 既有训练行为。
  bit [5:0] lf_value[32] = '{32{6'd24}};
  bit [5:0] fs_value[32] = '{32{6'd48}};
  bit [17:0] preset_to_coefficients_mapping_table[16] =
    '{16{18'h0c900}};
  bit [5:0] lf_value_16g[32] = '{32{6'd24}};
  bit [5:0] fs_value_16g[32] = '{32{6'd48}};
  bit [17:0] preset_to_coefficients_mapping_table_16g[16] =
    '{16{18'h0c900}};
  bit [5:0] lf_value_32g[32] = '{32{6'd24}};
  bit [5:0] fs_value_32g[32] = '{32{6'd48}};
  bit [17:0] preset_to_coefficients_mapping_table_32g[16] =
    '{16{18'h0c900}};

  // Downstream Port 等待 Phase 1 完成的协议超时，单位 ns。该字段
  // 与 link_timeout 不同：后者是整体建链/transaction 预算，不能
  // 代替 Phase 1 内部超时。默认 24 us 与 R-2020.12 一致。
  int unsigned downstream_lanes_recovery_eq_phase1_timeout_ns = 24_000;

  // EQ checker 只影响 SVT 对训练序列/系数的校验与报告，不会
  // 改变 DUT 或替代 eq_mode 的 LTSSM 阶段选择。两项默认关闭与
  // R-2020.12 一致；开启 coefficients check 前必须同步配置对端
  // LF/FS/preset 期望，否则可能只是 checker 报错而非建链本身失败。
  bit enable_equalization_verification_mode = 1'b0;
  bit enable_equalization_coefficients_checks = 1'b0;

  // Data Link 接收 analysis port 的 TLP 过滤 mask：bit0/bit1 分别为
  // good/error packet。默认 2'b11 发布全部 TLP；1.png/02.png 中的
  // 数值 1 只发布 good packet。该字段不影响链路协议处理。
  int unsigned received_tlp_interface_mode = 3;

  // TL 层对端 capability 期望，用于发包约束与 monitor check。
  // remote_max_payload_size 必须与 DUT 有效 MPS 一致，不是本端
  // Driver 实际最大 payload。
  int unsigned remote_max_payload_size = 128;
  bit remote_extended_tag_field_enabled = 1'b0;

  // Driver App 约束本端主动请求大小。Target App 字段描述内建
  // Completion 分包与延迟；当前 TL-owned bridge 会拦截 Target App 的
  // 自动响应，因此 Target 字段不改变 DUT EP 的 Completion，但仍需要
  // 落到 SVT cfg 以便 checker/后续独立 SVT 模式复用。
  int unsigned driver_max_payload_size_in_bytes = 4096;
  int unsigned target_max_payload_size_in_bytes = 128;
  int unsigned target_max_read_cpl_data_size_in_bytes = 128;
  int unsigned target_min_mem_cpl_latency_ns = 0;
  int unsigned target_max_mem_cpl_latency_ns = 0;
  bit target_force_split_cpl_delay_to_0 = 1'b0;

  // --------------------------------------------------------------------------
  // SVT 配置空间与 Target App 策略。
  // --------------------------------------------------------------------------
  bit enable_shadow_cfg_lookup = 1'b0;
  bit enable_multi_endpoint_mode = 1'b0;
  bit target_app_enable = 1'b1;
  bit target_auto_response = 1'b0;

  // --------------------------------------------------------------------------
  // 超时与日志策略。
  // --------------------------------------------------------------------------
  time link_timeout = 3ms;
  time cfg_timeout = 1ms;
  time enum_timeout = 3ms;
  time traffic_timeout = 1ms;

  uvm_verbosity svt_verbosity = UVM_MEDIUM;
  bit enable_svt_monitor = 1'b0;
  bit enable_transaction_log = 1'b0;
  bit enable_symbol_log = 1'b0;
  bit enable_pl_history_log = 1'b0;
  bit enable_ctrl_skp_log = 1'b0;
  bit enable_mbi_log = 1'b0;
  bit enable_flit_transaction_log = 1'b0;

  // 日志文件名保持可配置；空字符串表示沿用 SVT 默认文件名。
  string transaction_log_filename = "";
  string symbol_log_filename = "";
  string pl_history_log_filename = "";
  string flit_transaction_log_filename = "";

  // 4RC 不能共用同一个可写日志文件。关联表以 link_id 为 key，
  // 命中时覆盖全局文件名；未命中则沿用上述全局值或 VIP 默认值。
  string transaction_log_filename_by_link[string];
  string symbol_log_filename_by_link[string];

  // 链路级覆盖优先于本对象的全局值，再由用户 hook 做最后修改。
  pcie_svt_link_override_cfg link_override[string];

  `uvm_object_utils(pcie_svt_backend_cfg)

  // 构造函数：仅透传名字，字段保持声明默认值。
  function new(string name = "pcie_svt_backend_cfg");
    super.new(name);
  endfunction

  // 把全部字段重置为声明默认值并清空链路覆盖表。用于测试或复用同一
  // 对象时回到已知状态；与声明初值保持逐字段一致。
  function void init_defaults();
    enable = 1'b1;
    transport = PCIE_SVT_TRANSPORT_SERIAL;
    backend_mode = PCIE_SVT_BACKEND_FULL_VIP;
    default_max_gen = 4;
    pcie_spec_version = 0;
    direct_gen4_enable = 1'b0;
    fast_link_training = 1'b0;
    enable_equalization = 1'b1;
    eq_mode = 0;
    full_equalization_required = 1'b1;
    lf_value = '{32{6'd24}};
    fs_value = '{32{6'd48}};
    preset_to_coefficients_mapping_table = '{16{18'h0c900}};
    lf_value_16g = '{32{6'd24}};
    fs_value_16g = '{32{6'd48}};
    preset_to_coefficients_mapping_table_16g = '{16{18'h0c900}};
    lf_value_32g = '{32{6'd24}};
    fs_value_32g = '{32{6'd48}};
    preset_to_coefficients_mapping_table_32g = '{16{18'h0c900}};
    downstream_lanes_recovery_eq_phase1_timeout_ns = 24_000;
    enable_equalization_verification_mode = 1'b0;
    enable_equalization_coefficients_checks = 1'b0;
    received_tlp_interface_mode = 3;
    remote_max_payload_size = 128;
    remote_extended_tag_field_enabled = 1'b0;
    driver_max_payload_size_in_bytes = 4096;
    target_max_payload_size_in_bytes = 128;
    target_max_read_cpl_data_size_in_bytes = 128;
    target_min_mem_cpl_latency_ns = 0;
    target_max_mem_cpl_latency_ns = 0;
    target_force_split_cpl_delay_to_0 = 1'b0;
    enable_shadow_cfg_lookup = 1'b0;
    enable_multi_endpoint_mode = 1'b0;
    target_app_enable = 1'b1;
    target_auto_response = 1'b0;
    link_timeout = 3ms;
    cfg_timeout = 1ms;
    enum_timeout = 3ms;
    traffic_timeout = 1ms;
    svt_verbosity = UVM_MEDIUM;
    enable_svt_monitor = 1'b0;
    enable_transaction_log = 1'b0;
    enable_symbol_log = 1'b0;
    enable_pl_history_log = 1'b0;
    enable_ctrl_skp_log = 1'b0;
    enable_mbi_log = 1'b0;
    enable_flit_transaction_log = 1'b0;
    transaction_log_filename = "";
    symbol_log_filename = "";
    pl_history_log_filename = "";
    flit_transaction_log_filename = "";
    transaction_log_filename_by_link.delete();
    symbol_log_filename_by_link.delete();
    link_override.delete();
  endfunction

  // 返回链路最终 Gen 上限：优先级为链路覆盖 > link.max_gen（非 0 时）
  // > 全局 default_max_gen。link 为 null 时返回全局默认；恒返回 1。
  function bit get_link_max_gen(
      pcie_link_cfg link,
      output int unsigned value);
    value = default_max_gen;
    if ((link != null) && (link.max_gen != 0))
      value = link.max_gen;
    if ((link != null) && link_override.exists(link.link_id) &&
        (link_override[link.link_id] != null) &&
        link_override[link.link_id].has_max_gen)
      value = link_override[link.link_id].max_gen;
    return 1'b1;
  endfunction

  // 返回链路最终快速建链开关：链路覆盖优先于全局 fast_link_training。
  function bit get_link_fast_training(
      pcie_link_cfg link,
      output bit value);
    value = fast_link_training;
    if ((link != null) && link_override.exists(link.link_id) &&
        (link_override[link.link_id] != null) &&
        link_override[link.link_id].has_fast_link_training)
      value = link_override[link.link_id].fast_link_training;
    return 1'b1;
  endfunction

  // 返回链路声明的 transport，优先使用链路覆盖；此 getter 不保证实现
  // 支持该模式。自动 backend 当前只接受 Serial，独立 PIPE 顶层不代表
  // backend 已支持 PIPE；静态 HDL 类型仍须与有效策略一致。
  function bit get_link_transport(
      pcie_link_cfg link,
      output pcie_svt_transport_e value);
    value = transport;
    if ((link != null) && link_override.exists(link.link_id) &&
        (link_override[link.link_id] != null) &&
        link_override[link.link_id].has_transport)
      value = link_override[link.link_id].transport;
    return 1'b1;
  endfunction

  // 返回链路最终的 EQ 开关。
  function bit get_link_equalization(
      pcie_link_cfg link,
      output bit value);
    value = enable_equalization;
    if ((link != null) && link_override.exists(link.link_id) &&
        (link_override[link.link_id] != null) &&
        link_override[link.link_id].has_equalization)
      value = link_override[link.link_id].enable_equalization;
    return 1'b1;
  endfunction

  // 返回链路选择的 EQ mode；override 的 0 也是按代际自动选择，不继承
  // 全局非零 mode。link 为空时返回全局值；恒返回 1，不修改配置对象。
  function bit get_link_eq_mode(
      pcie_link_cfg link,
      output int unsigned value);
    value = eq_mode;
    if ((link != null) && link_override.exists(link.link_id) &&
        (link_override[link.link_id] != null) &&
        link_override[link.link_id].has_eq_mode)
      value = link_override[link.link_id].eq_mode;
    return 1'b1;
  endfunction

  // 返回 direct/fast 开关组合，与显式 EQ mode 独立；backend 只在
  // EQ 总开关关闭时为兼容旧行为强制清零。保留这个
  // getter 的旧语义，避免破坏现有调用者。link 为空使用全局值；恒返回 1。
  // R-2020.12 的第二 API 参数仅描述 2.5→16 GT/s，故 Gen5 恒返回 0。
  function bit get_link_direct_speedup(
      pcie_link_cfg link,
      output bit value);
    int unsigned effective_gen;
    bit effective_fast_training;

    void'(get_link_max_gen(link, effective_gen));
    void'(get_link_fast_training(link, effective_fast_training));
    value = (effective_gen == 4) &&
            (direct_gen4_enable || effective_fast_training);
    return 1'b1;
  endfunction

  // 返回链路最终建链超时：链路覆盖优先于全局 link_timeout。
  function bit get_link_timeout(
      pcie_link_cfg link,
      output time value);
    value = link_timeout;
    if ((link != null) && link_override.exists(link.link_id) &&
        (link_override[link.link_id] != null) &&
        link_override[link.link_id].has_link_timeout)
      value = link_override[link.link_id].link_timeout;
    return 1'b1;
  endfunction

  // 校验全局字段与每条链路覆盖的取值合法性；所有问题以中文诊断累加进
  // errors（空表示通过）。未实现的非默认请求（passive monitor 等）在
  // 此硬拒绝，避免 backend 静默忽略用户意图。
  function void validate(output string errors[$]);
    bit seen_override[string];

    errors.delete();

    if (!((transport == PCIE_SVT_TRANSPORT_SERIAL) ||
          (transport == PCIE_SVT_TRANSPORT_PIPE)))
      errors.push_back("SVT transport 必须为 SERIAL 或 PIPE");
    if (!((backend_mode == PCIE_SVT_BACKEND_FULL_VIP) ||
          (backend_mode == PCIE_SVT_BACKEND_MAPPER_APP)))
      errors.push_back("SVT backend_mode 必须为 FULL_VIP 或 MAPPER_APP");
    if (!((default_max_gen == 4) || (default_max_gen == 5)))
      errors.push_back("SVT default_max_gen 必须为 Gen4 或 Gen5");
    if (!((pcie_spec_version == 0) || (pcie_spec_version == 4) ||
          (pcie_spec_version == 5)))
      errors.push_back("SVT pcie_spec_version 必须为 0(auto)/4/5");
    if ((pcie_spec_version != 0) &&
        (pcie_spec_version < default_max_gen))
      errors.push_back(
        "SVT pcie_spec_version 不能低于 default_max_gen");
    if (eq_mode > 3)
      errors.push_back("SVT eq_mode 必须为 0~3");
    if (downstream_lanes_recovery_eq_phase1_timeout_ns == 0)
      errors.push_back(
        "SVT downstream_lanes_recovery_eq_phase1_timeout_ns 必须大于 0");
    if (!((received_tlp_interface_mode == 1) ||
          (received_tlp_interface_mode == 2) ||
          (received_tlp_interface_mode == 3)))
      errors.push_back(
        "SVT received_tlp_interface_mode 必须是 1(good)/2(error)/3(all)");
    if (!(remote_max_payload_size inside
          {128, 256, 512, 1024, 2048, 4096}))
      errors.push_back("SVT remote_max_payload_size 必须是 128~4096 的标准 MPS");
    if (!(driver_max_payload_size_in_bytes inside
          {128, 256, 512, 1024, 2048, 4096}))
      errors.push_back(
        "SVT driver_max_payload_size_in_bytes 必须是 128~4096 的标准 MPS");
    if (!(target_max_payload_size_in_bytes inside
          {128, 256, 512, 1024, 2048, 4096}))
      errors.push_back(
        "SVT target_max_payload_size_in_bytes 必须是 128~4096 的标准 MPS");
    if (!(target_max_read_cpl_data_size_in_bytes inside {[64:128]}))
      errors.push_back(
        "SVT target_max_read_cpl_data_size_in_bytes 必须在 64~128 bytes");
    if (target_max_read_cpl_data_size_in_bytes >
        target_max_payload_size_in_bytes)
      errors.push_back(
        "SVT target max read Completion 不能大于 target max payload");
    if (target_min_mem_cpl_latency_ns > 5)
      errors.push_back("SVT target_min_mem_cpl_latency_ns 不能大于 5 ns");
    if (target_max_mem_cpl_latency_ns > 10)
      errors.push_back("SVT target_max_mem_cpl_latency_ns 不能大于 10 ns");
    if (target_max_mem_cpl_latency_ns < target_min_mem_cpl_latency_ns)
      errors.push_back(
        "SVT target_max_mem_cpl_latency_ns 不能小于 min latency");
    foreach (transaction_log_filename_by_link[link_id]) begin
      if ((link_id == "") ||
          (transaction_log_filename_by_link[link_id] == ""))
        errors.push_back(
          "SVT transaction_log_filename_by_link 不允许空 key/value");
    end
    foreach (symbol_log_filename_by_link[link_id]) begin
      if ((link_id == "") || (symbol_log_filename_by_link[link_id] == ""))
        errors.push_back(
          "SVT symbol_log_filename_by_link 不允许空 key/value");
    end

    // 当前 TL-root backend 始终创建 active Device Agent，并把 Target App
    // 的请求交给 pcie_tl_env 统一处理。R-2020.12 没有一个名为
    // target_app_enable/target_auto_response 的通用公开开关；Target App
    // 必须存在（Device Configuration 也约束 target_cfg.num()>0），且
    // backend 会通过 callback 抑制其自动 Completion。因此非默认请求必须
    // 在 build 前明确拒绝，不能让用户误以为设置已经生效。
    if (!target_app_enable)
      errors.push_back(
        "SVT target_app_enable=0 未实现：当前 backend 必须保留 Target App");
    if (target_auto_response)
      errors.push_back(
        "SVT target_auto_response=1 未实现：TL-owned backend 禁止内建自动响应");

    // enable_svt_monitor 不能在同一个 Device Agent 上与 active backend
    // 同时表达。SVT 的公开配置要求 is_active=0/enable_monitor=1 才是
    // passive monitor；当前 provider 没有创建独立 passive agent 的契约，
    // 所以对该非默认值直接报错，而不是只打印 warning 后继续运行。
    if (enable_svt_monitor)
      errors.push_back(
        "SVT enable_svt_monitor=1 未实现：请单独创建 passive SVT agent");

    // 该字段仅为旧项目保留的兼容命名，真正控制 R-2020.12 EQ 的是
    // enable_equalization/eq_mode。非默认值若继续被静默忽略会造成链路
    // 训练策略与 test 意图不一致，因此要求调用者改用实际字段。
    if (!full_equalization_required)
      errors.push_back(
        "SVT full_equalization_required=0 未实现：请使用 eq_mode/enable_equalization");

    // cfg/enum/traffic timeout 是 pcie_tl_env 编排阶段的预算，并非
    // R-2020.12 Device/PL/TL 的同名公开字段。当前 backend 尚未消费这些
    // stage budget；保留默认值兼容既有配置，但对显式改写给出硬错误，
    // 避免把一个未生效的 timeout 当成已启用。
    if (cfg_timeout != 1ms)
      errors.push_back(
        "SVT cfg_timeout 当前仅供后续编排 sequence 使用，backend 暂不支持非默认值");
    if (enum_timeout != 3ms)
      errors.push_back(
        "SVT enum_timeout 当前仅供后续编排 sequence 使用，backend 暂不支持非默认值");
    if (traffic_timeout != 1ms)
      errors.push_back(
        "SVT traffic_timeout 当前仅供后续编排 sequence 使用，backend 暂不支持非默认值");

    if ($isunknown(link_timeout) || (link_timeout == 0))
      errors.push_back("SVT link_timeout 必须大于 0");
    if ($isunknown(cfg_timeout) || (cfg_timeout == 0))
      errors.push_back("SVT cfg_timeout 必须大于 0");
    if ($isunknown(enum_timeout) || (enum_timeout == 0))
      errors.push_back("SVT enum_timeout 必须大于 0");
    if ($isunknown(traffic_timeout) || (traffic_timeout == 0))
      errors.push_back("SVT traffic_timeout 必须大于 0");

    foreach (link_override[link_id]) begin
      pcie_svt_link_override_cfg override_cfg;

      override_cfg = link_override[link_id];
      if (override_cfg == null) begin
        errors.push_back($sformatf("SVT link override '%s' 为空", link_id));
        continue;
      end
      if (link_id == "")
        errors.push_back("SVT link override 不能使用空 link_id");
      if (seen_override.exists(link_id))
        errors.push_back($sformatf("SVT link override '%s' 重复", link_id));
      else
        seen_override[link_id] = 1'b1;
      if (override_cfg.has_transport &&
          !((override_cfg.transport == PCIE_SVT_TRANSPORT_SERIAL) ||
            (override_cfg.transport == PCIE_SVT_TRANSPORT_PIPE)))
        errors.push_back($sformatf(
          "SVT link override '%s' transport 必须为 SERIAL 或 PIPE", link_id));
      if (override_cfg.has_max_gen &&
          !((override_cfg.max_gen == 4) || (override_cfg.max_gen == 5)))
        errors.push_back($sformatf(
          "SVT link override '%s' Gen 必须为 4 或 5", link_id));
      if (override_cfg.has_link_timeout &&
          ($isunknown(override_cfg.link_timeout) ||
           (override_cfg.link_timeout == 0)))
        errors.push_back($sformatf(
          "SVT link override '%s' timeout 必须大于 0", link_id));
      if (override_cfg.has_eq_mode && (override_cfg.eq_mode > 3))
        errors.push_back($sformatf(
          "SVT link override '%s' EQ mode 必须为 0~3", link_id));
    end
  endfunction

  // 深拷贝全部全局字段，并逐项复制链路覆盖表（覆盖对象各自 new，
  // 不共享句柄）；rhs 类型不符时报 fatal。
  virtual function void do_copy(uvm_object rhs);
    pcie_svt_backend_cfg source;
    pcie_svt_link_override_cfg override_copy;

    super.do_copy(rhs);

    if (!$cast(source, rhs)) begin
      `uvm_fatal("SVT_CFG_COPY", "SVT backend cfg 类型不匹配")
      return;
    end

    enable = source.enable;
    transport = source.transport;
    backend_mode = source.backend_mode;
    default_max_gen = source.default_max_gen;
    pcie_spec_version = source.pcie_spec_version;
    direct_gen4_enable = source.direct_gen4_enable;
    fast_link_training = source.fast_link_training;
    enable_equalization = source.enable_equalization;
    eq_mode = source.eq_mode;
    full_equalization_required = source.full_equalization_required;
    lf_value = source.lf_value;
    fs_value = source.fs_value;
    preset_to_coefficients_mapping_table =
      source.preset_to_coefficients_mapping_table;
    lf_value_16g = source.lf_value_16g;
    fs_value_16g = source.fs_value_16g;
    preset_to_coefficients_mapping_table_16g =
      source.preset_to_coefficients_mapping_table_16g;
    lf_value_32g = source.lf_value_32g;
    fs_value_32g = source.fs_value_32g;
    preset_to_coefficients_mapping_table_32g =
      source.preset_to_coefficients_mapping_table_32g;
    downstream_lanes_recovery_eq_phase1_timeout_ns =
      source.downstream_lanes_recovery_eq_phase1_timeout_ns;
    enable_equalization_verification_mode =
      source.enable_equalization_verification_mode;
    enable_equalization_coefficients_checks =
      source.enable_equalization_coefficients_checks;
    received_tlp_interface_mode = source.received_tlp_interface_mode;
    remote_max_payload_size = source.remote_max_payload_size;
    remote_extended_tag_field_enabled =
      source.remote_extended_tag_field_enabled;
    driver_max_payload_size_in_bytes =
      source.driver_max_payload_size_in_bytes;
    target_max_payload_size_in_bytes =
      source.target_max_payload_size_in_bytes;
    target_max_read_cpl_data_size_in_bytes =
      source.target_max_read_cpl_data_size_in_bytes;
    target_min_mem_cpl_latency_ns = source.target_min_mem_cpl_latency_ns;
    target_max_mem_cpl_latency_ns = source.target_max_mem_cpl_latency_ns;
    target_force_split_cpl_delay_to_0 =
      source.target_force_split_cpl_delay_to_0;
    enable_shadow_cfg_lookup = source.enable_shadow_cfg_lookup;
    enable_multi_endpoint_mode = source.enable_multi_endpoint_mode;
    target_app_enable = source.target_app_enable;
    target_auto_response = source.target_auto_response;
    link_timeout = source.link_timeout;
    cfg_timeout = source.cfg_timeout;
    enum_timeout = source.enum_timeout;
    traffic_timeout = source.traffic_timeout;
    svt_verbosity = source.svt_verbosity;
    enable_svt_monitor = source.enable_svt_monitor;
    enable_transaction_log = source.enable_transaction_log;
    enable_symbol_log = source.enable_symbol_log;
    enable_pl_history_log = source.enable_pl_history_log;
    enable_ctrl_skp_log = source.enable_ctrl_skp_log;
    enable_mbi_log = source.enable_mbi_log;
    enable_flit_transaction_log = source.enable_flit_transaction_log;
    transaction_log_filename = source.transaction_log_filename;
    symbol_log_filename = source.symbol_log_filename;
    pl_history_log_filename = source.pl_history_log_filename;
    flit_transaction_log_filename = source.flit_transaction_log_filename;
    transaction_log_filename_by_link.delete();
    foreach (source.transaction_log_filename_by_link[link_id])
      transaction_log_filename_by_link[link_id] =
        source.transaction_log_filename_by_link[link_id];
    symbol_log_filename_by_link.delete();
    foreach (source.symbol_log_filename_by_link[link_id])
      symbol_log_filename_by_link[link_id] =
        source.symbol_log_filename_by_link[link_id];

    link_override.delete();
    foreach (source.link_override[link_id]) begin
      if (source.link_override[link_id] == null) begin
        link_override[link_id] = null;
      end
      else begin
        override_copy = pcie_svt_link_override_cfg::type_id::create(
          {"override_copy_", link_id});
        override_copy.copy(source.link_override[link_id]);
        link_override[link_id] = override_copy;
      end
    end
  endfunction
endclass
