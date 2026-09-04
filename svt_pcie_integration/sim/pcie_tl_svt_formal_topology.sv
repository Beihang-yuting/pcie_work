//------------------------------------------------------------------------------
// 1x16 Serial RC ↔ EP 官方 HDL interconnect。
//------------------------------------------------------------------------------

`ifndef PCIE_TL_SVT_FORMAL_TOPOLOGY_SV
`define PCIE_TL_SVT_FORMAL_TOPOLOGY_SV

`SVT_PCIE_ICM_CREATE_PORT_INST(0, 0)
`SVT_PCIE_ICM_CREATE_PORT_INST(0, 1)
`SVT_PCIE_ICM_CREATE_LINK(0, spd_0, spd_1)
`SVT_PCIE_ICM_SER_SER_LINK(0, spd_0, spd_1)
`SVT_PCIE_ICM_DO_CONDITIONAL_INTERCONNECT(0, spd_0, 1, spd_1)

defparam SVT_PCIE_UI_PHY_INTERFACE_TYPE_P0 =
  `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
defparam SVT_PCIE_UI_DEVICE_IS_ROOT_P0 = 1;
defparam SVT_PCIE_UI_NUM_PHYSICAL_LANES_P0 = 16;

defparam SVT_PCIE_UI_PHY_INTERFACE_TYPE_P1 =
  `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
defparam SVT_PCIE_UI_DEVICE_IS_ROOT_P1 = 0;
defparam SVT_PCIE_UI_NUM_PHYSICAL_LANES_P1 = 16;

`endif
