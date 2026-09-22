# PCIe SVT 4RC LTSSM/SerDes HDL 调试工作指南

本文面向 4×x8 SVT RC + 4 个真实 DUT EP 的集成场景，说明如何只依靠
VCS/Verdi 的 HDL 层级观察 PCIe 建链，不依赖 pcie_svt_backend 的 UVM
class 状态对象。

本文中的层级以项目当前使用的 SVT R-2020.12 SerDes model 为准。假设用户
顶层为 tb、DUT 实例为 tb.dut。如果用户顶层名称不同，只需替换路径最前面的
tb。

> **版本和路径边界**
>
> `pl0.ltssm_state`、`pl0.pl_status` 以及 `vip_port_if.ser_if.*` 是本项目
> 集成和测试中使用的稳定观察入口；`m_ser`、`SER_GEN_N.serdes`、
> `PCS_GEN_N.pcs` 及其内部计数器属于 R-2020.12 当前编译展开后的模型层级，
> 不是 SVT 对外承诺的公共 API。SVT 的实现包可能以加密形式分发，模型版本、
> 物理层参数或 VCS elaboration 选项改变后，私有信号可能被重命名、折叠或
> 不出现在波形中。下文列出的私有路径都应在 **VCS Design Browser/Verdi
> 的当前 simv** 中先确认；找不到时沿着实际展开的 `port0`、`pl0` 或
> `vip_port_if.ser_if` 层级替换，不能为了匹配文档而增加 force 或修改模型。
>
> LTSSM 数值也是 R-2020.12 本次展开中观察到的编码。调试代码优先使用
> `svt_pcie_types::L0` 等枚举，而不是把数值硬编码到测试里；不同 SVT 版本
> 或不同 PHY model 不应直接复用这些数值。

## 1. 4RC 拓扑和信号方向

4 条链路的静态实例为：

~~~
SVT RC0 x8 ── DUT EP0   link_id=RC0_EP0   hdl_slot=0
SVT RC1 x8 ── DUT EP1   link_id=RC1_EP1   hdl_slot=1
SVT RC2 x8 ── DUT EP2   link_id=RC2_EP2   hdl_slot=2
SVT RC3 x8 ── DUT EP3   link_id=RC3_EP3   hdl_slot=3
~~~

当前 pad 映射为：

~~~
RC0 -> pad0 lane  0~ 7
RC1 -> pad0 lane  8~15
RC2 -> pad1 lane  0~ 7
RC3 -> pad1 lane  8~15
~~~

以 RC0 lane 0 为例，方向必须是：

~~~
tb.svt_rc0_spd.vip_port_if.ser_if.tx_datap_0
    -> tb.dut.pad0_phy_rx0_p

tb.svt_rc0_spd.vip_port_if.ser_if.tx_datan_0
    -> tb.dut.pad0_phy_rx0_m

tb.dut.pad0_phy_tx0_p
    -> tb.svt_rc0_spd.vip_port_if.ser_if.rx_datap_0

tb.dut.pad0_phy_tx0_m
    -> tb.svt_rc0_spd.vip_port_if.ser_if.rx_datan_0
~~~

因此：

~~~
SVT tx_datap/tx_datan = SVT TX -> DUT RX
DUT TX                 = DUT TX -> SVT rx_datap/rx_datan
~~~

### 1.1 从端口到协议状态的对应关系

建链时不要只盯着一个 `ltssm_state` 数值。每个状态都必须能在物理接口、
接收锁定和训练序列上找到对应证据。下面的方向以 `svt_rc0` 为例，其他
实例只替换实例名和 lane 范围：

| 观察入口 | 方向/属性 | 在建链中的含义 | 出现异常时先查什么 |
|---|---|---|---|
| `svt_rc0_spd.vip_port_if.ser_if.tx_datap_N/tx_datan_N` | SVT 输出 | SVT 发往 DUT 的串行数据；应接 DUT `pad*_phy_rxN_p/m` | SVT reset、`link_en`、内部 bit clock、宏展开 |
| `svt_rc0_spd.vip_port_if.ser_if.rx_datap_N/rx_datan_N` | SVT 输入 | DUT 发回 SVT 的串行数据；来源是 DUT `pad*_phy_txN_p/m` | DUT PHY ready、DUT TX、P/N 极性和 lane 位序 |
| `svt_rc0_serial.rx_p/rx_n` | 适配器输入侧 | 宏把 SVT `tx_datap/datan` 转成 DUT RX 方向 | `PCIE_SVT_MAP_SERDES_*` 和连接宏 |
| `svt_rc0_serial.tx_p/tx_n` | 适配器输出侧 | 宏把 DUT TX 送回 SVT `rx_datap/datan` | DUT TX pad 到 `tx_*` 的连续赋值 |
| `active_tx_transmit_clk_N` | SVT 输出观察时钟 | active PHY 的发送 bit-clock 观察点 | 只观察，不接 DUT reference clock |
| `active_rx_recovered_clk_N` | SVT 输出观察时钟 | active PHY 的接收恢复时钟观察点 | 只观察，不把它当 DUT refclk |
| `tx_clk_N/rx_clk_N` | 外部采样/时钟输入 | 外部 bit-clock 或 Passive Monitor 契约中的采样时钟 | mode=1 或 Passive Monitor 的时钟来源 |
| `ser_if.reset` | SVT Serial 控制 | 高有效复位；`1` 保持 reset，`0` 才允许 PHY 工作 | 顶层复位极性和重复驱动 |
| `link_en.enable` | sequence 参数，不是 pin | 允许该链开始 LTSSM；不产生 refclk，也不释放 DUT reset | sequence 是否真正绑定到该 link 的 sequencer |

因此，一条可靠的证据链应是：

```text
SVT tx_* 有活动
  → DUT rx pad 有同样的 P/N 活动
  → DUT tx pad 开始返回训练序列
  → SVT rx_* 有活动且 serdes_locked=1
  → TS1/TS2 连续计数满足
  → LTSSM 从 Polling 推进到 Configuration/Recovery
  → L0 + link_up + 期望的 negotiated width
```

数据在哪一级消失，就先修复哪一级。仅看到 SVT `tx_*` 有波形，不能证明
DUT 已经收到有效 TS1；仅看到 `link_en` sequence 返回，也不能证明链路已经
进入 L0。

### 1.2 x4/x8/x16 的观察范围替换

本文用 4 条 x8 作为例子；换成其他拓扑时，观察方法不变，只替换 lane 范围
和独立实例：

| 链路宽度 | 每个 `ser_if`/SerDes lane 范围 | 每组 lane 计数器范围 | 连接约束 |
|---:|---|---|---|
| x4 | `0~3` | `[0:3]` | 一个独立 HDL slot 占 4 个连续 DUT lane |
| x8 | `0~7` | `[0:7]` | 一个独立 HDL slot 占 8 个连续 DUT lane |
| x16 | `0~15` | `[0:15]` | 一个独立 HDL slot 占 16 个连续 DUT lane |

例如 2×x16 要有两个独立 `svt_rcX_spd`，1×x16+4×x4 要有五个独立 slot；
不能用一个 x32 的 status 或 sequence 句柄代替多个物理链路。具体 pad
offset 和 `PCIE_SVT_CONNECT_DUT_SERDES_X4/X8/X16` 连接见
[4RC 集成文档 §2.1](pcie_svt_4rc_dut_ep_integration.md#21-两组-16-lane-scalar-pad-的连接)。

pcie_svt_serial_port_if 中的名称是 adapter 端口视角：

~~~
tb.svt_rc0_serial.rx_p[0] = SVT TX -> DUT RX
tb.svt_rc0_serial.tx_p[0] = DUT TX -> SVT RX
~~~

不要因为字段名中有 tx 或 rx 就把方向接反。

## 2. HDL 层级：哪些路径可以直接看

svt_be.svt_status_by_link[...] 是 UVM class 对象，默认不会出现在 FSDB 的
HDL hierarchy 中。当前 SVT HDL agent 可以按下面的层级展开：

~~~
tb.svt_rc0_spd
└── m_ser
    └── port0
        ├── pl0
        ├── SER_GEN_0.serdes ... SER_GEN_7.serdes
        └── PCS_GEN_0.pcs  ... PCS_GEN_7.pcs
~~~

四条链对应的内部 model 根路径为：

~~~
R0 = tb.svt_rc0_spd.m_ser.port0
R1 = tb.svt_rc1_spd.m_ser.port0
R2 = tb.svt_rc2_spd.m_ser.port0
R3 = tb.svt_rc3_spd.m_ser.port0
~~~

如果 Design Browser 中没有 m_ser，应以实际展开的 generate scope 为准；
不要自行猜测层级。当前 R-2020.12 常见的 SerDes lane 实例名是
SER_GEN_N.serdes。

### 2.1 最重要的 LTSSM HDL 信号

下面先列出当前 R-2020.12 build 中常见的名称。`ltssm_state`、
`last_ltssm_state`、`next_ltssm_state` 和 `pl_status` 是首选观察对象；其余
内部字段属于候选路径，若当前 Design Browser 没有，直接跳过并使用第 2.4
节的实际层级发现方法。

以 RC0 为例：

~~~
R0.pl0.ltssm_state
R0.pl0.last_ltssm_state
R0.pl0.next_ltssm_state
R0.pl0.ltssm_state_transition_reason
R0.pl0.pl_status
R0.pl0.pl_info
R0.pl0.link_width
R0.pl0.local_rate
~~~

R1/R2/R3 将 R0 替换即可。

当前 R-2020.12 展开中，`pl_status` 还可作为一个 64-bit packed debug 状态
观察，常用位的当前含义如下。公开手册稳定保证的是 `link_up` 和 Recovery
指示；其余位是本次 SerDes model 展开中观察到的镜像，使用前必须在当前
Design Browser 中确认，不能把位号写进跨版本测试逻辑：

| 位 | 当前观察到的含义 | 调试用途 |
|---:|---|---|
| `[0]` | `link_up` | 链路已宣布 up；仍需同时检查 LTSSM=L0 |
| `[1]` | link in Recovery | 判断是否正在重新锁定/切速率/均衡 |
| `[2]` | link in Configuration | 判断是否仍在链宽度/lane 编号配置 |
| `[11]` | Recovery transition pending | 识别即将从 L0 进入 Recovery 的窗口 |
| `[15:20]` | configured link width | 训练得到/配置的目标宽度镜像 |
| `[21:26]` | current link width | 与目标宽度对比，发现降宽 |
| `[28]` | link in Detect | 区分 Detect 回退与 Polling/Recovery 停滞 |

如果当前 build 没有这些位，使用 `pl0.link_width`、公开 status 的
`negotiated_link_width`/`GetNegotiatedLinkWidth` 等稳定入口；不要因为
`pl_status[15:20]` 不存在而修改模型或 force 内部信号。

部分 R-2020.12 Verilog/SerDes example 还提供 ASCII 观察信号，可用于快速
确认状态和 lane 数据（实际父层级仍以当前 Design Browser 为准）：

~~~
R0.pl0.ascii_ltssm_tx_state
R0.pl0.ascii_ltssm_rx_state
R0.pl0.ascii_lanen_tx_data[0:7]
R0.pl0.ascii_lanen_rx_data[0:7]
R0.pl0.ascii_lane_reversal_mode
~~~

ASCII 信号是观察/显示辅助，不要把它们作为训练控制输入；若它们与数值
`ltssm_state` 不一致，优先相信当前 active PHY 的数值状态并检查 monitor
是否已进入 `SEARCHING`。

### 2.2 SerDes、接收锁定和电气空闲

~~~
R0.pl0_serdes_locked[0:7]
R0.sig_level_valid[0:7]
R0.rx_elec_idle[0:7]
R0.comma_detect[0:7]
R0.pl0_phy_ready
R0.tx_elec_idle_0 ... R0.tx_elec_idle_7
R0.tx_bit_clk[0:7]
~~~

单 lane 更深层的路径为：

~~~
R0.SER_GEN_0.serdes.recovered_bit_clk
R0.SER_GEN_0.serdes.pll_locked
R0.SER_GEN_0.serdes.serdes_locked
R0.SER_GEN_0.serdes.comma_det
R0.SER_GEN_0.serdes.last_bit_period
R0.SER_GEN_0.serdes.average_bit_period
R0.SER_GEN_0.serdes.rx_data_transition_time
~~~

这些路径适合定位 SERDES unlocked、recovered clock 周期变化、某个 lane
单独失锁等问题。

### 2.3 TS1/TS2 和训练计数器

SVT PHY 内部保留了每 lane 的训练计数器。以 RC0 lane 0~7 为例：

~~~
R0.pl0.num_rx_consecutive_ts1_sets[0:7]
R0.pl0.num_rx_consecutive_ts2_sets[0:7]
R0.pl0.last_consec_ts1[0:7]
R0.pl0.last_consec_ts2[0:7]
R0.pl0.num_rx_consecutive_eios[0:7]
R0.pl0.num_rx_consecutive_eieos[0:7]
R0.pl0.num_rx_consecutive_fts[0:7]
R0.pl0.num_rx_consecutive_logical_idle[0:7]
~~~

这些是“连续数量”，不是永久递增的总计数。进入其他 ordered set 或收到
错误数据后可能清零，因此应观察它们在对应 LTSSM 阶段是否持续有效。

### 2.4 在当前仿真中确认私有层级

如果用户在波形中只能看到 `svt_rc0_spd`，看不到文档中的 `m_ser`，这不
表示 SVT 没有 LTSSM。按下面顺序在当前编译产物中定位：

1. 在 Verdi Design Browser 以 `svt_rc0_spd` 展开 `port0`，搜索
   `ltssm_state`；先记录实际包含该信号的父层级。
2. 沿 `ltssm_state` 的同级或上一级查找 `pl_status` 和 `link_width`；配置宽度
   优先读 `pl_status[15:20]` 或调用公开的 `GetConfiguredLinkWidth`。有的
   elaboration 会把 `pl0` 展平，路径可能是
   `...port0.pl0`，也可能是 `...port0.<generate_scope>.pl0`。
3. 只有需要定位串行锁定或单 lane 问题时，再从 `port0` 搜索
   `serdes_locked`、`pll_locked`、`recovered_bit_clk`；找到后用实际的
   `SER_GEN_<N>`/generate 名替换本文的占位符 `SER_GEN_N`。
4. 在当前 build 没有这些私有信号时，退回稳定入口：
   `svt_rc0_spd.vip_port_if.ser_if.tx_*`、`rx_*`、active clock，以及
   UVM status 的 `pcie_status.pl_status.link_up/ltssm_state`。不要从
   `svt_be.svt_status_by_link[...]` 反推一个不存在的 HDL 路径。

下面的信号按“推荐级别”理解：

| 级别 | 信号/路径 | 适用场景 | 可靠性说明 |
|---|---|---|---|
| A | `vip_port_if.ser_if.tx_*`、`rx_*`、`reset`、active clocks | 首先确认连接、复位和数据活动 | 由当前集成 adapter 直接使用 |
| A | `pl0.ltssm_state`、`pl0.pl_status` | 判断训练阶段和 L0 | 当前 R-2020.12 集成的主要 HDL 观察点 |
| B | `pl0_serdes_locked`、TS1/TS2 counters、`SER_GEN_N.serdes.*` | 定位单 lane/恢复时钟/锁定问题 | 当前 model 常见私有信号，需 Design Browser 确认 |
| C | `PCS_GEN_N.pcs.num_decode_errs_since_last_comma`、`phy_lane_map`、EQ request/complete、PCS decode | 深入定位解码、deskew、均衡问题 | 不作为跨版本保证；没有就跳过 |

也就是说，文档中的 B/C 路径是“当前 R-2020.12 build 的候选 debug path”，
不是必须新增的 RTL 端口。FSDB 中没有 B/C 信号时，先用 A 级信号完成阶段
定位，再决定是否需要重新编译更完整的 debug access/dump。

### 2.5 PCS 解码路径

需要进一步判断 8b/10b 解码或 comma 对齐时，可以展开：

~~~
R0.PCS_GEN_0.pcs
R0.PCS_GEN_1.pcs
...
R0.PCS_GEN_7.pcs
~~~

常用信号包括：

~~~
R0.PCS_GEN_0.pcs.rx_byte10
R0.PCS_GEN_0.pcs.rx_byte32
R0.PCS_GEN_0.pcs.cg_block_aligned
R0.PCS_GEN_0.pcs.eios_detected
R0.PCS_GEN_0.pcs.eieos_detected
~~~

第一轮调试不需要加入全部 PCS 内部信号。通常先看 ltssm_state、
pl_status、pl0_serdes_locked 和 TS1/TS2 计数器，只有卡在 Polling 或
出现解码错误时再进入 PCS 层。

## 3. LTSSM 状态编码和总体执行顺序

当前 R-2020.12 SerDes model 中常用状态编码如下：

| 数值 | 英文状态 | 中文状态 | 主要作用 |
|---:|---|---|---|
| 99 | INITIAL | 初始内部状态 | SVT PHY 尚未开始 LTSSM |
| 0 | DETECT_QUIET | 检测静默 | 接收端保持电气空闲，等待检测条件 |
| 1 | DETECT_ACTIVE | 检测活动 | 发起接收器/终端检测 |
| 2 | POLLING_ACTIVE | 轮询活动 | 发送并接收 TS1 |
| 3 | POLLING_COMPLIANCE | 轮询一致性 | Compliance 测试模式，普通建链通常不经过 |
| 4 | POLLING_CONFIGURATION | 轮询配置 | 发送/接收 TS1、TS2，交换训练参数 |
| 5 | POLLING_SPEED | 轮询速率 | 某些速率切换流程中的轮询阶段 |
| 6 | CONFIGURATION_LINKWIDTH_START | 配置链宽度开始 | 检查并确定可用 lane 数量 |
| 7 | CONFIGURATION_LINKWIDTH_ACCEPT | 配置链宽度接受 | 双方接受最终宽度 |
| 8 | CONFIGURATION_LANENUM_WAIT | 配置 lane 编号等待 | 等待 lane 编号稳定 |
| 9 | CONFIGURATION_LANENUM_ACCEPT | 配置 lane 编号接受 | 接受 lane 编号和 lane 映射 |
| 10 | CONFIGURATION_COMPLETE | 配置完成 | 完成 lane/link 配置 |
| 11 | CONFIGURATION_IDLE | 配置空闲 | 等待进入 L0 或 Recovery |
| 12 | RECOVERY_RCVRLOCK | 恢复接收锁定 | 重新锁定接收端数据和时钟 |
| 13 | RECOVERY_SPEED | 恢复速率切换 | 切换 Gen 速率 |
| 14 | RECOVERY_RCVRCFG | 恢复接收配置 | 交换恢复训练序列 |
| 15 | RECOVERY_IDLE | 恢复空闲 | 确认恢复完成 |
| 16 | L0 | 正常工作 | 链路可传输 DLLP/TLP |
| 17 | L0S | L0s 低功耗 | 低功耗入口/退出的总状态 |
| 18 | L0S_ENTRY | L0s 进入 | 发送 FTS 并准备进入 L0s |
| 19 | L0S_IDLE | L0s 空闲 | 在 L0s 电气空闲中等待唤醒 |
| 20 | L0S_FTS | L0s FTS | 退出 L0s 后恢复 bit/symbol 对齐 |
| 21 | L1_ENTRY | L1 进入 | 协商进入更深的链路低功耗 |
| 22 | L1_IDLE | L1 空闲 | L1 中停止正常数据传输 |
| 23 | L1_1 | L1.1 低功耗 | 可选的 L1.1 电源管理状态 |
| 24 | L1_2_ENTRY | L1.2 进入 | 进入更深的 L1.2 低功耗 |
| 25 | L1_2_IDLE | L1.2 空闲 | L1.2 稳定空闲 |
| 26 | L1_2_EXIT | L1.2 退出 | 恢复参考时钟/链路活动 |
| 27 | L2_IDLE | L2 空闲 | 关闭或保持链路的更深低功耗 |
| 28 | L2_TRANSMIT_WAKE | L2 唤醒发送 | 发送唤醒序列，准备回到工作态 |
| 29 | DISABLED | 禁用 | 由配置/错误条件禁用链路 |
| 30 | HOT_RESET | 热复位 | 通过链路训练序列执行 Hot Reset |
| 31 | LOOPBACK_ENTRY | 回环进入 | 准备内部/外部回环测试 |
| 32 | LOOPBACK_ACTIVE | 回环活动 | 在回环路径上传输测试数据 |
| 33 | LOOPBACK_EXIT | 回环退出 | 退出测试并重新训练 |
| 34 | RECOVERY_EQUALIZATION_0 | 均衡阶段 0 | Gen3 及以上高速均衡开始 |
| 35 | RECOVERY_EQUALIZATION_1 | 均衡阶段 1 | 发送端预设/系数评估 |
| 36 | RECOVERY_EQUALIZATION_2 | 均衡阶段 2 | 接收端请求和反馈 |
| 37 | RECOVERY_EQUALIZATION_3 | 均衡阶段 3 | 完成最终均衡确认 |
| 38 | RECOVERY_EQUALIZATION_FORCE_TIMEOUT | 均衡强制超时 | Retimer/测试模式的均衡超时分支 |
| 39 | SLAVE_LOOPBACK_ACTIVE | 从回环活动 | 作为回环从端响应测试 |
| 100 | SEARCHING | 监视器搜索中 | Passive Monitor 无法跟随 DUT 状态时的监视器状态 |

初始 Gen1 建链通常可以观察到：

~~~
INITIAL
 -> Detect.Quiet
 -> Detect.Active
 -> Polling.Active
 -> Polling.Configuration
 -> Configuration.Linkwidth.Start
 -> Configuration.Linkwidth.Accept
 -> Configuration.LaneNum.Wait
 -> Configuration.LaneNum.Accept
 -> Configuration.Complete
 -> Configuration.Idle
 -> L0
~~~

如果随后从 Gen1 升到 Gen3/Gen4，则会再次进入 Recovery；Gen3 及以上通常还
会经过 Equalization 阶段。

### 3.1 一次建链的状态推进判定表

下表把“状态机做什么”和“波形上如何证明它做到了”放在一起。状态回退是
协议的一部分：接收错误、超时或重新训练时，LTSSM 可以回到 Polling、Recovery
甚至 Detect；不能只看某个状态曾经出现过一次。

| 顺序 | 状态/中文 | 协议动作 | 进入下一阶段的证据 | 失败或回退通常说明 |
|---:|---|---|---|---|
| 0 | INITIAL / 初始化 | 建立 PHY、接口和内部时序 | `reset=0` 后状态离开 99，`phy_ready` 有效 | reset 未释放、HDL agent 未完成初始化、时钟无效 |
| 1 | Detect.Quiet / 检测静默 | 双方保持 Electrical Idle，等待检测窗口 | 对端退出 idle 或 receiver-detect 成功 | 没有物理连接、DUT PHY 仍复位、link enable 未执行 |
| 2 | Detect.Active / 检测活动 | 发起 Receiver Detect，确认终端存在 | `receiver_present`/信号有效，进入 Polling.Active | P/N 接反、lane 接错、终端/PHY 检测失败 |
| 3 | Polling.Active / 轮询活动 | 发送 TS1；建立 comma、解码和接收锁定 | `serdes_locked=1`，TS1 连续计数，收到对端 TX | bit timing、P/N、编码、DUT TX/RX 或时钟失败 |
| 4 | Polling.Configuration / 轮询配置 | 由 TS1 过渡到 TS2，交换 link/lane 和能力字段 | TS2 连续计数，进入 Configuration.Linkwidth.Start | TS 字段非法、解码错误、能力/训练参数不一致 |
| 5 | Configuration.Linkwidth.* / 链宽度协商 | 确定双方共同可用的 x1/x4/x8/x16 宽度 | `pl_status[15:20]`/`link_width` 稳定且双方接受 | 某些 lane 无效、宽度被降级或反复回 Detect |
| 6 | Configuration.LaneNum.* / lane 编号协商 | 分配逻辑 lane number，完成顺序和 deskew | `phy_lane_map`/lane number 稳定，进入 Complete | offset、lane reversal、极性、lane 间 skew 错误 |
| 7 | Configuration.Complete/Idle / 配置完成/空闲 | 结束训练序列，准备正常工作或速率切换 | 状态到 L0，或明确进入 Recovery | 最后 TS 丢失、速率目标不同、单 lane 再次失效 |
| 8 | Recovery.RcvrLock / 恢复锁定 | 新速率下重新建立 CDR/PLL 和 ordered-set 接收 | 所有有效 lane 重新 `serdes_locked=1` | refclk/bit period、抖动、编码或数据质量问题 |
| 9 | Recovery.Speed / 恢复速率 | 切换 Gen 速率和 UI | 新速率下 recovered clock 稳定 | DUT 不支持目标速率或切换时钟不符合容差 |
| 10 | Recovery.Equalization 0~3 / 均衡 0~3 | 交换 EQ TS1，评估和调整 TX preset/coefficients | 各有效 lane 的 EQ request/complete 完成 | preset/CTLE/DFE/高速信号质量或能力协商失败 |
| 11 | Recovery.RcvrCfg/Idle / 恢复配置/空闲 | 交换恢复后的 TS1/TS2，确认宽度和训练完成 | 回到 L0 且 `link_up=1` | 重新训练或回到 Detect，说明恢复未完成 |
| 12 | L0 / 正常工作 | 允许 DLLP/TLP，链路进入业务状态 | `ltssm_state=L0`、`link_up=1`、宽度符合预期 | 若很快掉到 Recovery，优先查 PHY/SerDes，不是先查 BAR |

基础 Gen1/Gen2 建链可能没有明显的 Equalization 阶段；这不表示均衡逻辑
失效，而是目标速率没有触发该流程。反过来，看到 L0 也只证明当前速率下
链路可工作，若测试要求 Gen4，还必须另外确认 `current_rate`/`local_rate`
和双方 capability。

### 3.2 波形中看到的协议对象

LTSSM 的状态变化是控制结果，真正推动状态机的是下面这些 PCIe PHY 对象：

| 协议对象 | 作用 | 波形上的可见证据 | 缺失时的典型状态 |
|---|---|---|---|
| Electrical Idle | 链路未传输时保持差分空闲，避免把噪声当成训练数据 | `rx_elec_idle`、`tx_elec_idle` | Detect.Quiet/Detect.Active 不前进 |
| Receiver Detect | 发送端检测对端终端是否存在 | `receiver_present`、detect 控制/结果 | Detect.Active 反复 |
| TS1 Ordered Set | 初始训练、comma/接收锁定及基本能力交换 | TS1 连续计数、PCS ordered-set 解码 | Polling.Active 长时间停留 |
| TS2 Ordered Set | 确认训练参数、lane/link number 和切换配置阶段 | TS2 连续计数、TS1→TS2 转换 | Polling.Configuration 停留 |
| Lane/Link Number | 把物理 lane 映射为逻辑 lane，并支持 deskew | `phy_lane_map`、lane number 字段 | Configuration.LaneNum 停留或降宽 |
| EIOS/EIEOS/FTS | 电气空闲进入/退出及速率切换期间的同步 | 对应 ordered-set 计数/检测信号 | Recovery 或 Polling.Speed 失败 |
| EQ TS1/coefficients | Gen3+ 评估通道并调整发送端预加重 | EQ phase、preset/coeff、eval request/complete | Recovery.Equalization 反复 |
| DLLP/TLP | L0 后的链路层控制和业务包，不参与基础 PHY 建链 | `L0` 后才有稳定包活动 | 在 L0 前查 BAR/TLP 没有意义 |

因此调试顺序必须从 PHY 到链路层：先确认 Electrical Idle/Receiver Detect，
再确认 TS1/TS2 和 lane mapping，最后才分析配置空间、BAR、DLLP/TLP。把
L0 以前的问题归因于 TL sequence，通常会把真正的连线或时钟问题掩盖掉。

## 4. 建链前置条件：Reset、参考时钟和 link_en

### 4.1 SVT Serial reset

路径：

~~~
tb.svt_rc0_spd.vip_port_if.ser_if.reset
tb.svt_rc1_spd.vip_port_if.ser_if.reset
tb.svt_rc2_spd.vip_port_if.ser_if.reset
tb.svt_rc3_spd.vip_port_if.ser_if.reset
~~~

宏中 reset 是高有效：

~~~
reset = 1：SVT Serial 复位
reset = 0：SVT Serial 释放
~~~

释放复位后，DUT 自己的 PERST#、PHY reference clock、PHY PLL 和 LTSSM 使能
仍然需要由用户环境控制。link_en.enable=1 只是允许 SVT 链路训练，不会
代替 DUT 复位或产生 DUT reference clock。

### 4.2 内部发送 bit clock 模式

当前宏使用：

~~~systemverilog
.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE(1'b0)
~~~

此时 SVT 内部产生发送 bit clock。可观察：

~~~
R0.tx_bit_clk[0:7]
R0.SER_GEN_0.serdes.recovered_bit_clk
~~~

active_tx_transmit_clk_N 和 active_rx_recovered_clk_N 是 SVT active PHY
提供的观察时钟：

~~~
tb.svt_rc0_spd.vip_port_if.ser_if.active_tx_transmit_clk_0
tb.svt_rc0_spd.vip_port_if.ser_if.active_rx_recovered_clk_0
~~~

用户不需要把 active_rx_recovered_clk 回接到 DUT，也不能把 DUT PHY
reference clock 当作 SVT active TX bit clock。

官方 SVT-to-SVT Serial interconnect 的时钟连接可以作为方向校验参考：

~~~
端 A.rx_datap/datan <- 端 B.tx_datap/datan
端 A.rx_clk       <- 端 B.active_tx_transmit_clk
端 A.tx_clk       <- 端 B.active_rx_recovered_clk
~~~

接真实 DUT 时，`rx_datap/datan` 和 `tx_datap/datan` 仍按 §1 的数据方向连接；
`rx_clk/tx_clk` 是否需要连接，取决于 DUT 是否提供给 SVT/Passive Monitor 的
串行采样时钟。它们不能用 DUT 的低频 reference clock 代替。当前 active
宏的内部发送 bit clock 只解决 SVT 自己的 TX 时序，不会替 DUT 产生
recovered clock。

### 4.3 link_en 的作用

每条 SVT RC 都需要启动一次对应的 link enable sequence：

~~~
RC0_EP0 -> svt_rc0
RC1_EP1 -> svt_rc1
RC2_EP2 -> svt_rc2
RC3_EP3 -> svt_rc3
~~~

它是 sequence/UVM 操作，不一定对应一个可见的 HDL 单 bit 信号。启动时间
应在波形中与 reset 释放、DUT PHY ready 和第一个 TX 活动对齐。

一次完整的“控制层 → HDL 层”顺序应是：

1. 顶层 elaboration 产生 `svt_rcX_spd`、`vip_port_if.ser_if` 和 Serial
   adapter；静态 `update_if_variables()` 把每个 HDL slot 发布给对应的
   UVM/backend link。此时只能说明连接对象存在，不能说明链路已训练。
2. 用户环境稳定 DUT reference clock，按 DUT 要求释放 PHY/PERST#，确认
   PHY ready；同时把 SVT `ser_if.reset` 从 1 释放到 0。
3. backend 根据 `link_id` 找到该 RC 的 device agent/virtual sequencer，
   启动官方 `svt_pcie_dl_service_set_link_en_sequence`（或用户封装的同类
   sequence），设置 `enable=1`。sequence 返回表示调用完成，不表示 L0。
4. active PHY 由 Detect 开始驱动 TX；DUT 收到 TS1/TS2 后返回训练序列，
   LTSSM 才会按第 3 节推进。对 `link_up && ltssm_state == L0` 做有界等待，
   不能只等待 `start()` 返回。
5. 四条 RC 都进入 L0 后，才开始配置空间、BAR、Memory Read/Write 或 DMA；
   这些事务失败不能反推 PHY 建链失败，必须先检查 L0 判定是否成立。

常见控制层误判是：Tcl/AIP 命令返回 `OK`、UVM sequence 打印 `done`，但 HDL
仍为 `INITIAL` 或 Detect。这表示 sequence 已执行而训练前置条件未满足，排查
应回到 reset、clock、pad 方向和 `link_en` 绑定，而不是先提高 TL 日志级别。

## 5. 各 LTSSM 状态的协议原理和调试方法

### 5.1 Detect.Quiet：检测静默

协议目的：

- 接收端保持 Electrical Idle；
- 等待对端退出 Electrical Idle；
- 为 Receiver Detect 做准备。

应观察：

~~~
R0.pl0.ltssm_state = 0
R0.rx_elec_idle[0:7] = 1
R0.sig_level_valid[0:7] = 0
~~~

如果一直停在这里：

- SVT reset 可能没有释放；
- link_en 没有启动；
- DUT 没有提供有效 RX/TX 物理连接；
- DUT PHY 仍处于复位；
- P/N 或 lane 映射错误。

调整顺序：

1. 确认 ser_if.reset 从 1 变为 0；
2. 确认对应 RC 的 link_en 已启动；
3. 确认 DUT reference clock 和 PHY ready；
4. 确认 SVT TX 与 DUT RX 方向没有接反。

### 5.2 Detect.Active：检测活动

协议目的：

- 发起 Receiver Detect；
- 检测对端终端或接收器是否存在；
- 检测成功后进入 Polling.Active。

主要路径：

~~~
R0.pl0.ltssm_state
R0.phy_ctrl0_detect_receiver
R0.phy_ctrl0_receiver_present[0:7]
R0.rx_elec_idle[0:7]
~~~

正常现象：

~~~
ltssm_state = 1
receiver_present 至少有对应有效 lane
随后转到 ltssm_state = 2
~~~

如果状态在 0/1 之间反复：

- 对端没有被稳定检测到；
- 某个 lane 的接收器检测失败；
- lane 连接或终端建模不正确；
- reset/clock 在检测过程中抖动。

四条链同时失败时，优先查公共 reset、reference clock 和编译配置；单条链
失败时，优先查对应 EP 和 pad 分组。

### 5.3 Polling.Active：轮询活动，TS1 训练

协议原理：

- 双方开始发送 TS1 Ordered Set；
- 此时的主要目的不是最终协商宽度，而是确认串行数据、编码和接收锁定；
- 接收端要先能够识别 comma、完成 8b/10b 对齐并持续收到有效 TS1。

主要 HDL 路径：

~~~
R0.pl0.ltssm_state
R0.pl0.num_rx_consecutive_ts1_sets[0:7]
R0.pl0.num_rx_consecutive_ts2_sets[0:7]
R0.pl0_serdes_locked[0:7]
R0.SER_GEN_0.serdes.serdes_locked
R0.SER_GEN_0.serdes.pll_locked
R0.SER_GEN_0.serdes.recovered_bit_clk
R0.comma_detect[0:7]
~~~

外部接口路径：

~~~
tb.svt_rc0_spd.vip_port_if.ser_if.tx_datap_0~7
tb.svt_rc0_spd.vip_port_if.ser_if.tx_datan_0~7
tb.svt_rc0_spd.vip_port_if.ser_if.rx_datap_0~7
tb.svt_rc0_spd.vip_port_if.ser_if.rx_datan_0~7
~~~

正常现象：

~~~
ltssm_state = 2
SVT TX P/N 持续活动
DUT RX P/N 出现对应活动
DUT TX P/N 开始返回数据
SVT RX P/N 出现返回活动
num_rx_consecutive_ts1_sets[*] 持续有效
serdes_locked[*] 最终有效
~~~

常见问题：

| 现象 | 说明 | 调整方向 |
|---|---|---|
| SVT TX 无活动 | SVT 没开始训练 | 查 reset、link_en、agent active、宏 mode |
| SVT TX 有，DUT RX 无 | SVT 到 DUT 连接错误 | 查 tx_datap/datan 到 DUT RX、P/N、lane offset |
| DUT RX 有，DUT TX 无 | DUT 未接受训练 | 查 DUT RX PHY、PERST#、PHY ready、DUT LTSSM |
| DUT TX 有，SVT rx_* 无 | DUT 到 SVT 连接错误 | 查 DUT TX 到 SVT RX、P/N、lane 位序 |
| 只有部分 TS1 lane 有效 | 局部 lane 连接或 PHY 问题 | 逐 lane 对照 SER_GEN_N 和 pad |
| serdes_locked 反复 0/1 | 接收时钟/编码/数据质量不稳定 | 查 recovered clock、bit period、P/N、时间精度 |

### 5.4 Polling.Configuration：轮询配置，TS2 训练

协议原理：

- 双方继续交换 TS1/TS2；
- 开始交换 lane number、link number、N_FTS、速率能力等训练信息；
- 只有在训练序列内容有效且稳定后，才能进入 Configuration。

观察：

~~~
R0.pl0.ltssm_state = 4
R0.pl0.num_rx_consecutive_ts1_sets[0:7]
R0.pl0.num_rx_consecutive_ts2_sets[0:7]
R0.PCS_GEN_0.pcs.num_decode_errs_since_last_comma
R0.PCS_GEN_0.pcs.rx_disparity
R0.PCS_GEN_0.pcs.rx_elastic_buffer_overflow_flag
R0.PCS_GEN_0.pcs.rx_elastic_buffer_underflow_flag
R0.PCS_GEN_0.pcs.eios_detected
~~~

正常情况下：

~~~
TS1 计数持续出现
TS2 计数开始出现
ltssm_state 从 4 进入 6
~~~

如果 TS1 有而 TS2 没有：

- DUT 不能正确解析 TS1；
- lane/link number 字段不匹配；
- 训练控制字段不一致；
- 速率能力声明不一致；
- 某 lane 出现 disparity、invalid code、comma 后解码错误或 bit 错误。

这一步不应先修改 TL、配置空间或 BAR。问题仍然位于 PHY/SerDes 训练层。

### 5.5 Polling.Speed：轮询速率

该状态不是所有基础建链都会经过，但在速率切换或部分版本配置中可能出现。

协议目的：

- 双方准备切换到新的数据速率；
- 重新建立接收锁定；
- 速率切换后重新进入配置或 Recovery。

观察：

~~~
R0.pl0.ltssm_state = 5
R0.pl0.local_rate
R0.rate
R0.SER_GEN_N.serdes.recovered_bit_clk
R0.SER_GEN_N.serdes.serdes_locked
~~~

如果进入 Polling.Speed 后回到 Detect：

- 新速率下接收端无法锁定；
- DUT 速率切换没有完成；
- reference clock 或 bit clock 不满足要求；
- 高速 P/N、抖动或时间精度有问题。

### 5.6 Configuration.Linkwidth.Start：链宽度开始

协议原理：

- 双方确定哪些物理 lane 真实可用；
- 通过 TS1/TS2 判断 x1/x2/x4/x8 等宽度；
- 只有连续有效的 lane 才能参与最终宽度协商。

观察：

~~~
R0.pl0.ltssm_state = 6
R0.pl0.receiver_detect_max_width
R0.pl0.link_width
R0.pl0.pl_status[15:20]
R0.pl0.num_rx_consecutive_ts1_sets[0:7]
~~~

4RC 中每条链期望为 x8。如果这里出现 `pl_status[15:20]` 或 `link_width`
小于 8，优先查对应 8 个 lane 是否全部有效，而不是修改 TL 配置。

### 5.7 Configuration.Linkwidth.Accept：链宽度接受

协议原理：

- 双方对可用宽度达成一致；
- 关闭未参与协商的 lane；
- 准备进入 lane number 配置。

观察：

~~~
R0.pl0.ltssm_state = 7
R0.pl0.link_width
R0.pl0.pl_status[15:20]
R0.pl0.pl_status[21:26]
~~~

如果状态从 6 反复回到 Detect，通常表示对端无法接受当前宽度或某些 lane
在 deskew/训练期间失效。

### 5.8 Configuration.LaneNum.Wait / Accept：lane 编号配置

对应状态：

~~~
8 = CONFIGURATION_LANENUM_WAIT
9 = CONFIGURATION_LANENUM_ACCEPT
~~~

协议原理：

- 给每个有效物理 lane 分配逻辑 lane number；
- 确认 lane 顺序、lane reversal 和 deskew；
- 让接收端能把不同 lane 上的数据重新拼成一个链路。

应观察：

~~~
R0.pl0.ltssm_state
R0.pl0.phy_lane_map[0:7]
R0.pl0.link_width
R0.pl0.pl_status[15:20]
R0.comma_detect[0:7]
~~~

常见问题：

- RC1/RC3 的 pad offset 错误，把 DUT lane 8 接成 lane 0；
- lane reverse 配置与实际连接不一致；
- P/N 极性反转没有被 DUT 或 SVT 正确处理；
- lane 间 skew 过大，deskew 无法完成。

如果单条链宽度下降，而另一条链正常，优先检查该链的 lane offset 和物理
lane 顺序。

### 5.9 Configuration.Complete / Idle：配置完成和空闲

对应状态：

~~~
10 = CONFIGURATION_COMPLETE
11 = CONFIGURATION_IDLE
~~~

协议原理：

- lane number、link number、宽度和 deskew 已经完成；
- 双方发送最后的训练序列；
- 准备进入 L0，或因为速率切换进入 Recovery。

观察：

~~~
R0.pl0.ltssm_state
R0.pl0.pl_status[2]
R0.pl0.pl_status[15:20]
R0.pl0.pl_status[21:26]
R0.pl0.link_width
~~~

如果 Configuration.Idle 长时间不进入 L0：

- 最终训练序列没有满足对端要求；
- 某 lane 在最后阶段丢失；
- 双方目标速率不同；
- 直接进入 Recovery 但 Recovery 又失败。

### 5.10 Recovery.RcvrLock：恢复接收锁定

对应状态：

~~~
12 = RECOVERY_RCVRLOCK
~~~

协议原理：

- 重新建立接收 CDR/PLL 锁定；
- 检查新速率下的 bit period、comma 和 ordered set；
- 失锁时不能继续进入更高速度。

观察：

~~~
R0.pl0.ltssm_state
R0.pl0_serdes_locked[0:7]
R0.SER_GEN_N.serdes.pll_locked
R0.SER_GEN_N.serdes.serdes_locked
R0.SER_GEN_N.serdes.recovered_bit_clk
R0.SER_GEN_N.serdes.last_bit_period
R0.SER_GEN_N.serdes.average_bit_period
~~~

当前日志中的 SERDES unlocked、serdes_clk_slowdown，本质上就属于该类
接收锁定问题。应先确定是所有 lane 同时失锁，还是某一个 lane 单独失锁。

### 5.11 Recovery.Speed：恢复速率切换

对应状态：

~~~
13 = RECOVERY_SPEED
~~~

协议原理：

- 切换 Gen1/Gen2/Gen3/Gen4 等速率；
- 重新设置发送和接收的 UI；
- 速率切换后重新等待接收端锁定。

典型 UI：

~~~
Gen1 = 400 ps
Gen2 = 200 ps
Gen3 = 125 ps
Gen4 = 62.5 ps
~~~

应观察：

~~~
R0.pl0.local_rate
R0.rate
R0.tx_bit_clk[0:7]
R0.SER_GEN_N.serdes.recovered_bit_clk
~~~

如果旧速率下正常、新速率下掉回 Detect：

- DUT PHY 不支持或未正确切换目标速率；
- recovered clock 周期不符合 SVT 预期；
- SSC/频偏/时间精度导致时钟容差错误；
- 高速信号质量或均衡问题。

### 5.12 Recovery.Equalization：高速均衡

Gen3 及以上速率通常会经过：

~~~
34 = Equalization Phase 0
35 = Equalization Phase 1
36 = Equalization Phase 2
37 = Equalization Phase 3
~~~

协议原理：

- 发送端和接收端通过 EQ TS1 交换预设和系数；
- 接收端评估当前链路质量；
- 发送端根据反馈调整 precursor/cursor/postcursor；
- 所有有效 lane 都要完成均衡。

四个 phase 的关注点可以分开看：

| Phase | 中文含义 | 主要协议动作 | 波形判定 |
|---:|---|---|---|
| 0 | 均衡启动/预设初始化 | 双方进入高速 EQ，发送带初始 preset 的 EQ TS1 | 状态进入 34，所有有效 lane 仍有 ordered set 和 lock |
| 1 | 发送端预设评估 | 接收端对当前 preset 做评估并给出可接受/不可接受反馈 | `rx_eq_eval_requested`、preset/coeff 字段变化 |
| 2 | 接收端请求/发送端调整 | 接收端请求新的 preset 或 coefficient，发送端更新 TX FIR | `rx_eq_eval_complete`、precursor/cursor/postcursor 稳定 |
| 3 | 最终确认 | 双方确认最终系数并准备进入 Recovery.RcvrCfg/Idle | 所有有效 lane 完成，状态不反复回 Phase 0 |

可观察的 SVT HDL 信号包括：

~~~
R0.pl0.ltssm_state
R0.pl0.rx_eq_eval_requested[0:7]
R0.pl0.rx_eq_eval_complete[0:7]
R0.pl0.rx_precursor_coeff[0:7]
R0.pl0.rx_cursor_coeff[0:7]
R0.pl0.rx_postcursor_coeff[0:7]
~~~

如果 Gen1/Gen2 建链成功、Gen3/Gen4 失败，优先检查：

- DUT TX preset；
- DUT RX CTLE/DFE；
- EQ Phase 1/2/3 是否完成；
- 某个 lane 是否单独失败；
- Gen4 目标速率和双方 capability 是否一致。

不要在基础 lane mapping 尚未确认时直接调均衡参数。

### 5.13 Recovery.RcvrCfg / Idle：恢复配置和空闲

对应状态：

~~~
14 = RECOVERY_RCVRCFG
15 = RECOVERY_IDLE
~~~

协议原理：

- 交换恢复后的 TS1/TS2；
- 确认新速率下的 lane 宽度和 ordered set；
- 满足条件后回到 L0，失败则重新 Recovery 或 Detect。

观察：

~~~
R0.pl0.ltssm_state
R0.pl0.num_rx_consecutive_ts1_sets[0:7]
R0.pl0.num_rx_consecutive_ts2_sets[0:7]
R0.pl0_serdes_locked[0:7]
R0.pl0.pl_status[1]
~~~

### 5.14 L0：正常工作状态

对应状态：

~~~
16 = L0
~~~

L0 表示物理层训练完成，可以进行 DLLP/TLP 传输。建议至少同时确认：

~~~
R0.pl0.ltssm_state       = 16
R0.pl0.pl_status[0]       = 1
R0.pl0.pl_status[21:26]   = 8
R0.pl0.link_width         = 8
~~~

只有满足这些条件后，才开始配置空间、BAR、Memory Read/Write 或 DMA。

如果 link_up=1 但 width 不是 8，说明链路可能已经工作，但没有达到预期
x8，不应直接判定 4RC 建链完全成功。

### 5.15 低功耗、复位、回环和监视器专用状态

这些状态不是“首次 Detect→L0”主路径的必经步骤，但在长时间运行、Hot Reset、
ASPM 或 compliance/loopback 测试中必须能够解释：

| 状态组 | 协议原理 | 进入原因 | 调试重点 |
|---|---|---|---|
| L0s (`17~20`) | 在 L0 和低功耗电气空闲之间快速切换，使用 FTS 恢复对齐 | ASPM L0s 或链路短暂空闲 | `tx/rx_elec_idle`、FTS 计数、recovered clock；退出失败会回 Recovery |
| L1/L1.1/L1.2 (`21~26`) | 逐级关闭更多链路/参考时钟资源，唤醒后重新建立接收时序 | ASPM/L1 PM policy | 低功耗使能、refclk 唤醒、L1.2 exit；不要把正常 L1 当成掉链 |
| L2 (`27~28`) | 更深的链路关闭和唤醒流程 | 关机/电源管理 | 唤醒序列、电源和 PERST#；通常需要重新训练 |
| Disabled (`29`) | 链路被配置或错误条件明确禁用 | 用户配置、错误恢复策略 | 查 disable 原因和配置，不先改 P/N |
| Hot Reset (`30`) | 通过链路训练序列传播热复位，不等同于上电 fundamental reset | RC/DUT 发起 Hot Reset | 区分 `ser_if.reset`、DUT PERST# 与 Hot Reset；复位后应重新走训练 |
| Loopback (`31~33,39`) | 将发送数据回送到接收端进行 PHY/compliance 验证 | compliance/loopback test | 回环路径和测试模式；真实 DUT 正常建链不应误入 |
| EQ force timeout (`38`) | 均衡测试/retimer 场景的强制超时分支 | 特殊测试配置 | 确认是否误打开 retimer/compliance 选项 |
| SEARCHING (`100`) | Passive Monitor 自己无法从采样的 RX/TX 序列重建 DUT LTSSM | 监视器没有正确采样时钟、数据或状态跳变过快 | 查 Passive Monitor 的 `rx_clk/tx_clk` 和数据方向；它不等于 active VIP 的 LTSSM |

首次 4RC 建链看到上述状态时，先确认测试是否真的启用了对应功能。尤其是
`SEARCHING` 是 monitor 的观察状态，不代表 active RC/DUT LTSSM 本身处于数值
100；应同时查看 active `pl0.ltssm_state` 和 `pl_status.link_up`。

## 6. 失败位置和调整顺序

### 6.1 停在 INITIAL/Detect

检查顺序：

~~~
reset
 -> DUT reference clock
 -> DUT PHY ready
 -> link_en
 -> SVT TX/RX 方向
 -> P/N 和 lane mapping
~~~

### 6.2 停在 Polling.Active

检查顺序：

~~~
SVT tx_datap/datan
 -> DUT rx pad
 -> DUT tx pad
 -> SVT rx_datap/datan
 -> recovered clock
 -> serdes lock
 -> TS1 counter
~~~

### 6.3 停在 Polling.Configuration

重点查：

~~~
TS1/TS2
lane number
link number
data rate capability
PCS_GEN_N.pcs.num_decode_errs_since_last_comma
PCS disparity / elastic-buffer error
~~~

### 6.4 停在 Configuration

重点查：

~~~
pl_status[15:20] (configured width mirror, if present)
link_width
phy_lane_map
lane reversal
deskew
~~~

### 6.5 停在 Recovery/Equalization

重点查：

~~~
local_rate
recovered_bit_clk
pll_locked
serdes_locked
last_bit_period
average_bit_period
EQ phase
preset/coefficient
~~~

### 6.6 已经 L0 后掉链

重点看：

~~~
last_ltssm_state
ltssm_state
pl_status[0]
pl_status[1]
pl0_serdes_locked
recovered_bit_clk
DUT PHY PLL lock
~~~

如果 L0 -> Recovery.RcvrLock -> Detect，通常是 SerDes 失锁或接收错误，
不是配置空间访问本身导致的错误。

## 7. 当前 SerDes 时钟错误的专项定位

当前错误：

~~~
serdes_clk_slowdown
New large bit seen, but not at least 2x old bit
was 0.399960 ns, now is 0.400000 ns
SERDES unlocked
CLK_TOLERANCE = 0.000100
~~~

在错误时间点附近，四条链分别抓：

~~~
tb.svt_rc0_spd.m_ser.port0.SER_GEN_0.serdes.recovered_bit_clk
tb.svt_rc0_spd.m_ser.port0.SER_GEN_0.serdes.serdes_locked
tb.svt_rc0_spd.m_ser.port0.SER_GEN_0.serdes.last_bit_period
tb.svt_rc0_spd.m_ser.port0.pl0_serdes_locked[0]
tb.svt_rc0_spd.m_ser.port0.pl0.ltssm_state
tb.dut.pad0_phy_tx0_p
tb.dut.pad0_phy_tx0_m
~~~

判断方法：

~~~
四条链同时失锁 -> 公共 refclk、SSC、时间精度、公共配置
只有一条链失锁 -> 对应 EP、pad 分组、lane mapping、单独 PHY
DUT TX 消失后失锁 -> 先查 DUT
DUT TX 仍有而 SVT recovered clock 失锁 -> 查 bit timing、P/N、抖动和 SerDes
~~~

建议顺序：

1. 全工程统一 1ns/1fs 或等效的 timeunit/timeprecision；
2. 重新编译整个 simv；
3. 检查 DUT reference clock 是否有真实频偏或 SSC；
4. 检查具体 lane 的 last_bit_period 和 average_bit_period；
5. 确认 SVT 内部发送 bit clock 模式与 DUT 配置一致；
6. 只有确认该频偏符合设计预期后，才考虑放宽 SVT serial clock tolerance。

不要首先通过修改 disable_ext_bit_clock_mode 来掩盖 recovered-clock 失锁。

## 8. FSDB/VCS 调试准备

-debug_access+all 只保证信号可访问，不保证信号一定写入 FSDB。波形 dump
范围还必须包含 SVT model。例如可以选择性 dump：

~~~systemverilog
$fsdbDumpvars(0, tb.svt_rc0_spd.m_ser.port0);
$fsdbDumpvars(0, tb.svt_rc1_spd.m_ser.port0);
$fsdbDumpvars(0, tb.svt_rc2_spd.m_ser.port0);
$fsdbDumpvars(0, tb.svt_rc3_spd.m_ser.port0);
~~~

如果全量 dump 太大，第一轮只加入：

~~~
pl0.ltssm_state
pl0.last_ltssm_state
pl0.pl_status
pl0.link_width
pl0.pl_status[15:20]
pl0_serdes_locked
rx_elec_idle
sig_level_valid
num_rx_consecutive_ts1_sets
num_rx_consecutive_ts2_sets
~~~

必要时在顶层建立 debug alias，方便波形检索：

~~~systemverilog
wire [31:0] rc0_ltssm_state_dbg;
wire [63:0] rc0_pl_status_dbg;
wire [31:0] rc0_serdes_locked_dbg;

assign rc0_ltssm_state_dbg =
  svt_rc0_spd.m_ser.port0.pl0.ltssm_state;
assign rc0_pl_status_dbg =
  svt_rc0_spd.m_ser.port0.pl0.pl_status;
assign rc0_serdes_locked_dbg =
  svt_rc0_spd.m_ser.port0.pl0_serdes_locked;
~~~

这些 alias 仅用于 debug，不要对 SVT 内部 LTSSM、pl_status 或 SerDes 锁定
信号进行 force。需要改变训练行为时，应修改合法的 SVT 配置、DUT PHY 配置
或测试 sequence。

### 8.1 一次可复现的 VCS/Verdi 调试操作

推荐每次只改变一个因素，保留编译命令、seed、time precision 和 FSDB：

1. 编译时至少打开 `-debug_access+all`，并统一顶层和时钟文件的
   `1ns/1fs`（或项目等效的 `timeunit/timeprecision`）。`-debug_access+all`
   只保证对象可被访问，不自动把对象写入 FSDB。
2. 在顶层对报错链路先 dump `svt_rcX_spd.m_ser.port0`；如果 dump 量过大，
   只保留第 8 节 A 级信号。发生锁定/均衡问题后，再扩大到 B/C 级路径。
3. 用同一个 test/seed 重跑，在 Verdi 中先定位 `svt_rcX_spd`，再沿实际
   `port0/pl0` 层级搜索 `ltssm_state`。不要先从 `svt_be` 的 UVM class
   对象寻找 HDL pin；两者不是同一棵层级树。
4. 在波形中放置以下时间标记：SVT reset 释放、DUT reset/PERST# 释放、
   PHY ready、`link_en.enable=1`、第一笔 SVT TX、第一笔 DUT TX、TS1、TS2、
   Configuration、Recovery/Equalization、L0 以及第一次失锁。
5. 按“SVT TX → DUT RX → DUT TX → SVT RX → lock/TS → LTSSM”的方向逐级
   缩小范围。某一级没有活动时，先保存该级前后的波形截图和对应的状态值，
   再修改连接/时钟/复位；不要同时改 lane mapping、速率和 timeout。
6. 同时对 RC0~RC3 做横向比较：四条链在同一时间点失败，优先查公共
   reset/refclk/编译宏；只有一条链失败，优先查该 EP、pad group、lane offset
   和该 lane 的 SerDes lock。

如果仿真没有 FSDB，而只有 UCLI，可以先用 `scope`/Design Browser 记录实际
层级和状态，再补充 dump 重新运行；UCLI 里读到的某个 status 值不能替代
连续波形，因为 TS1/TS2 计数和锁定信号可能只持续很短时间。

## 9. 推荐的实际调试流程

### 第一步：只分析一条链

先选择报错最早或最明确的一条，例如 RC2：

~~~
tb.svt_rc2_spd.m_ser.port0.pl0.ltssm_state
tb.svt_rc2_spd.m_ser.port0.pl0.pl_status
tb.svt_rc2_spd.m_ser.port0.pl0_serdes_locked[0:7]
tb.svt_rc2_spd.m_ser.port0.pl0.num_rx_consecutive_ts1_sets[0:7]
tb.svt_rc2_spd.m_ser.port0.pl0.num_rx_consecutive_ts2_sets[0:7]
~~~

### 第二步：标记关键时间

~~~
SVT reset 释放
DUT reset 释放
link_en 启动
第一次 SVT TX 活动
第一次 DUT TX 活动
TS1 开始
TS2 开始
Configuration 开始
Recovery 开始
Equalization 开始
L0
SERDES unlocked
~~~

### 第三步：按方向逐级确认

~~~
SVT TX
  -> DUT RX
  -> DUT TX
  -> SVT RX
  -> recovered clock / serdes lock
  -> LTSSM 状态推进
~~~

数据在哪一级消失，就先修哪一级，不要跨层修改。

### 第四步：横向比较四条链

最后再同时比较 RC0~RC3：

~~~
同一时间、同一状态全部失败：公共环境问题
只有一个 RC 失败：局部 pad、lane、EP 或 PHY 问题
宽度全部降为 x4：公共宽度/配置问题
只有 RC1/RC3 降宽：优先检查 pad lane 8~15 offset
~~~

## 10. 建链完成判定清单

每条链都应满足：

~~~
ser_if.reset = 0
ltssm_state = 16 (L0)
pl_status[0] = 1 (link_up)
pl_status[21:26] = 8 (x8)
link_width = 8
~~~

如果还要求 Gen4，则另行确认当前速率已经达到 Gen4，不能仅凭进入 L0 就断言
最终速率已经完成。

四条链全部达到上述条件后，再启动配置空间访问、BAR 配置、Memory Read/Write
和 DMA 流量。
