# PCIe TL/SVT Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a compile-ready 1-RC + 1-EP Serial bridge in which `pcie_tl_env` is the only PCIe control plane and SVT is reached through a public TLP Mapper adapter.

**Architecture:** Keep the existing TL package and environments intact. Add a focused SVT adapter package containing a codec, route metadata, and adapter subtype; extend the topology environment only to construct and connect that bridge when explicitly selected. Preserve native/legacy SVT paths and make the first example use placeholder RTL and existing R-2020.12 include conventions.

**Tech Stack:** SystemVerilog, UVM, Synopsys SVT PCIe R-2020.12, VCS, existing `pcie_tl_pkg` transaction classes.

**Spec:** `docs/superpowers/specs/2026-09-03-pcie-tl-svt-bridge-design.md`

## Global Constraints

- `pcie_tl_env` remains the sole transaction/configuration control plane.
- No deletion or renaming of existing pcie_tl_vip public classes, enums, packages, or filelists in this phase. Legacy SVT-only wrappers may be superseded.
- SVT integration uses only documented/public TLP Mapper TLM ports; no SVT private internals or direct Serial driving from UVM.
- Dynamic UVM arrays are bounded by the existing `PCIE_SVT_ENV_MAX_NUM_LINKS` HDL slot macro.
- Missing bridge handles are fatal during build/connect; unsupported TLP fields are reported explicitly.
- First verification target is compile/elaboration for one RC and one EP over Serial; switch and PIPE are follow-up work.

### Task 1: Define bridge route metadata and codec API

**Files:**
- Create: `svt_pcie_integration/uvm/adapter/pcie_svt_adapter_types.sv`
- Create: `svt_pcie_integration/uvm/adapter/pcie_svt_tlp_codec.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Test: `svt_pcie_integration/uvm/tests/pcie_svt_tlp_codec_unit_test.sv`

**Interfaces:**
- `pcie_svt_route_info` stores `application_id`, `link_id`, `root_index`, and requester/completion routing metadata.
- `pcie_svt_tlp_codec::encode(pcie_tl_tlp tlp, output svt_pcie_tlp svt_tlp, pcie_svt_route_info route)`.
- `pcie_svt_tlp_codec::decode(svt_pcie_tlp svt_tlp, output pcie_tl_tlp tlp, pcie_svt_route_info route)`.

- [ ] **Step 1: Write the failing unit test** covering Config Read, Memory Write, Completion with data, requester ID/tag, payload, and route metadata.
- [ ] **Step 2: Run the test and confirm the codec symbols are absent.**
- [ ] **Step 3: Add route metadata and codec declarations, including explicit error reporting for null/unsupported transactions.**
- [ ] **Step 4: Implement field-by-field conversion using the installed SVT transaction declarations; preserve byte enables, length, IDs, tags, payload, and error metadata where SVT exposes them.**
- [ ] **Step 5: Run the unit test and require round-trip equality for all supported fields.**
- [ ] **Step 6: Commit `feat: add SVT bridge route metadata and codec`.**

### Task 2: Implement the TL-to-SVT adapter and mapper-facing ports

**Files:**
- Create: `svt_pcie_integration/uvm/adapter/pcie_svt_if_adapter.sv`
- Create: `svt_pcie_integration/uvm/adapter/pcie_svt_tlp_mapper_bridge.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Test: `svt_pcie_integration/uvm/tests/pcie_svt_if_adapter_unit_test.sv`

**Interfaces:**
- `pcie_svt_if_adapter extends pcie_tl_if_adapter`.
- Public configuration fields: `pcie_svt_route_info route`, `pcie_svt_tlp_codec codec`, and a mapper endpoint handle.
- `send(pcie_tl_tlp)` encodes and submits to the selected mapper `tx_tlp_in_export[application_id]`.
- `receive(output pcie_tl_tlp)` receives from `rx_tlp_out_port[application_id]`, decodes, and validates route metadata.

- [ ] **Step 1: Add a unit test with a mock mapper endpoint and assert one outbound and one inbound transaction.**
- [ ] **Step 2: Run it to establish the expected missing-adapter failure.**
- [ ] **Step 3: Implement adapter construction, null-handle checks, and route-aware send/receive tasks.**
- [ ] **Step 4: Implement mapper bridge plumbing with documented TLM export/port types; keep SVT package references isolated to the SVT integration package.**
- [ ] **Step 5: Run adapter unit checks, including wrong application ID and completion tag mismatch diagnostics.**
- [ ] **Step 6: Commit `feat: add TL to SVT mapper adapter`.**

### Task 3: Add explicit bridge mode and topology-environment integration

**Files:**
- Modify: `svt_pcie_integration/uvm/cfg/pcie_svt_topology_policy_cfg.sv`
- Modify: `svt_pcie_integration/uvm/env/pcie_svt_topology_env.sv`
- Modify: `svt_pcie_integration/uvm/env/pcie_unified_env.sv`
- Modify: `svt_pcie_integration/uvm/tests/pcie_device_base_test.sv`
- Test: `svt_pcie_integration/uvm/tests/pcie_svt_bridge_env_unit_test.sv`

**Interfaces:**
- Add a backward-compatible mode enum/value for TL-only versus TL/SVT bridge; retain existing enum values and defaults.
- `pcie_svt_topology_env` creates one adapter per active descriptor only in bridge mode and leaves TL-only behavior unchanged.
- Config DB keys are stable: `pcie_svt_bridge_enable`, `pcie_svt_mapper`, `pcie_svt_route_info`.

- [ ] **Step 1: Add mode/config assertions to the environment unit test.**
- [ ] **Step 2: Run the test against current code to capture the missing mode behavior.**
- [ ] **Step 3: Add the mode field with TL-only as the default and document override through config DB/plusarg.**
- [ ] **Step 4: Construct/connect adapters after topology descriptors are translated; enforce the HDL slot limit before allocation.**
- [ ] **Step 5: Keep native SVT aliases and existing root/endpoint handles intact for legacy tests.**
- [ ] **Step 6: Run TL-only and bridge environment unit tests; commit `feat: integrate optional SVT bridge mode`.**

### Task 4: Provide the 1-RC + 1-EP Serial compile/elaboration example

**Files:**
- Create: `svt_pcie_integration/sim/pcie_tl_svt_bridge_1rc1ep.f`
- Create: `svt_pcie_integration/sim/pcie_tl_svt_bridge_1rc1ep_tb.sv`
- Modify: `svt_pcie_integration/sim/README.md`

**Interfaces:**
- Example sets the bridge mode, maps RC/EP application IDs, binds existing Serial interfaces, and uses placeholder RTL if no DUT is supplied.
- Filelist continues to use `$PCIE_SVT_ROOT`, `$DESIGNWARE_HOME`, and `$HOST_MEM_ROOT` environment variables; no credentials or tokens are embedded.

- [ ] **Step 1: Add the testbench/filelist with explicit include ordering: TL package, adapter package, SVT package, RTL interfaces, environment, test.**
- [ ] **Step 2: Run local static checks for duplicate package declarations, missing include paths, and unresolved filelist paths.**
- [ ] **Step 3: Run VCS compile/elaboration on `10.11.10.53` using a login shell and the installed SVT R-2020.12 environment.**
- [ ] **Step 4: Record exact command, tool result, and any environment prerequisites in README.**
- [ ] **Step 5: Commit `test: add 1RC1EP TL SVT bridge compile example`.**

### Task 5: Regression and compatibility verification

**Files:**
- Modify: `svt_pcie_integration/sim/check_topology_hdl_agent_contract.sh` (only if required by the new filelist)
- Create: `svt_pcie_integration/sim/check_tl_svt_bridge_contract.sh`
- Modify: `pcie_tl_vip/docs/PCIe_TL_VIP_Integration_Guide.md`

- [ ] **Step 1: Add a shell contract check that validates required adapter files, public mapper symbols, and unchanged legacy filelists.**
- [ ] **Step 2: Run all existing repository-level static/unit checks.**
- [ ] **Step 3: Re-run VCS compile/elaboration for TL-only and bridge examples on the VCS host.**
- [ ] **Step 4: Confirm no public legacy class or file was removed, and document the new integration entry point.**
- [ ] **Step 5: Commit `docs: document TL SVT bridge integration and compatibility`.**

