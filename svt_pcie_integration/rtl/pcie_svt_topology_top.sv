`include "pcie_svt_topology_checks.svh"
`include "pcie_svt_serial_adapter.sv"
`include "pcie_svt_peer_harness.sv"
`include "pcie_svt_passive_sidecar_tap.sv"

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
  svt_pcie_if primary_rc0_if(clkreq_n[0], wake_n);
  svt_pcie_single_port_device_agent_hdl primary_rc0_spd(primary_rc0_if);
  pcie_svt_serial_port_if #(16) primary_rc0_serial();

  defparam primary_rc0_spd.SVT_PCIE_UI_PCIE_SPEC_VER =
    `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
  defparam primary_rc0_spd.SVT_PCIE_UI_DISPLAY_NAME = "primary_rc0_spd.";
  defparam primary_rc0_spd.SVT_PCIE_UI_PHY_INTERFACE_TYPE =
    `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
  defparam primary_rc0_spd.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE = 1'b1;
  defparam primary_rc0_spd.SVT_PCIE_UI_ENABLE_CFG_BLOCK = 1'b1;
  defparam primary_rc0_spd.SVT_PCIE_UI_CONNECT_ACTIVE_VIP = 1'b1;
  defparam primary_rc0_spd.SVT_PCIE_UI_NUM_PHYSICAL_LANES = 16;
  defparam primary_rc0_spd.SVT_PCIE_UI_DEVICE_IS_ROOT = 1;
  defparam primary_rc0_spd.SVT_PCIE_UI_HIERARCHY_NUMBER = 0;

  `PCIE_SVT_MAP_SERDES_X16(primary_rc0_spd, primary_rc0_serial)
  assign primary_rc0_spd.vip_port_if.ser_if.reset = reset_vif.asserted[0];

`ifdef PCIE_USE_SVT_PEER
  svt_pcie_if peer_ep0_if(clkreq_n[0], wake_n);
  svt_pcie_single_port_device_agent_hdl peer_ep0_spd(peer_ep0_if);
  pcie_svt_serial_port_if #(16) peer_ep0_serial();

  defparam peer_ep0_spd.SVT_PCIE_UI_PCIE_SPEC_VER =
    `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
  defparam peer_ep0_spd.SVT_PCIE_UI_DISPLAY_NAME = "peer_ep0_spd.";
  defparam peer_ep0_spd.SVT_PCIE_UI_PHY_INTERFACE_TYPE =
    `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
  defparam peer_ep0_spd.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE = 1'b1;
  defparam peer_ep0_spd.SVT_PCIE_UI_ENABLE_CFG_BLOCK = 1'b1;
  defparam peer_ep0_spd.SVT_PCIE_UI_CONNECT_ACTIVE_VIP = 1'b1;
  defparam peer_ep0_spd.SVT_PCIE_UI_NUM_PHYSICAL_LANES = 16;
  defparam peer_ep0_spd.SVT_PCIE_UI_DEVICE_IS_ROOT = 0;
  defparam peer_ep0_spd.SVT_PCIE_UI_HIERARCHY_NUMBER = 0;

  `PCIE_SVT_MAP_SERDES_X16(peer_ep0_spd, peer_ep0_serial)
  `PCIE_SVT_CONNECT_SERIAL_PEERS(primary_rc0_serial, peer_ep0_serial)
  assign peer_ep0_spd.vip_port_if.ser_if.reset = reset_vif.asserted[0];
`else
  pcie_dut_placeholder dut (
    .reset(reset_vif.asserted[0]),
    .ep0_rx_p(primary_rc0_serial.rx_p),
    .ep0_rx_n(primary_rc0_serial.rx_n),
    .ep0_tx_p(primary_rc0_serial.tx_p),
    .ep0_tx_n(primary_rc0_serial.tx_n)
  );
`endif

  initial begin
    primary_rc0_spd.update_if_variables(4'h0, 0,
      "uvm_test_top", "uvm_test_top");
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_rc0_vif", primary_rc0_if);
`ifdef PCIE_USE_SVT_PEER
    peer_ep0_spd.update_if_variables(4'h1, 0,
      "uvm_test_top", "uvm_test_top");
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "peer_ep0_vif", peer_ep0_if);
`endif
  end
`elsif PCIE_TOPO_EP_2X8
  svt_pcie_if primary_rc0_if(clkreq_n[0], wake_n);
  svt_pcie_single_port_device_agent_hdl primary_rc0_spd(primary_rc0_if);
  pcie_svt_serial_port_if #(8) primary_rc0_serial();
  svt_pcie_if primary_rc1_if(clkreq_n[1], wake_n);
  svt_pcie_single_port_device_agent_hdl primary_rc1_spd(primary_rc1_if);
  pcie_svt_serial_port_if #(8) primary_rc1_serial();

  defparam primary_rc0_spd.SVT_PCIE_UI_PCIE_SPEC_VER =
    `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
  defparam primary_rc0_spd.SVT_PCIE_UI_DISPLAY_NAME = "primary_rc0_spd.";
  defparam primary_rc0_spd.SVT_PCIE_UI_PHY_INTERFACE_TYPE =
    `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
  defparam primary_rc0_spd.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE = 1'b1;
  defparam primary_rc0_spd.SVT_PCIE_UI_ENABLE_CFG_BLOCK = 1'b1;
  defparam primary_rc0_spd.SVT_PCIE_UI_CONNECT_ACTIVE_VIP = 1'b1;
  defparam primary_rc0_spd.SVT_PCIE_UI_NUM_PHYSICAL_LANES = 8;
  defparam primary_rc0_spd.SVT_PCIE_UI_DEVICE_IS_ROOT = 1;
  defparam primary_rc0_spd.SVT_PCIE_UI_HIERARCHY_NUMBER = 0;

  defparam primary_rc1_spd.SVT_PCIE_UI_PCIE_SPEC_VER =
    `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
  defparam primary_rc1_spd.SVT_PCIE_UI_DISPLAY_NAME = "primary_rc1_spd.";
  defparam primary_rc1_spd.SVT_PCIE_UI_PHY_INTERFACE_TYPE =
    `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
  defparam primary_rc1_spd.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE = 1'b1;
  defparam primary_rc1_spd.SVT_PCIE_UI_ENABLE_CFG_BLOCK = 1'b1;
  defparam primary_rc1_spd.SVT_PCIE_UI_CONNECT_ACTIVE_VIP = 1'b1;
  defparam primary_rc1_spd.SVT_PCIE_UI_NUM_PHYSICAL_LANES = 8;
  defparam primary_rc1_spd.SVT_PCIE_UI_DEVICE_IS_ROOT = 1;
  defparam primary_rc1_spd.SVT_PCIE_UI_HIERARCHY_NUMBER = 1;

  `PCIE_SVT_MAP_SERDES_X8(primary_rc0_spd, primary_rc0_serial)
  `PCIE_SVT_MAP_SERDES_X8(primary_rc1_spd, primary_rc1_serial)
  assign primary_rc0_spd.vip_port_if.ser_if.reset = reset_vif.asserted[0];
  assign primary_rc1_spd.vip_port_if.ser_if.reset = reset_vif.asserted[1];

  pcie_dut_placeholder dut (
    .reset(|reset_vif.asserted[1:0]),
    .ep0_rx_p(primary_rc0_serial.rx_p),
    .ep0_rx_n(primary_rc0_serial.rx_n),
    .ep0_tx_p(primary_rc0_serial.tx_p),
    .ep0_tx_n(primary_rc0_serial.tx_n),
    .ep1_rx_p(primary_rc1_serial.rx_p),
    .ep1_rx_n(primary_rc1_serial.rx_n),
    .ep1_tx_p(primary_rc1_serial.tx_p),
    .ep1_tx_n(primary_rc1_serial.tx_n)
  );

  initial begin
    primary_rc0_spd.update_if_variables(4'h0, 0,
      "uvm_test_top", "uvm_test_top");
    primary_rc1_spd.update_if_variables(4'h0, 1,
      "uvm_test_top", "uvm_test_top");
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_rc0_vif", primary_rc0_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_rc1_vif", primary_rc1_if);
  end
`else
  svt_pcie_if primary_rc0_if(clkreq_n[0], wake_n);
  svt_pcie_single_port_device_agent_hdl primary_rc0_spd(primary_rc0_if);
  pcie_svt_serial_port_if #(16) primary_rc0_serial();
  svt_pcie_if primary_ep0_if(clkreq_n[1], wake_n);
  svt_pcie_single_port_device_agent_hdl primary_ep0_spd(primary_ep0_if);
  pcie_svt_serial_port_if #(4) primary_ep0_serial();
  svt_pcie_if primary_ep1_if(clkreq_n[2], wake_n);
  svt_pcie_single_port_device_agent_hdl primary_ep1_spd(primary_ep1_if);
  pcie_svt_serial_port_if #(4) primary_ep1_serial();
  svt_pcie_if primary_ep2_if(clkreq_n[3], wake_n);
  svt_pcie_single_port_device_agent_hdl primary_ep2_spd(primary_ep2_if);
  pcie_svt_serial_port_if #(4) primary_ep2_serial();
  svt_pcie_if primary_ep3_if(clkreq_n[4], wake_n);
  svt_pcie_single_port_device_agent_hdl primary_ep3_spd(primary_ep3_if);
  pcie_svt_serial_port_if #(4) primary_ep3_serial();

`ifdef PCIE_USE_SVT_SWITCH_PROXY
  svt_pcie_if proxy_usp_if(clkreq_n[0], wake_n);
  svt_pcie_single_port_device_agent_hdl proxy_usp_spd(proxy_usp_if);
  pcie_svt_serial_port_if #(16) proxy_usp_serial();
  svt_pcie_serdes_x16_if proxy_usp_sidecar_if(reset_vif.asserted[0]);

  svt_pcie_if proxy_dsp0_if(clkreq_n[1], wake_n);
  svt_pcie_single_port_device_agent_hdl proxy_dsp0_spd(proxy_dsp0_if);
  pcie_svt_serial_port_if #(4) proxy_dsp0_serial();
  svt_pcie_serdes_x4_if proxy_dsp0_sidecar_if(reset_vif.asserted[1]);
  svt_pcie_if proxy_dsp1_if(clkreq_n[2], wake_n);
  svt_pcie_single_port_device_agent_hdl proxy_dsp1_spd(proxy_dsp1_if);
  pcie_svt_serial_port_if #(4) proxy_dsp1_serial();
  svt_pcie_serdes_x4_if proxy_dsp1_sidecar_if(reset_vif.asserted[2]);
  svt_pcie_if proxy_dsp2_if(clkreq_n[3], wake_n);
  svt_pcie_single_port_device_agent_hdl proxy_dsp2_spd(proxy_dsp2_if);
  pcie_svt_serial_port_if #(4) proxy_dsp2_serial();
  svt_pcie_serdes_x4_if proxy_dsp2_sidecar_if(reset_vif.asserted[3]);
  svt_pcie_if proxy_dsp3_if(clkreq_n[4], wake_n);
  svt_pcie_single_port_device_agent_hdl proxy_dsp3_spd(proxy_dsp3_if);
  pcie_svt_serial_port_if #(4) proxy_dsp3_serial();
  svt_pcie_serdes_x4_if proxy_dsp3_sidecar_if(reset_vif.asserted[4]);
`endif

  defparam primary_rc0_spd.SVT_PCIE_UI_PCIE_SPEC_VER =
    `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
  defparam primary_rc0_spd.SVT_PCIE_UI_DISPLAY_NAME = "primary_rc0_spd.";
  defparam primary_rc0_spd.SVT_PCIE_UI_PHY_INTERFACE_TYPE =
    `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
  defparam primary_rc0_spd.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE = 1'b1;
  defparam primary_rc0_spd.SVT_PCIE_UI_ENABLE_CFG_BLOCK = 1'b1;
  defparam primary_rc0_spd.SVT_PCIE_UI_CONNECT_ACTIVE_VIP = 1'b1;
  defparam primary_rc0_spd.SVT_PCIE_UI_NUM_PHYSICAL_LANES = 16;
  defparam primary_rc0_spd.SVT_PCIE_UI_DEVICE_IS_ROOT = 1;
  defparam primary_rc0_spd.SVT_PCIE_UI_HIERARCHY_NUMBER = 0;

  defparam primary_ep0_spd.SVT_PCIE_UI_PCIE_SPEC_VER =
    `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
  defparam primary_ep0_spd.SVT_PCIE_UI_DISPLAY_NAME = "primary_ep0_spd.";
  defparam primary_ep0_spd.SVT_PCIE_UI_PHY_INTERFACE_TYPE =
    `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
  defparam primary_ep0_spd.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE = 1'b1;
  defparam primary_ep0_spd.SVT_PCIE_UI_ENABLE_CFG_BLOCK = 1'b1;
  defparam primary_ep0_spd.SVT_PCIE_UI_CONNECT_ACTIVE_VIP = 1'b1;
  defparam primary_ep0_spd.SVT_PCIE_UI_NUM_PHYSICAL_LANES = 4;
  defparam primary_ep0_spd.SVT_PCIE_UI_DEVICE_IS_ROOT = 0;
  defparam primary_ep0_spd.SVT_PCIE_UI_HIERARCHY_NUMBER = 0;

  defparam primary_ep1_spd.SVT_PCIE_UI_PCIE_SPEC_VER =
    `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
  defparam primary_ep1_spd.SVT_PCIE_UI_DISPLAY_NAME = "primary_ep1_spd.";
  defparam primary_ep1_spd.SVT_PCIE_UI_PHY_INTERFACE_TYPE =
    `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
  defparam primary_ep1_spd.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE = 1'b1;
  defparam primary_ep1_spd.SVT_PCIE_UI_ENABLE_CFG_BLOCK = 1'b1;
  defparam primary_ep1_spd.SVT_PCIE_UI_CONNECT_ACTIVE_VIP = 1'b1;
  defparam primary_ep1_spd.SVT_PCIE_UI_NUM_PHYSICAL_LANES = 4;
  defparam primary_ep1_spd.SVT_PCIE_UI_DEVICE_IS_ROOT = 0;
  defparam primary_ep1_spd.SVT_PCIE_UI_HIERARCHY_NUMBER = 0;

  defparam primary_ep2_spd.SVT_PCIE_UI_PCIE_SPEC_VER =
    `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
  defparam primary_ep2_spd.SVT_PCIE_UI_DISPLAY_NAME = "primary_ep2_spd.";
  defparam primary_ep2_spd.SVT_PCIE_UI_PHY_INTERFACE_TYPE =
    `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
  defparam primary_ep2_spd.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE = 1'b1;
  defparam primary_ep2_spd.SVT_PCIE_UI_ENABLE_CFG_BLOCK = 1'b1;
  defparam primary_ep2_spd.SVT_PCIE_UI_CONNECT_ACTIVE_VIP = 1'b1;
  defparam primary_ep2_spd.SVT_PCIE_UI_NUM_PHYSICAL_LANES = 4;
  defparam primary_ep2_spd.SVT_PCIE_UI_DEVICE_IS_ROOT = 0;
  defparam primary_ep2_spd.SVT_PCIE_UI_HIERARCHY_NUMBER = 0;

  defparam primary_ep3_spd.SVT_PCIE_UI_PCIE_SPEC_VER =
    `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
  defparam primary_ep3_spd.SVT_PCIE_UI_DISPLAY_NAME = "primary_ep3_spd.";
  defparam primary_ep3_spd.SVT_PCIE_UI_PHY_INTERFACE_TYPE =
    `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
  defparam primary_ep3_spd.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE = 1'b1;
  defparam primary_ep3_spd.SVT_PCIE_UI_ENABLE_CFG_BLOCK = 1'b1;
  defparam primary_ep3_spd.SVT_PCIE_UI_CONNECT_ACTIVE_VIP = 1'b1;
  defparam primary_ep3_spd.SVT_PCIE_UI_NUM_PHYSICAL_LANES = 4;
  defparam primary_ep3_spd.SVT_PCIE_UI_DEVICE_IS_ROOT = 0;
  defparam primary_ep3_spd.SVT_PCIE_UI_HIERARCHY_NUMBER = 0;

`ifdef PCIE_USE_SVT_SWITCH_PROXY
  defparam proxy_usp_spd.SVT_PCIE_UI_PCIE_SPEC_VER =
    `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
  defparam proxy_usp_spd.SVT_PCIE_UI_DISPLAY_NAME = "proxy_usp_spd.";
  defparam proxy_usp_spd.SVT_PCIE_UI_PHY_INTERFACE_TYPE =
    `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
  defparam proxy_usp_spd.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE = 1'b1;
  defparam proxy_usp_spd.SVT_PCIE_UI_ENABLE_CFG_BLOCK = 1'b1;
  defparam proxy_usp_spd.SVT_PCIE_UI_CONNECT_ACTIVE_VIP = 1'b1;
  defparam proxy_usp_spd.SVT_PCIE_UI_NUM_PHYSICAL_LANES = 16;
  defparam proxy_usp_spd.SVT_PCIE_UI_DEVICE_IS_ROOT = 0;
  defparam proxy_usp_spd.SVT_PCIE_UI_HIERARCHY_NUMBER = 0;

  defparam proxy_dsp0_spd.SVT_PCIE_UI_PCIE_SPEC_VER =
    `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
  defparam proxy_dsp0_spd.SVT_PCIE_UI_DISPLAY_NAME = "proxy_dsp0_spd.";
  defparam proxy_dsp0_spd.SVT_PCIE_UI_PHY_INTERFACE_TYPE =
    `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
  defparam proxy_dsp0_spd.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE = 1'b1;
  defparam proxy_dsp0_spd.SVT_PCIE_UI_ENABLE_CFG_BLOCK = 1'b1;
  defparam proxy_dsp0_spd.SVT_PCIE_UI_CONNECT_ACTIVE_VIP = 1'b1;
  defparam proxy_dsp0_spd.SVT_PCIE_UI_NUM_PHYSICAL_LANES = 4;
  defparam proxy_dsp0_spd.SVT_PCIE_UI_DEVICE_IS_ROOT = 1;
  defparam proxy_dsp0_spd.SVT_PCIE_UI_HIERARCHY_NUMBER = 1;

  defparam proxy_dsp1_spd.SVT_PCIE_UI_PCIE_SPEC_VER =
    `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
  defparam proxy_dsp1_spd.SVT_PCIE_UI_DISPLAY_NAME = "proxy_dsp1_spd.";
  defparam proxy_dsp1_spd.SVT_PCIE_UI_PHY_INTERFACE_TYPE =
    `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
  defparam proxy_dsp1_spd.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE = 1'b1;
  defparam proxy_dsp1_spd.SVT_PCIE_UI_ENABLE_CFG_BLOCK = 1'b1;
  defparam proxy_dsp1_spd.SVT_PCIE_UI_CONNECT_ACTIVE_VIP = 1'b1;
  defparam proxy_dsp1_spd.SVT_PCIE_UI_NUM_PHYSICAL_LANES = 4;
  defparam proxy_dsp1_spd.SVT_PCIE_UI_DEVICE_IS_ROOT = 1;
  defparam proxy_dsp1_spd.SVT_PCIE_UI_HIERARCHY_NUMBER = 2;

  defparam proxy_dsp2_spd.SVT_PCIE_UI_PCIE_SPEC_VER =
    `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
  defparam proxy_dsp2_spd.SVT_PCIE_UI_DISPLAY_NAME = "proxy_dsp2_spd.";
  defparam proxy_dsp2_spd.SVT_PCIE_UI_PHY_INTERFACE_TYPE =
    `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
  defparam proxy_dsp2_spd.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE = 1'b1;
  defparam proxy_dsp2_spd.SVT_PCIE_UI_ENABLE_CFG_BLOCK = 1'b1;
  defparam proxy_dsp2_spd.SVT_PCIE_UI_CONNECT_ACTIVE_VIP = 1'b1;
  defparam proxy_dsp2_spd.SVT_PCIE_UI_NUM_PHYSICAL_LANES = 4;
  defparam proxy_dsp2_spd.SVT_PCIE_UI_DEVICE_IS_ROOT = 1;
  defparam proxy_dsp2_spd.SVT_PCIE_UI_HIERARCHY_NUMBER = 3;

  defparam proxy_dsp3_spd.SVT_PCIE_UI_PCIE_SPEC_VER =
    `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
  defparam proxy_dsp3_spd.SVT_PCIE_UI_DISPLAY_NAME = "proxy_dsp3_spd.";
  defparam proxy_dsp3_spd.SVT_PCIE_UI_PHY_INTERFACE_TYPE =
    `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
  defparam proxy_dsp3_spd.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE = 1'b1;
  defparam proxy_dsp3_spd.SVT_PCIE_UI_ENABLE_CFG_BLOCK = 1'b1;
  defparam proxy_dsp3_spd.SVT_PCIE_UI_CONNECT_ACTIVE_VIP = 1'b1;
  defparam proxy_dsp3_spd.SVT_PCIE_UI_NUM_PHYSICAL_LANES = 4;
  defparam proxy_dsp3_spd.SVT_PCIE_UI_DEVICE_IS_ROOT = 1;
  defparam proxy_dsp3_spd.SVT_PCIE_UI_HIERARCHY_NUMBER = 4;
`endif

  `PCIE_SVT_MAP_SERDES_X16(primary_rc0_spd, primary_rc0_serial)
  `PCIE_SVT_MAP_SERDES_X4(primary_ep0_spd, primary_ep0_serial)
  `PCIE_SVT_MAP_SERDES_X4(primary_ep1_spd, primary_ep1_serial)
  `PCIE_SVT_MAP_SERDES_X4(primary_ep2_spd, primary_ep2_serial)
  `PCIE_SVT_MAP_SERDES_X4(primary_ep3_spd, primary_ep3_serial)
  assign primary_rc0_spd.vip_port_if.ser_if.reset = reset_vif.asserted[0];
  assign primary_ep0_spd.vip_port_if.ser_if.reset = reset_vif.asserted[1];
  assign primary_ep1_spd.vip_port_if.ser_if.reset = reset_vif.asserted[2];
  assign primary_ep2_spd.vip_port_if.ser_if.reset = reset_vif.asserted[3];
  assign primary_ep3_spd.vip_port_if.ser_if.reset = reset_vif.asserted[4];

`ifdef PCIE_USE_SVT_SWITCH_PROXY
  `PCIE_SVT_MAP_SERDES_X16(proxy_usp_spd, proxy_usp_serial)
  `PCIE_SVT_MAP_SERDES_X4(proxy_dsp0_spd, proxy_dsp0_serial)
  `PCIE_SVT_MAP_SERDES_X4(proxy_dsp1_spd, proxy_dsp1_serial)
  `PCIE_SVT_MAP_SERDES_X4(proxy_dsp2_spd, proxy_dsp2_serial)
  `PCIE_SVT_MAP_SERDES_X4(proxy_dsp3_spd, proxy_dsp3_serial)
  `PCIE_SVT_CONNECT_SERIAL_PEERS(primary_rc0_serial, proxy_usp_serial)
  `PCIE_SVT_CONNECT_SERIAL_PEERS(primary_ep0_serial, proxy_dsp0_serial)
  `PCIE_SVT_CONNECT_SERIAL_PEERS(primary_ep1_serial, proxy_dsp1_serial)
  `PCIE_SVT_CONNECT_SERIAL_PEERS(primary_ep2_serial, proxy_dsp2_serial)
  `PCIE_SVT_CONNECT_SERIAL_PEERS(primary_ep3_serial, proxy_dsp3_serial)

  `PCIE_SVT_TAP_PASSIVE_SERDES_X16(proxy_usp_sidecar_if, proxy_usp_serial)
  `PCIE_SVT_TAP_PASSIVE_SERDES_X4(proxy_dsp0_sidecar_if, proxy_dsp0_serial)
  `PCIE_SVT_TAP_PASSIVE_SERDES_X4(proxy_dsp1_sidecar_if, proxy_dsp1_serial)
  `PCIE_SVT_TAP_PASSIVE_SERDES_X4(proxy_dsp2_sidecar_if, proxy_dsp2_serial)
  `PCIE_SVT_TAP_PASSIVE_SERDES_X4(proxy_dsp3_sidecar_if, proxy_dsp3_serial)

  assign proxy_usp_spd.vip_port_if.ser_if.reset = reset_vif.asserted[0];
  assign proxy_dsp0_spd.vip_port_if.ser_if.reset = reset_vif.asserted[1];
  assign proxy_dsp1_spd.vip_port_if.ser_if.reset = reset_vif.asserted[2];
  assign proxy_dsp2_spd.vip_port_if.ser_if.reset = reset_vif.asserted[3];
  assign proxy_dsp3_spd.vip_port_if.ser_if.reset = reset_vif.asserted[4];
`else
  pcie_switch_dut_wrapper dut (
    .reset_asserted(reset_vif.asserted),
    .usp_rx_p(primary_rc0_serial.rx_p),
    .usp_rx_n(primary_rc0_serial.rx_n),
    .usp_tx_p(primary_rc0_serial.tx_p),
    .usp_tx_n(primary_rc0_serial.tx_n),
    .dsp0_rx_p(primary_ep0_serial.rx_p),
    .dsp0_rx_n(primary_ep0_serial.rx_n),
    .dsp0_tx_p(primary_ep0_serial.tx_p),
    .dsp0_tx_n(primary_ep0_serial.tx_n),
    .dsp1_rx_p(primary_ep1_serial.rx_p),
    .dsp1_rx_n(primary_ep1_serial.rx_n),
    .dsp1_tx_p(primary_ep1_serial.tx_p),
    .dsp1_tx_n(primary_ep1_serial.tx_n),
    .dsp2_rx_p(primary_ep2_serial.rx_p),
    .dsp2_rx_n(primary_ep2_serial.rx_n),
    .dsp2_tx_p(primary_ep2_serial.tx_p),
    .dsp2_tx_n(primary_ep2_serial.tx_n),
    .dsp3_rx_p(primary_ep3_serial.rx_p),
    .dsp3_rx_n(primary_ep3_serial.rx_n),
    .dsp3_tx_p(primary_ep3_serial.tx_p),
    .dsp3_tx_n(primary_ep3_serial.tx_n)
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
      "primary_rc0_vif", primary_rc0_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_ep0_vif", primary_ep0_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_ep1_vif", primary_ep1_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_ep2_vif", primary_ep2_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_ep3_vif", primary_ep3_if);
`ifdef PCIE_USE_SVT_SWITCH_PROXY
    proxy_usp_spd.update_if_variables(4'h1, 0,
      "uvm_test_top", "uvm_test_top");
    proxy_dsp0_spd.update_if_variables(4'h0, 1,
      "uvm_test_top", "uvm_test_top");
    proxy_dsp1_spd.update_if_variables(4'h0, 2,
      "uvm_test_top", "uvm_test_top");
    proxy_dsp2_spd.update_if_variables(4'h0, 3,
      "uvm_test_top", "uvm_test_top");
    proxy_dsp3_spd.update_if_variables(4'h0, 4,
      "uvm_test_top", "uvm_test_top");
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "proxy_usp_vif", proxy_usp_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "proxy_dsp0_vif", proxy_dsp0_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "proxy_dsp1_vif", proxy_dsp1_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "proxy_dsp2_vif", proxy_dsp2_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "proxy_dsp3_vif", proxy_dsp3_if);
    uvm_config_db#(
      svt_pcie_configuration::svt_pcie_serdes_x16_vif)::set(
      null, "uvm_test_top",
      "proxy_usp_sidecar_vif", proxy_usp_sidecar_if);
    uvm_config_db#(
      svt_pcie_configuration::svt_pcie_serdes_x4_vif)::set(
      null, "uvm_test_top",
      "proxy_dsp0_sidecar_vif", proxy_dsp0_sidecar_if);
    uvm_config_db#(
      svt_pcie_configuration::svt_pcie_serdes_x4_vif)::set(
      null, "uvm_test_top",
      "proxy_dsp1_sidecar_vif", proxy_dsp1_sidecar_if);
    uvm_config_db#(
      svt_pcie_configuration::svt_pcie_serdes_x4_vif)::set(
      null, "uvm_test_top",
      "proxy_dsp2_sidecar_vif", proxy_dsp2_sidecar_if);
    uvm_config_db#(
      svt_pcie_configuration::svt_pcie_serdes_x4_vif)::set(
      null, "uvm_test_top",
      "proxy_dsp3_sidecar_vif", proxy_dsp3_sidecar_if);
`endif
  end
`endif

  initial begin
    uvm_config_db#(virtual pcie_svt_reset_if)::set(null, "uvm_test_top",
      "reset_vif", reset_vif);
  end

  initial begin
    repeat (100) #0;
    run_test();
  end
endmodule
