//------------------------------------------------------------------------------
// 生产 TL-root + SVT adapter 最小 filelist（1RC + 1EP）。
//
// 该 filelist 不包含 pcie_svt_topology_pkg、peer harness 或旧 unified env；
// 只编译 TL 控制面、SVT 编解码/Mapper 适配层和最小门禁 test。
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
+define+PCIE_SVT_AVAILABLE
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

// SVT 官方 UVM 包必须先于 adapter package 定义；adapter 只使用其公开
// svt_pcie_tlp/mapper/device-agent 类型，不重复加载 SVT 源码。
../rtl/pcie_svt_vip_bootstrap.sv

// SVT adapter package（仅适配层，不引入 topology env）。
../uvm/adapter/pcie_svt_adapter_pkg.sv

../tests/pcie_tl_svt_adapter_base_test.sv
../tests/pcie_tl_svt_adapter_link_test.sv
../tests/pcie_tl_svt_adapter_tb_top.sv
