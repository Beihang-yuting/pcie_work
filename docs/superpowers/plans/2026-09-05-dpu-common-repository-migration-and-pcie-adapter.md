# DPU-common Repository Migration and PCIe Adapter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Move the canonical DPU configuration library into the standalone dpu_common repository, consume its frozen snapshots from pcie_work, update the external host_mem dependency, and keep PCIe physical-role configuration local to pcie_work.

**Architecture:** dpu_common owns logical Hosts, PCIe domains, PF/VF functions, BDF/BAR/resource resolution, and register plans. pcie_work owns physical RC/EP/Switch nodes, links, lane/gen/transport policy, Root-to-Host bindings, and TL/SVT execution. A PCIe adapter consumes frozen DPU snapshots and produces backend-neutral PCIe policy; it never reallocates DPU resources.

**Tech Stack:** SystemVerilog, UVM 1.2, VCS, Git subtree/submodule, Synopsys SVT R-2020.12 where available.

**Spec:** docs/superpowers/specs/2026-09-02-dpu-common-pcie-config-integration-design.md

## Global Constraints

- dpu_common is an independent repository and must not import pcie_work, pcie_tl_pkg, SVT, or concrete host_mem_manager classes.
- pcie_work must remain usable without DPU_COMMON_ROOT; DPU-aware filelists require an explicit external root.
- The frozen dpu_device_snapshot is the only source of resolved BDF and BAR values.
- Host count is derived from the validated dynamic Host array; no duplicated mutable num_hosts authority is introduced.
- RC/EP/Switch roles, Root indices, physical links, lane width, Gen, Serial/PIPE, and agent activation remain PCIe-side configuration.
- New or modified SystemVerilog must contain Chinese comments describing ownership, source values, and stage ordering, with readable blank lines.
- Existing native TL/SVT paths are preserved until replacement tests pass; deletion requires an active-filelist/reference audit.
- GitHub credentials and access tokens must not be written into remotes, scripts, credential helpers, or filelists.
- Simulation verification that requires VCS runs on 10.11.10.53 using the ubuntu login shell.

---

### Task 1: Freeze migration baseline and external dependency versions

**Files:**
- Inspect: /home/ryan/workspace/ryan/virtio_work/dpu_common
- Inspect: /home/ryan/workspace/ryan/virtio_work/virtio_net_vip/ext/host_mem
- Inspect: pcie_dpu_integration/sim/*.f

**Interfaces:**
- Consumes: committed virtio_work/dpu_common history and host_mem remote HEAD.
- Produces: recorded migration source commit, host_mem commit, and normalized external-root contract.

- [ ] **Step 1: Record source state without modifying user work.**

  Run:

~~~bash
git -C /home/ryan/workspace/ryan/virtio_work log -1 --format=%H -- dpu_common
git -C /home/ryan/workspace/ryan/virtio_work status --short
git ls-remote https://github.com/Beihang-yuting/host_mem.git HEAD refs/heads/master
~~~

- [ ] **Step 2: Confirm host_mem checkout.**

  Fetch the remote in the existing host-mem checkout and require git rev-parse HEAD to equal the remote HEAD 365b7553fc7dac6b4ad55886a8e4869153607c28. Do not change the pinned dependency if it already matches.

- [ ] **Step 3: Normalize DPU_COMMON_ROOT semantics.**

  Treat DPU_COMMON_ROOT as the root of the standalone repository, so all DPU-aware filelists use DPU_COMMON_ROOT/src and DPU_COMMON_ROOT/tests.

### Task 2: Export virtio_work/dpu_common as the standalone repository

**Files:**
- Remote repository: https://github.com/Beihang-yuting/dpu_common
- Create in exported repository: src/, tests/, filelists/dpu_common.f, README.md
- Modify in virtio_work: .gitmodules, filelists/dpu_common.f, filelists/tests.f, scripts/vcs.sh, scripts/check_deps.sh

**Interfaces:**
- Consumes: the committed DPU subtree ending at the recorded source commit.
- Produces: standalone dpu_resource_pkg package with stable src/tests layout and a version-pinned consumer path.

- [ ] **Step 1: Split history into a temporary branch.**

  From virtio_work, run git subtree split --prefix=dpu_common --branch=dpu-common-export. Verify the exported tree contains src/dpu_resource_pkg.sv and no virtio_net_vip or PCIe implementation files.

- [ ] **Step 2: Publish the export without embedding credentials.**

  Add the new remote with a normal HTTPS URL, push the export branch to dpu_common/main using an interactive/ephemeral credential path, then remove the temporary remote. Never put a token in the URL or repository configuration.

- [ ] **Step 3: Add standalone package documentation and filelist.**

  Document that Host/domain/function/BDF/BAR/resource snapshots are logical configuration, while physical PCIe roles are external. The standalone filelist must compile src/dpu_resource_pkg.sv after +incdir+src.

- [ ] **Step 4: Pin the consumer in virtio_work.**

  Replace the tracked dpu_common directory with a submodule at the same path, pinned to the exported commit. Update local filelists and dependency checks while preserving existing dpu_common/src/... relative paths inside virtio_work.

- [ ] **Step 5: Run a source/reference audit.**

  Require no active virtio_work filelist to reference a removed copied DPU source and require dpu_resource_pkg.sv to appear exactly once per compile command.

### Task 3: Add logical Host properties and immutable Host queries

**Files:**
- Modify in standalone dpu_common: src/dpu_device_cfg.sv, src/dpu_device_snapshot.sv, src/dpu_device_resolver.sv, src/dpu_resource_pkg.sv
- Test: tests/dpu_device_resolver_test.sv
- Create or modify: standalone README.md

**Interfaces:**
- Consumes: existing dpu_host_cfg.host_id and pcie_domains[].
- Produces: enabled, human-readable name, address-width, optional logical GPA aperture, host_count(), and frozen Host lookup/list methods.

- [ ] **Step 1: Add failing Host-property tests.**

  Author two Hosts with distinct IDs and logical apertures; assert duplicate IDs fail, disabled Hosts are excluded from the enabled count, frozen snapshots return the same Host properties, and no physical role field exists in the DPU package.

- [ ] **Step 2: Implement the minimum logical properties.**

  Add only logical fields to dpu_host_cfg; derive counts from the dynamic array; copy them into the immutable snapshot; validate aperture ordering and address width. Do not add RC/EP/Switch, root_index, link_id, lane, or transport fields.

- [ ] **Step 3: Run DPU-only tests.**

  Compile the standalone package and run dpu_device_resolver_test without any PCIe or host-mem package imports.

### Task 4: Add PCIe-side Root/Host and function/link projection

**Files:**
- Create: pcie_dpu_integration/src/pcie_dpu_root_binding_cfg.sv
- Modify: pcie_dpu_integration/src/pcie_dpu_integration_pkg.sv
- Modify: pcie_dpu_integration/src/pcie_dpu_cfg_adapter.sv
- Modify: pcie_dpu_integration/src/pcie_dpu_system_cfg.sv
- Test: pcie_dpu_integration/tests/pcie_dpu_cfg_adapter_unit_test.sv
- Test: pcie_dpu_integration/tests/pcie_dpu_attachment_unit_test.sv

**Interfaces:**
- Consumes: frozen DPU snapshots, pcie_topology_cfg, pcie_dpu_attachment_cfg.
- Produces: validated pcie_global_cfg, explicit (host_id, segment_id) -> root_index bindings, and function-to-physical-link records.

- [ ] **Step 1: Add failing mapping tests.**

  Test Host0/Segment0 -> Root0, Host1/Segment0 -> Root1, and Host0/Segment1 -> Root2; reject duplicate domain bindings, missing bindings, invalid Root indices, and a PF/VF attachment that has no physical EP/link.

- [ ] **Step 2: Implement Root binding as PCIe-owned composition.**

  Add a UVM object with bind_domain_to_root(host_id, segment_id, root_index, why), lookup, and complete-set validation. Keep root_index out of dpu-common.

- [ ] **Step 3: Project every resolved function.**

  Use snapshot.list_functions(), get_pcie_id(), and get_bar() to fill pcie_device_cfg. Preserve BDF/BAR values, map each function to its explicit physical EP/link attachment, and allow several PF/VF records to share one physical EP.

- [ ] **Step 4: Validate physical roles before child creation.**

  Require attached function nodes to be Endpoint nodes; require RC/Switch nodes to come from pcie_topology_cfg; reject missing or conflicting attachments before any TL/SVT child is constructed.

### Task 5: Wire projected Hosts to shared host_mem and backend activation

**Files:**
- Modify: pcie_dpu_integration/src/pcie_dpu_system_cfg.sv
- Modify: pcie_dpu_integration/src/pcie_dpu_cfg_adapter.sv
- Modify: pcie_tl_vip/src/env/pcie_tl_env_config.sv
- Modify: pcie_tl_vip/src/env/pcie_tl_env.sv
- Modify: pcie_dpu_integration/sim/pcie_dpu_integration.f
- Modify: pcie_dpu_integration/sim/pcie_dpu_tl_executor.f

**Interfaces:**
- Consumes: Root binding records and an externally owned host_mem_pool/host_mem_api set.
- Produces: Root-specific shared managers, correct RC/EP agent activation, and stable TL/SVT-independent policy.

- [ ] **Step 1: Add failing shared-memory tests.**

  Prove Root0 and Root2 can reference the same Host0 manager, Root1 references Host1, multi-Root incomplete bindings fail, and PREMAP allocates once per unique manager.

- [ ] **Step 2: Resolve managers without implicit multi-Root creation.**

  For each explicit Root binding, obtain the manager by host_id, validate its ID, initialize only if necessary, and call pcie_tl_env_config.bind_host_memory(). Preserve the single-Root legacy host_mem config-db fallback.

- [ ] **Step 3: Separate physical role from agent activation.**

  Derive physical node roles from pcie_topology_node_cfg.kind. For a real EP DUT use rc_agent_enable=1, ep_agent_enable=0; for a real RC DUT use the inverse. Do not infer agent counts from PF/VF counts.

- [ ] **Step 4: Update DPU-aware filelists to standalone-root paths.**

  Replace DPU_COMMON_ROOT/dpu_common/src with DPU_COMMON_ROOT/src and retain native TL filelists without any DPU dependency.

### Task 6: Clean obsolete PCIe content after replacement coverage

**Files:**
- Inspect/delete only confirmed unreferenced files under pcie_dpu_integration, svt_pcie_integration, and stale documentation paths.
- Modify: docs/pcie_unified_environment_usage.md
- Modify: pcie_tl_vip/docs/PCIe_TL_VIP_Integration_Guide.md

**Interfaces:**
- Consumes: active filelists, package includes, tests, and the new external DPU contract.
- Produces: a smaller pcie_work tree with adapter-only DPU integration and accurate setup instructions.

- [ ] **Step 1: Build the deletion candidate list.**

  Search each candidate stem with rg across all SystemVerilog, filelists, scripts, and docs; also check package includes and active filelists. A candidate is removable only when it has no active reference.

- [ ] **Step 2: Delete only verified scaffolding.**

  Remove duplicate proxy/sidecar or stale test files only after the new adapter tests cover their behavior. Keep native TL env, native SVT adapter, attachment model, and focused regression tests.

- [ ] **Step 3: Update documentation.**

  Document DPU_COMMON_ROOT=/path/to/dpu_common, Host/domain-to-Root binding, function-to-EP attachment, real-DUT agent activation, and the fact that pcie_work remains independently usable.

### Task 7: Verify migration, host_mem, and PCIe integration

**Files:**
- Modify: pcie_dpu_integration/sim/*.f only as needed for verification
- Test: existing DPU adapter, TL executor, Host-memory, topology, and SVT compile tests

**Interfaces:**
- Consumes: standalone DPU repository, latest host_mem commit, and cleaned PCIe tree.
- Produces: compile/elaboration evidence and a clean migration handoff.

- [ ] **Step 1: Run static checks locally.**

  Run git diff --check, duplicate filelist checks, rg reference audits, and package include-order checks. Confirm no credential or developer-specific absolute path is committed.

- [ ] **Step 2: Run focused VCS tests on 10.11.10.53.**

  Use a bash login shell and run DPU resolver, PCIe attachment/adapter, TL executor, and unified-memory tests with DPU_COMMON_ROOT and HOST_MEM_ROOT explicitly set.

- [ ] **Step 3: Run the maintained PCIe/SVT compile matrix.**

  Require native TL tests to compile without dpu-common, DPU-aware TL tests to compile with the standalone repository, and the Serial SVT source-only/elaboration path to remain clean.

- [ ] **Step 4: Record final versions and status.**

  Record the dpu-common commit, host_mem commit, pcie_work commit, test commands, and any remaining real-DUT limitation in the integration documentation.
