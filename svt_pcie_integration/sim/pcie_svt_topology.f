+incdir+../rtl
+incdir+../uvm
+incdir+../uvm/cfg
+incdir+../uvm/env
+incdir+../uvm/tests
+incdir+../../pcie_tl_vip/src/topology
+incdir+$PCIE_SVT_ROOT/sverilog/include
+incdir+$PCIE_SVT_ROOT/examples/sverilog/tb_pcie_svt_uvm_unified_vip_sys/env
+incdir+$DESIGNWARE_HOME/vip/svt/common/R-2020.12/sverilog/include
+define+DESIGNWARE_INCDIR=$DESIGNWARE_HOME
+define+SVT_LOADER_UTIL_ENABLE_DWHOME_INCDIRS
+define+SVT_PCIE_ENABLE_10_BIT_TAGS
-y $PCIE_SVT_ROOT/verilog/src/vcs
-y $PCIE_SVT_ROOT/sverilog/src/vcs
../rtl/pcie_svt_vip_bootstrap.sv
../rtl/pcie_svt_serial_port_if.sv
../rtl/pcie_svt_reset_if.sv
../rtl/pcie_svt_serial_adapter.sv
../rtl/pcie_svt_dut_wrapper.sv
../../pcie_tl_vip/src/topology/pcie_topology_pkg.sv
../uvm/pcie_svt_topology_pkg.sv
../uvm/tests/pcie_svt_topology_model_unit_test.sv
../uvm/tests/pcie_svt_topology_adapter_unit_test.sv
../uvm/tests/pcie_svt_cli_parser_unit_test.sv
../uvm/tests/pcie_svt_device_cfg_unit_test.sv
../uvm/tests/pcie_svt_topology_base_test.sv
../rtl/pcie_svt_topology_env_top.sv
