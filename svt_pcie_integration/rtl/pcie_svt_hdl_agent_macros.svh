//------------------------------------------------------------------------------
// SVT 单端 HDL agent 声明宏（Serial / PIPE 通用）。
//
// 该文件属于 svt_pcie_integration/rtl，由真实 DUT 集成顶层 include。
// 三个宏 PCIE_SVT_DECLARE_HDL_AGENT_X4/X8/X16 是唯一的声明入口：调用
// 行与参数在两种物理层下完全一致（instance_name、display_name、
// clkreq、wake、reset、is_root、hierarchy），update_if_variables 与
// vif_key 约定也不变。物理层由编译宏选择：
//
//   默认                          → SERDES（Serial），展开产物含
//                                    <name>_serial（pcie_svt_serial_port_if）
//   +define+PCIE_SVT_HDL_PHY_PIPE → PIPE，DUT 直接对接
//                                    <name>_spd.vip_port_if.pipe_if 的
//                                    逐 lane 信号；不生成 <name>_serial
//
// PIPE 模式下 PIPE/PCIe spec 版本与 Gen 档位联动（与
// pcie_tl_svt_pipe_topology.sv 相同的档位宏）：
//   （无档位宏）            → PCIe 3.0 + PIPE 4.3
//   +define+PCIE_PIPE_GEN4  → PCIe 4.0 + PIPE 4.4
//   +define+PCIE_PIPE_GEN5  → PCIe 5.0 + PIPE 5.1（还需官方
//     SVT_PCIE_ENABLE_GEN5 / SVT_PCIE_ENABLE_PIPE5 /
//     EXPERTIO_PCIESVC_INCLUDE_32G 三宏，见 sim/README.md）
//
// MPIPE 侧别由 is_root 自动推导：SVT 作 Root 时是 spipe（MPIPE=0），
// 作 Endpoint 时是 mpipe（MPIPE=1）——与官方双 VIP PIPE 拓扑一致，
// 用户无需新增参数。
//
// 注意：pipe_if.reset 在官方 interface 中是 logic 变量，只允许单一
// 结构驱动，因此 PIPE 模式下宏内**不**驱动它（reset_signal 参数保留
// 以维持与 Serial 版一致的签名）。复位归互连层：
//   * 双 VIP 对拼：官方 SVT_PCIE_ICM_PIPE_PIPE_LINK 已把两侧
//     pipe_if.reset 接到 common_pwr_on_reset；
//   * 真实 DUT 单侧：用户顶层自行
//     assign <name>_spd.vip_port_if.pipe_if.reset = <复位信号>;
//------------------------------------------------------------------------------
`ifndef PCIE_SVT_HDL_AGENT_MACROS_SVH
`define PCIE_SVT_HDL_AGENT_MACROS_SVH

`include "pcie_svt_hdl_slot_cfg.svh"

`ifdef PCIE_SVT_HDL_PHY_PIPE

//------------------------------------------------------------------------------
// PIPE 物理层版本。
//------------------------------------------------------------------------------

// 向量化 PIPE 端口与散名映射宏（与 Serial 版 serial_adapter 对称）。
`include "pcie_svt_pipe_adapter.sv"

// Gen 档位 → PCIe/PIPE spec 的中间宏（宏体内不能再写 `ifdef，先在
// 文件级解析档位）。
`ifdef PCIE_PIPE_GEN5
  `define PCIE_SVT_HDL_PCIE_SPEC `SVT_PCIE_UI_PCIE_SPEC_VER_5_0
  `define PCIE_SVT_HDL_PIPE_SPEC `SVT_PCIE_UI_PIPE_SPEC_VER_5_1
`elsif PCIE_PIPE_GEN4
  `define PCIE_SVT_HDL_PCIE_SPEC `SVT_PCIE_UI_PCIE_SPEC_VER_4_0
  `define PCIE_SVT_HDL_PIPE_SPEC `SVT_PCIE_UI_PIPE_SPEC_VER_4_4
`else
  `define PCIE_SVT_HDL_PCIE_SPEC `SVT_PCIE_UI_PCIE_SPEC_VER_3_0
  `define PCIE_SVT_HDL_PIPE_SPEC `SVT_PCIE_UI_PIPE_SPEC_VER_4_3
`endif

// PIPE 公共展开体：lane 数是唯一逐宽度差异，用内部基宏承载。
// 展开产物：<name>_if（svt_pcie_if）、<name>_spd（HDL agent）。
// DUT 侧对接 <name>_spd.vip_port_if.pipe_if 的 tx_*/rx_* 逐 lane 信号。
`define PCIE_SVT_DECLARE_HDL_AGENT_PIPE_BASE(instance_name, display_name, clkreq_signal, wake_signal, reset_signal, is_root, hierarchy, lanes) \
  svt_pcie_if instance_name``_if(clkreq_signal, wake_signal);              \
  svt_pcie_single_port_device_agent_hdl #(                                \
    .SVT_PCIE_UI_PCIE_SPEC_VER(`PCIE_SVT_HDL_PCIE_SPEC),                  \
    .SVT_PCIE_UI_PIPE_SPEC_VER(`PCIE_SVT_HDL_PIPE_SPEC),                  \
    .SVT_PCIE_UI_DISPLAY_NAME(display_name),                               \
    .SVT_PCIE_UI_PHY_INTERFACE_TYPE(                                       \
      `SVT_PCIE_UI_PHY_INTERFACE_TYPE_PIPE),                               \
    .SVT_PCIE_UI_MON_PHY_INTERFACE_TYPE(                                   \
      `SVT_PCIE_UI_PHY_INTERFACE_TYPE_PIPE),                               \
    .SVT_PCIE_UI_MPIPE((is_root) ? 0 : 1),                                 \
    .SVT_PCIE_UI_ENABLE_CFG_BLOCK(1'b1),                                   \
    .SVT_PCIE_UI_CONNECT_ACTIVE_VIP(1'b1),                                 \
    .SVT_PCIE_UI_NUM_PHYSICAL_LANES(lanes),                                \
    .SVT_PCIE_UI_DEVICE_IS_ROOT(is_root),                                  \
    .SVT_PCIE_UI_HIERARCHY_NUMBER(hierarchy)                               \
  ) instance_name``_spd(                                                   \
    instance_name``_if);

// 每个宽度外壳在基宏之上追加：向量化端口 <name>_pipe + 散名映射。
// DUT/对端只对接 <name>_pipe（或用 PCIE_SVT_PIPE_PORT_CROSS_Xn 与另一
// 实例的 port 对拼），与 Serial 版 <name>_serial 的体验一致。
`define PCIE_SVT_DECLARE_HDL_AGENT_X4(instance_name, display_name, clkreq_signal, wake_signal, reset_signal, is_root, hierarchy) \
  `PCIE_SVT_DECLARE_HDL_AGENT_PIPE_BASE(instance_name, display_name, clkreq_signal, wake_signal, reset_signal, is_root, hierarchy, 4) \
  pcie_svt_pipe_port_if #(4) instance_name``_pipe();                       \
  `PCIE_SVT_MAP_PIPE_X4(instance_name``_spd, instance_name``_pipe, is_root)

`define PCIE_SVT_DECLARE_HDL_AGENT_X8(instance_name, display_name, clkreq_signal, wake_signal, reset_signal, is_root, hierarchy) \
  `PCIE_SVT_DECLARE_HDL_AGENT_PIPE_BASE(instance_name, display_name, clkreq_signal, wake_signal, reset_signal, is_root, hierarchy, 8) \
  pcie_svt_pipe_port_if #(8) instance_name``_pipe();                       \
  `PCIE_SVT_MAP_PIPE_X8(instance_name``_spd, instance_name``_pipe, is_root)

`define PCIE_SVT_DECLARE_HDL_AGENT_X16(instance_name, display_name, clkreq_signal, wake_signal, reset_signal, is_root, hierarchy) \
  `PCIE_SVT_DECLARE_HDL_AGENT_PIPE_BASE(instance_name, display_name, clkreq_signal, wake_signal, reset_signal, is_root, hierarchy, 16) \
  pcie_svt_pipe_port_if #(16) instance_name``_pipe();                      \
  `PCIE_SVT_MAP_PIPE_X16(instance_name``_spd, instance_name``_pipe, is_root)

`else  // !PCIE_SVT_HDL_PHY_PIPE

//------------------------------------------------------------------------------
// SERDES（Serial）物理层版本——历史默认，展开产物与既有用户顶层兼容。
//------------------------------------------------------------------------------

`define PCIE_SVT_DECLARE_HDL_AGENT_X4(instance_name, display_name, clkreq_signal, wake_signal, reset_signal, is_root, hierarchy) \
  svt_pcie_if instance_name``_if(clkreq_signal, wake_signal);              \
  svt_pcie_single_port_device_agent_hdl #(                                \
    .SVT_PCIE_UI_PCIE_SPEC_VER(`SVT_PCIE_UI_PCIE_SPEC_VER_5_0),           \
    .SVT_PCIE_UI_DISPLAY_NAME(display_name),                               \
    .SVT_PCIE_UI_PHY_INTERFACE_TYPE(                                       \
      `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES),                             \
    .SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE(1'b1),                            \
    .SVT_PCIE_UI_ENABLE_CFG_BLOCK(1'b1),                                   \
    .SVT_PCIE_UI_CONNECT_ACTIVE_VIP(1'b1),                                 \
    .SVT_PCIE_UI_NUM_PHYSICAL_LANES(4),                                    \
    .SVT_PCIE_UI_DEVICE_IS_ROOT(is_root),                                  \
    .SVT_PCIE_UI_HIERARCHY_NUMBER(hierarchy)                               \
  ) instance_name``_spd(                                                   \
    instance_name``_if);                                                   \
  pcie_svt_serial_port_if #(4) instance_name``_serial();                   \
  `PCIE_SVT_MAP_SERDES_X4(instance_name``_spd, instance_name``_serial)     \
  assign instance_name``_spd.vip_port_if.ser_if.reset = reset_signal;

`define PCIE_SVT_DECLARE_HDL_AGENT_X8(instance_name, display_name, clkreq_signal, wake_signal, reset_signal, is_root, hierarchy) \
  svt_pcie_if instance_name``_if(clkreq_signal, wake_signal);              \
  svt_pcie_single_port_device_agent_hdl #(                                \
    .SVT_PCIE_UI_PCIE_SPEC_VER(`SVT_PCIE_UI_PCIE_SPEC_VER_5_0),           \
    .SVT_PCIE_UI_DISPLAY_NAME(display_name),                               \
    .SVT_PCIE_UI_PHY_INTERFACE_TYPE(                                       \
      `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES),                             \
    .SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE(1'b1),                            \
    .SVT_PCIE_UI_ENABLE_CFG_BLOCK(1'b1),                                   \
    .SVT_PCIE_UI_CONNECT_ACTIVE_VIP(1'b1),                                 \
    .SVT_PCIE_UI_NUM_PHYSICAL_LANES(8),                                    \
    .SVT_PCIE_UI_DEVICE_IS_ROOT(is_root),                                  \
    .SVT_PCIE_UI_HIERARCHY_NUMBER(hierarchy)                               \
  ) instance_name``_spd(                                                   \
    instance_name``_if);                                                   \
  pcie_svt_serial_port_if #(8) instance_name``_serial();                   \
  `PCIE_SVT_MAP_SERDES_X8(instance_name``_spd, instance_name``_serial)     \
  assign instance_name``_spd.vip_port_if.ser_if.reset = reset_signal;

`define PCIE_SVT_DECLARE_HDL_AGENT_X16(instance_name, display_name, clkreq_signal, wake_signal, reset_signal, is_root, hierarchy) \
  svt_pcie_if instance_name``_if(clkreq_signal, wake_signal);              \
  svt_pcie_single_port_device_agent_hdl #(                                \
    .SVT_PCIE_UI_PCIE_SPEC_VER(`SVT_PCIE_UI_PCIE_SPEC_VER_5_0),           \
    .SVT_PCIE_UI_DISPLAY_NAME(display_name),                               \
    .SVT_PCIE_UI_PHY_INTERFACE_TYPE(                                       \
      `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES),                             \
    .SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE(1'b1),                            \
    .SVT_PCIE_UI_ENABLE_CFG_BLOCK(1'b1),                                   \
    .SVT_PCIE_UI_CONNECT_ACTIVE_VIP(1'b1),                                 \
    .SVT_PCIE_UI_NUM_PHYSICAL_LANES(16),                                   \
    .SVT_PCIE_UI_DEVICE_IS_ROOT(is_root),                                  \
    .SVT_PCIE_UI_HIERARCHY_NUMBER(hierarchy)                               \
  ) instance_name``_spd(                                                   \
    instance_name``_if);                                                   \
  pcie_svt_serial_port_if #(16) instance_name``_serial();                  \
  `PCIE_SVT_MAP_SERDES_X16(instance_name``_spd, instance_name``_serial)    \
  assign instance_name``_spd.vip_port_if.ser_if.reset = reset_signal;

`endif  // PCIE_SVT_HDL_PHY_PIPE

`endif
