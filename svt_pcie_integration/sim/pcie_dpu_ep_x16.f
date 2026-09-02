// DPU-aware EP x16 example.  The native pcie_svt_topology.f remains usable
// without dpu-common; this companion list adds the optional system layer.
-f pcie_svt_topology.f

+incdir+$DPU_COMMON_ROOT/dpu_common/src
+incdir+../../pcie_dpu_integration/src
+incdir+../../pcie_dpu_integration/tests

$DPU_COMMON_ROOT/dpu_common/src/dpu_resource_pkg.sv
../../pcie_dpu_integration/src/pcie_dpu_integration_pkg.sv
../../pcie_dpu_integration/src/pcie_dpu_tl_reg_executor.sv
../uvm/backend/pcie_dpu_svt_reg_executor.sv
../../pcie_dpu_integration/src/pcie_dpu_system_pkg.sv
../../pcie_dpu_integration/tests/pcie_dpu_ep_x16_test.sv
