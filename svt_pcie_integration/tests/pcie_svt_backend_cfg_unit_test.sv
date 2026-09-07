//------------------------------------------------------------------------------
// SVT backend 配置对象契约测试。
//
// 该测试不创建 SVT agent，也不依赖物理 Serial 链路；它只锁定 backend
// 配置层的优先级和 Gen4 快速建链语义。这样配置错误会在 agent 创建前被
// 发现，避免把一个纯策略问题误判成链路训练问题。
//------------------------------------------------------------------------------

`include "uvm_macros.svh"

import uvm_pkg::*;
import pcie_tl_pkg::*;
import pcie_topology_pkg::*;
import pcie_svt_adapter_pkg::*;

class pcie_svt_backend_cfg_unit_test extends uvm_test;
  `uvm_component_utils(pcie_svt_backend_cfg_unit_test)

  function new(string name = "pcie_svt_backend_cfg_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void require(bit condition, string message);
    if (!condition)
      `uvm_fatal("SVT_CFG_CONTRACT", message)
  endfunction

  task run_phase(uvm_phase phase);
    pcie_svt_backend_cfg cfg;
    pcie_svt_link_override_cfg override_cfg;
    pcie_link_cfg link;
    pcie_svt_transport_e transport;
    bit equalization;
    int unsigned eq_mode;
    bit direct_speedup;
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

    // PIPE 仍是显式未实现路径，必须由 validate() 报出，而不是静默降级
    // 成 Serial。
    override_cfg.transport = PCIE_SVT_TRANSPORT_PIPE;
    cfg.validate(errors);
    require(errors.size() != 0,
            "PIPE override must be rejected during configuration validation");

    `uvm_info("SVT_CFG_CONTRACT",
      "SVT_BACKEND_CFG_CONTRACT_PASS: override precedence and Gen4 semantics",
      UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
