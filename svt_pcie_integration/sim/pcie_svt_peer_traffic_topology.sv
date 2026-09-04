//------------------------------------------------------------------------------
// SVT peer traffic 验证的 HDL 拓扑（仅用于 test-only filelist）。
//
// 该文件故意不进入生产 TL-root filelist。它使用 Synopsys R-2020.12 官方
// Unified VIP 宏创建一个 Serial RC 与一个 Serial EP，并在 HDL 层完成回环
// 连接；UVM 侧由官方 pcie_device_unified_vip_env 管理两个 active agent。
//------------------------------------------------------------------------------

`ifndef PCIE_SVT_PEER_TRAFFIC_TOPOLOGY_SV
  `define PCIE_SVT_PEER_TRAFFIC_TOPOLOGY_SV

  // 一个 16-lane Serial 链路：port 0 为 RC，port 1 为 EP。
  `SVT_PCIE_ICM_CREATE_PORT_INST(0, 0)
  `SVT_PCIE_ICM_CREATE_PORT_INST(0, 1)

  `SVT_PCIE_ICM_CREATE_LINK(0, spd_0, spd_1)
  `SVT_PCIE_ICM_SER_SER_LINK(0, spd_0, spd_1)
  `SVT_PCIE_ICM_DO_CONDITIONAL_INTERCONNECT(0, spd_0, 1, spd_1)

  // 仅覆盖本验证入口所需参数；其余参数沿用官方宏默认值。
  defparam SVT_PCIE_UI_PHY_INTERFACE_TYPE_P0 =
    `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
  defparam SVT_PCIE_UI_DEVICE_IS_ROOT_P0 = 1;
  defparam SVT_PCIE_UI_NUM_PHYSICAL_LANES_P0 = 16;

  defparam SVT_PCIE_UI_PHY_INTERFACE_TYPE_P1 =
    `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
  defparam SVT_PCIE_UI_DEVICE_IS_ROOT_P1 = 0;
  defparam SVT_PCIE_UI_NUM_PHYSICAL_LANES_P1 = 16;

`endif
