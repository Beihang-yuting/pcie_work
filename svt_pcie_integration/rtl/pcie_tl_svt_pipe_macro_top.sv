//------------------------------------------------------------------------------
// PIPE 版 PCIE_SVT_DECLARE_HDL_AGENT 宏的门禁顶层。
//
// 该文件属于 svt_pcie_integration/rtl，由 pcie_tl_svt_pipe_macro.f 收
// 录（该 filelist 定义 PCIE_SVT_HDL_PHY_PIPE）。目的：证明真实 DUT 集
// 成入口宏（PCIE_SVT_DECLARE_HDL_AGENT_Xn）的 PIPE 展开与官方
// CREATE_PORT_INST 路线等价——用同一批 test、同样的门禁断言，把两个
// 宏声明的 agent 经官方 PIPE 互连宏对拼后跑通双向数据面。
//
// 与真实 DUT 顶层的差异仅在互连：这里 EP 端也是 SVT（用官方
// PIPE_PIPE_LINK 对拼）；真实 DUT 场景把对应一侧换成 DUT 的 PIPE
// 逐 lane 信号即可，宏调用行不变。
//------------------------------------------------------------------------------

`timescale 1ns/1fs
module pcie_tl_svt_pipe_macro_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "import_pcie_svt_uvm_pkgs.svi"
  `include `SVC_SOURCE_MAP_SUITE_UTIL_V(pcie_svc,PCIE,latest,svc_util_parms)
  `include `SVC_SOURCE_MAP_SUITE_MODEL_MODULE(pcie_svc,Include,latest,pciesvc_parms)
  `include "pcie_device_unified_vip_env.sv"
  `include "pcie_tl_svt_formal_test.sv"

  bit reset = 1'b1;
  // 官方互连宏（PIPE_PIPE_COMMON_CODE）硬引用该复位名并独占驱动两侧
  // pipe_if.reset（该信号是 logic，只允许单一结构驱动，DECLARE 宏
  // 因此不驱动它）。
  bit common_pwr_on_reset = 1'b1;
  int unsigned global_random_seed = 0;
  `include "hdl_interconnect_macros.sv"
  `include "pcie_svt_hdl_agent_macros.svh"

  pciesvc_global_shadow #(.DISPLAY_NAME("global_shadow0.")) global_shadow0();

  // 两个 SVT agent 均通过通用 DECLARE 宏声明（PIPE 模式展开）：
  // RC 侧 is_root=1（spipe/MPIPE=0），EP 侧 is_root=0（mpipe/MPIPE=1）。
  `PCIE_SVT_DECLARE_HDL_AGENT_X4(svt_rc0, "SVT_RC0.", 1'b0, 1'b0,
                                 common_pwr_on_reset, 1, 0)
  `PCIE_SVT_DECLARE_HDL_AGENT_X4(svt_ep0, "SVT_EP0.", 1'b0, 1'b0,
                                 common_pwr_on_reset, 0, 1)

  // 向量化端口对拼：宏展开已生成 svt_rc0_pipe / svt_ep0_pipe，一条
  // CROSS 宏即完成全部 per-lane + 公共信号互连（a=spipe/RC 的 port，
  // b=mpipe/EP 的 port）。真实 DUT 场景把 CROSS 换成 DUT 与单个
  // <name>_pipe 的向量连线即可。
  `PCIE_SVT_PIPE_PORT_CROSS_X4(svt_rc0_pipe, svt_ep0_pipe)

  // pipe_if.reset 是 logic 单驱动，归顶层：每实例一条 assign。
  assign svt_rc0_spd.vip_port_if.pipe_if.reset = common_pwr_on_reset;
  assign svt_ep0_spd.vip_port_if.pipe_if.reset = common_pwr_on_reset;

  // VIF 发布沿用 DECLARE 宏路线的固定约定：RC 端 port 4'h0 →
  // link_0_vif_0，EP 端 port 4'h1 → link_0_vif_1，与 unified env 的
  // 查找 key 一致。
  initial begin
    svt_rc0_spd.update_if_variables(4'h0, 8'd0, "uvm_test_top", "uvm_test_top");
    svt_ep0_spd.update_if_variables(4'h1, 8'd0, "uvm_test_top", "uvm_test_top");
  end

  initial begin
    #200ns;
    reset = 1'b0;
    common_pwr_on_reset = 1'b0;
  end

  initial begin
    string selected_test;
    repeat (100) #0;
    if (!$value$plusargs("UVM_TESTNAME=%s", selected_test))
      selected_test = "pcie_tl_svt_formal_link_test";
    run_test(selected_test);
  end
endmodule
