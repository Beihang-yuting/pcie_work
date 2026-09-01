//------------------------------------------------------------------------------
// Compile-time limit for project-owned SVT HDL slots.
//
// This is intentionally different from Synopsys' SVT_PCIE_MAX_NUM_LINKS.  The
// project macro controls statically elaborated agent slots; runtime UVM policy
// may enable fewer links but cannot create more slots.
//------------------------------------------------------------------------------
`ifndef PCIE_SVT_ENV_REQUIRED_HDL_AGENTS
  `ifdef PCIE_TOPO_EP_X16
    `define PCIE_SVT_ENV_BASE_HDL_AGENTS 1
  `elsif PCIE_TOPO_EP_2X8
    `define PCIE_SVT_ENV_BASE_HDL_AGENTS 2
  `elsif PCIE_TOPO_SWITCH_1X16_4X4
    `define PCIE_SVT_ENV_BASE_HDL_AGENTS 5
  `else
    `define PCIE_SVT_ENV_BASE_HDL_AGENTS 5
  `endif
  `ifdef PCIE_USE_SVT_PEER
    `define PCIE_SVT_ENV_REQUIRED_HDL_AGENTS (2 * `PCIE_SVT_ENV_BASE_HDL_AGENTS)
  `else
    `define PCIE_SVT_ENV_REQUIRED_HDL_AGENTS `PCIE_SVT_ENV_BASE_HDL_AGENTS
  `endif
`endif

// Pull in the shared maximums after computing the SVT-specific requirement.
// This preserves automatic doubling when PCIE_USE_SVT_PEER is compiled.
`include "pcie_unified_limits.svh"

// The common header supplies the maximum-slot default.  The required count
// remains separate because peer mode may need twice as many static agents.
