package pcie_svt_topology_pkg;
  import uvm_pkg::*;
  import pcie_topology_pkg::*;
  `include "import_pcie_svt_uvm_pkgs.svi"
  `include "uvm_macros.svh"
  `include "pcie_device_unified_vip_env.sv"
  `include "cfg/pcie_svt_backend_types.sv"
  `include "cfg/pcie_svt_device_cfg_builder.sv"
  `include "cfg/pcie_svt_cfg_space_builder.sv"
  `include "cfg/pcie_svt_topology_policy_cfg.sv"
  `include "adapter/pcie_svt_topology_adapter.sv"
  `include "cfg/pcie_svt_cli_parser.sv"
  `include "cfg/pcie_svt_profile_factory.sv"
  `include "adapter/pcie_svt_peer_fixture_builder.sv"

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
