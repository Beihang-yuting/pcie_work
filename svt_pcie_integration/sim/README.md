# SVT PCIe unified topology simulation

This directory contains the active SVT integration entry point.  The project
uses the Synopsys SVT PCIe R-2020.12 Unified VIP in Serial mode and keeps
topology, device policy, BAR policy, and backend selection in the common
`pcie_global_cfg` management layer.

## Active build contract

Compile from this directory with:

```sh
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+PCIE_TOPO_EP_X16 \
  -f pcie_svt_topology.f \
  -top pcie_svt_topology_top \
  -o build/simv -l build/compile.log
```

本目录的 SVT filelist 已内置 `-timescale=1ns/1ps`。这是必要的
VCS 选项：SVT R-2020.12 的 source map 含有显式 `` `timescale``，而 TL
package 通常没有；统一默认时间单位可避免 compilation-unit timescale
冲突。若自行重写 filelist，请保留该选项。

The installed SVT environment must provide `svt_pcie.uvm.pkg`, the Unified VIP
environment example include directory, and the VCS/PLI support files.  Use a
login shell on the VCS host so `VCS_HOME`, `PCIE_SVT_ROOT`, and the license
environment are available.

Select exactly one compile-time topology:

```text
PCIE_TOPO_EP_X16
PCIE_TOPO_EP_2X8
PCIE_TOPO_SWITCH_1X16_4X4
```

The maximum statically elaborated HDL slot count may be overridden with
`PCIE_SVT_ENV_MAX_HDL_AGENTS`; the runtime policy limit is controlled by
`PCIE_SVT_ENV_MAX_NUM_LINKS`.  These project-private macros do not override
Synopsys' `SVT_PCIE_MAX_NUM_LINKS`.

## Runtime stages

The active test layer is based on `pcie_device_base_test` and
`pcie_unified_env`.  The stage sequence preserves this order:

```text
link bring-up -> configuration-space/BAR initialization -> enumeration/traffic
```

The current topology test entry points are listed in `pcie_svt_topology.f`.
Scenario tests can override `build_global_cfg()` to select backend, enable
links, assign BDFs, and customize BAR descriptors.

Enumeration and BAR allocation are also data-driven.  The profile creates
`pcie_svt_topology_policy_cfg.enum_cfg` with these defaults:

```text
pref_mem_base_addr       = 0x0000_0001_0000_0000
pref_mem_limit_addr      = 0x0000_0001_0fff_ffff
pref_mem_window_stride   = 0x0000_0000_1000_0000 (256 MiB per root)
bus_number/device_number = 1/0
```

The six `policy_cfg.ep_bars[]` descriptors remain the source of BAR aperture,
type, Prefetchable bit, and initial BAR address.  A test can override the
enumeration object before the base test builds `env`, for example:

```systemverilog
pcie_svt_enum_cfg enum_override;
enum_override = pcie_svt_enum_cfg::type_id::create("enum_override");
enum_override.pref_mem_base_addr = 64'h0000_0002_0000_0000;
enum_override.pref_mem_limit_addr = 64'h0000_0002_0fff_ffff;
enum_override.pref_mem_window_stride = 64'h0000_0000_2000_0000;
uvm_config_db#(pcie_svt_enum_cfg)::set(this, "", "enum_cfg", enum_override);
```

The adapter deep-copies this object into each active link descriptor.  The
enumeration sequence then derives the per-root window from
`pref_mem_*_for(root_hierarchy)`, so no address constant is embedded in the
sequence.  `pcie_svt_enum_cfg.validate()` rejects reversed windows, a stride
smaller than the window, and invalid function-count limits before elaboration.

The default transport is Serial.  PIPE support remains a future transport
extension and is not enabled by the current topology policy.

### 已验证的双侧 Serial link test

`pcie_svt_peer_test` 通过独立 filelist `pcie_svt_peer_selfcheck.f` 编译，并作为双向 TL/SVT
对接前的正式 link 门禁。它在同一顶层创建 primary RC 和 peer EP 两个
`pcie_svt_topology_env`，通过 `PCIE_SVT_CONNECT_SERIAL_PEERS` 互连，先
执行两侧 CFG_INIT/REFRESH_CFG，再执行双侧 DL/PL enable 和 LTSSM 检查。
验证命令为：

```sh
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  -f pcie_svt_peer_selfcheck.f -top pcie_svt_topology_top \
  -o build/peer_x16/simv -l build/peer_x16/compile.log
./build/peer_x16/simv -no_save \
  +UVM_TESTNAME=pcie_svt_peer_test \
  +PCIE_TOPOLOGY=EP_X16 +PCIE_GEN=4 +PCIE_LINK_ONLY
```

在 53 号机 VCS W-2024.09-SP1 + SVT R-2020.12 上，1RC+1EP/x16/Serial
运行结果为 `RUN_STATUS=0`、`UVM_ERROR=0`、`UVM_FATAL=0`，两侧均报告
`LTSSM: Link training completed`、`Speed is 16Gb/s`、`Link width is 16`，
并输出 `PCIE_SVT_LINK_PASS`。该 test 是环境级 link 验证；真实 DUT 接入
时只需替换 peer EP 的 HDL/Serial 连接，保留相同 test 和 sequence。

## Production TL-root SVT adapter entry point

生产集成使用独立 filelist `pcie_tl_svt_adapter.f`。它只编译
`pcie_tl_env`、`pcie_svt_adapter_pkg` 和门禁 test，不依赖旧的
`pcie_unified_env`、`pcie_svt_topology_env` 或 peer self-check。测试类
`pcie_tl_svt_adapter_base_test` 在 env 创建前通过 UVM factory 将
`pcie_tl_if_adapter` 覆盖为 `pcie_svt_if_adapter`，因此所有 RC/EP 链路都
共享同一个 TL-root 控制面。

在 53 号机（登录 shell）上可先做编译/elaboration 门禁：

```sh
mkdir -p build/tl_svt_adapter
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  -f pcie_tl_svt_adapter.f -top pcie_tl_svt_adapter_tb_top \
  -o build/tl_svt_adapter/simv -l build/tl_svt_adapter/compile.log
./build/tl_svt_adapter/simv -no_save \
  +UVM_TESTNAME=pcie_tl_svt_adapter_link_test \
  -l build/tl_svt_adapter/run.log
```

当前门禁不创建正式 `svt_pcie_device_agent`，因此 adapter 会输出
compile-only warning，但不会发送实际 TLP。真实 DUT 顶层应创建并配置正式
SVT agent，然后通过 config_db 在相应 adapter 路径发布 `svt_agent`（或直接
发布 `pcie_svt_mapper`）。加入 `+PCIE_SVT_REQUIRE_MAPPER` 后，若 Mapper
未绑定，connect_phase 会立即报出明确的 UVM_FATAL，避免误把占位环境当成
真实链路验证。

## DPU-common EP x16 example

The optional DPU-aware example uses the companion filelist
`pcie_dpu_ep_x16.f`, so native SVT builds do not acquire a hard dependency on
`dpu-common`:

```sh
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  +define+PCIE_TOPO_EP_X16 \
  -f pcie_dpu_ep_x16.f -top pcie_svt_topology_top \
  -o build/dpu_ep_x16_simv -l build/dpu_ep_x16_compile.log
```

The profile is selected at runtime without changing DPU authoring data:

```sh
./build/dpu_ep_x16_simv +UVM_TESTNAME=pcie_dpu_ep_x16_test \
  +PCIE_BACKEND=SVT_REAL_DUT +PCIE_GEN=4 +PCIE_DPU_COMPILE_ONLY
```

`+PCIE_BACKEND=TL_ONLY +PCIE_DPU_CONTROLLED_EXECUTOR` runs the controlled TL
plan smoke against the generic TL Endpoint.  The controlled executor is only
for a protocol-only environment; a real DPU RTL register model should omit it
and use the transport executor directly.

## RTL connection boundary

`pcie_svt_topology_env_top.sv` and the reset/serial interfaces provide the
project boundary for a real DUT.  Users supply the DUT wrapper, SerDes or PIPE wiring,
clock/reset conversion, and any board-specific connections.  The environment
owns policy translation, configuration-space initialization, enumeration, and
traffic sequencing.

## Removed legacy paths

The former TL proxy, passive-sidecar, and switch-proxy implementation has been
removed.  It was not a real DUT data path and is not part of the active unified
environment.  Historical design notes remain under `docs/superpowers/` for
reference only; they are not build inputs.
