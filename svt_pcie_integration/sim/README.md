# SVT PCIe unified topology simulation

This directory contains the active SVT integration entry point.  The project
uses the Synopsys SVT PCIe R-2020.12 Unified VIP in Serial mode and keeps
topology, device policy, BAR policy, and backend selection in the common
`pcie_global_cfg` management layer.

## Active build contract

Compile from this directory with:

```sh
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+PCIE_TOPO_EP_X16 \
  -f pcie_svt_topology.f \
  -top pcie_svt_topology_top \
  -o build/simv -l build/compile.log
```

The installed SVT environment must provide `svt_pcie.uvm.pkg`, the Unified VIP
environment example include directory, and the VCS/PLI support files.  Use a
login shell on the VCS host so `VCS_HOME`, `PCIE_SVT_ROOT`, and the license
environment are available.

Select exactly one compile-time topology:

```text
PCIE_TOPO_EP_X16
PCIE_TOPO_EP_2X8
PCIE_TOPO_SWITCH_1X16_4X4
```

The maximum statically elaborated HDL slot count may be overridden with
`PCIE_SVT_ENV_MAX_HDL_AGENTS`; the runtime policy limit is controlled by
`PCIE_SVT_ENV_MAX_NUM_LINKS`.  These project-private macros do not override
Synopsys' `SVT_PCIE_MAX_NUM_LINKS`.

## Runtime stages

The active test layer is based on `pcie_device_base_test` and
`pcie_unified_env`.  The stage sequence preserves this order:

```text
link bring-up -> configuration-space/BAR initialization -> enumeration/traffic
```

The current topology test entry points are listed in `pcie_svt_topology.f`.
Scenario tests can override `build_global_cfg()` to select backend, enable
links, assign BDFs, and customize BAR descriptors.

The default transport is Serial.  PIPE support remains a future transport
extension and is not enabled by the current topology policy.

## RTL connection boundary

`pcie_svt_topology_env_top.sv` and the reset/serial interfaces provide the
project boundary for a real DUT.  Users supply the DUT wrapper, SerDes or PIPE wiring,
clock/reset conversion, and any board-specific connections.  The environment
owns policy translation, configuration-space initialization, enumeration, and
traffic sequencing.

## Removed legacy paths

The former TL proxy, passive-sidecar, and switch-proxy implementation has been
removed.  It was not a real DUT data path and is not part of the active unified
environment.  Historical design notes remain under `docs/superpowers/` for
reference only; they are not build inputs.
