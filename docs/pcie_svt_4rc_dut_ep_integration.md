# 四链路（4×x8）SVT RC + DUT EP 集成说明

本文档描述“4 条独立 x8 物理链路，每条链路由 SVT VIP 模拟 Root Complex、
对端为真实 DUT Endpoint”的完整端到端集成方式，覆盖 HDL 顶层、编译宏、
UVM env/config、SVT backend、链路训练和 RC→DUT EP 业务流量。文中的
4×x8 是一个可直接套用的完整示例；x4/x16 只需替换 HDL slot 与 topology
中的链路宽度，连接规则见 §2.1。

建链阶段如果需要从 Verdi/FSDB 的 HDL 层级定位 Detect、Polling、
Configuration、Recovery、Equalization 和 L0，请先阅读
[PCIe SVT 4RC LTSSM/SerDes HDL 调试工作指南](pcie_svt_4rc_ltssm_hdl_debug.md)。
该文档以当前 R-2020.12 常见的实例层级
svt_rcX_spd.m_ser.port0.pl0、SER_GEN_N.serdes 和 PCS_GEN_N.pcs 为例，
并明确哪些路径需要在当前 simv 的 Design Browser 中确认；不依赖用户能否在
波形中看到 pcie_svt_backend 的 UVM class 对象。

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
  // Serial DUT 边界必须先提供接口类型和 lane 映射宏，再声明 HDL agent。
  `include "pcie_svt_serial_port_if.sv"
  `include "pcie_svt_serial_adapter.sv"
  `include "pcie_svt_hdl_agent_macros.svh"

  // 只驱动下面四个 SVT Serial agent 的高有效复位；DUT 复位另由顶层控制。
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

  // 200ns 仅为示例；真实 DUT 须按 §2.3 的上电/PHY ready 契约安排时序。
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

### 2.2 Serial 时钟与 Passive Monitor

`PCIE_SVT_DECLARE_HDL_AGENT_X4/X8/X16` 的 Serial 分支统一使用：

```systemverilog
.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE(1'b0),
```

这是 active SVT 的**内部发送 bit clock 模式**：SVT PHY 模型按当前链路
速率自行产生发送时序，训练变速时随之调整，用户不需要另写高速时钟。
本文只接 Serial 差分数据，因此不需要额外设置
`svt_cfg.pcie_cfg.pl_cfg.disable_ext_bit_clock_mode = 1'b1`，也不需要为此
派生 backend 或实现 `customize_svt_agent_cfg()`。该设置不自动启动训练，
仍需正常释放复位并执行 §6 的 `link_en`。

| HDL 参数 `SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE` | `pl_cfg.disable_ext_bit_clock_mode` | active SVT 发送时钟来源 |
|---|---|---|
| `0`（当前宏默认值） | 无需设置 | SVT 内部产生 |
| `1` | `0`（cfg 默认值） | 用户通过 `ext_clk_if.tx_clk_*` 提供外部 bit clock |
| `1` | `1` | 禁用外部时钟模式，改由 SVT 内部产生 |

旧版三个 Serial 宏使用 HDL 参数 `1`；若 cfg 保持默认 `0` 且没有提供
外部发送时钟，可能出现已经执行 `link_en`、但 LTSSM 停在 `INITIAL`、
差分数据无活动的现象。更新宏后必须**重新编译 HDL**，仅重跑 Tcl 或
旧 `simv` 不会生效；已有 cfg workaround 可以移除。PIPE 分支没有改动。
如果项目有意使用外部发送 bit clock，应选择表中第二种组合，并按所用
SVT 版本的 `ext_clk_if.tx_clk_*` 契约提供各速率时钟；不能用
`serial.tx_clk/rx_clk` 代替，它们是 Serial monitor 的采样时钟输入。

PHY reference clock 仍由 DUT 顶层独立接入 DUT PHY，不接到这些 Serial
数据宏，也不能替代上述高速 bit clock。
`active_tx_transmit_clk` 和 `active_rx_recovered_clk` 是 active SVT PHY
model 输出给 monitor/其他 VIP 使用的时钟观察信号，不是 DUT reference
clock，不需要用户驱动或回接到 DUT。

SVT 侧的 Passive Monitor 是旁路观察器，只采样 Serial symbol、解码链路
活动并向分析端口发布观察结果；它不驱动 TX/RX，也不会替 DUT 完成训练或
产生时钟。当前场景只需要 active SVT RC + 真实 DUT EP，因此不创建额外的
Passive Monitor。若后续确实要观察 DUT 侧波形，应在顶层单独实例化
`is_active=UVM_PASSIVE` 且 `enable_monitor=1` 的 SVT agent，并按 SVT
接口契约显式提供 bit clock：DUT TX transmit clock 接 monitor 的
`rx_clk`，DUT RX recovered clock 接 monitor 的 `tx_clk`。DUT PHY reference
clock 与这两个 bit clock 不是同一个信号。active VIP 改用内部发送时钟
不会免除 Passive Monitor 的采样时钟要求。当前数据连接宏只连接
`rx_p/rx_n` 与 `tx_p/tx_n`，不会替用户驱动 monitor 的时钟字段。

双 SVT 的 Tcl 建链复现方式及内部发送时钟验证记录，见
[AIP Tcl 建链诊断](pcie_svt_aip_link_diagnostic.md)。该用例不替代真实 DUT 验证。

### 2.3 Serial 复位与建链前置条件

**内部发送时钟模式不等于内部自动复位。** mode=0 只免除外部 active TX
bit clock；SVT 的 Serial reset 仍由用户顶层显式驱动，DUT 的 PHY reference
clock、复位和 LTSSM 使能也仍由用户环境负责。

| 对象/信号 | 谁驱动、何时有效 |
|---|---|
| 宏的第 5 个参数 `reset_signal` | 用户顶层提供；`1` 保持 SVT Serial 复位，`0` 释放 |
| `<name>_spd.vip_port_if.ser_if.reset` | 声明宏已经用连续赋值连接到 `reset_signal`，不要再额外驱动 |
| DUT PHY reference clock | 用户时钟环境提供；需满足 DUT PHY 的频率、稳定时间等要求 |
| DUT reset / PERST# | 用户复位环境按 DUT 真实接口、极性和上电时序控制；宏不会连接或释放它 |
| `link_en.enable=1` | 只使能对应 SVT 链路训练，不产生参考钟、不释放 SVT/DUT 复位 |

§2 的四个 SVT agent 共用 `reset`，并在示例时间 `200ns` 释放，**并不表示
DUT 的复位也已释放**。四个 RC 可以共用复位，也可以分别传入
`svt_rc0_reset` 到 `svt_rc3_reset`；选择应与用户的独立复位域一致。

若某条链确实要让 SVT 与 DUT 共用同一次 **fundamental reset**，且 DUT
使用低有效 `ep0_perst_n`，可以在顶层做极性转换：

```systemverilog
// 集成片段：替换 §2 原来的 svt_rc0 声明，不要追加第二个同名实例。
// ep0_perst_n 由用户已有复位控制器唯一驱动，且接到 DUT EP0 的 PERST#；
// 控制器负责上电时先拉低，再在参考钟/供电等满足 DUT 要求后释放。
wire svt_rc0_reset;
assign svt_rc0_reset = ~ep0_perst_n;

`PCIE_SVT_DECLARE_HDL_AGENT_X8(
  svt_rc0, "SVT_RC0.", 1'b0, 1'b0, svt_rc0_reset, 1, 0)
```

不要再对 `svt_rc0_reset` 或 `svt_rc0_spd.vip_port_if.ser_if.reset` 写
`initial`/`assign`，否则会形成重复驱动。其余 RC 可保留独立复位或按各自
PERST# 做相同映射；SVT 与 DUT 并非必须共用复位。Hot Reset、FLR 等协议/
功能级复位不等同于此 fundamental reset，不能都直接映射到 `ser_if.reset`。

执行 §6 的建链 sequence（包括 Tcl 启动）前，需按每条链确认：

1. SVT `ser_if.reset` 已明确为 `0`，不是 `X/Z`；
2. DUT reference clock 已稳定，DUT 相关复位已按设计要求释放，PHY 已 ready；
3. DUT LTSSM 的相关控制允许训练，再执行 SVT `link_en.enable=1`；
4. 对 `link_up && LTSSM=L0` 做有界等待，超时报告具体 link ID 和状态。

`#200ns` 和 §6 的 `#10us` 都只是示例延时，不是 PCIe/DUT 通用上电要求，也
不能替代 ready 条件检查。真实项目应使用自身 clock/reset/PHY-ready 接口
完成有超时的前置等待；不要靠不断放大固定延时掩盖未释放的复位。

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

### 3.1 真实 DUT + Serial 的 `pcie-work` filelist 顺序

真实 DUT 接入时要区分 VCS 外层输入顺序和用户 top 内的 include 顺序。推荐的
外层顺序如下；`pcie_tl_svt_adapter.f` 是 source-only 基础，不要把 DUT/test
放到它之前：

```text
1. 用户环境变量（DESIGNWARE_HOME、PCIE_SVT_ROOT、HOST_MEM_ROOT）
2. 用户 prefix（只定义可选的 SVC_RANDOM_SEED_SCOPE 等宏，不 include package）
3. -f svt_pcie_integration/sim/pcie_tl_svt_adapter.f
4. 用户 DUT top（包含 SVT Serial interface/adapter/header，并实例化 DUT）
5. 用户 UVM test
```

列表第 3 项内部的关键编译顺序是：

```text
pcie_tl_vip 基础 package/source
  -> pcie_svt_vip_bootstrap.sv
       -> svt_pcie.uvm.pkg
            -> svt_pciesvc_source.svi
                 -> pciesvc_global_shadow.svp
                 -> pcie_device_agent_svt/sverilog/src/vcs/
                    svt_pcie_single_port_device_agent_hdl.svp
  -> pcie_svt_adapter_pkg.sv
```

bootstrap 依赖 `+define+DESIGNWARE_INCDIR=$DESIGNWARE_HOME` 和
`+define+SVT_LOADER_UTIL_ENABLE_DWHOME_INCDIRS`，通过官方 source-map 直接
加载 R-2020.12 的 `.svp` 模型。因此截图中的 `Cannot find cell in liblist`
不能靠 `+incdir+$PCIE_SVT_ROOT/sverilog/include` 单独解决；如果外层流程绕过
bootstrap，才需要同时显式加入：

```text
+libext+.v+.sv+.vp+.svp
-y $PCIE_SVT_ROOT/verilog/src/vcs
-y $PCIE_SVT_ROOT/sverilog/src/vcs
-y $PCIE_SVT_ROOT/pcie_device_agent_svt/sverilog/src/vcs
```

用户 top 内的 Serial include 顺序也必须固定。`pcie_svt_serial_port_if.sv`
定义端口类型，`pcie_svt_serial_adapter.sv` 定义 `PCIE_SVT_MAP_SERDES_X4/X8/X16`
映射宏，最后才 include `pcie_svt_hdl_agent_macros.svh` 并调用
`PCIE_SVT_DECLARE_HDL_AGENT_X4/X8/X16`：

```systemverilog
`include "import_pcie_svt_uvm_pkgs.svi" // package 已由 bootstrap 编译
`include `SVC_SOURCE_MAP_SUITE_UTIL_V(pcie_svc,PCIE,latest,svc_util_parms)
`include `SVC_SOURCE_MAP_SUITE_MODEL_MODULE(pcie_svc,Include,latest,pciesvc_parms)
`include "pcie_svt_serial_port_if.sv"
`include "pcie_svt_serial_adapter.sv"
`include "pcie_svt_hdl_agent_macros.svh"
```

其中 `import_pcie_svt_uvm_pkgs.svi` 是 SVT 安装提供的导入 helper，不是本仓库
生成的文件；请通过 `$PCIE_SVT_ROOT/sverilog/include`（或内网安装的实际
include 目录）查找，无需复制到 DUT 工程。

当前仓库 Serial 声明宏的参数是 `SVT_PCIE_UI_PCIE_SPEC_VER_5_0`，因此使用
未修改的 `pcie_svt_hdl_agent_macros.svh` 时，外层 filelist 还应开启：

```text
+define+SVT_PCIE_ENABLE_GEN5
+define+SVT_PCIE_ENABLE_SERDES_ARCH
```

如果用户已经把 Serial 声明宏改成 PCIe 4.0 参数，则改用
`+define+SVT_PCIE_ENABLE_GEN4`，不要同时定义 `SVT_PCIE_ENABLE_PIPE5`；PIPE5
只属于 PIPE 物理层。`EXPERTIO_PCIESVC_INCLUDE_8G/16G` 已由
`pcie_tl_svt_adapter.f` 提供，`SVT_PCIE_ENABLE_10_BIT_TAGS` 也由该列表提供。

不要在用户 top 再次 include `svt_pcie.uvm.pkg`；否则会与 bootstrap 造成
package 重复定义。只有外层已经独立编译官方 package 时，才定义
`PCIE_SVT_PKG_EXTERNAL`，并把那次 package 编译放在 adapter filelist 之前。

```sh
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT=$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12
export HOST_MEM_ROOT=/path/to/host_mem
cd /path/to/pcie_work/svt_pcie_integration/sim
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+SVT_PCIE_ENABLE_GEN5 \
  +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_SVT_ENV_MAX_NUM_LINKS=4 \
  /path/to/user/user_svt_pkg_prefix.sv \
  -f pcie_tl_svt_adapter.f \
  /path/to/user/my_4rc_dut_top.sv /path/to/user/my_4rc_test.sv
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
    // 以下两个开关默认均为 0；只对 Gen4 链路生效。
    svt_backend_cfg.direct_gen4_enable         = 1'b0; // Gen1 直达 Gen4
    svt_backend_cfg.fast_link_training         = 1'b0; // 旧兼容别名，不必与 direct 同开
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

#### Gen4 快速建链开关

`pcie_svt_backend_cfg` 保留两个配置名以兼容已有用例，但它们控制的是同一
Gen4 直达行为，不是必须同时开启的两项能力。新配置优先使用显式命名：

```systemverilog
svt_backend_cfg.direct_gen4_enable = 1'b1;
svt_backend_cfg.fast_link_training = 1'b0; // 保持默认；旧用例设 1 仍有效
```

两者按 OR 合成直达请求，与显式 `eq_mode=1/2/3` 独立；保留 EQ 总开关
关闭时清零直达的旧行为：

```text
effective_direct_speedup = (effective_max_gen == 4) && effective_enable_eq &&
                           (direct_gen4_enable || effective_fast_link_training)
```

其中 `direct_gen4_enable` 是全局显式开关，`fast_link_training` 也是全局开关，
但可以通过 `pcie_svt_link_override_cfg.has_fast_link_training` 对单条链路覆盖。
fast=0 不能否定全局 direct=1，且 fast 没有额外缩短 LTSSM 定时器的功能。
默认值均为 `0` 且默认 mode=0，因此保留普通训练策略。只有在
`enable_equalization=1` 时，backend 才会把该结果传给 SVT 的
`enable_direct_speed_up_from_2_5g_to_16g`；如果设置 `enable_equalization=0`，
backend 会强制清零该 SVT 参数。

Gen4 的 EQ 策略必须区分：

| 配置（enable_equalization=1） | 训练策略 |
|---|---|
| `eq_mode=0/1` | 保留 Full-EQ，是否直达由上述旧开关请求决定 |
| `eq_mode=2` | 部分 EQ：只做 Phase 0/1，跳过 Phase 2/3；不改变直达开关 |
| `eq_mode=3` | No-EQ，是否直达仍由 direct/fast 请求决定 |

R-2020.12 下，Gen4 No-EQ 必须把 `set_link_eq_attribute_values()` 的第三参
设为 0；仅修改第一参枚举不生效。新版 backend 已补齐该映射。旧版
`enable_equalization=1, eq_mode=3` 第三参仍为 3，需要更新代码并重新编译。
部分 EQ 则把第三参设为 `1`。第三参 `0` 是不进入 EQ，不是“只做 Phase 0”。

例如，DUT 只做 Phase 0/1，并保持 Gen1→Gen3→Gen4 路径：

```systemverilog
svt_backend_cfg.enable_equalization = 1'b1;
svt_backend_cfg.eq_mode             = 2;    // Partial，不是速率 Bypass
svt_backend_cfg.direct_gen4_enable  = 1'b0;
svt_backend_cfg.fast_link_training  = 1'b0;
```

需要直达时另设 `direct_gen4_enable=1`；这不会把 Partial 改成 Full。
若沿用旧版 `eq_mode=2` 的“直达 Gen4 且执行完整 EQ”，应改为
`eq_mode=1, direct_gen4_enable=1`。该模式语义有意调整，升级时需要检查旧用例。

例如，Gen4 No-EQ 但仍使用 Gen1→Gen4 直达：

```systemverilog
svt_backend_cfg.enable_equalization = 1'b1;
svt_backend_cfg.eq_mode             = 3;    // NO_EQUALIZATION_NEEDED
svt_backend_cfg.direct_gen4_enable  = 1'b1;
```

Gen5 不使用这两个字段作为 `2.5→32 GT/s` 的 direct API；即使打开
`fast_link_training`，`effective_direct_speedup` 对 Gen5 仍为 0。Gen5 的
Gen1→Gen5 最高速率路径仍由 `eq_mode=0` 的旧自动策略
（`EQ_BYPASS_TO_HIGHEST_RATE`）控制，这不是 No-EQ。显式 `eq_mode=2` 在
Gen5 也统一表示仅 Phase 0/1，使用 FULL 枚举与 phase=1，不再表示速率
Bypass；旧 Gen5 `eq_mode=2` 的最高速率 Bypass 用例可改用 `eq_mode=0`。

#### DUT 侧前置条件

`fast_link_training` 只修改 SVT 发送端的训练策略，不能替 DUT 打开快速速率
切换能力。使用真实 DUT 时，DUT 的 PCIe LTSSM/PHY 控制器至少需要支持：

- 从 Gen1 直接接受并执行 Gen4 的速率切换，而不是只等待 Gen2/Gen3 中间阶段；
- 识别速率切换期间的 EIOS/EIEOS/FTS，并完成新的 TX UI、RX CDR/PLL 锁定；
- Gen4 下的 EQ 策略与 SVT 一致：`eq_mode=1` 要求完整 EQ，`2` 要求双方
  使用仅 Phase 0/1 的部分 EQ，`3` 则要求 DUT 确实支持 No-EQ；
- 速率切换后重新接收 TS1/TS2，并使 LTSSM 正常进入 `Recovery.RcvrCfg`、
  `Recovery.Idle` 和 `L0`。

通常这些能力配置在 DUT 的 PCIe PHY/PCS 控制器或 LTSSM 配置寄存器/仿真参数
中，例如 Gen4 capability、direct-rate-change/fast-training 使能、EQ 模式和
PLL/CDR 速率选择；具体字段取决于 DUT 厂商和 RTL 实现。它不是
`disable_ext_bit_clock_mode`，也不是 100 MHz reference clock 的配置。

如果 DUT 不支持这种非标准的 Gen1→Gen4 直达，常见结果是停在
`Recovery.Speed`、等待 Gen3 相关训练、PLL/CDR 失锁，或者重新回到 Detect。
此时应将 `direct_gen4_enable` 和 `fast_link_training` 都设为 `0`；按 DUT
能力选完整 EQ 的 `0/1`、部分 EQ 的 `2` 或 No-EQ 的 `3`，先使用
标准的 Gen1→Gen3→Gen4 路径验证 DUT；不要通过放宽时钟容差掩盖该能力不匹配。

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
ov.has_fast_link_training = 1'b1;
ov.fast_link_training = 1'b0;                   // 关闭该链的旧 fast 请求，非全局 direct
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
训练由 test 在 `run_phase` 显式启动。先满足 §2.3 的每链复位/PHY ready
条件；`link_en` 不会代替这些前置操作：

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

  // 仅为示例初始化裕量；真实 DUT 必须先完成 §2.3 的有超时 ready 检查。
  #10us;

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
            en.start(svt_be.svt_agent_by_link[id].virt_seqr.pcie_virt_seqr.dl_seqr);

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

### 6.1 用 AIP Tcl 按顺序启动建链和 EP 配置

推荐使用已提供的[可选通用 sequence](pcie_svt_aip_sequences.md)：包含
`pcie_svt_aip_seqs.sv`，由用户注册命令并绑定真实 DL/TL sequencer，库内严格
解析参数。该接口不接受 `host/rc`；用不同命令名绑定不同目标即可。本节保留
手工 wrapper 展示原理，其参数格式/能力与新库不同，不要混用。

如果希望“一次编译、多个 Tcl 用例”，可以在同一个 test 上接入
`aip-architecture-restructure` 分支的 AIP Tcl bridge。AIP 不替用户猜测
SVT 的 `enable`、link ID 或 BDF；这些动作放在用户定义的 zero-adaptation
sequence 中，Tcl 只负责调度命令。当前使用的 AIP 接口是
`` `aip_cmd_user_seq(cmd_name, seq_type, sequencer) ``，对应提交
`f635185`（远程分支 `feat/aip-architecture-restructure`）。

#### 6.1.1 编译和 Env 绑定

先把 AIP checkout 到本机并准备 Tcl 发布库（若使用发布包可跳过 `dist` 构建）：

```sh
git clone https://github.com/Beihang-yuting/aip_core.git
cd aip_core
git checkout feat/aip-architecture-restructure
make -C dist all
export AIP_CORE=$PWD
```

用户 command/test compilation unit 内必须先 include AIP 统一入口；但该源文件
本身要放在 `pcie_tl_svt_adapter.f` 之后，因为下面的 wrapper 会 import
`pcie_tl_pkg`/`pcie_svt_adapter_pkg`。不要先单独 include `aip_cmd.sv` 或
`aip_tcl_bridge.sv`。下面的静态 command sequencer 只作为 AIP sequence 的
启动锚点，不承载 PCIe item；真正的 item 仍分别发到 SVT DL sequencer 或 TL RC
sequencer。

```systemverilog
`include "aip_core_pkg.sv"
import aip_core_pkg::*;
import pcie_tl_pkg::*;
import pcie_svt_adapter_pkg::*;

class pcie_aip_cmd_sqr extends uvm_sequencer;
  `uvm_component_utils(pcie_aip_cmd_sqr)
  static uvm_sequencer_base       cmd_sqr;
  static pcie_svt_backend         svt_be;
  static pcie_tl_virtual_sequencer tl_vseqr;

  function new(string name = "pcie_aip_cmd_sqr", uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass
```

`svt_link_up` sequence 通过命令句柄读取 `link=`，自己创建官方
`svt_pcie_dl_service_set_link_en_sequence`，并明确设置 `enable=1`。下面的
配置命令示例同时覆盖 Config Write/Read；`reg` 是 DWORD 编号（例如 `reg=0`
对应 byte offset `0x000`），不是字节地址。

```systemverilog
class pcie_aip_link_up_seq extends uvm_sequence;
  `uvm_object_utils(pcie_aip_link_up_seq)
  function new(string name = "pcie_aip_link_up_seq"); super.new(name); endfunction

  task body();
    aip_cmd h;
    string args, link_id;
    svt_pcie_dl_service_set_link_en_sequence link_en;
    svt_pcie_device_status st;

    h = aip_cmd::get_handle("svt_link_up");
    args = (h == null) ? "" : h.args_in;
    link_id = aip_cmd::get_arg(args, "link");
    if ((h == null) || (pcie_aip_cmd_sqr::svt_be == null) ||
        !pcie_aip_cmd_sqr::svt_be.svt_agent_by_link.exists(link_id)) begin
      if (h != null) begin
        h.status = 1;
        h.result_out = $sformatf("ERROR: unknown SVT link %s", link_id);
      end
      return;
    end

    link_en = svt_pcie_dl_service_set_link_en_sequence::type_id::create(
      {"link_en_", link_id});
    link_en.enable = 1'b1; // 该字段必须由用户 sequence 设置
    link_en.start(pcie_aip_cmd_sqr::svt_be.svt_agent_by_link[link_id]
                  .virt_seqr.pcie_virt_seqr.dl_seqr);

    st = pcie_aip_cmd_sqr::svt_be.svt_status_by_link[link_id];
    wait (st.pcie_status.pl_status.link_up == 1'b1);
    wait (st.pcie_status.pl_status.ltssm_state == svt_pcie_types::L0);
    h.status = 0;
    h.result_out = $sformatf("OK: %s L0", link_id);
  endtask
endclass

class pcie_aip_ep_cfg_seq extends uvm_sequence;
  `uvm_object_utils(pcie_aip_ep_cfg_seq)
  function new(string name = "pcie_aip_ep_cfg_seq"); super.new(name); endfunction

  task body();
    aip_cmd h;
    string args, op;
    int rc_index, reg_num, data;
    bit [15:0] bdf;
    uvm_sequencer_base rc_sqr;

    h = aip_cmd::get_handle("ep_cfg");
    args = (h == null) ? "" : h.args_in;
    op = aip_cmd::get_arg(args, "op");
    rc_index = aip_cmd::parse_int_arg(aip_cmd::get_arg(args, "rc"), 0);
    reg_num = aip_cmd::parse_int_arg(aip_cmd::get_arg(args, "reg"), 0);
    data = aip_cmd::parse_int_arg(aip_cmd::get_arg(args, "data"), 0);
    bdf = aip_cmd::parse_int_arg(aip_cmd::get_arg(args, "bdf"), 0);

    if ((h == null) || (pcie_aip_cmd_sqr::tl_vseqr == null) ||
        (rc_index < 0) ||
        (rc_index >= pcie_aip_cmd_sqr::tl_vseqr.rc_seqr_arr.size())) begin
      if (h != null) begin h.status = 1; h.result_out = "ERROR: bad RC index"; end
      return;
    end
    rc_sqr = pcie_aip_cmd_sqr::tl_vseqr.rc_seqr_arr[rc_index];

    if (op == "wr") begin
      pcie_tl_cfg_wr_seq wr = pcie_tl_cfg_wr_seq::type_id::create("ep_cfg_wr");
      wr.target_bdf = bdf; wr.reg_num = reg_num; wr.wr_data = data;
      wr.first_be = 4'hf; wr.is_type1 = 1'b0;
      wr.start(rc_sqr);
      h.status = (wr.status == PCIE_RW_OK) ? 0 : 1;
      h.result_out = (h.status == 0) ?
        $sformatf("OK: cfg wr bdf=%04h reg=%0d data=%08h", bdf, reg_num, data) :
        $sformatf("ERROR: cfg wr status=%0d", wr.status);
    end else if (op == "rd") begin
      pcie_tl_cfg_rd_seq rd = pcie_tl_cfg_rd_seq::type_id::create("ep_cfg_rd");
      rd.target_bdf = bdf; rd.reg_num = reg_num;
      rd.first_be = 4'hf; rd.is_type1 = 1'b0;
      rd.start(rc_sqr);
      h.status = (rd.status == PCIE_RW_OK) ? 0 : 1;
      h.result_out = (h.status == 0) ?
        $sformatf("OK: cfg rd bdf=%04h reg=%0d data=%08h", bdf, reg_num, rd.rd_data) :
        $sformatf("ERROR: cfg rd status=%0d", rd.status);
    end else begin
      h.status = 1;
      h.result_out = $sformatf("ERROR: ep_cfg op must be wr or rd, got %s", op);
    end
  endtask
endclass

`aip_cmd_user_seq(svt_link_up, pcie_aip_link_up_seq, pcie_aip_cmd_sqr::cmd_sqr)
`aip_cmd_user_seq(ep_cfg,      pcie_aip_ep_cfg_seq,   pcie_aip_cmd_sqr::cmd_sqr)
```

在 `build_phase/connect_phase` 创建静态锚点并绑定 backend/TL virtual sequencer，
再由 `run_phase` 把 objection 生命周期交给 AIP：

```systemverilog
pcie_aip_cmd_sqr aip_sqr;

function void build_phase(uvm_phase phase);
  super.build_phase(phase);
  // ...按 §4 创建 tl_env...
  aip_sqr = pcie_aip_cmd_sqr::type_id::create("aip_sqr", this);
endfunction

function void connect_phase(uvm_phase phase);
  super.connect_phase(phase);
  if (!$cast(pcie_aip_cmd_sqr::svt_be, tl_env.backend_provider))
    `uvm_fatal("AIP", "backend provider 不是 pcie_svt_backend")
  pcie_aip_cmd_sqr::tl_vseqr = tl_env.v_seqr;
  pcie_aip_cmd_sqr::cmd_sqr = aip_sqr;
endfunction

task run_phase(uvm_phase phase);
  phase.raise_objection(this);
  aip_tcl_bridge::run_loop(); // Tcl 的 end_test 返回后才释放 objection
  phase.drop_objection(this);
endtask
```

VCS 编译时把 AIP include 放在普通 include 路径中，并为 Tcl force/bridge
打开完整 debug access：

```sh
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  -timescale=1ns/1ps -debug_access+r+w+f \
  +incdir+$AIP_CORE +incdir+$AIP_CORE/src/sv \
  +define+SVT_PCIE_ENABLE_GEN5 \
  +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_SVT_ENV_MAX_NUM_LINKS=4 \
  /path/to/user_svt_pkg_prefix.sv \
  -f /path/to/pcie_work/svt_pcie_integration/sim/pcie_tl_svt_adapter.f \
  /path/to/my_4rc_dut_top.sv /path/to/my_4rc_dut_test.sv -o simv
```

#### 6.1.2 Tcl 调度顺序

`aip_cmd_user_seq` 不解释 `count/time`，命令参数原样留在
`aip_cmd::get_handle(...).args_in`。因此脚本必须先逐条建链，等每条 sequence
确认 L0 后再访问 DUT EP 的配置空间：

```tcl
source $env(AIP_CORE)/dist/aip_init_so.tcl

# 4 条物理链逐条执行；每条命令返回时已经 link_up && LTSSM=L0。
svt_link_up link=RC0_EP0
if {[aip_check_status] != 0} { error [aip_read_result] }
svt_link_up link=RC1_EP1
svt_link_up link=RC2_EP2
svt_link_up link=RC3_EP3

# L0 之后由 TL RC sequencer 访问真实 DUT EP 配置空间。
ep_cfg op=rd rc=0 bdf=0x0100 reg=0       ;# Vendor/Device ID
ep_cfg op=wr rc=0 bdf=0x0100 reg=1 data=0x00000007 ;# Command/Status 示例
ep_cfg op=rd rc=3 bdf=0x0300 reg=0

end_test drain=500
```

不要在 Tcl 中直接访问 `svt_agent_by_link` 或调用 SVT 私有 API；这些对象只能
由 SV sequence 通过 backend 的公开关联数组使用。需要四链并行时，应为每条链
注册独立 command name/sequence，使每个 AIP command 都有独立的 `args_in` 和
活动登记；同一个 `svt_link_up` 命令不要在 Tcl `fork` 中并发调用。AIP watchdog
只负责停滞 sequence 的清理，不会替用户补发 `link_en` 或自动跳过 L0 门禁。

#### 6.1.3 多 Host、多个参数与并发的边界

这里先区分底层 sequence 能力和上面示例实际解析的 Tcl 参数：向命令追加
`key=value` 不会自动给 sequence 同名字段赋值。`aip_cmd_user_seq` 只创建并
启动 sequence，必须由 wrapper 显式解析、检查范围并赋给子 sequence。

| 当前入口 | 同一条命令中生效的选择/数据 | 未实现或固定的部分 |
|---|---|---|
| `svt_link_up` 示例 | `link` 选择 backend 的物理链路 | 不解析 `host/rc`；`enable` 固定为 1 |
| `ep_cfg` 示例 | `op/rc/bdf/reg`；写操作另加 `data` | 不解析 `host/addr/be/type1/timeout_ns`；`first_be=0xf`、`is_type1=0` |
| `pcie_tl_rw_seq` 底层 SV 类 | 启动它的 RC sequencer，以及 `op/addr/byte_len/wdata/rb_timeout_ns` 等字段 | 本节尚未注册对应的通用 Tcl Memory 命令；不能直接在 Tcl 使用这些 SV 字段名 |

**Root 选择与 Host 身份不是同一个参数。** `rc=N` 在当前 wrapper 中选择
`tl_vseqr.rc_seqr_arr[N]`，决定请求从哪条 Root 路径发出；`bdf` 或 `addr`
再决定该路径内的目标。多 Host 可以通过各自 Root 分别访问，但不能默认
`host_id == rc`。例如 Root0、Root2 可以同属 Host0，Root1 属于 Host1。
`bind_host_memory(root_index, host_id, manager, why)` 维护的是 Host memory
绑定，不会替 Tcl 建立 `host=` 参数解析，也不应仅为 RC→EP 访问强制开启
`use_unified_mem`。

这里的 `rc` 严格说是 **`rc_seqr_arr` 下标**。本例四个 SVT RC 都存在，
数组连续，才可与 Root0..Root3 一一对应。环境构建该数组时会跳过空 agent；
混合 DUT/SVT 等稀疏 Root 场景不能把数组下标直接当成 canonical
`root_index`，应在绑定时明确记录 Host/Root/link 与真实 sequencer 的关系。
此外，上面静态 `tl_vseqr/svt_be` 只保存一套 env 句柄；若多个 Host 分布在
不同 `tl_env` 实例中，需要分别绑定 context，或增加明确的目标句柄表，
不能依次覆盖同一静态句柄后期待 `host=` 自动恢复原环境。

当前示例可顺序执行如下组合；每次都要检查结果。两条独立 Root 路径中的
EP 可以使用相同 BDF，不能只凭 BDF 猜测应该选择哪个 Host/Root：

```tcl
# 假设用户已确认 Host0 使用 rc=0，Host1 使用 rc=1，且两条链均已 L0。
ep_cfg op=rd rc=0 bdf=0x0100 reg=0
if {[aip_check_status] != 0} { error [aip_read_result] }
ep_cfg op=rd rc=1 bdf=0x0100 reg=0
if {[aip_check_status] != 0} { error [aip_read_result] }
```

地址也只在所选 Root 的地址域内解释，不能通过换地址绕过 Root 路由；
在同一域内访问不同 Function 则使用其真实 BDF/BAR 配置。PCIe Memory
sequence 产生总线事务，不等同于直接读写 testbench 的 Host memory manager。
用户若要提供 `host=` 别名，应显式绑定 Host→Root 映射；同一 Host 对应
多个 Root 时还必须指定 Root，不能静默选第一条。若同时提供 `host/rc/link`，
wrapper 应检查它们是否指向同一路径，而不是让其中一个参数悄悄失效。

“多个参数一起生效”也不等于“同名命令可并发”。AIP 当前按命令名共享
`args_in/status/result_out` 和活动 sequence 登记：顺序调用同一命令可以，
并行调用同名命令存在覆盖风险。若需要多 Host 并发，用户应注册不同命令名，
每次创建独立 sequence，并在执行前固定本次目标句柄和参数。本文旧 wrapper
用 `get_handle("ep_cfg")`/`get_handle("svt_link_up")` 写死了命令名；只改注册名
还不够。通用 wrapper 可用 `aip_cmd::get_handle(get_name())`，因为当前 AIP
注册宏以命令名创建 sequence；不要共享可变的“当前 Host/当前地址”静态字段。

用户仍决定注册哪些命令、注册名及外层 sequencer。注册宏的第三个参数只是
外层启动锚点，实际的 SVT DL/TL RC 子 sequencer 必须按绑定和选择参数获取；
不能仅通过更换锚点切换 Host，且直接发送 item 的 sequence 必须匹配类型。

将这些示例收敛成通用命令时，参数校验还必须覆盖以下事项：

- AIP 的 `parse_int_arg` 对非法值可能回退默认值；不能把拼错的 `rc` 或
  地址默认为 0 后继续访问。应拒绝未知参数、缺失字段、重复键和越界值。
- 内存地址必须按无符号 64 位解析，不能复用 32 位 `parse_int_arg`；
  `bdf` 为 16 位，`reg` 为 10 位 DWORD 编号，不能将字节 `offset` 直接赋给它。
- 当前 Config 示例的 BE 和 Type0 是固定值；只有显式增加解析和赋值后，
  `be/type1` 才可控。Switch 路径还需按实际总线拓扑选择配置请求类型。
- `pcie_tl_rw_seq.byte_len` 是字节数，底层 `mem_rd/wr_seq.length` 是
  DWORD 编码；地址、长度、BE、数据必须一起满足 4KB 边界及 MPS/MRRS。
  `rw_seq` 当前不自动拆分跨界/超长请求，不能把字段允许的 1..4096 字节
  当成所有链路下单个 TLP 都合法。当前底层 Memory TLP 的默认限制是
  MPS=256 字节、MRRS=512 字节，通用封装还需匹配实际链路配置。
  显式写数据应严格匹配请求字节数；现有 `rw_seq` 对短 `wdata` 补零、
  对长 `wdata` 截断，不能将这种宽松行为误认为参数长度已经验证。
- `requester_id/TC/attr` 等并非现有 Tcl wrapper 的可控参数；需要这些
  变量时必须明确扩展到实际发出的 TLP，不能仅追加同名命令行字段。
- Memory Write 是 posted，sequence 返回只表示本次发送流程完成；需要
  确认 DUT 存储结果时必须追加合适的回读/检查。建链和非 posted 访问应有
  有界超时，同时协调 AIP ack/watchdog 窗口，不能把旧结果当成本次成功。

以上描述的是本节手工 wrapper 的静态接口审计，不代表其所有参数均已开放。
新提供的[通用 sequence](pcie_svt_aip_sequences.md)采用另一项明确契约：
用户按命令名绑定实际 sequencer，参数中不再选择 Host/RC；完整解析、边界和
独立验证记录以该文档为准，双向双 SVT 验证也不等同于多 Host 拓扑验证。

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
- PHY reference clock 已接到 DUT 并稳定，SVT 的高有效 reset 已释放，DUT
  复位/PHY ready/LTSSM 控制满足 §2.3；本文的 Serial connector 不会替你
  提供 reference clock、释放 DUT 复位或提供 Passive Monitor bit clock；
- Serial HDL 宏已使用内部发送时钟默认值 `TRANSMIT_BIT_CLOCK_MODE=0`，
  更新宏后已重新编译；若保留外部模式，必须满足 §2.2 的时钟契约；
- 需要 EP→RC DMA 时才打开 `use_unified_mem`，并为 Root0~Root3 显式
  绑定 Host memory manager。

## 8. 常见错误

| 现象 | 原因 |
|---|---|
| build fatal "缺少 svt_pcie_vif" | `vif_key` 与 `update_if_variables` 发布的 key 不一致 |
| build fatal "runtime_num_links 超上限" | 未加 `+define+PCIE_SVT_ENV_MAX_NUM_LINKS=4` |
| 链路一直不进 L0 | 忘记启动 RC 侧 link_en，或 SVT reset 仍为 1，或 DUT 复位/参考钟/PHY ready/LTSSM 控制未满足 §2.3 |
| 已执行 link_en，但停在 INITIAL、SVT 差分数据无活动 | 检查是否仍在使用旧版 HDL 参数 `1`，且 cfg 默认 `0`、外部 bit clock 未提供；按 §2.2 更新并重新编译 |
| 只有一条链建起来 | `update_if_variables` 的数字 link_id 重复或与 hdl_slot 不对应 |
| host memory 校验失败 | 多 Root 下只绑了部分 Root 的 manager |
