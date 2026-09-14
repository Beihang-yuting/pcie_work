`timescale 1ns/1ps

`include "pcie_svt_serial_port_if.sv"

module pcie_svt_dut_pad_adapter_compile;
  // Match the documented real-DUT usage: the macro header is included from
  // the top module after the SVT/Serial interfaces are available.
  `include "pcie_svt_hdl_agent_macros.svh"

  // Scalar DUT pad declarations.  The binder under test expands these names
  // for both 16-lane pad groups.
  wire pad0_phy_rx0_p,  pad0_phy_rx1_p,  pad0_phy_rx2_p,  pad0_phy_rx3_p;
  wire pad0_phy_rx4_p,  pad0_phy_rx5_p,  pad0_phy_rx6_p,  pad0_phy_rx7_p;
  wire pad0_phy_rx8_p,  pad0_phy_rx9_p,  pad0_phy_rx10_p, pad0_phy_rx11_p;
  wire pad0_phy_rx12_p, pad0_phy_rx13_p, pad0_phy_rx14_p, pad0_phy_rx15_p;
  wire pad0_phy_rx0_m,  pad0_phy_rx1_m,  pad0_phy_rx2_m,  pad0_phy_rx3_m;
  wire pad0_phy_rx4_m,  pad0_phy_rx5_m,  pad0_phy_rx6_m,  pad0_phy_rx7_m;
  wire pad0_phy_rx8_m,  pad0_phy_rx9_m,  pad0_phy_rx10_m, pad0_phy_rx11_m;
  wire pad0_phy_rx12_m, pad0_phy_rx13_m, pad0_phy_rx14_m, pad0_phy_rx15_m;
  logic pad0_phy_tx0_p,  pad0_phy_tx1_p,  pad0_phy_tx2_p,  pad0_phy_tx3_p;
  logic pad0_phy_tx4_p,  pad0_phy_tx5_p,  pad0_phy_tx6_p,  pad0_phy_tx7_p;
  logic pad0_phy_tx8_p,  pad0_phy_tx9_p,  pad0_phy_tx10_p, pad0_phy_tx11_p;
  logic pad0_phy_tx12_p, pad0_phy_tx13_p, pad0_phy_tx14_p, pad0_phy_tx15_p;
  logic pad0_phy_tx0_m,  pad0_phy_tx1_m,  pad0_phy_tx2_m,  pad0_phy_tx3_m;
  logic pad0_phy_tx4_m,  pad0_phy_tx5_m,  pad0_phy_tx6_m,  pad0_phy_tx7_m;
  logic pad0_phy_tx8_m,  pad0_phy_tx9_m,  pad0_phy_tx10_m, pad0_phy_tx11_m;
  logic pad0_phy_tx12_m, pad0_phy_tx13_m, pad0_phy_tx14_m, pad0_phy_tx15_m;

  wire pad1_phy_rx0_p,  pad1_phy_rx1_p,  pad1_phy_rx2_p,  pad1_phy_rx3_p;
  wire pad1_phy_rx4_p,  pad1_phy_rx5_p,  pad1_phy_rx6_p,  pad1_phy_rx7_p;
  wire pad1_phy_rx8_p,  pad1_phy_rx9_p,  pad1_phy_rx10_p, pad1_phy_rx11_p;
  wire pad1_phy_rx12_p, pad1_phy_rx13_p, pad1_phy_rx14_p, pad1_phy_rx15_p;
  wire pad1_phy_rx0_m,  pad1_phy_rx1_m,  pad1_phy_rx2_m,  pad1_phy_rx3_m;
  wire pad1_phy_rx4_m,  pad1_phy_rx5_m,  pad1_phy_rx6_m,  pad1_phy_rx7_m;
  wire pad1_phy_rx8_m,  pad1_phy_rx9_m,  pad1_phy_rx10_m, pad1_phy_rx11_m;
  wire pad1_phy_rx12_m, pad1_phy_rx13_m, pad1_phy_rx14_m, pad1_phy_rx15_m;
  logic pad1_phy_tx0_p,  pad1_phy_tx1_p,  pad1_phy_tx2_p,  pad1_phy_tx3_p;
  logic pad1_phy_tx4_p,  pad1_phy_tx5_p,  pad1_phy_tx6_p,  pad1_phy_tx7_p;
  logic pad1_phy_tx8_p,  pad1_phy_tx9_p,  pad1_phy_tx10_p, pad1_phy_tx11_p;
  logic pad1_phy_tx12_p, pad1_phy_tx13_p, pad1_phy_tx14_p, pad1_phy_tx15_p;
  logic pad1_phy_tx0_m,  pad1_phy_tx1_m,  pad1_phy_tx2_m,  pad1_phy_tx3_m;
  logic pad1_phy_tx4_m,  pad1_phy_tx5_m,  pad1_phy_tx6_m,  pad1_phy_tx7_m;
  logic pad1_phy_tx8_m,  pad1_phy_tx9_m,  pad1_phy_tx10_m, pad1_phy_tx11_m;
  logic pad1_phy_tx12_m, pad1_phy_tx13_m, pad1_phy_tx14_m, pad1_phy_tx15_m;

  pcie_svt_serial_port_if #(16) pad0_if();
  pcie_svt_serial_port_if #(16) pad1_if();
  pcie_svt_serial_port_if #(4)  svt_x4();
  pcie_svt_serial_port_if #(8)  svt_x8();
  pcie_svt_serial_port_if #(16) svt_x16();

  `PCIE_SVT_BIND_PAD16_SCALAR(pad0_if, pad0)
  `PCIE_SVT_BIND_PAD16_SCALAR(pad1_if, pad1)
  `PCIE_SVT_CONNECT_DUT_SERDES_X4 (svt_x4,  pad0_if, 0)
  `PCIE_SVT_CONNECT_DUT_SERDES_X8 (svt_x8,  pad0_if, 4)
  `PCIE_SVT_CONNECT_DUT_SERDES_X16(svt_x16, pad1_if, 0)

  initial begin
    svt_x4.rx_p  = 4'b1101;
    svt_x4.rx_n  = 4'b0010;
    svt_x8.rx_p  = 8'b1010_0110;
    svt_x8.rx_n  = 8'b0101_1001;
    svt_x16.rx_p = 16'ha55a;
    svt_x16.rx_n = 16'h5aa5;

    pad0_phy_tx4_p  = 1'b1;
    pad0_phy_tx5_p  = 1'b0;
    pad0_phy_tx6_p  = 1'b1;
    pad0_phy_tx7_p  = 1'b1;
    pad0_phy_tx8_p  = 1'b0;
    pad0_phy_tx9_p  = 1'b1;
    pad0_phy_tx10_p = 1'b0;
    pad0_phy_tx11_p = 1'b0;
    pad0_phy_tx4_m  = 1'b0;
    pad0_phy_tx5_m  = 1'b1;
    pad0_phy_tx6_m  = 1'b0;
    pad0_phy_tx7_m  = 1'b0;
    pad0_phy_tx8_m  = 1'b1;
    pad0_phy_tx9_m  = 1'b0;
    pad0_phy_tx10_m = 1'b1;
    pad0_phy_tx11_m = 1'b1;

    pad1_phy_tx0_p  = 1'b1;
    pad1_phy_tx1_p  = 1'b0;
    pad1_phy_tx2_p  = 1'b1;
    pad1_phy_tx3_p  = 1'b0;
    pad1_phy_tx4_p  = 1'b0;
    pad1_phy_tx5_p  = 1'b1;
    pad1_phy_tx6_p  = 1'b0;
    pad1_phy_tx7_p  = 1'b1;
    pad1_phy_tx8_p  = 1'b1;
    pad1_phy_tx9_p  = 1'b0;
    pad1_phy_tx10_p = 1'b1;
    pad1_phy_tx11_p = 1'b0;
    pad1_phy_tx12_p = 1'b0;
    pad1_phy_tx13_p = 1'b1;
    pad1_phy_tx14_p = 1'b0;
    pad1_phy_tx15_p = 1'b1;
    pad1_phy_tx0_m  = 1'b0;
    pad1_phy_tx1_m  = 1'b1;
    pad1_phy_tx2_m  = 1'b0;
    pad1_phy_tx3_m  = 1'b1;
    pad1_phy_tx4_m  = 1'b1;
    pad1_phy_tx5_m  = 1'b0;
    pad1_phy_tx6_m  = 1'b1;
    pad1_phy_tx7_m  = 1'b0;
    pad1_phy_tx8_m  = 1'b0;
    pad1_phy_tx9_m  = 1'b1;
    pad1_phy_tx10_m = 1'b0;
    pad1_phy_tx11_m = 1'b1;
    pad1_phy_tx12_m = 1'b1;
    pad1_phy_tx13_m = 1'b0;
    pad1_phy_tx14_m = 1'b1;
    pad1_phy_tx15_m = 1'b0;

    #1;
    if ({pad0_phy_rx3_p, pad0_phy_rx2_p, pad0_phy_rx1_p, pad0_phy_rx0_p} !== 4'b1101)
      $fatal(1, "x4 SVT TX -> DUT RX positive direction failed");
    if ({pad0_phy_rx7_p, pad0_phy_rx6_p, pad0_phy_rx5_p, pad0_phy_rx4_p} !== 4'b0110)
      $fatal(1, "x8 base-lane slice failed");
    if ({pad0_phy_rx11_p, pad0_phy_rx10_p, pad0_phy_rx9_p, pad0_phy_rx8_p} !== 4'b1010)
      $fatal(1, "x8 upper-lane slice failed");
    if ({pad1_phy_rx15_p, pad1_phy_rx14_p, pad1_phy_rx13_p, pad1_phy_rx12_p,
         pad1_phy_rx11_p, pad1_phy_rx10_p, pad1_phy_rx9_p, pad1_phy_rx8_p,
         pad1_phy_rx7_p, pad1_phy_rx6_p, pad1_phy_rx5_p, pad1_phy_rx4_p,
         pad1_phy_rx3_p, pad1_phy_rx2_p, pad1_phy_rx1_p, pad1_phy_rx0_p} !== 16'ha55a)
      $fatal(1, "x16 SVT TX -> DUT RX direction failed");
    if (svt_x8.tx_p !== 8'b0010_1101 || svt_x8.tx_n !== 8'b1101_0010)
      $fatal(1, "x8 DUT TX -> SVT RX direction failed");
    if (svt_x16.tx_p !== 16'b1010_0101_1010_0101 ||
        svt_x16.tx_n !== 16'b0101_1010_0101_1010)
      $fatal(1, "x16 DUT TX -> SVT RX direction failed");
    $display("PCIE_SVT_DUT_PAD_ADAPTER_COMPILE_PASS");
    $finish;
  end
endmodule
