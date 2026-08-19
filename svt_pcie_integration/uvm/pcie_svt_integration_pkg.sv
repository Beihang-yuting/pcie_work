`include "pcie_svt_topology_checks.svh"

package pcie_svt_integration_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import svt_uvm_pkg::*;
  import svt_pcie_uvm_pkg::*;
  import pcie_tl_switch_pkg::*;

  `include "pcie_svt_profile.sv"
  `include "pcie_svt_profile_set.sv"
  `include "pcie_svt_cfg_space_builder.sv"
  `include "pcie_svt_tlp_converter.sv"
  `include "sequences/pcie_svt_raw_tlp_sequence.sv"
  `include "pcie_svt_switch_scoreboard.sv"
  `include "pcie_svt_switch_port_adapter.sv"
  `include "pcie_svt_switch_sidecar_subscriber.sv"
  `include "pcie_svt_switch_sidecar_env.sv"
  `include "pcie_svt_switch_target_callback.sv"

  function automatic pcie_svt_topology_e compiled_topology();
`ifdef PCIE_TOPO_EP_X16
    return PCIE_SVT_TOPO_EP_X16;
`elsif PCIE_TOPO_EP_2X8
    return PCIE_SVT_TOPO_EP_2X8;
`elsif PCIE_TOPO_SWITCH_1X16_4X4
    return PCIE_SVT_TOPO_SWITCH;
`else
    `error "PCIe topology contract: compiled_topology has no selected topology"
`endif
  endfunction

  // Future Task 4-10 files, kept in planned dependency order.
  `include "pcie_svt_virtual_sequencer.sv"
  `include "pcie_svt_port_env.sv"
  `include "pcie_svt_env.sv"
  `include "sequences/pcie_svt_cfg_space_init_seq.sv"
  `include "sequences/pcie_svt_all_cfg_spaces_init_vseq.sv"
  `include "sequences/pcie_svt_link_bringup_seq.sv"
  `include "sequences/pcie_svt_all_links_bringup_vseq.sv"
  // `include "sequences/pcie_svt_topology_enumeration_vseq.sv"
  // `include "sequences/pcie_svt_post_enum_enable_vseq.sv"
  `include "sequences/pcie_svt_peer_smoke_vseq.sv"
  `include "pcie_svt_base_test.sv"

  `include "pcie_svt_profile_unit_test.sv"
endpackage
