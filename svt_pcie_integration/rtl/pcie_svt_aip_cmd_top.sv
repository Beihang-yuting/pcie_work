//------------------------------------------------------------------------------
// 所属层次：rtl/test-only；AIP 通用命令的真实双 SVT Serial 验证顶层。
// 依赖正式 SVT unified env、TL adapter、可选 AIP sequence 库；本文件不进入
// 生产 filelist。顶层拥有 HDL 互连、复位和 shadow，UVM test 拥有 env；
// link_en 只能由 Tcl 调用触发，HDL 采用 mode=0 的内部发送时钟。
//------------------------------------------------------------------------------
`timescale 1ns/1fs
`include "aip_core_pkg.sv"

module pcie_svt_aip_cmd_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "import_pcie_svt_uvm_pkgs.svi"
  `include `SVC_SOURCE_MAP_SUITE_UTIL_V(pcie_svc,PCIE,latest,svc_util_parms)
  `include `SVC_SOURCE_MAP_SUITE_MODEL_MODULE(pcie_svc,Include,latest,pciesvc_parms)
  `include "pcie_device_unified_vip_env.sv"
  `include "pcie_tl_svt_formal_test.sv"
  `include "pcie_svt_aip_seqs.sv"
  `include "pcie_svt_aip_cmd_test.sv"

  bit reset = 1'b1;
  int unsigned global_random_seed = 0;
  `include "hdl_interconnect_macros.sv"
  `include "pcie_tl_svt_formal_topology.sv"
  defparam SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE_P0 = 1'b0;
  defparam SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE_P1 = 1'b0;
  pciesvc_global_shadow #(.DISPLAY_NAME("global_shadow0.")) global_shadow0();

  // 测试局部复位；真实 DUT 的参考钟/PERST# 必须由用户另行驱动。
  initial begin
    #200ns;
    reset = 1'b0;
  end

  // 等待官方 HDL initial 发布 VIF，避免 config_db 的 delta-cycle 竞争。
  initial begin
    repeat (100) #0;
    run_test("pcie_svt_aip_cmd_test");
  end
endmodule
