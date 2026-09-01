//------------------------------------------------------------------------------
// Shared compile-time limits for the backend-neutral PCIe configuration.
//
// This header is intentionally independent of Synopsys SVT.  TL-only builds
// include pcie_global_cfg.sv without compiling the SVT RTL headers, so the
// limits used by global policy validation must have a common definition.
// Users may override either macro from the VCS command line before compiling.
//------------------------------------------------------------------------------

`ifndef PCIE_SVT_ENV_MAX_HDL_AGENTS
  // Prefer the SVT elaboration layer's exact requirement when it is already
  // available.  TL-only builds instead derive a conservative topology limit.
  `ifdef PCIE_SVT_ENV_REQUIRED_HDL_AGENTS
    `define PCIE_SVT_ENV_MAX_HDL_AGENTS `PCIE_SVT_ENV_REQUIRED_HDL_AGENTS
  `elsif PCIE_TOPO_EP_X16
    `define PCIE_SVT_ENV_MAX_HDL_AGENTS 1
  `elsif PCIE_TOPO_EP_2X8
    `define PCIE_SVT_ENV_MAX_HDL_AGENTS 2
  `elsif PCIE_TOPO_SWITCH_1X16_4X4
    `define PCIE_SVT_ENV_MAX_HDL_AGENTS 5
  `else
    `define PCIE_SVT_ENV_MAX_HDL_AGENTS 5
  `endif
`endif

`ifndef PCIE_SVT_ENV_MAX_NUM_LINKS
  // Runtime policy cannot enable more links than the compiled HDL budget.
  `define PCIE_SVT_ENV_MAX_NUM_LINKS `PCIE_SVT_ENV_MAX_HDL_AGENTS
`endif
