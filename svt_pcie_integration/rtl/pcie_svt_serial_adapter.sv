`ifndef PCIE_SVT_SERIAL_ADAPTER_SV
`define PCIE_SVT_SERIAL_ADAPTER_SV

`define PCIE_SVT_MAP_SERDES_LANE(spd, port, lane) \
  assign port.rx_p[lane] = spd.vip_port_if.ser_if.tx_datap_``lane``; \
  assign port.rx_n[lane] = spd.vip_port_if.ser_if.tx_datan_``lane``; \
  assign spd.vip_port_if.ser_if.rx_datap_``lane`` = port.tx_p[lane]; \
  assign spd.vip_port_if.ser_if.rx_datan_``lane`` = port.tx_n[lane]; \
  assign port.active_tx_transmit_clk[lane] = \
    spd.vip_port_if.ser_if.active_tx_transmit_clk_``lane``; \
  assign port.active_rx_recovered_clk[lane] = \
    spd.vip_port_if.ser_if.active_rx_recovered_clk_``lane``; \
  assign spd.vip_port_if.ser_if.tx_clk_``lane`` = port.tx_clk[lane]; \
  assign spd.vip_port_if.ser_if.rx_clk_``lane`` = port.rx_clk[lane];

`define PCIE_SVT_MAP_SERDES_X4(spd, port) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 0) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 1) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 2) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 3)

`define PCIE_SVT_MAP_SERDES_X8(spd, port) \
  `PCIE_SVT_MAP_SERDES_X4(spd, port) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 4) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 5) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 6) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 7)

`define PCIE_SVT_MAP_SERDES_X16(spd, port) \
  `PCIE_SVT_MAP_SERDES_X8(spd, port) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 8) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 9) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 10) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 11) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 12) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 13) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 14) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 15)

`endif
