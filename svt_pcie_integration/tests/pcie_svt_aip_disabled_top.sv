//------------------------------------------------------------------------------
// 所属层次：svt_pcie_integration/tests；可选 AIP sequence 的禁用编译门禁。
// 职责：不定义 PCIE_ENABLE_AIP_CMDS、不加载 UVM/AIP/SVT，仍包含可选文件，
//       确认其禁用分支没有泄漏外部类型、package 或宏依赖。
// 资源与生命周期：仅有一个 initial 进程，不创建 VIP、句柄或事务；
//                 输出通过标记后结束，不代表启用分支或物理链路通过。
//------------------------------------------------------------------------------
`timescale 1ns/1ps
`include "pcie_svt_aip_seqs.sv"

module pcie_svt_aip_disabled_top;
  // 编译能够到达本进程即说明无需外部依赖；启用宏的测试使用另一顶层。
  initial begin
    $display("PCIE_AIP_DISABLED_PASS dependencies=none");
    $finish;
  end
endmodule
