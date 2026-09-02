-f pcie_svt_topology.f

+incdir+$DPU_COMMON_ROOT/dpu_common/src
+incdir+../../pcie_dpu_integration/src
+incdir+../uvm/backend
+incdir+../uvm/tests

$DPU_COMMON_ROOT/dpu_common/src/dpu_resource_pkg.sv
../../pcie_dpu_integration/src/pcie_dpu_integration_pkg.sv
../uvm/backend/pcie_dpu_svt_reg_executor.sv
../uvm/tests/pcie_dpu_svt_reg_executor_unit_test.sv
../uvm/tests/pcie_dpu_svt_reg_executor_tb_top.sv
