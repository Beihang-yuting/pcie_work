# PCIe Unified Environment 使用说明

## 配置层次

统一环境使用 `pcie_global_cfg` 作为管理层入口，但连接关系仍由已有的
`pcie_topology_cfg` 描述。配置分成三层：

1. 拓扑图：RC、Switch、EP 节点以及 link 上下游关系。
2. link 策略：`enabled`、`use_svt`、x4/x8/x16、Gen4/Gen5、VIF key 和静态
   HDL slot。
3. device 策略：BDF、Type-0/Type-1 header、BAR0~BAR5、配置空间和 Bus
   Master 策略。

TL backend 会把 device 策略翻译成独立的 `pcie_tl_func_context`。因此多个
   EP/DSP 可以拥有不同的 BDF、4KB 配置空间和 BAR 状态；Switch 的 USP/DSP
   Type-1 bridge image 仍由 `pcie_tl_switch_port` 管理。

SVT backend 使用同一份 link/device 策略，但 HDL interface、SVT HDL agent 和
   物理 lane 数量必须在编译时确定。用户负责 RTL top、SerDes/PIPE 和 VIF
   物理连接，环境负责配置传递、建链、配置空间初始化、枚举和 traffic sequence。

## Backend 选择

```text
PCIE_BACKEND_TL_ONLY
  仅创建 TL 环境，不实例化 SVT HDL agent。

PCIE_BACKEND_SVT_REAL_DUT
  SVT active VIP 连接真实 RTL。

PCIE_BACKEND_SVT_TL_FORWARD
  只有显式选择时才启用 SVT-TL adapter，用于混合验证。
```

`pcie_device_base_test` 提供 `build_topology()` 和 `build_global_cfg()` 两个
   hook。用户 test 在 `build_global_cfg()` 中修改 backend、link enable/use_svt、
   BDF、BAR 和超时策略。

## 编译期 slot 宏

项目使用私有宏，不能覆盖 Synopsys 的 `SVT_PCIE_MAX_NUM_LINKS`：

```text
PCIE_SVT_ENV_MAX_HDL_AGENTS   静态生成的 SVT HDL slot 上限
PCIE_SVT_ENV_MAX_NUM_LINKS    UVM 管理层允许的逻辑 link 上限
```

默认值由 topology 宏推导：

```text
PCIE_TOPO_EP_X16              1 slot
PCIE_TOPO_EP_2X8              2 slots
PCIE_TOPO_SWITCH_1X16_4X4     5 slots
```

如果定义 `PCIE_USE_SVT_PEER`，所需静态 slot 数按两侧 agent 数量翻倍。运行时
可以禁用 link，但不能把 x4 物理 slot 变成 x8，也不能创建超过宏上限的 HDL agent。

示例：

```bash
+define+PCIE_TOPO_EP_X16
+define+PCIE_SVT_ENV_MAX_HDL_AGENTS=1
+define+PCIE_SVT_ENV_MAX_NUM_LINKS=1
```

## SVT VIF 激活语义

SVT HDL wrapper 必须为 link 提供非空 VIF handle。是否实际驱动由 VIF 中的：

```text
device_is_root       选择 RC 或 EP 角色
connect_active_vip   选择 active/inactive 驱动状态
```

因此 inactive 侧可以没有 SerDes 连接，但仍保留配置句柄；global-cfg 只校验
   期望角色和 slot 绑定，不替换 SVT HDL 侧的实际值。

## 验证限制

当前可独立复用的 TL 能力包括多 RC/EP、多 USP/DSP、DSP owner、bus/window、
Type-1 Switch image、独立 TL device context、BAR decoder 和配置空间管理。

SVT Target App 的 Multi-Endpoint BAR sizing 必须使用官方 RO-map/service 或
callback 流程。仅直接写 BAR 值不能表达 aperture。真实 DUT 模式下，配置空间和
BAR 的最终响应仍以 DUT/SVT Target App 的实际实现为准。
