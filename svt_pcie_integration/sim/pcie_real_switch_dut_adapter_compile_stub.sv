module pcie_real_switch_dut_adapter (
  input  logic [4:0] reset_asserted,
  input  logic [15:0] usp_rx_p, usp_rx_n,
  output logic [15:0] usp_tx_p, usp_tx_n,
  input  logic [3:0] dsp0_rx_p, dsp0_rx_n,
  output logic [3:0] dsp0_tx_p, dsp0_tx_n,
  input  logic [3:0] dsp1_rx_p, dsp1_rx_n,
  output logic [3:0] dsp1_tx_p, dsp1_tx_n,
  input  logic [3:0] dsp2_rx_p, dsp2_rx_n,
  output logic [3:0] dsp2_tx_p, dsp2_tx_n,
  input  logic [3:0] dsp3_rx_p, dsp3_rx_n,
  output logic [3:0] dsp3_tx_p, dsp3_tx_n
);
  assign usp_tx_p = '0;
  assign usp_tx_n = '1;
  assign dsp0_tx_p = '0;
  assign dsp0_tx_n = '1;
  assign dsp1_tx_p = '0;
  assign dsp1_tx_n = '1;
  assign dsp2_tx_p = '0;
  assign dsp2_tx_n = '1;
  assign dsp3_tx_p = '0;
  assign dsp3_tx_n = '1;
endmodule
