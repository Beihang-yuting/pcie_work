`ifndef PCIE_SVT_PEER_HARNESS_SV
`define PCIE_SVT_PEER_HARNESS_SV

// Cross-connect two framework Serial adapters exactly as the R-2020.12
// SVT_PCIE_ICM_SER_SER_LINK macro connects two Unified VIP instances.  Keeping
// this mapping at the adapter boundary exercises the same DUT-facing signals
// that the real controller will use.
`define PCIE_SVT_CONNECT_SERIAL_PEERS(primary_port, peer_port) \
  assign peer_port.tx_p = primary_port.rx_p; \
  assign peer_port.tx_n = primary_port.rx_n; \
  assign primary_port.tx_p = peer_port.rx_p; \
  assign primary_port.tx_n = peer_port.rx_n; \
  assign primary_port.rx_clk = peer_port.active_tx_transmit_clk; \
  assign primary_port.tx_clk = peer_port.active_rx_recovered_clk; \
  assign peer_port.rx_clk = primary_port.active_tx_transmit_clk; \
  assign peer_port.tx_clk = primary_port.active_rx_recovered_clk;

`endif
