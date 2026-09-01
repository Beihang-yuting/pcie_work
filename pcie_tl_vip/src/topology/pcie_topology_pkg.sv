package pcie_topology_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // --------------------------------------------------------------------------
  // Core topology graph.
  // --------------------------------------------------------------------------
  `include "pcie_topology_types.sv"
  `include "pcie_topology_cfg.sv"
  `include "pcie_topology_builder.sv"

  // Backend-neutral policy types are included after the graph classes because
  // pcie_global_cfg references pcie_topology_cfg and its node/link records.
  `include "pcie_unified_backend_types.sv"
  `include "pcie_device_cfg.sv"
  `include "pcie_link_cfg.sv"
  `include "pcie_global_cfg.sv"
endpackage : pcie_topology_pkg
