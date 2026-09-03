# PCIe TL Root Environment and SVT Adapter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task with verification checkpoints.

**Goal:** 收敛 PCIe 集成结构，使 `pcie_tl_env` 成为唯一根环境，SVT 仅通过 `pcie_tl_if_adapter` 工厂覆盖接入 Serial/PIPE 和真实 DUT。

**Architecture:** 复用 `xillinx_pcie/feat/adapter-mode` 的边界：TL env 继续拥有配置、sequence、枚举、BAR、Memory 和 Completion；SVT adapter 负责 TLP 编解码、正式 SVT Mapper 绑定以及物理接口。双侧 SVT peer 环境只作为独立 link self-check，不进入生产 TL filelist。

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys SVT PCIe R-2020.12, VCS W-2024.09-SP1, Serial transport first.

**Spec:** `docs/superpowers/specs/2026-09-03-pcie-tl-root-svt-adapter-design.md`

## Global Constraints

- `pcie_tl_vip` 的 TL-only API、filelist 和现有测试必须保持兼容。
- 生产控制面只能有一个根环境：`pcie_tl_env` 或其拓扑薄包装 `pcie_tl_custom_env`。
- SVT Mapper 必须来自正式 `svt_pcie_device_agent.tlp_mapper`，禁止孤立 Mapper。
- 默认只验证 Serial；PIPE 保留明确的扩展接口，不在本阶段声称可运行。
- 新增和修改代码使用中文注释、合理空行和清晰的上下文分段。
- 仿真验证必须在 `10.11.10.53` 上通过登录 shell 执行。
- `pcie_dpu_integration` 是可选配置来源，不能继续依赖已删除的
  `pcie_unified_env`；DPU 适配必须保持独立，并将最终策略投影到原生
  `pcie_tl_env` 配置接口。

### Task 1: Establish the TL-only baseline

**Files:**
- Test: existing `pcie_tl_vip/sim/filelist.f` and representative TL tests
- Modify: none unless the baseline exposes an existing compile break

**Interfaces:**
- Consumes: current `pcie_tl_env`, `pcie_tl_custom_env`, and TL package.
- Produces: a recorded clean baseline proving the cleanup starts without an unexplained TL regression.

- [ ] **Step 1: Run static checks**

Run:

```sh
./svt_pcie_integration/sim/check_tl_svt_bridge_contract.sh
git diff --check
```

Expected: contract pass and no whitespace errors.

- [ ] **Step 2: Run the representative TL-only compile/regression on host 53**

Run the existing `pcie_tl_vip/sim/run.sh` flow with the repository's configured VCS environment and capture the exact command, exit status, and UVM summary. Do not modify SVT files during this step.

- [ ] **Step 3: Commit the baseline record**

```sh
git add docs/superpowers/plans/2026-09-03-pcie-tl-root-svt-adapter.md
git commit -m "docs: plan TL root SVT adapter convergence"
```

### Task 2: Remove duplicate production management layers

**Files:**
- Delete: `svt_pcie_integration/uvm/env/pcie_unified_env.sv`
- Delete: `svt_pcie_integration/uvm/backend/pcie_backend_base.sv`
- Delete: `svt_pcie_integration/uvm/backend/pcie_tl_backend.sv`
- Delete: `svt_pcie_integration/uvm/backend/pcie_svt_backend.sv`
- Keep: `svt_pcie_integration/uvm/backend/pcie_dpu_svt_reg_executor.sv` because the independent DPU register-executor filelist consumes it; it does not own a PCIe environment.
- Move to test-only filelist: `svt_pcie_integration/uvm/env/pcie_svt_topology_env.sv`
- Move to test-only filelist: `svt_pcie_integration/uvm/env/pcie_svt_topology_virtual_sequencer.sv`
- Move to test-only filelist: `svt_pcie_integration/uvm/cfg/pcie_svt_profile_factory.sv`
- Move to test-only filelist: `svt_pcie_integration/uvm/cfg/pcie_svt_cli_parser.sv`
- Move to test-only filelist: `svt_pcie_integration/uvm/cfg/pcie_svt_topology_policy_cfg.sv`
- Move to test-only filelist: `svt_pcie_integration/uvm/cfg/pcie_svt_device_cfg_builder.sv`
- Move to test-only filelist: `svt_pcie_integration/uvm/cfg/pcie_svt_cfg_space_builder.sv`
- Move to test-only filelist: `svt_pcie_integration/uvm/adapter/pcie_svt_topology_adapter.sv`
- Move to test-only filelist: `svt_pcie_integration/uvm/sequences/pcie_global_stage_vseq.sv`
- Move to test-only filelist: `svt_pcie_integration/uvm/sequences/pcie_svt_cfg_init_vseq.sv`
- Move to test-only filelist: `svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_vseq.sv`
- Move to test-only filelist: `svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_registry.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Modify: SVT production filelists under `svt_pcie_integration/sim/`
- Modify: `pcie_dpu_integration/src/pcie_dpu_system_env.sv`,
  `pcie_dpu_integration/src/pcie_dpu_device_base_test.sv`, and related package
  filelists so the optional DPU path no longer inherits `pcie_unified_env`.
- Keep: `pcie_svt_peer_test.sv` and the listed self-check dependencies in a test-only filelist until the replacement adapter test is green. They must not be included by the production TL-root adapter filelist.

**Interfaces:**
- Consumes: `pcie_tl_env` and existing SVT codec/adapter types.
- Produces: a package that does not define a second global environment or duplicate TL control sequences.

- [ ] **Step 1: Search all references before deletion**

Run:

```sh
rg -n "pcie_unified_env|pcie_svt_topology_env|pcie_svt_profile_factory|pcie_svt_cli_parser|pcie_svt_cfg_init_vseq|pcie_svt_enumeration" .
```

Classify every hit as production, peer self-check, documentation, or stale historical note. Update production references before deleting files.

- [ ] **Step 2: Delete only classified duplicate production files**

Use `apply_patch` delete operations. Do not delete TL package files, TL sequences, Serial interfaces, codec files, or the peer self-check until their replacement filelist is present.

- [ ] **Step 3: Build the reduced package statically**

Run:

```sh
./svt_pcie_integration/sim/check_tl_svt_bridge_contract.sh
git diff --check
```

Expected: no deleted file remains in an active production filelist and the TL-only filelist is unchanged.

- [ ] **Step 4: Commit the cleanup**

```sh
git add -A svt_pcie_integration
git commit -m "refactor: remove duplicate SVT management layers"
```

- [ ] **Step 5: Compile the optional DPU package statically**

Run the DPU package filelist with `dpu-common` supplied.  The expected result
is that DPU configuration translation remains independently compilable and no
source references `pcie_unified_env` or the deleted backend classes.

### Task 3: Implement the TL-root SVT adapter seam

**Files:**
- Modify: `svt_pcie_integration/uvm/adapter/pcie_svt_if_adapter.sv`
- Modify: `svt_pcie_integration/uvm/adapter/pcie_svt_adapter_types.sv`
- Modify: `svt_pcie_integration/uvm/adapter/pcie_svt_tlp_codec.sv`
- Create: `svt_pcie_integration/uvm/adapter/pcie_svt_agent_adapter.sv`
- Create: `svt_pcie_integration/uvm/adapter/pcie_svt_adapter_pkg.sv`
- Modify: `pcie_tl_vip/src/pcie_tl_pkg.sv` only if a stable factory registration include is required; preserve TL-only compilation when `PCIE_SVT_AVAILABLE` is absent.

**Interfaces:**
- Consumes: `pcie_tl_if_adapter::send/receive`, TL `pcie_tl_tlp`, official `svt_pcie_device_agent.tlp_mapper`.
- Produces: `pcie_svt_if_adapter extends pcie_tl_if_adapter`, with `bind_agent(svt_pcie_device_agent agent)`, `send(pcie_tl_tlp)`, and `receive(output pcie_tl_tlp)`.

- [ ] **Step 1: Add a failing adapter construction test**

Create a test that installs the factory override, builds one RC and one EP official SVT agent, and asserts that each selected adapter receives a non-null `tlp_mapper` plus valid application/service handles. The test must fail if the adapter creates a Mapper itself.

- [ ] **Step 2: Run the construction test and capture the expected failure**

Run the new focused VCS filelist on host 53. Expected initial failure: the current bridge path has no formal agent Mapper binding or still reports the old isolated Mapper contract.

- [ ] **Step 3: Implement formal-agent binding**

In `bind_agent`, reject null agents and null `agent.tlp_mapper`; copy only the public Mapper handle and route metadata. Do not start an SVT service thread from the adapter and do not create `svt_pcie_tlp_mapper` with `type_id::create`.

- [ ] **Step 4: Connect public Mapper ports**

Connect the adapter bridge to `tx_tlp_in_export[]` and `rx_tlp_out_port[]` using the existing codec and route metadata. Ensure the adapter is `SV_IF_MODE`, so the TL environment does not enter TLM loopback or duplicate completion handling.

- [ ] **Step 5: Run the focused construction test again**

Expected: formal agent Mapper binding passes, no null service-port fatal occurs during build/run, and the test reports zero UVM errors/fatals.

- [ ] **Step 6: Commit the adapter seam**

```sh
git add svt_pcie_integration/uvm/adapter pcie_tl_vip/src/pcie_tl_pkg.sv
git commit -m "feat: make TL root own SVT adapter binding"
```

### Task 4: Add the production TL-root Serial test

**Files:**
- Create: `svt_pcie_integration/tests/pcie_tl_svt_adapter_base_test.sv`
- Create: `svt_pcie_integration/tests/pcie_tl_svt_adapter_link_test.sv`
- Create: `svt_pcie_integration/sim/pcie_tl_svt_adapter.f`
- Create: `svt_pcie_integration/sim/pcie_tl_svt_adapter_tb.sv`
- Modify: `svt_pcie_integration/sim/README.md`

**Interfaces:**
- Consumes: native `pcie_tl_env`, factory override, SVT formal agent/Serial macros.
- Produces: a user-facing test started with `+UVM_TESTNAME=pcie_tl_svt_adapter_link_test`, `+PCIE_GEN=4`, and `+PCIE_LINK_ONLY`.

- [ ] **Step 1: Configure native TL env**

Set `SV_IF_MODE`, RC/EP enable, `ep_auto_response`, `infinite_credit`, and disabled scoreboard as required by adapter-mode. Publish only `pcie_tl_env_config` under the native `env` scope.

- [ ] **Step 2: Declare and connect official SVT HDL agents**

Use the existing x16 Serial HDL macros in the top-level testbench. Connect RC/EP Serial peers with the existing peer harness and publish VIFs only for adapter binding; do not create a second UVM topology env.

- [ ] **Step 3: Start native TL link/traffic sequence**

Start the existing TL sequence or virtual sequence from the native TL environment. SVT is only the transport endpoint; no SVT CFG or enumeration sequence is started by this test.

- [ ] **Step 4: Run compile/elaboration and link smoke on host 53**

Require VCS status 0, `UVM_ERROR=0`, `UVM_FATAL=0`, and explicit RC/EP link-ready evidence. A placeholder electrical-idle DUT may pass construction only, not link training.

- [ ] **Step 5: Commit the production test**

```sh
git add svt_pcie_integration/tests svt_pcie_integration/sim/pcie_tl_svt_adapter.f svt_pcie_integration/sim/pcie_tl_svt_adapter_tb.sv svt_pcie_integration/sim/README.md
git commit -m "test: add TL-root SVT Serial adapter smoke"
```

### Task 5: Preserve and isolate the peer self-check

**Files:**
- Modify: `svt_pcie_integration/sim/pcie_svt_topology.f`
- Modify: `svt_pcie_integration/uvm/tests/pcie_svt_peer_test.sv`
- Create or modify: `svt_pcie_integration/sim/pcie_svt_peer_selfcheck.f`
- Modify: `svt_pcie_integration/sim/README.md`

**Interfaces:**
- Consumes: official SVT peer agents and Serial harness only.
- Produces: an explicitly test-only `pcie_svt_peer_test` entry that cannot be mistaken for the TL production environment.

- [ ] **Step 1: Move peer-only dependencies to the self-check filelist**

Keep only the files needed to instantiate two official SVT environments, CFG_INIT, and link checking. Do not include this filelist from the TL-root adapter filelist.

- [ ] **Step 2: Run the existing 1RC+1EP/x16/Serial/Gen4 peer self-check**

Expected: `PCIE_SVT_LINK_PASS`, `UVM_ERROR=0`, `UVM_FATAL=0`.

- [ ] **Step 3: Commit the isolation**

```sh
git add svt_pcie_integration/sim svt_pcie_integration/uvm/tests/pcie_svt_peer_test.sv
git commit -m "test: isolate SVT peer link self-check"
```

### Task 6: Final regression and documentation

**Files:**
- Modify: `svt_pcie_integration/sim/README.md`
- Modify: `pcie_tl_vip/docs/PCIe_TL_VIP_Integration_Guide.md` if the adapter contract needs a cross-reference.

- [ ] **Step 1: Run TL-only regression on host 53**

Require unchanged TL-only results and no SVT dependency.

- [ ] **Step 2: Run production TL-root SVT adapter test**

Require formal Mapper binding, zero UVM errors/fatals, and explicit transport/link evidence.

- [ ] **Step 3: Run peer self-check**

Require the independent peer test remains green.

- [ ] **Step 4: Run static contract checks**

```sh
./svt_pcie_integration/sim/check_tl_svt_bridge_contract.sh
git diff --check
git status --short
```

- [ ] **Step 5: Commit final documentation and verification record**

```sh
git add docs/superpowers/specs docs/superpowers/plans svt_pcie_integration/sim/README.md pcie_tl_vip/docs/PCIe_TL_VIP_Integration_Guide.md
git commit -m "docs: record TL-root SVT adapter integration contract"
```
