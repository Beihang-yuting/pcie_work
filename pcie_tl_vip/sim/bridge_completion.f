// 复用native生产/测试源，仅追加既有fake-provider合同和派生Completion回归。
-f $PCIE_WORK_ROOT/pcie_tl_vip/sim/native_sv_if.f
$PCIE_WORK_ROOT/pcie_tl_vip/tests/pcie_tl_backend_provider_unit_test.sv
$PCIE_WORK_ROOT/pcie_tl_vip/tests/pcie_tl_bridge_completion_test.sv
