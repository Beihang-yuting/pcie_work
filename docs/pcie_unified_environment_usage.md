# PCIe environment usage

## Single control plane

`pcie_tl_env` is the only production PCIe environment.  It owns topology,
configuration-space images, BAR allocation, BDF assignment, enumeration,
completions, Memory traffic, and all project sequences.  Existing users may
continue to instantiate `pcie_tl_env` directly.  Graph-driven users publish a
`pcie_topology_cfg` plus an optional policy object before creating the same
`pcie_tl_env`; the environment performs the translation before it creates any
agent.

```text
pcie_tl_env
        |
        +-- pcie_tl_if_adapter                 (TL-only default)
        |
        +-- pcie_svt_if_adapter                (optional SVT transport)
                    |
                    +-- official svt_pcie_device_agent.tlp_mapper
                    +-- Serial/PIPE adapter supplied by the user top
```

SVT is not a second configuration or traffic environment.  The optional
adapter is selected only in a dedicated SVT filelist and does not alter the
TL-only package or existing tests.

## TL-only example

```systemverilog
pcie_tl_env_config cfg;
cfg = pcie_tl_env_config::type_id::create("cfg");
cfg.if_mode = TLM_MODE;
cfg.rc_agent_enable = 1'b1;
cfg.ep_agent_enable = 1'b1;
uvm_config_db#(pcie_tl_env_config)::set(this, "env", "cfg", cfg);
env = pcie_tl_env::type_id::create("env", this);
```

For graph-driven topologies, publish `pcie_topology_cfg` and an optional
`pcie_tl_env_config` policy under `env`, then instantiate `pcie_tl_env`.  The
same environment validates and translates the graph once before creating its
native agents.  Native `cfg` injection remains valid when no graph is supplied.

## Optional SVT adapter

将 `svt_pcie_integration/sim/pcie_tl_svt_adapter.f` 作为 source-only 基础
filelist 引入用户工程，并在创建 `env` 前安装 factory override：

该列表中的 adapter package 会导入官方 `svt_uvm_pkg`/`svt_pcie_uvm_pkg`，
当前 filelist 自带 `pcie_svt_vip_bootstrap.sv`，会在 adapter package 前
include `svt_pcie.uvm.pkg`，因此用户 prefix 默认只定义宏，不要再次 include
官方 package。`EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH` 只在官方 example
env/interconnect 使用 global shadow 时需要；真实 DUT + backend 场景可以省略。
如果外层已独立编译官方 package，才使用 `PCIE_SVT_PKG_EXTERNAL` 跳过
bootstrap。可复制的 prefix 示例和完整顺序见
`svt_pcie_integration/sim/README.md`。

```systemverilog
pcie_tl_if_adapter::type_id::set_type_override(
  pcie_svt_if_adapter::get_type());
```

用户顶层必须创建官方 SVT device agent，并将每个 agent 发布到
the matching adapter instance with the `svt_agent` config-DB key.  The Mapper
must be the handle from `svt_pcie_device_agent.tlp_mapper`; creating an
isolated `svt_pcie_tlp_mapper` is unsupported because it has no service
sequencer.  Serial lane wiring, clocks, resets, and DUT connections remain a
top-level responsibility.

## AIP Tcl sequence 编排（TL-only 与 SVT backend 共用）

AIP 的职责是把 Tcl 命令同步转发到用户 sequence；它不是 PCIe backend，也
不会自动创建 `pcie_tl_env`、修改 `link_en` 或猜测 BDF。统一的数据流如下：

```text
Tcl script
  -> aip_tcl_bridge::run_loop()
      -> `aip_cmd_user_seq(command, user_seq, static_command_sequencer)
          -> user_seq 读取 aip_cmd::get_handle(command).args_in
              -> 官方 SVT DL sequence 或 pcie_tl_* sequence
```

这里的 `aip_cmd_user_seq` 来自 AIP 分支
`feat/aip-architecture-restructure`（当前迁移提交 `f635185`）。它不要求
`count/time` 字段；sequence 自己负责参数校验、官方 sequence 的字段赋值、
错误结果和完成条件。所有 Tcl 命令都应在单一 `run_phase` objection 内执行。

### 最小公共接入骨架

在用户 command/test compilation unit 的最前面 include AIP 入口，并用一个不
承载 PCIe item 的静态 sequencer 作为命令启动锚点。该源文件本身应列在
`pcie_tl_svt_adapter.f` 之后，以便先完成 `pcie_tl_pkg`/SVT adapter package
的分析；不要把 `aip_cmd.sv` 或 `aip_tcl_bridge.sv` 单独放到 filelist 前面：

```systemverilog
`include "aip_core_pkg.sv"
import aip_core_pkg::*;
// SVT backend 工程另需：import pcie_svt_adapter_pkg::*;

class pcie_aip_command_sequencer extends uvm_sequencer;
  `uvm_component_utils(pcie_aip_command_sequencer)
  static uvm_sequencer_base cmd_sqr;
  static pcie_tl_virtual_sequencer tl_vseqr;
  static pcie_svt_backend svt_be; // 仅 SVT backend 填充，TL-only 保持 null
  function new(string name = "pcie_aip_command_sequencer",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass
```

`build_phase` 创建 `pcie_aip_command_sequencer`，`connect_phase` 绑定
`tl_env.v_seqr`；SVT 模式额外把 `tl_env.backend_provider` `$cast` 成
`pcie_svt_backend`。然后注册用户 sequence 并进入 AIP loop：

```systemverilog
// 下面两个 seq 的 body 见各拓扑集成文档；它们都通过 args_in 取参数。
`aip_cmd_user_seq(tl_cfg_access, pcie_tl_cfg_cmd_seq,
                  pcie_aip_command_sequencer::cmd_sqr)
`aip_cmd_user_seq(svt_link_up, pcie_svt_link_up_cmd_seq,
                  pcie_aip_command_sequencer::cmd_sqr)

// 还需按需要注册 tl_bar_enum/tl_mem_rw 等用户 wrapper；它们不是 AIP 内建命令。

function void connect_phase(uvm_phase phase);
  super.connect_phase(phase);
  pcie_aip_command_sequencer::tl_vseqr = tl_env.v_seqr;
  if (global_cfg.backend == PCIE_BACKEND_SVT_REAL_DUT) begin
    if (!$cast(pcie_aip_command_sequencer::svt_be,
               tl_env.backend_provider))
      `uvm_fatal("AIP", "SVT backend cast failed")
  end
  pcie_aip_command_sequencer::cmd_sqr = aip_cmd_sqr;
endfunction

task run_phase(uvm_phase phase);
  phase.raise_objection(this);
  aip_tcl_bridge::run_loop();
  phase.drop_objection(this);
endtask
```

VCS 需要同时加入 AIP include 路径和 Tcl force 所需的 debug 权限；AIP 的
`aip_core_pkg.sv` 必须是每个 compilation unit 中最先出现的 AIP 文件：

```sh
make -C "$AIP_CORE/dist" all                 # 发布库尚未生成时执行一次
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  -timescale=1ns/1ps -debug_access+r+w+f \
  +incdir+$AIP_CORE +incdir+$AIP_CORE/src/sv \
  -f svt_pcie_integration/sim/pcie_tl_svt_adapter.f \
  user_top.sv user_test.sv -o simv
```

### TL-only：不做 link training

TL-only 的 `pcie_tl_env` 没有 SVT agent，Tcl 直接启动配置空间、BAR 或
Memory sequence；不要人为添加 `svt_link_up`：

```tcl
source $env(AIP_CORE)/dist/aip_init_so.tcl
tl_cfg_access op=rd rc=0 bdf=0x0100 reg=0
tl_cfg_access op=wr rc=0 bdf=0x0100 reg=1 data=0x00000007
tl_bar_enum ep=0
tl_mem_rw op=wr rc=0 addr=0x80000100 len=4
tl_mem_rw op=rd rc=0 addr=0x80000100 len=4
end_test drain=500
```

`tl_cfg_access` wrapper 应把 `rc` 解析成
`tl_env.v_seqr.rc_seqr_arr[rc]`，再创建 `pcie_tl_cfg_wr_seq` 或
`pcie_tl_cfg_rd_seq`；`reg` 是 DWORD 编号，`bdf` 是 `pcie_device_cfg.bdf`。
TL-only 的成功门禁是 sequence `status == PCIE_RW_OK` 和 scoreboard 清洁，
不需要等待 SVT `link_up/L0`。

### SVT backend：先 L0，再做 Config/BAR/Memory

`PCIE_BACKEND_SVT_REAL_DUT` 下，`pcie_tl_env` 仍是唯一控制面，但每条物理
链路必须由用户 sequence 在 SVT agent 的
`pcie_virt_seqr.dl_seqr` 上启动一次官方 link-enable sequence：

```systemverilog
svt_pcie_dl_service_set_link_en_sequence en;
en = svt_pcie_dl_service_set_link_en_sequence::type_id::create("link_en");
en.enable = 1'b1; // AIP 不会代填
en.start(pcie_aip_command_sequencer::svt_be
         .svt_agent_by_link[link_id].pcie_virt_seqr.dl_seqr);
wait (pcie_aip_command_sequencer::svt_be
      .svt_status_by_link[link_id].pcie_status.pl_status.link_up);
wait (pcie_aip_command_sequencer::svt_be
      .svt_status_by_link[link_id].pcie_status.pl_status.ltssm_state
      == svt_pcie_types::L0);
```

四 RC、Switch 五链路以及 Scalar Serial 的完整绑定例子分别见
[`pcie_svt_4rc_dut_ep_integration.md`](pcie_svt_4rc_dut_ep_integration.md) §6.1
和 [`pcie_svt_switch_1usp_4dsp_integration.md`](pcie_svt_switch_1usp_4dsp_integration.md)
§6.1。Tcl 的通用顺序是：

```tcl
source $env(AIP_CORE)/dist/aip_init_so.tcl
svt_link_up link=RC0_EP0       ;# 每条 physical link 重复一次
svt_link_up link=RC1_EP1
...
tl_cfg_access op=rd rc=0 bdf=0x0100 reg=0
tl_bar_enum ep=0
tl_mem_rw op=wr rc=0 addr=0x80000100 len=4
end_test drain=500
```

每个命令返回时才允许进入下一阶段；如果任一 `link_up` command 返回非零
status，Tcl 应立即 `error [aip_read_result]`，不要继续发 Config TLP。AIP
不会替代 backend 的 `enable_svt_monitor`、`target_auto_response` 或
Host-memory 绑定策略；这些仍在 Env/config build 阶段完成。

### 真实 DUT + Serial 的 `pcie-work` filelist 顺序

外层 VCS 输入必须按“用户 prefix → source-only adapter → DUT top → test”
排列。`pcie_tl_svt_adapter.f` 不能被 DUT/test 反向提供 package 或 SVT HDL
model；它内部的有效顺序如下：

```text
1. 环境变量：DESIGNWARE_HOME、PCIE_SVT_ROOT、HOST_MEM_ROOT
2. 用户 prefix：只定义 SVC_RANDOM_SEED_SCOPE 等宏
3. pcie_tl_svt_adapter.f 中的 TL source/package
4. pcie_svt_vip_bootstrap.sv
     -> svt_pcie.uvm.pkg
          -> svt_pciesvc_source.svi
               -> pciesvc_global_shadow.svp
               -> pcie_device_agent_svt/.../svt_pcie_single_port_device_agent_hdl.svp
5. pcie_svt_adapter_pkg.sv
6. 用户 DUT top 和 UVM test
```

bootstrap 需要以下两个定义来启用 R-2020.12 source-map，并把官方 `.svp`
模型加载到当前 VCS 编译库：

```text
+define+DESIGNWARE_INCDIR=$DESIGNWARE_HOME
+define+SVT_LOADER_UTIL_ENABLE_DWHOME_INCDIRS
```

仅添加 `+incdir+$PCIE_SVT_ROOT/sverilog/include` 不足以解决
`Cannot find cell in liblist`。若外层流程明确绕过 bootstrap，才需要改用
显式库搜索：

```text
+libext+.v+.sv+.vp+.svp
-y $PCIE_SVT_ROOT/verilog/src/vcs
-y $PCIE_SVT_ROOT/sverilog/src/vcs
-y $PCIE_SVT_ROOT/pcie_device_agent_svt/sverilog/src/vcs
```

Serial DUT top 内的 include 顺序也不能调换。Serial interface 和 lane 映射宏
必须先于 HDL agent 声明宏：

```systemverilog
`include "import_pcie_svt_uvm_pkgs.svi"
`include `SVC_SOURCE_MAP_SUITE_UTIL_V(pcie_svc,PCIE,latest,svc_util_parms)
`include `SVC_SOURCE_MAP_SUITE_MODEL_MODULE(pcie_svc,Include,latest,pciesvc_parms)
`include "pcie_svt_serial_port_if.sv"
`include "pcie_svt_serial_adapter.sv"
`include "pcie_svt_hdl_agent_macros.svh"
```

`import_pcie_svt_uvm_pkgs.svi` 是 SVT 安装提供的导入 helper，不是本仓库文件；
请确保 `$PCIE_SVT_ROOT/sverilog/include`（或内网安装的实际 include 目录）在
include 搜索路径中，无需复制该 helper。

其中 `pcie_svt_serial_port_if.sv` 提供 `pcie_svt_serial_port_if` 类型，
`pcie_svt_serial_adapter.sv` 提供 `PCIE_SVT_MAP_SERDES_X4/X8/X16`；最后才
include `pcie_svt_hdl_agent_macros.svh` 并调用 `PCIE_SVT_DECLARE_HDL_AGENT_Xn`。

当前仓库的 Serial 声明宏使用 PCIe 5.0 参数，所以未修改宏时需要额外选择：

```text
+define+SVT_PCIE_ENABLE_GEN5
+define+SVT_PCIE_ENABLE_SERDES_ARCH
```

若工程分支已把 Serial 声明宏改成 PCIe 4.0，则使用
`+define+SVT_PCIE_ENABLE_GEN4`；不要把 `SVT_PCIE_ENABLE_PIPE5` 加到 Serial
filelist，PIPE5 只适用于 PIPE 物理层。adapter filelist 已提供
`SVT_PCIE_ENABLE_10_BIT_TAGS` 以及 8G/16G SVC 模型选择。

单链路 Serial DUT 的命令模板如下；多链路时将容量宏和用户 top 按实际拓扑
替换：

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

如果外层已经编译过官方 package，输入顺序改为“外层 package prefix →
`+define+PCIE_SVT_PKG_EXTERNAL` → adapter filelist → DUT top/test”，且官方
package 只能出现一次。无论采用哪种模式，都不能在 DUT top 末尾再补
`svt_pcie.uvm.pkg`。

每个静态 `svt_pcie_single_port_device_agent_hdl` 还必须在 HDL 静态
`initial` 块调用 `update_if_variables`，由官方 API 发布
`link_<link_id>_vif_<port_id>`。SVT RC 使用 port `4'h0`，SVT EP 使用
`4'h1`；对应的 key 必须与 `pcie_link_cfg.vif_key` 完全一致，否则 backend
会在 build 阶段报告缺少 Unified VIF。

该 source-only filelist 不包含可独立运行的占位 test/top；用户必须追加自己
的 DUT top、SVT HDL agent、Serial/PIPE 物理连接和 test。桥接层不会自动启动
SVT 配置或 traffic sequence。TL sequence 仍然是 Config/BAR/enum/Memory
请求的唯一来源，SVT 只提供 transport endpoint。

## DPU-common integration

`pcie_dpu_integration` is optional and independent.  Its generic package
consumes frozen `dpu-common` snapshots and projects device/BAR/BDF data into
the native TL policy.  It does not import SVT packages, so the TL/DPU
filelists remain usable without a Synopsys installation.  A project-specific
system environment can apply that projected policy before constructing the
same `pcie_tl_env`; no unified or backend-selection environment is required.

`dpu_common` 只描述逻辑 Host、Segment、PF/VF、BDF 和 BAR。Host 不是 RC、EP
或 Switch，也不携带 Root/link 属性；这些物理关系必须在 `pcie_work` 侧
显式声明。这样同一份 DPU snapshot 可以被 TL-only、SVT Serial 或后续 PIPE
后端复用，而不会把 PCIe 物理假设反向写入 DPU 配置仓库。

### DPU snapshot 到 PCIe policy

典型调用顺序如下，`freeze()` 成功后 snapshot 是 BDF/BAR 的唯一权威来源：

```systemverilog
dpu_device_snapshot snapshot;
pcie_dpu_root_binding_cfg root_cfg;
pcie_global_cfg projected;
string errors[$];

// snapshot 由 dpu_common resolver 产生并冻结；这里不重新分配 BDF/BAR。
root_cfg = pcie_dpu_root_binding_cfg::type_id::create("root_cfg");
string why;
void'(root_cfg.bind_domain_to_root(0, 0, 0, why)); // Host0/Segment0 -> Root0

if (!adapter.project_with_root_bindings(
        snapshot, resource_snapshot, topology_cfg, attachments,
        root_cfg, projected, errors)) begin
    // 创建 pcie_tl_env 前处理 errors；错误不能延迟到运行期。
end
```

`pcie_dpu_root_binding_cfg` 检查逻辑域到 Root 的唯一性、Root 数量和
snapshot 中实际使用的 Host/Segment 是否一致。PF/VF 到 Endpoint/link 的
物理挂接由 `pcie_dpu_attachment_cfg` 单独负责；因此“Host 数量”不会被
错误地当成“RC 数量”。

投影出的 `pcie_device_cfg.root_index` 不只是审计字段：当调用方把
`pcie_global_cfg` 发布给 `pcie_tl_env` 时，环境会按 direct 链路或 Switch
DSP 的物理顺序生成 `ep_root_by_index[]`，随后用该 Root 选择对应的
tag/FC/ordering/config manager。这样
即使 DPU function 的声明顺序与链路顺序不同，EP 仍不会误用另一条 Root
的资源；Switch DSP 的 Root 元数据若与 `dsp_owner[]` 不一致会在 build 阶段
直接报错。

### 多 Root 共享 Host memory

启用统一内存时，Root-specific manager 也要显式绑定。下面的例子对应
Root0 → Host0、Root1 → Host1、Root2 → Host0：

```systemverilog
pcie_tl_env_config cfg;
host_mem_manager host0_mem, host1_mem;
string why;

cfg = pcie_tl_env_config::type_id::create("cfg");
cfg.use_unified_mem = 1'b1;
host0_mem = new("host0_mem"); host0_mem.set_host_id(0);
host1_mem = new("host1_mem"); host1_mem.set_host_id(1);

void'(cfg.bind_host_memory(0, 0, host0_mem, why));
void'(cfg.bind_host_memory(1, 1, host1_mem, why));
void'(cfg.bind_host_memory(2, 0, host0_mem, why));
```

多 Root 下每个 Root 都必须有显式绑定，不能回退到单一
`config_db("host_mem")`，也不能由环境偷偷创建私有 manager。相同 manager
被多个 Root 引用时，PREMAP backing memory 在一次环境中只分配一次；已经由
VIO/DPU 初始化的 manager 也不会被 `pcie_tl_env` 重新 `init_region()`。
单 Root 仍兼容旧的 `config_db("host_mem")` 注入；如果单 Root 使用显式
绑定，则显式绑定优先。EP 的 `dev_mem[i]` 仍可独立通过
`config_db("dev_mem_i")` 注入。

`pcie_work` 可以完全脱离 `dpu_common` 使用：直接创建
`pcie_tl_env_config`/`pcie_tl_env` 即可。集成 DPU 时只需额外编译
`pcie_dpu_integration`，设置 `DPU_COMMON_ROOT` 指向独立仓库根目录，并在
创建 TL 环境前执行 snapshot → policy 投影；两种使用方式互不污染。

## Supported boundaries

- Existing `pcie_tl_vip` classes, sequences, and TL filelists remain stable.
- SVT R-2020.12 Serial integration is available through the dedicated adapter
  filelist; PIPE is reserved for a later adapter implementation.
- The former `pcie_tl_custom_env` topology wrapper has been removed.  Its
  validation/translation behavior now belongs to `pcie_tl_env`, so there is
  only one production TL environment.  Real-DUT integration should provide
  its own HDL top while reusing the adapter package and official SVT agent
  interfaces.

## 宏定义总览（编译期 `+define+`）

本节汇总全仓库编译期宏：每个宏门控什么、在哪里开启。运行期 plusarg
（`+PCIE_TOPOLOGY=`、`+PCIE_GEN=`、`+TAG_BIT=`、`+CAPACITY_CASE=` 等）不属于
编译宏，见 `pcie_tl_vip/docs/PCIe_TL_VIP_User_Guide.md`。

### 项目功能宏

| 宏 | 门控内容 | 在哪里开启 |
|---|---|---|
| `PCIE_COSIM_ENABLE` | `pcie_tl_func_manager` / `pcie_tl_config_proxy` 中面向 QEMU-VCS bridge 的 DPI-C 导出（拓扑导出、VF 事件、BAR base 同步）。未定义时相关入口为安全空操作，TL 行为不变 | 仅 QEMU_VCS cosim 平台的组合构建（其 Makefile `vcs-vip` 等目标 `+define`）。TL-only 回归与 SVT 独立集成**不要**定义；无 bridge 库时定义它也能编译（DPI 运行期解析），但一旦调到 DPI 会运行时报错 |
| `PCIE_TOPO_EP_X16` / `PCIE_TOPO_EP_2X8` / `PCIE_TOPO_SWITCH_1X16_4X4` | 拓扑档位：推导 `pcie_svt_hdl_slot_cfg.svh` / `pcie_unified_limits.svh` 中链路数、HDL agent 槽位等容量默认值 | 各集成 filelist 按目标拓扑三选一（`pcie_tl_svt_adapter.f` 默认 `EP_X16`）；与运行期 `+PCIE_TOPOLOGY=` 档位保持一致 |
| `PCIE_PIPE_GEN4` / `PCIE_PIPE_GEN5` | Gen 档位 → PCIe/PIPE spec 版本联动（`pcie_svt_hdl_agent_macros.svh`、`pcie_tl_svt_pipe_topology.sv`）。无档位宏 = PCIe 3.0 + PIPE 4.3；GEN4 = 4.0 + 4.4；GEN5 = 5.0 + 5.1 且走 PIPE5 互连宏 | PIPE 集成 filelist / 顶层。GEN5 还需同时开官方 `SVT_PCIE_ENABLE_GEN5` / `SVT_PCIE_ENABLE_PIPE5` / `EXPERTIO_PCIESVC_INCLUDE_32G`（见 `svt_pcie_integration/sim/README.md`） |
| `PCIE_SVT_HDL_PHY_PIPE` | SVT HDL agent 的 PHY 形态：默认 SERDES（Serial），定义后切 PIPE、DUT 直接对接逐 lane PIPE 信号 | `pcie_tl_svt_pipe*.f`；Serial 集成不定义 |
| `PCIE_SVT_PIPE_MACRO_X16` | `pcie_tl_svt_pipe_macro_top` 的 x16 宽度门禁（DECLARE_X16 + CROSS_X16），默认 x4 | `pcie_tl_svt_pipe_macro.f` 需要 x16 时 |
| `PCIE_USE_SVT_PEER` | `pcie_unified_limits.svh` 中 SVT peer-traffic 模式的容量分支 | peer-traffic 场景 filelist |
| `PCIE_SVT_ENV_MAX_NUM_LINKS` / `PCIE_SVT_ENV_MAX_HDL_AGENTS` / `PCIE_SVT_ENV_REQUIRED_HDL_AGENTS` | 容量上限覆盖；不定义时按拓扑档位宏自动推导（`ifndef` 默认） | 仅需偏离默认容量时在 filelist 覆盖 |
| `PCIE_SVT_PKG_EXTERNAL` | 跳过 `pcie_svt_vip_bootstrap.sv` 的官方 SVT 包编译 | 外部集成流程已在别处编译 `svt_pcie.uvm.pkg` 时，避免 package 重复定义 |

### Synopsys 官方宏（原样透传给 SVT VIP）

| 宏 | 作用 | 在哪里开启 |
|---|---|---|
| `DESIGNWARE_INCDIR=$DESIGNWARE_HOME` + `SVT_LOADER_UTIL_ENABLE_DWHOME_INCDIRS` | SVT loader 定位安装目录并启用其内部 incdir | 所有编译 SVT 包的 filelist（adapter/formal/pipe/peer 已带） |
| `SVT_PCIE_ENABLE_10_BIT_TAGS` | SVT 10-bit tag 能力 | 需要 10-bit tag 的入口（adapter.f 已带） |
| `SVT_PCIE_ENABLE_GEN4` / `SVT_PCIE_ENABLE_GEN5` / `SVT_PCIE_ENABLE_PIPE5` | SVT 速率/PIPE5 能力开关 | 对应 Gen 档位的 filelist |
| `EXPERTIO_PCIESVC_INCLUDE_8G/16G/32G` | 包含对应速率的 SVC 模型 | 与 Gen 档位配套 |
| `EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH` / `SVC_RANDOM_SEED_SCOPE` | 层次锚：前者指向顶层 `pciesvc_global_shadow` 实例（官方 example env/interconnect 需要），后者把 SVT 随机种子锚定到顶层变量以复现随机序列 | **均可选**。formal/pipe filelist 已指向各自 top；自研 top 不需要官方 example env 时可不定义（种子回退 `$random`），详见 `pcie_svt_vip_bootstrap.sv` 头注释 |
| `SVT_PCIE_ENABLE_PIPE5_PCLK_AS_PHY_OUTPUT_MODE` | PIPE5 pclk 由 PHY 输出的时钟模式 | Gen5/PIPE5 拓扑需要该时钟模型时 |

### 已清理的历史宏

- `PCIE_SVT_AVAILABLE`：曾守卫"无 SVT 时空翻译单元"的适配器测试；该批测试
  在环境清理（`aeac5ae`）中删除后宏残留、全仓库零引用，现已从
  `pcie_tl_svt_adapter.f` 移除。请勿再使用。
