//------------------------------------------------------------------------------
// Test-only SVT RC/EP peer traffic filelist。
//
// 运行前需设置 PCIE_SVT_ROOT 和 DESIGNWARE_HOME。官方 env、interconnect 宏
// 和 SVT HDL model 均从安装目录读取；本入口不改动生产 TL-root filelist。
//------------------------------------------------------------------------------

-sverilog
-timescale=1ns/1fs

+incdir+../rtl
+incdir+../tests
+incdir+.
+incdir+$PCIE_SVT_ROOT/sverilog/include
+incdir+$PCIE_SVT_ROOT/examples/sverilog/tb_pcie_svt_uvm_unified_vip_sys
+incdir+$PCIE_SVT_ROOT/examples/sverilog/tb_pcie_svt_uvm_unified_vip_sys/env
+incdir+$DESIGNWARE_HOME/vip/svt/common/R-2020.12/sverilog/include

+define+DESIGNWARE_INCDIR=$DESIGNWARE_HOME
+define+SVT_LOADER_UTIL_ENABLE_DWHOME_INCDIRS
+define+SVT_PCIE_ENABLE_10_BIT_TAGS
+define+SVT_PCIE_ENABLE_GEN4
+define+EXPERTIO_PCIESVC_INCLUDE_8G
+define+EXPERTIO_PCIESVC_INCLUDE_16G

-y $PCIE_SVT_ROOT/verilog/src/vcs
-y $PCIE_SVT_ROOT/sverilog/src/vcs

// 顶层会按官方示例顺序 include package、env、interconnect、拓扑和自定义
// test；filelist 只编译本入口顶层，避免 test 在错误的 compilation unit
// 中找不到官方 pcie_device_base_test。
../rtl/pcie_svt_peer_traffic_top.sv
