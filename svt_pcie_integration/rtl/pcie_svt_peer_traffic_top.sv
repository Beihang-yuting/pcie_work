//------------------------------------------------------------------------------
// SVT peer traffic test-only 顶层。
//
// 该顶层依赖 Synopsys R-2020.12 官方 env 和 HDL interconnect 宏，仅由
// pcie_svt_peer_traffic.f 引用；生产 pcie_tl_svt_adapter.f 不会编译它。
//------------------------------------------------------------------------------

`timescale 1ns/1fs

`define SVT_PCIE_ENABLE_GEN4
`define EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH pcie_svt_peer_traffic_top.global_shadow0
`define SVC_RANDOM_SEED_SCOPE pcie_svt_peer_traffic_top.global_random_seed

`include "svt_pcie.uvm.pkg"

module pcie_svt_peer_traffic_top;

  import uvm_pkg::*;

  `include "uvm_macros.svh"
  `include "import_pcie_svt_uvm_pkgs.svi"

  // 官方模型模块宏由 filelist 提供 include 路径。
  `include `SVC_SOURCE_MAP_SUITE_UTIL_V(pcie_svc,PCIE,latest,svc_util_parms)
  `include `SVC_SOURCE_MAP_SUITE_MODEL_MODULE(pcie_svc,Include,latest,pciesvc_parms)

  // 官方 Unified VIP 环境；其中还会包含官方随机 traffic sequence。
  `include "pcie_device_unified_vip_env.sv"

  // 官方 base test 创建 RC/EP agent 和 sys virtual sequencer。
  `include "pcie_device_base_test.sv"

  // 自定义测试必须与官方 base test 保持同一 module 编译作用域；
  // 若作为独立 filelist 源文件编译，VCS 无法解析其基类。
  `include "pcie_svt_peer_traffic_test.sv"

  // 供官方 interconnect 宏使用的复位信号。时钟/辅助信号由
  // hdl_interconnect_macros.sv 按官方约定声明，顶层不重复声明。
  bit reset = 1'b1;

  `include "hdl_interconnect_macros.sv"
  `include "pcie_svt_peer_traffic_topology.sv"

  int unsigned global_random_seed = 0;
  pciesvc_global_shadow #(.DISPLAY_NAME("global_shadow0.")) global_shadow0();

  // 与官方示例一致：先保持复位，再启动 UVM 测试。
  initial begin
    #200ns;
    reset = 1'b0;
  end

  initial begin
    repeat (100) #0;
    run_test();
  end

endmodule
