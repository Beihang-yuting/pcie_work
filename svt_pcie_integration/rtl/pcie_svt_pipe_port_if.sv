//------------------------------------------------------------------------------
// 向量化 PIPE 端口 interface（DUT 连线标准入口）。
//
// 该文件属于 svt_pcie_integration/rtl，与 pcie_svt_serial_port_if 对称：
// PCIE_SVT_DECLARE_HDL_AGENT_Xn 在 PIPE 模式下为每个 SVT 实例生成一个
// 本 interface 的 <name>_pipe 实例，并经 PCIE_SVT_MAP_PIPE_Xn 与官方
// svt_pcie_pipe_if 的散名逐 lane 信号互映；DUT 只需对接这里的向量。
//
// 信号命名沿用官方 PIPE 全局语义（与 DUT 自身侧别无关）：
//   tx_*  = MAC→PHY 方向（mpipe 侧驱动）；
//   rx_*  = PHY→MAC 方向（spipe 侧驱动）。
// 收录集合 = 官方 SVT_PCIE_ICM_PIPE_PIPE_LINK 实际交叉连接的全部信号
// （per-lane + common），含 MBI message bus 与 pie8 EQ 子接口向量。
//
// 位宽引用官方 define（SVT_PCIE_PIPE_DATA_WIDTH 等），与所选 PIPE
// spec 版本自动保持一致；本文件必须在官方 include 之后编译。
//------------------------------------------------------------------------------
`ifndef PCIE_SVT_PIPE_PORT_IF_SV
`define PCIE_SVT_PIPE_PORT_IF_SV

interface pcie_svt_pipe_port_if #(int LANES = 1);

  //--- 公共信号：mpipe（MAC 侧）驱动 ---
  logic [3:0]  power_down;
  logic [`SVT_PCIE_PIPE_RATE_WIDTH-1:0]     rate;
  logic [`SVT_PCIE_PIPE_PCLKRATE_WIDTH-1:0] pclk_rate;
  logic        tx_detect_rx;
  logic        block_align_control;
  logic [2:0]  tx_margin;
  logic        tx_swing;
  logic [`SVT_PCIE_PIPE_WIDTH_WIDTH-1:0]    width;
  logic        pipe_reset_n;
  logic        pclk_change_ack;
  logic        async_power_change_ack;
  logic        rx_eidetect_disable;
  logic        tx_commonmode_disable;
  logic [5:0]  lf;   // 共享版（PIPE < 4.2 兼容字段）
  logic [5:0]  fs;   // 共享版（PIPE < 4.2 兼容字段）

  //--- 公共信号：spipe（PHY 侧）驱动 ---
  logic        pclk;          // CLK_FROM_MAC=0 组合下由 spipe 驱动
  logic        max_pclk;
  logic        pclk_change_ok;
  logic [`SVT_PCIE_PIPE_WIDTH_WIDTH-1:0]    data_bus_width;

  //--- 逐 lane：mpipe 驱动（tx 组 + rx_polarity）---
  logic [`SVT_PCIE_PIPE_DATA_WIDTH-1:0]    tx_data        [LANES];
  logic [`SVT_PCIE_PIPE_DATAK_WIDTH-1:0]   tx_data_k      [LANES];
  logic [31:0]                             tx_ei_code     [LANES];
  logic                                    tx_compliance  [LANES];
  logic [`SVT_PCIE_PIPE_TXELECIDLE_WIDTH-1:0] tx_elec_idle [LANES];
  logic                                    tx_data_valid  [LANES];
  logic                                    tx_start_block [LANES];
  logic [`SVT_PCIE_PIPE_SYNCHDR_WIDTH-1:0] tx_sync_header [LANES];
  logic                                    rx_polarity    [LANES];
  logic                                    rx_eq_in_progress [LANES];
  logic [5:0]                              lf_lane        [LANES];
  logic [5:0]                              fs_lane        [LANES];
  logic [17:0]                             tx_deemph      [LANES];
  logic [`SVT_PCIE_PIPE_LOCALPRESETINDEX_WIDTH-1:0] local_preset_index [LANES];
  logic [2:0]                              rx_preset_hint [LANES];
  logic                                    get_local_preset_coefficients [LANES];
  logic                                    rx_eq_eval     [LANES];
  logic                                    invalid_request [LANES];
  logic                                    rx_standby     [LANES];
  logic [`SVT_PCIE_PIPE_MBI_WIDTH-1:0]     m2p_message_bus [LANES];
  logic                                    sris_enable    [LANES];
  logic [5:0]                              pie8_mac_data  [LANES];
  logic                                    pie8_mac_data_en [LANES];

  //--- 逐 lane：spipe 驱动（rx 组 + 状态/EQ 反馈）---
  logic [`SVT_PCIE_PIPE_DATA_WIDTH-1:0]    rx_data        [LANES];
  logic [`SVT_PCIE_PIPE_DATAK_WIDTH-1:0]   rx_data_k      [LANES];
  logic [2:0]                              rx_status      [LANES];
  logic                                    rx_valid       [LANES];
  logic                                    rx_data_valid  [LANES];
  logic                                    rx_elec_idle   [LANES];
  logic                                    rx_start_block [LANES];
  logic [`SVT_PCIE_PIPE_SYNCHDR_WIDTH-1:0] rx_sync_header [LANES];
  logic                                    phy_status     [LANES];
  logic                                    rx_standby_status [LANES];
  logic [17:0]                             local_tx_preset_coefficients [LANES];
  logic [7:0]  link_evaluation_feedback_figure_merit      [LANES];
  logic [5:0]  link_evaluation_feedback_direction_change  [LANES];
  logic [5:0]                              local_fs       [LANES];
  logic [5:0]                              local_lf       [LANES];
  logic                                    local_tx_coefficients_valid [LANES];
  logic [`SVT_PCIE_PIPE_MBI_WIDTH-1:0]     p2m_message_bus [LANES];
  logic [5:0]                              pie8_phy_data  [LANES];
  logic                                    pie8_phy_data_en [LANES];

endinterface

`endif
