# TL-root / SVT adapter

本目录只保留正式 SVT transport adapter 的编译入口。生产控制面是
`pcie_tl_env`；SVT 不再提供第二套 topology、配置空间或 traffic env。

## 编译入口

当前有五个可直接运行的 SVT 验证入口：

- `pcie_tl_svt_formal.f`：本项目 TL-root + SVT FULL_VIP 双向 Serial 门禁；
- `pcie_tl_svt_pipe.f`：同一门禁的 PIPE 物理层版本（见下节）；
- `pcie_svt_peer_traffic.f`：官方 SVT RC/EP peer-only Serial 自检。
- `pcie_svt_aip_link.f`：AIP Tcl 启动双 SVT Serial 建链诊断，运行
  `bash ./check_svt_aip_link.sh`，详见[复现说明](../../docs/pcie_svt_aip_link_diagnostic.md)。
- `pcie_svt_aip_cmd.f`：可选通用 AIP seq 的 Config 与双向 Memory 门禁，
  运行 `bash ./check_svt_aip_cmd.sh`，详见[参数和绑定说明](../../docs/pcie_svt_aip_sequences.md)。

## TL→SVT PIPE 双向门禁（Gen3/4/5）

`pcie_tl_svt_pipe.f` + `pcie_tl_svt_pipe_top` 与 Serial 门禁完全同构
（同一批 test、同样的 `PCIE_TL_SVT_TLP_PASS` 等断言），差异只在物理层：
双 SVT agent 通过官方 PIPE/PIPE5 互连宏对接（RC=MPIPE 0，EP=MPIPE 1，
x1 lane）。TL 控制面与 adapter 对 PHY 类型无感知。

PIPE spec 版本与 PCIe Gen 联动，由编译宏选择档位（拓扑内锁定映射，
用户只选 Gen，不可能出现版本错配）：

| 编译宏 | PCIe | PIPE | 互连宏 |
|---|---|---|---|
| （无，默认） | 3.0 | 4.3 | `SVT_PCIE_ICM_PIPE_PIPE_LINK` |
| `+define+PCIE_PIPE_GEN4` | 4.0 | 4.4 | `SVT_PCIE_ICM_PIPE_PIPE_LINK` |
| `+define+PCIE_PIPE_GEN5` | 5.0 | 5.1 | `SVT_PCIE_ICM_PIPE5_PIPE5_LINK` |

Gen5 档必须同时给出三个官方使能宏，缺一编译失败：

```sh
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  +define+PCIE_PIPE_GEN5 \
  +define+SVT_PCIE_ENABLE_GEN5 \
  +define+SVT_PCIE_ENABLE_PIPE5 \
  +define+EXPERTIO_PCIESVC_INCLUDE_32G \
  -f pcie_tl_svt_pipe.f -top pcie_tl_svt_pipe_top \
  -o build/pipe_gen5/simv
./build/pipe_gen5/simv +UVM_TESTNAME=pcie_tl_svt_formal_link_test
```

宏含义：`SVT_PCIE_ENABLE_GEN5` 提供 32G 速率编码与覆盖组；
`SVT_PCIE_ENABLE_PIPE5` 编译 PIPE5 MBI EQ 握手 task；
`EXPERTIO_PCIESVC_INCLUDE_32G` 引入 32 GT/s 速率模型。三档均已在
R-2020.12 上通过 L0 + 全部四个双向门禁标志（0 ERROR/FATAL）。PIPE5 的
pclk 方向由 `SVT_PCIE_ENABLE_PIPE5_PCLK_AS_PHY_OUTPUT_MODE` 编译宏联动
两端，默认 pclk 来自 MAC。

### 真实 DUT 集成宏的 PIPE 模式

`PCIE_SVT_DECLARE_HDL_AGENT_X4/X8/X16` 是 Serial/PIPE 通用的声明入口：
默认展开 SERDES，加 `+define+PCIE_SVT_HDL_PHY_PIPE`
即切换为 PIPE 展开——宏调用行、参数、`update_if_variables`、
`vif_key` 约定完全不变。差异只有两点：

- 生成 `<name>_pipe`（`pcie_svt_pipe_port_if #(LANES)` 向量化端口，
  替代 Serial 的 `<name>_serial`）：宏内已把官方 pipe_if/pie8_eq_if 的
  全部散名逐 lane 信号（含 tx_deemph、preset/EQ、MBI message bus）按
  is_root 方向映射进该端口，DUT 只需向量级连线：
  `assign <name>_pipe.tx_data[0] = dut_tx_data_l0;` …；
- 双实例对拼一行搞定：
  `` `PCIE_SVT_PIPE_PORT_CROSS_X4(rc_pipe, ep_pipe) ``（a 必须是
  spipe/Root 的 port，b 是 mpipe/EP 的 port）；
- `pipe_if.reset` 是 logic（单一结构驱动），宏内不驱动它：由用户顶层
  每实例一行 `assign <name>_spd.vip_port_if.pipe_if.reset = <复位>;`。

MPIPE 侧别由 is_root 自动推导（Root=spipe，Endpoint=mpipe）；PIPE/PCIe
spec 版本沿用上表的 `PCIE_PIPE_GEN4/GEN5` 档位宏。宏路线的双 SVT x4
PIPE 门禁入口为 `pcie_tl_svt_pipe_macro.f` + `pcie_tl_svt_pipe_macro_top`
（复用同一批门禁断言），已在 R-2020.12 上全绿。

### 真实 DUT 集成宏的 Serial 时钟

`PCIE_SVT_DECLARE_HDL_AGENT_X4/X8/X16` 的 Serial 分支统一显式设置
`SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE=0`，由 active VIP 内部产生发送
bit clock，匹配只连接差分数据的 DUT 集成。不需要额外设置
`pcie_cfg.pl_cfg.disable_ext_bit_clock_mode=1` 或为此派生 backend。
旧版 mode=1 配合 cfg 默认值 0 会等待外部发送时钟；无时钟时可能停在
INITIAL。更新宏必须重新编译 HDL，不能只重跑旧 `simv`。

DUT PHY reference clock 仍由用户独立提供；独立 Passive Monitor 的
采样时钟要求不变，PIPE 分支也不受此修改影响。有意使用外部发送模式
时，应在用户封装中选择 mode=1、cfg disable=0，并驱动
`ext_clk_if.tx_clk_*`，不能拿 DUT reference clock 或 monitor 采样接口
代替。完整配置关系见[4RC 集成说明 §2.2](../../docs/pcie_svt_4rc_dut_ep_integration.md#22-serial-时钟与-passive-monitor)。

`pcie_tl_svt_adapter.f` 现在是 source-only 适配层 filelist。它只包含
`pcie_tl_env`、SVT adapter package 和官方 SVT 支持源码，不再包含没有真实
SVT agent 的占位 test/top。接入真实 DUT 时，应在用户工程自己的 filelist
中引用这些源文件，并追加 DUT wrapper、SVT HDL agent、Serial/PIPE 连接和
用户 test。

已删除的 `pcie_tl_svt_adapter_*` 占位测试只验证 factory/queue-only 对象是否
创建，既没有真实 SVT agent，也没有实际 TLP 或物理链路，不再作为回归入口。

`pcie_svt_adapter_pkg.sv` 会导入官方 `svt_uvm_pkg` 和
`svt_pcie_uvm_pkg`。当前 source-only 列表已经包含
`pcie_svt_vip_bootstrap.sv`，会在 adapter package 前自动 include 官方
`svt_pcie.uvm.pkg`。用户 prefix 默认只定义可选宏，不要再次 include 官方
package；`EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH` 只在官方 example
env/interconnect 使用 global shadow 时需要，真实 DUT + backend 场景可以省略。

推荐创建一个用户自有的 package-prefix 源文件（下面的层次名仅为示例），
并把它放在 `-f` 之前：

```systemverilog
// user_svt_pkg_prefix.sv -- 由用户工程维护；只定义宏，不 include package
`define SVC_RANDOM_SEED_SCOPE my_pcie_top.global_random_seed
// 官方 example env/interconnect 才需要这一行：
// `define EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH my_pcie_top.global_shadow0
```

随后真实 DUT 工程可按如下顺序编译 source-only 列表：

```text
/path/to/user/user_svt_pkg_prefix.sv
-f /path/to/pcie_work/svt_pcie_integration/sim/pcie_tl_svt_adapter.f
/path/to/user/pcie_real_dut_top.sv
/path/to/user/pcie_real_dut_test.sv
```

这里的四行应按顺序作为 VCS 输入（例如直接追加在 `vcs` 命令行中）；如果
工程统一使用外层 filelist，请把 prefix 源文件列在外层 filelist 的
`-f pcie_tl_svt_adapter.f` 之前。

### 真实 DUT + Serial 的完整编译顺序

外层顺序固定为“环境变量 → prefix → source-only adapter → DUT top → test”：

```text
1. DESIGNWARE_HOME、PCIE_SVT_ROOT、HOST_MEM_ROOT
2. user_svt_pkg_prefix.sv（只定义宏）
3. -f pcie_tl_svt_adapter.f
4. 用户 DUT top
5. 用户 UVM test
```

`pcie_tl_svt_adapter.f` 内部的关键依赖顺序为：

```text
TL source/package
  -> pcie_svt_vip_bootstrap.sv
       -> svt_pcie.uvm.pkg
            -> svt_pciesvc_source.svi
                 -> pciesvc_global_shadow.svp
                 -> pcie_device_agent_svt/sverilog/src/vcs/
                    svt_pcie_single_port_device_agent_hdl.svp
  -> pcie_svt_adapter_pkg.sv
```

bootstrap 依赖 filelist 中的：

```text
+define+DESIGNWARE_INCDIR=$DESIGNWARE_HOME
+define+SVT_LOADER_UTIL_ENABLE_DWHOME_INCDIRS
```

这两个定义让官方 source-map 找到 R-2020.12 的加密 `.svp` 模型；只设置
`+incdir+$PCIE_SVT_ROOT/sverilog/include` 不会把
`pciesvc_global_shadow` 或 `svt_pcie_single_port_device_agent_hdl` 加入
`work`。只有完全绕过 bootstrap 时，才改用：

```text
+libext+.v+.sv+.vp+.svp
-y $PCIE_SVT_ROOT/verilog/src/vcs
-y $PCIE_SVT_ROOT/sverilog/src/vcs
-y $PCIE_SVT_ROOT/pcie_device_agent_svt/sverilog/src/vcs
```

用户 DUT top 内还要保持以下 Serial include 顺序。`pcie_svt_serial_port_if.sv`
可以作为用户 filelist 源文件放在 DUT top 前，或者直接 include；
`pcie_svt_serial_adapter.sv` 是宏定义文件，必须与使用它的 top 在同一编译
作用域内 include，不能只把它作为排在 top 后面的独立源文件：

```systemverilog
`include "import_pcie_svt_uvm_pkgs.svi"
`include `SVC_SOURCE_MAP_SUITE_UTIL_V(pcie_svc,PCIE,latest,svc_util_parms)
`include `SVC_SOURCE_MAP_SUITE_MODEL_MODULE(pcie_svc,Include,latest,pciesvc_parms)
`include "pcie_svt_serial_port_if.sv"
`include "pcie_svt_serial_adapter.sv"
`include "pcie_svt_hdl_agent_macros.svh"
```

最后才调用 `PCIE_SVT_DECLARE_HDL_AGENT_X4/X8/X16`。不要在 DUT top 末尾再次
include `svt_pcie.uvm.pkg`，否则会与 bootstrap 产生 package 重复定义。

当前仓库的 Serial 声明宏使用 PCIe 5.0 参数；未修改宏时，真实 DUT 的外层
filelist 还要选择：

```text
+define+SVT_PCIE_ENABLE_GEN5
+define+SVT_PCIE_ENABLE_SERDES_ARCH
```

如果工程分支将 Serial 声明宏改为 PCIe 4.0 参数，则改用
`+define+SVT_PCIE_ENABLE_GEN4`。Serial filelist 不应无条件定义
`SVT_PCIE_ENABLE_PIPE5`；该宏只用于 PIPE5 物理层。adapter filelist 已包含
`SVT_PCIE_ENABLE_10_BIT_TAGS` 和 8G/16G SVC 模型选择。

适用于单链路 Serial DUT 的命令模板如下；多链路只需按拓扑修改容量宏和
用户 top/test：

```sh
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT=$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12
export HOST_MEM_ROOT=/path/to/host_mem
cd /path/to/pcie_work/svt_pcie_integration/sim
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+SVT_PCIE_ENABLE_GEN5 \
  +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_SVT_ENV_MAX_NUM_LINKS=1 \
  /path/to/user/user_svt_pkg_prefix.sv \
  -f pcie_tl_svt_adapter.f \
  /path/to/user/pcie_real_dut_top.sv \
  /path/to/user/pcie_real_dut_test.sv
```

`-timescale` 应与用户 DUT/adapter 工程统一；如果外层 filelist 已明确设置
其它精度，以外层工程的单一设置为准，不能让不同 compilation unit 随意混用。

如果外层集成流程选择自行 include 官方 package，则必须在本列表之前编译该
源文件（或一个只包含 package 的 prefix），同时增加
`+define+PCIE_SVT_PKG_EXTERNAL` 让 bootstrap 跳过重复 include，并保证
`svt_pcie.uvm.pkg` 只编译一次；不要依赖列表末尾的 test/top 反向提供 package。

`import_pcie_svt_uvm_pkgs.svi` 是 SVT 安装提供的导入 helper（通过
`$PCIE_SVT_ROOT/sverilog/include` 或用户工程的 include path 查找），不是本
仓库生成的文件。用户 top 仍应按上面的顺序 include 它；若内网安装采用不同
目录，应把实际安装目录加入 `+incdir+`，不需要复制或修改该 helper。

### 真实 DUT VIF 发布

每个静态 `svt_pcie_single_port_device_agent_hdl`（包括 link macro 展开的
实例）都必须在 HDL 中调用一次官方 `update_if_variables` task。该调用必须
位于静态模块 `initial` 块，不能从 UVM class/function 中调用。例如，SVT
作为 Root Complex 时使用 port ID `4'h0`，SVT 作为 Endpoint 时使用 `4'h1`：

```systemverilog
initial begin
  svt_side0_spd.update_if_variables(
    svt_is_root ? 4'h0 : 4'h1,
    8'h00,                 // link_id；与 pcie_link_cfg.link_id 对应
    "uvm_test_top", "uvm_test_top");
end
```

`update_if_variables` 会通过官方 config DB 发布
`link_<link_id>_vif_<port_id>`（上例为 `link_0_vif_0` 或
`link_0_vif_1`）。该字符串必须原样填入对应
`pcie_link_cfg.vif_key`，否则 backend 会在 build 阶段报告找不到
`svt_pcie_vif`。如果用户采用不同的 UVM 根层次，应同步替换 task 的两个
parent-hierarchy 参数和 config-DB 查找路径。

本目录内的专用 formal/peer filelist 中的相对路径以该 `sim` 目录为基准；
从仓库根目录直接执行会把 `../rtl` 解析到错误位置并产生
“Source file cannot be opened”。

运行前在 VCS 主机登录 shell 中设置 `HOST_MEM_ROOT`、`PCIE_SVT_ROOT` 和
`DESIGNWARE_HOME`。真实项目应将 filelist 中的示例顶层替换为自己的 HDL
top，并保留 `pcie_svt_adapter_pkg`、官方 `svt_pcie_device_agent` 以及
Serial lane 适配宏。

## 官方 SVT 双向 Serial 自检

`pcie_svt_peer_traffic.f` 是独立的 test-only 自检入口，用于确认
R-2020.12 官方 RC/EP agent、16-lane Serial interconnect 和默认 DriverApp
本身可用。该入口不包含 `pcie_tl_env`，因此不能替代 TL→Mapper 往返验证。

```sh
cd svt_pcie_integration/sim
export PCIE_SVT_ROOT=/home/ubuntu/synopsys/designware_vip_R-2020.12/vip/svt/pcie_svt/R-2020.12
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export HOST_MEM_ROOT=/path/to/host_mem
mkdir -p build/peer_traffic
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  -f pcie_svt_peer_traffic.f -top pcie_svt_peer_traffic_top \
  -o build/peer_traffic/simv
./build/peer_traffic/simv +UVM_TESTNAME=pcie_svt_peer_traffic_test \
  -l build/peer_traffic/run.log
```

日志中应同时看到 `SvtTestEpilog: Passed`、`UVM_ERROR : 0` 和
`UVM_FATAL : 0`。VCS 编译阶段较慢时不要对同一个 build 目录并发启动多个
编译进程，否则会互相覆盖 `simv.daidir`。

## TL→SVT FULL_VIP Serial→TL 双向门禁

`pcie_tl_svt_formal.f` 是双向集成测试入口。它在同一个 UVM test 中创建
官方 `pcie_device_unified_vip_env`（仅提供正式 RC/EP agent 和 Serial
transport）以及本项目的 `pcie_tl_env`（唯一事务控制面）。这里使用
`FULL_VIP` 后端：正式 active agent 不创建 `tlp_mapper`，而是由 adapter
将 TL 事务送入 `pcie_agent.tlp_seqr`。接收方向使用 SVT 的公开边界：Root
优先使用 TL monitor，active monitor 不存在时退回
`svt_pcie_tl::pre_tlp_out_put`；Endpoint 使用
`svt_pcie_target_app::post_rx_tlp_get` 捕获下行请求。这样 Endpoint 请求
交给本项目 EP driver 生成 Completion，Completion 再沿 SVT Serial 返回
本项目 RC driver。

```sh
cd svt_pcie_integration/sim
export PCIE_SVT_ROOT=/home/ubuntu/synopsys/designware_vip_R-2020.12/vip/svt/pcie_svt/R-2020.12
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export HOST_MEM_ROOT=/path/to/host_mem
mkdir -p build/tl_svt_formal
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  -f pcie_tl_svt_formal.f -top pcie_tl_svt_formal_top \
  -o build/tl_svt_formal/simv -l build/tl_svt_formal/compile.log
./build/tl_svt_formal/simv \
  +UVM_TESTNAME=pcie_tl_svt_formal_link_test \
  -l build/tl_svt_formal/run.log
```

`pcie_tl_svt_formal_test.sv` 是源文件名，实际注册到 UVM factory 的测试类
名是 `pcie_tl_svt_formal_link_test`；运行命令应使用后者。省略
`+UVM_TESTNAME` 也可以，因为 formal top 会把同一个类设为默认测试。

通过标志为 `PCIE_TL_SVT_TLP_PASS`；同时应检查日志中的 SVT Serial
链路进入 L0，且 `UVM_ERROR/UVM_FATAL` 均为 0。正式门禁还会检查
`RC_EP_WRITE_READBACK_PASS`、`EP_RC_READBACK_PASS` 和
`EP_RC_WRITE_PASS`：分别覆盖 RC→EP 写后读回、EP→RC 读 Root host
memory，以及 EP→RC posted write 回读 Root host memory。这样既确认
Completion 返回，也确认反向 posted 请求确实落入 RC 的统一内存，而不是
只在 adapter mailbox 中出现。真实 DUT 集成时保留同样的 `pcie_tl_env`、
factory override 和 `svt_agent_path` 配置即可。

FULL_VIP 使用 `pcie_tl_env` 的 TL/SVT adapter 作为事务控制入口，因此
`ENV_BRIDGE_DIAG` 中的 “entered SV_IF_MODE without vif” 是预期诊断：该
路径不使用旧的 `pcie_tl_if` streaming VIF，而是直接绑定正式 SVT agent 的
`tlp_seqr` 和公开 callback。它不是缺少 SVT Unified VIF；若需要旧式 TL
interface streaming，应使用 TL-only/SV interface backend，并为 adapter
注入 `virtual pcie_tl_if`。

### Transport-only 的 SVT shadow 配置检查

当前 FULL_VIP 门禁由 `pcie_tl_env` 统一管理配置空间和 BDF；SVT 只承担
DL/PL/Serial transport，因此不会为 TL sequence 动态产生的 requester
function 自动建立 shadow configuration entry。测试在
`pcie_tl_svt_formal_test.sv`（其中的
`pcie_tl_svt_formal_link_test`）将 Root/Endpoint 的
`pcie_cfg.tl_cfg.enable_shadow_cfg_lookup` 设为 0，并保留回归断言，避免
`ReceiveTLP: ... no cfg ptr tbl entry` warning 干扰 transport 验证。

如果后续要验证 SVT 自身的 shadow 配置一致性，应改为给每个实际 BDF 注册
对应的 SVT shadow function entry，再重新打开该字段；不能把 transport-only
的关闭策略当成配置空间完整性检查。

### AT 字段约束

`pcie_tl_tlp.at` 是随机字段，声明时的 `2'b00` 初值不会限制
`randomize()`。为避免普通 Memory TLP 被随机编码成 SVT 不接受的
`AT=01`（Translation Request）。当前实现对 AT 使用标准独立 soft 默认
`soft at == 2'b00`，因此普通序列默认发出未翻译请求；该 soft 约束不会把
`CONSTRAINT_ILLEGAL` 锁死，后续 ATS 专用 sequence 可以用 hard inline
constraint 显式选择 `AT=10`，而不影响现有 TL-only 错误注入模式。

## 集成边界

测试在创建 TL env 前安装：

```systemverilog
pcie_tl_if_adapter::type_id::set_type_override(
  pcie_svt_if_adapter::get_type());
```

正式 SVT agent 由用户顶层或官方 unified env 创建。`svt_agent_path` 通过
config DB 发布正式 `svt_pcie_device_agent` 的全路径；FULL_VIP 后端不要求
`tlp_mapper`，adapter 直接使用官方 TL sequencer 和 callback。若用户选择
兼容的 `MAPPER_APP` 后端，才需要通过 `svt_agent`/`svt_agent_path` 绑定
正式 Mapper。TL sequence 继续负责 link policy、Config/BAR、枚举和 Memory
traffic；adapter 只做 TL/SVT 编解码和 transport 转接。

`pcie_svt_hdl_agent_macros.svh`、`pcie_svt_serial_port_if.sv` 和
`pcie_svt_serial_adapter.sv` 提供 Serial HDL 边界。DUT wrapper、时钟、复位、
SerDes/PIPE 物理连接由用户 top 完成。当前只承诺 Serial；PIPE 作为后续
独立适配器扩展。

### SVT backend 配置映射

`pcie_svt_backend_cfg` 是 SVT 专用配置对象，由 `pcie_tl_env` 在创建
Device Agent 前消费。常用字段示例：

```systemverilog
pcie_svt_backend_cfg svt_cfg;
svt_cfg = pcie_svt_backend_cfg::type_id::create("svt_cfg");
svt_cfg.default_max_gen       = 4;
svt_cfg.direct_gen4_enable    = 1'b1; // 允许 Gen1 直接加速到 Gen4
svt_cfg.fast_link_training    = 1'b1;
svt_cfg.eq_mode               = 1;    // 1=Full, 2=Bypass, 3=No-Eq, 0=自动
svt_cfg.enable_transaction_log = 1'b1;
svt_cfg.transaction_log_filename = "pcie_xact.log";
uvm_config_db#(pcie_svt_backend_cfg)::set(
  this, "env", "pcie_svt_backend_cfg", svt_cfg);
```

`eq_mode` 会映射到官方 `set_link_eq_attribute_values()` 的第一个参数；
第二个参数是 SVT 特有的 `enable_direct_speed_up_from_2_5g_to_16g`，由
`direct_gen4_enable || fast_link_training` 控制，不能用
`full_equalization_required` 代替。`link_timeout` 会换算成 ns，同时写入
`pcie_cfg.tl_cfg.completion_timeout_ns`、
`pcie_cfg.tl_cfg.credit_starvation_timeout_ns`（RX/monitor 预算）以及
`driver_cfg[0].completion_timeout_ns`（active Driver App 的真正 CTO）。

`svt_verbosity` 通过 UVM 公共的
`set_report_verbosity_level_hier()` 应用到自动创建的 Device Agent。

以下字段目前没有 R-2020.12 对应的安全公开映射，backend 会在创建 agent
之前直接报错（默认值仍保持向后兼容）：

- `target_app_enable=0`：Device Configuration 要求至少一个 Target App，且
  当前 TL-owned bridge 必须保留 Target App 以接收并抑制默认响应；
- `target_auto_response=1`：Completion 由 `pcie_tl_env` 统一处理，不能让
  SVT 内建 Target App 并行响应；
- `enable_svt_monitor=1`：passive monitor 必须是独立的
  `is_active=0/enable_monitor=1` agent；
- `full_equalization_required=0`：请使用 `enable_equalization/eq_mode`；
- 非默认的 `cfg_timeout`、`enum_timeout`、`traffic_timeout`：它们是 TL
  编排 sequence 的阶段预算，不是 SVT configuration 字段，当前 backend
  不会伪造写入私有成员。

日志开关分别映射到 SVT 的 transaction、symbol、PL-history、Ctrl-SKP、
MBI 和 FLIT logging 字段。backend 创建的是 active Device Agent；需要纯
观察时，请在 test 中另建一个 `is_active=0` 且 `enable_monitor=1` 的 SVT
agent。

### AIP Tcl sequence 接入（建链 → Config/BAR/Memory）

新增接入推荐使用[可选通用 sequence 库](../../docs/pcie_svt_aip_sequences.md)：
显式启用 `PCIE_ENABLE_AIP_CMDS`，由用户把命令注册到真实 DL/TL sequencer，
支持严格的地址、长度、BE、payload 和超时检查。下文保留旧手工 wrapper
说明；旧 `link/rc/reg` 参数与新接口不同，不能混用，也不要重复定义同名类。
真实双 SVT Config/双向 Memory 验证入口为 `bash ./check_svt_aip_cmd.sh`。

如果用户 test 采用 `aip-architecture-restructure` 分支的 AIP bridge，
source-only filelist 仍只负责 TL/SVT package 和 adapter；AIP 是用户 test
额外加入的 Tcl 编排层。其推荐顺序是：

```text
VCS source order: user prefix → pcie_tl_svt_adapter.f
                   → user command/test source (its first AIP include is aip_core_pkg.sv)
                   → DUT top/test
run_phase:   create env/config → bind static command sequencer
              → aip_tcl_bridge::run_loop()
Tcl:         source AIP library → link_en/L0 → Config/BAR/Memory → end_test
```

AIP 分支 checkout 和发布库准备：

```sh
git clone https://github.com/Beihang-yuting/aip_core.git
cd aip_core && git checkout feat/aip-architecture-restructure
make -C dist all
export AIP_CORE=$PWD
```

用户 command/test compilation unit 内的 AIP 入口必须先出现；但该源文件本身
应放在 `pcie_tl_svt_adapter.f` 之后，因为 wrapper 会 import
`pcie_tl_pkg`/`pcie_svt_adapter_pkg`。不要单独 include
`aip_cmd.sv`/`aip_tcl_bridge.sv`：

```systemverilog
`include "aip_core_pkg.sv"
import aip_core_pkg::*;
import pcie_tl_pkg::*;
import pcie_svt_adapter_pkg::*; // TL-only 用户可删除 svt_be 字段及此 import

class pcie_aip_cmd_sqr extends uvm_sequencer;
  `uvm_component_utils(pcie_aip_cmd_sqr)
  static uvm_sequencer_base cmd_sqr;
  static pcie_tl_virtual_sequencer tl_vseqr;
  static pcie_svt_backend svt_be;
  function new(string name = "pcie_aip_cmd_sqr", uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass
```

为一次性建链、配置空间初始化或枚举注册 `` `aip_cmd_user_seq ``，不要用
要求 `count/time` 的 `` `aip_cmd_seq ``。用户 sequence 的职责是：

1. 从 `aip_cmd::get_handle("command").args_in` 读取 `link/rc/bdf/reg`；
2. 在 `svt_agent_by_link[id].virt_seqr.pcie_virt_seqr.dl_seqr` 上创建官方
   `svt_pcie_dl_service_set_link_en_sequence` 并设置 `enable=1`；
3. 等待 `link_up && ltssm_state == L0`，再启动
   `pcie_tl_cfg_wr_seq/pcie_tl_cfg_rd_seq`、BAR 或 Memory sequence；
4. 在失败时设置 `aip_cmd.status/result_out`，成功时返回明确结果。

例如，两个命令的注册形态如下（具体 wrapper 见两个拓扑集成文档）：

```systemverilog
`aip_cmd_user_seq(svt_link_up, pcie_svt_link_up_cmd_seq,
                  pcie_aip_cmd_sqr::cmd_sqr)
`aip_cmd_user_seq(ep_cfg, pcie_tl_cfg_cmd_seq,
                  pcie_aip_cmd_sqr::cmd_sqr)
```

`build_phase/connect_phase` 绑定 `pcie_aip_cmd_sqr::tl_vseqr = tl_env.v_seqr`
和 `svt_be = tl_env.backend_provider`（TL-only 时保持 `svt_be=null`），
`run_phase` 只需保持一份 objection：

```systemverilog
task run_phase(uvm_phase phase);
  phase.raise_objection(this);
  aip_tcl_bridge::run_loop();
  phase.drop_objection(this);
endtask
```

Tcl 调度模板：

```tcl
source $env(AIP_CORE)/dist/aip_init_so.tcl
svt_link_up link=RC0_EP0       ;# SVT backend：每条 physical link 重复
ep_cfg op=rd rc=0 bdf=0x0100 reg=0
ep_cfg op=wr rc=0 bdf=0x0100 reg=1 data=0x00000007
end_test drain=500
```

TL-only 模式省略 `svt_link_up`，直接运行 `ep_cfg`/BAR/Memory；SVT backend
模式则必须先让所有活动物理链进入 L0。AIP 不会自动修改
`target_auto_response`、Host memory binding、Passive Monitor 或 SVT
backend 配置，这些仍由用户 Env/config 和 HDL top 负责。

编译 AIP Tcl bridge 时追加：

```sh
vcs ... -timescale=1ns/1ps -debug_access+r+w+f \
  +incdir+$AIP_CORE +incdir+$AIP_CORE/src/sv \
  -f pcie_tl_svt_adapter.f user_dut_top.sv user_test.sv -o simv
```

## 静态契约检查

```sh
./svt_pcie_integration/sim/check_tl_svt_bridge_contract.sh
bash ./svt_pcie_integration/sim/check_svt_serial_clock_contract.sh
git diff --check
```

检查会确认 adapter package、公开 Mapper 端口和 TL-only filelist 隔离，
避免旧 topology/unified 文件被重新带回生产路径；Serial clock 检查另行
锁定三个宽度的内部时钟参数及 PIPE 隔离，只做静态检查，不代表物理建链。
