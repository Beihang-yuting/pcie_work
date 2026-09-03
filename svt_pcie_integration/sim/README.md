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

Enumeration and BAR allocation are also data-driven.  The profile creates
`pcie_svt_topology_policy_cfg.enum_cfg` with these defaults:

```text
pref_mem_base_addr       = 0x0000_0001_0000_0000
pref_mem_limit_addr      = 0x0000_0001_0fff_ffff
pref_mem_window_stride   = 0x0000_0000_1000_0000 (256 MiB per root)
bus_number/device_number = 1/0
```

The six `policy_cfg.ep_bars[]` descriptors remain the source of BAR aperture,
type, Prefetchable bit, and initial BAR address.  A test can override the
enumeration object before the base test builds `env`, for example:

```systemverilog
pcie_svt_enum_cfg enum_override;
enum_override = pcie_svt_enum_cfg::type_id::create("enum_override");
enum_override.pref_mem_base_addr = 64'h0000_0002_0000_0000;
enum_override.pref_mem_limit_addr = 64'h0000_0002_0fff_ffff;
enum_override.pref_mem_window_stride = 64'h0000_0000_2000_0000;
uvm_config_db#(pcie_svt_enum_cfg)::set(this, "", "enum_cfg", enum_override);
```

The adapter deep-copies this object into each active link descriptor.  The
enumeration sequence then derives the per-root window from
`pref_mem_*_for(root_hierarchy)`, so no address constant is embedded in the
sequence.  `pcie_svt_enum_cfg.validate()` rejects reversed windows, a stride
smaller than the window, and invalid function-count limits before elaboration.

The default transport is Serial.  PIPE support remains a future transport
extension and is not enabled by the current topology policy.

## 1RC + 1EP TL/SVT bridge compile example

`pcie_tl_svt_bridge_1rc1ep.f` is a minimal 1-RC/1-EP Serial bridge entry
point.  It compiles the TL package first, then the SVT adapter declarations and
`pcie_svt_topology_pkg`, followed by the existing Serial/reset interfaces,
`pcie_svt_dut_wrapper`, and the dedicated testbench.  The test selects
`PCIE_BACKEND_SVT_TL_FORWARD` and sets the runtime policy field
`global_cfg.svt_bridge_enable = 1'b1`, which the environment translates to
`PCIE_SVT_BRIDGE_TL_SVT`.  It publishes a `svt_pcie_tlp_mapper` and reserves
`svt_pcie_tlp_mapper`.  The direct `EP_X16` profile exposes only the RC-owned
descriptor to this SVT environment (the EP is the DUT side), so application ID
`0` is the active bridge route.  ID `1` is published only as an alias for a
future real-DUT/explicit EP extension; it is not consumed by an active adapter
in this direct example.  Serial VIF `primary_vif_0` is bound to the existing
x16 HDL agent macro.  Unless `PCIE_TL_SVT_BRIDGE_USE_REAL_DUT` is
defined, the wrapper drives electrical idle and therefore proves only compile
and elaboration; it cannot prove LTSSM/link training or traffic.

Run from this directory on the VCS host:

```sh
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  -f pcie_tl_svt_bridge_1rc1ep.f \
  -top pcie_svt_topology_top \
  -o build/pcie_tl_svt_bridge_1rc1ep_simv \
  -l build/pcie_tl_svt_bridge_1rc1ep_compile.log
```

The command requires a login shell with VCS and SVT R-2020.12 installed and
the `PCIE_SVT_ROOT`, `DESIGNWARE_HOME`, and `HOST_MEM_ROOT` variables exported.
No credentials are embedded in the filelist.  The VCS host (`10.11.10.53`) is
reachable and exposes `vcs`, but its current login environment does not export
`PCIE_SVT_ROOT`, `DESIGNWARE_HOME`, or `HOST_MEM_ROOT`; the required
R-2020.12 SVT file locations therefore cannot be resolved.  The compile result
is **not run (required SVT environment variables unavailable)**; source the
site SVT setup that supplies those three variables, then rerun the exact
command above for final elaboration evidence.

## DPU-common EP x16 example

The optional DPU-aware example uses the companion filelist
`pcie_dpu_ep_x16.f`, so native SVT builds do not acquire a hard dependency on
`dpu-common`:

```sh
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  +define+PCIE_TOPO_EP_X16 \
  -f pcie_dpu_ep_x16.f -top pcie_svt_topology_top \
  -o build/dpu_ep_x16_simv -l build/dpu_ep_x16_compile.log
```

The profile is selected at runtime without changing DPU authoring data:

```sh
./build/dpu_ep_x16_simv +UVM_TESTNAME=pcie_dpu_ep_x16_test \
  +PCIE_BACKEND=SVT_REAL_DUT +PCIE_GEN=4 +PCIE_DPU_COMPILE_ONLY
```

`+PCIE_BACKEND=TL_ONLY +PCIE_DPU_CONTROLLED_EXECUTOR` runs the controlled TL
plan smoke against the generic TL Endpoint.  The controlled executor is only
for a protocol-only environment; a real DPU RTL register model should omit it
and use the transport executor directly.

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
