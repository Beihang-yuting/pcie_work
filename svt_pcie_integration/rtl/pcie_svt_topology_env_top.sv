`define PCIE_SVT_TOPOLOGY_ENV_PATH
`include "pcie_svt_hdl_slot_cfg.svh"
`include "pcie_svt_topology_checks.svh"
`include "pcie_svt_serial_adapter.sv"
`include "pcie_svt_hdl_agent_macros.svh"
`include "pcie_svt_peer_harness.sv"

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

  // See pcie_svt_topology_top: static slot limits are checked before UVM.
  initial begin
    if (`PCIE_SVT_ENV_MAX_HDL_AGENTS <
        `PCIE_SVT_ENV_REQUIRED_HDL_AGENTS)
      $fatal(1, "PCIE_SVT_ENV_MAX_HDL_AGENTS=%0d below required slots=%0d",
             `PCIE_SVT_ENV_MAX_HDL_AGENTS,
             `PCIE_SVT_ENV_REQUIRED_HDL_AGENTS);
  end
`ifdef PCIE_USE_SVT_PEER
  pcie_svt_reset_if peer_reset_vif();
`endif

`ifdef PCIE_TOPO_EP_X16
  `PCIE_SVT_DECLARE_HDL_AGENT_X16(primary_rc0, "primary_rc0_spd.",
    clkreq_n[0], wake_n, reset_vif.asserted[0], 1, 0)

`ifdef PCIE_USE_SVT_PEER
  `PCIE_SVT_DECLARE_HDL_AGENT_X16(peer_ep0, "peer_ep0_spd.",
    clkreq_n[0], wake_n, peer_reset_vif.asserted[0], 0, 0)
  `PCIE_SVT_CONNECT_SERIAL_PEERS(primary_rc0_serial, peer_ep0_serial)
`else
  pcie_svt_dut_wrapper #(
    .RESET_WIDTH($bits(reset_vif.asserted)), .PORT0_WIDTH(16)
  ) dut (
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
`endif

  initial begin
    primary_rc0_spd.update_if_variables(4'h0, 0,
      "uvm_test_top", "uvm_test_top");
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_vif_0", primary_rc0_if);
`ifdef PCIE_USE_SVT_PEER
    peer_ep0_spd.update_if_variables(4'h1, 0,
      "uvm_test_top", "uvm_test_top");
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "peer_vif_0", peer_ep0_if);
`endif
  end
`elsif PCIE_TOPO_EP_2X8
  `PCIE_SVT_DECLARE_HDL_AGENT_X8(primary_rc0, "primary_rc0_spd.",
    clkreq_n[0], wake_n, reset_vif.asserted[0], 1, 0)
  `PCIE_SVT_DECLARE_HDL_AGENT_X8(primary_rc1, "primary_rc1_spd.",
    clkreq_n[1], wake_n, reset_vif.asserted[1], 1, 1)

`ifdef PCIE_USE_SVT_PEER
  `PCIE_SVT_DECLARE_HDL_AGENT_X8(peer_ep0, "peer_ep0_spd.",
    clkreq_n[0], wake_n, peer_reset_vif.asserted[0], 0, 0)
  `PCIE_SVT_DECLARE_HDL_AGENT_X8(peer_ep1, "peer_ep1_spd.",
    clkreq_n[1], wake_n, peer_reset_vif.asserted[1], 0, 1)
  `PCIE_SVT_CONNECT_SERIAL_PEERS(primary_rc0_serial, peer_ep0_serial)
  `PCIE_SVT_CONNECT_SERIAL_PEERS(primary_rc1_serial, peer_ep1_serial)
`else
  pcie_svt_dut_wrapper #(
    .RESET_WIDTH($bits(reset_vif.asserted)),
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
`endif

  initial begin
    primary_rc0_spd.update_if_variables(4'h0, 0,
      "uvm_test_top", "uvm_test_top");
    primary_rc1_spd.update_if_variables(4'h0, 1,
      "uvm_test_top", "uvm_test_top");
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_vif_0", primary_rc0_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_vif_1", primary_rc1_if);
`ifdef PCIE_USE_SVT_PEER
    peer_ep0_spd.update_if_variables(4'h1, 0,
      "uvm_test_top", "uvm_test_top");
    peer_ep1_spd.update_if_variables(4'h1, 1,
      "uvm_test_top", "uvm_test_top");
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "peer_vif_0", peer_ep0_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "peer_vif_1", peer_ep1_if);
`endif
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

`ifdef PCIE_USE_SVT_PEER
  `PCIE_SVT_DECLARE_HDL_AGENT_X16(peer_ep0, "peer_ep0_spd.",
    clkreq_n[0], wake_n, peer_reset_vif.asserted[0], 0, 0)
  `PCIE_SVT_DECLARE_HDL_AGENT_X4(peer_rc0, "peer_rc0_spd.",
    clkreq_n[1], wake_n, peer_reset_vif.asserted[1], 1, 1)
  `PCIE_SVT_DECLARE_HDL_AGENT_X4(peer_rc1, "peer_rc1_spd.",
    clkreq_n[2], wake_n, peer_reset_vif.asserted[2], 1, 2)
  `PCIE_SVT_DECLARE_HDL_AGENT_X4(peer_rc2, "peer_rc2_spd.",
    clkreq_n[3], wake_n, peer_reset_vif.asserted[3], 1, 3)
  `PCIE_SVT_DECLARE_HDL_AGENT_X4(peer_rc3, "peer_rc3_spd.",
    clkreq_n[4], wake_n, peer_reset_vif.asserted[4], 1, 4)
  `PCIE_SVT_CONNECT_SERIAL_PEERS(primary_rc0_serial, peer_ep0_serial)
  `PCIE_SVT_CONNECT_SERIAL_PEERS(primary_ep0_serial, peer_rc0_serial)
  `PCIE_SVT_CONNECT_SERIAL_PEERS(primary_ep1_serial, peer_rc1_serial)
  `PCIE_SVT_CONNECT_SERIAL_PEERS(primary_ep2_serial, peer_rc2_serial)
  `PCIE_SVT_CONNECT_SERIAL_PEERS(primary_ep3_serial, peer_rc3_serial)
`else
  pcie_svt_dut_wrapper #(
    .RESET_WIDTH($bits(reset_vif.asserted)),
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
`endif

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
`ifdef PCIE_USE_SVT_PEER
    peer_ep0_spd.update_if_variables(4'h1, 0,
      "uvm_test_top", "uvm_test_top");
    peer_rc0_spd.update_if_variables(4'h0, 1,
      "uvm_test_top", "uvm_test_top");
    peer_rc1_spd.update_if_variables(4'h0, 2,
      "uvm_test_top", "uvm_test_top");
    peer_rc2_spd.update_if_variables(4'h0, 3,
      "uvm_test_top", "uvm_test_top");
    peer_rc3_spd.update_if_variables(4'h0, 4,
      "uvm_test_top", "uvm_test_top");
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "peer_vif_0", peer_ep0_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "peer_vif_1", peer_rc0_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "peer_vif_2", peer_rc1_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "peer_vif_3", peer_rc2_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "peer_vif_4", peer_rc3_if);
`endif
  end
`endif

  initial begin
    uvm_config_db#(virtual pcie_svt_reset_if)::set(null, "uvm_test_top",
      "primary_reset_vif", reset_vif);
`ifdef PCIE_USE_SVT_PEER
    uvm_config_db#(virtual pcie_svt_reset_if)::set(null, "uvm_test_top",
      "peer_reset_vif", peer_reset_vif);
`endif
  end

  initial begin
    repeat (100) #0;
    run_test();
  end
endmodule
