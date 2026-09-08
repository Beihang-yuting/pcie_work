# SVT Backend Configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional SVT backend to `pcie_tl_env` that creates and configures one SVT device agent per enabled physical link while preserving the existing TL-only API and filelist.

**Architecture:** `pcie_global_cfg` remains backend-neutral and selects `TL_ONLY`, `SVT_REAL_DUT`, or `SVT_TL_FORWARD`. A separate SVT integration package owns the SVT-specific configuration object and backend component; `pcie_tl_env` discovers that backend through a neutral factory/registry hook and injects the resulting adapters before creating TL agents. No SVT type is introduced into the TL-only package.

**Tech Stack:** SystemVerilog, UVM, Synopsys SVT PCIe R-2020.12, VCS.

**Spec:** `docs/superpowers/specs/2026-09-06-svt-backend-configuration-design.md`

## Global Constraints

- TL-only filelists must not depend on Synopsys SVT packages or types.
- Existing direct `pcie_tl_env_config` injection and TL sequence APIs remain compatible.
- UVM agents/config/status are dynamic; HDL slots, lane width, and physical VIFs remain static at elaboration.
- New code uses detailed Chinese comments and readable blank-line separation.
- SVT backend selection must fail during build when a requested link has no valid static slot/VIF.

### Task 1: Add SVT backend-neutral registry and configuration object

**Files:**
- Create: `svt_pcie_integration/uvm/backend/pcie_svt_backend_cfg.sv`
- Create: `svt_pcie_integration/uvm/backend/pcie_svt_backend_if.sv`
- Create: `svt_pcie_integration/uvm/backend/pcie_svt_backend_registry.sv`
- Modify: `svt_pcie_integration/uvm/adapter/pcie_svt_adapter_pkg.sv`
- Test: `svt_pcie_integration/tests/pcie_svt_backend_cfg_unit_test.sv`

**Interfaces:**
- `pcie_svt_backend_cfg` exposes global SVT controls, `link_override[string]`, `validate()`, and `copy()`.
- `pcie_svt_backend_if` exposes `build_backend(uvm_component parent, pcie_global_cfg global_cfg, pcie_tl_env_config tl_cfg)` and `get_*_adapter()` methods without being referenced by TL-only code.
- `pcie_svt_backend_registry::register_factory()` publishes a callback that the TL environment can invoke through a neutral UVM config-db object handle.

- [ ] Add defaults and validation for transport, Gen4 fast training, EQ, shadow config, Multi-EP, Target App, timeouts, logging, and per-link overrides.
- [ ] Add a unit test that checks defaults, invalid transport, and link override precedence.
- [ ] Run the unit test file through the SVT compile filelist and confirm the expected pre-implementation failure before implementation.
- [ ] Implement the configuration object and registry, then rerun the unit test.

### Task 2: Implement automatic SVT agent backend

**Files:**
- Create: `svt_pcie_integration/uvm/backend/pcie_svt_backend.sv`
- Modify: `svt_pcie_integration/uvm/adapter/pcie_svt_adapter_pkg.sv`
- Modify: `svt_pcie_integration/sim/pcie_tl_svt_adapter.f`
- Test: `svt_pcie_integration/tests/pcie_svt_backend_build_unit_test.sv`

**Interfaces:**
- `pcie_svt_backend extends uvm_component` and implements the registry interface.
- `pcie_svt_backend::build_backend()` creates `svt_pcie_device_configuration`, `svt_pcie_device_status`, `svt_pcie_device_agent`, and `pcie_svt_if_adapter` only for `enabled && use_svt` links.
- `pcie_svt_backend::get_rc_adapter(int)` and `get_ep_adapter(int)` return already-created adapters for `pcie_tl_env`.
- `pcie_svt_backend::customize_svt_agent_cfg()` is a virtual hook called after defaults and overrides but before agent creation.

- [ ] Add a test matrix for one RC, four RC links, and one RC plus four EP links; assert agent count and role without using Host count as a creation driver.
- [ ] Implement static slot/VIF lookup and fatal diagnostics for missing or role-mismatched slots.
- [ ] Map public `pcie_link_cfg` fields to SVT speed, EQ, and role configuration using only official SVT APIs.
- [ ] Bind each adapter to the created formal agent and publish adapter handles under the neutral registry.

### Task 3: Integrate backend selection into `pcie_tl_env`

**Files:**
- Modify: `pcie_tl_vip/src/env/pcie_tl_env.sv`
- Modify: `pcie_tl_vip/src/topology/pcie_global_cfg.sv`
- Modify: `svt_pcie_integration/uvm/backend/pcie_svt_backend.sv`
- Test: `pcie_tl_vip/tests/pcie_global_cfg_unit_test.sv`

**Interfaces:**
- The environment reads `pcie_global_cfg` before adapter creation.
- `PCIE_BACKEND_TL_ONLY` leaves current factory/config-db behavior unchanged.
- SVT backend selection sets `bridge_required`, obtains adapters from the registry, and injects them at `pcie_svt_bridge_rc_adapter_%0d` / `pcie_svt_bridge_ep_adapter_%0d` equivalent internal handles before TL agents are built.

- [ ] Add failing assertions for TL-only no-backend creation and SVT backend adapter injection.
- [ ] Implement neutral discovery through config-db/registry so TL package never names SVT classes.
- [ ] Validate that enabled links have unique static slots and that `runtime_num_links` does not exceed the static HDL limit.
- [ ] Keep single-root legacy Host memory fallback and existing bridge FIFO behavior intact.

### Task 4: Add documented integration examples and verification

**Files:**
- Create: `svt_pcie_integration/tests/pcie_svt_backend_single_rc_test.sv`
- Create: `svt_pcie_integration/tests/pcie_svt_backend_four_rc_test.sv`
- Modify: `svt_pcie_integration/sim/README.md`
- Modify: `docs/pcie_unified_environment_usage.md`

- [ ] Document TL-only, SVT RC plus DUT EP, DUT RC plus SVT EP, and switch peer setup.
- [ ] Add compile/elaboration commands for static slot macros and runtime link selection.
- [ ] Run TL-only compile/elaboration and the existing dual-SVT formal regression on host 10.11.10.53.
- [ ] Report any SVT API/version-dependent limitation without weakening the TL-only path.
