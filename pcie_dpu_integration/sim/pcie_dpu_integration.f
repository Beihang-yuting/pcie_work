// DPU_COMMON_ROOT 指向独立 dpu_common 仓库根目录，而不是其父目录。
+incdir+$DPU_COMMON_ROOT/src
+incdir+../../pcie_tl_vip/src/topology
+incdir+../src
+incdir+../tests

$DPU_COMMON_ROOT/src/dpu_resource_pkg.sv
../../pcie_tl_vip/src/topology/pcie_topology_pkg.sv
../src/pcie_dpu_integration_pkg.sv
../tests/pcie_dpu_attachment_unit_test.sv
../tests/pcie_dpu_cfg_adapter_unit_test.sv
../tests/pcie_dpu_attachment_tb_top.sv
../tests/pcie_dpu_cfg_adapter_tb_top.sv
