//------------------------------------------------------------------------------
// svt_pcie_integration/tests：SVT backend 配置对象契约测试。
//
// 该测试不创建 SVT agent，也不依赖物理 Serial 链路；它只锁定 backend
// 配置层的优先级和 Gen4 快速建链语义。这样配置错误会在 agent 创建前被
// 发现，避免把一个纯策略问题误判成链路训练问题。
// 依赖 UVM、TL/topology 与 SVT adapter package；测试拥有局部配置和
// provider 句柄，UVM 管理 test 生命周期，不改变 HDL 或启动建链 sequence。
//------------------------------------------------------------------------------

`include "uvm_macros.svh"

import uvm_pkg::*;
import pcie_tl_pkg::*;
import pcie_topology_pkg::*;
import pcie_svt_adapter_pkg::*;

class pcie_svt_backend_cfg_unit_test extends uvm_test;
  `uvm_component_utils(pcie_svt_backend_cfg_unit_test)

  // 透传 test 名字和父组件；配置对象在 run_phase 内创建。
  function new(string name = "pcie_svt_backend_cfg_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 同步契约断言；condition 为假时立即 fatal，禁止错误配置继续通过。
  function void require(bit condition, string message);
    if (!condition)
      `uvm_fatal("SVT_CFG_CONTRACT", message)
  endfunction

  // 验证默认值、模式解析、覆盖优先级与非法请求；保持 objection 直到
  // 所有断言结束，任意失败 fatal，不推进物理链路。
  task run_phase(uvm_phase phase);
    pcie_svt_backend_cfg cfg;
    pcie_svt_backend_cfg copied_cfg;
    pcie_svt_link_override_cfg override_cfg;
    pcie_link_cfg link;
    pcie_svt_transport_e transport;
    bit equalization;
    int unsigned eq_mode;
    bit direct_speedup;
    pcie_svt_backend backend;
    svt_pcie_pl_configuration::link_eq_mode_enum effective_mode;
    string errors[$];

    phase.raise_objection(this);

    cfg = pcie_svt_backend_cfg::type_id::create("cfg");
    cfg.init_defaults();
    link = pcie_link_cfg::type_id::create("link");
    link.link_id = "L0";
    link.max_gen = 4;

    // 默认策略：Serial、EQ 开启、Gen4 才允许 direct-speed-up。
    void'(cfg.get_link_transport(link, transport));
    void'(cfg.get_link_equalization(link, equalization));
    void'(cfg.get_link_eq_mode(link, eq_mode));
    void'(cfg.get_link_direct_speedup(link, direct_speedup));
    require(transport == PCIE_SVT_TRANSPORT_SERIAL,
            "default transport must be SERIAL");
    require(equalization == 1'b1,
            "default equalization must be enabled");
    require(eq_mode == 0,
            "default link EQ mode must inherit global automatic mode");
    require(direct_speedup == 1'b0,
            "direct speed-up must be disabled by default");
    require(cfg.pcie_spec_version == 0,
            "default PCIe spec version must follow effective max_gen");
    require((cfg.lf_value[0] == 6'd24) &&
            (cfg.fs_value[0] == 6'd48) &&
            (cfg.preset_to_coefficients_mapping_table[0] == 18'h0c900),
            "default 8G EQ TS1 values must match R-2020.12 defaults");
    require((cfg.lf_value_16g[0] == 6'd24) &&
            (cfg.fs_value_16g[0] == 6'd48) &&
            (cfg.preset_to_coefficients_mapping_table_16g[0] == 18'h0c900),
            "default 16G EQ TS1 values must match R-2020.12 defaults");
    require(cfg.downstream_lanes_recovery_eq_phase1_timeout_ns == 24_000,
            "default downstream Phase1 timeout must be 24000 ns");
    require(!cfg.enable_equalization_verification_mode &&
            !cfg.enable_equalization_coefficients_checks &&
            (cfg.received_tlp_interface_mode == 3),
            "default EQ checker and received-TLP mask must match SVT defaults");
    require((cfg.remote_max_payload_size == 128) &&
            !cfg.remote_extended_tag_field_enabled &&
            (cfg.driver_max_payload_size_in_bytes == 4096) &&
            (cfg.target_max_payload_size_in_bytes == 128) &&
            (cfg.target_max_read_cpl_data_size_in_bytes == 128),
            "default TL/Driver/Target payload fields must match SVT defaults");

    // 配置对象可能由 test/factory 复制后再发布；数组和 timeout 必须深值复制，
    // 不能只在原对象直接使用时有效。这里改写 lane0/preset0 后验证副本，
    // 随后恢复默认值，避免影响后续模式与 override 契约。
    cfg.lf_value[0] = 6'd9;
    cfg.fs_value[0] = 6'd24;
    cfg.preset_to_coefficients_mapping_table[0] = 18'h00543;
    cfg.downstream_lanes_recovery_eq_phase1_timeout_ns = 500_000;
    cfg.enable_equalization_coefficients_checks = 1'b1;
    cfg.received_tlp_interface_mode = 1;
    cfg.remote_max_payload_size = 4096;
    cfg.remote_extended_tag_field_enabled = 1'b1;
    cfg.pcie_spec_version = 5;
    cfg.driver_max_payload_size_in_bytes = 128;
    cfg.target_force_split_cpl_delay_to_0 = 1'b1;
    cfg.transaction_log_filename_by_link[link.link_id] = "trans_rc0.log";
    cfg.symbol_log_filename_by_link[link.link_id] = "symbol_rc0.log";
    copied_cfg = pcie_svt_backend_cfg::type_id::create("copied_cfg");
    copied_cfg.copy(cfg);
    require((copied_cfg.lf_value[0] == 6'd9) &&
            (copied_cfg.fs_value[0] == 6'd24) &&
            (copied_cfg.preset_to_coefficients_mapping_table[0] == 18'h00543) &&
            (copied_cfg.downstream_lanes_recovery_eq_phase1_timeout_ns ==
             500_000) && copied_cfg.enable_equalization_coefficients_checks &&
            (copied_cfg.received_tlp_interface_mode == 1) &&
            (copied_cfg.remote_max_payload_size == 4096) &&
            copied_cfg.remote_extended_tag_field_enabled &&
            (copied_cfg.pcie_spec_version == 5) &&
            (copied_cfg.driver_max_payload_size_in_bytes == 128) &&
            copied_cfg.target_force_split_cpl_delay_to_0 &&
            (copied_cfg.transaction_log_filename_by_link[link.link_id] ==
             "trans_rc0.log") &&
            (copied_cfg.symbol_log_filename_by_link[link.link_id] ==
             "symbol_rc0.log"),
            "02.png protocol fields and per-link log names must survive cfg copy");
    cfg.init_defaults();

    // EQ 关闭语义：无论 Gen4 还是 Gen5，都必须落到官方
    // NO_EQUALIZATION_NEEDED 枚举，不能隐式启用 direct-speed-up。
    backend = pcie_svt_backend::type_id::create("cfg_contract_backend");
    effective_mode = backend.get_effective_equalization_mode(
      4, 1'b0, 0);
    require(effective_mode ==
            svt_pcie_pl_configuration::LINK_EQ_MODE_NO_EQUALIZATION_NEEDED,
            "Gen4 EQ-off must map to NO_EQUALIZATION_NEEDED");
    effective_mode = backend.get_effective_equalization_mode(
      5, 1'b0, 0);
    require(effective_mode ==
            svt_pcie_pl_configuration::LINK_EQ_MODE_NO_EQUALIZATION_NEEDED,
            "Gen5 EQ-off must map to NO_EQUALIZATION_NEEDED");

    // EQ 开启时保留既有代际策略：Gen4 默认 Full-EQ，Gen5 默认 bypass。
    effective_mode = backend.get_effective_equalization_mode(
      4, 1'b1, 0);
    require(effective_mode ==
            svt_pcie_pl_configuration::LINK_EQ_MODE_FULL_EQUALIZATION_REQUIRED,
            "Gen4 default EQ must map to FULL_EQUALIZATION_REQUIRED");
    effective_mode = backend.get_effective_equalization_mode(
      5, 1'b1, 0);
    require(effective_mode ==
            svt_pcie_pl_configuration::LINK_EQ_MODE_EQ_BYPASS_TO_HIGHEST_RATE,
            "Gen5 default EQ must map to EQ_BYPASS_TO_HIGHEST_RATE");

    // 部分 EQ 不是速率 bypass。两种代际都使用 FULL 枚举，阶段上限
    // 由实际 setter 矩阵另验为 1；更改 mode 不能暗中开启 direct。
    for (int gen = 4; gen <= 5; gen++) begin
      effective_mode = backend.get_effective_equalization_mode(gen, 1'b1, 2);
      require(effective_mode ==
              svt_pcie_pl_configuration::LINK_EQ_MODE_FULL_EQUALIZATION_REQUIRED,
              "partial EQ must use FULL enum with a separate phase limit");
    end
    cfg.eq_mode = 2;
    void'(cfg.get_link_direct_speedup(link, direct_speedup));
    require(direct_speedup == 1'b0,
            "partial EQ must not enable direct speed-up implicitly");

    // 链路级覆盖必须优先于全局值；覆盖对象只修改明确置位的字段。
    cfg.direct_gen4_enable = 1'b1;
    cfg.eq_mode = 1;
    cfg.enable_equalization = 1'b1;
    override_cfg = pcie_svt_link_override_cfg::type_id::create("override_L0");
    override_cfg.has_transport = 1'b1;
    override_cfg.transport = PCIE_SVT_TRANSPORT_SERIAL;
    override_cfg.has_equalization = 1'b1;
    override_cfg.enable_equalization = 1'b0;
    override_cfg.has_eq_mode = 1'b1;
    override_cfg.eq_mode = 3;
    override_cfg.has_fast_link_training = 1'b1;
    override_cfg.fast_link_training = 1'b1;
    cfg.link_override[link.link_id] = override_cfg;

    void'(cfg.get_link_transport(link, transport));
    void'(cfg.get_link_equalization(link, equalization));
    void'(cfg.get_link_eq_mode(link, eq_mode));
    void'(cfg.get_link_direct_speedup(link, direct_speedup));
    require(transport == PCIE_SVT_TRANSPORT_SERIAL,
            "link transport override was not applied");
    require(equalization == 1'b0,
            "link equalization override was not applied");
    require(eq_mode == 3,
            "link EQ mode override was not applied");
    require(direct_speedup == 1'b1,
            "Gen4 direct speed-up should honor global/override training policy");

    // Gen5 32 GT/s 没有 R-2020.12 的 2.5->16 GT/s direct API，不能误把
    // Gen4 的布尔开关传给 Gen5。
    link.max_gen = 5;
    void'(cfg.get_link_direct_speedup(link, direct_speedup));
    require(direct_speedup == 1'b0,
            "Gen5 must not use the Gen4-only direct speed-up flag");

    // 全局 EQ mode 与链路覆盖使用同一 0~3 约束；非法值必须在 backend
    // 创建任何 SVT agent 之前由配置对象拒绝。
    cfg.eq_mode = 4;
    errors.delete();
    cfg.validate(errors);
    require(errors.size() != 0,
            "global EQ mode 4 must be rejected during validation");
    cfg.eq_mode = 0;

    // Phase1 timeout 由 SVT PL LTSSM 直接消费；0 会使训练立即超时，
    // 必须在 agent build 之前拒绝，避免被误判为 SerDes 链路问题。
    cfg.downstream_lanes_recovery_eq_phase1_timeout_ns = 0;
    errors.delete();
    cfg.validate(errors);
    require(errors.size() != 0,
            "zero downstream Phase1 timeout must be rejected");
    cfg.downstream_lanes_recovery_eq_phase1_timeout_ns = 24_000;

    // received mask=0 会让 analysis port 什么都不发布，且不是官方
    // good/error/all 三种合法语义；配置层应在 build 前直接拒绝。
    cfg.received_tlp_interface_mode = 0;
    errors.delete();
    cfg.validate(errors);
    require(errors.size() != 0,
            "received TLP interface mask 0 must be rejected");
    cfg.received_tlp_interface_mode = 3;

    // Target completion latency 必须保持 min<=max，不允许依赖 SVT
    // randomize 失败后才暴露配置错误。
    cfg.target_min_mem_cpl_latency_ns = 5;
    cfg.target_max_mem_cpl_latency_ns = 4;
    errors.delete();
    cfg.validate(errors);
    require(errors.size() != 0,
            "target completion min latency greater than max must be rejected");
    cfg.target_min_mem_cpl_latency_ns = 0;
    cfg.target_max_mem_cpl_latency_ns = 0;

    // Unsupported Target App/passive-monitor switches must fail fast rather
    // than silently being ignored.  The current TL-root bridge owns all
    // completions, therefore the active SVT Target App is mandatory and its
    // built-in automatic response must remain disabled.
    cfg.target_app_enable = 1'b0;
    errors.delete();
    cfg.validate(errors);
    require(errors.size() != 0,
            "target_app_enable=0 must be rejected as unsupported");
    cfg.target_app_enable = 1'b1;

    cfg.target_auto_response = 1'b1;
    errors.delete();
    cfg.validate(errors);
    require(errors.size() != 0,
            "target_auto_response=1 must be rejected by TL-owned bridge");
    cfg.target_auto_response = 1'b0;

    cfg.enable_svt_monitor = 1'b1;
    errors.delete();
    cfg.validate(errors);
    require(errors.size() != 0,
            "enable_svt_monitor=1 must be rejected for active backend");
    cfg.enable_svt_monitor = 1'b0;

    // These stage budgets belong to the (not-yet-present) TL orchestration
    // sequences, not to an R-2020.12 Device configuration field.  A nonzero
    // default is valid, but a changed value must be diagnosed until the
    // orchestration layer consumes it explicitly.
    cfg.cfg_timeout = 2ms;
    errors.delete();
    cfg.validate(errors);
    require(errors.size() != 0,
            "non-default cfg_timeout must be diagnosed as unsupported");
    cfg.cfg_timeout = 1ms;

    cfg.enum_timeout = 4ms;
    errors.delete();
    cfg.validate(errors);
    require(errors.size() != 0,
            "non-default enum_timeout must be diagnosed as unsupported");
    cfg.enum_timeout = 3ms;

    cfg.traffic_timeout = 2ms;
    errors.delete();
    cfg.validate(errors);
    require(errors.size() != 0,
            "non-default traffic_timeout must be diagnosed as unsupported");
    cfg.traffic_timeout = 1ms;

    // full_equalization_required is retained for source compatibility only;
    // eq_mode/enable_equalization are the actual SVT controls.
    cfg.full_equalization_required = 1'b0;
    errors.delete();
    cfg.validate(errors);
    require(errors.size() != 0,
            "non-default full_equalization_required must be diagnosed");
    cfg.full_equalization_required = 1'b1;

    // 配置对象允许声明 PIPE；这不代表自动 backend 已实现 PIPE。
    // validate() 只校验枚举，后续 backend 的能力检查仍可拒绝该模式。
    override_cfg.transport = PCIE_SVT_TRANSPORT_PIPE;
    cfg.validate(errors);
    require(errors.size() == 0,
            "PIPE override must be accepted after PIPE support landed");

    `uvm_info("SVT_CFG_CONTRACT",
      "SVT_BACKEND_CFG_CONTRACT_PASS: override precedence and Gen4 semantics",
      UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
