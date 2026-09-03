package pcie_svt_topology_pkg;
  import uvm_pkg::*;
  import pcie_topology_pkg::*;
  import pcie_tl_pkg::*;
  `include "import_pcie_svt_uvm_pkgs.svi"
  `include "uvm_macros.svh"
  `include "pcie_device_unified_vip_env.sv"
  `include "backend/pcie_backend_base.sv"
  `include "backend/pcie_svt_backend.sv"
  `include "backend/pcie_tl_backend.sv"
  `include "cfg/pcie_svt_backend_types.sv"
  `include "cfg/pcie_svt_device_cfg_builder.sv"
  `include "cfg/pcie_svt_cfg_space_builder.sv"
  `include "callbacks/pcie_svt_topology_ep_bar_sizing_callback.sv"
  `include "cfg/pcie_svt_topology_policy_cfg.sv"
  `include "adapter/pcie_svt_topology_adapter.sv"
  `include "adapter/pcie_svt_adapter_types.sv"
  `include "adapter/pcie_svt_tlp_codec.sv"
  `include "adapter/pcie_svt_tlp_mapper_bridge.sv"
  `include "adapter/pcie_svt_if_adapter.sv"
  `include "cfg/pcie_svt_cli_parser.sv"
  `include "cfg/pcie_svt_profile_factory.sv"
  `include "adapter/pcie_svt_peer_fixture_builder.sv"
  `include "env/pcie_svt_topology_virtual_sequencer.sv"
  `include "env/pcie_svt_topology_env.sv"
  `include "env/pcie_unified_env.sv"
  `include "sequences/pcie_svt_cfg_init_vseq.sv"
  `include "sequences/pcie_svt_link_vseq.sv"
  `include "sequences/pcie_svt_enumeration_registry.sv"
  `include "sequences/pcie_svt_enumeration_vseq.sv"
  `include "sequences/pcie_global_stage_vseq.sv"
  `include "tests/pcie_device_base_test.sv"

  function automatic string pcie_svt_compiled_profile_name();
`ifdef PCIE_TOPO_EP_X16
    return "EP_X16";
`elsif PCIE_TOPO_EP_2X8
    return "EP_2X8";
`elsif PCIE_TOPO_SWITCH_1X16_4X4
    return "SWITCH_1X16_4X4";
`else
    return "";
`endif
  endfunction
endpackage
