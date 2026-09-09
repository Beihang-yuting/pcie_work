// svt_pcie_integration/rtl/pcie_svt_vip_bootstrap.sv
//
// 职责：把 Synopsys SVT PCIe 官方 package（svt_uvm_pkg / svt_pcie_uvm_pkg）
// 编译进当前 VCS 会话。任何 import 这些包的入口（adapter/formal/pipe/
// peer-traffic filelist）都必须保证本文件在 pcie_svt_adapter_pkg 等使用方
// 之前展开一次、且仅一次。
//
// 跳过开关：若外部环境（更大的集成流程）已经用别的方式编译了 SVT 包，
// 在 filelist 中 +define+PCIE_SVT_PKG_EXTERNAL 可整体跳过本文件，避免
// package 重复定义。
//
// 两个 HDL 层次宏均为可选（查证 R-2020.12 源码）：
// - SVC_RANDOM_SEED_SCOPE：未定义时 SVT 内部回退 $random（全局种子），
//   定义后可把随机种子锚定到用户顶层变量以获得可复现随机序列；
// - EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH：仅官方 example top 引用，
//   使用官方 hdl_interconnect/example env 时需在顶层实例化
//   pciesvc_global_shadow 并把宏指向该实例（参考 pcie_tl_svt_formal_top）。
// 需要上述能力的顶层应在 include 本文件之前定义对应宏。
`ifndef PCIE_SVT_PKG_EXTERNAL
`include "svt_pcie.uvm.pkg"
`endif
