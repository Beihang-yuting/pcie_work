//------------------------------------------------------------------------------
// 兼容历史入口。
//
// 推荐的新测试直接继承 pcie_tl_vip 的 base test；该类只保留旧 DPU 入口
// 所需的 global_cfg/env 成员，并把环境实现收敛到 TL-root 兼容包装。
//------------------------------------------------------------------------------

class pcie_device_base_test extends uvm_test;
  `uvm_component_utils(pcie_device_base_test)

  pcie_global_cfg global_cfg;
  pcie_unified_env env;

  function new(string name = "pcie_device_base_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_global_cfg();
    global_cfg = pcie_global_cfg::type_id::create("global_cfg");
    global_cfg.build_default_for_topology(
      pcie_topology_builder::build_ep_x16(4));
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    build_global_cfg();
    uvm_config_db#(pcie_global_cfg)::set(
      this, "env", "global_cfg", global_cfg);
    env = pcie_unified_env::type_id::create("env", this);
  endfunction
endclass : pcie_device_base_test
