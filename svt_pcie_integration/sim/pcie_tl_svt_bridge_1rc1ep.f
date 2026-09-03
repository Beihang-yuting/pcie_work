//------------------------------------------------------------------------------
// 1RC + 1EP Serial bridge compile/elaboration example.
//
// 文件列表按依赖方向排列：TL 基础包 -> SVT bridge/适配器包 -> Unified SVT
// 包 -> HDL Serial 接口与 placeholder -> 本例顶层及测试。SVT 包内部会按
// pcie_svt_topology_pkg.sv 的顺序包含 adapter package，避免重复声明。
//------------------------------------------------------------------------------

+define+PCIE_SVT_AVAILABLE
+define+PCIE_TOPO_EP_X16

// SVT 发行版和 TL 源码被 VCS 合并到同一个 compilation unit；统一默认
// timescale，避免 SVT `` `timescale`` 与前置 package 的隐式 timescale 冲突。
-timescale=1ns/1ps

+incdir+../rtl
+incdir+../uvm
+incdir+../uvm/cfg
+incdir+../uvm/callbacks
+incdir+../uvm/env
+incdir+../uvm/adapter
+incdir+../uvm/backend
+incdir+../uvm/sequences
+incdir+../uvm/tests
+incdir+$HOST_MEM_ROOT/src

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
+incdir+../../pcie_tl_vip/src/topology
+incdir+$PCIE_SVT_ROOT/sverilog/include
+incdir+$PCIE_SVT_ROOT/examples/sverilog/tb_pcie_svt_uvm_unified_vip_sys/env
+incdir+$DESIGNWARE_HOME/vip/svt/common/R-2020.12/sverilog/include

+define+DESIGNWARE_INCDIR=$DESIGNWARE_HOME
+define+SVT_LOADER_UTIL_ENABLE_DWHOME_INCDIRS
+define+SVT_PCIE_ENABLE_10_BIT_TAGS
-y $PCIE_SVT_ROOT/verilog/src/vcs
-y $PCIE_SVT_ROOT/sverilog/src/vcs

// TL package and its package dependencies (first).
$HOST_MEM_ROOT/src/host_mem_pkg.sv
../../pcie_tl_vip/src/pcie_tl_if.sv
../../pcie_tl_vip/src/shared/pcie_tl_bdf_utils_pkg.sv
../../pcie_tl_vip/src/shared/pcie_tl_device_profile_pkg.sv
../../pcie_tl_vip/src/topology/pcie_topology_pkg.sv
../../pcie_tl_vip/src/pcie_tl_pkg.sv

// SVT bootstrap and RTL interface declarations must precede the UVM package:
// the package's environment classes use these interface types in signatures.
../rtl/pcie_svt_vip_bootstrap.sv
../rtl/pcie_svt_serial_port_if.sv
../rtl/pcie_svt_reset_if.sv
../rtl/pcie_svt_serial_adapter.sv

// Unified SVT package.  Its adapter package includes route metadata, codec,
// Mapper bridge, and the TL-facing adapter exactly once.
../uvm/pcie_svt_topology_pkg.sv

// No-DUT electrical-idle wrapper.
../rtl/pcie_svt_dut_wrapper.sv

// Environment top and the dedicated 1RC+1EP bridge test.
pcie_tl_svt_bridge_1rc1ep_tb.sv
