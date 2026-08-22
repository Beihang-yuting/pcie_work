# SVT PCIe Direct Passive Sidecar Design

**Date:** 2026-08-20

**Status:** Approved

**Validation host:** `ubuntu@10.11.10.53`

**Synopsys release:** SVT PCIe R-2020.12

## 1. Purpose

Replace only the five passive Switch Proxy sidecars from
`svt_pcie_device_agent` wrappers to direct standalone `svt_pcie_agent`
instances. The ten active full Device Agents remain unchanged.

The replacement fixes a wrapper-boundary role mismatch. The current nested
TL monitor eventually reports the requested switch attributes, but its USP
compliance checker is initialized as an Endpoint and produces 893 errors in a
real five-link enumeration run. Publishing a second
`svt_pcie_configuration` into the existing Device Agent's child hierarchy was
also disproved: the run terminated at time zero because the wrapper-owned HDL
model scope was empty. A standalone passive agent is the public R-2020.12
boundary that accepts the passive SERDES VIF directly and does not need the
Device Agent's RC/EP wrapper role.

The change must preserve all previously proven Task 9 behavior: five Serial
links, RX/TX observation, monitor configuration-space services, exact
STAR#9000762979 handling, official enumeration, twelve Endpoint BAR
apertures, route-event correlation, forwarding state checks, and the existing
scoreboard.

This document narrows and updates the sidecar implementation in
`2026-08-18-svt-pcie-five-sidecar-switch-proxy-design.md`. All active-agent,
switch-core, adapter, converter, enumeration, BAR, and scoreboard requirements
from that design and
`2026-08-19-svt-pcie-dynamic-control-plane-observation-design.md` remain in
force.

## 2. R-2020.12 Public API Basis

The installed HTML reference on the validation host establishes these public
contracts:

- `svt_pcie_agent` contains the passive TL, DL, and PL monitors and publicly
  exposes `tl_mon` and `status`.
- `svt_pcie_agent::establish_cfg(ref svt_pcie_configuration cfg)` retrieves
  the direct-agent configuration from `uvm_config_db`.
- `svt_pcie_configuration.enable_monitor` enables the monitor components.
- `svt_pcie_configuration.serdes_x16_if` and `serdes_x4_if` are explicitly
  documented for a passive monitor in standalone mode.
- `svt_pcie_agent` inherits the public `svt_agent::err_check` handle, so the
  existing exact `disable_checks()` call remains available.
- `svt_pcie_tl_monitor` publicly exposes `rx_tlp_observed_port`,
  `tx_tlp_observed_port`, and `tl_service_in_port`.

The source references are:

```text
/home/ubuntu/synopsys/designware_vip_R-2020.12/vip/svt/pcie_svt/R-2020.12/doc/
  pcie_svt_uvm_class_reference/html/agent/class_svt_pcie_agent.html
  pcie_svt_uvm_class_reference/html/agent/class_svt_pcie_agent-members.html
  pcie_svt_uvm_class_reference/html/configuration/class_svt_pcie_configuration.html
```

No private vendor state, vendor source edit, HDL force/deposit, or report
catcher is part of this design.

## 3. Scope

### 3.1 Included

- Change the five `pcie_svt_switch_sidecar_env` instances to direct
  `svt_pcie_agent` ownership.
- Use one width-matched standalone passive SERDES VIF per sidecar.
- Configure explicit USP/DSP switch-monitor roles before direct-agent
  creation.
- Preserve Gen4/Gen5 and x16/x4 effective monitor configuration.
- Preserve RX/TX subscribers, TL configuration-space service access, and the
  existing adapter/scoreboard ownership.
- Apply the exact enumeration-only STAR#9000762979 exception once per enabled
  sidecar.
- Update focused unit and integration assertions to the direct-agent public
  hierarchy.
- Re-run the complete Task 9 validation matrix on the VCS host.

### 3.2 Excluded

- Changes to the ten active primary/Proxy Device Agents or their links.
- Changes to switch routing, TLP conversion, enumeration policy, BAR sizing,
  registry semantics, or scoreboard matching.
- PIPE implementation in this task. The configuration boundary must remain
  suitable for adding width-matched passive PIPE VIF selection later.
- New checker suppression, wildcard suppression, severity downgrade, or
  suppression outside enumeration mode.
- Changes to the read-only Synopsys installation.

## 4. Component and Configuration Boundary

`pcie_svt_switch_sidecar_env` changes its vendor-owned handles to:

```systemverilog
svt_pcie_configuration cfg;
svt_pcie_agent         agent;
```

The Device Agent-only `svt_pcie_device_configuration`,
`svt_pcie_device_status`, and `svt_pcie_device_agent` handles are removed from
this environment. The direct agent owns its `svt_pcie_status` as
`agent.status`; the sidecar does not create or publish a redundant
`shared_status` object.

Before creating `agent`, the environment:

1. creates one `svt_pcie_configuration`;
2. sets `enable_monitor = 1'b1`;
3. sets the existing width, supported-width, selected-speed, and
   supported-speed values through `cfg.pl_cfg`;
4. sets the switch role through `cfg.tl_cfg`;
5. assigns exactly one non-null `serdes_x16_if` or `serdes_x4_if`; and
6. publishes the object as `uvm_config_db#(svt_pcie_configuration)` at the
   direct child path `agent` with field name `cfg`.

The direct configuration deliberately has no `is_active`, `device_is_root`,
`pcie_spec_ver`, or `model_instance_scope` assignment. Those are Device
Agent wrapper concepts, not the standalone passive-agent contract. Passive
drive protection is instead proven by direct-agent structure, monitor-only
configuration, input-only HDL taps, absence of active sequencer use, and the
link-neutral sidecar readiness check.

All configuration is complete before `svt_pcie_agent::type_id::create()`.
There is no child-path override after construction and no `REFRESH_CFG` used
to repair an initially incorrect role.

## 5. Explicit Switch Roles

Role selection is based on the physical switch port index, not inferred from
lane width. This keeps direction semantics correct if a later topology uses a
different width for the same role.

| Port | Role | Width | `is_switch` | `is_tx_downstream` | `cfg_space_mode` |
| ---: | --- | ---: | ---: | ---: | --- |
| 0 | USP | x16 | 1 | 0 | `CFG_SPACE_ENUMERATION_UPDATE` |
| 1-4 | DSP0-DSP3 | x4 | 1 | 1 | `CFG_SPACE_ENUMERATION_UPDATE` |

`configure_monitor_role()` therefore accepts an
`svt_pcie_configuration` and explicit `port_index`. It rejects an index
outside 0 through 4. A focused unit test proves the complete pre-create
configuration for one USP and four DSPs.

At end of elaboration, each live `agent.tl_mon` returns its effective
configuration through `get_cfg()`. The test requires the effective values to
match the table for every sidecar. Checking only the input object is
insufficient because the current failure occurs during child construction.

## 6. Observation and Configuration-Space Data Flow

The existing input-only HDL taps and SERDES interfaces are unchanged:

```text
active Serial link
  -> input-only passive tap
  -> width-matched standalone SERDES VIF
  -> direct svt_pcie_agent monitors
  -> agent.tl_mon RX/TX observed ports
  -> existing sidecar subscribers
  -> existing adapter and scoreboard
```

Only public-hierarchy references change:

```text
agent.pcie_agent.tl_mon  -> agent.tl_mon
cfg.pcie_cfg.tl_cfg      -> cfg.tl_cfg
cfg.pcie_cfg.pl_cfg      -> cfg.pl_cfg
cfg.pcie_cfg.enable_monitor -> cfg.enable_monitor
```

The environment continues to connect one service analysis port per sidecar to
`agent.tl_mon.tl_service_in_port`. Existing SET_FIELD, GET_FIELD, WRITE_ADDR,
and readiness operations therefore continue to program and inspect the
monitor's configuration-space image. The Header Type and PCIe Capability
templates remain:

```text
USP: Header Type 1, PCIe Device/Port Type 5
DSP: Header Type 1, PCIe Device/Port Type 6
```

No monitor observation feeds a TLP back into the switch except through the
already-defined Completion ownership path. The direct-agent change does not
alter routing ownership or exactly-once checking.

## 7. STAR#9000762979 and Error Handling

During enumeration only, each enabled direct sidecar requires a non-null
inherited `agent.err_check` and executes exactly:

```systemverilog
agent.err_check.disable_checks(
  "PASSIVE_DL_TX", "FLOW_CTRL_INIT", "txn_06_01_16");
```

The sidecar records one local applied flag. The test requires configured and
applied flags to equal enumeration mode on all five ports. Link-only mode
applies no exception. A missing `err_check`, `tl_mon`, effective
configuration, analysis port, service port, VIF, adapter, subscriber, or
scoreboard handle is fatal.

The implementation must not hide the existing USP errors. The successful
acceptance run must instead show that the direct USP monitor was constructed
with the switch role and that the complete simulation report has
Warnings/Errors/Fatals equal to `0/0/0`.

## 8. Test-Driven Implementation and Validation

Implementation starts by adapting the focused role/configuration unit so that
it fails to compile against the old Device Agent sidecar API. The minimum
GREEN result proves:

```text
one direct-agent configuration type
one USP role
four DSP roles
all roles established before child creation
invalid port rejection
```

After the direct sidecar change, validation runs serially on
`10.11.10.53`. Before every compile, the remote source tree is synchronized
from the local worktree so the disproved nested-publication experiment cannot
remain in the validation copy.

The required gates are:

1. Focused direct-sidecar role/configuration RED then GREEN.
2. BAR sizing callback unit test.
3. Enumeration registry valid case and every negative case.
4. Switch adapter default, dynamic, and focused modes.
5. Link-only with sidecars disabled, proving the ten-active-agent baseline.
6. Link-only with five direct sidecars enabled, proving passive neutrality and
   five ready sidecars.
7. A fresh enum-only run requiring:
   - five `LINK_PASS` results;
   - five direct-sidecar ready results;
   - effective USP/DSP roles matching Section 5;
   - exactly one USP, four DSPs, four Endpoints, and twelve 64-bit
     Prefetchable BAR apertures;
   - zero drops, queued observations, expectations, outstanding Requests, or
     deferred state;
   - `SWITCH_ENUM_PASS usp=1 dsp=4 ep=4 bars=12`; and
   - final Warnings/Errors/Fatals of `0/0/0`.
8. The original single-Endpoint x16 regression.
9. `git diff --check`, credential scan, generated-artifact scan, and focused
   code review.

Task 9 remains uncommitted until all GREEN gates pass. The design document is
also kept uncommitted under that policy.

## 9. Acceptance Boundary

This design is complete only when the five sidecars are direct passive
`svt_pcie_agent` instances and the fresh enum-only run proves the same
end-to-end topology and forwarding result with zero report counts. A compile
success, a role-object unit pass, five links without enumeration, or
suppression of the 893 USP errors does not satisfy acceptance by itself.
