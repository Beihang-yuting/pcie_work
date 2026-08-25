# PCIe SVT Topology Environment Redesign

**Date:** 2026-08-25

**Status:** Approved for implementation planning

## 1. Purpose

The current `svt_pcie_integration` environment grew around fixed port slots,
compile-time profiles, a project-owned Switch proxy, passive sidecars, and
sequences that refer to hard-coded port numbers. That structure does not map
cleanly to a real PCIe DUT and obscures the intended Synopsys unified-VIP
integration.

This redesign replaces that environment with
`pcie_svt_topology_env extends pcie_device_unified_vip_env`. The new class uses
the project-owned `pcie_topology_cfg` as its topology source and creates exactly
one Synopsys SVT agent for each enabled DUT-facing link. It preserves the
official R-2020.12 environment type contract without invoking the official
example's default behavior of creating both a Root Complex and an Endpoint.

Code is reused only when it has a clear boundary and has already demonstrated
the required behavior. Fixed-slot, Proxy, sidecar, or otherwise entangled code
is rewritten and removed after the replacement passes VCS verification.

## 2. Goals and Scope

### 2.1 Supported topologies

The first implementation supports the three existing static compile profiles:

| Profile | DUT | DUT-facing SVT agents |
| --- | --- | --- |
| `EP_X16` | one x16 Endpoint | one Root Complex |
| `EP_2X8` | two independent x8 Endpoints | two independent Root Complexes |
| `SWITCH_1X16_4X4` | one x16 USP and four x4 DSPs | one Root Complex on the USP and four Endpoints on the DSPs |

Each profile supports Gen4 and Gen5. Every enabled link has an independent
policy entry so later tests can override generation, negotiated width, enable
state, timeout, or acceleration policy without changing the environment.

### 2.2 Required behavior

The environment must retain the complete real-DUT workflow:

- publish and refresh SVT configuration while reset is asserted;
- configure Endpoint SVT configuration space and BAR sizing behavior;
- bring up all enabled Serial links;
- enumerate a direct Endpoint or a real Switch hierarchy from an SVT RC;
- allocate and verify BAR and bridge-window state; and
- send Memory Requests through the real DUT and verify Completions and data.

The implementation must compile against Synopsys DesignWare VIP R-2020.12 and
use the official unified-VIP example class and public sequences.

### 2.3 Out of scope

- Emulating Switch forwarding with a project-owned transaction-level Proxy.
- Treating a collection of independent point-to-point peers as proof that a
  Switch enumerates or forwards traffic.
- Copying or modifying Synopsys source files in this repository.
- Implementing PIPE transport in this phase. The configuration API reserves
  the transport selection, but selecting PIPE before it is implemented is a
  fatal configuration error.
- Cascaded Switches or multiple Endpoints behind one Downstream Port.
- Claiming real Switch enumeration or forwarding before a real Switch DUT is
  connected.

## 3. Architectural Decisions

### 3.1 Inheritance strategy

The environment is declared as:

```systemverilog
class pcie_svt_topology_env extends pcie_device_unified_vip_env;
```

The official base implementation always creates one RC agent, one EP agent,
their configurations and statuses, and a two-ended system virtual sequencer.
That lifecycle cannot represent two independent RCs or a five-port real Switch
without unused agents. The subclass therefore overrides `build_phase()` and
`connect_phase()` and does not call the official implementations of those two
methods.

The inherited `root`, `endpoint`, and `sys_virt_seqr` handles remain available
for limited source compatibility:

- `root` aliases the first active RC agent, or is null when no RC exists;
- `endpoint` aliases the first active EP agent, or is null when no EP exists;
- `sys_virt_seqr` is created once and receives only those two primary handles.

They do not own additional components and are not the control interface for a
multi-port test. New tests and sequences use
`pcie_svt_topology_virtual_sequencer` and resolve ports by `link_id`.

### 3.2 Environment ownership boundary

The common topology remains vendor neutral:

```text
pcie_topology_cfg
        |
        v
pcie_svt_topology_adapter  <--- pcie_svt_topology_policy_cfg
        |
        v
pcie_svt_port_descriptor[]
        |
        v
pcie_svt_topology_env
        +-- svt_pcie_device_agent[]
        +-- svt_pcie_device_configuration[]
        +-- svt_pcie_device_status[]
        `-- pcie_svt_topology_virtual_sequencer
```

`pcie_topology_cfg` owns nodes, links, width, maximum generation, port roles,
and enable state. The SVT-specific policy owns the boundary between nodes
implemented by the real DUT and nodes implemented by SVT. This avoids adding
vendor or testbench-ownership fields to the common topology model.

### 3.3 No internal Switch datapath

The real-DUT environment has no `pcie_tl_switch`, Proxy adapter, sidecar path,
or software forwarding callback. In Switch mode, a request launched by the
upstream RC SVT must traverse the DUT USP and selected DSP before it reaches an
Endpoint SVT. Its Completion must return through the DUT. The environment
cannot manufacture or mirror either packet on another port.

## 4. Configuration Objects and Translation

### 4.1 `pcie_svt_topology_policy_cfg`

The backend policy contains:

- `dut_node_ids[$]`, the topology nodes implemented by the real DUT;
- transport selection, defaulting to Serial;
- default and per-link link-training timeout values;
- default fast-link-training policy;
- per-link overrides keyed by `link_id`; and
- an optional `link_id`-to-HDL-slot binding used by synthetic peer fixtures;
  normal real-DUT profiles derive this binding from the static topology; and
- the default Endpoint BAR template.

The standard bindings are:

| Profile | `dut_node_ids` |
| --- | --- |
| `EP_X16` | `EP0` |
| `EP_2X8` | `EP0`, `EP1` |
| `SWITCH_1X16_4X4` | `SW0` |

A future RC DUT can use the same topology and name the RC node as the DUT. The
adapter then creates an Endpoint SVT for the opposite side of that link.

### 4.2 `pcie_svt_port_descriptor`

The adapter emits one descriptor for each enabled link that crosses the DUT
boundary. A descriptor contains:

- stable `link_id` and physical slot index;
- the topology endpoint implemented by SVT;
- RC or Endpoint SVT role;
- maximum physical lane count and configured active width;
- requested maximum generation;
- transport and fast-training policy;
- reset and link-training timeouts; and
- the Endpoint BAR policy when the SVT role is Endpoint.

Descriptors are ordered deterministically by `link_id`. A descriptor's
physical slot is assigned from the sorted complete compile topology before
effectively disabled links are omitted, so disabling an earlier link cannot
remap a later agent onto the wrong HDL VIF. Synthetic peer descriptors inherit
the primary descriptor's slot through the explicit binding above. The same
stable slot is used by UVM component names and the HDL Serial interface
registry. Functional code still looks up a descriptor by `link_id` instead of
depending on the numeric order.

The common `link.enabled` field describes the physical profile. An SVT policy
override may make that link effectively disabled for one run without modifying
the common topology object. The adapter validates the common graph first and
then omits an effectively disabled link from the descriptor array. Other
per-link overrides on the same effectively disabled link are rejected.

### 4.3 Boundary validation

For every enabled link, exactly one endpoint must belong to a node listed in
`dut_node_ids`. A link whose endpoints are both DUT-owned or both SVT-owned is
invalid in the real-DUT environment. The adapter also rejects:

- missing or duplicate DUT node IDs;
- a DUT node not present in `pcie_topology_cfg`;
- unsupported port-role combinations;
- duplicate or empty link IDs;
- a width larger than the compiled HDL slot;
- generation values other than 4 or 5;
- an override for a missing or disabled link; and
- PIPE transport during this implementation phase.

The adapter completes validation before the environment creates an SVT agent.

## 5. Static HDL and Runtime Selection

Exactly one topology macro is present in a compiled simulation image:

```text
PCIE_TOPO_EP_X16
PCIE_TOPO_EP_2X8
PCIE_TOPO_SWITCH_1X16_4X4
```

The macros determine only the number and maximum width of Serial HDL slots.
They do not create a maximum-sized collection of dormant VIP agents.

Runtime selection continues to use the common strict command-line contract:

```text
+PCIE_TOPOLOGY=EP_X16|EP_2X8|SWITCH_1X16_4X4
+PCIE_GEN=4|5
+PCIE_FAST_LINK_TRAIN=0|1
```

The runtime profile must match the compiled topology macro. Missing, bare,
empty, duplicate, or conflicting arguments are fatal before agent creation.
The global generation and fast-training values supply defaults. Tests may
provide a policy object with per-`link_id` overrides; command-line per-link
overrides use these forms:

```text
+PCIE_LINK_<link_id>_ENABLE=0|1
+PCIE_LINK_<link_id>_GEN=4|5
+PCIE_LINK_<link_id>_WIDTH=4|8|16
+PCIE_LINK_<link_id>_FAST_LINK_TRAIN=0|1
```

An active width cannot exceed or conflict with the physical slot compiled for
that profile. Unsupported values fail instead of being clipped.

The top level supports separate connection builds for a real DUT and the SVT
peer harness. The real-DUT build exposes one typed Serial interface per
descriptor. The peer build connects each slot to an opposite-role peer without
inserting any cross-port forwarding model.

## 6. SVT Configuration Construction

The environment creates one `svt_pcie_device_configuration`, status, and agent
per descriptor. Configuration is published at the exact agent path before the
agent is created. The configuration builder applies:

- `device_is_root` from the descriptor role;
- Serial transport and the descriptor lane width;
- PCIe specification and maximum data rate for Gen4 or Gen5;
- link equalization mode;
- transaction, symbol, and coverage policy without changing topology;
- active target/requester/driver app configuration required by later
  sequences; and
- Endpoint Multi-Endpoint Mode and target configuration when the agent is an
  Endpoint.

With `PCIE_FAST_LINK_TRAIN=1`, the builder uses the R-2020.12 public
highest-rate equalization-bypass mode already proven by the existing
integration. The test must still observe and check the negotiated generation
and width; enabling acceleration is not itself a pass condition.

### 6.1 Endpoint BAR template

Every Endpoint SVT has one function and three 64-bit Prefetchable BAR pairs:

| BAR pair | Aperture | Low DWORD RO map | High DWORD RO map | Low attributes |
| --- | ---: | ---: | ---: | ---: |
| BAR0/1 | 32 MB | `01ff_ffff` | `0000_0000` | bits `[3:0] = 4'hc` |
| BAR2/3 | 64 KB | `0000_ffff` | `0000_0000` | bits `[3:0] = 4'hc` |
| BAR4/5 | 64 KB | `0000_ffff` | `0000_0000` | bits `[3:0] = 4'hc` |

Initial BAR bases are zero. Enumeration assigns operational addresses. While
reset is asserted, the initialization sequence uses the public Target App
service sequences `SET_BAR_RO_MAP`, `WRITE_ADDR`, `READ_ADDR`, and
`GET_BAR_RO_MAP` on `target_seqr[0]`. It checks both the programmed attributes
and the RO maps. RC agents do not run an Endpoint BAR operation and do not emit
a synthetic BAR-skip result.

R-2020.12 `REFRESH_CFG` is always issued for Endpoint agents after final
configuration publication and before reset release so the HDL Target App sees
`enable_multi_endpoint_mode == 1`. The exact per-agent config object is
republished immediately before the refresh to prevent a broader stale
`uvm_config_db` entry from being selected.

## 7. Environment and Sequencer Structure

`pcie_svt_topology_env` owns dynamic arrays of agent, configuration, status,
and descriptor handles. Components receive stable names derived from the slot
and a sanitized link ID. `connect_phase()` registers each device virtual
sequencer with `pcie_svt_topology_virtual_sequencer`.

The topology virtual sequencer provides checked accessors equivalent to:

```systemverilog
get_port_by_link_id(string link_id);
get_rc_ports();
get_ep_ports();
```

It also stores per-link stage status and the enumeration result associated with
each independent hierarchy. It has no fixed `PCIE_SVT_MAX_PORTS` array and no
primary-port constant. A request for an absent, disabled, or ambiguous link is
fatal with the topology/profile context.

The official two-ended `sys_virt_seqr` remains a compatibility view only. A
new sequence that uses it for a multi-port operation is an integration error.

## 8. Staged Runtime Flow

### 8.1 Configuration and reset

All active link resets begin asserted. The configuration stage waits the
R-2020.12 initialization hold time, refreshes Endpoint configurations, writes
the local SVT configuration databases, programs Endpoint Target App BAR
behavior, and reads back important configuration DWORDs. Work runs in parallel
across links with a per-link watchdog.

### 8.2 Link training

After configuration completes, the environment releases reset and starts the
public DL-link-enable and PL-PHY-enable sequences for all active ports in
parallel. Each link independently waits for Physical Link Up and Data Link Up.
The result is PASS only when the observed generation and width match that
link's policy. Timeout reports include profile, link ID, role, LTSSM status,
observed speed, and observed width.

### 8.3 Enumeration

For `EP_X16`, the RC enumerates the single DUT Endpoint. For `EP_2X8`, each RC
enumerates its own independent hierarchy in parallel and uses a separate BDF
and address-allocation registry.

For `SWITCH_1X16_4X4`, the upstream RC uses the official
`svt_pcie_device_virtual_switch_enumeration_sequence`. The sequence discovers
the DUT USP, four DSPs, and the four Endpoint SVTs behind the DSPs. The
environment records BDFs, bus ranges, Prefetchable Memory windows, and every
Endpoint BAR allocation. It reads the relevant configuration registers back
through the real link, enables Memory Space and Bus Master where required, and
checks that the programmed values were retained.

The registry is descriptor- and topology-driven. It does not assume a legacy
fixed port slot even though the first Switch profile has exactly four DSPs.

### 8.4 Traffic

After successful enumeration, the RC sends Memory Writes and Reads to every
enumerated Endpoint BAR and checks Completion status and returned data. In
Switch mode this is an end-to-end assertion about the real DUT forwarding path.
No monitor callback or helper may inject a copy onto a DSP.

The virtual sequencer reserves an RC host-memory service window and exposes the
sequencer handles needed for a later Endpoint-to-RC DMA test. The first phase
requires RC-to-Endpoint write/read traffic; the reverse-direction traffic API
is retained as an extension point rather than a pass criterion.

### 8.5 Peer verification

The peer harness creates only the opposite role needed for each physical link.
For direct Endpoint profiles, that peer can support link, enumeration, and
Memory traffic testing. For the Switch compile profile, the harness verifies
the five Serial links independently and verifies the four Endpoint SVT BAR
configurations. It does not connect the USP to any DSP and therefore reports
Switch enumeration and traffic as `NOT_RUN`.

## 9. Error Handling and Reporting

The implementation uses strict, early failure and no silent fallback.

- Configuration errors are detected before component creation.
- Configuration initialization, refresh, link, enumeration, and traffic each
  have explicit watchdogs.
- Parallel work records every port's state before the test fails so one failure
  does not hide useful status from other links.
- An exact R-2020.12 vendor warning may be caught only by matching severity,
  report ID, full message, and expected count. Broad warning suppression is
  forbidden.
- A missing inherited compatibility handle remains null. The environment does
  not silently select another agent.

The final report contains one row per `link_id` with `CFG`, `LINK`, `ENUM`, and
`TRAFFIC` state. Valid states are `PASS`, `FAIL`, and `NOT_RUN`. A Switch peer
run must show `NOT_RUN` for enumeration and traffic. Normal passing runs require
zero unexpected UVM warnings, errors, and fatals.

## 10. Source Layout and Migration

The replacement code is organized by responsibility:

```text
svt_pcie_integration/
|-- rtl/
|   |-- Serial and reset interfaces
|   |-- static topology top and real-DUT connection boundary
|   `-- lightweight SVT peer harness
|-- uvm/
|   |-- cfg/
|   |-- adapter/
|   |-- env/
|   |-- sequences/
|   `-- tests/
`-- sim/
    |-- file lists and run scripts
    `-- integration README
```

The Synopsys base environment remains an installation dependency at:

```text
examples/sverilog/tb_pcie_svt_uvm_unified_vip_sys/
env/pcie_device_unified_vip_env.sv
```

The VCS file list compiles it from the configured R-2020.12 installation. It is
not copied into or patched by this project.

The following proven behavior is migrated behind the new APIs. An old class is
retained only when it already has the required dependency boundary; otherwise
its algorithm is moved into a new focused class and the old class is deleted:

- BAR RO-map computation and configuration-space image construction;
- Serial, reset, and width-specific adapter logic;
- the supported Gen4/Gen5 and fast-training settings; and
- calls to official link, enumeration, and application service sequences.

The old Endpoint BAR sizing callback that rewrites received and transmitted
TLPs is not part of the new path. BAR sizing is owned exclusively by the
documented Multi-Endpoint Target App RO-map service. The callback and its unit
test are deleted after the official sequence path passes.

The following legacy structures are removed after their replacements pass:

- `pcie_svt_env` and `pcie_svt_port_env`;
- fixed profile/profile-set classes and the fixed ten-slot virtual sequencer;
- Switch Proxy, sidecar, project-owned Switch forwarding, callbacks,
  scoreboards, and their dedicated tests;
- sequences and registries that depend on fixed port-number constants;
- the TLP converter when no remaining non-Proxy consumer exists; and
- obsolete placeholder or wrapper code superseded by the typed DUT boundary.

Deletion occurs only after a read-only reference audit and successful VCS
verification of the replacement. A post-deletion build and residual-reference
scan are mandatory.

## 11. Verification Strategy and Acceptance Criteria

All simulator-dependent verification runs on `10.11.10.53` with the host's
login-shell VCS and license environment.

### 11.1 Unit and contract tests

- topology-to-descriptor translation for all three profiles;
- DUT-boundary ownership errors and per-link override errors;
- deterministic slot and `link_id` lookup behavior;
- Gen4/Gen5, width, transport, and fast-training translation;
- BAR attribute and RO-map values;
- topology virtual sequencer lookup and stage-state reporting; and
- exact handling of any known R-2020.12 warning.

### 11.2 Compile and elaboration matrix

Each of the three topology macros must compile and elaborate against the actual
R-2020.12 installation. With every profile link effectively enabled, the
elaborated UVM topology must contain exactly:

- one agent for `EP_X16`;
- two agents for `EP_2X8`; and
- five agents for `SWITCH_1X16_4X4`.

There must be no dormant maximum-sized agent collection.

### 11.3 Runtime matrix

| Build | Gen4 | Gen5 | Required peer result |
| --- | --- | --- | --- |
| `EP_X16` | run | run | configuration, link, enumeration, traffic PASS |
| `EP_2X8` | run | run | both independent hierarchies PASS |
| `SWITCH_1X16_4X4` | run | run | five links and four EP BAR configurations PASS; enumeration/traffic NOT_RUN |

At least one Gen4 and one Gen5 run also enable fast link training and check the
negotiated result.

### 11.4 Real Switch readiness

Until a real Switch DUT is available, the real-DUT test must compile and expose
the complete five-port interface, enumeration sequence, registry, and traffic
sequence. Once connected, acceptance requires:

- all five links reach Physical Link Up and Data Link Up;
- the RC discovers exactly one USP, four DSPs, and four Endpoint SVTs;
- each Endpoint reports the three required BAR pairs and assigned addresses;
- bridge windows cover the assigned Endpoint ranges; and
- Memory Write/Read traffic completes successfully through every DSP.

No peer-only result satisfies these real-Switch criteria.

### 11.5 Regression and cleanup gates

- Existing `pcie_tl_vip` topology and traffic regressions remain green.
- Passing SVT runs end with zero unexpected UVM warnings, errors, and fatals.
- No new source includes or instantiates a removed Proxy, sidecar, fixed profile,
  or fixed-slot class.
- The documented compile and run commands work from a clean checkout with the
  R-2020.12 installation configured.

## 12. Completion Definition

This redesign is complete when the replacement source structure is present,
the matrix above passes to the extent possible without a real Switch DUT, the
real-DUT Switch path is compile-ready without a software forwarding model, all
obsolete legacy integration files and references are removed, and the user
documentation describes the supported profiles, arguments, status meanings,
and real-DUT connection boundary.
