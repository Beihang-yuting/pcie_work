//------------------------------------------------------------------------------
// 2 Host × 16 PF × 16 VF DPU 路线 example 的最小仿真顶层。
//
// 该顶层属于 pcie_dpu_integration/tests，由 pcie_dpu_example_env.f 收录。
// 全流程为纯 UVM class（TL-only、无物理链路），因此顶层只负责启动
// example test；接真实 DUT/SVT 时应换用带静态 HDL agent 的用户顶层。
//------------------------------------------------------------------------------
module pcie_dpu_2host_example_tb_top;
  import uvm_pkg::*;

  initial run_test("pcie_dpu_2host_16pf_16vf_example_test");
endmodule
