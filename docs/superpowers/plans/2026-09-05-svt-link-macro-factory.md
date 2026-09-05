# SVT Link Macro Factory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用统一的 `PCIE_SVT_BUILD_LINK(mode, width, transport, ...)` 宏函数创建双 SVT 或 SVT-DUT 链路，并验证双 SVT 数据面；同时为后续 4-SVT 和 PIPE 保留稳定入口。

**Architecture:** 对外暴露一个按 `mode × width × transport` 分发的链路宏。内部继续复用现有 SVT HDL agent/lane 宏，SVT 模式调用官方 ICM peer interconnect，DUT 模式创建单侧 SVT agent 和规范化 Serial interface。物理连接宏与链路创建宏分离，当前实现 SERDES，PIPE 只进入统一分发并以明确 compile-time guard 拒绝。

**Tech Stack:** SystemVerilog preprocessor macros, Synopsys SVT R-2020.12, UVM 1.2, VCS, existing `pcie_tl_env` and `pcie_svt_if_adapter`.

**Spec:** `docs/superpowers/specs/2026-09-05-svt-link-macro-factory-design.md`

## Global Constraints

- `pcie_tl_env` remains the only PCIe configuration and traffic control environment.
- Existing TL-only sources, tests, APIs, and `pcie_tl_vip/sim/filelist.f` must remain SVT-independent.
- Existing dual-SVT formal data-plane behavior must remain unchanged: L0, TL TLP pass, RC/EP readback checks, and zero UVM errors/fatals.
- Physical signal names are exposed through fixed Serial interfaces; DUT hierarchy names stay in the user top/wrapper.
- `X4`, `X8`, and `X16` are supported widths; unsupported width/mode/transport tokens fail at compile time.
- `SERDES` is the only implemented transport in this plan; `PIPE` has a stable dispatch entry and an explicit unsupported guard.
- 4-SVT coverage is two independent x8 peer links (four SVT HDL agents), using the same macro API and unique link/port names.
- All added code and comments must be readable, include Chinese explanations where useful, and preserve blank-line separation.

---

### Task 1: Add the parameterized link and transport macro API

**Files:**
- Create: `svt_pcie_integration/rtl/pcie_svt_link_macros.svh`
- Create: `svt_pcie_integration/rtl/pcie_svt_transport_macros.svh`
- Modify: `svt_pcie_integration/rtl/pcie_svt_hdl_agent_macros.svh:1-63`
- Modify: `svt_pcie_integration/rtl/pcie_svt_serial_adapter.sv:1-40`
- Create: `svt_pcie_integration/sim/check_pcie_svt_link_macros.sh`

**Interfaces:**
- Consumes existing `PCIE_SVT_DECLARE_HDL_AGENT_X4/X8/X16`, `PCIE_SVT_MAP_SERDES_X4/X8/X16`, `pcie_svt_serial_port_if`, and official `SVT_PCIE_ICM_*` macros.
- Produces `PCIE_SVT_BUILD_LINK(mode, width, transport, link_id, svt_side0, svt_side1, reset_signal, clkreq_signal, wake_signal, svt_is_root, external_serial_if)` as the public fixed-arity entry.
- Produces `PCIE_SVT_CONNECT_PHY(transport, width, svt_serial_if, external_serial_if)` and concrete `PCIE_SVT_CONNECT_SERDES_X4/X8/X16` connectors.

- [ ] **Step 1: Write the macro contract check first**

Create `check_pcie_svt_link_macros.sh` that exits non-zero unless all of the following are true:

```sh
grep -q '`define PCIE_SVT_BUILD_LINK' ../rtl/pcie_svt_link_macros.svh
grep -q 'PCIE_SVT_BUILD_LINK_``mode``_``width``_``transport' \
  ../rtl/pcie_svt_link_macros.svh
grep -q '`define PCIE_SVT_CONNECT_PHY' ../rtl/pcie_svt_transport_macros.svh
grep -q 'PCIE_SVT_CONNECT_SERDES_X4' ../rtl/pcie_svt_transport_macros.svh
grep -q 'PCIE_SVT_CONNECT_SERDES_X8' ../rtl/pcie_svt_transport_macros.svh
grep -q 'PCIE_SVT_CONNECT_SERDES_X16' ../rtl/pcie_svt_transport_macros.svh
grep -q 'PIPE' ../rtl/pcie_svt_transport_macros.svh
```

The script must also reject a link macro that contains a hard-coded user DUT hierarchy path; only formal interface field names such as `tx_p`, `rx_p`, `tx_n`, `rx_n`, `tx_clk`, and `rx_clk` are allowed.

- [ ] **Step 2: Add explicit mode/width/transport dispatch**

Implement fixed-arity token dispatch without relying on variadic macro syntax:

```systemverilog
`define PCIE_SVT_BUILD_LINK(mode, width, transport, link_id, side0, side1, reset_signal, clkreq_signal, wake_signal, svt_is_root, external_serial_if) \
  `PCIE_SVT_BUILD_LINK_``mode``_``width``_``transport(link_id, side0, side1, reset_signal, clkreq_signal, wake_signal, svt_is_root, external_serial_if)
```

Provide concrete `SVT_X4_SERDES`, `SVT_X8_SERDES`, `SVT_X16_SERDES`, `DUT_X4_SERDES`, `DUT_X8_SERDES`, and `DUT_X16_SERDES` expansions. Unsupported combinations must use a preprocessor `error` rather than silently selecting SERDES.

- [ ] **Step 3: Implement SVT peer expansions**

For each supported width, call the official peer macros with the supplied link id and stable side names:

```systemverilog
`SVT_PCIE_ICM_CREATE_PORT_INST(link_id, 0)
`SVT_PCIE_ICM_CREATE_PORT_INST(link_id, 1)
`SVT_PCIE_ICM_CREATE_LINK(link_id, side0, side1)
`SVT_PCIE_ICM_SER_SER_LINK(link_id, side0, side1)
`SVT_PCIE_ICM_DO_CONDITIONAL_INTERCONNECT(link_id, side0, 1, side1)
```

Apply the width-specific SerDes `defparam` values in the same expansion, preserving the existing root/endpoint role and Gen4 model settings. Do not change the official `link_<id>_vif_<port>` publication contract.

- [ ] **Step 4: Implement DUT expansions and Serial connectors**

For each supported width, create only the SVT side using the existing HDL agent helper and create one `pcie_svt_serial_port_if #(LANES)` interface. The `svt_is_root` argument must feed the existing `is_root` parameter. `external_serial_if` is the user-facing interface handle.

Implement `PCIE_SVT_CONNECT_SERDES_X4/X8/X16` as bidirectional fixed-field interface connections. The connector must map SVT TX to external RX and external TX to SVT RX, and connect the existing clock/active-clock fields using the same direction as `pcie_svt_serial_adapter.sv`.

Implement `PCIE_SVT_CONNECT_PHY(PIPE, ...)` dispatch with an explicit compile-time error string such as `PIPE transport adapter is reserved and not implemented in this release`; do not map PIPE to SERDES.

- [ ] **Step 5: Keep existing lower-level macros source-compatible**

Only add aliases/helpers or comments to `pcie_svt_hdl_agent_macros.svh` and `pcie_svt_serial_adapter.sv`. Existing direct calls to `PCIE_SVT_DECLARE_HDL_AGENT_X4/X8/X16` and `PCIE_SVT_MAP_SERDES_X4/X8/X16` must still preprocess unchanged.

- [ ] **Step 6: Run the static contract check**

Run from `svt_pcie_integration/sim`:

```sh
./check_pcie_svt_link_macros.sh
```

Expected: exit 0 and report all public mode/width/transport entries found.

- [ ] **Step 7: Commit**

```sh
git add svt_pcie_integration/rtl/pcie_svt_link_macros.svh \
  svt_pcie_integration/rtl/pcie_svt_transport_macros.svh \
  svt_pcie_integration/rtl/pcie_svt_hdl_agent_macros.svh \
  svt_pcie_integration/rtl/pcie_svt_serial_adapter.sv \
  svt_pcie_integration/sim/check_pcie_svt_link_macros.sh
git commit -m "feat: add parameterized SVT link macro factory"
```

### Task 2: Migrate the existing dual-SVT Serial topology to the macro API

**Files:**
- Modify: `svt_pcie_integration/sim/pcie_tl_svt_formal_topology.sv:1-25`
- Modify: `svt_pcie_integration/sim/pcie_tl_svt_formal.f:8-52`
- Modify: `svt_pcie_integration/sim/pcie_svt_peer_traffic_topology.sv:1-33`
- Modify: `svt_pcie_integration/sim/pcie_svt_peer_traffic.f:8-29`
- Modify: `svt_pcie_integration/sim/check_tl_svt_bridge_contract.sh:1-120`

**Interfaces:**
- Consumes Task 1 public `PCIE_SVT_BUILD_LINK(SVT, X16, SERDES, ...)`.
- Produces the same official VIF names and the same UVM test-visible SVT agent hierarchy as before.

- [ ] **Step 1: Replace the formal topology body**

Replace the four direct `SVT_PCIE_ICM_*` calls in `pcie_tl_svt_formal_topology.sv` with one `PCIE_SVT_BUILD_LINK(SVT, X16, SERDES, ...)` invocation. Preserve the existing link id 0, root/endpoint names, reset behavior, and width defparams.

- [ ] **Step 2: Include the new macro files in the test-only compilation scope**

Add the two new `.svh` files to the top-level include order or include them from the topology file after the official `svt_pcie.uvm.pkg` and interconnect macro definitions are available. Do not add them to the TL-only filelist.

- [ ] **Step 3: Migrate the official peer traffic topology**

Replace its direct ICM calls with the same macro API. Keep this peer-only test’s official `pcie_device_base_test` flow untouched.

- [ ] **Step 4: Extend the contract script**

Add checks that both topology files invoke `PCIE_SVT_BUILD_LINK(SVT,` and no longer contain direct `SVT_PCIE_ICM_CREATE_LINK` calls outside the link macro implementation.

- [ ] **Step 5: Run source and static checks**

```sh
cd svt_pcie_integration/sim
./check_pcie_svt_link_macros.sh
./check_tl_svt_bridge_contract.sh
cd ../../
git diff --check
```

Expected: all scripts exit 0; `pcie_tl_vip/sim/filelist.f` remains unchanged and free of SVT references.

- [ ] **Step 6: Commit**

```sh
git add svt_pcie_integration/sim/pcie_tl_svt_formal_topology.sv \
  svt_pcie_integration/sim/pcie_tl_svt_formal.f \
  svt_pcie_integration/sim/pcie_svt_peer_traffic_topology.sv \
  svt_pcie_integration/sim/pcie_svt_peer_traffic.f \
  svt_pcie_integration/sim/check_tl_svt_bridge_contract.sh
git commit -m "refactor: use link macro for dual SVT topologies"
```

### Task 3: Add a real-DUT Serial boundary example using the same macro

**Files:**
- Create: `svt_pcie_integration/rtl/pcie_svt_dut_serial_bind_example.sv`
- Create: `svt_pcie_integration/sim/pcie_tl_svt_dut_example.f`
- Modify: `svt_pcie_integration/sim/README.md:1-150`
- Modify: `docs/pcie_unified_environment_usage.md:42-62`

**Interfaces:**
- Consumes Task 1 `PCIE_SVT_BUILD_LINK(DUT, X8/X16, SERDES, ...)` and `PCIE_SVT_CONNECT_SERDES_X8/X16`.
- Produces a compile-only DUT wrapper contract with fixed `pcie_svt_serial_port_if` signal names and no fake PCIe endpoint behavior.

- [ ] **Step 1: Create the DUT-facing wrapper example**

Define a module with explicit x8 and x16-capable Serial vectors for DUT RX/TX and clocks. Instantiate a `pcie_svt_serial_port_if`, invoke the DUT link macro for `SVT RC + DUT EP`, and connect the interface to DUT-facing ports with continuous assignments. Include Chinese comments explaining direction and reset polarity.

- [ ] **Step 2: Keep the example behavior-free**

The wrapper must not implement a fake LTSSM, configuration space, Completion generator, or memory model. It only demonstrates the physical boundary and may leave the DUT ports as top-level ports for the user to connect.

- [ ] **Step 3: Add a source-only DUT filelist**

Create a filelist that includes the production `pcie_tl_svt_adapter.f` sources plus the wrapper example and official SVT include paths, but does not add the example as a passing end-to-end regression. Document that a real project appends its DUT top and test.

- [ ] **Step 4: Document the two mode invocations**

Show side-by-side `SVT` and `DUT` calls, the required `is_root` choice, and the only user edits needed: DUT port assignments and UVM `svt_agent_path`/TL agent enable settings.

- [ ] **Step 5: Run compile-only checks when SVT installation is available**

From `svt_pcie_integration/sim` on the VCS host, compile the source-only DUT example with `-f pcie_tl_svt_dut_example.f`. Expected: VCS compile/elaboration succeeds without requiring a DUT implementation or claiming data-plane pass.

- [ ] **Step 6: Commit**

```sh
git add svt_pcie_integration/rtl/pcie_svt_dut_serial_bind_example.sv \
  svt_pcie_integration/sim/pcie_tl_svt_dut_example.f \
  svt_pcie_integration/sim/README.md \
  docs/pcie_unified_environment_usage.md
git commit -m "feat: add SVT real-DUT Serial boundary example"
```

### Task 4: Add a four-SVT data-plane regression using repeated macro calls

**Files:**
- Create: `svt_pcie_integration/sim/pcie_tl_svt_4peer_topology.sv`
- Create: `svt_pcie_integration/rtl/pcie_tl_svt_4peer_top.sv`
- Create: `svt_pcie_integration/tests/pcie_tl_svt_4peer_data_test.sv`
- Create: `svt_pcie_integration/sim/pcie_tl_svt_4peer.f`
- Modify: `svt_pcie_integration/sim/README.md:39-95`

**Interfaces:**
- Consumes Task 1 macro API and Task 2 dual-SVT naming/VIF conventions.
- Produces a four-agent data-plane test consisting of two independent x8 peer links: `link_0` has RC0/EP0 and `link_1` has RC1/EP1.

- [ ] **Step 1: Inspect the installed R-2020.12 ICM macro naming**

On the VCS host, inspect the installed definitions before selecting generated names:

```sh
rg -n "define[[:space:]]+SVT_PCIE_ICM_(CREATE_PORT_INST|CREATE_LINK|SER_SER_LINK|DO_CONDITIONAL_INTERCONNECT)" \
  "$PCIE_SVT_ROOT" "$DESIGNWARE_HOME"
```

Record the exact expansion convention in the task report. Do not assume a second invocation can reuse `spd_0`/`spd_1` names.

- [ ] **Step 2: Build two independent macro-generated links**

Invoke the same public API twice:

```systemverilog
`PCIE_SVT_BUILD_LINK(SVT, X8, SERDES, link_0, svt_rc0, svt_ep0, reset, clkreq, wake, 1'b1, unused_if0)
`PCIE_SVT_BUILD_LINK(SVT, X8, SERDES, link_1, svt_rc1, svt_ep1, reset, clkreq, wake, 1'b1, unused_if1)
```

Use unique generated HDL instance/interface names and preserve four distinct UVM agent paths.

- [ ] **Step 3: Configure four SVT agents and two TL links**

Extend the test top to create four official SVT device agents, initialize their configurations from the four published VIFs, disable SVT random application traffic, and bind each TL adapter to the matching official agent. Configure the TL environment with `num_rc=2`, `num_ep=2`, independent Root managers, and `SV_IF_MODE` on all active adapters.

- [ ] **Step 4: Add per-link data-plane checks**

For each RC/EP pair, perform a posted Memory Write followed by Memory Read to a unique address window and assert the returned pattern. Also perform one EP-originated read/completion path per link. The test must fail on a missing completion, cross-link response, or data mismatch.

- [ ] **Step 5: Compile and run the four-SVT regression**

```sh
cd svt_pcie_integration/sim
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  -f pcie_tl_svt_4peer.f -top pcie_tl_svt_4peer_top \
  -o build/tl_svt_4peer/simv -l build/tl_svt_4peer/compile.log
./build/tl_svt_4peer/simv -l build/tl_svt_4peer/run.log
```

Expected: both links reach L0, both link-specific readbacks pass, and `UVM_ERROR/UVM_FATAL` are zero.

- [ ] **Step 6: Commit**

```sh
git add svt_pcie_integration/sim/pcie_tl_svt_4peer_topology.sv \
  svt_pcie_integration/rtl/pcie_tl_svt_4peer_top.sv \
  svt_pcie_integration/tests/pcie_tl_svt_4peer_data_test.sv \
  svt_pcie_integration/sim/pcie_tl_svt_4peer.f \
  svt_pcie_integration/sim/README.md
git commit -m "test: add four-SVT macro-generated data plane"
```

### Task 5: Regression, documentation, and final review

**Files:**
- Modify: `svt_pcie_integration/sim/README.md`
- Modify: `docs/pcie_unified_environment_usage.md`
- Modify: `pcie_tl_vip/docs/PCIe_TL_VIP_Integration_Guide.md`

**Interfaces:**
- Consumes all previous task APIs and test results.
- Produces the final usage matrix for TL-only, dual SVT, DUT/SERDES, four-SVT, and reserved PIPE.

- [ ] **Step 1: Run repository-level static checks**

```sh
./svt_pcie_integration/sim/check_pcie_svt_link_macros.sh
./svt_pcie_integration/sim/check_tl_svt_bridge_contract.sh
git diff --check
```

- [ ] **Step 2: Run the TL-only regression gate**

Use the existing TL filelist and representative smoke, switch, root-mapping, and unified-memory tests. Expected: no new SVT dependency and the existing pass criteria remain unchanged.

- [ ] **Step 3: Run dual-SVT data-plane validation on the VCS host**

Run `pcie_tl_svt_formal.f` and confirm L0, `PCIE_TL_SVT_TLP_PASS`, RC/EP readback markers, and zero UVM errors/fatals. Record exact commands and log paths in the task report.

- [ ] **Step 4: Update documentation with the public macro contract**

Document the fixed `mode × width × transport` call, interface signal direction, `SVT RC + DUT EP`/`DUT RC + SVT EP` role selection, and the explicit PIPE guard. State that DUT top-level wiring and clocks/resets remain user responsibilities.

- [ ] **Step 5: Commit documentation and verification results**

```sh
git add svt_pcie_integration/sim/README.md \
  docs/pcie_unified_environment_usage.md \
  pcie_tl_vip/docs/PCIe_TL_VIP_Integration_Guide.md
git commit -m "docs: document SVT link macro usage and verification"
```
