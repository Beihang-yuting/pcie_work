# TL-root / SVT adapter

本目录只保留正式 SVT transport adapter 的编译入口。生产控制面是
`pcie_tl_env`；SVT 不再提供第二套 topology、配置空间或 traffic env。

## 编译入口

当前有两个可直接运行的 SVT 验证入口：

- `pcie_tl_svt_formal.f`：本项目 TL-root + SVT FULL_VIP 双向 Serial 门禁；
- `pcie_svt_peer_traffic.f`：官方 SVT RC/EP peer-only Serial 自检。

`pcie_tl_svt_adapter.f` 现在是 source-only 适配层 filelist。它只包含
`pcie_tl_env`、SVT adapter package 和官方 SVT 支持源码，不再包含没有真实
SVT agent 的占位 test/top。接入真实 DUT 时，应在用户工程自己的 filelist
中引用这些源文件，并追加 DUT wrapper、SVT HDL agent、Serial/PIPE 连接和
用户 test。

已删除的 `pcie_tl_svt_adapter_*` 占位测试只验证 factory/queue-only 对象是否
创建，既没有真实 SVT agent，也没有实际 TLP 或物理链路，不再作为回归入口。

真实 DUT 工程使用 source-only 列表时，需要自行提供顶层，例如：

```text
-f /path/to/pcie_work/svt_pcie_integration/sim/pcie_tl_svt_adapter.f
/path/to/user/pcie_real_dut_top.sv
/path/to/user/pcie_real_dut_test.sv
```

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
./build/tl_svt_formal/simv -l build/tl_svt_formal/run.log
```

通过标志为 `PCIE_TL_SVT_TLP_PASS`；同时应检查日志中的 SVT Serial
链路进入 L0，且 `UVM_ERROR/UVM_FATAL` 均为 0。正式门禁还会检查
`RC_EP_WRITE_READBACK_PASS`、`EP_RC_READBACK_PASS` 和
`EP_RC_WRITE_PASS`：分别覆盖 RC→EP 写后读回、EP→RC 读 Root host
memory，以及 EP→RC posted write 回读 Root host memory。这样既确认
Completion 返回，也确认反向 posted 请求确实落入 RC 的统一内存，而不是
只在 adapter mailbox 中出现。真实 DUT 集成时保留同样的 `pcie_tl_env`、
factory override 和 `svt_agent_path` 配置即可。

### Transport-only 的 SVT shadow 配置检查

当前 FULL_VIP 门禁由 `pcie_tl_env` 统一管理配置空间和 BDF；SVT 只承担
DL/PL/Serial transport，因此不会为 TL sequence 动态产生的 requester
function 自动建立 shadow configuration entry。测试在
`pcie_tl_svt_formal_test.sv` 中将 Root/Endpoint 的
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

## 静态契约检查

```sh
./svt_pcie_integration/sim/check_tl_svt_bridge_contract.sh
git diff --check
```

检查会确认 adapter package、公开 Mapper 端口和 TL-only filelist 隔离，
避免旧 topology/unified 文件被重新带回生产路径。
