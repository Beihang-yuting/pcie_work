`ifdef PCIE_TOPO_SWITCH_1X16_4X4
module pcie_switch_dut_wrapper (
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
`ifdef PCIE_USE_REAL_SWITCH_DUT
  pcie_real_switch_dut_adapter dut_adapter (.*);
`else
  pcie_dut_placeholder idle_dut (
    .reset(|reset_asserted),
    .usp_rx_p(usp_rx_p), .usp_rx_n(usp_rx_n),
    .usp_tx_p(usp_tx_p), .usp_tx_n(usp_tx_n),
    .dsp0_rx_p(dsp0_rx_p), .dsp0_rx_n(dsp0_rx_n),
    .dsp0_tx_p(dsp0_tx_p), .dsp0_tx_n(dsp0_tx_n),
    .dsp1_rx_p(dsp1_rx_p), .dsp1_rx_n(dsp1_rx_n),
    .dsp1_tx_p(dsp1_tx_p), .dsp1_tx_n(dsp1_tx_n),
    .dsp2_rx_p(dsp2_rx_p), .dsp2_rx_n(dsp2_rx_n),
    .dsp2_tx_p(dsp2_tx_p), .dsp2_tx_n(dsp2_tx_n),
    .dsp3_rx_p(dsp3_rx_p), .dsp3_rx_n(dsp3_rx_n),
    .dsp3_tx_p(dsp3_tx_p), .dsp3_tx_n(dsp3_tx_n)
  );
`endif
endmodule
`endif
