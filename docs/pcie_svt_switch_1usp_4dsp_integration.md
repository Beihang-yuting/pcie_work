# DUT Switch（1×x16 USP + 4×x4 DSP）端到端集成说明

本文档给出一个可直接改名落地的完整示例：真实 DUT 是 PCIe Switch，
上行 USP 为 x16，下行 DSP0~DSP3 各为 x4；SVT 在 USP 侧模拟 RC，在每个
DSP 侧模拟 EP。DUT Switch 负责五条真实 SerDes 链路的物理转发，
`pcie_tl_env` 负责拓扑、配置空间、BAR 和业务流量，`pcie_svt_backend`
负责把 TL adapter 接到五个正式 SVT active Device Agent。

```text
                                  SVT RC0
                                    │ x16
                         RC0_SW0_USP0│ hdl_slot=0
                             ┌──────┴──────┐
                             │   DUT SW0   │
                             └─┬────┬────┬─┴─┐
                       x4      │    │    │   │
                 DSP0_EP0   DSP1_EP1 DSP2_EP2 DSP3_EP3
                 SVT EP0    SVT EP1  SVT EP2  SVT EP3
                 slot=1     slot=2   slot=3    slot=4
```

拓扑 builder 生成的稳定 link ID 是：

```text
RC0_SW0_USP0
SW0_DSP0_EP0
SW0_DSP1_EP1
SW0_DSP2_EP2
SW0_DSP3_EP3
```

对应 `docs/superpowers/specs/2026-09-06-svt-backend-configuration-design.md`
§8 的 Switch 行：自动创建 1 个 SVT RC 和 4 个 SVT EP，共 5 个 active
SVT agent。DUT 本身不创建 SVT/TL agent。

## 1. 角色、槽位与事务所有权

| 对象 | 数量 | 所有权/用途 |
|---|---:|---|
| 物理 SerDes 链路 | 5 | USP x16 一条，DSP x4 四条 |
| SVT RC agent | 1 | 连接 DUT USP，模拟上游 Root |
| SVT EP agent | 4 | 分别连接 DUT DSP0~DSP3，响应下行请求 |
| TL RC agent | 1 | `tl_env.v_seqr.rc_seqr_arr[0]` 发起配置和内存事务 |
| TL EP agent | 4 | 由 env 为四个 DSP 槽位创建，驱动 SVT EP 的响应路径 |
| DUT Switch | 1 | 只做真实物理链路转发，不由 VIP 模拟 |

`hdl_slot` 和 `vif_key` 是物理连接契约，不是 Host 编号。Switch 场景的
规范序号按端口号固定：`rc_agents[0]` 对应 USP0，`ep_agents[i]` 恒对应
DSPi；禁用某一条链路时保留其物理槽位，不把后面的 DSP 前移。

## 2. HDL 顶层与 SerDes 连接

### 2.1 五个 SVT HDL agent

下面的顶层只展示 SVT 侧和连接边界，`my_switch_dut` 的端口名必须替换为
用户 DUT 的真实声明。Serial 数据方向始终是 **SVT TX → DUT RX，DUT TX →
SVT RX**；不要按信号名把 `tx` 对 `tx`。

```systemverilog
`timescale 1ns/1fs
module my_switch_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "import_pcie_svt_uvm_pkgs.svi"
  `include `SVC_SOURCE_MAP_SUITE_UTIL_V(pcie_svc,PCIE,latest,svc_util_parms)
  `include `SVC_SOURCE_MAP_SUITE_MODEL_MODULE(pcie_svc,Include,latest,pciesvc_parms)
  // Serial DUT 边界必须先提供接口类型和 lane 映射宏，再声明 HDL agent。
  `include "pcie_svt_serial_port_if.sv"
  `include "pcie_svt_serial_adapter.sv"
  `include "pcie_svt_hdl_agent_macros.svh"

  bit reset = 1'b1;
  int unsigned global_random_seed = 0;

  // 只接真实 DUT + pcie_svt_backend 时不需要 global shadow。
  // 官方 example env/interconnect 若引用它，再实例化并定义对应宏。
  // pciesvc_global_shadow #(.DISPLAY_NAME("global_shadow0.")) global_shadow0();

  // 参数顺序：name, display_name, clkreq, wake, reset, is_root, hierarchy
  `PCIE_SVT_DECLARE_HDL_AGENT_X16(svt_rc0, "SVT_RC0.", 1'b0, 1'b0,
                                  reset, 1, 0)
  `PCIE_SVT_DECLARE_HDL_AGENT_X4 (svt_ep0, "SVT_EP0.", 1'b0, 1'b0,
                                  reset, 0, 1)
  `PCIE_SVT_DECLARE_HDL_AGENT_X4 (svt_ep1, "SVT_EP1.", 1'b0, 1'b0,
                                  reset, 0, 2)
  `PCIE_SVT_DECLARE_HDL_AGENT_X4 (svt_ep2, "SVT_EP2.", 1'b0, 1'b0,
                                  reset, 0, 3)
  `PCIE_SVT_DECLARE_HDL_AGENT_X4 (svt_ep3, "SVT_EP3.", 1'b0, 1'b0,
                                  reset, 0, 4)

  // 每个 Switch 物理端口使用独立的 Serial interface；不要把五个电气
  // 端口拼成一个向量。若 DUT 端口本来就是向量，下面的接口可直接接入。
  pcie_svt_serial_port_if #(16) usp_if();
  pcie_svt_serial_port_if #(4)  dsp0_if();
  pcie_svt_serial_port_if #(4)  dsp1_if();
  pcie_svt_serial_port_if #(4)  dsp2_if();
  pcie_svt_serial_port_if #(4)  dsp3_if();

  `PCIE_SVT_CONNECT_DUT_SERDES_X16(svt_rc0_serial, usp_if, 0)
  `PCIE_SVT_CONNECT_DUT_SERDES_X4 (svt_ep0_serial, dsp0_if, 0)
  `PCIE_SVT_CONNECT_DUT_SERDES_X4 (svt_ep1_serial, dsp1_if, 0)
  `PCIE_SVT_CONNECT_DUT_SERDES_X4 (svt_ep2_serial, dsp2_if, 0)
  `PCIE_SVT_CONNECT_DUT_SERDES_X4 (svt_ep3_serial, dsp3_if, 0)

  my_switch_dut u_dut (
    .usp_rx_p  (usp_if.rx_p),  .usp_rx_m  (usp_if.rx_n),
    .usp_tx_p  (usp_if.tx_p),  .usp_tx_m  (usp_if.tx_n),
    .dsp0_rx_p (dsp0_if.rx_p), .dsp0_rx_m (dsp0_if.rx_n),
    .dsp0_tx_p (dsp0_if.tx_p), .dsp0_tx_m (dsp0_if.tx_n),
    .dsp1_rx_p (dsp1_if.rx_p), .dsp1_rx_m (dsp1_if.rx_n),
    .dsp1_tx_p (dsp1_if.tx_p), .dsp1_tx_m (dsp1_if.tx_n),
    .dsp2_rx_p (dsp2_if.rx_p), .dsp2_rx_m (dsp2_if.rx_n),
    .dsp2_tx_p (dsp2_if.tx_p), .dsp2_tx_m (dsp2_if.tx_n),
    .dsp3_rx_p (dsp3_if.rx_p), .dsp3_rx_m (dsp3_if.rx_n),
    .dsp3_tx_p (dsp3_if.tx_p), .dsp3_tx_m (dsp3_if.tx_n)
  );

  // 第二个参数是数字 link_id；它必须与下面 global_cfg 的 hdl_slot 对齐。
  // RC 使用 port ID 4'h0，EP 使用 port ID 4'h1。
  initial begin
    svt_rc0_spd.update_if_variables(4'h0, 8'd0,
                                    "uvm_test_top", "uvm_test_top");
    svt_ep0_spd.update_if_variables(4'h1, 8'd1,
                                    "uvm_test_top", "uvm_test_top");
    svt_ep1_spd.update_if_variables(4'h1, 8'd2,
                                    "uvm_test_top", "uvm_test_top");
    svt_ep2_spd.update_if_variables(4'h1, 8'd3,
                                    "uvm_test_top", "uvm_test_top");
    svt_ep3_spd.update_if_variables(4'h1, 8'd4,
                                    "uvm_test_top", "uvm_test_top");
  end

  // PHY reference clock、复位、clkreq/wake 属于 DUT 顶层职责。
  initial begin #200ns; reset = 1'b0; end
  initial run_test("my_switch_test");
endmodule
```

`clkreq` 和 `wake` 传入 `1'b0` 只表示本例不建模 sideband；它们不是
SerDes bit clock。若 DUT 有真实管脚，应把常量替换为顶层信号并按 DUT
极性连接。

### 2.2 标量差分 pad 和 x4/x8/x16 切片

`PCIE_SVT_BIND_PAD16_SCALAR` 与三个 `PCIE_SVT_CONNECT_DUT_SERDES_Xn`
宏都定义在
[`pcie_svt_hdl_agent_macros.svh`](../svt_pcie_integration/rtl/pcie_svt_hdl_agent_macros.svh)。
绑定宏把 `pad_prefix_phy_rx0..15_p/m`（DUT 输入）和
`pad_prefix_phy_tx0..15_p/m`（DUT 输出）转换成一个 16-lane 向量视图：

```systemverilog
pcie_svt_serial_port_if #(16) usp_pad_if();
`PCIE_SVT_BIND_PAD16_SCALAR(usp_pad_if, usp)
`PCIE_SVT_CONNECT_DUT_SERDES_X16(svt_rc0_serial, usp_pad_if, 0)
```

如果四个 DSP 各自有 16 个 scalar lane，可对每个端口各绑定一次，再取
x4 切片：

```systemverilog
pcie_svt_serial_port_if #(16) dsp0_pad_if();
`PCIE_SVT_BIND_PAD16_SCALAR(dsp0_pad_if, dsp0)
`PCIE_SVT_CONNECT_DUT_SERDES_X4(svt_ep0_serial, dsp0_pad_if, 0)
```

若一个 16-lane pad 组承载两个 x8 链路，也可以使用 `base_lane=0` 和
`base_lane=8`；x4/x8/x16 不能重叠占用同一组物理 lane。若 DUT 只有四个
scalar pad 而不是 16-lane 命名组，应在用户顶层先手工打包成
`pcie_svt_serial_port_if #(4)`，或写一个等价的 4-lane binder；不要把不
相邻的物理端口错误地拼在一个 16-lane pad 组中。

展开后的方向可用下面的等式核对：

```text
svt_port.rx_p/rx_n = SVT tx_datap/tx_datan = DUT RX 输入
svt_port.tx_p/tx_n = DUT TX 输出          = SVT rx_datap/rx_datan
```

### 2.3 Reference clock、bit clock 与 Passive Monitor

SerDes 数据连接宏只连接 `rx_p/rx_n` 和 `tx_p/tx_n`，不产生 DUT PHY
reference clock，也不自动创建 Passive Monitor。

对启用 transmit-bit-clock mode 的 active SVT Serial 端口，`tx_clk` 和
`rx_clk` 是送入 SVT PHY interface 的时钟输入，按对端方向连接：

| 信号 | 来源/用途 |
|---|---|
| `svt_port.rx_clk` | DUT TX transmit bit clock |
| `svt_port.tx_clk` | DUT RX recovered bit clock |
| `svt_port.active_tx_transmit_clk` | SVT active PHY 输出，供观察器使用 |
| `svt_port.active_rx_recovered_clk` | SVT active PHY 输出，供观察器使用 |
| DUT PHY reference clock | 只接 DUT PHY，由用户顶层负责 |

`active_rx_recovered_clk` 不是 DUT 的 reference clock，也不需要回接到
DUT。若 DUT 只提供 reference clock 而不提供上述 bit clock，请先按所用
SVT Serial PHY interface 的时钟契约选择 clock-recovery 方案；不能把
reference clock 随意同时接到 `tx_clk`/`rx_clk`。

SVT 侧的 Passive Monitor 是旁路观察器：它只采样 Serial symbol、解码
链路活动并向 analysis port 发布结果，不驱动 TX/RX、不启动 link training、
也不替 DUT 产生时钟。当前端到端示例只需要五个 active SVT agent，因而
不额外实例化 Passive Monitor。若要观察 DUT 波形，应单独创建
`is_active=UVM_PASSIVE`、`enable_monitor=1` 的 SVT agent，并显式提供：

```text
DUT TX transmit bit clock   -> passive_port.rx_clk
DUT RX recovered bit clock  -> passive_port.tx_clk
```

`pcie_svt_backend_cfg.enable_svt_monitor=1` 不会把 active backend 变成
passive agent；backend 会给出 warning，纯观察器必须由用户单独实例化。

## 3. 编译、bootstrap 与宏

`pcie_tl_svt_adapter.f` 是 source-only filelist，包含 TL env、SVT adapter
和 `pcie_svt_vip_bootstrap.sv`。bootstrap 会在 adapter package 前 include
官方 `svt_pcie.uvm.pkg`；因此用户 prefix 只定义需要的宏，不要再次 include
官方 package。

```systemverilog
// user_svt_pkg_prefix.sv
`define SVC_RANDOM_SEED_SCOPE my_switch_top.global_random_seed
// 只有官方 example env 使用 global shadow 时才需要：
// `define EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH my_switch_top.global_shadow0
```

真实 Switch 工程的 VCS 输入顺序应保持为 prefix → source-only filelist →
DUT top → test：

```sh
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  +define+PCIE_TOPO_SWITCH_1X16_4X4 \
  +define+PCIE_SVT_ENV_MAX_NUM_LINKS=5 \
  user_svt_pkg_prefix.sv \
  -f svt_pcie_integration/sim/pcie_tl_svt_adapter.f \
  my_switch_top.sv my_switch_test.sv
```

必须显式给 `PCIE_SVT_ENV_MAX_NUM_LINKS=5`：source-only filelist 为兼容
其它入口带有 `PCIE_TOPO_EP_X16`，不能只依赖 Switch 拓扑宏推导五个静态
slot。若外层流程已经编译官方 package，再增加
`+define+PCIE_SVT_PKG_EXTERNAL`，并保证 package 只编译一次。

### 3.1 真实 Switch DUT + Serial 的 `pcie-work` filelist 顺序

VCS 的外层输入顺序和用户 top 内的 include 顺序都必须固定。外层 filelist
按下面顺序组织；`pcie_tl_svt_adapter.f` 是 source-only 基础，不能把 Switch
DUT 或 test 放在它前面：

```text
1. 用户环境变量（DESIGNWARE_HOME、PCIE_SVT_ROOT、HOST_MEM_ROOT）
2. 用户 prefix（只定义可选的 SVC_RANDOM_SEED_SCOPE 等宏，不 include package）
3. -f svt_pcie_integration/sim/pcie_tl_svt_adapter.f
4. 用户 Switch DUT top（包含 Serial interface/adapter/header，并连接 USP/DSP）
5. 用户 UVM test
```

source-only adapter filelist 内部的关键关系为：

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

bootstrap 由 `+define+DESIGNWARE_INCDIR=$DESIGNWARE_HOME` 和
`+define+SVT_LOADER_UTIL_ENABLE_DWHOME_INCDIRS` 启用官方 source-map，直接
加载 R-2020.12 的加密 `.svp` 模型。`+incdir+$PCIE_SVT_ROOT/sverilog/include`
本身不会把这两个 HDL cell 放进 `work`。只有绕过 bootstrap 的外层流程才需要
额外显式加入：

```text
+libext+.v+.sv+.vp+.svp
-y $PCIE_SVT_ROOT/verilog/src/vcs
-y $PCIE_SVT_ROOT/sverilog/src/vcs
-y $PCIE_SVT_ROOT/pcie_device_agent_svt/sverilog/src/vcs
```

用户 Switch top 内的 Serial include 顺序如下：

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

其中 `pcie_svt_serial_port_if.sv` 定义 Serial 端口类型，
`pcie_svt_serial_adapter.sv` 定义 `PCIE_SVT_MAP_SERDES_X4/X8/X16`，最后的
`pcie_svt_hdl_agent_macros.svh` 才能展开五个 HDL agent。不要在 Switch top
再次 include `svt_pcie.uvm.pkg`，否则会与 bootstrap 重复定义 package。

当前仓库 Serial 声明宏使用 `SVT_PCIE_UI_PCIE_SPEC_VER_5_0`，因此未修改宏
时需要在 Switch 外层 filelist 开启：

```text
+define+SVT_PCIE_ENABLE_GEN5
+define+SVT_PCIE_ENABLE_SERDES_ARCH
```

若用户把 Serial 声明宏改为 PCIe 4.0 参数，则改用
`+define+SVT_PCIE_ENABLE_GEN4`；Serial 场景不要无条件添加
`SVT_PCIE_ENABLE_PIPE5`。`EXPERTIO_PCIESVC_INCLUDE_8G/16G` 和
`SVT_PCIE_ENABLE_10_BIT_TAGS` 已在 `pcie_tl_svt_adapter.f` 中提供。

可直接复制的命令如下：

```sh
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT=$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12
export HOST_MEM_ROOT=/path/to/host_mem
cd /path/to/pcie_work/svt_pcie_integration/sim
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+SVT_PCIE_ENABLE_GEN5 \
  +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_SWITCH_1X16_4X4 \
  +define+PCIE_SVT_ENV_MAX_NUM_LINKS=5 \
  /path/to/user/user_svt_pkg_prefix.sv \
  -f pcie_tl_svt_adapter.f \
  /path/to/user/my_switch_top.sv /path/to/user/my_switch_test.sv
```

| 宏 | 用途 | 本示例 |
|---|---|---|
| `PCIE_TOPO_SWITCH_1X16_4X4` | 标记 Switch 拓扑 profile | 定义 |
| `PCIE_SVT_ENV_MAX_NUM_LINKS` | 静态 HDL slot/runtime link 上限 | `5` |
| `SVC_RANDOM_SEED_SCOPE` | 把 SVT 随机种子锚定到用户变量 | 可选 |
| `EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH` | 官方 global shadow 层次路径 | 仅官方 example env 必需 |

## 4. UVM env、global policy 与 backend 配置

拓扑路径的配置优先级是：`global_cfg.topology` → TL topology translation
→ `tl_policy_cfg` → backend provider。**当存在 topology 时，必须把
`pcie_tl_env_config` 发布到 `tl_policy_cfg`；`cfg` 是无 topology 的旧路径，
不能只发布 `cfg`。**

下面的 class 骨架包含五条链所需的完整 build 配置。`pcie_tl_env` 会按
provider 返回的 adapter 数量创建 1 个 TL RC agent、4 个 TL EP agent 和
一个 1-USP/4-DSP 的 TL switch；用户不需要手工创建 SVT agent/config/status。

```systemverilog
import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
import pcie_svt_adapter_pkg::*;
`include "uvm_macros.svh"

class my_switch_test extends uvm_test;
  `uvm_component_utils(my_switch_test)

  pcie_global_cfg          global_cfg;
  pcie_tl_env_config       tl_cfg;
  pcie_svt_backend_cfg     svt_backend_cfg;
  pcie_svt_backend_factory backend_factory;
  pcie_tl_env              tl_env;

  extern task run_phase(uvm_phase phase);
  extern task run_enum_and_traffic();
  extern function void check_switch_contract();
  extern function void end_of_elaboration_phase(uvm_phase phase);

  function new(string name = "my_switch_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_global_policy();
    pcie_topology_cfg topology;

    topology = pcie_topology_builder::build_switch_1x16_4x4(4);
    global_cfg = pcie_global_cfg::type_id::create("global_cfg");
    global_cfg.build_default_for_topology(topology);
    global_cfg.backend           = PCIE_BACKEND_SVT_REAL_DUT;
    global_cfg.svt_bridge_enable = 1'b1;
    global_cfg.runtime_num_links = 5;

    foreach (global_cfg.links[i]) begin
      pcie_link_cfg link = global_cfg.links[i];
      bit is_usp = (link.link_id == "RC0_SW0_USP0");
      int slot = is_usp ? 0 : (link.upstream_port_index + 1);

      link.enabled        = 1'b1;
      link.use_svt        = 1'b1;
      link.svt_role_valid = 1'b1;
      link.svt_role       = is_usp ? PCIE_DEVICE_RC : PCIE_DEVICE_EP;
      link.svt_node_id    = is_usp ? link.upstream_node_id
                                   : link.downstream_node_id;
      link.has_hdl_slot   = 1'b1;
      link.hdl_slot       = slot;
      link.vif_key        = is_usp ?
        $sformatf("link_%0d_vif_0", slot) :
        $sformatf("link_%0d_vif_1", slot);
    end
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    build_global_policy();

    svt_backend_cfg = pcie_svt_backend_cfg::type_id::create(
      "svt_backend_cfg");
    svt_backend_cfg.init_defaults();
    svt_backend_cfg.transport                = PCIE_SVT_TRANSPORT_SERIAL;
    svt_backend_cfg.backend_mode             = PCIE_SVT_BACKEND_FULL_VIP;
    svt_backend_cfg.default_max_gen          = 4;
    svt_backend_cfg.enable_equalization      = 1'b1;
    svt_backend_cfg.eq_mode                  = 0; // 按 Gen 自动选择 EQ
    svt_backend_cfg.enable_shadow_cfg_lookup = 1'b0;
    svt_backend_cfg.enable_svt_monitor       = 1'b0;
    // FULL_VIP 内建 Target App 不响应；EP TL driver 统一负责 Completion。
    svt_backend_cfg.target_app_enable        = 1'b1;
    svt_backend_cfg.target_auto_response     = 1'b0;

    backend_factory = pcie_svt_backend_factory::type_id::create(
      "svt_backend_factory");

    tl_cfg = pcie_tl_env_config::type_id::create("tl_policy_cfg");
    tl_cfg.if_mode          = SV_IF_MODE;
    tl_cfg.rc_agent_enable  = 1'b1;  // provider build 后仍为 1
    tl_cfg.ep_agent_enable  = 1'b1;  // provider build 后仍为 1
    tl_cfg.num_rc           = 1;     // topology translation 会确认 USP 数量
    tl_cfg.num_ep           = 4;     // topology translation 会确认 DSP 数量
    tl_cfg.rc_is_active     = UVM_ACTIVE;
    tl_cfg.ep_is_active     = UVM_ACTIVE;
    tl_cfg.fc_enable        = 1'b1;
    tl_cfg.infinite_credit  = 1'b1;
    tl_cfg.scb_enable       = 1'b1;
    // Switch 下的 SVT EP 要由 TL EP driver 对 DUT 发来的请求回 Completion。
    tl_cfg.ep_auto_response = 1'b1;
    tl_cfg.use_unified_mem  = 1'b0; // 最小 BAR/窗口示例使用 EP sparse memory

    uvm_config_db#(pcie_global_cfg)::set(
      this, "tl_env", "global_cfg", global_cfg);
    uvm_config_db#(pcie_svt_backend_cfg)::set(
      this, "tl_env", "pcie_svt_backend_cfg", svt_backend_cfg);
    uvm_config_db#(pcie_tl_backend_factory)::set(
      this, "tl_env", "pcie_tl_backend_factory", backend_factory);
    // topology env 消费 tl_policy_cfg；不要只写 cfg。
    uvm_config_db#(pcie_tl_env_config)::set(
      this, "tl_env", "tl_policy_cfg", tl_cfg);

    tl_env = pcie_tl_env::type_id::create("tl_env", this);
  endfunction

  // 上述 extern 方法的定义见 §6~§8，仍属于本 class。
endclass
```

backend 的关键映射如下：

| link | SVT role/node | `vif_key` | `hdl_slot` |
|---|---|---|---:|
| `RC0_SW0_USP0` | RC / RC0 | `link_0_vif_0` | 0 |
| `SW0_DSP0_EP0` | EP / EP0 | `link_1_vif_1` | 1 |
| `SW0_DSP1_EP1` | EP / EP1 | `link_2_vif_1` | 2 |
| `SW0_DSP2_EP2` | EP / EP2 | `link_3_vif_1` | 3 |
| `SW0_DSP3_EP3` | EP / EP3 | `link_4_vif_1` | 4 |

`target_auto_response=0` 与 `tl_cfg.ep_auto_response=1` 是有意的分工：
SVT Target App 不重复回包，TL EP driver 通过 SVT adapter 产生唯一的
Completion。若把两者都打开，会出现重复 Completion 或 tag 状态不一致。

## 5. Host memory（可选）

本示例 `use_unified_mem=0`，不需要 Host manager；Switch 的 DSP memory
window 和 EP sparse memory 足够完成 BAR/读写演示。若测试 DUT/SVT EP 发起
DMA 或需要统一 Host memory，Switch 只有一个 Root，显式绑定一次即可：

```systemverilog
host_mem_manager host0_mem;
string bind_why;

host0_mem = new("host0_mem");
host0_mem.set_host_id(0);
tl_cfg.use_unified_mem = 1'b1;
if (!tl_cfg.bind_host_memory(0, 0, host0_mem, bind_why))
  `uvm_fatal("HOST_MEM", bind_why)
```

`bind_host_memory(root_index, host_id, mem, why)` 的四个参数都必须提供。
Host 数量不会改变五条物理链路或 SVT agent 数量；若将来扩展为多个 USP，
必须为每个 active Root 显式绑定 manager，详见
[`pcie_svt_4rc_dut_ep_integration.md`](pcie_svt_4rc_dut_ep_integration.md)
§5。

## 6. 五条链路的训练与 L0 等待

backend 只创建/configure agent，不自动启动 LTSSM。因为五个链路的 SVT 端
都是 active VIP，五个 agent 都要各自执行一次 `link_en`；DUT Switch 的
LTSSM/物理训练由 DUT 自己完成。Host 不参与建链。

```systemverilog
task my_switch_test::run_phase(uvm_phase phase);
  pcie_svt_backend svt_be;
  phase.raise_objection(this);

  if (!$cast(svt_be, tl_env.backend_provider))
    `uvm_fatal("LINKUP", "backend provider 不是 pcie_svt_backend")

  #10us; // 等 HDL agent/复位初始化完成

  fork : linkup_supervisor
    begin
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
      // 这个 wait fork 位于拥有 join_none 子线程的外层线程中，
      // 因而会等待五条链全部结束。
      wait fork;
    end
    begin
      #500us;
      `uvm_fatal("LINKUP", "五条 SVT/DUT Serial 链路建链超时")
    end
  join_any
  disable linkup_supervisor;

  // L0 后才能开始 §7 的枚举和业务流量。
  run_enum_and_traffic();
  phase.drop_objection(this);
endtask
```

四条 DSP 链漏掉 `link_en` 时，USP 可能已经进入 L0，但 Config 请求仍然
无法穿过 Switch 到达 EP；因此应以五个 L0 状态作为建链门禁。

### 6.1 用 AIP Tcl 编排五条链、EP 配置和枚举

Switch 场景也可以只编译一次 UVM test，再由 Tcl 选择建链、配置和枚举步骤。
使用 `aip-architecture-restructure` 的 `` `aip_cmd_user_seq `` 时，AIP
只负责 factory `create`/`start` 和活动 sequence 登记；`link_en.enable`、
link ID、RC sequencer 和 BDF 仍由用户 sequence 明确设置。AIP checkout、
`aip_core_pkg.sv` 的 include 顺序、`-debug_access+r+w+f` 和
`aip_tcl_bridge::run_loop()` 的接法与 4RC 文档 §6.1.1 完全相同。

建议把下面三个静态句柄放到 Switch test 的 command context 中：

```systemverilog
`include "aip_core_pkg.sv"
import aip_core_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
import pcie_svt_adapter_pkg::*;

class switch_aip_cmd_sqr extends uvm_sequencer;
  `uvm_component_utils(switch_aip_cmd_sqr)
  static uvm_sequencer_base        cmd_sqr;
  static pcie_svt_backend          svt_be;
  static pcie_tl_virtual_sequencer tl_vseqr;
  static pcie_global_cfg           global_cfg;
  static pcie_tl_env               tl_env;

  static function pcie_device_cfg find_ep_cfg(int ep);
    foreach (global_cfg.devices[i]) begin
      if ((global_cfg.devices[i] != null) &&
          (global_cfg.devices[i].role == PCIE_DEVICE_EP) &&
          (global_cfg.devices[i].device_id == $sformatf("EP%0d", ep)))
        return global_cfg.devices[i];
    end
    return null;
  endfunction

  function new(string name = "switch_aip_cmd_sqr", uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass
```

`switch_svt_link_up_seq` 应复用 4RC 文档中的 link wrapper，但命令句柄名改为
`switch_link_up`：它按 `link=` 在 `svt_agent_by_link` 中查找对应 agent，创建
官方 `svt_pcie_dl_service_set_link_en_sequence`，设置
`enable = 1'b1`，再等待 `pcie_status.pl_status.link_up` 和
`ltssm_state == svt_pcie_types::L0`。Switch 的 Config wrapper 则复用
`pcie_tl_cfg_wr_seq`/`pcie_tl_cfg_rd_seq`，并始终从
`switch_aip_cmd_sqr::tl_vseqr.rc_seqr_arr[0]` 启动；`reg` 参数仍是 DWORD 编号。
注册方式如下：

```systemverilog
`aip_cmd_user_seq(switch_link_up, switch_svt_link_up_seq,
                  switch_aip_cmd_sqr::cmd_sqr)
`aip_cmd_user_seq(switch_ep_cfg, switch_ep_cfg_seq,
                  switch_aip_cmd_sqr::cmd_sqr)
`aip_cmd_user_seq(switch_enum, switch_enum_seq,
                  switch_aip_cmd_sqr::cmd_sqr)
```

`switch_enum_seq` 的职责是遍历 `global_cfg.devices` 中的 EP0~EP3，为每个
EP 创建 `pcie_tl_bar_enum_seq`，设置 `target_bdf`、对应
`tl_env.cfg.switch_cfg.ds_mem_base[ep]`/`ds_mem_limit[ep]` 窗口，然后在 RC
sequencer 上 `start()`。它不再创建第二个 env，也不直接操作 SVT agent：

```systemverilog
class switch_enum_seq extends uvm_sequence;
  `uvm_object_utils(switch_enum_seq)
  function new(string name = "switch_enum_seq"); super.new(name); endfunction

  task body();
    aip_cmd h = aip_cmd::get_handle("switch_enum");
    if ((h == null) || (switch_aip_cmd_sqr::tl_vseqr == null)) begin
      if (h != null) begin h.status = 1; h.result_out = "ERROR: TL vseqr is null"; end
      return;
    end
    // 实际工程中从 test 共享只读的 global_cfg/tl_env 句柄；下面只保留
    // 关键 sequence 调用。find_ep_cfg() 应按 device_id 查找 canonical EP，
    // 不要用声明顺序猜 BDF；window 字段来自真实 Switch 配置。
    for (int ep = 0; ep < 4; ep++) begin
      pcie_device_cfg ep_cfg = switch_aip_cmd_sqr::find_ep_cfg(ep);
      pcie_tl_bar_enum_seq e = pcie_tl_bar_enum_seq::type_id::create(
        $sformatf("aip_ep%0d_enum", ep));
      if (ep_cfg == null) begin
        h.status = 1;
        h.result_out = $sformatf("ERROR: EP%0d device image missing", ep);
        return;
      end
      e.target_bdf       = ep_cfg.bdf;
      e.num_bars        = 6;
      e.bar_region_base = switch_aip_cmd_sqr::tl_env.cfg.switch_cfg.ds_mem_base[ep];
      e.bar_region_size = switch_aip_cmd_sqr::tl_env.cfg.switch_cfg.ds_mem_limit[ep] -
                          e.bar_region_base + 1;
      e.start(switch_aip_cmd_sqr::tl_vseqr.rc_seqr_arr[0]);
    end
    h.status = 0;
    h.result_out = "OK: switch EP0..EP3 BAR enumeration";
  endtask
endclass
```

`find_ep_cfg()` 必须按 `device_id` 查找真实 device image，不能用固定
`EP0/EP1` 数组下标猜 BDF。`build_phase` 创建 `switch_aip_cmd_sqr`，
`connect_phase` 绑定实际 backend/TL virtual sequencer，`run_phase` 保持唯一
的 UVM objection：

```systemverilog
switch_aip_cmd_sqr aip_sqr;

function void build_phase(uvm_phase phase);
  super.build_phase(phase);
  // ...按 §4 创建 tl_env...
  aip_sqr = switch_aip_cmd_sqr::type_id::create("aip_sqr", this);
endfunction

function void connect_phase(uvm_phase phase);
  super.connect_phase(phase);
  if (!$cast(switch_aip_cmd_sqr::svt_be, tl_env.backend_provider))
    `uvm_fatal("AIP", "backend provider 不是 pcie_svt_backend")
  switch_aip_cmd_sqr::tl_vseqr = tl_env.v_seqr;
  switch_aip_cmd_sqr::global_cfg = global_cfg;
  switch_aip_cmd_sqr::tl_env = tl_env;
  switch_aip_cmd_sqr::cmd_sqr = aip_sqr;
endfunction

task run_phase(uvm_phase phase);
  phase.raise_objection(this);
  aip_tcl_bridge::run_loop();
  phase.drop_objection(this);
endtask
```

Tcl 必须把 USP 和四个 DSP 的 `link_en` 都启动并确认 L0 后，才能访问 EP
配置空间或做 BAR 枚举。每行是同步 command；返回后 sequence 已经完成：

```tcl
source $env(AIP_CORE)/dist/aip_init_so.tcl

switch_link_up link=RC0_SW0_USP0
if {[aip_check_status] != 0} { error [aip_read_result] }
switch_link_up link=SW0_DSP0_EP0
switch_link_up link=SW0_DSP1_EP1
switch_link_up link=SW0_DSP2_EP2
switch_link_up link=SW0_DSP3_EP3

# 选择安全的配置寄存器验证读写；reg 是 DWORD 编号，bdf 来自 global_cfg。
switch_ep_cfg op=rd rc=0 bdf=0x0100 reg=0
switch_ep_cfg op=wr rc=0 bdf=0x0100 reg=1 data=0x00000007
switch_enum                         ;# 四个 DSP window 内做 BAR 枚举

end_test drain=1000
```

不要在 Tcl `fork` 中重复调用同一个 `switch_link_up` 命令：该命令只有一个
`args_in`/结果句柄。若需要五链并行，按物理链分别注册五个 command name，或
在一个用户 sequence 内对五个官方 link-enable sequence 做受控 `fork/join`，
并让该 sequence 统一等待五个 L0。AIP 不会自动启动 EP 链路、自动枚举 BAR，
也不会把 `target_auto_response` 改成 1；Switch 的唯一 Completion 来源仍是
§4 配置的 TL EP driver。

## 7. BAR 枚举与 RC→Switch→EP 读写

`pcie_tl_bar_enum_seq` 应在 RC sequencer 上启动，目标 BDF 来自
`global_cfg.devices` 的 EP device image。Switch 的 DSP memory window 默认
为 `0x8000_0000 + i*0x1000_0000`，所以枚举时把 BAR 分配窗口限制在对应
DSP window，避免 BAR 地址被分配到 Switch 不会转发的区域。

下面的 task 展示 EP0~EP3 逐一枚举、写入 64 字节、再读回校验的完整路径；
读写方向是 `TL RC → SVT RC → DUT USP → DUT Switch → DUT DSP → SVT EP`，
Completion 沿反方向返回。

```systemverilog
task my_switch_test::run_enum_and_traffic();
  pcie_tl_virtual_sequencer vseqr = tl_env.v_seqr;

  for (int ep = 0; ep < 4; ep++) begin
    pcie_device_cfg ep_cfg;
    pcie_tl_bar_enum_seq enum_seq;
    bit [31:0] bar0;
    bit [31:0] win_base;
    bit [31:0] win_size;

    foreach (global_cfg.devices[i]) begin
      if ((global_cfg.devices[i] != null) &&
          (global_cfg.devices[i].role == PCIE_DEVICE_EP) &&
          (global_cfg.devices[i].device_id == $sformatf("EP%0d", ep)))
        ep_cfg = global_cfg.devices[i];
    end
    if (ep_cfg == null)
      `uvm_fatal("ENUM", $sformatf("global_cfg 中缺少 EP%0d", ep))

    win_base = tl_env.cfg.switch_cfg.ds_mem_base[ep];
    win_size = tl_env.cfg.switch_cfg.ds_mem_limit[ep] - win_base + 1;
    enum_seq = pcie_tl_bar_enum_seq::type_id::create(
      $sformatf("ep%0d_bar_enum", ep));
    enum_seq.target_bdf       = ep_cfg.bdf;
    enum_seq.num_bars         = 6;
    enum_seq.bar_region_base  = win_base;
    enum_seq.bar_region_size  = win_size;
    enum_seq.start(vseqr.rc_seqr_arr[0]);

    if (!enum_seq.assigned_bar_base.exists(0))
      `uvm_fatal("ENUM", $sformatf("EP%0d BAR0 未分配", ep))
    bar0 = enum_seq.assigned_bar_base[0];

    begin
      pcie_tl_rw_seq wr, rd;
      wr = pcie_tl_rw_seq::type_id::create($sformatf("rc_ep%0d_write", ep));
      wr.op = PCIE_RW_WRITE;
      wr.addr = {32'h0, bar0} + 64'h100;
      wr.byte_len = 64;
      wr.wdata = new[wr.byte_len];
      foreach (wr.wdata[i]) wr.wdata[i] = 8'hA0 + ep*8'h10 + i;
      wr.start(vseqr.rc_seqr_arr[0]);

      rd = pcie_tl_rw_seq::type_id::create($sformatf("rc_ep%0d_read", ep));
      rd.op = PCIE_RW_READ;
      rd.addr = wr.addr;
      rd.byte_len = wr.byte_len;
      rd.rb_timeout_ns = 200_000;
      rd.start(vseqr.rc_seqr_arr[0]);
      if (rd.status != PCIE_RW_OK)
        `uvm_fatal("TRAFFIC", $sformatf("EP%0d BAR0 read completion 失败", ep))
      foreach (wr.wdata[i])
        if ((i >= rd.rdata.size()) || (rd.rdata[i] != wr.wdata[i]))
          `uvm_fatal("TRAFFIC", $sformatf(
            "EP%0d BAR0 readback mismatch at byte %0d", ep, i))
    end
    `uvm_info("TRAFFIC", $sformatf(
      "RC -> Switch -> EP%0d BAR0 readback PASS (BDF=%04h base=%08h)",
      ep, ep_cfg.bdf, bar0), UVM_LOW)
  end
endtask
```

上面的 `run_enum_and_traffic()` 是普通 task，可在 `run_phase` 中紧接五条
链路 L0 等待后调用。若只验证 Switch 路由而不需要真实 BAR，可把
`use_unified_mem` 保持为 0，并直接使用 `ds_mem_base[ep]` 作为窗口地址；
这与 `pcie_tl_switch_rw_readback_test` 的 sparse-memory 方式一致。

## 8. Switch 运行前契约检查

建议在 `end_of_elaboration_phase` 执行以下检查，尽早区分“拓扑/槽位配置
错误”和“DUT 链路训练错误”：

```systemverilog
function void my_switch_test::check_switch_contract();
  pcie_svt_backend svt_be;
  bit seen_slot[int];

  if ((global_cfg == null) || (global_cfg.runtime_num_links != 5))
    `uvm_fatal("CONTRACT", "Switch runtime_num_links 必须为 5")
  if ((tl_env == null) || !tl_env.cfg.switch_enable ||
      (tl_env.cfg.switch_cfg == null) ||
      (tl_env.cfg.switch_cfg.num_usp != 1) ||
      (tl_env.cfg.switch_cfg.num_ds_ports != 4))
    `uvm_fatal("CONTRACT", "TL env 未得到 1 USP + 4 DSP 的 Switch 配置")

  foreach (global_cfg.links[i]) begin
    pcie_link_cfg link = global_cfg.links[i];
    int expected_slot;
    string expected_vif;
    bit expect_rc;

    if (link == null)
      `uvm_fatal("CONTRACT", $sformatf("link[%0d] 为空", i))
    expect_rc = (link.link_id == "RC0_SW0_USP0");
    expected_slot = expect_rc ? 0 : (link.upstream_port_index + 1);
    expected_vif = expect_rc ?
      $sformatf("link_%0d_vif_0", expected_slot) :
      $sformatf("link_%0d_vif_1", expected_slot);

    if (!link.enabled || !link.use_svt || !link.svt_role_valid ||
        (link.svt_role != (expect_rc ? PCIE_DEVICE_RC : PCIE_DEVICE_EP)))
      `uvm_fatal("CONTRACT", $sformatf("%s role/ownership 错误", link.link_id))
    if (!link.has_hdl_slot || (link.hdl_slot != expected_slot))
      `uvm_fatal("CONTRACT", $sformatf("%s hdl_slot 错误", link.link_id))
    if (link.vif_key != expected_vif)
      `uvm_fatal("CONTRACT", $sformatf("%s vif_key 错误", link.link_id))
    if (link.max_gen != 4 ||
        link.link_width != (expect_rc ? 16 : 4))
      `uvm_fatal("CONTRACT", $sformatf("%s 必须是预期的 Gen4/x%s 链路",
        link.link_id, expect_rc ? "16" : "4"))
    if (seen_slot.exists(link.hdl_slot))
      `uvm_fatal("CONTRACT", $sformatf("重复 hdl_slot=%0d", link.hdl_slot))
    seen_slot[link.hdl_slot] = 1'b1;
  end

  if (!$cast(svt_be, tl_env.backend_provider))
    `uvm_fatal("CONTRACT", "backend provider 不是 pcie_svt_backend")
  if ((svt_be.created_rc_count != 1) || (svt_be.created_ep_count != 4))
    `uvm_fatal("CONTRACT", $sformatf(
      "期望 SVT RC=1/EP=4，实际 RC=%0d EP=%0d",
      svt_be.created_rc_count, svt_be.created_ep_count))
  if ((tl_env.v_seqr.rc_seqr_arr.size() != 1) ||
      (tl_env.v_seqr.ep_seqr_arr.size() != 4))
    `uvm_fatal("CONTRACT", "TL sequencer 数量不是 RC=1、EP=4")
endfunction

function void my_switch_test::end_of_elaboration_phase(uvm_phase phase);
  super.end_of_elaboration_phase(phase);
  check_switch_contract();
endfunction
```

实际 test 中可把 §6 的 `run_phase` 与 §7 的 task 合并为：raise objection →
五链 `link_en`/L0 → `run_enum_and_traffic()` → drop objection。不要在 DUT
侧再创建一个“帮忙回包”的 SVT EP；四个 SVT EP 已由 backend 创建，TL EP
driver 是它们唯一的业务响应入口。

## 9. 常见错误与定位

| 现象 | 优先检查 |
|---|---|
| `svt_pcie_vif` 缺失 | `update_if_variables` 的 link_id、port ID 与 `vif_key` 是否逐字符一致 |
| `runtime_num_links exceeds ...` | `+define+PCIE_SVT_ENV_MAX_NUM_LINKS=5` 是否出现在 filelist 前 |
| 只有 USP L0，EP 枚举超时 | 四个 SVT EP 是否都执行 `link_en`，DSP 复位/bit clock 是否释放 |
| EP agent 序号错位 | 使用 `ep_agents[i]`/canonical DSP 槽位，不要按启用链声明顺序压缩 |
| 重复 Completion | `svt_backend_cfg.target_auto_response` 应为 0，`tl_cfg.ep_auto_response` 应为 1 |
| BAR 写入后内存读超时 | BAR 基址是否位于对应 `ds_mem_base/ds_mem_limit` window |
| Passive Monitor 无数据 | 只接 reference clock；应显式提供 `rx_clk`/`tx_clk` bit clock |
| global shadow 报错 | 仅官方 example env 才需要 `EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH`，并检查实例层次 |
