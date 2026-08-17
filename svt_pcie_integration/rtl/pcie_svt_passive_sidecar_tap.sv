`ifndef PCIE_SVT_PASSIVE_SIDECAR_TAP_SV
`define PCIE_SVT_PASSIVE_SIDECAR_TAP_SV

// The standalone monitor is oriented as the monitored Proxy port:
//   monitor RX samples peer -> Proxy traffic;
//   monitor TX samples Proxy -> peer traffic.
// Every assignment terminates on the standalone monitor interface. Nothing
// in this macro drives the active Serial port or an active SVT interface.
`define PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, lane) \
  assign mon_if.rx_clk_``lane``   = proxy_port.rx_clk[lane]; \
  assign mon_if.rx_datap_``lane`` = proxy_port.tx_p[lane]; \
  assign mon_if.rx_datan_``lane`` = proxy_port.tx_n[lane]; \
  assign mon_if.tx_clk_``lane``   = proxy_port.active_tx_transmit_clk[lane]; \
  assign mon_if.tx_datap_``lane`` = proxy_port.rx_p[lane]; \
  assign mon_if.tx_datan_``lane`` = proxy_port.rx_n[lane];

`define PCIE_SVT_TAP_PASSIVE_SERDES_X4(mon_if, proxy_port) \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 0) \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 1) \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 2) \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 3)

`endif
