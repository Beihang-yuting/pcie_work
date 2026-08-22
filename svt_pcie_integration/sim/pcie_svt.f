+incdir+../rtl
+incdir+../uvm
+incdir+../uvm/sequences
+incdir+../../pcie_tl_vip/src
+define+DESIGNWARE_INCDIR=$DESIGNWARE_HOME
+define+SVT_LOADER_UTIL_ENABLE_DWHOME_INCDIRS
+define+SVT_PCIE_ENABLE_10_BIT_TAGS
+incdir+$PCIE_SVT_ROOT/sverilog/include
+incdir+$DESIGNWARE_HOME/vip/svt/common/R-2020.12/sverilog/include
-y $PCIE_SVT_ROOT/verilog/src/vcs
-y $PCIE_SVT_ROOT/sverilog/src/vcs
../rtl/pcie_svt_vip_bootstrap.sv
../rtl/pcie_svt_serial_port_if.sv
../rtl/pcie_svt_reset_if.sv
../rtl/pcie_svt_serial_adapter.sv
../rtl/pcie_svt_peer_harness.sv
../rtl/pcie_dut_placeholder.sv
../rtl/pcie_switch_dut_wrapper.sv
../../pcie_tl_vip/src/pcie_tl_switch_pkg.sv
../uvm/pcie_svt_integration_pkg.sv
../uvm/pcie_svt_switch_proxy_test.sv
../uvm/pcie_svt_real_switch_test.sv
../rtl/pcie_svt_topology_top.sv
