// pcie_tl_vip filelist — portable VCS compilation entry
// Compile order: host_mem_pkg → pcie_tl_if → pcie_tl_pkg → test files → tb_top

// ---- host_mem incdir + files ----
+incdir+$HOST_MEM_ROOT/src
$HOST_MEM_ROOT/src/host_mem_pkg.sv
$HOST_MEM_ROOT/src/host_mem_manager.sv

// ---- pcie_tl_vip source incdirs ----
+incdir+../src
+incdir+../src/types
+incdir+../src/shared
+incdir+../src/agent
+incdir+../src/env
+incdir+../src/adapter
+incdir+../src/seq/base
+incdir+../src/seq/constraints
+incdir+../src/seq/scenario
+incdir+../src/seq/virtual
+incdir+../src/switch
+incdir+../src/topology

// ---- tests incdir (for test files compiled as separate units) ----
+incdir+../tests

// ---- pcie_tl interface (must precede package) ----
../src/pcie_tl_if.sv

// ---- standalone helpers imported by pcie_tl_pkg ----
../src/shared/pcie_tl_bdf_utils_pkg.sv
../src/shared/pcie_tl_device_profile_pkg.sv
../src/topology/pcie_topology_pkg.sv

// ---- pcie_tl top package (includes all src via relative `include) ----
../src/pcie_tl_pkg.sv

// ---- test files (separate compile units — each has top-level import) ----
../tests/pcie_tl_base_test.sv
../tests/pcie_tl_custom_base_test.sv
../tests/pcie_tl_custom_profile_test.sv
../tests/pcie_tl_smoke_test.sv
../tests/pcie_tl_advanced_test.sv
../tests/pcie_tl_unified_mem_test.sv
../tests/pcie_tl_switch_unified_mem_test.sv
../tests/pcie_tl_multi_root_unified_mem_binding_test.sv
../tests/pcie_tl_root_mapping_test.sv
../tests/pcie_tl_multi_root_route_test.sv
../tests/pcie_tl_cross_root_isolation_test.sv
../tests/pcie_tl_uneven_ownership_test.sv
../tests/pcie_tl_per_root_tag_test.sv
../tests/pcie_tl_multi_root_stress_test.sv
../tests/pcie_tl_multipair_heavy_test.sv
../tests/pcie_tl_tag_bit_runtime_test.sv
../tests/pcie_tl_rw_readback_test.sv
../tests/pcie_tl_switch_rw_readback_test.sv
../tests/pcie_tl_dpu_501x_profile_test.sv
../tests/pcie_tl_route_metadata_test.sv
../tests/pcie_tl_bar_state_test.sv
../tests/pcie_tl_bar_decoder_test.sv
../tests/pcie_tl_virtio_fix_regression_test.sv
../tests/pcie_tl_codec_regression_test.sv
../tests/pcie_topology_model_unit_test.sv
../tests/pcie_topology_builder_unit_test.sv
../tests/pcie_topology_validation_unit_test.sv
../tests/pcie_tl_topology_adapter_unit_test.sv
../tests/pcie_global_cfg_unit_test.sv
../tests/pcie_tl_device_cfg_adapter_unit_test.sv

// ---- testbench top module ----
../tests/pcie_tl_tb_top.sv
