# 四链路（4×x8）SVT RC + DUT EP 集成说明

本文档描述“4 条独立 x8 物理链路，每条链路由 SVT VIP 模拟 Root Complex、
对端为真实 DUT Endpoint”的完整端到端集成方式，覆盖 HDL 顶层、编译宏、
UVM env/config、SVT backend、链路训练和 RC→DUT EP 业务流量。文中的
4×x8 是一个可直接套用的完整示例；x4/x16 只需替换 HDL slot 与 topology
中的链路宽度，连接规则见 §2.1。

对应 `docs/superpowers/specs/2026-09-06-svt-backend-configuration-design.md`
§8 拓扑表第二行：**四条独立 DUT EP 链路 → 自动创建 4 个 SVT RC agent，
DUT EP 侧不创建任何 SVT agent**。

```text
SVT RC0 ──x8 Serial── DUT EP0        link_id: RC0_EP0   hdl_slot 0
SVT RC1 ──x8 Serial── DUT EP1        link_id: RC1_EP1   hdl_slot 1
SVT RC2 ──x8 Serial── DUT EP2        link_id: RC2_EP2   hdl_slot 2
SVT RC3 ──x8 Serial── DUT EP3        link_id: RC3_EP3   hdl_slot 3
```

## 1. 角色与所有权模型

| 实体 | 数量 | 说明 |
|---|---|---|
| 物理链路 | 4 | agent 创建的唯一驱动来源（不是 Host 数量） |
| SVT RC agent | 4 | 由 `pcie_svt_backend` 按 `enabled && use_svt` 链路自动创建 |
| SVT EP agent | 0 | 对端是真实 DUT，`svt_role=RC` 表示 SVT 只模拟 RC 端 |
| TL RC agent | 4 | `pcie_tl_env` 按 provider 返回的 RC 计数创建 |
| Host memory manager | 1~4 | 纯内存域对象，与链路解耦，见 §5 |

## 2. 静态 HDL 顶层

每条链路一个 SVT 单端 HDL agent，使用
`svt_pcie_integration/rtl/pcie_svt_hdl_agent_macros.svh` 中的
`PCIE_SVT_DECLARE_HDL_AGENT_X4/X8/X16` 宏（按 lane 宽度选择）：

```systemverilog
`timescale 1ns/1fs
module my_4rc_dut_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "import_pcie_svt_uvm_pkgs.svi"
  `include `SVC_SOURCE_MAP_SUITE_UTIL_V(pcie_svc,PCIE,latest,svc_util_parms)
  `include `SVC_SOURCE_MAP_SUITE_MODEL_MODULE(pcie_svc,Include,latest,pciesvc_parms)
  `include "pcie_svt_hdl_agent_macros.svh"

  bit reset = 1'b1;
  int unsigned global_random_seed = 0;

  // 如果使用官方 example env/interconnect，可实例化 global shadow 并通过
  // EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH 指向它；本例只使用 backend + DUT，
  // 不依赖该对象，因此自研顶层可以省略 global_shadow0。
  // pciesvc_global_shadow #(.DISPLAY_NAME("global_shadow0.")) global_shadow0();

  // 4 个 SVT RC HDL slot（每条 x8）。宏参数依次为：
  //   instance_name, display_name, clkreq, wake, reset, is_root, hierarchy
  // is_root=1 表示 SVT 侧是 Root；hierarchy 每实例必须唯一。
  // 展开产物：<name>_if（svt_pcie_if）、<name>_spd（HDL agent）、
  //           <name>_serial（pcie_svt_serial_port_if，接 DUT SerDes）
  // 本例把 clkreq/wake 传 0，表示不建模这两个 sideband；它们不是
  // SerDes bit clock。若 DUT 有真实 clkreq/wake 管脚，请把这里的常量换成
  // 对应顶层信号，并按 DUT 的极性连接。
  `PCIE_SVT_DECLARE_HDL_AGENT_X8(svt_rc0, "SVT_RC0.", 1'b0, 1'b0, reset, 1, 0)
  `PCIE_SVT_DECLARE_HDL_AGENT_X8(svt_rc1, "SVT_RC1.", 1'b0, 1'b0, reset, 1, 1)
  `PCIE_SVT_DECLARE_HDL_AGENT_X8(svt_rc2, "SVT_RC2.", 1'b0, 1'b0, reset, 1, 2)
  `PCIE_SVT_DECLARE_HDL_AGENT_X8(svt_rc3, "SVT_RC3.", 1'b0, 1'b0, reset, 1, 3)

  // DUT 的每组 16 条单 bit 差分 pad 先绑定成向量视图，再按链路宽度
  // 连接到 SVT Serial 端口。rx 是 SVT TX -> DUT RX，tx 是 DUT TX -> SVT RX。
  pcie_svt_serial_port_if #(16) pad0_if();
  pcie_svt_serial_port_if #(16) pad1_if();
  `PCIE_SVT_BIND_PAD16_SCALAR(pad0_if, pad0)
  `PCIE_SVT_BIND_PAD16_SCALAR(pad1_if, pad1)
  `PCIE_SVT_CONNECT_DUT_SERDES_X8(svt_rc0_serial, pad0_if,  0)
  `PCIE_SVT_CONNECT_DUT_SERDES_X8(svt_rc1_serial, pad0_if,  8)
  `PCIE_SVT_CONNECT_DUT_SERDES_X8(svt_rc2_serial, pad1_if,  0)
  `PCIE_SVT_CONNECT_DUT_SERDES_X8(svt_rc3_serial, pad1_if,  8)

  // DUT 端口名按用户 RTL 实际声明填写；以下 pad 是 DUT 的真实边界信号。
  my_dut u_dut ( /* pad0_phy_* / pad1_phy_*，以及各 EP 的复位和参考钟 */ );

  // 每个静态 HDL agent 必须在静态 initial 块调用官方 update_if_variables，
  // 不能从 UVM class/function 调用。RC 端使用 port ID 4'h0；第二个参数
  // 是数字 link_id，发布的 config-DB key 为 link_<link_id>_vif_0。
  initial begin
    svt_rc0_spd.update_if_variables(4'h0, 8'd0, "uvm_test_top", "uvm_test_top");
    svt_rc1_spd.update_if_variables(4'h0, 8'd1, "uvm_test_top", "uvm_test_top");
    svt_rc2_spd.update_if_variables(4'h0, 8'd2, "uvm_test_top", "uvm_test_top");
    svt_rc3_spd.update_if_variables(4'h0, 8'd3, "uvm_test_top", "uvm_test_top");
  end
  // → 发布 link_0_vif_0 / link_1_vif_0 / link_2_vif_0 / link_3_vif_0

  initial begin #200ns; reset = 1'b0; end
  initial run_test("my_4rc_dut_test");
endmodule
```

### 2.1 两组 16-lane scalar pad 的连接

`PCIE_SVT_BIND_PAD16_SCALAR` 和 `PCIE_SVT_CONNECT_DUT_SERDES_X4/X8/X16`
都直接定义在 `svt_pcie_integration/rtl/pcie_svt_hdl_agent_macros.svh` 中。
pad 向量复用已有的 `pcie_svt_serial_port_if #(16)`，每组 pad 的 lane 编号
为 0~15；`p` 是正端，`m` 是负端：

```systemverilog
pcie_svt_serial_port_if #(16) pad0_if();
pcie_svt_serial_port_if #(16) pad1_if();

// pad0_phy_rx0_p/m ... pad0_phy_rx15_p/m：DUT 输入
// pad0_phy_tx0_p/m ... pad0_phy_tx15_p/m：DUT 输出
// pad1 同理
`PCIE_SVT_BIND_PAD16_SCALAR(pad0_if, pad0)
`PCIE_SVT_BIND_PAD16_SCALAR(pad1_if, pad1)
```

字段方向按 DUT 边界命名，不能对调：

```text
svt_rc<i>_serial.rx_*  = SVT TX -> DUT pad*_phy_rx*_p/m
DUT pad*_phy_tx*_p/m   -> svt_rc<i>_serial.tx_* = SVT RX
```

本例的四条 x8 链路（默认 lane 0 对应 bit 0）使用：

```systemverilog
`PCIE_SVT_CONNECT_DUT_SERDES_X8(svt_rc0_serial, pad0_if,  0)
`PCIE_SVT_CONNECT_DUT_SERDES_X8(svt_rc1_serial, pad0_if,  8)
`PCIE_SVT_CONNECT_DUT_SERDES_X8(svt_rc2_serial, pad1_if,  0)
`PCIE_SVT_CONNECT_DUT_SERDES_X8(svt_rc3_serial, pad1_if,  8)
```

两条 x16 链路则各占一组 pad：

```systemverilog
`PCIE_SVT_CONNECT_DUT_SERDES_X16(svt_rc0_serial, pad0_if, 0)
`PCIE_SVT_CONNECT_DUT_SERDES_X16(svt_rc1_serial, pad1_if, 0)
```

如果拓扑是 1 条 x16 加 4 条 x4，则需要 5 个独立 SVT HDL slot，连接为：

```systemverilog
`PCIE_SVT_CONNECT_DUT_SERDES_X16(svt_rc0_serial, pad0_if,  0)
`PCIE_SVT_CONNECT_DUT_SERDES_X4 (svt_rc1_serial, pad1_if,  0)
`PCIE_SVT_CONNECT_DUT_SERDES_X4 (svt_rc2_serial, pad1_if,  4)
`PCIE_SVT_CONNECT_DUT_SERDES_X4 (svt_rc3_serial, pad1_if,  8)
`PCIE_SVT_CONNECT_DUT_SERDES_X4 (svt_rc4_serial, pad1_if, 12)
```

UVM 拓扑中的链路宽度必须与这里一致（x8 就配置为 width=8，x16 就配置为
width=16），并为每个链路保留唯一的 `hdl_slot`/`vif_key`。四条 x8 或一条
x16 加四条 x4 都要求相应数量的独立 Endpoint 控制器，单个 x32 控制器不能
仅靠物理连线拆分。

PHY reference clock 仍由 DUT 顶层接入 DUT PHY，不接到这些 Serial 数据宏；
本次宏也不创建 Passive Monitor 时钟连接。

SVT 侧的 Passive Monitor 是旁路观察器，只采样 Serial symbol、解码链路
活动并向分析端口发布观察结果；它不驱动 TX/RX，也不会替 DUT 完成训练或
产生时钟。当前场景只需要 active SVT RC + 真实 DUT EP，因此不创建额外的
Passive Monitor。若后续确实要观察 DUT 侧波形，应在顶层单独实例化
`is_active=UVM_PASSIVE` 且 `enable_monitor=1` 的 SVT agent，并按 SVT
接口契约显式提供 bit clock：DUT TX transmit clock 接 monitor 的
`rx_clk`，DUT RX recovered clock 接 monitor 的 `tx_clk`。DUT PHY reference
clock 与这两个 bit clock 不是同一个信号。`active_tx_transmit_clk` 和
`active_rx_recovered_clk` 是 active SVT PHY model 输出给 monitor/其他 VIP
使用的时钟观察信号，不是 DUT reference clock，也不需要回接到 DUT。当前
数据连接宏只连接 `rx_p/rx_n` 与 `tx_p/tx_n`，不会替用户驱动上述时钟字段。

## 3. 编译宏与 filelist 顺序

HDL 顶层中的 `SVC_SOURCE_MAP_SUITE_UTIL_V(...)` 和
`SVC_SOURCE_MAP_SUITE_MODEL_MODULE(...)` 是 SVT 官方 source-map include
宏：它们负责按 Suite/版本定位并引入 SVT 的 utility/model 源码，不负责
拓扑、链路宽度或 DUT pad 连线。真实 DUT 集成仍需按下述顺序先完成官方
package/bootstrap，再编译 adapter 与用户 top。

`svt_pcie.uvm.pkg` 必须在 `pcie_svt_adapter_pkg` 之前编译。当前
`pcie_tl_svt_adapter.f` 已包含 `pcie_svt_vip_bootstrap.sv`，会在 adapter
package 之前自动 include 官方 package。用户只需维护一个**只定义宏、不
include package** 的 prefix，并把它放在 `-f` 列表之前：

```systemverilog
// user_svt_pkg_prefix.sv
// 可选：把随机种子锚定到用户顶层变量，便于复现。
`define SVC_RANDOM_SEED_SCOPE my_4rc_dut_top.global_random_seed
// 仅当官方 example env/interconnect 引用了 global shadow 时才需要这一行；
// 本文的自研 top + pcie_svt_backend 示例可以省略它。
// `define EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH my_4rc_dut_top.global_shadow0
```

`EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH` 不是 SVT backend 的必选宏：官方
example env 使用 global shadow 时必须指向真实层次；只接真实 DUT、由
`pcie_svt_backend` 创建 active SVT RC 的场景不需要定义。若更大的工程已经
编译过官方 package，则在编译命令中增加
`+define+PCIE_SVT_PKG_EXTERNAL`，并由外层流程在该 prefix 之后、adapter
之前编译一次 `svt_pcie.uvm.pkg`，避免重复定义 package。

```sh
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  +define+PCIE_SVT_ENV_MAX_NUM_LINKS=4 \
  user_svt_pkg_prefix.sv \
  -f svt_pcie_integration/sim/pcie_tl_svt_adapter.f \
  my_4rc_dut_top.sv my_4rc_test.sv
```

这里的顺序是硬性要求：prefix（先定义宏）→ source-only adapter filelist →
用户 DUT top → 用户 test。`PCIE_SVT_ENV_MAX_NUM_LINKS=4` 必须覆盖默认
上限，否则 `global_cfg.runtime_num_links=4` 会在 build 阶段被拒绝。

宏说明：

| 宏 | 作用 | 本场景取值 |
|---|---|---|
| `PCIE_SVT_ENV_MAX_NUM_LINKS` | 静态 HDL slot 上限；`runtime_num_links` 超过它会在 build 校验失败 | 4（默认是 1，必须显式给出） |
| `EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH` | 官方 example env/interconnect 使用的全局 shadow 实例路径 | 使用该官方路径时指向 `global_shadow0`；只接真实 DUT 的 backend 场景可省略 |
| `SVC_RANDOM_SEED_SCOPE` | 官方 package 的随机种子作用域 | 用户顶层的 `global_random_seed` |
| `PCIE_SVT_DECLARE_HDL_AGENT_X4/X8/X16` | 展开一组 svt_pcie_if + HDL agent + Serial 端口 | 每链一次，is_root=1 |
| `PCIE_SVT_BIND_PAD16_SCALAR` | 将一组 `padN_phy_rx/tx0..15_p/m` 绑定到 16-lane 向量接口 | 每组 pad 一次 |
| `PCIE_SVT_CONNECT_DUT_SERDES_X4/X8/X16` | 将 SVT Serial 端口连接到指定 pad lane slice | 每条链一次，`base_lane` 不重叠 |

## 4. UVM 策略配置（自动 backend）

下面是一个可直接改名使用的 test 骨架。构建链为
`global_cfg → pcie_tl_env → pcie_tl_backend_factory → pcie_svt_backend
→ 4× svt_pcie_device_agent`。test 只发布配置，不手工创建 SVT
agent/config/status；四个 active SVT RC 由 backend 按 `global_cfg.links[]`
自动创建，真实 DUT EP 不创建 SVT/TL EP agent。

```systemverilog
import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
import pcie_svt_adapter_pkg::*;
`include "uvm_macros.svh"

class my_4rc_dut_test extends uvm_test;
  `uvm_component_utils(my_4rc_dut_test)

  pcie_global_cfg          global_cfg;
  pcie_tl_env_config       tl_cfg;
  pcie_svt_backend_cfg     svt_backend_cfg;
  pcie_svt_backend_factory backend_factory;
  pcie_tl_env              tl_env;

  function new(string name = "my_4rc_dut_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_global_policy();
    pcie_topology_builder builder;
    pcie_topology_cfg topology;

    builder = pcie_topology_builder::type_id::create("topology_builder");
    for (int i = 0; i < 4; i++) begin
      void'(builder.add_rc($sformatf("RC%0d", i)));
      void'(builder.add_ep($sformatf("EP%0d", i)));
      void'(builder.connect($sformatf("RC%0d_EP%0d", i, i),
        $sformatf("RC%0d", i), PCIE_TOPO_PORT_RC, 0,
        $sformatf("EP%0d", i), PCIE_TOPO_PORT_EP, 0,
        8, 4));                         // x8, Gen4
    end
    topology = builder.finish();

    global_cfg = pcie_global_cfg::type_id::create("global_cfg");
    global_cfg.build_default_for_topology(topology);
    global_cfg.backend           = PCIE_BACKEND_SVT_REAL_DUT;
    global_cfg.svt_bridge_enable = 1'b1;
    global_cfg.runtime_num_links = 4;

    foreach (global_cfg.links[i]) begin
      pcie_link_cfg link = global_cfg.links[i];
      link.enabled        = 1'b1;
      link.use_svt        = 1'b1;
      link.svt_role_valid = 1'b1;
      link.svt_role       = PCIE_DEVICE_RC;
      link.svt_node_id    = link.upstream_node_id;
      link.has_hdl_slot   = 1'b1;
      link.hdl_slot       = i;             // 对应 svt_rc<i>
      link.vif_key        = $sformatf("link_%0d_vif_0", i);
    end
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    build_global_policy();

    svt_backend_cfg = pcie_svt_backend_cfg::type_id::create("svt_backend_cfg");
    svt_backend_cfg.init_defaults();       // SERIAL + FULL_VIP + Gen4
    svt_backend_cfg.transport                  = PCIE_SVT_TRANSPORT_SERIAL;
    svt_backend_cfg.backend_mode               = PCIE_SVT_BACKEND_FULL_VIP;
    svt_backend_cfg.default_max_gen            = 4;
    svt_backend_cfg.enable_equalization        = 1'b1;
    svt_backend_cfg.eq_mode                    = 0; // 自动 EQ 策略
    svt_backend_cfg.enable_shadow_cfg_lookup   = 1'b0;
    svt_backend_cfg.enable_svt_monitor         = 1'b0;
    // target_app_enable=1 / target_auto_response=0 保持默认值；不要让
    // SVT Target App 与 TL bridge 同时产生 Completion。

    backend_factory = pcie_svt_backend_factory::type_id::create(
      "svt_backend_factory");

    tl_cfg = pcie_tl_env_config::type_id::create("tl_cfg");
    tl_cfg.if_mode          = SV_IF_MODE;
    tl_cfg.rc_agent_enable  = 1'b1;
    tl_cfg.ep_agent_enable  = 1'b1;         // provider build 后会改为 0
    tl_cfg.num_rc           = 4;
    tl_cfg.num_ep           = 4;            // 保留物理 EP 槽位描述
    tl_cfg.rc_is_active     = UVM_ACTIVE;
    tl_cfg.ep_is_active     = UVM_PASSIVE;
    tl_cfg.fc_enable        = 1'b1;
    tl_cfg.infinite_credit  = 1'b1;
    tl_cfg.scb_enable       = 1'b1;
    tl_cfg.ep_auto_response  = 1'b0;        // DUT EP 自己响应
    tl_cfg.use_unified_mem  = 1'b0;         // 仅 RC→EP 业务时无需 Host memory

    uvm_config_db#(pcie_global_cfg)::set(
      this, "tl_env", "global_cfg", global_cfg);
    uvm_config_db#(pcie_svt_backend_cfg)::set(
      this, "tl_env", "pcie_svt_backend_cfg", svt_backend_cfg);
    uvm_config_db#(pcie_tl_backend_factory)::set(
      this, "tl_env", "pcie_tl_backend_factory", backend_factory);
    // topology env 从 tl_policy_cfg 读取行为策略；cfg 仅用于没有
    // topology 的历史直接注入路径。
    uvm_config_db#(pcie_tl_env_config)::set(
      this, "tl_env", "tl_policy_cfg", tl_cfg);

    tl_env = pcie_tl_env::type_id::create("tl_env", this);
endfunction
```

`run_phase` 和 §7 的检查函数应继续写在同一个 `my_4rc_dut_test` 类中；
本文最后用 `endclass` 结束该类。

关键约束（build 阶段 fatal，不静默降级）：

- `vif_key` 必须与 HDL `update_if_variables` 发布的 key 逐字符一致；
- 每条启用的 SVT 链路必须 `has_hdl_slot=1` 且 slot 唯一；
- 本文物理连接使用 SERIAL；若改用 PIPE，必须同时采用 PIPE 专用 HDL
  port/interface 和编译宏，不能把 Serial pad 宏混用；
- Gen 只支持 4/5，EQ mode 0~3（0 = 自动策略）。

### 每链差异化（可选）

```systemverilog
pcie_svt_link_override_cfg ov =
  pcie_svt_link_override_cfg::type_id::create("ov");
ov.has_max_gen = 1'b1;  ov.max_gen = 5;          // 让第 2 条链跑 Gen5
svt_backend_cfg.link_override["RC2_EP2"] = ov;    // key 是 link_id
```

## 5. Host memory 绑定（"四 Host"部分）

Host 只是 memory domain，不携带任何链路属性；链路/agent 数量永远由物理
link 决定，与 Host 数量无关（回归 `pcie_tl_backend_provider_unit_test`
用 Host1/Host4 变体固定验证这一点）。

四 Root 场景两种典型绑定，多 Root 环境必须为**每个 Root 显式**绑定：

```systemverilog
// 方式 A：四 Host —— 每个 Root 一个独立 manager
host_mem_manager host_mem[4];
for (int i = 0; i < 4; i++) begin
  string why;
  host_mem[i] = new($sformatf("host_mem_%0d", i));
  host_mem[i].set_host_id(i);
  if (!tl_cfg.bind_host_memory(i, i, host_mem[i], why))
    `uvm_fatal("HOST_MEM", why)
end

// 方式 B：单 Host —— 四个 Root 共享一个 manager
string why;
host_mem_manager shared_mem = new("shared_host_mem");
shared_mem.set_host_id(0);
for (int i = 0; i < 4; i++)
  if (!tl_cfg.bind_host_memory(i, 0, shared_mem, why))
    `uvm_fatal("HOST_MEM", why)
```

函数签名是 `bind_host_memory(root_index, host_id, mem, why)`，不能省略
`host_id` 或诊断字符串。本文的最小 RC→DUT EP 读写例子将
`use_unified_mem=0`，因此可以完全不绑定 Host memory；只有需要 DUT 发起
EP→RC DMA 或统一内存模型时才打开该选项并完成上述绑定。

规则（`pcie_tl_env_config.validate_host_memory_bindings`）：

- 一旦使用 `host_mem_by_root`，绑定数必须等于 Root 数，缺一个即报错；
- 共享 manager 允许（多个 Root 指向同一句柄），PREMAP backing memory 对
  同一 manager 只初始化一次，不会重复分配；
- 只有单 Root 旧路径允许从 config-db `host_mem` key 隐式获取。

## 6. 建链（link training）启动流程

backend 只负责 agent 创建前的链路配置（速率/宽度/EQ 通过官方
`set_link_speed_values` / `set_link_width_values` /
`set_link_eq_attribute_values` 生效），**不会自动启动链路训练**。
训练由 test 在 `run_phase` 显式启动：

1. 只启动 SVT RC 侧的 DL service sequence——DUT EP 是真实 RTL，其 LTSSM
   自行训练；
2. 每条链一个 `svt_pcie_dl_service_set_link_en_sequence`（enable=1），
   跑在该链 SVT agent 的 `pcie_virt_seqr.dl_seqr` 上；
3. 等待该链 status 进入 L0，四条链并行，统一超时兜底。

```systemverilog
task run_phase(uvm_phase phase);
  pcie_svt_backend svt_be;
  pcie_device_cfg ep0_cfg;
  pcie_tl_bar_enum_seq enum_seq;
  pcie_tl_rw_seq wr, rd;
  bit [31:0] bar0;

  phase.raise_objection(this);

  // env 持有中性 provider 句柄；downcast 拿 SVT 的 link->agent/status 表
  if (!$cast(svt_be, tl_env.backend_provider))
    `uvm_fatal("LINKUP", "backend provider 不是 pcie_svt_backend")

  #10us;   // 等 Serial HDL model 出复位

  fork : linkup_supervisor
    begin
      // 外层线程拥有每个 join_none 子线程，所以这里的 wait fork 会
      // 等待四条链全部完成，而不是只等待当前线程的兄弟进程。
      foreach (svt_be.svt_agent_by_link[link_id]) begin
        automatic string id = link_id;
        fork
          begin
            svt_pcie_dl_service_set_link_en_sequence en;
            en = svt_pcie_dl_service_set_link_en_sequence::type_id::create(
              {"link_en_", id});
            en.enable = 1'b1;
            en.start(svt_be.svt_agent_by_link[id].pcie_virt_seqr.dl_seqr);

            wait (svt_be.svt_status_by_link[id]
                    .pcie_status.pl_status.link_up == 1'b1);
            wait (svt_be.svt_status_by_link[id]
                    .pcie_status.pl_status.ltssm_state == svt_pcie_types::L0);
            `uvm_info("LINKUP", {id, " 进入 L0"}, UVM_LOW)
          end
        join_none
      end
      wait fork;
    end
    begin
      #500us;
      `uvm_fatal("LINKUP", "SVT/DUT Serial link-up 超时")
    end
  join_any
  disable linkup_supervisor;

  // L0 之后 TL 控制面接管：Config/BAR 枚举/Memory 全部由 TL sequence
  // 从对应 Root 的 sequencer 发起（按 Root，不按 Host）。多 Root 场景
  // 使用 rc_seqr_arr[rc_index]；rc_seqr 只是第一个 Root 的兼容别名。
  foreach (global_cfg.devices[i]) begin
    if ((global_cfg.devices[i] != null) &&
        (global_cfg.devices[i].role == PCIE_DEVICE_EP) &&
        (global_cfg.devices[i].device_id == "EP0"))
      ep0_cfg = global_cfg.devices[i];
  end
  if (ep0_cfg == null)
    `uvm_fatal("ENUM", "global_cfg.devices 中找不到 EP0")

  enum_seq = pcie_tl_bar_enum_seq::type_id::create("ep0_bar_enum");
  enum_seq.target_bdf = ep0_cfg.bdf;
  enum_seq.num_bars = 6;
  enum_seq.start(tl_env.v_seqr.rc_seqr_arr[0]);
  if (!enum_seq.assigned_bar_base.exists(0))
    `uvm_fatal("ENUM", "EP0 BAR0 未分配，不能开始 memory traffic")
  bar0 = enum_seq.assigned_bar_base[0];

  wr = pcie_tl_rw_seq::type_id::create("rc0_ep0_write");
  wr.op = PCIE_RW_WRITE;
  wr.addr = {32'h0, bar0} + 64'h100;
  wr.byte_len = 16;
  wr.wdata = new[16];
  foreach (wr.wdata[i]) wr.wdata[i] = 8'hA0 + i;
  wr.start(tl_env.v_seqr.rc_seqr_arr[0]);

  rd = pcie_tl_rw_seq::type_id::create("rc0_ep0_read");
  rd.op = PCIE_RW_READ;
  rd.addr = wr.addr;
  rd.byte_len = wr.byte_len;
  rd.rb_timeout_ns = 100_000;
  rd.start(tl_env.v_seqr.rc_seqr_arr[0]);
  if (rd.status != PCIE_RW_OK)
    `uvm_fatal("TRAFFIC", "RC0 -> DUT EP0 read completion failed")
  foreach (wr.wdata[i])
    if ((i >= rd.rdata.size()) || (rd.rdata[i] != wr.wdata[i]))
      `uvm_fatal("TRAFFIC", $sformatf("EP0 BAR0 data mismatch at byte %0d", i))

  phase.drop_objection(this);
endtask
```

要点：

- **是否每个 Host 都启动？不是。** 建链按物理 link 逐条启动（本场景 4
  次），Host 从不参与建链；无链路的 Host 只创建内存对象。
- 多 Host 绑同一批 Root 不改变启动次数；共享 Host manager 也只初始化
  一次。
- `svt_agent_by_link` / `svt_status_by_link` 是 `pcie_svt_backend` 的公开
  关联数组（以 link_id 为 key），即诊断/建链的权威入口；不要按序号猜。

业务流量的所有权也要保持一致：SVT RC 侧由 `pcie_tl_rw_seq`、
`pcie_tl_bar_enum_seq` 等 TL sequence 发起请求；DUT EP 侧由真实 RTL
完成 BAR 命中、Completion 和 DMA 响应。不要再打开 `ep_auto_response`，
也不要额外创建一个 SVT EP 来“帮 DUT 回包”。

## 7. 运行前检查清单

建议在 `end_of_elaboration_phase` 或 `run_phase` 建链前做一次断言，尽早
发现“拓扑配置与 HDL 实例数量不一致”的问题：

```systemverilog
function void check_4x8_contract();
  pcie_svt_backend svt_be;
  bit seen_slot[int];

  if (global_cfg.runtime_num_links != 4)
    `uvm_fatal("CONTRACT", "runtime_num_links 必须为 4")
  foreach (global_cfg.links[i]) begin
    pcie_link_cfg link = global_cfg.links[i];
    if (link == null)
      `uvm_fatal("CONTRACT", $sformatf("link[%0d] 为空", i))
    if (!link.enabled || !link.use_svt || (link.svt_role != PCIE_DEVICE_RC))
      `uvm_fatal("CONTRACT", $sformatf("link[%0d] 不是 SVT RC 链路", i))
    if (!link.has_hdl_slot)
      `uvm_fatal("CONTRACT", $sformatf("%s 缺少 hdl_slot", link.link_id))
    if (link.link_width != 8 || link.max_gen != 4)
      `uvm_fatal("CONTRACT", $sformatf("%s 必须是 x8/Gen4", link.link_id))
    if (seen_slot.exists(link.hdl_slot))
      `uvm_fatal("CONTRACT", $sformatf("重复 hdl_slot=%0d", link.hdl_slot))
    seen_slot[link.hdl_slot] = 1'b1;
    if (link.vif_key != $sformatf("link_%0d_vif_0", i))
      `uvm_fatal("CONTRACT", $sformatf("%s 的 vif_key 不匹配", link.link_id))
  end

  if (!$cast(svt_be, tl_env.backend_provider))
    `uvm_fatal("CONTRACT", "backend provider 不是 pcie_svt_backend")
  if (svt_be.created_rc_count != 4 || svt_be.created_ep_count != 0)
    `uvm_fatal("CONTRACT", "期望 4 个 SVT RC、0 个 SVT EP")
  if (tl_env.v_seqr.rc_seqr_arr.size() != 4)
    `uvm_fatal("CONTRACT", "期望 4 个 TL RC sequencer")
endfunction

function void end_of_elaboration_phase(uvm_phase phase);
  super.end_of_elaboration_phase(phase);
  check_4x8_contract();
endfunction
endclass
```

运行前还应逐项确认：

- HDL 顶层确实发布了 `link_0_vif_0` 到 `link_3_vif_0`，且每个
  `hdl_slot` 唯一；
- `global_cfg.runtime_num_links == 4`，四条 link 的宽度为 x8，SVT role
  全部是上游 RC；
- backend 创建 4 个 SVT RC agent、0 个 SVT EP agent；TL env 暴露 4 个
  `rc_seqr_arr`，DUT EP 由 RTL 自己响应；
- PHY reference clock 已接到 DUT，复位释放时序正确；本文的 Serial
  connector 不会替你提供 reference clock 或 Passive Monitor bit clock；
- 需要 EP→RC DMA 时才打开 `use_unified_mem`，并为 Root0~Root3 显式
  绑定 Host memory manager。

## 8. 常见错误

| 现象 | 原因 |
|---|---|
| build fatal "缺少 svt_pcie_vif" | `vif_key` 与 `update_if_variables` 发布的 key 不一致 |
| build fatal "runtime_num_links 超上限" | 未加 `+define+PCIE_SVT_ENV_MAX_NUM_LINKS=4` |
| 链路一直不进 L0 | 忘记启动 RC 侧 link_en，或 DUT 侧复位/时钟未释放 |
| 只有一条链建起来 | `update_if_variables` 的数字 link_id 重复或与 hdl_slot 不对应 |
| host memory 校验失败 | 多 Root 下只绑了部分 Root 的 manager |
