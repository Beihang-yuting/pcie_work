//------------------------------------------------------------------------------
// svt_pcie_integration/rtl：TL-root + 正式 SVT agent Serial 验证顶层。
// 依赖 SVT 官方 HDL interconnect 与 integration 测试类；持有静态 RC/EP
// HDL、共享 shadow 和 reset，UVM test 拥有动态 agent/cfg。默认运行双向
// 数据面门禁，其他契约/EQ 测试通过 UVM_TESTNAME 选择，不自动叠加启动。
//------------------------------------------------------------------------------

`timescale 1ns/1fs
module pcie_tl_svt_formal_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "import_pcie_svt_uvm_pkgs.svi"
  `include `SVC_SOURCE_MAP_SUITE_UTIL_V(pcie_svc,PCIE,latest,svc_util_parms)
  `include `SVC_SOURCE_MAP_SUITE_MODEL_MODULE(pcie_svc,Include,latest,pciesvc_parms)
  `include "pcie_device_unified_vip_env.sv"
  `include "pcie_tl_svt_formal_test.sv"
  `include "pcie_svt_backend_auto_link_test.sv"
  `include "pcie_svt_backend_cfg_unit_test.sv"
  `include "pcie_svt_backend_eq_test.sv"

  bit reset = 1'b1;
  int unsigned global_random_seed = 0;
  `include "hdl_interconnect_macros.sv"
  `include "pcie_tl_svt_formal_topology.sv"

  // 本顶层没有外部 TX bit clock；与生产 PCIE_SVT_DECLARE_HDL_AGENT 宏及
  // 已验证的 AIP 顶层一致，显式选择 SVT 内部时钟。官方互连默认 mode=1
  // 会让不依赖官方 env 时钟覆盖的 backend EQ 用例停在 INITIAL。
  defparam SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE_P0 = 1'b0;
  defparam SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE_P1 = 1'b0;

  pciesvc_global_shadow #(.DISPLAY_NAME("global_shadow0.")) global_shadow0();

  initial begin
    #200ns;
    reset = 1'b0;
  end

  initial begin
    string selected_test;
    repeat (100) #0;
    // 默认保持原有双向 formal 门禁；配置契约可通过标准 UVM_TESTNAME
    // plusarg 单独运行，避免修改顶层或重新编译另一套 testbench。
    if (!$value$plusargs("UVM_TESTNAME=%s", selected_test))
      selected_test = "pcie_tl_svt_formal_link_test";
    run_test(selected_test);
  end
endmodule
