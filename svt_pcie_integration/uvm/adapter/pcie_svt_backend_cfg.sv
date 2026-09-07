//------------------------------------------------------------------------------
// SVT backend 专用配置。
//
// 该对象只存在于 SVT integration package 中。拓扑、BDF、BAR 和 Host
// binding 仍由 pcie_global_cfg / pcie_tl_env_config 管理；本对象只保存
// Synopsys SVT transport 所需的参数，避免把 vendor 类型泄漏到 TL-only
// package。
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

  // 链路级 EQ mode 覆盖。0 表示沿用全局自动策略，1/2/3 对应 Full /
  // Bypass / No-Equalization；只有 has_eq_mode 置位时才生效。
  bit has_eq_mode;
  int unsigned eq_mode;

  bit has_link_timeout;
  time link_timeout;

  `uvm_object_utils(pcie_svt_link_override_cfg)

  function new(string name = "pcie_svt_link_override_cfg");
    super.new(name);
  endfunction

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
  // Transport and link-training policy.
  // --------------------------------------------------------------------------
  bit enable = 1'b1;
  pcie_svt_transport_e transport = PCIE_SVT_TRANSPORT_SERIAL;
  pcie_svt_backend_mode_e backend_mode = PCIE_SVT_BACKEND_FULL_VIP;

  int unsigned default_max_gen = 4;
  bit direct_gen4_enable = 1'b0;
  bit fast_link_training = 1'b0;

  // --------------------------------------------------------------------------
  // Physical equalization policy.
  // --------------------------------------------------------------------------
  bit enable_equalization = 1'b1;
  int unsigned eq_mode = 0;
  // 兼容既有项目配置名：该字段仅表示所选 EQ mode 是否要求完整均衡，
  // 不对应 SVT set_link_eq_attribute_values() 的第二个参数。SVT 的
  // direct-speed-up 选项由 direct_gen4_enable/fast_link_training 控制。
  bit full_equalization_required = 1'b1;

  // --------------------------------------------------------------------------
  // SVT configuration-space and Target App policy.
  // --------------------------------------------------------------------------
  bit enable_shadow_cfg_lookup = 1'b0;
  bit enable_multi_endpoint_mode = 1'b0;
  bit target_app_enable = 1'b1;
  bit target_auto_response = 1'b0;

  // --------------------------------------------------------------------------
  // Timeout and log policy.
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

  // 链路级覆盖优先于本对象的全局值，再由用户 hook 做最后修改。
  pcie_svt_link_override_cfg link_override[string];

  `uvm_object_utils(pcie_svt_backend_cfg)

  function new(string name = "pcie_svt_backend_cfg");
    super.new(name);
  endfunction

  function void init_defaults();
    enable = 1'b1;
    transport = PCIE_SVT_TRANSPORT_SERIAL;
    backend_mode = PCIE_SVT_BACKEND_FULL_VIP;
    default_max_gen = 4;
    direct_gen4_enable = 1'b0;
    fast_link_training = 1'b0;
    enable_equalization = 1'b1;
    eq_mode = 0;
    full_equalization_required = 1'b1;
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
    link_override.delete();
  endfunction

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

  // 返回链路最终采用的 transport。当前只实现 Serial；PIPE 会在
  // validate() 阶段被拒绝，避免 backend 把未实现请求静默降级。
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

  // 返回链路最终 EQ mode；0 保留全局自动选择语义。
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

  // R-2020.12 的 direct-speed-up API 只描述 2.5 GT/s 到 16 GT/s，故仅
  // 对 Gen4 返回 1。Gen5 即使打开 fast_link_training，也必须走正常的
  // 32 GT/s 训练/均衡配置，不能复用该布尔参数。
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

  function void validate(output string errors[$]);
    bit seen_override[string];

    errors.delete();

    if (transport != PCIE_SVT_TRANSPORT_SERIAL)
      errors.push_back("SVT backend 当前只支持 SERIAL transport，PIPE 预留未实现");
    if (!((backend_mode == PCIE_SVT_BACKEND_FULL_VIP) ||
          (backend_mode == PCIE_SVT_BACKEND_MAPPER_APP)))
      errors.push_back("SVT backend_mode 必须为 FULL_VIP 或 MAPPER_APP");
    if (!((default_max_gen == 4) || (default_max_gen == 5)))
      errors.push_back("SVT default_max_gen 必须为 Gen4 或 Gen5");
    if (eq_mode > 3)
      errors.push_back("SVT eq_mode 必须为 0~3");

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
          (override_cfg.transport != PCIE_SVT_TRANSPORT_SERIAL))
        errors.push_back($sformatf(
          "SVT link override '%s' 请求了未实现的 PIPE transport", link_id));
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
    direct_gen4_enable = source.direct_gen4_enable;
    fast_link_training = source.fast_link_training;
    enable_equalization = source.enable_equalization;
    eq_mode = source.eq_mode;
    full_equalization_required = source.full_equalization_required;
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
