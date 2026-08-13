package pcie_svt_integration_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import svt_uvm_pkg::*;
  import svt_pcie_uvm_pkg::*;

  `include "pcie_svt_profile.sv"
  `include "pcie_svt_profile_set.sv"

  // Future Task 4-10 files, kept in planned dependency order.
  // `include "pcie_svt_cfg_space_builder.sv"
  // `include "pcie_svt_virtual_sequencer.sv"
  // `include "pcie_svt_port_env.sv"
  // `include "pcie_svt_env.sv"
  // `include "sequences/pcie_svt_cfg_space_init_seq.sv"
  // `include "sequences/pcie_svt_all_cfg_spaces_init_vseq.sv"
  // `include "sequences/pcie_svt_link_bringup_seq.sv"
  // `include "sequences/pcie_svt_all_links_bringup_vseq.sv"
  // `include "sequences/pcie_svt_topology_enumeration_vseq.sv"
  // `include "sequences/pcie_svt_post_enum_enable_vseq.sv"
  // `include "sequences/pcie_svt_peer_smoke_vseq.sv"
  // `include "pcie_svt_base_test.sv"

  `include "pcie_svt_profile_unit_test.sv"
endpackage
