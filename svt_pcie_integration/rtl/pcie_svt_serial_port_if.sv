interface pcie_svt_serial_port_if #(int LANES = 1);
  logic [LANES-1:0] rx_p;
  logic [LANES-1:0] rx_n;
  logic [LANES-1:0] tx_p;
  logic [LANES-1:0] tx_n;
  logic [LANES-1:0] tx_clk;
  logic [LANES-1:0] rx_clk;
  logic [LANES-1:0] active_tx_transmit_clk;
  logic [LANES-1:0] active_rx_recovered_clk;
endinterface
