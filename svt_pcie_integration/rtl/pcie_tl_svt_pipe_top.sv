//------------------------------------------------------------------------------
// TL-root + 正式 SVT agent PIPE 验证顶层。
//
// 该文件属于 svt_pcie_integration/rtl，由 pcie_tl_svt_pipe.f 收录。与
// Serial 版 pcie_tl_svt_formal_top.sv 完全同构：同一批 test（默认仍是
// pcie_tl_svt_formal_link_test 双向门禁），唯一差异是 include 的拓扑换
// 成 PIPE 互连（pcie_tl_svt_pipe_topology.sv）。TL 控制面与 adapter 对
// 物理层类型无感知，因此 PIPE 数据面复用同一门禁断言
// （PCIE_TL_SVT_TLP_PASS 等）。
//------------------------------------------------------------------------------

`timescale 1ns/1fs
module pcie_tl_svt_pipe_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "import_pcie_svt_uvm_pkgs.svi"
  `include `SVC_SOURCE_MAP_SUITE_UTIL_V(pcie_svc,PCIE,latest,svc_util_parms)
  `include `SVC_SOURCE_MAP_SUITE_MODEL_MODULE(pcie_svc,Include,latest,pciesvc_parms)
  `include "pcie_device_unified_vip_env.sv"
  `include "pcie_tl_svt_formal_test.sv"

  bit reset = 1'b1;
  int unsigned global_random_seed = 0;
  `include "hdl_interconnect_macros.sv"
  `include "pcie_tl_svt_pipe_topology.sv"

  pciesvc_global_shadow #(.DISPLAY_NAME("global_shadow0.")) global_shadow0();

  initial begin
    #200ns;
    reset = 1'b0;
  end

  initial begin
    string selected_test;
    repeat (100) #0;
    // 默认运行与 Serial 门禁相同的双向 formal 测试；其他测试可用标准
    // UVM_TESTNAME plusarg 选择，无需改顶层。
    if (!$value$plusargs("UVM_TESTNAME=%s", selected_test))
      selected_test = "pcie_tl_svt_formal_link_test";
    run_test(selected_test);
  end
endmodule
