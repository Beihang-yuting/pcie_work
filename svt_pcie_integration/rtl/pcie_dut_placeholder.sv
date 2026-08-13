module pcie_dut_placeholder (
`ifdef PCIE_TOPO_EP_X16
  input logic reset,
  input logic [15:0] ep0_rx_p, ep0_rx_n,
  output logic [15:0] ep0_tx_p, ep0_tx_n
`elsif PCIE_TOPO_EP_2X8
  input logic reset,
  input logic [7:0] ep0_rx_p, ep0_rx_n,
  output logic [7:0] ep0_tx_p, ep0_tx_n,
  input logic [7:0] ep1_rx_p, ep1_rx_n,
  output logic [7:0] ep1_tx_p, ep1_tx_n
`else
  input logic reset,
  input logic [15:0] usp_rx_p, usp_rx_n,
  output logic [15:0] usp_tx_p, usp_tx_n,
  input logic [3:0] dsp0_rx_p, dsp0_rx_n,
  output logic [3:0] dsp0_tx_p, dsp0_tx_n,
  input logic [3:0] dsp1_rx_p, dsp1_rx_n,
  output logic [3:0] dsp1_tx_p, dsp1_tx_n,
  input logic [3:0] dsp2_rx_p, dsp2_rx_n,
  output logic [3:0] dsp2_tx_p, dsp2_tx_n,
  input logic [3:0] dsp3_rx_p, dsp3_rx_n,
  output logic [3:0] dsp3_tx_p, dsp3_tx_n
`endif
);
`ifdef PCIE_TOPO_EP_X16
  assign ep0_tx_p = '0;
  assign ep0_tx_n = '1;
`elsif PCIE_TOPO_EP_2X8
  assign ep0_tx_p = '0;
  assign ep0_tx_n = '1;
  assign ep1_tx_p = '0;
  assign ep1_tx_n = '1;
`else
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
`endif
endmodule
