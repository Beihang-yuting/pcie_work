# AIP Tcl 启动双 SVT Serial 建链诊断

本例用于区分“命令未执行”“链路未起来”和“没有建链过程打印”。
它不包含真实 DUT，不检查配置空间访问、业务流量或链路长期稳定性。

## 测试组成

RC 通过生产路径 `global_cfg -> pcie_tl_env -> backend_factory ->
pcie_svt_backend` 创建；另一个真实 SVT EP 作为外部对端，两者使用 x16
Serial 互连。两端配置为 Gen4 能力，但通过条件只要求双端同时
`link_up == 1 && ltssm_state == L0`，不把它等同于已完成 Gen4 速率协商。

- 顶层：`svt_pcie_integration/rtl/pcie_svt_aip_link_top.sv`。
- 用户 sequence/test：`svt_pcie_integration/tests/pcie_svt_aip_link_test.sv`。
- Tcl：`svt_pcie_integration/tests/pcie_svt_aip_link.tcl`。
- 编译列表：`svt_pcie_integration/sim/pcie_svt_aip_link.f`。
- 双模式检查：`svt_pcie_integration/sim/check_svt_aip_link.sh`。

未设置官方自动建链/default sequence。Tcl 调用 `svt_pair_link_up` 后，用户
sequence 才对 RC/EP 并行启动官方
`svt_pcie_dl_service_set_link_en_sequence`，各自设置 `enable=1`。
启动前若任一端已在 L0，测试直接失败，防止把已有链路误判为本命令的结果。
接真实 DUT 时只启动 SVT 侧的 sequence；DUT 的 LTSSM 由自身逻辑控制。

当前测试将官方 Serial 互连两端的 `TRANSMIT_BIT_CLOCK_MODE` 显式设为
`0`，与生产 `PCIE_SVT_DECLARE_HDL_AGENT_X4/X8/X16` 的新默认值一致。
不提供外部发送 bit clock，也不再通过 backend 子类或 EP cfg 设置
`disable_ext_bit_clock_mode=1`；由 HDL mode=0 选择内部发送时钟。
这里仍使用官方互连，不能把该运行当成三个生产宽度宏的逐一建链回归；
三个宏的参数由 `check_svt_serial_clock_contract.sh` 独立静态检查。
此 bit clock 选择不能与 DUT PHY 参考钟或 Passive Monitor 采样时钟混淆，
完整说明见[4RC 文档 §2.2](pcie_svt_4rc_dut_ep_integration.md#22-serial-时钟与-passive-monitor)。

## 在 53 上运行

先准备 pcie_work、host_mem、AIP 源码和 SVT 安装。AIP 需要支持
`aip_cmd_user_seq`；测试从源码加载 `dist/aip_init.tcl`，不依赖旧发布库中
内嵌的 Tcl。进入已加载 VCS 路径和许可证配置的 bash shell 后执行：

```sh
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT=$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12
export HOST_MEM_ROOT=/path/to/host_mem
export AIP_CORE=/path/to/aip_core
cd /path/to/pcie_work/svt_pcie_integration/sim
bash ./check_svt_aip_link.sh
```

脚本编译一次，然后以 seed=17、UVM_MEDIUM 分别运行 `trace=0/1`。
`trace` 只控制用户 wrapper 的日志，不改变 SVT 日志配置或训练逻辑。
完整输出和厂商附属文件分别保存在
`build/aip_pair/runs.XXXXXX/trace_0/` 与 `trace_1/`。
仅在确认源码/依赖未改变时，才用 `PCIE_AIP_SKIP_BUILD=1` 复用编译产物。

通过必须同时满足：命令有本次新 ack、AIP sequence start/done、返回明确的
`PAIR_LINK_L0`、完成 UVM report、UVM ERROR/FATAL 均为零；关键词计数只是
辅助观察，不是建链成功依据。每组另有 600 秒主机侧超时。

## 对用户集成的排查要点

1. 注册不等于执行：`` `aip_cmd_user_seq `` 只是注册入口，必须从 Tcl
   实际调用命令。AIP 默认 INFO 下有 `[USER_SEQ] ... start/done`；通用
   `OK: <command>` 只表示 `seq.start()` 返回，不能单独证明进入 L0。
2. 4RC 文档的 Tcl wrapper 本身没有 `uvm_info`/`$display` 过程打印，
   只写 `status/result_out`。脚本应显式检查并打印结果，例如
   `puts [aip_read_result]`，同时检查 `aip_check_status` 和本次 ack。
3. R-2020.12 的 backend 数组保存的是 **device agent**，不是 device
   virtual sequencer。正确路径如下；现有集成示例中省略 `virt_seqr`
   的写法会编译失败，不能照搬：

   ```systemverilog
   link_en.enable = 1'b1;
   link_en.start(svt_be.svt_agent_by_link[id].virt_seqr.pcie_virt_seqr.dl_seqr);
   ```

   建链前应逐层检查 agent、`virt_seqr`、`pcie_virt_seqr`、`dl_seqr`
   和 status 非空。不要对已是 device virtual sequencer 的句柄再加一层。
4. `svt_verbosity` 默认 UVM_MEDIUM；backend 的 symbol、PL history、
   transaction 日志开关默认关闭。UVM verbosity 与厂商文件日志不是同一
   开关；提高 verbosity 不保证出现完整 LTSSM 轨迹。
5. AIP 默认 Tcl ack 等待与无活动 watchdog 都是 50 us。纯 SVT 内部训练
   不会自动更新 AIP activity。本例把 ack 窗口设为 5 ms，以
   `set_cmd_watchdog ns=0` 关闭该 watchdog，并由 sequence 独立的 1 ms
   超时覆盖复位等待、两次 `start()` 和 L0 等待。不能只关 watchdog
   却不补建链超时；no-ack 后的旧结果也不能当作成功。

SV/UVM 输出是否被 Tcl `redirect` 隐藏，必须以所用 VCS 的实际行为为准。
53 的最小 `$display`、`$write`、`uvm_info` 加 `$stop` 实验中，
`redirect /dev/null { _vcs_run 100ns }` 仍保留这些输出，不能仅凭这行 Tcl
就判定它吞掉了建链日志。

## 53 实测记录：旧 HDL mode=1 + cfg disable=1（2026-09-17）

环境为 VCS W-2024.09-SP1、SVT R-2020.12、UVM 1.2，seed=17，
UVM_MEDIUM。AIP 使用 `aip-user-seq-port` 工作树源码快照（基于
`6913070a7347d23249cdd797538851c46ed3ddbf`，含已有未提交拆分改动），
pcie_work 基于 `9186083` 加本诊断用例；本轮未修改 AIP 源码。

以下保留修改生产宏之前的历史对照：当时官方互连默认 HDL mode=1，
测试通过 backend 子类 hook 和 EP cfg 的 `disable_ext_bit_clock_mode=1`
切到内部时钟；这不是当前 mode=0 用例的配置要求。

首次缺少内部 bit clock 配置时，两端在 10 us 均执行了 `SetLinkEnable`，
但 1 ms 时仍为 `link_up=0, ltssm=99 (INITIAL)`，用例正确报 FATAL。
只在测试台补齐 cfg disable=1 后，两组独立运行均通过：

| 模式 | 双端状态 | 命令耗时 | UVM ERROR / FATAL |
|---|---|---|---|
| `trace=0`，不加 wrapper 过程日志 | `link_up=1, L0` | 88,623 ns（取整） | 0 / 0 |
| `trace=1`，增加 wrapper 过程日志 | `link_up=1, L0` | 88,623 ns（取整） | 0 / 0 |

两组的 Tcl 结果一致：

```text
PAIR_TCL_RESULT status=0 result=PAIR_LINK_L0 link=RC0_EP0 rc_link_up=1 rc_ltssm=16 ep_link_up=1 ep_ltssm=16 elapsed_ns=88623
UVM_ERROR : 0
UVM_FATAL : 0
```

`16` 是此版本的 `L0`。时间约 88.623 us，包含命令内的 10 us 复位等待，
已超过 AIP 默认的 50 us ack/watchdog 窗口。
即使没有 wrapper 过程打印，默认 SVT 日志仍出现：

```text
SetLinkEnable: DL link_enable = 1 via call to SetLinkEnable task.
LTSSM: Performing receiver detect
LTSSM: Link training completed. The link is READY! Speed is 8Gb/s. Link width is 16.
```

最后一项来自 EP 的厂商日志，当时报告 8 Gb/s x16。本例在双端满足 L0 后
结束，不验证之后是否继续升速至 Gen4，不能据此声称 Gen4 建链已通过。

`trace=1` 额外打印命令入口、双方 enable 起止、每 1 us 采样观察到的状态
变化及双端 L0 成功信息。两端 enable sequence 均在 10 us 返回，但直到
约 88.623 us 才同时满足 L0，直接证明 `enable.start()` 返回不等于建链完成。
原始控制台日志包含上述 SV/UVM 信息，AIP 的内部 `redirect` 在本环境没有
将它们吞掉。runner 最终返回 `SVT_AIP_LINK_CHECK_PASS`，退出码 0。

因此，没有逐状态的详细轨迹不一定异常；但本配置下并非完全没有训练相关
消息。用户现场若连 `[USER_SEQ] ... start`、`SetLinkEnable` 都看不到，应先
核对实际命令调用、日志过滤及 sequencer 绑定；若 enable 已执行但状态停在
INITIAL，则检查复位和 bit clock，不要只提高 verbosity。双 SVT 测试台的
这次时钟问题不能直接认定为真实 DUT 现场的根因。

53 日志保留在：

```text
/tmp/pcie_aip_pair.lzgaqG/pcie_work/svt_pcie_integration/sim/build/aip_pair/
  runs.LetnHr/trace_0/run.log    # 首次时钟配置缺失，1ms 超时
  runs.sNPZC9/trace_0/run.log    # 内部 bit clock，默认打印
  runs.sNPZC9/trace_1/run.log    # 内部 bit clock，增加 wrapper 打印
```

本地忽略目录 `svt_pcie_integration/sim/build/aip_pair_evidence/` 也保存了
失败对照和两组通过日志；这些运行产物不纳入源码提交。测试涉及的新增
源码、Tcl 和 shell 在该轮完成真实编译/执行及静态检查，当时未修改生产
backend、AIP 实现或批量修订既有集成文档。后续宏切到 mode=0 的验证
记录单独列出，不把这份历史结果作为新 HDL 设置已通过的证据。

## 53 实测记录：新 HDL mode=0，无 cfg 覆盖（2026-09-17）

同一 VCS/SVT/AIP 环境下，重新编译专用顶层，将官方互连 RC/EP 两端的
`SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE_P0/P1` 显式设为 `1'b0`；移除旧测试
backend 子类及其 factory override，并移除 EP cfg 的内部时钟覆盖。
RC 使用生产 backend，两端都不再设置 `disable_ext_bit_clock_mode=1`，
也不提供外部发送 bit clock。

VCS 编译通过；同一二进制、seed=17、UVM_MEDIUM 下两组运行均通过：

| 模式 | 双端状态 | 命令耗时 | UVM WARNING / ERROR / FATAL |
|---|---|---|---|
| `trace=0` | `link_up=1, L0` | 88,623 ns（取整） | 0 / 0 / 0 |
| `trace=1` | `link_up=1, L0` | 88,623 ns（取整） | 0 / 0 / 0 |

两组均实际输出以下结果，runner 返回 `SVT_AIP_LINK_CHECK_PASS`，退出码 0：

```text
PAIR_TCL_RESULT status=0 result=PAIR_LINK_L0 link=RC0_EP0 rc_link_up=1 rc_ltssm=16 ep_link_up=1 ep_ltssm=16 elapsed_ns=88623
```

这验证了 HDL mode=0 可以在不加 cfg workaround 的情况下，通过 Tcl
开启双 SVT 训练并达到双端 L0。厂商日志当时报告 8 Gb/s x16；仍不声称
已验证最终 Gen4 速率、业务流量或真实 DUT。运行采用官方 x16 互连，
不是逐一展开生产 X4/X8/X16 宏的建链测试；三个生产宏另经静态检查，
确认均为 mode=0，且 PIPE 分支没有混入 Serial 时钟参数。

53 上的本次编译和运行日志：

```text
/tmp/pcie_aip_pair.lzgaqG/pcie_work/svt_pcie_integration/sim/build/aip_pair/
  mode0_build.log
  runs.6M9BsE/trace_0/run.log
  runs.6M9BsE/trace_1/run.log
```

本地副本保存在忽略目录
`svt_pcie_integration/sim/build/aip_pair_evidence/mode0/`，与旧配置证据分开。
本次未运行全量回归，未修改生产 backend 或 AIP 实现。
