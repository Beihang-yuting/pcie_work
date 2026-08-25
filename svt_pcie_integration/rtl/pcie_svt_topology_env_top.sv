`define PCIE_SVT_TOPOLOGY_ENV_PATH
`include "pcie_svt_topology_checks.svh"
`include "pcie_svt_serial_adapter.sv"
`include "pcie_svt_hdl_agent_macros.svh"

module pcie_svt_topology_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "import_pcie_svt_uvm_pkgs.svi"
  `include `SVC_SOURCE_MAP_SUITE_UTIL_V(pcie_svc,PCIE,latest,svc_util_parms)
  `include `SVC_SOURCE_MAP_SUITE_MODEL_MODULE(pcie_svc,Include,latest,pciesvc_parms)

  int unsigned global_random_seed = 0;
  pciesvc_global_shadow #(.DISPLAY_NAME("global_shadow0.")) global_shadow0();
  tri1 [4:0] clkreq_n;
  tri1 wake_n;
  pcie_svt_reset_if reset_vif();

`ifdef PCIE_TOPO_EP_X16
  `PCIE_SVT_DECLARE_HDL_AGENT_X16(primary_rc0, "primary_rc0_spd.",
    clkreq_n[0], wake_n, reset_vif.asserted[0], 1, 0)

  pcie_svt_dut_wrapper #(.PORT0_WIDTH(16)) dut (
    .reset_asserted(reset_vif.asserted),
    .port0_tx_p(primary_rc0_serial.rx_p),
    .port0_tx_n(primary_rc0_serial.rx_n),
    .port0_rx_p(primary_rc0_serial.tx_p),
    .port0_rx_n(primary_rc0_serial.tx_n),
    .port1_tx_p('0), .port1_tx_n('1),
    .port1_rx_p(), .port1_rx_n(),
    .port2_tx_p('0), .port2_tx_n('1),
    .port2_rx_p(), .port2_rx_n(),
    .port3_tx_p('0), .port3_tx_n('1),
    .port3_rx_p(), .port3_rx_n(),
    .port4_tx_p('0), .port4_tx_n('1),
    .port4_rx_p(), .port4_rx_n()
  );

  initial begin
    primary_rc0_spd.update_if_variables(4'h0, 0,
      "uvm_test_top", "uvm_test_top");
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_vif_0", primary_rc0_if);
  end
`elsif PCIE_TOPO_EP_2X8
  `PCIE_SVT_DECLARE_HDL_AGENT_X8(primary_rc0, "primary_rc0_spd.",
    clkreq_n[0], wake_n, reset_vif.asserted[0], 1, 0)
  `PCIE_SVT_DECLARE_HDL_AGENT_X8(primary_rc1, "primary_rc1_spd.",
    clkreq_n[1], wake_n, reset_vif.asserted[1], 1, 1)

  pcie_svt_dut_wrapper #(
    .PORT0_WIDTH(8), .PORT1_WIDTH(8)
  ) dut (
    .reset_asserted(reset_vif.asserted),
    .port0_tx_p(primary_rc0_serial.rx_p),
    .port0_tx_n(primary_rc0_serial.rx_n),
    .port0_rx_p(primary_rc0_serial.tx_p),
    .port0_rx_n(primary_rc0_serial.tx_n),
    .port1_tx_p(primary_rc1_serial.rx_p),
    .port1_tx_n(primary_rc1_serial.rx_n),
    .port1_rx_p(primary_rc1_serial.tx_p),
    .port1_rx_n(primary_rc1_serial.tx_n),
    .port2_tx_p('0), .port2_tx_n('1),
    .port2_rx_p(), .port2_rx_n(),
    .port3_tx_p('0), .port3_tx_n('1),
    .port3_rx_p(), .port3_rx_n(),
    .port4_tx_p('0), .port4_tx_n('1),
    .port4_rx_p(), .port4_rx_n()
  );

  initial begin
    primary_rc0_spd.update_if_variables(4'h0, 0,
      "uvm_test_top", "uvm_test_top");
    primary_rc1_spd.update_if_variables(4'h0, 1,
      "uvm_test_top", "uvm_test_top");
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_vif_0", primary_rc0_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_vif_1", primary_rc1_if);
  end
`else
  `PCIE_SVT_DECLARE_HDL_AGENT_X16(primary_rc0, "primary_rc0_spd.",
    clkreq_n[0], wake_n, reset_vif.asserted[0], 1, 0)
  `PCIE_SVT_DECLARE_HDL_AGENT_X4(primary_ep0, "primary_ep0_spd.",
    clkreq_n[1], wake_n, reset_vif.asserted[1], 0, 0)
  `PCIE_SVT_DECLARE_HDL_AGENT_X4(primary_ep1, "primary_ep1_spd.",
    clkreq_n[2], wake_n, reset_vif.asserted[2], 0, 0)
  `PCIE_SVT_DECLARE_HDL_AGENT_X4(primary_ep2, "primary_ep2_spd.",
    clkreq_n[3], wake_n, reset_vif.asserted[3], 0, 0)
  `PCIE_SVT_DECLARE_HDL_AGENT_X4(primary_ep3, "primary_ep3_spd.",
    clkreq_n[4], wake_n, reset_vif.asserted[4], 0, 0)

  pcie_svt_dut_wrapper #(
    .PORT0_WIDTH(16), .PORT1_WIDTH(4), .PORT2_WIDTH(4),
    .PORT3_WIDTH(4), .PORT4_WIDTH(4)
  ) dut (
    .reset_asserted(reset_vif.asserted),
    .port0_tx_p(primary_rc0_serial.rx_p),
    .port0_tx_n(primary_rc0_serial.rx_n),
    .port0_rx_p(primary_rc0_serial.tx_p),
    .port0_rx_n(primary_rc0_serial.tx_n),
    .port1_tx_p(primary_ep0_serial.rx_p),
    .port1_tx_n(primary_ep0_serial.rx_n),
    .port1_rx_p(primary_ep0_serial.tx_p),
    .port1_rx_n(primary_ep0_serial.tx_n),
    .port2_tx_p(primary_ep1_serial.rx_p),
    .port2_tx_n(primary_ep1_serial.rx_n),
    .port2_rx_p(primary_ep1_serial.tx_p),
    .port2_rx_n(primary_ep1_serial.tx_n),
    .port3_tx_p(primary_ep2_serial.rx_p),
    .port3_tx_n(primary_ep2_serial.rx_n),
    .port3_rx_p(primary_ep2_serial.tx_p),
    .port3_rx_n(primary_ep2_serial.tx_n),
    .port4_tx_p(primary_ep3_serial.rx_p),
    .port4_tx_n(primary_ep3_serial.rx_n),
    .port4_rx_p(primary_ep3_serial.tx_p),
    .port4_rx_n(primary_ep3_serial.tx_n)
  );

  initial begin
    primary_rc0_spd.update_if_variables(4'h0, 0,
      "uvm_test_top", "uvm_test_top");
    primary_ep0_spd.update_if_variables(4'h1, 1,
      "uvm_test_top", "uvm_test_top");
    primary_ep1_spd.update_if_variables(4'h1, 2,
      "uvm_test_top", "uvm_test_top");
    primary_ep2_spd.update_if_variables(4'h1, 3,
      "uvm_test_top", "uvm_test_top");
    primary_ep3_spd.update_if_variables(4'h1, 4,
      "uvm_test_top", "uvm_test_top");
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_vif_0", primary_rc0_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_vif_1", primary_ep0_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_vif_2", primary_ep1_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_vif_3", primary_ep2_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_vif_4", primary_ep3_if);
    // Retain the Task-4 unit-test aliases while the new topology keys are the
    // sole production-environment binding contract.
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_rc0_vif", primary_rc0_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_ep0_vif", primary_ep0_if);
  end
`endif

  initial begin
    uvm_config_db#(virtual pcie_svt_reset_if)::set(null, "uvm_test_top",
      "primary_reset_vif", reset_vif);
  end

  initial begin
    repeat (100) #0;
    run_test();
  end
endmodule
