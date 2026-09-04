//------------------------------------------------------------------------------
// SVT HDL 静态实例上限。
//
// TL-only 仿真不会包含本文件；只有真实 SVT Serial/PIPE 适配顶层需要它。
// 用户可在编译命令行以 PCIE_SVT_ENV_MAX_NUM_LINKS 覆盖默认值，避免为
// 未启用的拓扑实例化多余 HDL agent。
//------------------------------------------------------------------------------
`ifndef PCIE_SVT_ENV_MAX_NUM_LINKS
  `ifdef PCIE_TOPO_EP_X16
    `define PCIE_SVT_ENV_MAX_NUM_LINKS 1
  `elsif PCIE_TOPO_EP_2X8
    `define PCIE_SVT_ENV_MAX_NUM_LINKS 2
  `elsif PCIE_TOPO_SWITCH_1X16_4X4
    `define PCIE_SVT_ENV_MAX_NUM_LINKS 5
  `else
    `define PCIE_SVT_ENV_MAX_NUM_LINKS 1
  `endif
`endif

// 兼容旧宏名称；新代码统一使用 PCIE_SVT_ENV_MAX_NUM_LINKS。
`ifndef PCIE_SVT_ENV_REQUIRED_HDL_AGENTS
  `define PCIE_SVT_ENV_REQUIRED_HDL_AGENTS `PCIE_SVT_ENV_MAX_NUM_LINKS
`endif

`ifndef PCIE_SVT_ENV_MAX_HDL_AGENTS
  `define PCIE_SVT_ENV_MAX_HDL_AGENTS `PCIE_SVT_ENV_MAX_NUM_LINKS
`endif
