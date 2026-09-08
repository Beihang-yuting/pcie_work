//------------------------------------------------------------------------------
// 1x1 PIPE RC ↔ EP 官方 HDL interconnect（Gen 参数化）。
//
// 该文件属于 svt_pcie_integration/sim，由 pcie_tl_svt_pipe_top.sv 在
// module 内 include，依赖官方 hdl_interconnect_macros.sv。与 Serial
// formal 拓扑的唯一差异是物理层：PHY_INTERFACE_TYPE 选 PIPE。
//
// PIPE spec 版本必须与 PCIe Gen 保持一致。SV 预处理只有存在性判断，
// 因此用编译宏选择档位（缺省 Gen3）：
//   （无宏）      → PCIe 3.0 + PIPE 4.3 + PIPE_PIPE_LINK（官方 pipe 示例）
//   +define+PCIE_PIPE_GEN4 → PCIe 4.0 + PIPE 4.4 + PIPE_PIPE_LINK
//   +define+PCIE_PIPE_GEN5 → PCIe 5.0 + PIPE 5.1 + PIPE5_PIPE5_LINK
//          （官方 pipe5 示例组合；PIPE5 的 pclk 方向由 CLK_FROM_MAC
//           参数联动，两端必须一致）
//
// 两端角色固定：RC 侧（spd_0）MPIPE=0（spipe），EP 侧（spd_1）
// MPIPE=1（mpipe）；x1 lane 是官方示例的已验证宽度，提速/加宽属于
// 后续增量。
//------------------------------------------------------------------------------

`ifndef PCIE_TL_SVT_PIPE_TOPOLOGY_SV
`define PCIE_TL_SVT_PIPE_TOPOLOGY_SV

`SVT_PCIE_ICM_CREATE_PORT_INST(0, 0)
`SVT_PCIE_ICM_CREATE_PORT_INST(0, 1)
`SVT_PCIE_ICM_CREATE_LINK(0, spd_0, spd_1)

`ifdef PCIE_PIPE_GEN5
  // Gen5 使用 PIPE5 专用互连宏；pclk 来源由 CLK_FROM_MAC 决定，官方
  // 宏要求把该参数一并传入以选择正确的时钟交叉连接。
  `SVT_PCIE_ICM_PIPE5_PIPE5_LINK(spd_0, spd_1,
                                 SVT_PCIE_UI_PIPE_CLK_FROM_MAC_P0)
`else
  `SVT_PCIE_ICM_PIPE_PIPE_LINK(0, spd_0, spd_1)
`endif

`SVT_PCIE_ICM_DO_CONDITIONAL_INTERCONNECT(0, spd_0, 1, spd_1)

//------------------------------------------------------------------------------
// RC 侧（spd_0）。
//------------------------------------------------------------------------------
defparam SVT_PCIE_UI_MPIPE_P0 = 0;
defparam SVT_PCIE_UI_PHY_INTERFACE_TYPE_P0 =
  `SVT_PCIE_UI_PHY_INTERFACE_TYPE_PIPE;
defparam SVT_PCIE_UI_DEVICE_IS_ROOT_P0 = 1;
defparam SVT_PCIE_UI_NUM_PHYSICAL_LANES_P0 = 1;
defparam SVT_PCIE_UI_MON_PHY_INTERFACE_TYPE_P0 =
  `SVT_PCIE_UI_PHY_INTERFACE_TYPE_PIPE;

//------------------------------------------------------------------------------
// EP 侧（spd_1）。
//------------------------------------------------------------------------------
defparam SVT_PCIE_UI_MPIPE_P1 = 1;
defparam SVT_PCIE_UI_PHY_INTERFACE_TYPE_P1 =
  `SVT_PCIE_UI_PHY_INTERFACE_TYPE_PIPE;
defparam SVT_PCIE_UI_DEVICE_IS_ROOT_P1 = 0;
defparam SVT_PCIE_UI_NUM_PHYSICAL_LANES_P1 = 1;

//------------------------------------------------------------------------------
// Gen ↔ PCIe/PIPE spec 版本联动。
//------------------------------------------------------------------------------
`ifdef PCIE_PIPE_GEN5
  defparam SVT_PCIE_UI_PCIE_SPEC_VER_P0 = `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
  defparam SVT_PCIE_UI_PIPE_SPEC_VER_P0 = `SVT_PCIE_UI_PIPE_SPEC_VER_5_1;
  defparam SVT_PCIE_UI_PCIE_SPEC_VER_P1 = `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
  defparam SVT_PCIE_UI_PIPE_SPEC_VER_P1 = `SVT_PCIE_UI_PIPE_SPEC_VER_5_1;

  // PIPE5 pclk 方向：官方示例按 PHY-output 编译宏联动两端一致取值。
  `ifdef SVT_PCIE_ENABLE_PIPE5_PCLK_AS_PHY_OUTPUT_MODE
    defparam SVT_PCIE_UI_PIPE_CLK_FROM_MAC_P0 = 0;
  `else
    defparam SVT_PCIE_UI_PIPE_CLK_FROM_MAC_P0 = 1;
  `endif
  defparam SVT_PCIE_UI_PIPE_CLK_FROM_MAC_P1 =
    SVT_PCIE_UI_PIPE_CLK_FROM_MAC_P0;
  defparam SVT_PCIE_UI_ENABLE_SHADOW_MEMORY_CHECKING_P0 = 1;
  defparam SVT_PCIE_UI_ENABLE_SHADOW_MEMORY_CHECKING_P1 = 1;
`elsif PCIE_PIPE_GEN4
  defparam SVT_PCIE_UI_PCIE_SPEC_VER_P0 = `SVT_PCIE_UI_PCIE_SPEC_VER_4_0;
  defparam SVT_PCIE_UI_PIPE_SPEC_VER_P0 = `SVT_PCIE_UI_PIPE_SPEC_VER_4_4;
  defparam SVT_PCIE_UI_PCIE_SPEC_VER_P1 = `SVT_PCIE_UI_PCIE_SPEC_VER_4_0;
  defparam SVT_PCIE_UI_PIPE_SPEC_VER_P1 = `SVT_PCIE_UI_PIPE_SPEC_VER_4_4;
`else
  defparam SVT_PCIE_UI_PCIE_SPEC_VER_P0 = `SVT_PCIE_UI_PCIE_SPEC_VER_3_0;
  defparam SVT_PCIE_UI_PIPE_SPEC_VER_P0 = `SVT_PCIE_UI_PIPE_SPEC_VER_4_3;
  defparam SVT_PCIE_UI_PCIE_SPEC_VER_P1 = `SVT_PCIE_UI_PCIE_SPEC_VER_3_0;
  defparam SVT_PCIE_UI_PIPE_SPEC_VER_P1 = `SVT_PCIE_UI_PIPE_SPEC_VER_4_3;
`endif

`endif
