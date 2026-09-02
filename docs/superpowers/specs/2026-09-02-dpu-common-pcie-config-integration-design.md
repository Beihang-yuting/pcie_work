# DPU-common PCIe Configuration Integration Design

**Date:** 2026-09-02  
**Status:** Draft for review

## 1. Goal

Make `virtio_work/dpu_common` the single authority for device-level PCIe
configuration while keeping PCIe protocol and physical-topology behavior in
`pcie_work`.  The same resolved DPU snapshot must drive either the TL backend
or the Synopsys SVT backend without allowing either backend to silently
reallocate BDFs or BARs.

## 2. Non-goals

- Do not copy or modify the `virtio_work` repository.
- Do not make `dpu_common` depend on Synopsys SVT or this PCIe repository.
- Do not move RC/EP/Switch physical topology, lane width, generation, Serial,
  or PIPE knowledge into the DPU resource resolver.
- Do not remove the native `pcie_tl_env` or the SVT
  `pcie_svt_topology_env` implementations.
- Do not claim real-DUT Serial or PIPE verification until the corresponding
  executor and RTL connection are tested on the VCS host.

## 3. Ownership model

`dpu_common` owns desired and resolved device state:

- hosts and PCIe domains;
- domain-qualified BDF ranges and reservations;
- PF/VF function identity;
- BAR role, size, alignment, and resolved base;
- AF selection;
- service ownership and resource placement;
- immutable `dpu_device_snapshot` and `dpu_resource_snapshot`;
- ordered, frozen `dpu_reg_plan` objects.

`pcie_work` owns transport and physical topology:

- RC/EP/Switch graph and USP/DSP ownership;
- physical link width and maximum generation;
- runtime link enablement;
- SVT static HDL slot and VIF binding;
- TL or SVT protocol agents and sequencers;
- execution of register plans through a transport-specific executor.

The adapter layer is the only place that translates DPU snapshot data into
PCIe device policy.  It must preserve resolved identity and address values;
it must not run a second BDF or BAR allocator.

## 4. Target component structure

```text
system test
  |
  +-- dpu_device_env
  |     +-- dpu_device_cfg
  |     +-- dpu_device_snapshot
  |     +-- dpu_resource_snapshot
  |     `-- dpu_reg_plan
  |
  +-- pcie_dpu_cfg_adapter
  |     `-- pcie_global_cfg + pcie_topology_cfg projection
  |
  `-- pcie_unified_env
        +-- TL backend:  pcie_tl_custom_env -> pcie_tl_env
        `-- SVT backend: pcie_svt_topology_env
```

The public test entry point is `pcie_device_base_test`.  Existing direct TL
and SVT tests remain as compatibility paths until the unified backend and
stage sequence have passed their regression; they are not new configuration
authorities.

## 5. Snapshot-to-PCIe projection

The adapter consumes a frozen `dpu_device_snapshot`, the frozen resource
snapshot when service/resource data is needed, and a PCIe physical attachment
description.  It produces a validated `pcie_global_cfg` and preserves the
authoritative topology graph.

The projection rules are:

| DPU snapshot value | PCIe policy value |
|---|---|
| `dpu_pcie_function_id_t.bdf` | `pcie_device_cfg.bdf` |
| function PF/VF identity | PCIe device/function identity |
| BAR pair base | `pcie_unified_bar_cfg.initial_base` |
| BAR pair size | `pcie_unified_bar_cfg.aperture` |
| BAR role | BAR0/1, BAR2/3, or BAR4/5 role mapping |
| domain window | per-root enumeration window |
| physical attachment | topology node/link association |

The DPU real-DUT profile maps Device Memory/AF registers to BAR0/1,
Mailbox to BAR2/3, and MSI-X to BAR4/5.  The adapter must validate that a
resolved pair is 64-bit, aligned, and represented by the expected low/high
BAR entries.

The physical attachment is intentionally separate from the DPU function key.
One physical Endpoint may expose multiple PF/VF functions, while four
physical Endpoints may each own one or more functions.  The attachment record
must therefore identify at least the function key, physical node ID, link ID,
and optional function/BDF mapping.

## 6. Backend and execution flow

The unified environment selects exactly one protocol child per run:

```text
PCIE_BACKEND_TL_ONLY
  -> pcie_tl_custom_env -> pcie_tl_env

PCIE_BACKEND_SVT_REAL_DUT
  -> pcie_svt_topology_env -> Synopsys Unified VIP
```

`dpu_reg_executor` remains protocol-neutral.  Two PCIe-side implementations
are planned:

- TL executor: translate config and MMIO operations to TL Config/Memory
  sequences on the selected RC sequencer;
- SVT executor: translate the same operations to SVT RC configuration and
  memory sequences on the selected SVT virtual sequencer.

The executor receives frozen plans and reports preflight, execution, and
readback failures.  It does not allocate resources or interpret service
ownership.

The required stage order is:

```text
DPU resolve
-> SVT link-up (SVT only)
-> PCIe configuration/BAR sizing
-> apply DPU bootstrap plan
-> apply DPU VIO register plan
-> Virtio/service traffic
```

TL-only runs omit physical link-up and use the TL environment's configuration
and traffic path.  SVT enumeration must use or verify the BDF/BAR values from
the DPU snapshot rather than independently selecting conflicting addresses.

## 7. Configuration and build-time contracts

- DPU snapshot handles are published only after successful resolution and are
  treated as immutable by consumers.
- A system-level parent or test resolves DPU configuration before creating
  protocol children; sibling build ordering must not be used as an implicit
  dependency.
- `PCIE_SVT_ENV_MAX_HDL_AGENTS` remains a compile-time HDL slot budget.
- Dynamic UVM descriptor arrays may contain fewer active links, but they cannot
  create slots beyond the compiled budget.
- Serial is the initial SVT transport.  PIPE remains a rejected/unimplemented
  option until a separate transport adapter is added.

## 8. Cleanup policy

The following remain production components:

- native TL sources and `pcie_tl_env`;
- `pcie_tl_custom_env` as the topology-to-TL adapter;
- `pcie_unified_env` as backend orchestration;
- `pcie_svt_topology_env` as the SVT-specific environment;
- focused unit tests and the SVT/TL compatibility tests until unified tests
  replace their coverage.

Only files proven to be unreferenced by active filelists, packages, tests, and
documentation may be removed.  Legacy direct test entry points are removed
only after equivalent unified tests pass.

## 9. Acceptance criteria

1. A unit test projects a frozen DPU snapshot into PCIe device records with
   identical BDFs, BAR bases, BAR sizes, and role mapping.
2. A conflicting or unfrozen snapshot is rejected before any protocol child is
   created.
3. The unified environment creates exactly one TL or SVT child according to
   backend policy and passes the projected configuration to it.
4. A TL executor can preflight and execute config/MMIO plan operations against
   the TL RC sequencer in a controlled test.
5. An SVT executor can preflight and execute the same plan shape through the
   SVT RC sequencer in a controlled test; physical real-DUT coverage is a
   separate verification milestone.
6. Existing TL topology unit tests and current SVT compile/elaboration tests
   remain clean.
7. New and modified code contains comments documenting ownership, source of
   each value, and stage ordering.

