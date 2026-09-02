# PCIe unified environment usage

The common entry point is `pcie_device_base_test`, with
`pcie_unified_env` creating exactly one protocol child.  Native tests can keep
overriding `build_global_cfg()`.  DPU-aware tests derive from
`pcie_dpu_device_base_test`, override `build_system_cfg()`, and let the system
environment resolve and freeze DPU state before the TL or SVT child is built.

## Ownership and data flow

`dpu-common` owns device identity, domain-qualified BDFs, PF/VF functions, BAR
roles/sizes/bases, resource placement, and frozen register plans.  PCIe owns
the physical RC/Switch/EP graph, link width/generation, enabled links, SVT
static slots, and VIF bindings.  `pcie_dpu_cfg_adapter` is the only translator;
it copies frozen BDF/BAR values and does not allocate them again.

```text
dpu_device_cfg + placement_cfg
        -> dpu_configuration_resolver
        -> frozen device/resource snapshots
        -> pcie_dpu_cfg_adapter + attachment map
        -> pcie_global_cfg
        -> pcie_unified_env (one TL or one SVT child)
```

The DPU-aware package is deliberately separate from the native packages:

```text
pcie_dpu_integration_pkg   backend-neutral attachment/projection/executor base
pcie_dpu_system_pkg        DPU + TL + SVT system extension and stage sequence
```

## Backend selection

`pcie_global_cfg.backend` selects one of:

- `PCIE_BACKEND_TL_ONLY`: creates `pcie_tl_custom_env` and uses the selected
  TL RC virtual sequencer.
- `PCIE_BACKEND_SVT_REAL_DUT`: creates `pcie_svt_topology_env` and uses the
  SVT RC transaction sequencer.  Serial is the supported transport.
- `PCIE_BACKEND_SVT_TL_FORWARD`: retained for an explicitly supplied hybrid
  adapter; it is not selected by the EP x16 profile.

For the example profile, use `+PCIE_BACKEND=TL_ONLY` or
`+PCIE_BACKEND=SVT_REAL_DUT`.  `+PCIE_GEN=4|5` changes only the PCIe topology
capability; Gen4 is the safe R-2020.12 runtime default.

## Stage order

The DPU-aware stage sequence is:

```text
DPU resolve/freeze
-> local VIP/config-space initialization
-> SVT link-up (SVT only)
-> SVT enumeration (SVT only)
-> DPU bootstrap register plan
-> DPU VIO register plan
-> service traffic hook
```

SVT cfg-init intentionally precedes link enable because the R-2020.12 refresh
and reset-release contract requires links to be down.  Every stage is a
virtual hook; switch enumeration and service traffic can be replaced by a
derived sequence without changing DPU resolution.

## DPU EP x16 example

The companion filelist is `svt_pcie_integration/sim/pcie_dpu_ep_x16.f` and
requires `DPU_COMMON_ROOT`, `HOST_MEM_ROOT`, `DESIGNWARE_HOME`, and
`PCIE_SVT_ROOT` to be set by the caller.  The profile creates one RC-to-EP x16
link and one PF0 with:

```text
BDF 01:00.0
BAR0/1 32 MiB, 64-bit, Prefetchable
BAR2/3 64 KiB,  64-bit, Prefetchable
BAR4/5 64 KiB,  64-bit, Prefetchable
```

Compile/elaborate against the official Serial HDL top:

```sh
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  +define+PCIE_TOPO_EP_X16 \
  -f svt_pcie_integration/sim/pcie_dpu_ep_x16.f \
  -top pcie_svt_topology_top -o build/dpu_ep_x16_simv
./build/dpu_ep_x16_simv +UVM_TESTNAME=pcie_dpu_ep_x16_test \
  +PCIE_BACKEND=SVT_REAL_DUT +PCIE_GEN=4 +PCIE_DPU_COMPILE_ONLY
```

For a protocol-only TL plan smoke against the generic TL model:

```sh
./build/dpu_ep_x16_simv +UVM_TESTNAME=pcie_dpu_ep_x16_test \
  +PCIE_BACKEND=TL_ONLY +PCIE_DPU_CONTROLLED_EXECUTOR
```

The controlled executor verifies DPU plan ordering when the generic TL model
does not implement DPU AF/VIO register semantics.  Omit that switch when a
real DUT or register model is connected; the transport executor will then
issue Config/Memory requests through the selected RC VIP.

## Switch attachment rule

For a switch, a DPU function is attached to its DSP link, while the SVT RC
executor is selected by the USP link.  The SVT executor accepts this pair only
when both descriptors have the same `root_hierarchy`; an attachment in another
root is rejected during preflight.  This prevents a multi-host BDF from being
sent through the wrong RC.

## Real RTL boundary

The project HDL top publishes the static Serial VIF slots and reset VIF.  The
user supplies the DUT wrapper, clocks/resets, SerDes wiring, and any board
specific PIPE conversion.  This repository manages policy, stage ordering,
enumeration hooks, and register-plan dispatch; it does not claim real-DUT link
success when the placeholder wrapper is used.
