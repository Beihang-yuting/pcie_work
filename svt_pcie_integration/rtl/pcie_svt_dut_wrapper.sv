module pcie_svt_dut_wrapper #(
  parameter int unsigned RESET_WIDTH = 5,
  parameter int unsigned PORT0_WIDTH = 16,
  parameter int unsigned PORT1_WIDTH = 4,
  parameter int unsigned PORT2_WIDTH = 4,
  parameter int unsigned PORT3_WIDTH = 4,
  parameter int unsigned PORT4_WIDTH = 4
) (
  input  logic [RESET_WIDTH-1:0] reset_asserted,
  input  logic [PORT0_WIDTH-1:0] port0_tx_p,
  input  logic [PORT0_WIDTH-1:0] port0_tx_n,
  output logic [PORT0_WIDTH-1:0] port0_rx_p,
  output logic [PORT0_WIDTH-1:0] port0_rx_n,
  input  logic [PORT1_WIDTH-1:0] port1_tx_p,
  input  logic [PORT1_WIDTH-1:0] port1_tx_n,
  output logic [PORT1_WIDTH-1:0] port1_rx_p,
  output logic [PORT1_WIDTH-1:0] port1_rx_n,
  input  logic [PORT2_WIDTH-1:0] port2_tx_p,
  input  logic [PORT2_WIDTH-1:0] port2_tx_n,
  output logic [PORT2_WIDTH-1:0] port2_rx_p,
  output logic [PORT2_WIDTH-1:0] port2_rx_n,
  input  logic [PORT3_WIDTH-1:0] port3_tx_p,
  input  logic [PORT3_WIDTH-1:0] port3_tx_n,
  output logic [PORT3_WIDTH-1:0] port3_rx_p,
  output logic [PORT3_WIDTH-1:0] port3_rx_n,
  input  logic [PORT4_WIDTH-1:0] port4_tx_p,
  input  logic [PORT4_WIDTH-1:0] port4_tx_n,
  output logic [PORT4_WIDTH-1:0] port4_rx_p,
  output logic [PORT4_WIDTH-1:0] port4_rx_n
);
  // A legal differential electrical-idle termination.  This placeholder does
  // not loop back or forward symbols, so no link can train through it.
  always_comb begin
    port0_rx_p = '0;
    port0_rx_n = '1;
    port1_rx_p = '0;
    port1_rx_n = '1;
    port2_rx_p = '0;
    port2_rx_n = '1;
    port3_rx_p = '0;
    port3_rx_n = '1;
    port4_rx_p = '0;
    port4_rx_n = '1;
  end
endmodule
