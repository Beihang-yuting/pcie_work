# SVT PCIe R-2020.12 Integration Framework Design

> Date: 2026-08-13
>
> Status: Approved
>
> Validation host: `ubuntu@10.11.10.53`
>
> Synopsys release: SVT PCIe R-2020.12

## 1. Goal

Add a reusable Synopsys SVT PCIe integration framework to `pcie_work`. The
framework controls complete active SVT PCIe protocol stacks connected to a
controller DUT through Serial/SERDES interfaces. It supports three mutually
exclusive compile-time topologies, Gen4 or Gen5 runtime selection, independent
per-port profiles, SVT-owned configuration spaces, link bring-up, and later DUT
enumeration without changing the framework structure.

Phase 1 must do more than compile. It must:

1. compile and elaborate all three DUT-placeholder topologies;
2. replace the placeholder with SVT peer agents in a verification-only build;
3. bring every active Serial link to Link Up and LTSSM L0 at both Gen4 and
   Gen5; and
4. check the negotiated width and speed on every link.

The framework must not copy or commit Synopsys commercial source code. It
references the installed release through environment variables and file lists.

## 2. Scope and Boundaries

### 2.1 Phase 1 deliverables

- Compile-time topology selection and mutual-exclusion checks.
- A single DUT wrapper interface whose ports vary with the selected topology.
- Serial adapters between DUT differential lanes and `svt_pcie_if`.
- One active SVT agent for each port facing the DUT.
- Independent port profiles with complete, directly usable templates.
- SVT internal configuration-space initialization and read-back checks.
- Correct Endpoint BAR sizing behavior during enumeration probes.
- Link bring-up sequences with bounded waits and useful diagnostics.
- An optional SVT peer harness for real link-up validation.
- VCS file list and usage documentation.
- Six passing peer simulations: three topologies at Gen4 and Gen5.

### 2.2 Deferred work

- Integration with the real controller DUT RTL.
- Proof of USP-to-DSP forwarding through the real switch DUT.
- Full enumeration of the real switch's USP and DSP functions.
- End-to-end application traffic through the real switch.
- PIPE interface support.
- Equalization-specialized test scenarios, error injection, polarity reversal,
  lane reversal, and channel impairment.

The peer harness validates each physical link independently. In the switch
topology it does not emulate a switch fabric and therefore cannot validate DUT
internal routing or a single coherent switch hierarchy.

## 3. Selected Architecture

The design uses a thin adapter around the official Unified VIP rather than
copying the official two-VIP example environment.

Each DUT-facing link has only one primary SVT agent. The opposing component is
either the real DUT, the phase-1 placeholder, or an optional peer SVT agent.
Profile data is the single source of truth for both SVT protocol behavior and
the configuration-space image exposed by an SVT endpoint.

Alternatives considered were:

- fixed raw configuration-space DWORD arrays, which are compact but make
  capability links and behavior/configuration consistency fragile;
- using only the UVM register model, which is useful for discovery and checking
  but is not the only initialization path for the VIP's responding
  configuration database; and
- a custom behavioral switch substituted for the DUT, which would duplicate
  DUT behavior and expand phase 1 substantially.

The selected structured-profile and SVT-peer approach gives early proof of the
actual integration boundaries without pretending to verify a switch fabric
that is not present.

## 4. Compile-Time Topologies

Exactly one of these macros must be defined by the user on the VCS command
line:

```text
+define+PCIE_TOPO_EP_X16
+define+PCIE_TOPO_EP_2X8
+define+PCIE_TOPO_SWITCH_1X16_4X4
```

No macro or more than one macro is a compile-time error.

### 4.1 `PCIE_TOPO_EP_X16`

```text
SVT RC0 x16 <-> DUT EP0 x16
```

### 4.2 `PCIE_TOPO_EP_2X8`

```text
SVT RC0 x8 <-> independent DUT EP0 x8
SVT RC1 x8 <-> independent DUT EP1 x8
```

The two endpoints are independent root hierarchies and are started
concurrently.

### 4.3 `PCIE_TOPO_SWITCH_1X16_4X4`

```text
SVT RC0 x16 <-> DUT USP x16
DUT DSP0 x4  <-> SVT EP0 x4
DUT DSP1 x4  <-> SVT EP1 x4
DUT DSP2 x4  <-> SVT EP2 x4
DUT DSP3 x4  <-> SVT EP3 x4
```

This uses all 32 physical lanes. The five ports are members of one root
hierarchy for later real-DUT enumeration.

Only topology-selected HDL and UVM agents are created: one, two, or five
primary agents respectively. Unused agents are not statically instantiated.

## 5. Runtime Control

The Unified VIP HDL is compiled with PCIe 5.0 capability. The required runtime
argument limits the maximum generation for the current run:

```text
+PCIE_GEN=4
+PCIE_GEN=5
```

The mapping is:

| `PCIE_GEN` | Advertised speeds | Expected negotiated speed |
|---|---|---|
| 4 | Gen1 through Gen4 | 16 GT/s |
| 5 | Gen1 through Gen5 | 32 GT/s |

All active links in one simulation use the same generation. A missing value or
a value other than 4 or 5 causes `uvm_fatal`. Link width remains a compile-time
topology property because it must agree with the HDL agent lane count.

The optional verification-only macro is:

```text
+define+PCIE_USE_SVT_PEER
```

It selects the peer harness instead of the DUT placeholder. It is not a fourth
topology and does not change the primary port profiles.

## 6. File and Component Layout

The implementation will use the following focused units:

```text
svt_pcie_integration/
├── rtl/
│   ├── pcie_svt_topology_top.sv
│   ├── pcie_svt_serial_adapter.sv
│   ├── pcie_dut_placeholder.sv
│   ├── pcie_svt_peer_harness.sv
│   └── pcie_svt_topology_checks.svh
├── uvm/
│   ├── pcie_svt_integration_pkg.sv
│   ├── pcie_svt_port_env.sv
│   ├── pcie_svt_env.sv
│   ├── pcie_svt_virtual_sequencer.sv
│   ├── pcie_svt_base_test.sv
│   ├── pcie_svt_profile.sv
│   ├── pcie_svt_profile_set.sv
│   ├── pcie_svt_cfg_space_builder.sv
│   └── sequences/
│       ├── pcie_svt_cfg_space_init_seq.sv
│       ├── pcie_svt_all_cfg_spaces_init_vseq.sv
│       ├── pcie_svt_link_bringup_seq.sv
│       ├── pcie_svt_all_links_bringup_vseq.sv
│       ├── pcie_svt_topology_enumeration_vseq.sv
│       ├── pcie_svt_post_enum_enable_vseq.sv
│       └── pcie_svt_peer_smoke_vseq.sv
└── sim/
    ├── pcie_svt.f
    └── README.md
```

`pcie_svt_port_env` owns one agent, configuration, status object, Unified
virtual interface, profile, and virtual sequencer handle. The top environment
creates only the selected ports and connects them to a topology-wide virtual
sequencer.

The virtual sequencer contains bounded arrays for the supported design:

```text
rc_seqr[2]
ep_seqr[4]
port_status[6]
port_profile[6]
active_port_mask
```

Entries that do not exist in the selected topology remain inactive and are
never dereferenced.

## 7. Unified VIP HDL and Serial Connection

Every active Unified VIP port uses:

```systemverilog
SVT_PCIE_UI_PCIE_SPEC_VER          = PCIe 5.0
SVT_PCIE_UI_PHY_INTERFACE_TYPE     = SERDES
SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE = 1
SVT_PCIE_UI_ENABLE_CFG_BLOCK       = 1
SVT_PCIE_UI_CONNECT_ACTIVE_VIP     = 1
```

After creating `svt_pcie_device_configuration`, the test calls:

```systemverilog
cfg.set_initial_values_via_unified_vif(1, unified_if);
```

It then applies the profile so user settings are not overwritten by values
copied from the HDL instance.

The Serial adapter performs signal mapping only:

```text
SVT tx_datap_N / tx_datan_N -> DUT rx_p[N] / rx_n[N]
DUT tx_p[N] / tx_n[N]       -> SVT rx_datap_N / rx_datan_N
```

It also connects the official per-lane clock/activity signals required by
transmit-bit-clock mode:

```text
tx_clk_N
rx_clk_N
active_tx_transmit_clk_N
active_rx_recovered_clk_N
```

No encoding, LTSSM, equalization, or data manipulation belongs in the adapter.
The same profile and sequence layers will be retained when a later PIPE adapter
is introduced.

The placeholder exposes only the ports selected by the topology macro and
drives stable defaults. It is expected not to train a link.

## 8. Port Profiles

Each active primary and peer port receives an independent
`pcie_svt_port_profile`. Templates are complete and runnable without user edits.
Fields that do not affect topology, enumeration, or traffic semantics use fixed
legal values.

The top-level profile contains:

```text
port_id
role                       // RC or EP
link_width                 // x4, x8, or x16
max_gen                    // set from +PCIE_GEN
root_hierarchy
functions[]
```

Each function profile contains:

```text
Vendor ID / Device ID
Class Code / Revision ID
Header Type
Subsystem Vendor ID / Subsystem Device ID
Command and Status reset values
BAR0 through BAR5 and expansion ROM
PCIe Capability
MSI and MSI-X
AER
SR-IOV
ATS, PRI, and PASID
ARI and ACS
Resizable BAR
optional raw DWORD overrides
```

The supplied EP templates use stable distinct Device IDs where useful for
debug. Revision ID, subsystem IDs, interrupt pin, capability locations,
completion-timeout support, default payload size, default read-request size,
and reserved fields are fixed to legal values unless a test explicitly needs
to change them.

Raw DWORD overrides are applied last and are intended only for uncommon
registers. They cannot overwrite capability-link fields or BAR attribute bits
without an explicit consistency check.

### 8.1 Profile consumers

The same profile is consumed twice:

1. During `build_phase`, it configures
   `svt_pcie_device_configuration`, including role, supported generation,
   width, protocol behavior, and capability-related behavior controls.
2. Before link release in `run_phase`, `pcie_svt_cfg_space_builder` converts it
   to the configuration-space image and Target App BAR model programming used
   by `pcie_svt_cfg_space_init_seq`.

Declaring a capability in configuration space while leaving the associated SVT
behavior disabled is a fatal profile error. Dependencies such as PRI or PASID
without ATS are also fatal.

## 9. Endpoint BAR Template and Sizing

Every SVT Endpoint template implements three 64-bit Prefetchable Memory BARs:

| Register pair | Type | Aperture |
|---|---|---:|
| BAR0/BAR1 | 64-bit Prefetchable Memory | 32 MiB |
| BAR2/BAR3 | 64-bit Prefetchable Memory | 64 KiB |
| BAR4/BAR5 | 64-bit Prefetchable Memory | 64 KiB |

The initial base addresses are zero. The enumerating RC probes and assigns the
addresses. The low DWORD contains the Memory, 64-bit, and Prefetchable
attribute encoding; the paired high DWORD is the upper address portion.

Programming the configuration database alone does not define sizing-probe
behavior. The initialization sequence therefore programs both:

1. `svt_pcie_cfg_database_service` for the visible BAR DWORD values; and
2. `svt_pcie_target_app_service_set_bar_ro_map_sequence` for the Target App
   BAR read-only maps.

The aperture-derived low-DWORD read-only maps are:

```text
BAR0 (32 MiB): 0x01FF_FFFF
BAR2 (64 KiB): 0x0000_FFFF
BAR4 (64 KiB): 0x0000_FFFF
```

The paired high DWORD maps are configured consistently with a 64-bit aperture,
not treated as independent BAR windows. The builder verifies pairing, power-of-
two aperture, alignment, type bits, and non-overlap of assigned addresses.

After enumeration, a BAR sizing/read-back check must observe size masks
equivalent to:

```text
BAR0 low: 0xFE00_000C   // address mask plus 64-bit/prefetchable attributes
BAR2 low: 0xFFFF_000C
BAR4 low: 0xFFFF_000C
```

## 10. Configuration-Space Construction and Initialization

The builder creates a complete 4 KiB image per function. It owns:

- Type 0 or Type 1 header selection;
- standard Capability pointer construction;
- standard and Extended Capability next-pointer construction;
- alignment and overlap validation;
- Gen4/Gen5 Maximum Link Speed and Supported Link Speeds consistency;
- MSI-X Table and PBA BAR reference validation;
- SR-IOV, ATS, PRI, PASID, ARI, and related dependency validation; and
- agreement between advertised features and SVT behavior controls.

`pcie_svt_cfg_space_init_seq` runs on the selected port's
`cfg_database_seqr`. It issues `svt_pcie_cfg_database_service` requests using
`WRITE_CFG_DWORD` and verifies important locations with `READ_CFG_DWORD`. It
also starts the Target App BAR-map service sequences on the appropriate target
sequencer.

`pcie_svt_all_cfg_spaces_init_vseq` starts one initialization sequence for
every active port concurrently. Each port uses its own profile and reports its
own failures.

The following official sequences are not initialization mechanisms:

- `svt_pcie_full_discovery_sequence` discovers a reachable topology and builds
  a register-model representation;
- `svt_pcie_config_space_bit_bash_sequence` tests discovered register fields.

They are reserved for later discovery and dedicated register tests.

## 11. Reset and Startup Flow

A reset coordinator holds DUT and all active Unified interfaces in reset from
power-on. Per-port reset handles remain available so later tests can reset one
link independently.

The normal startup flow is:

```text
hold all resets stable
-> create/configure all active agents
-> preload every SVT configuration database through its backdoor service
-> configure Endpoint Target App BAR sizing behavior
-> read back critical configuration DWORDs
-> release active-link resets together
-> enable Data Link operation on all active SVT agents
-> wait for Link Up and L0 on every active link
-> run topology-specific enumeration
-> enable post-enumeration control bits
-> start later application traffic
```

Configuration preload is intentionally performed while external link reset is
held, and after UVM components and sequencers exist. A later test that resets or
clears the SVT configuration database must explicitly rerun initialization;
the phase-1 reset coordinator does not issue `RESET_MEM` after preload.

## 12. Link Bring-Up

`pcie_svt_link_bringup_seq` is a single-port wrapper around:

```systemverilog
svt_pcie_dl_service_set_link_en_sequence
```

It constrains `enable == 1'b1` and runs on that agent's DL sequencer. It then
waits with a bounded timeout for:

```systemverilog
status.pcie_status.pl_status.link_up == 1'b1
status.pcie_status.pl_status.ltssm_state == svt_pcie_types::L0
```

`pcie_svt_all_links_bringup_vseq` starts this operation concurrently on every
active primary port. With the peer harness enabled, both ends of every link run
the link-enable operation concurrently and both status objects must reach L0.

The specialized SERDES link-up-with-equalization sequences are not the default
startup path. They remain available for later equalization-focused tests.

On timeout, the wrapper reports port ID, role, current LTSSM state, current
speed, negotiated width, expected speed, and expected width.

## 13. Topology Enumeration and Post-Enumeration Enable

These operations are implemented now as reusable sequences even though the
placeholder cannot execute them and phase 1 does not prove real-switch
enumeration.

### 13.1 EP x16

RC0 runs:

```systemverilog
svt_pcie_device_virtual_ep_enumeration_sequence
```

### 13.2 Two independent EP x8 links

RC0 and RC1 run independent EP enumeration sequences concurrently. They use
different `root_hierarchy` values and independent address spaces.

### 13.3 Real switch topology

Only RC0 runs:

```systemverilog
svt_pcie_device_virtual_switch_enumeration_sequence
```

with:

```systemverilog
switch_parms.enumerate_device_beneath_dsp = 1'b1;
```

This is intended to enumerate the real DUT USP, four DSPs, and the four SVT EPs
below those DSPs. The four downstream SVT EP agents only respond to requests;
they do not initiate enumeration.

After successful enumeration, `pcie_svt_post_enum_enable_vseq` enables only
profile-requested features, including Memory Space Enable, Bus Master Enable,
MSI/MSI-X, SR-IOV VFs, ATS, PRI, PASID, AER reporting, and selected PCIe Device
Control fields.

Any link failure prevents enumeration. Any enumeration failure prevents
post-enumeration enable and application traffic.

## 14. SVT Peer Harness

The `PCIE_USE_SVT_PEER` build replaces the DUT placeholder with opposing SVT
ports:

```text
EP_X16
  primary RC0 x16 <-> peer EP0 x16

EP_2X8
  primary RC0 x8 <-> peer EP0 x8
  primary RC1 x8 <-> peer EP1 x8

SWITCH_1X16_4X4
  primary RC0 x16 <-> peer EP-USP x16
  primary EP0 x4  <-> peer RC-DSP0 x4
  primary EP1 x4  <-> peer RC-DSP1 x4
  primary EP2 x4  <-> peer RC-DSP2 x4
  primary EP3 x4  <-> peer RC-DSP3 x4
```

The switch peer build contains ten SVT agents, but only in verification builds.
Production builds with the real DUT contain five primary agents.

The peer smoke sequence:

1. initializes primary and peer profiles;
2. programs configuration spaces and Endpoint BAR behavior;
3. releases reset;
4. enables both sides of all links concurrently;
5. waits for Link Up and L0 on both sides;
6. checks exact negotiated width and selected Gen4/Gen5 speed; and
7. performs a minimal configuration access on links with an RC/EP pair.

In the switch peer topology, four peer RCs may enumerate the four primary SVT
EPs independently to validate their configuration templates and BAR sizing.
The primary RC may similarly access the peer EP on the x16 link. These are five
independent root hierarchies in peer mode and are not evidence of switch
forwarding.

## 15. Error Handling

- Invalid topology macro selection is a compile-time error.
- Missing or invalid `PCIE_GEN` is `uvm_fatal` before startup.
- Profile role, lane count, or hierarchy mismatch is `uvm_fatal`.
- Capability alignment, overlap, broken next pointers, illegal BAR pairing, or
  capability/behavior mismatch is `uvm_fatal`.
- Configuration backdoor failure reports port, function, DWORD address,
  request status, expected value, and actual value.
- BAR model programming failure reports port, function, BAR number, aperture,
  and requested read-only map.
- Link timeout reports the complete per-port status described above.
- Enumeration failure reports root hierarchy, BDF, Configuration Completion
  Status, and current enumeration stage.
- A failure in any required active link blocks all later stages.

All waits have explicit timeouts. No test may hang indefinitely waiting for
Link Up, L0, a configuration completion, or an idle condition.

## 16. VCS Validation

All simulation validation runs on `10.11.10.53` under a Bash login shell so
the host's VCS and license environment is active. The installed VIP root is:

```text
/home/ubuntu/synopsys/designware_vip_R-2020.12
```

### 16.1 Placeholder compile/elaboration matrix

Compile and elaborate each topology without `PCIE_USE_SVT_PEER`:

```text
PCIE_TOPO_EP_X16
PCIE_TOPO_EP_2X8
PCIE_TOPO_SWITCH_1X16_4X4
```

Acceptance requires no compiler or elaboration errors, no width mismatch,
duplicate driver, unresolved hierarchy, or invalid UVM configuration path.
These builds do not run link training.

### 16.2 Peer link-up matrix

Compile with `PCIE_USE_SVT_PEER` and run:

| Topology | Runtime | Required result |
|---|---|---|
| EP x16 | `+PCIE_GEN=4` | one x16 link at 16 GT/s, both ends in L0 |
| EP x16 | `+PCIE_GEN=5` | one x16 link at 32 GT/s, both ends in L0 |
| 2 EP x8 | `+PCIE_GEN=4` | two simultaneous x8 links at 16 GT/s, all ends in L0 |
| 2 EP x8 | `+PCIE_GEN=5` | two simultaneous x8 links at 32 GT/s, all ends in L0 |
| Switch port set | `+PCIE_GEN=4` | one x16 and four x4 links at 16 GT/s, all ends in L0 |
| Switch port set | `+PCIE_GEN=5` | one x16 and four x4 links at 32 GT/s, all ends in L0 |

Every run must end with zero `UVM_ERROR` and zero `UVM_FATAL`. Link-up success
alone is insufficient if negotiated width or speed differs from the selected
profile.

The peer tests also verify critical configuration DWORD read-back. Endpoint
enumeration smoke checks must observe the 32 MiB, 64 KiB, and 64 KiB
Prefetchable 64-bit BAR layout.

## 17. Documentation and Security

`sim/README.md` documents:

- the required Synopsys environment variable;
- the three topology macros;
- the optional peer macro;
- Gen4 and Gen5 runtime examples;
- the distinction between placeholder compile testing, peer link testing, and
  real-DUT switch testing; and
- the expected status messages and log locations.

No GitHub token, simulation-host password, license string, commercial SVT
source, or absolute user-specific credential path is written into the
repository. External installation paths are passed through environment
configuration except where the validation-host location is documented for the
team.

## 18. Completion Criteria

Phase 1 is complete only when:

1. the three placeholder builds compile and elaborate;
2. the six SVT-peer runs pass on the VCS host;
3. every required peer link reaches Link Up and L0 at the expected speed and
   width;
4. profile and configuration-space initialization checks pass;
5. Endpoint BAR sizing checks return the approved apertures and attributes;
6. no Synopsys commercial source or credentials are added to Git; and
7. the README contains reproducible build and run commands.

Success in phase 1 proves the framework, Unified VIP configuration, Serial
mapping, reset sequencing, configuration-space setup, and link-control
sequences. It does not claim that the real DUT switch enumerates or forwards
traffic until those tests run with the real DUT.
