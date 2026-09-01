# PCIe Unified Global CFG Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a comment-rich, backend-neutral PCIe global configuration and environment manager that reuses the existing TL topology environment and optionally creates only the SVT HDL/UVM resources selected by compile-time macros and runtime link configuration.

**Architecture:** Keep `pcie_topology_cfg` as the authoritative graph. Add device/link/backend policy objects around it, translate the same configuration into either the existing `pcie_tl_custom_env`, the SVT unified device environment, or an explicitly selected SVT↔TL bridge. Generate HDL slots statically behind project-private macros and create UVM children dynamically only for enabled links.

**Tech Stack:** SystemVerilog, UVM, VCS, Synopsys SVT PCIe R-2020.12, existing `pcie_tl_vip`, host_mem package.

**Spec:** `docs/superpowers/specs/2026-09-01-pcie-unified-global-cfg-design.md`

## Global Constraints

- Preserve `pcie_topology_cfg` as the single source of truth for node/link connectivity.
- Do not override Synopsys `SVT_PCIE_MAX_NUM_LINKS`; use project-private HDL/link limit macros.
- HDL interfaces, SVT HDL agents, and `SVT_PCIE_UI_NUM_PHYSICAL_LANES` remain compile-time static.
- UVM link/backend arrays are dynamic and are sized only after global configuration is validated.
- `TL_ONLY` must not instantiate SVT HDL agents or old SVT proxy/sidecar data paths.
- `SVT_REAL_DUT` must not route real DUT traffic through the TL proxy.
- Every created SystemVerilog file gets a file header; every public class, field, macro, phase and adapter method gets a concrete comment explaining ownership and mapping.
- Existing valid official comments remain in place; project behavior is added around them instead of replacing them with uncommented code.
- Do not delete legacy files until the replacement filelists compile and the no-regression checks pass.
- VCS simulation validation runs on `10.11.10.53` with a login shell and the configured Synopsys license environment.

### Task 1: Add project compile limits and backend-neutral configuration objects

**Files:**
- Create: `pcie_tl_vip/src/topology/pcie_unified_backend_types.sv`
- Create: `pcie_tl_vip/src/topology/pcie_device_cfg.sv`
- Create: `pcie_tl_vip/src/topology/pcie_link_cfg.sv`
- Create: `pcie_tl_vip/src/topology/pcie_global_cfg.sv`
- Modify: `pcie_tl_vip/src/topology/pcie_topology_pkg.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Modify: `pcie_tl_vip/sim/filelist.f`
- Modify: `svt_pcie_integration/sim/pcie_svt_topology.f`
- Test: `pcie_tl_vip/tests/pcie_global_cfg_unit_test.sv`

**Interfaces:**
- `pcie_backend_e` values: `PCIE_BACKEND_TL_ONLY`, `PCIE_BACKEND_SVT_REAL_DUT`, `PCIE_BACKEND_SVT_TL_FORWARD`.
- `pcie_device_cfg` fields: `device_id`, `role`, `bdf`, `header_type`, `bars[6]`, and `cfg_space_enable`.
- `pcie_link_cfg` fields: `link_id`, `enabled`, `use_svt`, `role`, `link_width`, `max_gen`, `vif_key`, and `hdl_slot`.
- `pcie_global_cfg::validate(output string errors[$])` checks topology, compile limits, link uniqueness, slot ownership, roles, width/Gen, and backend-specific requirements.
- `pcie_global_cfg::build_default_for_topology(pcie_topology_cfg topology, pcie_global_cfg cfg)` creates one device record per graph node/port and copies the existing six BAR defaults without duplicating topology connectivity.

  These backend-neutral classes live in `pcie_topology_pkg`, not in the SVT package, so the independent TL build can consume them without creating a TL→SVT package dependency cycle.

- [ ] **Step 1: Write the failing unit test**

  Test valid single EP, 2x EP, and Switch configurations; test duplicate link IDs, a runtime link count above the compile limit, duplicate HDL slots, unsupported width/Gen, and a TL-only configuration with no SVT VIF requirements.

- [ ] **Step 2: Run the focused test and verify it fails**

  From the VCS host, use the repository's documented topology compile flow:

  ```bash
  ssh ubuntu@10.11.10.53 'bash -lc "cd /home/ryan/pcie_work/svt_pcie_integration/sim && vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs -f pcie_svt_topology.f -top pcie_svt_topology_top -o simv_global_cfg -l compile_global_cfg.log && ./simv_global_cfg +UVM_TESTNAME=pcie_global_cfg_unit_test -l run_global_cfg.log"'
  ```

  Expected: the test cannot compile because the new cfg classes and project macros are not present.

- [ ] **Step 3: Implement the configuration objects**

  Add a guarded macro header inside `pcie_unified_backend_types.sv`:

  ```systemverilog
  `ifndef PCIE_SVT_ENV_MAX_HDL_AGENTS
    `ifdef PCIE_TOPO_EP_X16
      `define PCIE_SVT_ENV_MAX_HDL_AGENTS 1
    `elsif PCIE_TOPO_EP_2X8
      `define PCIE_SVT_ENV_MAX_HDL_AGENTS 2
    `elsif PCIE_TOPO_SWITCH_1X16_4X4
      `define PCIE_SVT_ENV_MAX_HDL_AGENTS 5
    `else
      `define PCIE_SVT_ENV_MAX_HDL_AGENTS 1
    `endif
  `endif
  `ifndef PCIE_SVT_ENV_MAX_NUM_LINKS
    `define PCIE_SVT_ENV_MAX_NUM_LINKS `PCIE_SVT_ENV_MAX_HDL_AGENTS
  `endif
  ```

  Implement deep-copy and validation methods. The comments must explicitly distinguish compile-time HDL slots from runtime enabled links and explain that `pcie_topology_cfg` remains authoritative for connectivity.

- [ ] **Step 4: Add the classes to package/filelist in dependency order**

  Include backend types before device/link/global cfg, and include the unit test after the package. Keep existing SVT types and official package imports before the new project classes.

- [ ] **Step 5: Run the focused unit test and verify it passes**

  Re-run the command above and require zero UVM errors and explicit checks for all three default topology profiles.

- [ ] **Step 6: Commit**

  ```bash
  git add pcie_tl_vip/src/topology pcie_tl_vip/tests/pcie_global_cfg_unit_test.sv pcie_tl_vip/sim/filelist.f svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv svt_pcie_integration/sim/pcie_svt_topology.f
  git commit -m "feat: add backend-neutral PCIe global configuration"
  ```

### Task 2: Translate device configuration into independent TL config/BAR contexts

**Files:**
- Create: `pcie_tl_vip/src/topology/pcie_tl_device_cfg_adapter.sv`
- Modify: `pcie_tl_vip/src/pcie_tl_pkg.sv`
- Modify: `pcie_tl_vip/src/env/pcie_tl_env_config.sv`
- Modify: `pcie_tl_vip/src/env/pcie_tl_env.sv`
- Modify: `pcie_tl_vip/src/switch/pcie_tl_switch.sv`
- Test: `pcie_tl_vip/tests/pcie_tl_device_cfg_adapter_unit_test.sv`
- Test: `pcie_tl_vip/tests/pcie_tl_switch_endpoint_cfg_test.sv`

**Interfaces:**
- `pcie_tl_device_cfg_adapter::apply_device_cfg(pcie_device_cfg src, pcie_tl_func_context dst, output string errors[$])`.
- `pcie_tl_env_config::device_cfgs[]` stores per-device records while retaining all existing fields and defaults.
- `pcie_tl_env::device_cfg_contexts[bit[15:0]]` maps every configured BDF to an independent `pcie_tl_func_context`.
- `pcie_tl_switch::endpoint_cfg_by_port[]` maps DSP index to the downstream Endpoint Type-0 image; `pcie_tl_switch_port` continues to own only the Type-1 USP/DSP image.

- [ ] **Step 1: Write failing tests**

  Add tests that configure two direct EPs with different BDFs and BAR0 apertures, then configure two DSP endpoints under one USP with distinct Type-0 images. Assert that a BAR sizing write/read and a config-space read on one BDF do not change the other BDF.

- [ ] **Step 2: Run the tests and verify the current limitation**

  Run the focused TL filelist with `+UVM_TESTNAME=pcie_tl_device_cfg_adapter_unit_test` and `+UVM_TESTNAME=pcie_tl_switch_endpoint_cfg_test`. Expected: the new tests fail or expose the current shared-manager behavior.

- [ ] **Step 3: Implement the adapter and per-device map**

  Copy BAR flags, size, base, enable state, and Type-0 header fields into independent function contexts. Preserve existing `cfg_mgrs[]` aliases for old tests. For switch mode, route Type-1 requests to `pcie_tl_switch_port` and downstream Type-0 requests to the BDF-indexed Endpoint context. Do not change memory routing semantics or the existing DSP owner/USP bus-window calculations.

- [ ] **Step 4: Run the focused tests and verify isolation**

  Require distinct config reads, independent BAR sizing masks, no duplicate BDF fatal, and successful memory routing for each configured DSP.

- [ ] **Step 5: Run the existing TL regression subset**

  Run the existing multi-pair, switch config, switch readback, multi-root, BAR decoder, and topology adapter tests. Expected: all pre-existing tests remain green.

- [ ] **Step 6: Commit**

  ```bash
  git add pcie_tl_vip/src pcie_tl_vip/tests
  git commit -m "feat: map global device cfg to independent TL contexts"
  ```

### Task 3: Add the unified backend environment and base test

**Files:**
- Create: `svt_pcie_integration/uvm/backend/pcie_backend_base.sv`
- Create: `svt_pcie_integration/uvm/backend/pcie_tl_backend.sv`
- Create: `svt_pcie_integration/uvm/backend/pcie_svt_backend.sv`
- Create: `svt_pcie_integration/uvm/env/pcie_unified_env.sv`
- Create: `svt_pcie_integration/uvm/tests/pcie_device_base_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt_topology.f`

**Interfaces:**
- `pcie_backend_base::configure(pcie_global_cfg cfg)`.
- `pcie_backend_base::build_backend(uvm_phase phase)` and `connect_backend(uvm_phase phase)`.
- `pcie_unified_env.global_cfg`, `pcie_unified_env.tl_backend`, `pcie_unified_env.svt_backend`, and `pcie_unified_env.active_backend`.
- `pcie_device_base_test::build_global_cfg()` and `pcie_device_base_test::select_backend()` are virtual hooks for user tests.

- [ ] **Step 1: Write failing construction tests**

  Add three smoke tests derived from `pcie_device_base_test`: TL-only creates only the TL child, SVT real-DUT creates only the SVT child, and an invalid runtime link count causes the exact global-cfg fatal before child construction.

- [ ] **Step 2: Run the tests and verify they fail**

  Compile the new test names with the existing topology tops. Expected: classes and backend children are not defined.

- [ ] **Step 3: Implement the backend interface and unified env**

  The unified env reads one `pcie_global_cfg`, validates it once, and creates only the backend required by `cfg.backend`. Use dynamic arrays for enabled link descriptors and never size arrays from a hard-coded five-port constant. Keep all backend-specific objects behind their adapter class so the base test does not access TL or SVT internals directly.

- [ ] **Step 4: Implement the official-style base test**

  Preserve the official build ordering: parse command line, create configuration objects, set VIF/config handles, create env, then let the backend create agents. Add explicit comments explaining the difference between VIF handle presence and `connect_active_vip` drive enable.

- [ ] **Step 5: Run construction tests**

  Require component-tree checks proving inactive backends and disabled links have no created agent children.

- [ ] **Step 6: Commit**

  ```bash
  git add svt_pcie_integration/uvm/backend svt_pcie_integration/uvm/env/pcie_unified_env.sv svt_pcie_integration/uvm/tests/pcie_device_base_test.sv svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv svt_pcie_integration/sim/pcie_svt_topology.f
  git commit -m "feat: add unified PCIe backend environment"
  ```

### Task 4: Replace hard-coded HDL slot generation with macro-limited slots

**Files:**
- Create: `svt_pcie_integration/rtl/pcie_svt_hdl_slot_cfg.svh`
- Create: `svt_pcie_integration/rtl/pcie_svt_hdl_slots.sv`
- Modify: `svt_pcie_integration/rtl/pcie_svt_topology_top.sv`
- Modify: `svt_pcie_integration/rtl/pcie_svt_hdl_agent_macros.svh`
- Modify: `svt_pcie_integration/rtl/pcie_svt_reset_if.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt_topology.f`
- Test: `svt_pcie_integration/sim/pcie_svt_hdl_slot_contract_unit_test.sv`

**Interfaces:**
- `PCIE_SVT_ENV_MAX_HDL_AGENTS` controls the number of generated SVT agent slots.
- `pcie_svt_hdl_slots` exports `primary_vif_<slot>` and reset handles for exactly the compiled slots.
- Each slot carries a static width selected by the topology macro; runtime cfg can disable a slot but cannot change x4/x8/x16 physical width.

- [ ] **Step 1: Add the contract test**

  The test parses the generated slot metadata and asserts that EP_X16 emits one slot, EP_2X8 emits two, and SWITCH emits five, while a user override such as `+define+PCIE_SVT_ENV_MAX_HDL_AGENTS=1` rejects a topology requiring more slots during elaboration.

- [ ] **Step 2: Run each topology contract and record current failure**

  Compile with each topology define and the explicit override. Expected: current top still instantiates the fixed topology branches and does not expose the new macro-limited slot contract.

- [ ] **Step 3: Implement static generate branches**

  Move repeated slot declarations into a documented wrapper. Use the existing width-specific SVT macros rather than inventing a runtime lane-width mechanism. Keep VIF keys stable for existing tests and add a slot-to-link map consumed by the UVM backend.

- [ ] **Step 4: Run compile/elaboration for all three modes**

  Use VCS with `PCIE_TOPO_EP_X16`, `PCIE_TOPO_EP_2X8`, and `PCIE_TOPO_SWITCH_1X16_4X4`. Require no duplicate instance, VIF, or reset key.

- [ ] **Step 5: Commit**

  ```bash
  git add svt_pcie_integration/rtl svt_pcie_integration/sim/pcie_svt_topology.f
  git commit -m "feat: limit SVT HDL slots with project macros"
  ```

### Task 5: Connect global device/link cfg to SVT unified VIP

**Files:**
- Modify: `svt_pcie_integration/uvm/backend/pcie_svt_backend.sv`
- Modify: `svt_pcie_integration/uvm/env/pcie_svt_topology_env.sv`
- Modify: `svt_pcie_integration/uvm/cfg/pcie_svt_topology_policy_cfg.sv`
- Modify: `svt_pcie_integration/uvm/cfg/pcie_svt_device_cfg_builder.sv`
- Modify: `svt_pcie_integration/uvm/cfg/pcie_svt_cfg_space_builder.sv`
- Test: `svt_pcie_integration/uvm/tests/pcie_svt_global_cfg_mapping_test.sv`

**Interfaces:**
- `pcie_svt_backend::apply_global_cfg(pcie_global_cfg cfg)` creates dynamic SVT descriptors only for `use_svt && enabled` links.
- `pcie_svt_topology_env::register_link(pcie_link_cfg link, svt_pcie_vif vif)` records the descriptor/config/status/agent mapping.
- `pcie_svt_device_cfg_builder::apply_device_cfg(pcie_device_cfg src, svt_pcie_device_configuration dst)` copies BDF, role, capabilities, and BAR policy.

- [ ] **Step 1: Write mapping tests**

  Test role mismatch, inactive VIF with a non-null handle, active VIF with `connect_active_vip=0`, Gen/width propagation, and six-BAR mapping including 64-bit prefetchable BAR pairs.

- [ ] **Step 2: Run the mapping tests and verify current failures**

  Expected: current topology env can create descriptors but has no global-device mapping or slot-limit enforcement.

- [ ] **Step 3: Implement SVT mapping**

  Preserve the official `device_is_root`/`connect_active_vip` semantics. Use the global cfg role only as an expectation and report a fatal on disagreement. For Endpoint BAR sizing, pass RO maps and Target App callback/service configuration; do not emulate aperture by writing all-ones as a final BAR value.

- [ ] **Step 4: Run the single-EP SVT smoke path**

  On the VCS host, compile and run the x16 environment with `+UVM_TESTNAME=pcie_device_base_test +PCIE_BACKEND=SVT_REAL_DUT +PCIE_GEN=4`. Require link configuration and environment construction to complete without SVT configuration fatal.

- [ ] **Step 5: Commit**

  ```bash
  git add svt_pcie_integration/uvm/backend/pcie_svt_backend.sv svt_pcie_integration/uvm/env/pcie_svt_topology_env.sv svt_pcie_integration/uvm/cfg svt_pcie_integration/uvm/tests/pcie_svt_global_cfg_mapping_test.sv
  git commit -m "feat: map global device cfg into SVT unified VIP"
  ```

### Task 6: Add backend smoke sequences and topology examples

**Files:**
- Create: `svt_pcie_integration/uvm/sequences/pcie_global_link_bringup_vseq.sv`
- Create: `svt_pcie_integration/uvm/sequences/pcie_global_cfg_init_vseq.sv`
- Create: `svt_pcie_integration/uvm/sequences/pcie_global_enum_traffic_vseq.sv`
- Create: `svt_pcie_integration/uvm/tests/pcie_global_tl_only_smoke_test.sv`
- Create: `svt_pcie_integration/uvm/tests/pcie_global_svt_real_dut_smoke_test.sv`
- Create: `svt_pcie_integration/uvm/tests/pcie_global_svt_tl_forward_smoke_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt_topology.f`

**Interfaces:**
- `pcie_global_link_bringup_vseq::start_enabled_links()`.
- `pcie_global_cfg_init_vseq::initialize_devices()`.
- `pcie_global_enum_traffic_vseq::enumerate_and_test_memory()`.

- [ ] **Step 1: Add tests that exercise sequence ordering**

  Assert the required order is link bring-up → configuration-space init → enumeration → memory traffic, and that disabled links are skipped.

- [ ] **Step 2: Implement the sequences with backend dispatch**

  TL-only dispatches to existing TL virtual sequencers and BAR/config sequences. SVT dispatches to the unified SVT virtual sequencer and official service sequences. The hybrid path uses only the explicitly registered adapter links.

- [ ] **Step 3: Run smoke tests for all three backend modes**

  Require deterministic logs showing enabled link IDs, role, width, Gen, BDF, and backend. Any missing VIF or device context must fail with a link-specific message.

- [ ] **Step 4: Commit**

  ```bash
  git add svt_pcie_integration/uvm/sequences svt_pcie_integration/uvm/tests svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv svt_pcie_integration/sim/pcie_svt_topology.f
  git commit -m "test: add unified PCIe bringup and enumeration smoke flows"
  ```

### Task 7: Update documentation, filelists, and remove only proven obsolete code

**Files:**
- Modify: `svt_pcie_integration/sim/README.md`
- Modify: `svt_pcie_integration/sim/pcie_svt.f`
- Modify: `svt_pcie_integration/sim/pcie_svt_topology.f`
- Modify: `pcie_tl_vip/docs/PCIe_TL_VIP_Integration_Guide.md`
- Create: `docs/pcie_unified_environment_usage.md`
- Delete only after reference scan: obsolete duplicate topology/proxy/sidecar files identified by `rg` and the passing filelists.

**Interfaces:**
- Documented plusargs/defines: `PCIE_TOPO_*`, `PCIE_SVT_ENV_MAX_HDL_AGENTS`, `PCIE_SVT_ENV_MAX_NUM_LINKS`, `+PCIE_BACKEND=`, `+PCIE_GEN=`, and runtime link enable syntax.
- Documented user contract: user owns RTL top, SerDes/PIPE wiring, and VIF physical connectivity; environment owns cfg, BDF, BAR policy, sequences, and backend selection.

- [ ] **Step 1: Scan references before deletion**

  Run `rg -n` over all filelists, packages, tests, and docs. Record every obsolete file with zero remaining production references.

- [ ] **Step 2: Update usage docs and comments**

  Include complete commands for TL-only, SVT real-DUT, and hybrid builds. Explain why a VIF handle may exist while `connect_active_vip` is false and why lane width remains compile-time static.

- [ ] **Step 3: Remove only files proven unused**

  Delete obsolete duplicate implementations only after the replacement filelists and tests no longer reference them. Do not delete official example-derived comments that remain useful.

- [ ] **Step 4: Run documentation/filelist lint checks**

  Require no missing include, no deleted-file reference, and no stale macro name that collides with Synopsys macros.

- [ ] **Step 5: Commit**

  ```bash
  git add docs svt_pcie_integration/sim pcie_tl_vip/docs pcie_tl_vip/sim
  git commit -m "docs: document unified PCIe environment usage and cleanup"
  ```

### Task 8: Full VCS verification and final review

**Files:**
- Modify only if verification finds a concrete defect: files from Tasks 1–7.
- Test: all new unit/smoke tests and the existing TL regression list.

**Interfaces:**
- Verification matrix covers compile/elaboration, component-tree counts, TL config/BAR isolation, SVT mapping, and sequence order.

- [ ] **Step 1: Run TL-only regression on `10.11.10.53`**

  Run the existing TL unit and smoke tests, including topology validation, multi-pair, multi-root, switch config, switch readback, BAR decoder, and unified-memory tests. Record the VCS command and summary log.

- [ ] **Step 2: Run SVT compile/elaboration for all three topology macros**

  Build EP_X16, EP_2X8, and SWITCH_1X16_4X4 independently with the smallest valid `PCIE_SVT_ENV_MAX_HDL_AGENTS` value. Confirm no inactive agent is accidentally constructed.

- [ ] **Step 3: Run single EP x16 SVT regression**

  Run link bring-up, configuration-space initialization, enumeration, and basic memory traffic with Gen4 and serial transport. Verify BAR sizing uses the SVT Target App mechanism.

- [ ] **Step 4: Run negative limit checks**

  Compile with an HDL-agent limit below the selected topology requirement and require a clear elaboration/configuration error rather than silent truncation.

- [ ] **Step 5: Review changed files for comments and stale paths**

  Check every new class, macro, dynamic array, adapter, phase, and backend branch for a useful explanatory comment. Confirm no real DUT path uses the old proxy/sidecar.

- [ ] **Step 6: Commit any verified fixes and report evidence**

  Use a focused commit for each fix, then report exact passing commands, topology, backend, macro values, and remaining limitations.
