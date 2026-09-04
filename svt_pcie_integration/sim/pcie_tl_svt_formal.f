//------------------------------------------------------------------------------
// 正式 SVT agent + TL-root adapter 双向 Serial 门禁 filelist。
//------------------------------------------------------------------------------

-sverilog
-timescale=1ns/1fs

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
+define+EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH=pcie_tl_svt_formal_top.global_shadow0
+define+SVC_RANDOM_SEED_SCOPE=pcie_tl_svt_formal_top.global_random_seed
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
../rtl/pcie_tl_svt_formal_top.sv
