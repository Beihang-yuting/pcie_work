//------------------------------------------------------------------------------
// 1RC + 1EP Serial TL/SVT bridge compile/elaboration top.
//------------------------------------------------------------------------------
// 本顶层沿用 Unified VIP 的 HDL agent 宏和 Serial adapter，不修改
// pcie_tl_vip 公共 API。默认实例化 placeholder wrapper；需要真实 DUT 时可
// 定义 PCIE_TL_SVT_BRIDGE_USE_REAL_DUT 并替换下方 DUT 实例连接。

`define PCIE_SVT_TOPOLOGY_ENV_PATH
`include "pcie_svt_hdl_agent_macros.svh"
`include "pcie_svt_peer_harness.sv"

import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
import pcie_svt_topology_pkg::*;
`include "uvm_macros.svh"

// 测试只负责选择后端和发布桥接输入；拓扑图、VIF 绑定及 adapter 创建仍由
// pcie_unified_env/pcie_svt_topology_env 负责，保证示例与生产环境相同。
class pcie_tl_svt_bridge_1rc1ep_test extends pcie_device_base_test;
  `uvm_component_utils(pcie_tl_svt_bridge_1rc1ep_test)

  function new(string name = "pcie_tl_svt_bridge_1rc1ep_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_global_cfg();
    pcie_svt_route_info rc_route;
    pcie_svt_route_info ep_route;

    super.build_global_cfg();

    // SVT_TL_FORWARD 保留 TL child 为控制面，同时启用 SVT Serial 数据面。
    global_cfg.backend = PCIE_BACKEND_SVT_TL_FORWARD;
    global_cfg.svt_bridge_enable = 1'b1;
    foreach (global_cfg.links[i]) begin
      global_cfg.links[i].enabled = 1'b1;
      global_cfg.links[i].use_svt = 1'b1;
    end

    // application_id 是 Mapper 的公开端口索引。本例保留 RC/EP 两个稳定
    // 号码，便于后续将 EP 替换为真实 RTL；实际 descriptor route 会继续
    // 携带拓扑 link_id/root_index，避免依赖隐含数组下标。
    rc_route = pcie_svt_route_info_default();
    rc_route.application_id = 32'h0000_0000;
    rc_route.application_id_valid = 1'b1;
    rc_route.link_name = "RC0_EP0";
    ep_route = pcie_svt_route_info_default();
    ep_route.application_id = 32'h0000_0001;
    ep_route.application_id_valid = 1'b1;
    ep_route.link_name = "RC0_EP0";

    // route 对象通过 Config DB 在 build_phase 前发布；两个别名键均保留，
    // 方便真实 DUT 测试按 RC/EP 名称覆盖而不改变公共环境源码。
    uvm_config_db#(pcie_svt_route_info)::set(
      this, "env.svt_env", "pcie_svt_route_info", rc_route);
    uvm_config_db#(pcie_svt_route_info)::set(
      this, "env.svt_env", "pcie_svt_rc_route_info", rc_route);
    uvm_config_db#(pcie_svt_route_info)::set(
      this, "env.svt_env", "pcie_svt_ep_route_info", ep_route);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    svt_pcie_tlp_mapper mapper;

    // Mapper 必须在 SVT topology build 前存在；缺失时环境会给出明确 fatal。
    mapper = svt_pcie_tlp_mapper::type_id::create("bridge_mapper", this);
    uvm_config_db#(svt_pcie_tlp_mapper)::set(
      this, "env", "pcie_svt_mapper", mapper);
    super.build_phase(phase);
  endfunction
endclass

// 模块名沿用 bootstrap 中 `EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH` 的固定层次，
// 否则 SVT loader 会找不到 global_shadow0。
module pcie_svt_topology_top;
  // SVT bootstrap 的 source-map include 负责导入 Unified VIP 的 UVM 类型和
  // pciesvc_global_shadow 所需模型宏；该顺序与正式 topology top 保持一致。
  `include "import_pcie_svt_uvm_pkgs.svi"
  `include `SVC_SOURCE_MAP_SUITE_UTIL_V(pcie_svc,PCIE,latest,svc_util_parms)
  `include `SVC_SOURCE_MAP_SUITE_MODEL_MODULE(pcie_svc,Include,latest,pciesvc_parms)

  int unsigned global_random_seed = 0;
  pciesvc_global_shadow #(.DISPLAY_NAME("global_shadow0.")) global_shadow0();

  tri1 [4:0] clkreq_n;
  tri1 wake_n;
  pcie_svt_reset_if reset_vif();

  // RC 端使用现有 HDL agent 宏；宏同时建立 svt_pcie_if 和 Serial bundle。
  `PCIE_SVT_DECLARE_HDL_AGENT_X16(primary_rc0, "primary_rc0_spd.",
    clkreq_n[0], wake_n, reset_vif.asserted[0], 1, 0)

`ifdef PCIE_TL_SVT_BRIDGE_USE_REAL_DUT
  // 真实 DUT 连接点：保持与 pcie_svt_dut_wrapper 相同的差分端口命名。
  pcie_svt_dut_wrapper #(.RESET_WIDTH($bits(reset_vif.asserted)),
                         .PORT0_WIDTH(16)) dut (
    .reset_asserted(reset_vif.asserted),
    .port0_tx_p(primary_rc0_serial.rx_p),
    .port0_tx_n(primary_rc0_serial.rx_n),
    .port0_rx_p(primary_rc0_serial.tx_p),
    .port0_rx_n(primary_rc0_serial.tx_n),
    .port1_tx_p('0), .port1_tx_n('1), .port1_rx_p(), .port1_rx_n(),
    .port2_tx_p('0), .port2_tx_n('1), .port2_rx_p(), .port2_rx_n(),
    .port3_tx_p('0), .port3_tx_n('1), .port3_rx_p(), .port3_rx_n(),
    .port4_tx_p('0), .port4_tx_n('1), .port4_rx_p(), .port4_rx_n());
`else
  // 默认 placeholder 只驱动电气 idle，用于 compile/elaboration 检查；它
  // 不模拟 LTSSM，因此不能据此宣称真实链路训练或流量通过。
  pcie_svt_dut_wrapper #(.RESET_WIDTH($bits(reset_vif.asserted)),
                         .PORT0_WIDTH(16)) placeholder_dut (
    .reset_asserted(reset_vif.asserted),
    .port0_tx_p(primary_rc0_serial.rx_p),
    .port0_tx_n(primary_rc0_serial.rx_n),
    .port0_rx_p(primary_rc0_serial.tx_p),
    .port0_rx_n(primary_rc0_serial.tx_n),
    .port1_tx_p('0), .port1_tx_n('1), .port1_rx_p(), .port1_rx_n(),
    .port2_tx_p('0), .port2_tx_n('1), .port2_rx_p(), .port2_rx_n(),
    .port3_tx_p('0), .port3_tx_n('1), .port3_rx_p(), .port3_rx_n(),
    .port4_tx_p('0), .port4_tx_n('1), .port4_rx_p(), .port4_rx_n());
`endif

  initial begin
    primary_rc0_spd.update_if_variables(4'h0, 0,
      "uvm_test_top", "uvm_test_top");
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "primary_vif_0", primary_rc0_if);
    uvm_config_db#(virtual pcie_svt_reset_if)::set(null, "uvm_test_top",
      "primary_reset_vif", reset_vif);
  end

  initial begin
    repeat (100) #0;
    run_test("pcie_tl_svt_bridge_1rc1ep_test");
  end
endmodule
