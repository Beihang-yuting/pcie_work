//------------------------------------------------------------------------------
// 测试专用：AIP Tcl -> backend RC + 外部 SVT EP 的 x16 Serial 建链。
// 依赖 DESIGNWARE_HOME / PCIE_SVT_ROOT / HOST_MEM_ROOT / AIP_CORE。
// 保持已验证 formal Serial 源顺序和 1fs 精度；不修改生产 adapter filelist。
// AIP package 由 test-only top 在 module 外包含，socket DPI 仅满足统一包的链接依赖。
//------------------------------------------------------------------------------

-sverilog
-timescale=1ns/1fs

+incdir+$AIP_CORE
+incdir+$AIP_CORE/src/sv
+incdir+../rtl
+incdir+../tests
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
+incdir+$PCIE_SVT_ROOT/examples/sverilog/tb_pcie_svt_uvm_unified_vip_sys
+incdir+$DESIGNWARE_HOME/vip/svt/common/R-2020.12/sverilog/include

+define+DESIGNWARE_INCDIR=$DESIGNWARE_HOME
+define+SVT_LOADER_UTIL_ENABLE_DWHOME_INCDIRS
+define+SVT_PCIE_ENABLE_10_BIT_TAGS
+define+SVT_PCIE_ENABLE_MONITOR
+define+SVT_PCIE_ENABLE_GEN4
+define+EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH=pcie_svt_aip_link_top.global_shadow0
+define+SVC_RANDOM_SEED_SCOPE=pcie_svt_aip_link_top.global_random_seed
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
../rtl/pcie_svt_vip_bootstrap.sv
../uvm/adapter/pcie_svt_adapter_pkg.sv
../rtl/pcie_svt_aip_link_top.sv
$AIP_CORE/src/c/runtime/sv_socket_dpi.c
