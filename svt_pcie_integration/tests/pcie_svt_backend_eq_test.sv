//------------------------------------------------------------------------------
// svt_pcie_integration/tests：backend EQ API 落地与 Gen4 Serial 建链回归。
// 由 formal_top 在 auto_link_test 之后包含，依赖 SVT/UVM、adapter 与 topology
// 类型。矩阵测试只创建临时 cfg，不创建 agent；训练测试复用生产 backend RC
// 和独立配置的外部 SVT EP，UVM 负责子组件生命周期，不依赖 AIP/Tcl。
//------------------------------------------------------------------------------

// 仅在测试层开放 protected 配置入口，使断言覆盖实际 SVT setter，而不是
// 重复验证枚举转换。生产 backend 不为测试新增公开配置/调试 API。
class pcie_svt_eq_test_backend extends pcie_svt_backend;
  // 构造一个测试拥有的 provider，不创建 UVM component 或自动启动链路。
  function new(string name = "eq_test_backend");
    super.new(name);
  endfunction

  // 调用真实配置路径；cfg/link/vif 由测试提供，SVT cfg 被原地更新，错误
  // 通过队列返回。每次只配置一条 link，不经过用户 customize hook。
  function void apply_for_test(pcie_svt_backend_cfg cfg,
                              pcie_link_cfg link,
                              svt_pcie_vif vif,
                              svt_pcie_device_configuration device_cfg,
                              output string errors[$]);
    backend_cfg = cfg;
    apply_link_configuration(0, link, vif, device_cfg, errors);
  endfunction
endclass

// 真实双 SVT Serial 对打：RC 必须由生产 backend 创建，EP 按独立预期表
// 配置，不复用 backend 的映射算法。只检查训练，不替代既有双向 TLP 门禁。
class pcie_svt_backend_eq_link_test extends pcie_svt_backend_auto_link_test;
  `uvm_component_utils(pcie_svt_backend_eq_link_test)

  int unsigned test_mode = 3;
  int unsigned test_enable = 1;
  int unsigned test_direct = 0;
  int unsigned test_fast = 0;
  bit expected_direct;
  int unsigned expected_phase;

  // 透传名字；默认重现“Gen4 No-EQ，非直达”的修复场景。
  function new(string name = "pcie_svt_backend_eq_link_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 父类先发布配置句柄；此时 child build 尚未执行，可安全修改 RC/EP
  // 策略。plusarg 仅属于本测试，非法范围 fatal，不增加生产配置入口。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'($value$plusargs("SVT_EQ_MODE=%d", test_mode));
    void'($value$plusargs("SVT_EQ_ENABLE=%d", test_enable));
    void'($value$plusargs("SVT_EQ_DIRECT=%d", test_direct));
    void'($value$plusargs("SVT_EQ_FAST=%d", test_fast));
    if (test_mode > 3 || test_enable > 1 || test_direct > 1 || test_fast > 1)
      `uvm_fatal("SVT_EQ_LINK", "mode 必须 0~3，enable/direct/fast 必须 0/1")
    svt_backend_cfg.enable_equalization = bit'(test_enable);
    svt_backend_cfg.eq_mode = test_mode;
    svt_backend_cfg.direct_gen4_enable = bit'(test_direct);
    svt_backend_cfg.fast_link_training = bit'(test_fast);

    expected_direct = test_enable && (test_mode == 2 || test_direct || test_fast);
    expected_phase = (!test_enable || test_mode == 3) ? 0 : 3;
    external_endpoint_cfg.pcie_spec_ver =
      svt_pcie_device_configuration::PCIE_SPEC_VER_4_0;
    external_endpoint_cfg.pcie_cfg.pl_cfg.set_link_width_values(16, 32'h3f, 16);
    external_endpoint_cfg.pcie_cfg.pl_cfg.set_link_speed_values(
      (`SVT_PCIE_SPEED_2_5G | `SVT_PCIE_SPEED_5_0G |
       `SVT_PCIE_SPEED_8_0G | `SVT_PCIE_SPEED_16_0G),
      `SVT_PCIE_SPEED_16_0G, `SVT_PCIE_SPEED_16_0G);
    // Gen4 的 enum 无行为效果；独立 EP 故意固定 FULL，验证真正决定
    // No-EQ 的是第三参，而不是与 RC 使用相同 enum 恰巧掩盖错误。
    external_endpoint_cfg.pcie_cfg.pl_cfg.set_link_eq_attribute_values(
      svt_pcie_pl_configuration::LINK_EQ_MODE_FULL_EQUALIZATION_REQUIRED,
      expected_direct, expected_phase);
  endfunction

  // 继承自动构建门禁，并检查已创建 RC 的实际 SVT 配置；不修改任何参数。
  function void end_of_elaboration_phase(uvm_phase phase);
    svt_pcie_device_configuration rc_cfg;
    super.end_of_elaboration_phase(phase);
    rc_cfg = backend.svt_cfg_by_link[global_cfg.links[0].link_id];
    if (rc_cfg.pcie_cfg.pl_cfg.enable_direct_speed_up_from_2_5g_to_16g != expected_direct ||
        rc_cfg.pcie_cfg.pl_cfg.highest_enabled_equalization_phase != expected_phase)
      `uvm_fatal("SVT_EQ_LINK", "生产 RC 的 direct/phase 与独立预期不符")
  endfunction

  // 双端必须同时 L0 且实际/协商速率均为 16 GT/s；仅 Gen1 初次 L0 不算通过。
  // status 由父类构建并经 end_of_elaboration 校验，run 时不允许空 PL 对象。
  function bit both_at_gen4(svt_pcie_device_status rc_status);
    return rc_status.pcie_status.pl_status.link_up &&
      external_endpoint_status.pcie_status.pl_status.link_up &&
      rc_status.pcie_status.pl_status.ltssm_state == svt_pcie_types::L0 &&
      external_endpoint_status.pcie_status.pl_status.ltssm_state == svt_pcie_types::L0 &&
      rc_status.pcie_status.pl_status.current_speed == svt_pcie_pl_status::SPEED_16_0G &&
      external_endpoint_status.pcie_status.pl_status.current_speed == svt_pcie_pl_status::SPEED_16_0G &&
      rc_status.pcie_status.pl_status.negotiated_speed == svt_pcie_pl_status::SPEED_16_0G &&
      external_endpoint_status.pcie_status.pl_status.negotiated_speed == svt_pcie_pl_status::SPEED_16_0G;
  endfunction

  // 复位释放后并行启动官方 link-enable sequence；500us 有界等待，随后
  // 每 100ns 采样检查 5us 稳定性。失败时 fatal，不静默降级为 Gen1 通过。
  task run_phase(uvm_phase phase);
    svt_pcie_device_agent rc_agent;
    svt_pcie_device_status rc_status;
    svt_pcie_dl_service_set_link_en_sequence rc_seq;
    svt_pcie_dl_service_set_link_en_sequence ep_seq;

    phase.raise_objection(this);
    rc_agent = backend.svt_agent_by_link[global_cfg.links[0].link_id];
    rc_status = backend.get_status(global_cfg.links[0].link_id);
    if (rc_status == null || external_endpoint_status == null)
      `uvm_fatal("SVT_EQ_LINK", "RC/EP status 未创建")
    if (rc_status.pcie_status == null || external_endpoint_status.pcie_status == null)
      `uvm_fatal("SVT_EQ_LINK", "RC/EP PCIe status 未创建")
    if (rc_status.pcie_status.pl_status == null || external_endpoint_status.pcie_status.pl_status == null)
      `uvm_fatal("SVT_EQ_LINK", "RC/EP PL status 未创建")
    rc_seq = svt_pcie_dl_service_set_link_en_sequence::type_id::create("eq_rc_enable");
    ep_seq = svt_pcie_dl_service_set_link_en_sequence::type_id::create("eq_ep_enable");
    rc_seq.enable = 1;
    ep_seq.enable = 1;
    fork : training_or_timeout
      begin
        // 与已验证的 AIP 双 SVT 用例相同，在 200ns reset 释放后留出启动裕量。
        #10us;
        fork
          rc_seq.start(rc_agent.virt_seqr.pcie_virt_seqr.dl_seqr);
          ep_seq.start(external_endpoint.virt_seqr.pcie_virt_seqr.dl_seqr);
        join
        // 定时采样避免 wait(function()) 对 class 内部属性变化的敏感性差异。
        while (!both_at_gen4(rc_status)) #100ns;
        repeat (50) begin
          #100ns;
          if (!both_at_gen4(rc_status))
            `uvm_fatal("SVT_EQ_LINK", "Gen4 L0 后稳定性检查掉链")
        end
        `uvm_info("SVT_EQ_LINK", $sformatf(
          "SVT_EQ_GEN4_LINK_PASS mode=%0d enable=%0b direct=%0b fast=%0b highest_eq_phase=%0d both=16GT/s_L0",
          test_mode, test_enable, expected_direct, test_fast, expected_phase), UVM_NONE)
      end
      begin
        #500us;
        `uvm_fatal("SVT_EQ_LINK", $sformatf(
          "Gen4 timeout: RC state=%0d speed=%0d EP state=%0d speed=%0d",
          rc_status.pcie_status.pl_status.ltssm_state,
          rc_status.pcie_status.pl_status.current_speed,
          external_endpoint_status.pcie_status.pl_status.ltssm_state,
          external_endpoint_status.pcie_status.pl_status.current_speed))
      end
    join_any
    disable training_or_timeout;
    phase.drop_objection(this);
  endtask
endclass

// 配置回归遍历所有公开 EQ mode/旧开关组合，并追加链路 override 用例。
// 断言使用 SVT 公开 getter/属性读回值，防止只映射枚举、遗漏 phase 再次回归。
class pcie_svt_backend_eq_cfg_test extends uvm_test;
  `uvm_component_utils(pcie_svt_backend_eq_cfg_test)

  pcie_svt_eq_test_backend backend;
  svt_pcie_vif root_vif;
  int unsigned checked_cases;

  // 透传 UVM 名字；测试句柄在 run_phase 中创建，不提前访问 HDL VIF。
  function new(string name = "pcie_svt_backend_eq_cfg_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 将一组策略应用到独立 SVT cfg 后，与调用者的预期三参数逐一比较。
  // 任意配置错误/参数不符立即 fatal，避免“打印正确”掩盖 setter 未落地。
  function void check_case(pcie_svt_backend_cfg cfg, pcie_link_cfg link,
                          svt_pcie_pl_configuration::link_eq_mode_enum mode,
                          bit direct, int unsigned highest_phase);
    svt_pcie_device_configuration device_cfg;
    string errors[$];

    device_cfg = svt_pcie_device_configuration::type_id::create(
      $sformatf("eq_device_cfg_%0d", checked_cases));
    backend.apply_for_test(cfg, link, root_vif, device_cfg, errors);
    if (errors.size() != 0)
      `uvm_fatal("SVT_EQ_TEST", $sformatf("apply errors: %p", errors))
    if ((device_cfg.pcie_cfg.pl_cfg.get_link_eq_attribute_values() != mode) ||
        (device_cfg.pcie_cfg.pl_cfg.enable_direct_speed_up_from_2_5g_to_16g != direct) ||
        (device_cfg.pcie_cfg.pl_cfg.highest_enabled_equalization_phase != highest_phase))
      `uvm_fatal("SVT_EQ_TEST", $sformatf(
        "case=%0d Gen%0d enable=%0b mode=%0d direct_flag=%0b fast_flag=%0b got=(%0d,%0b,%0d) expected=(%0d,%0b,%0d)",
        checked_cases, link.max_gen, cfg.enable_equalization, cfg.eq_mode,
        cfg.direct_gen4_enable, cfg.fast_link_training,
        device_cfg.pcie_cfg.pl_cfg.get_link_eq_attribute_values(),
        device_cfg.pcie_cfg.pl_cfg.enable_direct_speed_up_from_2_5g_to_16g,
        device_cfg.pcie_cfg.pl_cfg.highest_enabled_equalization_phase,
        mode, direct, highest_phase))
    checked_cases++;
  endfunction

  // 在 HDL VIF 发布后执行 64 组合与 override 用例，不推进物理链路。
  // Gen5 mode=3 保持原有 phase=3、依靠第一参关闭 EQ；EQ-off 则保留 phase=0。
  task run_phase(uvm_phase phase);
    pcie_svt_backend_cfg cfg;
    pcie_svt_link_override_cfg ov;
    pcie_link_cfg link;
    svt_pcie_pl_configuration::link_eq_mode_enum expected_mode;
    bit expected_direct;
    int unsigned expected_phase;

    phase.raise_objection(this);
    if (!uvm_config_db#(svt_pcie_vif)::get(this, "", "link_0_vif_0", root_vif) ||
        root_vif == null)
      `uvm_fatal("SVT_EQ_TEST", "缺少 formal_top 的 root Unified VIF")
    backend = new();
    cfg = pcie_svt_backend_cfg::type_id::create("eq_policy");
    link = pcie_link_cfg::type_id::create("eq_link");
    link.link_id = "RC0_EP0";
    link.link_width = 16;
    link.svt_role = PCIE_DEVICE_RC;

    for (int gen = 4; gen <= 5; gen++) begin
      for (int en = 0; en <= 1; en++) begin
        for (int mode = 0; mode <= 3; mode++) begin
          for (int direct = 0; direct <= 1; direct++) begin
            for (int fast = 0; fast <= 1; fast++) begin
              cfg.init_defaults();
              link.max_gen = gen;
              cfg.enable_equalization = bit'(en);
              cfg.eq_mode = mode;
              cfg.direct_gen4_enable = bit'(direct);
              cfg.fast_link_training = bit'(fast);
              if (!en || mode == 3)
                expected_mode = svt_pcie_pl_configuration::LINK_EQ_MODE_NO_EQUALIZATION_NEEDED;
              else if (mode == 2 || (mode == 0 && gen == 5))
                expected_mode = svt_pcie_pl_configuration::LINK_EQ_MODE_EQ_BYPASS_TO_HIGHEST_RATE;
              else
                expected_mode = svt_pcie_pl_configuration::LINK_EQ_MODE_FULL_EQUALIZATION_REQUIRED;
              expected_direct = en && gen == 4 && (mode == 2 || direct || fast);
              expected_phase = (!en || (gen == 4 && mode == 3)) ? 0 : 3;
              check_case(cfg, link, expected_mode, expected_direct, expected_phase);
            end
          end
        end
      end
    end

    // 全局 Full + per-link No-EQ、Bypass，确认映射使用选中值而非全局字段。
    cfg.init_defaults();
    cfg.eq_mode = 1;
    link.max_gen = 4;
    ov = pcie_svt_link_override_cfg::type_id::create("eq_override");
    cfg.link_override[link.link_id] = ov;
    ov.has_eq_mode = 1;
    ov.eq_mode = 3;
    check_case(cfg, link, svt_pcie_pl_configuration::LINK_EQ_MODE_NO_EQUALIZATION_NEEDED, 0, 0);
    ov.eq_mode = 2;
    check_case(cfg, link, svt_pcie_pl_configuration::LINK_EQ_MODE_EQ_BYPASS_TO_HIGHEST_RATE, 1, 3);
    // override=0 明确选择自动策略，不应继续继承全局的 No-EQ。
    cfg.eq_mode = 3;
    ov.eq_mode = 0;
    check_case(cfg, link, svt_pcie_pl_configuration::LINK_EQ_MODE_FULL_EQUALIZATION_REQUIRED, 0, 3);
    ov.eq_mode = 3;
    ov.has_fast_link_training = 1;
    ov.fast_link_training = 1;
    check_case(cfg, link, svt_pcie_pl_configuration::LINK_EQ_MODE_NO_EQUALIZATION_NEEDED, 1, 0);
    ov.has_equalization = 1;
    ov.enable_equalization = 0;
    check_case(cfg, link, svt_pcie_pl_configuration::LINK_EQ_MODE_NO_EQUALIZATION_NEEDED, 0, 0);
    // 链路 Gen override 也必须用于决策：Gen5 的 phase/direct 不能按全局 Gen4。
    ov.enable_equalization = 1;
    ov.has_max_gen = 1;
    ov.max_gen = 5;
    check_case(cfg, link, svt_pcie_pl_configuration::LINK_EQ_MODE_NO_EQUALIZATION_NEEDED, 0, 3);

    `uvm_info("SVT_EQ_TEST", $sformatf(
      "SVT_EQ_CFG_MATRIX_PASS cases=%0d", checked_cases), UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
