# PCIe Environment Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove obsolete SVT adapter scaffolding and dangling active references while preserving the verified FULL_VIP formal test, official SVT peer traffic test, and valid TL/DPU regression entries.

**Architecture:** `pcie_tl_env` remains the only PCIe control plane. The runnable SVT checks are limited to the verified TL-root/FULL_VIP formal gate and the independent official peer self-check; the generic adapter filelist remains a source template for a future real-DUT top, not a standalone fake test. TL-only and DPU-only filelists remain independent.

**Tech Stack:** SystemVerilog, UVM 1.2, VCS, Synopsys SVT PCIe R-2020.12, shell contract checks.

**Spec:** `docs/pcie_unified_environment_usage.md`

## Global Constraints

- Preserve `pcie_tl_vip` standalone behavior and all tests listed by `pcie_tl_vip/sim/filelist.f`.
- Preserve `pcie_dpu_integration` attachment/config/executor tests and both DPU filelists.
- Preserve `svt_pcie_integration/tests/pcie_tl_svt_formal_test.sv` and its formal top/filelist.
- Preserve `svt_pcie_integration/tests/pcie_svt_peer_traffic_test.sv` and its peer top/filelist.
- Do not reintroduce the removed SVT topology/proxy/backend/sidecar environment.
- Keep historical design plans as documentation; only active source/filelist references are cleaned.

### Task 1: Remove obsolete adapter-only test scaffolding

**Files:**
- Delete: `svt_pcie_integration/tests/pcie_tl_svt_adapter_base_test.sv`
- Delete: `svt_pcie_integration/tests/pcie_tl_svt_adapter_link_test.sv`
- Delete: `svt_pcie_integration/tests/pcie_tl_svt_adapter_tb_top.sv`
- Modify: `svt_pcie_integration/sim/pcie_tl_svt_adapter.f`

The deleted test only checks factory construction and a queue-only mapper without a real SVT agent or TLP. Keep the filelist as an adapter source template, but remove its deleted test/top entries so real-DUT filelists can include the adapter package without pulling in a fake test.

- [x] Remove the three obsolete test sources.
- [x] Remove their entries from `pcie_tl_svt_adapter.f` and update its header to state that it is source-only.

### Task 2: Update active documentation and contract checks

**Files:**
- Modify: `svt_pcie_integration/sim/README.md`
- Modify: `docs/pcie_unified_environment_usage.md`
- Modify: `svt_pcie_integration/sim/check_tl_svt_bridge_contract.sh`

Document the two runnable SVT gates and explain that `pcie_tl_svt_adapter.f` is a source template requiring a user top. Remove instructions that run the deleted adapter-only test. Make the contract check validate the formal filelist and adapter source filelist without expecting deleted test names.

- [x] Update compile/run commands and filelist descriptions.
- [x] Remove all active references to the deleted test/top.
- [x] Keep the checks for adapter package, mapper ports, FULL_VIP callback suppression, and TL-only isolation.

### Task 3: Verify the cleaned active tree

**Commands:**

```sh
./svt_pcie_integration/sim/check_tl_svt_bridge_contract.sh
git diff --check
rg -n "pcie_tl_svt_adapter_(base|link)_test|pcie_tl_svt_adapter_tb_top" \
  svt_pcie_integration docs pcie_tl_vip || true
```

- [x] Confirm the contract checker passes.
- [x] Confirm no active source/filelist/documentation reference remains.
- [x] Confirm formal and peer test files remain present and referenced by their dedicated filelists.
- [x] Report the final retained/deleted test set and any intentionally preserved historical plans.
