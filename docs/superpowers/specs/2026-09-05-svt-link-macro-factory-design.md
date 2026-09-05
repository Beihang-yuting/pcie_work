# SVT Link Macro Factory Design

## Goal

为 PCIe SVT 集成提供一个统一的、可参数化的 HDL 宏函数入口，使调用方通过
`mode`、`width` 和 `transport` 选择双 SVT、真实 DUT、x4/x8/x16 以及
SERDES/PIPE 连接方式，同时保持现有双 SVT 数据面回归兼容。

## Context

当前双 SVT 门禁在
`svt_pcie_integration/sim/pcie_tl_svt_formal_topology.sv` 中直接调用
Synopsys `SVT_PCIE_ICM_*` 宏。仓库另外已有
`pcie_svt_hdl_agent_macros.svh` 和
`pcie_svt_serial_adapter.sv`，但二者还没有统一的链路级调用入口。

本设计不改变 `pcie_tl_env` 的控制面。Config/BAR/BDF、枚举、Memory/Config
TLP 和 Completion 仍由 `pcie_tl_env` 负责；本设计只规范 SVT HDL agent、物理
接口和连接拓扑的静态 elaboration。

## Public API

新增上层宏文件 `pcie_svt_link_macros.svh`，对外提供固定形式的链路宏函数：

```systemverilog
`PCIE_SVT_BUILD_LINK(SVT, X8, SERDES, link_0, ...)
`PCIE_SVT_BUILD_LINK(DUT, X8, SERDES, link_0, ...)
`PCIE_SVT_BUILD_LINK(DUT, X8, PIPE,   link_0, ...)
```

宏使用 token dispatch 将三个静态维度展开到具体实现：

```text
PCIE_SVT_BUILD_LINK(mode, width, transport, ...)
        -> PCIE_SVT_BUILD_LINK_<mode>_<width>_<transport>(...)
```

实现使用固定参数列表，避免依赖 VCS 版本相关的可变参数宏扩展。`SVT`、
`DUT`、`X4`、`X8`、`X16`、`SERDES` 和 `PIPE` 是预定义 token，拼写错误必须在
预处理/编译阶段给出明确错误。

## Mode semantics

### SVT mode

`SVT` 模式创建两个官方 SVT HDL port/agent，并调用官方
`SVT_PCIE_ICM_CREATE_PORT_INST`、`SVT_PCIE_ICM_CREATE_LINK`、
`SVT_PCIE_ICM_SER_SER_LINK` 和
`SVT_PCIE_ICM_DO_CONDITIONAL_INTERCONNECT` 宏完成 peer link。

该模式保持当前 `link_<id>_vif_0` 和 `link_<id>_vif_1` 的 UVM 句柄契约，现有
双 SVT formal test 的 UVM 配置和 TL sequence 不需要迁移。

### DUT mode

`DUT` 模式只创建 SVT transport 侧的官方 HDL agent 和一个规范化的物理
interface，不创建第二个 SVT peer agent，也不创建 SVT-to-SVT ICM link。

DUT 的真实模块端口不写入 SVT agent 创建逻辑。调用方通过规范化 interface
或端口绑定宏将 DUT 的 TX/RX、时钟和复位接入。SVT 侧的 `is_root` 参数决定
SVT 为 RC 还是 EP：

```text
SVT RC + DUT EP: is_root = 1
DUT RC + SVT EP: is_root = 0
```

真实 DUT 侧不存在的 TL agent 必须在 test 的 `pcie_tl_env_config` 中关闭；
该行为不由 HDL 宏隐式修改。

## Width semantics

第一阶段实现并验证：

```text
X4  -> 4 lanes
X8  -> 8 lanes
X16 -> 16 lanes
```

每种宽度调用现有的
`PCIE_SVT_DECLARE_HDL_AGENT_X4/X8/X16` 和
`PCIE_SVT_MAP_SERDES_X4/X8/X16` 底层宏。链路实例名必须可拼接出唯一的
SVT/Serial interface 名称，重复实例名属于编译错误或 elaboration 错误。

## Transport semantics

新增 `pcie_svt_transport_macros.svh`，提供统一分发入口：

```systemverilog
`PCIE_SVT_CONNECT_PHY(SERDES, X4,  svt_if, dut_if)
`PCIE_SVT_CONNECT_PHY(SERDES, X8,  svt_if, dut_if)
`PCIE_SVT_CONNECT_PHY(SERDES, X16, svt_if, dut_if)
```

SERDES connector 使用固定的 `pcie_svt_serial_port_if` 信号命名和方向：

```text
tx_p/tx_n                    发送到对端 RX
rx_p/rx_n                    从对端 TX 接收
tx_clk/rx_clk                物理时钟边界
active_tx_transmit_clk       SVT 发送时钟状态
active_rx_recovered_clk      SVT 接收恢复时钟状态
```

PIPE 预留同一层分发入口：

```systemverilog
`PCIE_SVT_CONNECT_PHY(PIPE, X4,  svt_pipe_if, dut_pipe_if)
`PCIE_SVT_CONNECT_PHY(PIPE, X8,  svt_pipe_if, dut_pipe_if)
`PCIE_SVT_CONNECT_PHY(PIPE, X16, svt_pipe_if, dut_pipe_if)
```

当前阶段不声明未经 R-2020.12 实际接口确认的 PIPE 信号，也不允许 PIPE 模式
静默回退到 SERDES。PIPE 分支应保留明确的 compile-time guard，提示需要加入
正式 PIPE adapter；未来只增加 PIPE interface/connector 文件，不修改上层
`PCIE_SVT_BUILD_LINK` 调用形式。

## Data-plane topology tests

### Existing dual-SVT test

将 `pcie_tl_svt_formal_topology.sv` 改为使用统一链路宏，保持：

```text
1 x16 SVT RC <-> SVT EP
官方 Serial ICM interconnect
TL -> SVT -> Serial -> SVT -> TL
```

必须继续通过现有的 link L0、RC->EP read/write readback、EP->RC read/write
和 Completion 检查。

### Four-SVT reservation

后续 4-SVT 数据面使用相同宏族，通过多个唯一 link/port 调用构造两条或多条
独立链路。每条链路拥有独立的 SVT instance/interface 名称和 UVM VIF 映射；
不得复制一套新的 topology 宏 API。4-SVT 的具体官方 ICM 实例编号和命名在
读取 R-2020.12 宏展开规则后确定，不能假定当前 `spd_0/spd_1` 命名可直接复用。

## File boundaries

```text
svt_pcie_integration/rtl/pcie_svt_link_macros.svh
    链路级 mode/width/transport 分发和 SVT/DUT 创建行为

svt_pcie_integration/rtl/pcie_svt_transport_macros.svh
    SERDES/PIPE connector 分发和固定物理信号映射

svt_pcie_integration/rtl/pcie_svt_hdl_agent_macros.svh
    现有 x4/x8/x16 SVT HDL agent 底层声明，保持兼容

svt_pcie_integration/rtl/pcie_svt_serial_adapter.sv
    现有 SerDes lane 映射底层宏，保持兼容
```

双 SVT formal/peer filelist 继续使用官方 SVT 安装源码。生产
`pcie_tl_svt_adapter.f` 仍然是 source-only 入口，不自动引入 test/top；真实
DUT 工程追加自己的 top 和连接宏调用。

## Compatibility and non-goals

- 不修改 `pcie_tl_env`、TL sequence 或现有 TL-only filelist。
- 不把 DUT 层次路径写入 SVT package 或 adapter package。
- 不通过宏自动创建第二套 UVM PCIe 控制环境。
- 不在本阶段实现 PIPE 的真实 SVT 物理传输。
- 不假设 4-SVT 的官方 ICM 实例命名，先以双 SVT 宏化回归为基线。

## Verification criteria

1. `check_tl_svt_bridge_contract.sh` 通过。
2. 双 SVT formal filelist 使用新宏编译/elaboration 通过。
3. 双 SVT 数据面继续输出 L0、`PCIE_TL_SVT_TLP_PASS`、三类 readback pass，
   且 `UVM_ERROR/UVM_FATAL` 为 0。
4. TL-only filelist 不依赖新宏或 Synopsys SVT package。
5. DUT/SERDES 宏入口可在 source-only DUT top 中展开，并暴露固定 interface
   信号；没有真实 DUT 时不添加伪造的端到端通过声明。
6. `PIPE` token 能进入统一分发，但当前会以明确的 compile-time guard 失败，
   防止误认为 PIPE 已经实现。
