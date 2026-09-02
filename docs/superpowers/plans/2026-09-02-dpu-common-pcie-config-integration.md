# DPU-common PCIe Configuration Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the resolved `virtio_work/dpu_common` snapshot the single source of PCIe device identity and resource placement while allowing one unified test entry point to select the TL or SVT backend.

**Architecture:** Keep `pcie_tl_env` and `pcie_svt_topology_env` as the protocol implementations. Add an optional DPU integration layer that consumes frozen DPU snapshots, projects BDF/BAR/function data into `pcie_global_cfg`, and supplies backend-specific register executors. Complete `pcie_unified_env` so it creates exactly one protocol child and dispatches the common stage sequence.

**Tech Stack:** SystemVerilog, UVM 1.2, VCS, Synopsys SVT PCIe R-2020.12, `dpu_resource_pkg` from `virtio_work`.

**Spec:** `docs/superpowers/specs/2026-09-02-dpu-common-pcie-config-integration-design.md`

## Global Constraints

- `dpu-common` remains an external dependency and is never copied or modified.
- The frozen `dpu_device_snapshot` is the only source for resolved BDF and BAR values.
- PCIe topology, link width/generation, SVT slots, and VIF bindings remain PCIe-side data.
- Serial is the only implemented SVT transport; PIPE remains rejected.
- Existing native TL and SVT environments remain intact until equivalent unified tests pass.
- New and modified code must contain comments describing ownership, source values, and stage ordering.
- Any destructive cleanup must be preceded by `rg` reference checks and an active-filelist check.

---

### Task 1: Add the optional DPU integration package and attachment model

**Files:**
- Create: `pcie_dpu_integration/src/pcie_dpu_attachment_cfg.sv`
- Create: `pcie_dpu_integration/src/pcie_dpu_integration_pkg.sv`
- Create: `pcie_dpu_integration/sim/pcie_dpu_integration.f`
- Test: `pcie_dpu_integration/tests/pcie_dpu_attachment_unit_test.sv`

**Interfaces:**
- Consumes: `dpu_resource_pkg` types, `pcie_topology_pkg` types.
- Produces: `pcie_dpu_attachment_cfg`, a typed mapping from a DPU function key to a PCIe physical node/link, including `function_key`, `physical_node_id`, `link_id`, `function_number`, and optional `has_function_number`.

- [x] **Step 1: Write the failing test**

  Add a UVM unit test that creates two attachments, verifies valid function/link lookup, rejects duplicate function keys, rejects empty link IDs, and rejects a function-number collision on one physical Endpoint.

- [x] **Step 2: Run the test to verify it fails**

  Run:

  ```bash
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -f pcie_dpu_integration/sim/pcie_dpu_integration.f -top pcie_dpu_attachment_unit_test
  ```

  Expected: compilation fails because the attachment class and package are not defined.

- [x] **Step 3: Implement the minimal attachment model**

  Define a UVM object with dynamic attachment records and these methods:

  ```systemverilog
  function bit add(
      dpu_function_key_t function_key,
      string physical_node_id,
      string link_id,
      bit has_function_number,
      int unsigned function_number,
      output string why);
  function bit find_by_function(
      dpu_function_key_t function_key,
      output string physical_node_id,
      output string link_id,
      output bit has_function_number,
      output int unsigned function_number);
  function bit validate(output string errors[$]);
  ```

  Keep the package independent of SVT classes; import only the common topology and DPU resource packages.

- [x] **Step 4: Run the test to verify it passes**

  Re-run the focused VCS command and require `UVM_ERROR=0` and `UVM_FATAL=0`.

- [x] **Step 5: Commit**

  ```bash
  git add pcie_dpu_integration
  git commit -m "feat: add DPU to PCIe physical attachment model"
  ```

### Task 2: Project a frozen DPU snapshot into PCIe device policy

**Files:**
- Create: `pcie_dpu_integration/src/pcie_dpu_cfg_adapter.sv`
- Modify: `pcie_dpu_integration/src/pcie_dpu_integration_pkg.sv`
- Test: `pcie_dpu_integration/tests/pcie_dpu_cfg_adapter_unit_test.sv`

**Interfaces:**
- Consumes: frozen `dpu_device_snapshot`, optional frozen `dpu_resource_snapshot`, `pcie_topology_cfg`, and `pcie_dpu_attachment_cfg`.
- Produces: `pcie_global_cfg` with device BDF/BAR projections and unchanged topology; errors before any backend child is created.

- [x] **Step 1: Write the failing projection tests**

  Build a minimal DPU configuration with one PF0, a pinned BDF, and three BAR pairs. Resolve and freeze it through `dpu_device_resolver`. Assert that the adapter emits the same BDF, BAR bases, sizes, 64-bit flags, and role mapping. Add negative tests for an unfrozen snapshot, a missing attachment, and an overlapping/invalid BAR pair.

- [x] **Step 2: Run the tests to verify they fail**

  Run the focused adapter test through the DPU integration filelist. Expected: failure because `pcie_dpu_cfg_adapter` is not defined.

- [x] **Step 3: Implement the projection**

  Add:

  ```systemverilog
  class pcie_dpu_cfg_adapter extends uvm_object;
    function bit project(
        dpu_device_snapshot device_snapshot,
        dpu_resource_snapshot resource_snapshot,
        pcie_topology_cfg topology,
        pcie_dpu_attachment_cfg attachments,
        output pcie_global_cfg global_cfg,
        output string errors[$]);
  endclass
  ```

  Require both snapshots to be frozen. Copy each resolved function into one `pcie_device_cfg`; copy the resolved BAR pair base/size into the low/high `pcie_unified_bar_cfg` entries; map Device Memory, Mailbox, and MSI-X to BAR0/1, BAR2/3, and BAR4/5. Use the attachment map to associate functions with physical links. Do not call any PCIe allocator.

  Add a clearly commented conversion for domain-qualified BDFs and per-root enumeration windows. Reject a projection if an attachment is absent or if one physical link receives incompatible function ownership.

- [x] **Step 4: Run the tests to verify they pass**

  Require positive and negative projection tests to pass and confirm no protocol environment is constructed by the unit test.

- [x] **Step 5: Commit**

  ```bash
  git add pcie_dpu_integration
  git commit -m "feat: project DPU snapshots into PCIe global policy"
  ```

### Task 3: Make the unified environment create the selected protocol child

**Files:**
- Modify: `svt_pcie_integration/uvm/env/pcie_unified_env.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Test: `svt_pcie_integration/uvm/tests/pcie_unified_env_unit_test.sv`

**Interfaces:**
- Consumes: `pcie_global_cfg`, projected topology/device policy, and optional DPU snapshot projection.
- Produces: exactly one `pcie_tl_custom_env` for `PCIE_BACKEND_TL_ONLY` or one `pcie_svt_topology_env` for `PCIE_BACKEND_SVT_REAL_DUT`.

- [x] **Step 1: Extend the unit test with failing child-selection cases**

  Add one test that sets `PCIE_BACKEND_TL_ONLY` and asserts `env.tl_env` is non-null while `env.svt_env` is null. Add a second test that sets `PCIE_BACKEND_SVT_REAL_DUT` and asserts the inverse. Add a negative test that supplies an invalid projected policy and asserts no child is created.

- [x] **Step 2: Run the tests to verify the current failure**

  Run the unified environment unit test. Expected: the TL case fails because the current environment creates no TL child.

- [x] **Step 3: Implement explicit child ownership**

  Add a `pcie_tl_custom_env tl_env` handle beside `svt_env`. For TL backend, publish `topology_cfg` and a translated `pcie_tl_env_config` under `tl_env`, then create `pcie_tl_custom_env`. For SVT backend, preserve the existing SVT creation path but copy every projected link/device policy field required by the adapter, not only DUT node IDs and HDL slots. Keep `pcie_global_cfg` backend-neutral; do not add a hard dependency on `dpu_resource_pkg` to the TL topology package.

  Add comments explaining that only one child is built per run and that the topology graph remains authoritative.

- [x] **Step 4: Run all affected unit tests**

  Run the unified environment unit test and the existing TL topology adapter tests. Require no regressions in native TL construction.

- [ ] **Step 5: Commit**

  ```bash
  git add svt_pcie_integration/uvm
  git commit -m "feat: connect TL and SVT children through unified environment"
  ```

### Task 4: Add transport-specific DPU register executors

**Files:**
- Create: `pcie_dpu_integration/src/pcie_dpu_reg_executor_base.sv`
- Create: `pcie_dpu_integration/src/pcie_dpu_tl_reg_executor.sv`
- Create: `svt_pcie_integration/uvm/backend/pcie_dpu_svt_reg_executor.sv`
- Modify: `pcie_dpu_integration/src/pcie_dpu_integration_pkg.sv`
- Test: `pcie_dpu_integration/tests/pcie_dpu_tl_reg_executor_unit_test.sv`
- Test: `svt_pcie_integration/uvm/tests/pcie_dpu_svt_reg_executor_unit_test.sv`

**Interfaces:**
- Consumes: frozen `dpu_reg_plan`, selected RC sequencer, and backend-specific environment handles.
- Produces: `dpu_execution_report` with preflight and execution status; no resource allocation.

- [ ] **Step 1: Write failing executor contract tests**

  Create a small plan containing one PCI config write, one MMIO write, and one read/verify. Assert that null plans, unfrozen plans, unsupported target spaces, and missing sequencers are rejected before execution.

- [ ] **Step 2: Run tests to verify they fail**

  Run the focused executor tests. Expected: the executor classes are missing.

- [ ] **Step 3: Implement the neutral contract and TL executor**

  The base adapter must validate plan freezing and expose a common `configure(...)` method. The TL executor must map PCI config and MMIO operations to existing TL config/memory sequence types and use the selected `pcie_tl_virtual_sequencer`. Preserve operation dependencies and return readback mismatches as execution failures.

- [ ] **Step 4: Implement the SVT executor**

  Map config and memory operations to SVT RC sequence calls through the existing SVT virtual sequencer. Keep SVT-specific imports in the SVT integration filelist; the DPU common package must not import SVT.

- [ ] **Step 5: Run focused tests to verify both executors pass**

  Require all contract tests to pass with zero UVM errors and verify that the same plan ordering is preserved in both backends.

- [ ] **Step 6: Commit**

  ```bash
  git add pcie_dpu_integration svt_pcie_integration/uvm/backend
  git commit -m "feat: execute DPU register plans through PCIe backends"
  ```

### Task 5: Integrate DPU resolve and the common stage sequence

**Files:**
- Create: `pcie_dpu_integration/src/pcie_dpu_system_cfg.sv`
- Create: `pcie_dpu_integration/src/pcie_dpu_system_env.sv`
- Modify: `svt_pcie_integration/uvm/tests/pcie_device_base_test.sv`
- Modify: `svt_pcie_integration/uvm/sequences/pcie_global_stage_vseq.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Test: `pcie_dpu_integration/tests/pcie_dpu_system_env_unit_test.sv`

**Interfaces:**
- Consumes: `dpu_device_cfg`, placement policy, attachment records, and backend selection.
- Produces: resolved snapshots, projected global PCIe policy, one protocol child, and ordered stage dispatch.

- [ ] **Step 1: Write the failing lifecycle test**

  Assert the lifecycle order using a spy executor and a minimal one-function configuration: DPU resolution precedes child creation; TL runs config/bootstrap/VIO operations; SVT runs link/config/enumeration hooks before the same DPU plans. Assert that an unresolved snapshot prevents child construction.

- [ ] **Step 2: Run the lifecycle test to verify it fails**

  Run the focused system environment test. Expected: the current global stage sequence only logs requests and does not dispatch backend operations.

- [ ] **Step 3: Implement system configuration ownership**

  `pcie_dpu_system_cfg` stores the DPU authoring config, placement config, physical attachment map, topology graph, backend, and executor. `pcie_dpu_system_env` resolves DPU state before publishing immutable snapshot handles and before creating the unified PCIe child. Use explicit parent-child ordering; do not rely on sibling build order.

- [ ] **Step 4: Implement backend stage dispatch**

  Replace logging-only hooks with backend-specific dispatch:

  ```text
  TL: config/BAR -> DPU bootstrap plan -> DPU VIO plan -> traffic
  SVT: cfg_init -> link-up -> enumeration -> DPU bootstrap plan -> DPU VIO plan -> traffic
  ```

  Keep each stage overridable and document which sequencer handle it consumes.

- [ ] **Step 5: Run lifecycle and existing tests**

  Run the DPU system unit test, unified environment unit test, existing SVT topology model/adapter tests, and TL global-cfg tests.

- [ ] **Step 6: Commit**

  ```bash
  git add pcie_dpu_integration svt_pcie_integration/uvm
  git commit -m "feat: orchestrate DPU resolution and PCIe stages"
  ```

### Task 6: Add the single-function EP x16 integration example

**Files:**
- Create: `pcie_dpu_integration/tests/pcie_dpu_ep_x16_test.sv`
- Modify: `pcie_dpu_integration/sim/pcie_dpu_integration.f`
- Modify: `svt_pcie_integration/sim/pcie_svt_topology.f`
- Modify: `svt_pcie_integration/sim/README.md`
- Test: VCS compile/elaboration and controlled plan-execution smoke test

**Interfaces:**
- Consumes: the system environment and one DPU PF0 configuration.
- Produces: a repeatable EP x16 example with DPU-owned BDF/BAR values.

- [ ] **Step 1: Add the test skeleton and expected failure checks**

  Register a test that builds one RC-to-EP x16 topology, one DPU PF0 with a pinned BDF, and the three BAR pairs. Initially assert the expected system environment handle and stage result; run before implementing the integration and capture the failure.

- [ ] **Step 2: Implement the minimum example configuration**

  Use the current project BAR profile only where it matches the DPU role mapping. Publish the physical attachment for `RC0_EP0`. Make the backend selectable without changing the DPU authoring object.

- [ ] **Step 3: Run TL compile and plan smoke**

  Use the TL filelist with the DPU integration include paths. Verify BDF/BAR projection, plan ordering, and zero UVM errors.

- [ ] **Step 4: Run SVT compile/elaboration on the VCS host**

  On `10.11.10.53`, use a login shell and the R-2020.12 environment. Compile the EP x16 profile with Serial and verify the HDL slot contract and environment construction. Do not claim real-DUT link success when using the placeholder wrapper.

- [ ] **Step 5: Commit**

  ```bash
  git add pcie_dpu_integration svt_pcie_integration/sim
  git commit -m "test: add DPU-owned EP x16 integration example"
  ```

### Task 7: Audit and remove only obsolete files and update documentation

**Files:**
- Modify: `svt_pcie_integration/sim/README.md`
- Modify: `docs/pcie_unified_environment_usage.md`
- Modify: `pcie_tl_vip/docs/PCIe_TL_VIP_Integration_Guide.md`
- Delete: only files shown by `rg` to be unreferenced after Tasks 1–6
- Test: filelist/package/reference audit scripts

- [ ] **Step 1: Build the deletion candidate list**

  Run this exact audit after the unified tests pass:

  ```bash
  while IFS= read -r file; do
    stem="$(basename "$file" .sv)"
    count="$(rg -n "$stem" svt_pcie_integration pcie_tl_vip --glob '*.sv' --glob '*.svh' --glob '*.f' --glob '*.md' | wc -l)"
    printf '%s %s\n' "$count" "$file"
  done < <(find svt_pcie_integration pcie_tl_vip -type f -name '*.sv' -o -name '*.svh' | sort)
  ```

  A file is a deletion candidate only when its count is one (the file itself)
  and it is not listed by an active filelist or included by a package. Do not
  delete `pcie_tl_env`, `pcie_svt_topology_env`, focused unit tests, or
  compatibility tests before their replacements pass.

- [ ] **Step 2: Remove only confirmed obsolete entries**

  Delete stale duplicate/proxy/sidecar sources only when no active package, filelist, test, or documentation references them. Use `apply_patch` for each deletion and describe the reason in the commit.

- [ ] **Step 3: Update usage documentation**

  Document `dpu-common` as the device-config authority, the attachment mapping, the two executors, the stage order, and the requirement to set `DPU_COMMON_ROOT`/`PCIE_SVT_ROOT` without hard-coded developer paths.

- [ ] **Step 4: Run the complete audit**

  Run `git diff --check`, active filelist duplicate checks, all available TL unit tests, and SVT compile/elaboration checks. Confirm no deleted file remains in a package include or filelist.

- [ ] **Step 5: Commit**

  ```bash
  git add -A
  git commit -m "chore: remove obsolete PCIe integration paths"
  ```
