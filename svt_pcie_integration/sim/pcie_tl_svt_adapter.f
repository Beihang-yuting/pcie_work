//------------------------------------------------------------------------------
// 生产 TL-root + SVT adapter 源文件列表。
//
// 该 filelist 只编译 TL 控制面和 SVT 编解码/Mapper 适配层，不再包含
// 没有真实 SVT agent 的占位 test/top。真实 DUT 工程应将本列表作为源文件
// 基础，并在自己的 filelist 中追加 DUT top、SVT HDL agent 和 test。
//------------------------------------------------------------------------------

-timescale=1ns/1ps

+incdir+../rtl
+incdir+../uvm
+incdir+../uvm/adapter
+incdir+../../pcie_tl_vip/src
+incdir+../../pcie_tl_vip/src/types
+incdir+../../pcie_tl_vip/src/shared
+incdir+../../pcie_tl_vip/src/agent
+incdir+../../pcie_tl_vip/src/env
+incdir+../../pcie_tl_vip/src/adapter
+incdir+../../pcie_tl_vip/src/seq/base
+incdir+../../pcie_tl_vip/src/seq/constraints
+incdir+../../pcie_tl_vip/src/seq/scenario
+incdir+../../pcie_tl_vip/src/seq/virtual
+incdir+../../pcie_tl_vip/src/switch
+incdir+../../pcie_tl_vip/src/topology
+incdir+$HOST_MEM_ROOT/src
+incdir+$PCIE_SVT_ROOT/sverilog/include
+incdir+$PCIE_SVT_ROOT/examples/sverilog/tb_pcie_svt_uvm_unified_vip_sys/env
+incdir+$DESIGNWARE_HOME/vip/svt/common/R-2020.12/sverilog/include

+define+DESIGNWARE_INCDIR=$DESIGNWARE_HOME
+define+SVT_LOADER_UTIL_ENABLE_DWHOME_INCDIRS
+define+SVT_PCIE_ENABLE_10_BIT_TAGS
+define+PCIE_TOPO_EP_X16

+define+EXPERTIO_PCIESVC_INCLUDE_8G
+define+EXPERTIO_PCIESVC_INCLUDE_16G

-y $PCIE_SVT_ROOT/verilog/src/vcs
-y $PCIE_SVT_ROOT/sverilog/src/vcs

$HOST_MEM_ROOT/src/host_mem_pkg.sv
$HOST_MEM_ROOT/src/host_mem_manager.sv
../../pcie_tl_vip/src/pcie_tl_if.sv
../../pcie_tl_vip/src/shared/pcie_tl_bdf_utils_pkg.sv
../../pcie_tl_vip/src/shared/pcie_tl_device_profile_pkg.sv
../../pcie_tl_vip/src/topology/pcie_topology_pkg.sv
../../pcie_tl_vip/src/pcie_tl_pkg.sv

// adapter package 会 import svt_uvm_pkg/svt_pcie_uvm_pkg，官方
// svt_pcie.uvm.pkg 必须先于 adapter package 编译。本列表默认通过
// bootstrap 自行完成该编译，因此单独 -f 本列表即可通过编译（两个
// HDL 层次宏 EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH / SVC_RANDOM_SEED_SCOPE
// 为可选，详见 bootstrap 头注释）。若外部集成流程已在别处编译了
// SVT 包，请 +define+PCIE_SVT_PKG_EXTERNAL 跳过 bootstrap，避免
// package 重复定义。
../rtl/pcie_svt_vip_bootstrap.sv

// SVT adapter package（仅适配层，不引入 topology env）。
../uvm/adapter/pcie_svt_adapter_pkg.sv
