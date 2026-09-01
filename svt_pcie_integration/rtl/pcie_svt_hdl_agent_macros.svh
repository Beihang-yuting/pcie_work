`ifndef PCIE_SVT_HDL_AGENT_MACROS_SVH
`define PCIE_SVT_HDL_AGENT_MACROS_SVH

`include "pcie_svt_hdl_slot_cfg.svh"

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

`endif
