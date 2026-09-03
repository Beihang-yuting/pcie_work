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

    bridge_route_info_check();
    descriptor_root_mapping_check();

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

  function void bridge_route_info_check();
    pcie_svt_route_info route;

    route = pcie_svt_route_info_default();
    route.link_id = 3;
    route.link_name = "RC0_EP0";
    if (route.link_name != "RC0_EP0")
      `uvm_fatal("SVT_BRIDGE_TEST", "logical route link_name was lost")
  endfunction

  function void descriptor_root_mapping_check();
    pcie_topology_cfg topology;
    pcie_svt_topology_policy_cfg policy;
    pcie_svt_topology_adapter topology_adapter;
    pcie_svt_port_descriptor descriptors[$];
    string errors[$];

    // 反转物理 link 声明顺序，确认 bridge 发布应依赖 root_hierarchy，
    // 而不是动态 descriptor 数组下标。
    topology = pcie_topology_builder::build_ep_2x8(4);
    topology.links.reverse();
    policy = pcie_svt_topology_policy_cfg::type_id::create("root_policy");
    policy.init_defaults();
    policy.dut_node_ids.push_back("EP0");
    policy.dut_node_ids.push_back("EP1");
    topology_adapter = pcie_svt_topology_adapter::type_id::create(
      "root_adapter");
    topology_adapter.translate(topology, policy, descriptors, errors);
    if ((errors.size() != 0) || (descriptors.size() != 2) ||
        (descriptors[0].root_hierarchy != 0) ||
        (descriptors[1].root_hierarchy != 1))
      `uvm_fatal("SVT_BRIDGE_TEST",
        "descriptor root hierarchy changed with link declaration order")
  endfunction
endclass
