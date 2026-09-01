`ifndef PCIE_SVT_TOPOLOGY_CHECKS_SVH
`define PCIE_SVT_TOPOLOGY_CHECKS_SVH

// The active topology top supports either a placeholder/real DUT wrapper or
// the optional SVT peer harness.  The former Switch Proxy/sidecar mode was
// removed; no proxy-specific compile-time contract remains.
`ifdef PCIE_USE_REAL_SWITCH_DUT
  `ifndef PCIE_TOPO_SWITCH_1X16_4X4
    `error "PCIE_USE_REAL_SWITCH_DUT requires PCIE_TOPO_SWITCH_1X16_4X4"
  `endif
  `ifdef PCIE_USE_SVT_PEER
    `error "PCIE_USE_REAL_SWITCH_DUT and PCIE_USE_SVT_PEER are mutually exclusive"
  `endif
`endif

`ifdef PCIE_TOPO_EP_X16
  `ifdef PCIE_TOPO_EP_2X8
    `error "PCIe topology contract: define exactly one topology macro"
  `endif
  `ifdef PCIE_TOPO_SWITCH_1X16_4X4
    `error "PCIe topology contract: define exactly one topology macro"
  `endif
  `define PCIE_SVT_ACTIVE_PORTS 1
  `define PCIE_SVT_TOTAL_LANES 16
`elsif PCIE_TOPO_EP_2X8
  `ifdef PCIE_TOPO_SWITCH_1X16_4X4
    `error "PCIe topology contract: define exactly one topology macro"
  `endif
  `define PCIE_SVT_ACTIVE_PORTS 2
  `define PCIE_SVT_TOTAL_LANES 16
`elsif PCIE_TOPO_SWITCH_1X16_4X4
  `define PCIE_SVT_ACTIVE_PORTS 5
  `define PCIE_SVT_TOTAL_LANES 32
`else
  `error "PCIe topology contract: define one PCIE_TOPO_EP_X16, PCIE_TOPO_EP_2X8, or PCIE_TOPO_SWITCH_1X16_4X4"
`endif

`endif
