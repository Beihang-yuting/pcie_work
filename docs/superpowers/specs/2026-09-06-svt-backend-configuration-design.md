# SVT Backend 自动配置与多 Host 映射设计

## 1. 目标

在不增加第二套 PCIe 控制环境的前提下，为 `pcie_tl_env` 增加可选的 SVT
backend。用户只选择 backend 和拓扑配置，backend 自动创建实际启用的 SVT
UVM device agent，并把公共 PCIe 策略转换为 Synopsys SVT R-2020.12 配置。

SVT backend 还要集中管理均衡（EQ）、链速、快速建链、SVT 日志、shadow
configuration、Multi-Endpoint 和 Target App 等 SVT 专属参数。

## 2. 总体边界

```text
pcie_global_cfg / pcie_tl_env
    ├── 拓扑、角色、链路数量和链路启用
    ├── BDF、PF/VF、BAR、枚举策略
    ├── Host memory 与 Root 绑定
    ├── 公共 timeout 和 stage 控制
    └── backend 选择
            |
            +-- TL_ONLY
            |     └── pcie_tl_env
            |
            +-- SVT_REAL_DUT
            |     ├── pcie_tl_env
            |     └── pcie_svt_backend
            |           └── svt_pcie_device_agent[]
            |
            └-- SVT_TL_FORWARD
                  ├── pcie_tl_env
                  └── SVT Mapper/forward adapter
```

`pcie_tl_env` 是唯一的 PCIe 配置、枚举和 TL traffic 控制面。SVT backend
不是第二套 topology 或 traffic 环境，而是一个可选的 backend 实现。

TL-only filelist 不得依赖 Synopsys SVT 类型。SVT 类型只允许出现在 SVT
integration package、backend 和对应 filelist 中。

## 3. 动态 UVM 与静态 HDL 的边界

backend 可以在 `build_phase` 动态创建：

- `svt_pcie_device_configuration`；
- `svt_pcie_device_status`；
- `svt_pcie_device_agent`；
- `pcie_svt_if_adapter`。

以下内容仍然必须在 HDL elaboration 前静态存在：

- `svt_pcie_single_port_device_agent_hdl`；
- `pcie_svt_serial_port_if`；
- x4/x8/x16 lane width；
- `SVT_PCIE_UI_NUM_PHYSICAL_LANES`；
- `PCIE_SVT_ENV_MAX_HDL_AGENTS` 对应的 slot；
- 真实 DUT 的 Serial/PIPE 端口连接。

因此 runtime backend 只能在预先编译的静态 slot 中选择和启用 link，不能
通过 plusarg 在仿真运行时改变 lane 数量或新增 HDL instance。

## 4. 配置分层

### 4.1 公共 `pcie_global_cfg`

该对象保持后端无关，包含：

- `pcie_topology_cfg topology`；
- `pcie_backend_e backend`；
- `pcie_link_cfg links[$]`；
- `pcie_device_cfg devices[$]`；
- runtime link 数量和静态 slot 校验；
- Host/Root 绑定所需的逻辑标识。

`pcie_link_cfg.max_gen` 和 `pcie_link_cfg.link_width` 是公共链路意图。SVT
backend 将其转换成 SVT 的 supported/target/expected speed 配置；TL backend
只用于拓扑检查和能力策略。

### 4.2 SVT 专用 `pcie_svt_backend_cfg`

该对象只在 SVT filelist 中定义和使用，至少包含：

```systemverilog
bit enable;
pcie_svt_transport_e transport;

int unsigned default_max_gen;
bit direct_gen4_enable;
bit fast_link_training;

bit enable_equalization;
int unsigned eq_mode;
bit full_equalization_required;

bit enable_shadow_cfg_lookup;
bit enable_multi_endpoint_mode;
bit target_app_enable;
bit target_auto_response;

time link_timeout;
time cfg_timeout;
time enum_timeout;
time traffic_timeout;

uvm_verbosity svt_verbosity;
bit enable_svt_monitor;
bit enable_transaction_log;

pcie_svt_link_override_cfg link_override[string];
```

配置优先级如下：

```text
SVT 默认值
  < global_cfg 公共链路/设备策略
  < pcie_svt_backend_cfg 全局覆盖
  < link_override[link_id] 链路级覆盖
  < 用户 customize_svt_agent_cfg() hook
```

如果链路级配置与全局 SVT 配置冲突，链路级显式配置优先；如果
`pcie_link_cfg.max_gen` 与 SVT backend 没有显式覆盖，则使用公共链路策略。

## 5. 官方 SVT 配置映射

backend 按 `pcie-device-base-test` 的生命周期顺序执行：先得到 VIF，再创建
SVT device configuration/status，应用角色和物理能力，最后创建 agent。

### 5.1 VIF 和角色

```systemverilog
svt_cfg.set_initial_values_via_unified_vif(1'b1, link_vif);
svt_cfg.device_is_root = (link_role == PCIE_DEVICE_RC);
```

backend 必须检查 global link role、HDL slot role 和 SVT `device_is_root` 一致。

### 5.2 Device model

`FULL_VIP` 使用：

```systemverilog
svt_cfg.dut_model =
    svt_pcie_device_configuration::NOT_APPLICABLE;
```

只有 Application/Mapper backend 使用 `RTL` model。真实 Serial DUT 不得误选
`MAPPER_APP`，否则事务不会经过 SVT DL/PL/PHY。

### 5.3 链速和 EQ

backend 使用 SVT 官方 PL 配置接口：

```systemverilog
svt_cfg.pcie_cfg.pl_cfg.set_link_speed_values(
    supported_speed_mask,
    target_speed,
    expected_speed);

svt_cfg.pcie_cfg.pl_cfg.set_link_eq_attribute_values(
    eq_mode,
    enable_direct_speed_up_from_2_5g_to_16g,
    ...);
```

该 API 的第二个参数不是“是否要求 Full Equalization”，而是
`enable_direct_speed_up_from_2_5g_to_16g`。本项目由
`direct_gen4_enable || fast_link_training` 计算该参数；它表示允许从
2.5 GT/s 直接加速到 16 GT/s。`eq_mode` 仍负责选择 Full、Bypass 或
No-Equalization 模式，兼容字段 `full_equalization_required` 不直接传给该
参数。PCIe 基础接收检测和规范要求的初始训练仍然存在，不能宣称完全跳过
Gen1。

### 5.4 Shadow configuration 和 Multi-Endpoint

TL env 是配置空间控制者时默认关闭：

```systemverilog
svt_cfg.pcie_cfg.tl_cfg.enable_shadow_cfg_lookup = 1'b0;
```

一个物理 SVT EP 模拟多个 BDF 时才打开：

```systemverilog
svt_cfg.pcie_cfg.enable_multi_endpoint_mode = 1'b1;
```

BAR aperture 使用官方 BAR RO map 和 Target App service sequence 表达，不能
仅把 BAR 最终值写成全 1。

### 5.5 Status、链路和日志

每个 active link 保留独立的 `svt_pcie_device_status`。公共 link sequence
通过 backend 的 status/virtual sequencer 等待：

```systemverilog
status.pcie_status.pl_status.link_up
status.pcie_status.pl_status.ltssm_state
```

链路启动复用：

```systemverilog
svt_pcie_dl_service_set_link_en_sequence
```

日志分为 UVM verbosity、SVT monitor 开关和 transaction log 开关。backend
只通过公开 SVT/UVM 配置接口应用这些设置，不直接访问 SVT 私有成员。

## 6. 自动创建 agent 的规则

backend 根据 `global_cfg.links[]` 中 `enabled && use_svt` 的链路创建 agent。
每条物理 SVT link 生成一组独立对象：

```text
one link
  ├── one svt_pcie_device_configuration
  ├── one svt_pcie_device_status
  ├── one svt_pcie_device_agent
  └── one pcie_svt_if_adapter
```

用户不需要在 test 中手动创建这些 UVM agent。用户只需在 HDL top 提供静态
slot/VIF，并把 `global_cfg` 和 `pcie_svt_backend_cfg` 发布到 backend scope。

backend 对外暴露只读查询句柄和一个配置 hook：

```systemverilog
virtual function void customize_svt_agent_cfg(
    int link_index,
    pcie_link_cfg link_policy,
    svt_pcie_device_configuration svt_cfg);
```

hook 在默认策略和链路覆盖应用后、agent 创建前执行。

## 7. Host、Root、Function 与 SVT agent 的关系

Host 数量不直接决定 SVT agent 数量。

```text
Host 数量        → Host memory manager 数量和 Root binding
PCIe 物理 link 数 → SVT agent/config/status 数量
PF/VF 数量       → function/BDF 配置数量
```

### 7.1 一个 Host 对应多个 Root

```text
Root0 -> Host0
Root1 -> Host0
Root2 -> Host0
```

需要三个 Root 的 PCIe 配置/状态上下文，但可以共享一个 Host memory manager。
`bind_host_memory()` 对每个 Root 显式调用；PREMAP backing memory 对同一 manager
只分配一次。

### 7.2 多个 Host 对应多个 Root

```text
Root0 -> Host0
Root1 -> Host1
Root2 -> Host0
```

每个 Root 仍然拥有独立的 PCIe/SVT link 上下文，但 Root0/Root2 可以共享
Host0 memory manager。

### 7.3 一个物理 Endpoint 的多个 PF/VF

一个物理 Endpoint 默认只创建一个 SVT agent；多个 PF/VF 作为多个 function
或 BDF 配置记录。只有一个 SVT EP agent 需要同时模拟多个 BDF 时才启用
Multi-Endpoint。

### 7.4 没有 PCIe link 的 Host

只创建 Host memory 相关对象，不创建 SVT agent。

## 8. 典型拓扑

| 场景 | SVT agent 数量 | 说明 |
|---|---:|---|
| SVT RC + DUT EP x16 | 1 RC | DUT EP 不创建 SVT agent |
| 四条独立 DUT EP 链路 | 4 RC | 每条 link 一个 SVT RC |
| DUT RC + 四个 SVT EP | 4 EP | 每个物理 EP 一个 SVT agent |
| SVT RC + DUT Switch + 四个 SVT EP | 1 RC + 4 EP | TL env 管理端口，DUT 完成物理转发 |
| SVT RC + 完整 DUT Switch/EP | 1 RC | 不创建虚假的下游 SVT EP |

## 9. 兼容性要求

- `pcie_tl_vip/sim/filelist.f` 不得引入 SVT。
- 未选择 SVT backend 时，不创建 SVT UVM agent，不绑定 SVT adapter。
- 现有 `pcie_tl_env`、TL sequence 和 TL-only test API 保持兼容。
- `pcie_device_unified_vip_env` 只作为官方 SVT peer 自检入口保留，不作为真实
  DUT backend 的必需层。
- 真实 Serial 使用 `FULL_VIP`；PIPE 只保留显式未实现的分发入口。

## 10. 验证标准

1. TL-only 模式不加载 SVT 类且既有回归保持通过。
2. SVT_REAL_DUT 模式可根据 enabled/use_svt link 数量自动创建 agent。
3. 单 x16、四独立 link、1 USP+4 DSP 三种配置的 agent 数量和角色正确。
4. EQ、链速、快速建链和日志配置能在 agent 创建前生效。
5. 多 Host/Root 绑定不产生重复 agent，也不重复初始化共享 Host manager。
6. SVT agent 与静态 VIF/HDL slot 的映射错误在 build 阶段报告 fatal。
7. 双 SVT Serial formal 回归继续通过，且真实 DUT source-only filelist 不
   依赖官方 unified env。
