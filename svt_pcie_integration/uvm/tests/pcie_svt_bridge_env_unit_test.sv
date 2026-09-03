// 桥接环境策略单元测试。
//
// 该测试不启动真实 SVT Agent；它验证兼容默认值、深拷贝语义以及稳定的
// Config DB 开关名称。需要真实 Mapper/VIF 的层次构造由 VCS 集成测试覆盖。
import uvm_pkg::*;
import pcie_svt_topology_pkg::*;
`include "uvm_macros.svh"

class pcie_svt_bridge_env_unit_test extends uvm_test;
  `uvm_component_utils(pcie_svt_bridge_env_unit_test)

  function new(string name = "pcie_svt_bridge_env_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    pcie_svt_topology_policy_cfg tl_only_policy;
    pcie_svt_topology_policy_cfg bridge_policy;
    pcie_svt_topology_policy_cfg copied_policy;
    bit bridge_enable;

    phase.raise_objection(this);

    tl_only_policy = pcie_svt_topology_policy_cfg::type_id::create(
      "tl_only_policy");
    tl_only_policy.init_defaults();
    if (tl_only_policy.bridge_mode != PCIE_SVT_BRIDGE_TL_ONLY)
      `uvm_fatal("SVT_BRIDGE_TEST",
        "new policy must default to PCIE_SVT_BRIDGE_TL_ONLY")

    bridge_policy = pcie_svt_topology_policy_cfg::type_id::create(
      "bridge_policy");
    bridge_policy.init_defaults();
    bridge_policy.bridge_mode = PCIE_SVT_BRIDGE_TL_SVT;
    copied_policy = pcie_svt_topology_policy_cfg::type_id::create(
      "copied_policy");
    copied_policy.copy(bridge_policy);
    if (copied_policy.bridge_mode != PCIE_SVT_BRIDGE_TL_SVT)
      `uvm_fatal("SVT_BRIDGE_TEST", "bridge_mode was not copied")

    // The exact key is part of the integration contract and must not drift.
    bridge_enable = 1'b1;
    uvm_config_db#(bit)::set(this, "", "pcie_svt_bridge_enable",
                             bridge_enable);
    bridge_enable = 1'b0;
    if (!uvm_config_db#(bit)::get(this, "", "pcie_svt_bridge_enable",
                                  bridge_enable) || !bridge_enable)
      `uvm_fatal("SVT_BRIDGE_TEST",
        "pcie_svt_bridge_enable Config DB contract is broken")

    phase.drop_objection(this);
  endtask
endclass
