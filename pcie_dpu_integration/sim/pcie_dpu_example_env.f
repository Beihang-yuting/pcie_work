// 2 Host × 16 PF × 16 VF DPU 路线 example 的编译清单。
// 相对路径以本 sim 目录为基准。运行前设置：
//   DPU_COMMON_ROOT 指向独立 dpu_common 仓库根目录；
//   HOST_MEM_ROOT   指向 host_mem 项目根目录。
// 该 example 是 TL-only 纯 class 流程，不依赖 Synopsys SVT。

+incdir+$DPU_COMMON_ROOT/src
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
+incdir+../../pcie_tl_vip/src/switch
+incdir+../../pcie_tl_vip/src/topology
+incdir+../src
+incdir+../tests

$HOST_MEM_ROOT/src/host_mem_pkg.sv
$HOST_MEM_ROOT/src/host_mem_manager.sv
$DPU_COMMON_ROOT/src/dpu_resource_pkg.sv
../../pcie_tl_vip/src/pcie_tl_if.sv
../../pcie_tl_vip/src/shared/pcie_tl_bdf_utils_pkg.sv
../../pcie_tl_vip/src/shared/pcie_tl_device_profile_pkg.sv
../../pcie_tl_vip/src/topology/pcie_topology_pkg.sv
../../pcie_tl_vip/src/pcie_tl_pkg.sv
../src/pcie_dpu_integration_pkg.sv
../tests/pcie_dpu_2host_16pf_16vf_example.sv
../tests/pcie_dpu_2host_example_tb_top.sv
