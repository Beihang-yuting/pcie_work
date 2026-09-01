# PCIe Unified Global Configuration and Backend Environment

## 1. 目标

本设计把现有 Transaction Layer VIP 能力和 Synopsys SVT PCIe 能力放到同一
个环境管理接口下。现有 `pcie_topology_cfg`、TL Switch、配置空间、BAR
decoder 和内存路由逻辑继续作为 TL backend 的实现；新增的 `global-cfg`
只负责全局拓扑编排、设备级配置描述以及 SVT backend 的管理，不重新实现
一套与 TL 重复的拓扑模型。

目标场景包括：

1. `TL_ONLY`：不创建 SVT HDL agent，只使用现有 TL 环境完成 RC/EP、USP/DSP
   和 Switch 转发验证。
2. `SVT_REAL_DUT`：SVT active VIP 连接用户真实 RTL，TL proxy 不参与真实
   DUT 的数据路径。
3. `SVT_TL_FORWARD`：部分链路由 SVT VIP 驱动，另一部分通过明确的 TL
   adapter/forwarder 连接，用于混合验证。

## 2. 设计边界

### 2.1 动态部分和静态部分

UVM 管理层使用动态数组，在 `build_phase()` 根据运行时配置创建实际的
link、agent、sequencer、scoreboard 和 backend child。未启用的 link 不创建
UVM 组件。

HDL interface、SVT HDL agent 以及 `SVT_PCIE_UI_NUM_PHYSICAL_LANES` 必须在
elaboration 前静态确定。因此 lane width（x4/x8/x16）和 HDL slot 数量不能
通过运行时 plusarg 改变，只能通过编译宏和对应的 HDL generate 分支选择。

### 2.2 编译期资源上限

项目不得覆盖 Synopsys 原始 `SVT_PCIE_MAX_NUM_LINKS` 宏，而应使用项目私有
宏：

```systemverilog
`PCIE_SVT_ENV_MAX_HDL_AGENTS
`PCIE_SVT_ENV_MAX_NUM_LINKS
```

`PCIE_SVT_ENV_MAX_HDL_AGENTS` 决定静态生成的 SVT HDL agent 槽位数量；
`PCIE_SVT_ENV_MAX_NUM_LINKS` 决定 UVM 管理层允许的逻辑 link 上限。默认值
根据 `PCIE_TOPO_EP_X16`、`PCIE_TOPO_EP_2X8` 和
`PCIE_TOPO_SWITCH_1X16_4X4` 推导，但命令行可以用 `+define+...` 覆盖。
运行时 `runtime_num_links` 必须不大于这两个编译期上限。

开启 SVT peer 时，静态 HDL agent 数量按实际需要增加；真实 DUT 场景只生成
主动 SVT 侧的 agent，DUT 侧的物理连接由用户顶层负责。官方环境要求的
inactive VIF 句柄仍由 HDL wrapper 提供，但 inactive 侧不驱动 SerDes。

## 3. 配置模型

### 3.1 拓扑的唯一来源

`pcie_topology_cfg` 仍然是节点和链路关系的权威来源，包含：

- RC、Switch、EP 节点；
- USP/DSP 数量和 DSP owner USP；
- link 的上下游节点、port index、width、Gen 和 enabled 状态。

`pcie_global_cfg` 持有或引用该对象，并在进入任何 backend 前调用现有拓扑
校验。这样 TL 和 SVT 不会分别维护两份拓扑连接关系。

### 3.2 设备级配置

新增 `pcie_device_cfg` 描述每个可枚举设备的配置空间属性：

- node/port 标识和角色；
- BDF；
- Type-0 或 Type-1 header；
- BAR0~BAR5 的实现状态、64-bit、Prefetchable、aperture 和初始地址；
- capability 和 memory-space enable 策略。

该对象用于把同一套设备配置分别翻译到 TL 的
`pcie_tl_cfg_space_manager`/`pcie_tl_func_manager` 和 SVT 的 device
configuration/Target App 配置。

### 3.3 link 运行时配置

每条 link 记录包含 `enabled`、`use_svt`、RC/EP role、width、Gen、VIF key、
bus/dev/func 和超时策略。`enabled` 控制 UVM 组件是否创建；SVT VIF 中的
`device_is_root` 和 `connect_active_vip` 仍是 HDL 侧实际角色和驱动状态的
权威值，global-cfg 只用于期望值校验和管理层选择。

## 4. 环境层结构

新增统一环境 `pcie_unified_env`，只做生命周期编排和 backend 选择，不直接
实现 TLP 路由：

```text
pcie_device_base_test
  └── pcie_global_cfg
        └── pcie_unified_env
              ├── pcie_svt_topology_env   // SVT_REAL_DUT 或混合模式
              ├── pcie_tl_custom_env       // TL_ONLY 或混合模式
              └── backend adapter          // 明确的 SVT↔TL 边界
```

SVT env 和 TL env 只有在 backend 需要时才创建。TL_ONLY 不编译或不实例化
SVT HDL agent；SVT_REAL_DUT 不启用旧的 sidecar/proxy 数据路径。

新增的 base-test 参考官方 `pcie-device-base-test` 的配置时序和注释风格，
但不复制官方固定单 RC/单 EP 假设。它负责：

1. 解析宏和 plusarg；
2. 创建并校验 `pcie_global_cfg`；
3. 将同一配置放入统一 env；
4. 启动 backend 对应的 link bring-up、配置空间初始化、枚举和 traffic
   virtual sequence。

## 5. TL backend 复用和补齐范围

现有 `pcie_tl_custom_env`、`pcie_tl_env` 和 Switch 组件继续复用，已有能力
包括动态 RC/EP agent、多个 USP/DSP、DSP owner、bus/window、Type-1 Switch
port、Tag/FC/Ordering 和 TL 路由。

需要通过 global-cfg translator 补齐或明确以下内容：

- 非 Switch 多 RC/EP 的 link-to-agent 映射；
- 每个下游 EP 独立的 Type-0 配置空间和 BAR context；
- 每个 device 的 BDF 与 BAR 描述向 TL manager 的绑定；
- Switch port 的 Type-1 image 与下游 EP device image 的区分。

当前 Switch port 的 bus/window/BDF 建模不能替代每个下游 Endpoint 的独立
配置空间。不能把多个 DSP EP 简单地绑定到同一个 owner USP 的 config manager
后就宣称每个 EP 已独立建模。

## 6. SVT backend 复用范围

SVT backend 复用官方 `pcie_device_unified_vip_env` 的 device agent、配置
对象和 virtual sequencer。项目侧只负责：

- 从 global-cfg 生成每个启用 link 的 SVT descriptor；
- 获取静态 HDL slot 对应的 VIF；
- 校验 `device_is_root`/`connect_active_vip`；
- 传递 Gen、lane width、Endpoint multi-BDF、BAR RO map 和 BDF；
- 启动 link bring-up、configuration-space initialization、enumeration 和
  memory traffic sequence。

SVT 配置空间的 BAR sizing 必须使用官方 Target App service sequence 或
callback 机制，不能仅靠直接写 BAR 值伪造 aperture。

## 7. 注释和代码组织要求

所有新增 SystemVerilog 文件必须包含文件头注释，说明职责、依赖、backend
范围和使用限制。每个 public class、配置字段、宏和关键 phase/adapter
函数都必须有具体注释，尤其要解释：

- 为什么某个数组是动态的或静态的；
- 为什么某个 VIF 可以 inactive 但句柄仍必须存在；
- `global_cfg` 字段如何映射到 TL/SVT；
- Switch Type-1 port 和下游 EP Type-0 device 的区别；
- 编译宏和运行时 link enable 的区别。

不允许把大段逻辑压成无注释的连续代码，也不通过删除原始官方注释来“整理”
文件。重构旧代码时保留仍然有效的原注释，并为项目新增行为补充注释。

## 8. 验证标准

实现完成后至少验证：

1. `TL_ONLY`：单 RC/EP、2 RC/2 EP、1 USP+4 DSP 和多 USP Switch 的
   compile/elaboration；
2. TL 配置空间读写、Type-1 bus/window、独立 BDF 和 BAR sizing/访问；
3. `SVT_REAL_DUT`：x16、2x x8、1x x16 + 4x x4 三种编译宏模式的
   compile/elaboration；
4. SVT link bring-up、配置空间初始化、枚举和基础 memory traffic；
5. 未启用的 link 不创建 UVM agent，HDL agent 数量不超过宏上限；
6. `SVT_TL_FORWARD` 的 adapter 只在显式选择该 backend 时启用，不能影响
   `SVT_REAL_DUT` 的真实 RTL 数据路径。

## 9. 实施顺序

1. 添加 global/device/link cfg 和编译宏，保留现有 TL 环境不变；
2. 添加 TL translator，先保证现有 TL 回归不退化；
3. 添加统一 env 和新的 base-test；
4. 重写 HDL slot wrapper，使 slot 数量受宏限制；
5. 接入 SVT backend 和官方 sequence；
6. 对每个 backend 做 compile/elaboration 和最小运行回归；
7. 确认无引用后再删除旧的重复 topology/proxy/sidecar 文件，并同步更新
   文档和 filelist。
