// SVT 官方 package 要求集成顶层在编译前提供这两个 HDL 层次宏。
// 这里不再提供旧占位 top 的默认层次，避免 source-only adapter filelist
// 意外绑定到已经删除的测试顶层。正式 formal/user top 必须在包含本文件
// 之前定义自己的 global_shadow 和 global_random_seed 路径。
`ifndef EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH
  `error "Define EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH before including pcie_svt_vip_bootstrap.sv"
`endif

`ifndef SVC_RANDOM_SEED_SCOPE
  `error "Define SVC_RANDOM_SEED_SCOPE before including pcie_svt_vip_bootstrap.sv"
`endif
`include "svt_pcie.uvm.pkg"
