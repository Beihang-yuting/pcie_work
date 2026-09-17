//------------------------------------------------------------------------------
// 所属层次：svt_pcie_integration/rtl；仅用于 AIP Tcl 双 SVT Serial 建链诊断。
// 依赖官方 R-2020.12 interconnect、生产 backend 和 AIP 统一 package。
// 顶层持有复位/HDL port/global shadow；UVM test 持有 backend RC 与外部 SVT EP。
// 两端均为真实 FULL_VIP；不实例化 DUT，不启动官方默认流量或自动建链 sequence。
// Tcl 命令是 link_en 的唯一触发入口；不进入生产 source-only filelist。
// 沿用官方互连，但显式选择与生产 X4/X8/X16 宏一致的内部发送时钟模式；
// 不依赖 cfg.disable_ext_bit_clock_mode 覆盖，以验证 mode=0 本身的行为。
//------------------------------------------------------------------------------
`timescale 1ns/1fs
`include "aip_core_pkg.sv"

module pcie_svt_aip_link_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "import_pcie_svt_uvm_pkgs.svi"
  `include `SVC_SOURCE_MAP_SUITE_UTIL_V(pcie_svc,PCIE,latest,svc_util_parms)
  `include `SVC_SOURCE_MAP_SUITE_MODEL_MODULE(pcie_svc,Include,latest,pciesvc_parms)

  // 基类仅构建并检查 backend；派生 test 接管 run_phase 为 AIP bridge。
  `include "pcie_svt_backend_auto_link_test.sv"
  `include "pcie_svt_aip_link_test.sv"

  bit reset = 1'b1;
  int unsigned global_random_seed = 0;
  `include "hdl_interconnect_macros.sv"
  `include "pcie_tl_svt_formal_topology.sv"
  // 官方互连自己的默认值是 1；此处覆盖两端为 0，无外部发送 bit clock。
  defparam SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE_P0 = 1'b0;
  defparam SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE_P1 = 1'b0;
  pciesvc_global_shadow #(.DISPLAY_NAME("global_shadow0.")) global_shadow0();

  // 沿用已验证 Serial 顶层的 200ns 复位；command body 另等 10us 后才开启链路。
  initial begin
    #200ns;
    reset = 1'b0;
  end

  // 让官方 HDL initial 完成 VIF 发布，避免 UVM build 与 config_db 的 delta 竞争。
  initial begin
    repeat (100) #0;
    run_test("pcie_svt_aip_link_test");
  end
endmodule
