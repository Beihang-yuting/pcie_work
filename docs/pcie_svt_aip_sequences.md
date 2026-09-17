# 可选 AIP Tcl PCIe sequence

本层为用户提供可复用的建链、配置空间和内存访问 sequence。它不创建 env，
不自动注册命令，不按 Host/RC 编号猜测访问目标，不修改 DUT/VIP 的复位。
使用者自行选择命令名，并将其注册到类型匹配的真实 sequencer。

源码：`svt_pcie_integration/uvm/aip/pcie_svt_aip_seqs.sv`。

## 1. 可选编译与用户绑定

仅在需要 Tcl 控制时定义 `+define+PCIE_ENABLE_AIP_CMDS`，增加本项目
`svt_pcie_integration/uvm/aip` 与 AIP 的 include 路径，并按 AIP 要求链接
DPI 依赖。生产 adapter filelist 不引入 AIP。

用户 command compilation unit 应先在 package/module 外 include AIP 统一
入口，然后在 TL/SVT 类型可见的作用域包含本文件；不要将 package 声明包含
到 module 内，也不要先单独 include AIP 的内部 `aip_cmd.sv`。

```systemverilog
`ifdef PCIE_ENABLE_AIP_CMDS
  `include "aip_core_pkg.sv"
`endif

// 用户自己的 command/test 作用域；先编译 TL/SVT package。
`include "pcie_svt_aip_seqs.sv"
```

本文件禁用时不引用 UVM/AIP/SVT 类型。`AIP_CORE_PKG_SV` 只是 AIP 的
include guard，不能代替功能开关，也不能探测预编译库是否可用。用户自己的
注册、句柄声明和 bridge 调用也应放在功能开关内。

提供以下类型，注册动作仍由用户执行：

| sequence 类型 | 注册目标 | 职责 |
|---|---|---|
| `pcie_aip_link_up_seq` | 对应 SVT agent 的真实 DL sequencer | 显式 link enable，可等待 L0 |
| `pcie_aip_cfg_rd_seq` / `pcie_aip_cfg_wr_seq` | 对应 RC 的 `uvm_sequencer #(pcie_tl_tlp)` | Config Read/Write 并等待 Completion |
| `pcie_aip_mem_rd_seq` / `pcie_aip_mem_wr_seq` | 对应 `uvm_sequencer #(pcie_tl_tlp)` | Memory Read / posted Write |

```systemverilog
// 用户 command 作用域：只保存借用的真实 sequencer，不创建额外空 sequencer。
class my_context;
  static uvm_sequencer_base rc0_dl_sqr;
  static uvm_sequencer_base rc0_tl_sqr;
  static uvm_sequencer_base rc1_tl_sqr;
endclass

`aip_cmd_user_seq(rc0_link_up, pcie_aip_link_up_seq, my_context::rc0_dl_sqr)
`aip_cmd_user_seq(rc0_cfg_rd, pcie_aip_cfg_rd_seq, my_context::rc0_tl_sqr)
`aip_cmd_user_seq(rc0_cfg_wr, pcie_aip_cfg_wr_seq, my_context::rc0_tl_sqr)
`aip_cmd_user_seq(rc0_mem_rd, pcie_aip_mem_rd_seq, my_context::rc0_tl_sqr)
`aip_cmd_user_seq(rc0_mem_wr, pcie_aip_mem_wr_seq, my_context::rc0_tl_sqr)
`aip_cmd_user_seq(rc1_mem_rd, pcie_aip_mem_rd_seq, my_context::rc1_tl_sqr)
`aip_cmd_user_seq(rc1_mem_wr, pcie_aip_mem_wr_seq, my_context::rc1_tl_sqr)
```

命令名不必包含 `rc`，也可用用户自己的 Host/端口名。同一 seq 类型可注册
多次，命令参数通过 `get_handle(get_name())` 获取，实际请求通过
`get_sequencer()` 发出，不会由隐藏的静态“当前 RC/地址”覆盖用户选择。
这里不接受 `host/rc/link` 选择参数：目标已经由命令绑定确定。

建链还需要同一目标的 status，用于验证 L0。用户在 agent 创建完成后调用
`pcie_aip_link_binding::bind_agent(agent, status)`，并将命令注册到该 agent 的
`agent.virt_seqr.pcie_virt_seqr.dl_seqr`。这不是为另一个空 command sequencer
绑定状态；注册目标必须与绑定函数获取的实际 DL sequencer 一致。
用户持有 agent/status，它们需在整个调用期间有效，不得在运行中改绑。

以 4RC 文档的 `pcie_svt_backend` 为例，下列代码放在用户 test 内，并在该
作用域 import `pcie_svt_adapter_pkg::*`。这里只演示 RC0 和 RC1 的绑定；
RC2/RC3 按同样方式增加独立句柄和注册名。前提是按 4RC 文档创建了四个
连续 TL RC agent；稀疏 Root 拓扑必须重新确认数组下标与物理链的对应关系。

```systemverilog
`ifdef PCIE_ENABLE_AIP_CMDS
// connect 自底向上执行，子 env 已完成创建与连接；不能在父 test 的 build
// 中提前读取 backend_provider，也不能只看 $cast 成功就假设句柄非空。
function void connect_phase(uvm_phase phase);
  pcie_svt_backend svt_be;
  super.connect_phase(phase);
  if (tl_env == null)
    `uvm_fatal("AIP_BIND", "tl_env is null")
  if (!$cast(svt_be, tl_env.backend_provider) || svt_be == null)
    `uvm_fatal("AIP_BIND", "pcie_svt_backend is not ready")
  if (!svt_be.svt_agent_by_link.exists("RC0_EP0") ||
      !svt_be.svt_status_by_link.exists("RC0_EP0"))
    `uvm_fatal("AIP_BIND", "RC0_EP0 agent/status is missing")
  if (!pcie_aip_link_binding::bind_agent(
        svt_be.svt_agent_by_link["RC0_EP0"],
        svt_be.svt_status_by_link["RC0_EP0"]))
    `uvm_fatal("AIP_BIND", "RC0_EP0 DL/status binding failed")
  my_context::rc0_dl_sqr = svt_be.svt_agent_by_link["RC0_EP0"]
                            .virt_seqr.pcie_virt_seqr.dl_seqr;
  if (tl_env.v_seqr == null)
    `uvm_fatal("AIP_BIND", "TL virtual sequencer is missing")
  if (tl_env.v_seqr.rc_seqr_arr.size() != 4)
    `uvm_fatal("AIP_BIND", "expected four contiguous TL RC sequencers")
  my_context::rc0_tl_sqr = tl_env.v_seqr.rc_seqr_arr[0];
  my_context::rc1_tl_sqr = tl_env.v_seqr.rc_seqr_arr[1];
  if (my_context::rc0_tl_sqr == null || my_context::rc1_tl_sqr == null)
    `uvm_fatal("AIP_BIND", "registered TL sequencer is null")
endfunction

// 用户持有 objection；Tcl end_test 后 bridge 返回，再结束 run phase。
task run_phase(uvm_phase phase);
  phase.raise_objection(this);
  aip_tcl_bridge::run_loop();
  phase.drop_objection(this);
endtask
`endif
```

以上是替换原 test 相应 phase 的模板，不要在同一个类重复定义 phase。
使用新库时也应移除旧手工 wrapper：4RC 文档里的旧 wrapper 恰好也名为
`pcie_aip_link_up_seq`，不能与本库同名类一起编译。旧接口的 `reg/link/rc`
参数与新接口的 `offset`、按命令绑定目标的规则不兼容。

双 SVT 的完整可执行示例见
[`pcie_svt_aip_cmd_test.sv`](../svt_pcie_integration/tests/pcie_svt_aip_cmd_test.sv)：
它直接持有 official env 的 RC/EP agent，因此绑定方式不同，但调用的是同一
`bind_agent()` 和通用 sequence。生产 4RC backend 的 env/config/HDL 仍按
[4RC 集成文档](pcie_svt_4rc_dut_ep_integration.md)完成，命令层不会代建环境。

Config/Memory seq 直接构造确定字段的 TL 请求，交给现有 TL driver 分配 Tag、
编码并经 SVT backend 发送，沿用原有 Completion 回写路径。不要把这些 TL
sequence 直接注册到原生 SVT TLP sequencer，二者 item 类型不同。
Config 由 RC 发起，不支持注册成 EP→RC 配置访问。Memory 可双向，但前提是
两端已有响应路径：EP→RC 需要正确绑定的 Root Host memory 和 responder；
本项目双 SVT TL env 的 EP Completion 分派也依赖 `ep_auto_response=1`。
这是拥有 TL EP agent 的双 SVT 用法，真实 DUT EP 场景仍按 4RC 文档关闭
额外的 EP 自动响应，不能用软件 responder 代替 DUT。

本库不自动分配 Bus 号、枚举 BAR、打开 Command 的 Memory Space/Bus Master
位、配置 Switch 地址窗口或分配 Host buffer。访问地址必须已由用户环境建立
有效路由；测试中的 EP sparse backing 接受某个地址，不代表真实 DUT 也会接受。

## 2. 参数解析规则

一条命令由空白分隔的 `key=value` 组成。数字仅接受无符号十进制或 `0x`
十六进制，不经 32 位整数中转解析 64 位地址；payload 单独用无 `0x` 前缀的
连续十六进制字节串。参数名区分大小写。

未知键、重复键、缺失必填值、非法字符、负数、溢出或冲突组合均在发包前
拒绝。`fisrtbe` 等拼写错误不会静默忽略，也不会把无效地址默认为 0。
写数据必须精确匹配长度，不能依赖旧基础 seq 的补零/截断行为。

每次调用有独立参数对象和实际请求 `issued_tlp`，静态绑定只保存目标关联，
不保存可变的“本次访问参数”。不同命令可绑定不同目标；AIP 同名命令共享
命令句柄，仍禁止同名并发。参数对象独立不等于 AIP 同名调度天然线程安全。

建链和访问的完成/超时竞争也按本次 sequence 实例隔离：一条命令完成时只
取消自己的期限分支，不能终止另一命令的建链或 Completion 等待。多个实例
并发时不能用类方法内的具名 `disable` 收尾，它可能影响同一方法的其他实例。

### 2.1 建链

| 参数 | 默认值 | 约束 |
|---|---|---|
| `enable` | `1` | `0/1`；设置官方 link-enable sequence 的 enable |
| `wait_l0` | `1` | `0/1`；若 enable=0，需显式设 wait_l0=0 |
| `timeout_ns` | `1000000` | 正整数，有界覆盖官方 sequence 与 L0 等待 |

```tcl
rc0_link_up timeout_ns=1000000
```

SVT reset 必须已释放，DUT reference clock、复位、PHY-ready 和 LTSSM 控制
由用户管理，详见 [4RC 复位说明](pcie_svt_4rc_dut_ep_integration.md#23-serial-复位与建链前置条件)。
双 active SVT 测试中两端都需 enable：可先分别调用 `wait_l0=0`，再确认双方
L0；真实 DUT 场景只对 SVT 端执行，DUT 自己控制训练。

使用已支持“逐命令 `wait`”的新 AIP 版本时，也可让 sequence 在后台继续
等待 L0，而 Tcl 只等待启动确认：

```tcl
rc0_link_up enable=1 wait_l0=1 timeout_ns=1000000 wait=0
# 返回 status=0 / STARTED: rc0_link_up；下一条未写 wait 的命令仍默认等待完成。
```

`wait` 由 AIP 调度层校验并剥离，不是本库参数；旧 AIP 未实现此功能时不能
直接添加它。`wait=0` 与 `wait_l0=0` 不同：前者不等待整个 sequence 返回，
后者改变 sequence 内部是否等待 L0。后台启动不代表链路就绪，依赖它的
配置访问仍需先确认链路；sequence 自身的 `timeout_ns`/FATAL 继续有效。
UCLI 停住时仿真也停住，需要下一条命令或 `run` 推进后台工作。

### 2.2 配置空间

| 参数 | 默认值 | 含义/约束 |
|---|---|---|
| `bdf` | 必填 | 16 位目标 BDF |
| `offset` | 必填 | 0..0xffc 的 DWORD 对齐字节偏移；内部转为 offset>>2 |
| `data` | 写必填，读禁止 | 32 位写入值；按 PCIe little-endian 进入 payload |
| `first_be` | `0xf` | 非零 4 位字节使能；不接受 Config 的 last_be |
| `type1` | `0` | `0/1`；桥后设备按真实拓扑选择，不能无条件用 Type0 |
| `requester_id` | `0` | 16 位请求者 BDF，用户应设置为实际来源；不从命令名推导 |
| `timeout_ns` | `50000` | 正整数，覆盖仲裁、发送及 Completion 等待 |
| `tc/relaxed/no_snoop` | `0` | Config 合法模式只接受 0，不制造非法配置请求 |

```tcl
rc0_cfg_rd bdf=0x0100 offset=0x000 requester_id=0x0000
rc0_cfg_wr bdf=0x0100 offset=0x004 data=0x00000007 first_be=0x3
```

第二例只写 Command 的低两个字节，避免同时写到 Status 的 W1C 字段。
配置写成功表示收到了成功 Completion，不表示已额外回读寄存器；检查写入
结果应访问允许回读、语义明确的寄存器，不能无条件比较只写或 W1C 字段。
Config Read 的 `data` 返回完整 4 字节，`value` 返回该 DWORD 的小端数值，
例如 `data=44332211 value=0x11223344`。即使 `first_be!=0xf` 也不压缩结果；
未使能字节不可作为有效数据比较，应按 BE 生成 mask 后比较 `value`。

### 2.3 内存访问

| 参数 | 默认值 | 含义/约束 |
|---|---|---|
| `addr` | 必填 | 完整 64 位字节地址；非零高 32 位自动选择 4DW header |
| `is_64bit` | 按地址自动 | 可显式校验头格式，但必须与地址范围一致：低于4GB为0，高地址为1 |
| `bytes` | 与 length_dw 二选一 | 实际字节数 1..4096，地址可非对齐，自动计算 BE/DWORD 长度；仍受线长/边界限制 |
| `length_dw` | 与 bytes 二选一 | 实际 DWORD 数 1..1024，不使用线上的 0 编码表示法 |
| `first_be` | raw 默认 0xf | 仅 length_dw 模式可指定 |
| `last_be` | raw 单 DW 为0，否则0xf | 仅 length_dw 模式可指定，遵守长度与连续性约束 |
| `data` | 写必填，读禁止 | 地址递增顺序的 hex 字节串，不是整数 |
| `requester_id` | `0` | 16 位请求者 BDF；EP requester 应显式配置 |
| `tc` | `0` | 0..7；应与真实链路 VC/TC 配置匹配 |
| `relaxed/no_snoop` | `0` | `0/1`，显式设置对应 TLP 属性 |
| `timeout_ns` | `50000` | 正整数，包含发送等待；读还等待 Completion |
| `mps_bytes/mrrs_bytes` | `256/512` | 128/256/512/1024/2048/4096；仅本命令校验上限，不配置链路 |

```tcl
# 字节模式：写5字节，自动计算 BE。
rc0_mem_wr addr=0x180004001 bytes=5 data=1122334455
rc0_mem_rd addr=0x180004001 bytes=5

# raw 模式：完整8字节 payload，禁用位置仍占据 payload 字节。
rc0_mem_wr addr=0x180004000 length_dw=2 \
    first_be=0xe last_be=0x3 data=0011223344556677
rc0_mem_rd addr=0x180004000 length_dw=2 first_be=0xe last_be=0x3
```

字节模式禁止再指定 `first_be/last_be`，避免两组参数互相覆盖。raw 模式
要求地址 DWORD 对齐，payload 长度恰为 `length_dw*4`。读结果按有效地址
顺序返回 BE 使能的字节，不将禁用 lane 当作有效数据。
raw 模式的支持范围为：单 DW 的 `last_be=0`、`first_be` 非零且连续；
QW 对齐的 2DW 请求允许首尾任意非零 BE；其余多 DW 请求的 `first_be`
限 `8/c/e/f`、`last_be` 限 `1/3/7/f`，保证与中间有效字节连续。
Memory 请求的地址高 32 位为零时必须使用 3DW 头，非零时使用 4DW 头。
显式 `is_64bit` 不用于制造格式不匹配请求；低地址配1和高地址配0都会拒绝。

第一版不自动拆包：按完整线上的 DWORD 跨度检查 4KB 边界和 MPS/MRRS，
并拒绝 64 位地址范围溢出。提高命令里的 MPS/MRRS 不会改变 DUT/VIP 配置，
必须由用户保证与实际协商/配置一致。部分协议允许的特殊 BE/零长度请求不
属于此常用合法访问接口，未开放组合应明确拒绝。

超时参数的单位统一为 ns，接受范围为 1..1,000,000,000；不接受混杂的
`1us` 字符串。Tag 由 TL driver 管理，不开放手填 tag；Poison、ECRC/LCRC
注错、ATS/Prefix 等异常或扩展流量不在本常用访问接口内。
RC driver 还有独立的 Completion 期限 `pcie_tl_env_config.cpl_timeout_ns`
（默认 50000ns）。调大命令 `timeout_ns` 不会同步修改 driver；慢 DUT 应在
构建环境时一起配置 driver 期限，不能期待命令参数覆盖底层超时。

## 3. 返回值与错误路径

下列返回值指默认同步调用。`wait=0` 只返回启动确认，后台普通业务错误会
写后台完成日志，不补发 Tcl 结果；需要捕获参数/访问结果时应保持 `wait=1`。

- 参数错误：`status!=0`，结果包含命令名和错误原因，不发出请求。
- 正常非 posted Completion：结果报告 Completion 状态；读还返回字节数据。
- posted Memory Write：结果为 `POSTED_SENT`，只表示发送完成；确认 DUT/
  Host memory 内容必须再做读回或 testbench backing-memory 检查。
- 事务总超时：终止仿真，防止强杀 seq 后遗留 pending Tag/driver 状态，继续
  发包却把旧 Completion 误认为新请求。必须关闭外层 AIP activity watchdog，
  禁止对活动事务使用 `kill_seq`，由本库总超时和 test 全局期限负责终止。

Tcl 必须检查每次命令的状态，不能只看 `seq.start()` 返回。AIP 不保证业务
失败自动抛 Tcl error；例如：

```tcl
# 在首次命令前设置；ack 预算应大于本次 sequence timeout_ns 并预留桥接开销。
set ::aip_ack_timeout_ns 5000000
set_cmd_watchdog ns=0
if {[aip_check_status] != 0} { error [aip_read_result] }
rc0_mem_rd addr=0x180004001 bytes=5 timeout_ns=100000
if {[aip_check_status] != 0} { error [aip_read_result] }
puts [aip_read_result]
```

测试脚本还检查本次 command ack ID，避免 no-ack 后读取陈旧结果。序列
超时、AIP 无活动 watchdog、Tcl ack 窗口是三个不同限制；双 SVT 测试会将
ack 设为5ms、关闭 AIP 无活动 watchdog，并保留 sequence 自身的有界超时。
这不改变用户 test 对 reference clock、reset、PHY ready 和全局仿真期限的责任。

## 4. 定向验证入口

`svt_pcie_integration/sim/check_svt_aip_cmd.sh` 在 53 上编译并运行专用双
SVT Serial 顶层。环境要求与 [AIP 建链诊断](pcie_svt_aip_link_diagnostic.md)
相同；不使用真实 DUT，不触发全量回归。

测试必须区分：无 AIP 依赖的禁用编译、参数错误不发包、真实双端 L0、
RC→EP Config/Memory、EP→RC Memory、BE 与64位地址的实际请求字段、
读回数据和 UVM report。两个方向有不同的 sequencer/命令绑定，但不等同于
已经覆盖任意多 Root/多 Host 拓扑。

最后两次恢复读通过 `fork ... join` 同时启动；SV 和 Tcl 分别校验两条命令
的真实 `COMPLETED cpl_status=SC` 与读回数据，不能只根据 fork 的汇总成功
判定通过。这组覆盖同一访问 sequence 方法的跨实例取消隔离，不增加请求数。

在 53 上进入已加载 VCS/license 环境的 bash，设置 `AIP_CORE`、
`HOST_MEM_ROOT`、`PCIE_SVT_ROOT`、`DESIGNWARE_HOME` 后执行：

```sh
cd /path/to/pcie_work/svt_pcie_integration/sim
bash ./check_svt_aip_cmd.sh
# 仅 Tcl/runner 改动且确认 SV/filelist/依赖未变化时，可以复用专用 binary：
PCIE_AIP_SKIP_BUILD=1 bash ./check_svt_aip_cmd.sh
```

脚本先编译关闭宏、无外部类型依赖的测试，再编译真实双 SVT 顶层。正常组
必须完成全部业务、34 项错参拒绝且接收计数不增加，并保持 UVM WARNING/ERROR/FATAL
为零；随后以同一 binary 在独立目录重启，故意不使能 EP，检查 RC 的 1000ns
建链期限只触发一次 `PCIE_AIP_LINK_TIMEOUT`。后者是预期失败测试，不与正常组
共用“零 FATAL”判据，也不接受主机超时或崩溃作为成功。

范围限制：此入口使用一个 RC 与一个 EP 的 x16 Serial 互连、现有 FULL_VIP/TL
adapter 环境，不是四个 Host 并发，也不是实际 DUT 或生产 backend 工厂生命周期
的重新验证。Type1/Switch 路由、非零 TC、4096 字节极限长度尚不属于该动态
用例的覆盖范围；这些字段有参数校验，但不能将接口支持等同于对应拓扑已实测。

### 4.1 本次实测记录（2026-09-17）

53 上使用 VCS W-2024.09-SP1、UVM 1.2、SVT R-2020.12，seed=17。
最终业务测试确认：

| 检查项 | 实测结果 |
|---|---|
| 关闭 `PCIE_ENABLE_AIP_CMDS` | 不加载 UVM/AIP/SVT 仍可编译运行 |
| Tcl 建链 | RC/EP 都达到 L0，未使用基类自动建链 |
| RC→EP | 6 个 Config 请求 + 6 个 Memory 请求，接收字段和读回正确 |
| EP→RC | 6 个 Memory 请求，真实 Host backing 和反向 Completion 检查通过 |
| 错参恢复 | 34 项拒绝，接收计数不增加，随后合法访问成功 |
| 正常组 UVM 汇总 | WARNING=0、ERROR=0、FATAL=0 |
| 独立建链超时 | EP 不使能，RC 等待 1000ns 后唯一 `PCIE_AIP_LINK_TIMEOUT`；WARNING=0、ERROR=0、FATAL=1 |

实测发现并修正了“低于 4GB 却强制 4DW 头”的协议问题：SVT 按 PCIe
2.2.4.1 报格式警告，现改为参数阶段拒绝，没有屏蔽 checker。VCS 带
`-exitstatus` 时此预期 FATAL 的退出码实测为3；脚本同时核对精确报告内容与
计数，不仅按退出码判定预期失败。

工作区证据保存在 `svt_pcie_integration/sim/build/aip_cmd_evidence/`
（build 产物不纳入 Git）：`normal.mk7xoU/run.no_color.log`、
`timeout.BjGegu/run.no_color.log`、`disabled/run.log` 和 `build.log`。
53 上原始记录位于
`/tmp/pcie_aip_cmd.Qrxmhp/pcie_work/svt_pcie_integration/sim/build/aip_cmd/`。

最终脚本退出0，同时打印 `SVT_AIP_CMD_CHECK_PASS` 和
`SVT_AIP_CMD_TIMEOUT_CHECK_PASS exit=3`。期间一次重复运行在进入 AIP bridge
前发生运行期网络连接等待，保留为 `run.5OWKvW`，未计作通过；不改网络或
许可证配置，以相同 binary 重启后得到上述最终结果。

### 4.2 逐命令 wait 联调记录（2026-09-17）

配套包含 `wait=0/1` 调度实现的 AIP 源码重新编译同一 1RC+1EP x16 Serial
顶层，未复用旧 AIP binary。RC 命令使用 `wait_l0=1 wait=0`，10us 即收到
`STARTED`，约16.939us 在后台完成；EP 未写 `wait`，约17.018us 到 L0 后才
返回。正常组仍通过 12/6 双向请求、34 项拒参和最后两向并发读检查，
UVM WARNING/ERROR/FATAL 全为零。

同一新 binary 另运行原版同步 Tcl（RC 首次 `wait_l0=0`），相同业务门禁和
UVM 零警告/错误检查亦通过，保留原有默认调用方式。

同一 binary 分别以同步、后台方式只使能 RC、设置 `timeout_ns=1000`。
两组都只触发一次 `PCIE_AIP_LINK_TIMEOUT`，WARNING=0、ERROR=0、FATAL=1，
退出码3；后台组先返回 `STARTED` 再 FATAL，证明外层不等待不会屏蔽业务期限。

本轮同时修复建链/访问类方法内具名 `disable` 的跨实例取消问题；期限竞争
现在由独立父进程隔离。最小复现中，原写法让预期10ns的实例在5ns被另一个
实例取消；修复后两实例分别在5ns和10ns完成，双SVT并行读也验证了真实路径。

本地证据：`svt_pcie_integration/sim/build/aip_cmd_wait_evidence/`，包含重放
脚本、源码 hash 和原始日志。53 对应目录为 `/tmp/pcie_aip_wait_svt.hSuqxo/`：
正常组 `build/run.X2I1OH`、同步超时 `build/timeout_sync.Lu4WhY`、后台超时
`build/timeout_async.d7yARa`、原版同步脚本 `build/canonical.h47DFL`。
该结果不扩大到四 Host 或实际 DUT 的覆盖范围。
