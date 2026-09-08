//------------------------------------------------------------------------------
// SVT pipe_if ↔ pcie_svt_pipe_port_if 映射宏（PIPE 版连线适配层）。
//
// 该文件属于 svt_pcie_integration/rtl，被 pcie_svt_hdl_agent_macros.svh
// 在 PIPE 模式下使用，与 Serial 版 pcie_svt_serial_adapter.sv 对称。
//
// 方向规则沿用官方 SVT_PCIE_ICM_PIPE_PIPE_LINK 的驱动关系：tx 组与
// mpipe 公共组由 MAC（mpipe）侧驱动，rx 组与 spipe 公共组由 PHY
// （spipe）侧驱动。SVT 实例的侧别由 is_root 推导（Root=spipe，
// Endpoint=mpipe），因此 MAP 宏用 generate if 按 is_root 选择两套
// assign 方向：SVT 驱动的组 → port，port（DUT 对端驱动）→ SVT。
//
// pclk 采用 CLK_FROM_MAC=0 组合：spipe 驱动公共 pclk，并馈入 spipe
// 侧的 per-lane pclk_N（官方宏同款接法）。信号集合与官方
// PIPE_PIPE_PER_LANE_CODE 逐行一致，含 MBI message bus 与 pie8 EQ
// 子接口。
//------------------------------------------------------------------------------
`ifndef PCIE_SVT_PIPE_ADAPTER_SV
`define PCIE_SVT_PIPE_ADAPTER_SV

// 单 lane 映射：spipe 侧 SVT（is_root=1）时 rx 组由 SVT 驱动 port、
// tx 组由 port 驱动 SVT；mpipe 侧（is_root=0）方向整体取反。
`define PCIE_SVT_MAP_PIPE_LANE(spd, port, lane, is_root) \
  generate if (is_root) begin : port``_s_l``lane \
    /* SVT=spipe：rx/状态组 SVT→port */ \
    assign port.rx_data[lane]        = spd.vip_port_if.pipe_if.rx_data_``lane``; \
    assign port.rx_data_k[lane]      = spd.vip_port_if.pipe_if.rx_data_k_``lane``; \
    assign port.rx_status[lane]      = spd.vip_port_if.pipe_if.rx_status_``lane``; \
    assign port.rx_valid[lane]       = spd.vip_port_if.pipe_if.rx_valid_``lane``; \
    assign port.rx_data_valid[lane]  = spd.vip_port_if.pipe_if.rx_data_valid_``lane``; \
    assign port.rx_elec_idle[lane]   = spd.vip_port_if.pipe_if.rx_elec_idle_``lane``; \
    assign port.rx_start_block[lane] = spd.vip_port_if.pipe_if.rx_start_block_``lane``; \
    assign port.rx_sync_header[lane] = spd.vip_port_if.pipe_if.rx_sync_header_``lane``; \
    assign port.phy_status[lane]     = spd.vip_port_if.pipe_if.phy_status_``lane``; \
    assign port.rx_standby_status[lane] = spd.vip_port_if.pipe_if.rx_standby_status_``lane``; \
    assign port.local_tx_preset_coefficients[lane] = spd.vip_port_if.pipe_if.local_tx_preset_coefficients_``lane``; \
    assign port.link_evaluation_feedback_figure_merit[lane] = spd.vip_port_if.pipe_if.link_evaluation_feedback_figure_merit_``lane``; \
    assign port.link_evaluation_feedback_direction_change[lane] = spd.vip_port_if.pipe_if.link_evaluation_feedback_direction_change_``lane``; \
    assign port.local_fs[lane]       = spd.vip_port_if.pipe_if.local_fs_``lane``; \
    assign port.local_lf[lane]       = spd.vip_port_if.pipe_if.local_lf_``lane``; \
    assign port.local_tx_coefficients_valid[lane] = spd.vip_port_if.pipe_if.local_tx_coefficients_valid_``lane``; \
    /* tx 组 port（对端 MAC）→SVT */ \
    assign spd.vip_port_if.pipe_if.tx_data_``lane``        = port.tx_data[lane]; \
    assign spd.vip_port_if.pipe_if.tx_data_k_``lane``      = port.tx_data_k[lane]; \
    assign spd.vip_port_if.pipe_if.tx_ei_code_``lane``     = port.tx_ei_code[lane]; \
    assign spd.vip_port_if.pipe_if.tx_compliance_``lane``  = port.tx_compliance[lane]; \
    assign spd.vip_port_if.pipe_if.tx_elec_idle_``lane``   = port.tx_elec_idle[lane]; \
    assign spd.vip_port_if.pipe_if.tx_data_valid_``lane``  = port.tx_data_valid[lane]; \
    assign spd.vip_port_if.pipe_if.tx_start_block_``lane`` = port.tx_start_block[lane]; \
    assign spd.vip_port_if.pipe_if.tx_sync_header_``lane`` = port.tx_sync_header[lane]; \
    assign spd.vip_port_if.pipe_if.rx_polarity_``lane``    = port.rx_polarity[lane]; \
    assign spd.vip_port_if.pipe_if.rx_eq_in_progress_``lane`` = port.rx_eq_in_progress[lane]; \
    assign spd.vip_port_if.pipe_if.lf_``lane``             = port.lf_lane[lane]; \
    assign spd.vip_port_if.pipe_if.fs_``lane``             = port.fs_lane[lane]; \
    assign spd.vip_port_if.pipe_if.tx_deemph_``lane``      = port.tx_deemph[lane]; \
    assign spd.vip_port_if.pipe_if.local_preset_index_``lane`` = port.local_preset_index[lane]; \
    assign spd.vip_port_if.pipe_if.rx_preset_hint_``lane`` = port.rx_preset_hint[lane]; \
    assign spd.vip_port_if.pipe_if.get_local_preset_coefficients_``lane`` = port.get_local_preset_coefficients[lane]; \
    assign spd.vip_port_if.pipe_if.rx_eq_eval_``lane``     = port.rx_eq_eval[lane]; \
    assign spd.vip_port_if.pipe_if.invalid_request_``lane`` = port.invalid_request[lane]; \
    assign spd.vip_port_if.pipe_if.rx_standby_``lane``     = port.rx_standby[lane]; \
    assign spd.vip_port_if.pipe_if.m2p_message_bus_``lane`` = port.m2p_message_bus[lane]; \
    assign spd.vip_port_if.pipe_if.sris_enable_``lane``    = port.sris_enable[lane]; \
    assign spd.vip_port_if.pipe_if.pclk_``lane``           = port.pclk; \
    assign spd.vip_port_if.pie8_eq_if.mac_data_``lane``    = port.pie8_mac_data[lane]; \
    assign spd.vip_port_if.pie8_eq_if.mac_data_en_``lane`` = port.pie8_mac_data_en[lane]; \
    assign port.p2m_message_bus[lane] = spd.vip_port_if.pipe_if.p2m_message_bus_``lane``; \
    assign port.pie8_phy_data[lane]   = spd.vip_port_if.pie8_eq_if.phy_data_``lane``; \
    assign port.pie8_phy_data_en[lane] = spd.vip_port_if.pie8_eq_if.phy_data_en_``lane``; \
  end else begin : port``_m_l``lane \
    /* SVT=mpipe：tx 组 SVT→port */ \
    assign port.tx_data[lane]        = spd.vip_port_if.pipe_if.tx_data_``lane``; \
    assign port.tx_data_k[lane]      = spd.vip_port_if.pipe_if.tx_data_k_``lane``; \
    assign port.tx_ei_code[lane]     = spd.vip_port_if.pipe_if.tx_ei_code_``lane``; \
    assign port.tx_compliance[lane]  = spd.vip_port_if.pipe_if.tx_compliance_``lane``; \
    assign port.tx_elec_idle[lane]   = spd.vip_port_if.pipe_if.tx_elec_idle_``lane``; \
    assign port.tx_data_valid[lane]  = spd.vip_port_if.pipe_if.tx_data_valid_``lane``; \
    assign port.tx_start_block[lane] = spd.vip_port_if.pipe_if.tx_start_block_``lane``; \
    assign port.tx_sync_header[lane] = spd.vip_port_if.pipe_if.tx_sync_header_``lane``; \
    assign port.rx_polarity[lane]    = spd.vip_port_if.pipe_if.rx_polarity_``lane``; \
    assign port.rx_eq_in_progress[lane] = spd.vip_port_if.pipe_if.rx_eq_in_progress_``lane``; \
    assign port.lf_lane[lane]        = spd.vip_port_if.pipe_if.lf_``lane``; \
    assign port.fs_lane[lane]        = spd.vip_port_if.pipe_if.fs_``lane``; \
    assign port.tx_deemph[lane]      = spd.vip_port_if.pipe_if.tx_deemph_``lane``; \
    assign port.local_preset_index[lane] = spd.vip_port_if.pipe_if.local_preset_index_``lane``; \
    assign port.rx_preset_hint[lane] = spd.vip_port_if.pipe_if.rx_preset_hint_``lane``; \
    assign port.get_local_preset_coefficients[lane] = spd.vip_port_if.pipe_if.get_local_preset_coefficients_``lane``; \
    assign port.rx_eq_eval[lane]     = spd.vip_port_if.pipe_if.rx_eq_eval_``lane``; \
    assign port.invalid_request[lane] = spd.vip_port_if.pipe_if.invalid_request_``lane``; \
    assign port.rx_standby[lane]     = spd.vip_port_if.pipe_if.rx_standby_``lane``; \
    assign port.m2p_message_bus[lane] = spd.vip_port_if.pipe_if.m2p_message_bus_``lane``; \
    assign port.sris_enable[lane]    = spd.vip_port_if.pipe_if.sris_enable_``lane``; \
    assign port.pie8_mac_data[lane]  = spd.vip_port_if.pie8_eq_if.mac_data_``lane``; \
    assign port.pie8_mac_data_en[lane] = spd.vip_port_if.pie8_eq_if.mac_data_en_``lane``; \
    assign spd.vip_port_if.pipe_if.p2m_message_bus_``lane`` = port.p2m_message_bus[lane]; \
    assign spd.vip_port_if.pie8_eq_if.phy_data_``lane``     = port.pie8_phy_data[lane]; \
    assign spd.vip_port_if.pie8_eq_if.phy_data_en_``lane``  = port.pie8_phy_data_en[lane]; \
    /* rx/状态组 port（对端 PHY）→SVT */ \
    assign spd.vip_port_if.pipe_if.rx_data_``lane``        = port.rx_data[lane]; \
    assign spd.vip_port_if.pipe_if.rx_data_k_``lane``      = port.rx_data_k[lane]; \
    assign spd.vip_port_if.pipe_if.rx_status_``lane``      = port.rx_status[lane]; \
    assign spd.vip_port_if.pipe_if.rx_valid_``lane``       = port.rx_valid[lane]; \
    assign spd.vip_port_if.pipe_if.rx_data_valid_``lane``  = port.rx_data_valid[lane]; \
    assign spd.vip_port_if.pipe_if.rx_elec_idle_``lane``   = port.rx_elec_idle[lane]; \
    assign spd.vip_port_if.pipe_if.rx_start_block_``lane`` = port.rx_start_block[lane]; \
    assign spd.vip_port_if.pipe_if.rx_sync_header_``lane`` = port.rx_sync_header[lane]; \
    assign spd.vip_port_if.pipe_if.phy_status_``lane``     = port.phy_status[lane]; \
    assign spd.vip_port_if.pipe_if.rx_standby_status_``lane`` = port.rx_standby_status[lane]; \
    assign spd.vip_port_if.pipe_if.local_tx_preset_coefficients_``lane`` = port.local_tx_preset_coefficients[lane]; \
    assign spd.vip_port_if.pipe_if.link_evaluation_feedback_figure_merit_``lane`` = port.link_evaluation_feedback_figure_merit[lane]; \
    assign spd.vip_port_if.pipe_if.link_evaluation_feedback_direction_change_``lane`` = port.link_evaluation_feedback_direction_change[lane]; \
    assign spd.vip_port_if.pipe_if.local_fs_``lane``       = port.local_fs[lane]; \
    assign spd.vip_port_if.pipe_if.local_lf_``lane``       = port.local_lf[lane]; \
    assign spd.vip_port_if.pipe_if.local_tx_coefficients_valid_``lane`` = port.local_tx_coefficients_valid[lane]; \
  end endgenerate

// 公共信号映射：mpipe 组/spipe 组按 is_root 定方向（与官方
// PIPE_PIPE_COMMON_CODE 驱动关系一致）。
`define PCIE_SVT_MAP_PIPE_COMMON(spd, port, is_root) \
  generate if (is_root) begin : port``_cs \
    /* SVT=spipe 驱动组 → port */ \
    assign port.pclk           = spd.vip_port_if.pipe_if.pclk; \
    assign port.max_pclk       = spd.vip_port_if.pipe_if.max_pclk; \
    assign port.pclk_change_ok = spd.vip_port_if.pipe_if.pclk_change_ok; \
    assign port.data_bus_width = spd.vip_port_if.pipe_if.data_bus_width; \
    /* mpipe 驱动组 port → SVT */ \
    assign spd.vip_port_if.pipe_if.power_down      = port.power_down; \
    assign spd.vip_port_if.pipe_if.rate            = port.rate; \
    assign spd.vip_port_if.pipe_if.pclk_rate       = port.pclk_rate; \
    assign spd.vip_port_if.pipe_if.tx_detect_rx    = port.tx_detect_rx; \
    assign spd.vip_port_if.pipe_if.block_align_control = port.block_align_control; \
    assign spd.vip_port_if.pipe_if.tx_margin       = port.tx_margin; \
    assign spd.vip_port_if.pipe_if.tx_swing        = port.tx_swing; \
    assign spd.vip_port_if.pipe_if.width           = port.width; \
    assign spd.vip_port_if.pipe_if.pipe_reset_n    = port.pipe_reset_n; \
    assign spd.vip_port_if.pipe_if.pclk_change_ack = port.pclk_change_ack; \
    assign spd.vip_port_if.pipe_if.async_power_change_ack = port.async_power_change_ack; \
    assign spd.vip_port_if.pipe_if.rx_eidetect_disable    = port.rx_eidetect_disable; \
    assign spd.vip_port_if.pipe_if.tx_commonmode_disable  = port.tx_commonmode_disable; \
    assign spd.vip_port_if.pipe_if.lf              = port.lf; \
    assign spd.vip_port_if.pipe_if.fs              = port.fs; \
  end else begin : port``_cm \
    /* SVT=mpipe 驱动组 → port */ \
    assign port.power_down      = spd.vip_port_if.pipe_if.power_down; \
    assign port.rate            = spd.vip_port_if.pipe_if.rate; \
    assign port.pclk_rate       = spd.vip_port_if.pipe_if.pclk_rate; \
    assign port.tx_detect_rx    = spd.vip_port_if.pipe_if.tx_detect_rx; \
    assign port.block_align_control = spd.vip_port_if.pipe_if.block_align_control; \
    assign port.tx_margin       = spd.vip_port_if.pipe_if.tx_margin; \
    assign port.tx_swing        = spd.vip_port_if.pipe_if.tx_swing; \
    assign port.width           = spd.vip_port_if.pipe_if.width; \
    assign port.pipe_reset_n    = spd.vip_port_if.pipe_if.pipe_reset_n; \
    assign port.pclk_change_ack = spd.vip_port_if.pipe_if.pclk_change_ack; \
    assign port.async_power_change_ack = spd.vip_port_if.pipe_if.async_power_change_ack; \
    assign port.rx_eidetect_disable    = spd.vip_port_if.pipe_if.rx_eidetect_disable; \
    assign port.tx_commonmode_disable  = spd.vip_port_if.pipe_if.tx_commonmode_disable; \
    assign port.lf              = spd.vip_port_if.pipe_if.lf; \
    assign port.fs              = spd.vip_port_if.pipe_if.fs; \
    /* spipe 驱动组 port → SVT */ \
    assign spd.vip_port_if.pipe_if.pclk           = port.pclk; \
    assign spd.vip_port_if.pipe_if.max_pclk       = port.max_pclk; \
    assign spd.vip_port_if.pipe_if.pclk_change_ok = port.pclk_change_ok; \
    assign spd.vip_port_if.pipe_if.data_bus_width = port.data_bus_width; \
  end endgenerate

`define PCIE_SVT_MAP_PIPE_X4(spd, port, is_root) \
  `PCIE_SVT_MAP_PIPE_COMMON(spd, port, is_root) \
  `PCIE_SVT_MAP_PIPE_LANE(spd, port, 0, is_root) \
  `PCIE_SVT_MAP_PIPE_LANE(spd, port, 1, is_root) \
  `PCIE_SVT_MAP_PIPE_LANE(spd, port, 2, is_root) \
  `PCIE_SVT_MAP_PIPE_LANE(spd, port, 3, is_root)

`define PCIE_SVT_MAP_PIPE_X8(spd, port, is_root) \
  `PCIE_SVT_MAP_PIPE_X4(spd, port, is_root) \
  `PCIE_SVT_MAP_PIPE_LANE(spd, port, 4, is_root) \
  `PCIE_SVT_MAP_PIPE_LANE(spd, port, 5, is_root) \
  `PCIE_SVT_MAP_PIPE_LANE(spd, port, 6, is_root) \
  `PCIE_SVT_MAP_PIPE_LANE(spd, port, 7, is_root)

`define PCIE_SVT_MAP_PIPE_X16(spd, port, is_root) \
  `PCIE_SVT_MAP_PIPE_X8(spd, port, is_root) \
  `PCIE_SVT_MAP_PIPE_LANE(spd, port, 8, is_root) \
  `PCIE_SVT_MAP_PIPE_LANE(spd, port, 9, is_root) \
  `PCIE_SVT_MAP_PIPE_LANE(spd, port, 10, is_root) \
  `PCIE_SVT_MAP_PIPE_LANE(spd, port, 11, is_root) \
  `PCIE_SVT_MAP_PIPE_LANE(spd, port, 12, is_root) \
  `PCIE_SVT_MAP_PIPE_LANE(spd, port, 13, is_root) \
  `PCIE_SVT_MAP_PIPE_LANE(spd, port, 14, is_root) \
  `PCIE_SVT_MAP_PIPE_LANE(spd, port, 15, is_root)

// 两个 port 对拼（门禁/双 VIP 用）：a 侧必须是 spipe（Root）实例的
// port，b 侧是 mpipe（Endpoint）实例的 port。spipe 驱动组 a→b，
// mpipe 驱动组 b→a——与官方 PIPE_PIPE_LINK 的交叉方向一致。
`define PCIE_SVT_PIPE_PORT_CROSS_LANE(a, b, lane) \
  assign b.rx_data[lane]        = a.rx_data[lane]; \
  assign b.rx_data_k[lane]      = a.rx_data_k[lane]; \
  assign b.rx_status[lane]      = a.rx_status[lane]; \
  assign b.rx_valid[lane]       = a.rx_valid[lane]; \
  assign b.rx_data_valid[lane]  = a.rx_data_valid[lane]; \
  assign b.rx_elec_idle[lane]   = a.rx_elec_idle[lane]; \
  assign b.rx_start_block[lane] = a.rx_start_block[lane]; \
  assign b.rx_sync_header[lane] = a.rx_sync_header[lane]; \
  assign b.phy_status[lane]     = a.phy_status[lane]; \
  assign b.rx_standby_status[lane] = a.rx_standby_status[lane]; \
  assign b.local_tx_preset_coefficients[lane] = a.local_tx_preset_coefficients[lane]; \
  assign b.link_evaluation_feedback_figure_merit[lane] = a.link_evaluation_feedback_figure_merit[lane]; \
  assign b.link_evaluation_feedback_direction_change[lane] = a.link_evaluation_feedback_direction_change[lane]; \
  assign b.local_fs[lane]       = a.local_fs[lane]; \
  assign b.local_lf[lane]       = a.local_lf[lane]; \
  assign b.local_tx_coefficients_valid[lane] = a.local_tx_coefficients_valid[lane]; \
  assign a.tx_data[lane]        = b.tx_data[lane]; \
  assign a.tx_data_k[lane]      = b.tx_data_k[lane]; \
  assign a.tx_ei_code[lane]     = b.tx_ei_code[lane]; \
  assign a.tx_compliance[lane]  = b.tx_compliance[lane]; \
  assign a.tx_elec_idle[lane]   = b.tx_elec_idle[lane]; \
  assign a.tx_data_valid[lane]  = b.tx_data_valid[lane]; \
  assign a.tx_start_block[lane] = b.tx_start_block[lane]; \
  assign a.tx_sync_header[lane] = b.tx_sync_header[lane]; \
  assign a.rx_polarity[lane]    = b.rx_polarity[lane]; \
  assign a.rx_eq_in_progress[lane] = b.rx_eq_in_progress[lane]; \
  assign a.lf_lane[lane]        = b.lf_lane[lane]; \
  assign a.fs_lane[lane]        = b.fs_lane[lane]; \
  assign a.tx_deemph[lane]      = b.tx_deemph[lane]; \
  assign a.local_preset_index[lane] = b.local_preset_index[lane]; \
  assign a.rx_preset_hint[lane] = b.rx_preset_hint[lane]; \
  assign a.get_local_preset_coefficients[lane] = b.get_local_preset_coefficients[lane]; \
  assign a.rx_eq_eval[lane]     = b.rx_eq_eval[lane]; \
  assign a.invalid_request[lane] = b.invalid_request[lane]; \
  assign a.rx_standby[lane]     = b.rx_standby[lane]; \
  assign a.m2p_message_bus[lane] = b.m2p_message_bus[lane]; \
  assign a.sris_enable[lane]    = b.sris_enable[lane]; \
  assign a.pie8_mac_data[lane]  = b.pie8_mac_data[lane]; \
  assign a.pie8_mac_data_en[lane] = b.pie8_mac_data_en[lane]; \
  assign b.p2m_message_bus[lane] = a.p2m_message_bus[lane]; \
  assign b.pie8_phy_data[lane]   = a.pie8_phy_data[lane]; \
  assign b.pie8_phy_data_en[lane] = a.pie8_phy_data_en[lane];

`define PCIE_SVT_PIPE_PORT_CROSS_COMMON(a, b) \
  assign b.pclk           = a.pclk; \
  assign b.max_pclk       = a.max_pclk; \
  assign b.pclk_change_ok = a.pclk_change_ok; \
  assign b.data_bus_width = a.data_bus_width; \
  assign a.power_down      = b.power_down; \
  assign a.rate            = b.rate; \
  assign a.pclk_rate       = b.pclk_rate; \
  assign a.tx_detect_rx    = b.tx_detect_rx; \
  assign a.block_align_control = b.block_align_control; \
  assign a.tx_margin       = b.tx_margin; \
  assign a.tx_swing        = b.tx_swing; \
  assign a.width           = b.width; \
  assign a.pipe_reset_n    = b.pipe_reset_n; \
  assign a.pclk_change_ack = b.pclk_change_ack; \
  assign a.async_power_change_ack = b.async_power_change_ack; \
  assign a.rx_eidetect_disable    = b.rx_eidetect_disable; \
  assign a.tx_commonmode_disable  = b.tx_commonmode_disable; \
  assign a.lf              = b.lf; \
  assign a.fs              = b.fs;

`define PCIE_SVT_PIPE_PORT_CROSS_X4(a, b) \
  `PCIE_SVT_PIPE_PORT_CROSS_COMMON(a, b) \
  `PCIE_SVT_PIPE_PORT_CROSS_LANE(a, b, 0) \
  `PCIE_SVT_PIPE_PORT_CROSS_LANE(a, b, 1) \
  `PCIE_SVT_PIPE_PORT_CROSS_LANE(a, b, 2) \
  `PCIE_SVT_PIPE_PORT_CROSS_LANE(a, b, 3)

`endif
