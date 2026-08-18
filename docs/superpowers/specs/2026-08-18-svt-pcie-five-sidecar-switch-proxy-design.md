# SVT PCIe Five-Sidecar Switch Proxy Design

**Date:** 2026-08-18

**Status:** Approved in design review; pending written-spec confirmation

**Validation host:** `ubuntu@10.11.10.53`

**Synopsys release:** SVT PCIe R-2020.12

## 1. Purpose

Build a verification-only PCIe Switch Proxy for the
`PCIE_TOPO_SWITCH_1X16_4X4` topology. The proxy must present one x16 Upstream
Port and four x4 Downstream Ports, let the existing primary SVT Root Complex
enumerate four downstream SVT Endpoints, and forward the approved downstream
and upstream traffic at Gen4 or Gen5.

The production design uses five full active Proxy Device Agents and five
standalone passive sidecars. This is required by the accepted Task 1 evidence:

- an active R-2020.12 Device Agent has no usable public `tl_mon` handle;
- `is_active=1` and `enable_monitor=1` cannot be combined;
- a Target App callback can clone and suppress an incoming Request; and
- a standalone passive monitor is the documented public boundary that exposes
  the original returning Completion TLP.

This document supersedes the active-TL-callback receive boundary in
`2026-08-15-svt-pcie-switch-proxy-design.md`. It extends the proven two-link
feasibility architecture in
`2026-08-17-svt-pcie-passive-sidecar-proxy-design.md` to the production
five-port switch. It does not invalidate the completed switch-package work or
the Task 1 feasibility evidence.

## 2. Scope

### 2.1 Included

- Compile-selected `PCIE_USE_SVT_SWITCH_PROXY` mode.
- One x16 primary-RC-to-Proxy-USP Serial link.
- Four x4 primary-EP-to-Proxy-DSP Serial links.
- Five width-matched, input-only passive SERDES sidecars.
- Minimal complete Type-1 configuration images for one USP and four DSPs.
- Dynamic BDF, Type-1-to-Type-0, bridge-window, and exact Completion routing.
- Explicit SVT-to-repository TLP conversion for Configuration, Memory, and
  Completion TLPs.
- Official SVT switch enumeration initiated only by primary RC0.
- Four downstream Memory Write/Read checks and four upstream Memory Write
  checks.
- Gen4/Gen5 default and optional fast-training validation.
- Original single-Endpoint x16 regression preservation.

### 2.2 Deferred

- PIPE connectivity.
- Endpoint-to-Endpoint P2P.
- Nested switches, hot plug, AER injection, and power-management flows.
- SR-IOV or multiple functions behind a DSP.
- Sustained-bandwidth and fairness testing.
- Replacement of the proxy with the real controller RTL.

## 3. Compile and Runtime Selection

`PCIE_USE_SVT_SWITCH_PROXY` is legal only with
`PCIE_TOPO_SWITCH_1X16_4X4`. It is mutually exclusive with
`PCIE_USE_SVT_PEER` and the placeholder-DUT build.

Only this compile mode contains the ten active agents and five passive
sidecars. The single-Endpoint x16, dual-Endpoint x8, and other macro-selected
images retain their existing static agent counts.

The full proxy image has:

```text
5 primary active agents
5 Proxy active agents
5 passive sidecars
------------------------
15 R-2020.12 Device Agents
```

`+PCIE_DISABLE_SWITCH_SIDECARS` is legal only together with
`+PCIE_LINK_ONLY`. That combination measures the ten-active-agent link
baseline and cannot claim proxy observation, enumeration, or forwarding
success. Enumeration and traffic modes require all five sidecars.

## 4. Topology

```text
Primary RC  -- x16 Serial -- Proxy USP -- adapter --+
                              sidecar x16            |
                                                     +-- pcie_tl_switch
Primary EP0 -- x4 Serial --- Proxy DSP0 -- adapter --|
Primary EP1 -- x4 Serial --- Proxy DSP1 -- adapter --|
Primary EP2 -- x4 Serial --- Proxy DSP2 -- adapter --|
Primary EP3 -- x4 Serial --- Proxy DSP3 -- adapter --+
                              one x4 sidecar per link
```

Each active endpoint owns a distinct Unified VIP interface. Each sidecar owns
a separate standalone SERDES interface populated by an input-only HDL tap.
No passive output is connected to an active link. Passive agents do not train
links, send DLLPs or TLPs, or count as either end of a link pair.

The five active pairs are:

| Primary side | Proxy side | Width |
| --- | --- | --- |
| RC0 | USP | x16 |
| EP0 | DSP0 | x4 |
| EP1 | DSP1 | x4 |
| EP2 | DSP2 | x4 |
| EP3 | DSP3 | x4 |

## 5. Receive and Send Ownership

### 5.1 Requests

Each Proxy active Target App owns one
`svt_pcie_target_app_callback`. For a supported Configuration or Memory
Request, `post_rx_tlp_get`:

1. validates the handles and TLP class;
2. clones the vendor transaction;
3. enqueues the clone with `mailbox::try_put`;
4. increments the Request-capture counter; and
5. sets `drop=1`.

The callback performs no conversion, wait, switch call, or sequence start.
Its `pre_tx_tlp_put` is a safety wall: any locally generated Proxy Target
response is dropped, counted, and treated as a test failure. The final gate
requires zero such transmissions.

### 5.2 Completions

The active Requester path does not expose a usable public raw-TLP monitor.
Each passive sidecar therefore supplies the Completion receive boundary. Its
RX subscriber clones only Completion and Completion-with-Data TLPs into the
port adapter's Completion mailbox.

A Request observed on passive RX and every TLP observed on passive TX are
observation-only. They feed the scoreboard but never re-enter the switch.
This directional filter prevents duplicate ownership and forwarding loops.

### 5.3 Egress

The switch writes a repository-owned TLP to a port's TX FIFO. The matching
adapter converts it to a fresh `svt_pcie_tlp` and starts a fresh raw-TLP
sequence on that Proxy active Agent's public `pcie_agent.tlp_seqr`.
Forwarding success is counted only after the raw sequence returns.

## 6. Component Boundaries

### 6.1 Target callback

`pcie_svt_switch_target_callback` accepts supported Requests, clones them into
the adapter, and suppresses local Target ownership. It rejects Completion or
unsupported classes at this boundary.

### 6.2 Passive subscriber

`pcie_svt_switch_sidecar_subscriber` has a fixed port and observation role.
Only its Completion-RX role may enqueue into the adapter. All roles clone
before retaining a transaction and publish independent observations to the
scoreboard.

### 6.3 Port adapter

Each `pcie_svt_switch_port_adapter` owns two unbounded mailboxes:

```text
request_mbox     <- active Target callback
completion_mbox  <- passive sidecar RX subscriber
```

Separate worker tasks drain the mailboxes, convert each clone, and put one
normalized object into the same switch-port RX FIFO. A third worker drains
the switch-port TX FIFO and performs raw active-Agent reinjection.

### 6.4 Converter

`pcie_svt_tlp_converter` maps supported `(Fmt, Type)` tuples explicitly. It
preserves TC, attributes, length, address, byte enables, Requester ID,
Completer ID, full 10-bit Tag, Completion Status, byte count, lower address,
and every payload byte. Unsupported Message, Atomic, or Vendor TLPs fail with
a non-empty diagnostic; they are never silently dropped.

### 6.5 Switch core

`pcie_tl_switch` is the only routing and switch-configuration owner. It
implements one USP and four DSP Type-1 images, exact BDF lookup, dynamic
32-bit non-Prefetchable and 64-bit Prefetchable windows, Type-1-to-Type-0
conversion at directly attached Endpoint buses, and local configuration
responses.

Every forwarded non-posted Request records its ingress under the full
`{Requester ID, Tag}` key. A returning Completion routes through that entry
and deletes it. Duplicate keys, unknown Completions, or outstanding entries at
the final gate are fatal.

### 6.6 Scoreboard

The scoreboard's proof boundary is independent of callback ownership. It
compares sidecar observations at ingress and egress using:

```text
direction, ingress, egress, Fmt/Type, Requester ID, Completer ID,
10-bit Tag, address, length, byte enables, Completion fields, payload digest
```

It detects wrong egress, missing or duplicate forwarding, payload mismatch,
unmatched Completion, and a forwarding loop. Target memory readback remains
an additional end-to-end data check, not a substitute for wire proof.

## 7. Configuration and Enumeration

The Type-1 images expose non-FFFF Vendor/Device IDs, Bridge class code,
Header Type 1, PCIe capability, USP/DSP port type, Command, bus-number,
non-Prefetchable window, and 64-bit Prefetchable window registers with
byte-enable semantics.

Each downstream Endpoint exposes these fixed 64-bit Prefetchable BAR pairs:

| BAR pair | Aperture |
| --- | ---: |
| BAR0/1 | 32 MiB |
| BAR2/3 | 64 KiB |
| BAR4/5 | 64 KiB |

Only primary RC0 starts
`svt_pcie_device_virtual_switch_enumeration_sequence`. Final Endpoint BDFs,
BAR bases, secondary/subordinate buses, and bridge windows are not preloaded.
The result registry requires exactly one USP, four DSPs, four Endpoints, and
twelve BAR apertures. It rejects overlap, a BAR outside its parent window, a
non-Prefetchable or 32-bit Endpoint BAR, or duplicate BDFs.

## 8. Startup Stages

The full flow executes in this order:

```text
CFG_INIT
RESET_RELEASE_CHECK
ACTIVE_LINK_BRINGUP
SIDECAR_READY_CHECK
ENUMERATION
TRAFFIC
FINAL_CHECK
```

All ten active Device Agents are enabled concurrently. The five active link
pairs must all report Link Up, the selected generation, the expected width,
and LTSSM L0 before the flow continues. Sidecar readiness requires a non-null
passive `tl_mon`, connected RX/TX analysis ports, the correct width-matched
SERDES interface, and successful setup/readback of the minimal checker image.
The passive agents are not treated as active link endpoints.

No later stage starts after an earlier fatal or bounded timeout.

## 9. Error Handling

The following conditions are fatal:

- missing active, passive, callback, subscriber, sequencer, or switch handle;
- a passive tap driving or feeding back into an active link;
- a Proxy Target App generating a local response;
- blocking work or sequence start from a callback or analysis `write()`;
- clone, conversion, or raw reinjection failure;
- an unsupported TLP in an approved flow;
- duplicate outstanding key or unknown Completion;
- wrong port, duplicate/missing transaction, or field/payload mismatch;
- a 100 us packet or service wait timeout; or
- nonempty adapter queues, scoreboard state, or outstanding table at the final
  gate.

No report catcher, severity downgrade, private vendor state, hierarchical
`force`/`deposit`, or Synopsys source modification is permitted.

## 10. Verification Strategy

Implementation remains TDD and proceeds through independent gates:

1. Type-1 configuration-space unit test.
2. Dynamic BDF, 64-bit window, Type conversion, and Completion-routing unit
   test.
3. SVT/repository TLP converter round-trip unit test.
4. Target-callback plus passive-Completion dual-queue adapter unit test.
5. Five-link `LINK_ONLY` ten-active baseline with sidecars disabled.
6. Five-link `LINK_ONLY` run with all five passive sidecars enabled.
7. Gen4 official enumeration.
8. Four downstream Memory Write/Read paths and four upstream Memory Writes.
9. Gen4 default, Gen5 default, Gen4 fast, and Gen5 fast full-flow matrix.
10. Original single-Endpoint x16 default/fast Gen4/Gen5 regression matrix.

Every formal run requires exact pass-marker counts, zero adapter drops, an
empty outstanding table and scoreboard, and UVM W/E/F=`0/0/0`. All VCS
compilation and simulation runs execute on `10.11.10.53` through a Bash login
shell. The Synopsys installation remains read-only.

## 11. Acceptance Boundary

The feature is accepted only when all of these are true:

- one x16 and four x4 active links reach L0 at the selected generation;
- all five passive sidecars remain input-only and decode their assigned link;
- official enumeration reports one USP, four DSPs, four Endpoints, and the
  twelve required BAR apertures;
- every approved Request and Completion is forwarded exactly once with full
  protocol-significant field and payload preservation;
- all eight traffic paths pass end-to-end memory and wire checks;
- the four Gen4/Gen5 default/fast full runs end with W/E/F=`0/0/0`; and
- the original single-Endpoint x16 regression matrix remains clean.

Passing a ten-active-agent link-only baseline with sidecars disabled proves
only link bring-up. It cannot satisfy enumeration, forwarding, or final
acceptance.
