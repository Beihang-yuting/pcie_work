# SVT PCIe Dynamic Control-Plane Observation Design

**Date:** 2026-08-19

**Status:** Written-spec review

**Validation host:** `ubuntu@10.11.10.53`

**Synopsys release:** SVT PCIe R-2020.12

## 1. Purpose

Allow the official SVT switch-enumeration sequence to drive the five-link
Switch Proxy without pre-registering scoreboard expectations before the SVT
Requester assigns its final wire Tag.

The existing strict scoreboard assumes that an expected Request is installed
before the passive sidecar observes that Request. This assumption is valid for
repository-owned traffic sequences, but it is not valid for
`svt_pcie_device_virtual_switch_enumeration_sequence`: no public R-2020.12
callback exposes the Requester's final Tag before passive RX. Registering from
a Proxy Target callback is also too late because passive RX may execute first
in the same control-plane transaction.

The solution is to publish the Switch Proxy's actual routing decision and let
the scoreboard correlate it with a strictly deferred passive RX observation.
Correlation uses the final normalized TLP captured after it reaches the Proxy,
so it includes the real 10-bit Tag. The design preserves exactly-once wire
checking and does not weaken Task 6 or Task 10 traffic checks.

This document extends Sections 5, 6, 9, and 10 of
`2026-08-18-svt-pcie-five-sidecar-switch-proxy-design.md`. All topology,
ownership, conversion, link, sidecar, and final-acceptance requirements in that
design remain in force.

## 2. Scope

### 2.1 Included

- A repository-side route-observation event emitted by `pcie_tl_switch`.
- Ordinary Request forwarding, Completion forwarding, Cfg1-to-Cfg0 rewriting,
  local Configuration Read/Write responses, and route drops.
- A scoreboard deferred-enumeration mode that accepts either RX-first or
  route-event-first ordering.
- Exact final-wire validation of ingress, egress, protocol-significant fields,
  payload, and exactly-once behavior.
- Immediate or final-gate failures for drop, duplicate, ambiguity, wrong port,
  missing observation, and residual state.
- The exact public R-2020.12 workaround for STAR#9000762979 on each enabled
  passive sidecar during enumeration flows.
- Focused Task 4, Task 6, Task 8, and Task 9 regressions.

### 2.2 Excluded

- Reading or forcing a private SVT Requester Tag.
- Changing the SVT installation or any Synopsys source file.
- Report catchers, severity downgrades, wildcard checker suppression, or
  suppression of any rule other than the one named in Section 8.
- PIPE, P2P broadcast proof, nested switches, hot plug, or additional topology
  modes.
- Replacing strict pre-registration for repository-owned Task 6 and Task 10
  traffic.

## 3. Route Observer API

### 3.1 Repository-owned event

Add a package-owned `pcie_tl_switch_route_event` after the normalized TLP
types and before `pcie_tl_switch`. It contains no SVT type:

```systemverilog
typedef enum int unsigned {
    PCIE_TL_ROUTE_FORWARD,
    PCIE_TL_ROUTE_LOCAL_RESPONSE,
    PCIE_TL_ROUTE_DROP,
    PCIE_TL_ROUTE_UNSUPPORTED_BROADCAST
} pcie_tl_switch_route_action_e;

class pcie_tl_switch_route_event extends uvm_object;
    longint unsigned event_id;
    pcie_tl_switch_route_action_e action;
    int ingress_port;
    int egress_port;
    int route_code;
    pcie_tl_tlp ingress_tlp;
    pcie_tl_tlp egress_tlp;
endclass
```

`event_id` is monotonically increasing and unique within one switch
instance. `ingress_tlp` is always an event-owned deep clone.
`egress_tlp` is an independent event-owned deep clone for forward, local,
and unsupported-broadcast actions; it is null only for `DROP`. A missing
required clone or clone failure is fatal. Subscribers may inspect the event
but may not modify either TLP.

The action contracts are:

| Action | Ingress | Egress | TLP contract |
| --- | --- | --- | --- |
| `FORWARD` | valid port | distinct valid port | original normalized RX and actual normalized egress |
| `LOCAL_RESPONSE` | valid port | same port | local request and generated Completion |
| `DROP` | valid port | `SWITCH_ROUTE_DROP` | original RX and null egress |
| `UNSUPPORTED_BROADCAST` | valid port | `SWITCH_ROUTE_BCAST` | original RX; enumeration treats it as fatal |

`egress_port` is a valid physical port only for `FORWARD` and
`LOCAL_RESPONSE`. It is the canonical action constant shown above for drop
and unsupported-broadcast actions. `route_code` always records the raw
routing result: it equals the egress port for ordinary forwarding,
`SWITCH_ROUTE_LOCAL` for a local response, and preserves the original
no-route, cross-root, broadcast, or invalid-destination value otherwise.

`route_code` preserves the concrete switch decision, including no-route,
cross-root, invalid destination, local, and ordinary egress decisions. It is
diagnostic for forward/local actions and mandatory for drop actions.

### 3.2 Publication port and timing

`pcie_tl_switch` owns:

```systemverilog
uvm_analysis_port #(pcie_tl_switch_route_event) route_observed_port;
```

The switch publishes exactly one event for every supported unicast routing
decision:

1. The ingress TLP has already been normalized by the port adapter.
2. The destination and any local target have been resolved.
3. Cfg1-to-Cfg0 rewriting or local Completion construction is complete.
4. Non-posted ownership state has been updated as required.
5. The event is published immediately before the corresponding
   `tx_fifo.put()`.

A route drop is published before returning from the drop branch. A returning
Completion publishes a normal `FORWARD` event with the actual Completion
ingress and recorded Request ingress as its egress. A local Configuration
response publishes `LOCAL_RESPONSE` immediately before its same-port
`tx_fifo.put()`.

The broadcast route is outside this feature's proof boundary. The switch emits
one `UNSUPPORTED_BROADCAST` decision before existing broadcast handling; an
enumeration flow fails if it reaches this branch.

The production proxy environment connects exactly one subscriber:

```systemverilog
switch_core.route_observed_port.connect(
    switch_scoreboard.route_event_export);
```

Proxy end-of-elaboration checks require the connection. Standalone switch unit
tests may connect a collecting subscriber. No route event is generated from a
sidecar callback, and the observer never feeds a TLP back into the switch.

## 4. Scoreboard Modes and State

### 4.1 Modes

The scoreboard has two explicit modes:

- `PCIE_SVT_SCOREBOARD_STRICT` is the construction default. Existing
  `expect_forward()` and `expect_local_response()` calls must precede RX.
  Route events are ignored in this mode.
- `PCIE_SVT_SCOREBOARD_DEFERRED_ENUM` consumes route events and permits an
  ingress RX to wait for its routing decision.

Only `begin_deferred_enumeration()` may enter deferred mode. It requires no
existing expectation or pending RX, clears per-phase completed/event-ID
history, and resets dynamic counters. Nested entry is fatal.

`end_deferred_enumeration()` first requires all expectations and pending RX
entries to be empty, then returns to strict mode. Ending strict mode, ending
with residual state, or changing mode while a wire observation is unresolved
is fatal.

### 4.2 Deferred state

The dynamic state is:

```text
pending_rx[]       passive RX observations with no route event yet
expected[]         route-derived expectations, with rx_seen state
completed[]        completed exactly-once transactions for duplicate TX checks
seen_event_id[]    route-event IDs already accepted
dynamic_event_count
dynamic_complete_count
```

Every stored entry contains a full value signature, never a mutable vendor
handle. The signature remains the Task 6 signature:

```text
direction, ingress/egress, Fmt/Type, TC, attributes, length,
Requester ID, Completer ID, full 10-bit Tag, address or BDF/register,
first/last BE, Completion fields, prefixes, payload bytes and digest
```

Payload digest is an acceleration only; equality still compares every payload
DWORD.

## 5. Deferred Correlation State Machine

### 5.1 RX arrives before route event

When passive RX has no matching route-derived expectation:

1. Validate the port and full TLP signature.
2. If the same unresolved signature already exists on that port, fail as an
   ambiguous/duplicate RX.
3. If the signature is waiting on a different ingress, fail as wrong ingress.
4. Otherwise append one `pending_rx` entry.

The RX is not counted as passed and cannot authorize a later TX until a route
event consumes it.

When the route event arrives, it must match exactly one pending RX by ingress
port and the event's original-TLP signature. One match is removed from
`pending_rx` and the resulting expectation is marked `rx_seen`. Zero
matches creates an expectation waiting for RX. More than one match is fatal
ambiguity.

### 5.2 Route event arrives before RX

The event creates one expectation using:

- `ingress_port` plus the original normalized TLP for RX;
- `egress_port` plus the rewritten/generated normalized TLP for TX; and
- the action to distinguish ordinary forwarding from a same-port local
  response.

The later passive RX must match exactly that ingress and original signature.
It marks `rx_seen`. More than one matching expectation, a match on another
port, or a field/payload mismatch is fatal.

The design guarantees only RX/route-event order independence. A passive TX
before its correlated RX remains fatal because it cannot prove that the
observed ingress caused that egress.

### 5.3 TX and completion

A passive TX completes exactly one expectation only when:

- the expectation has `rx_seen=1`;
- the physical egress port is exact;
- every relevant header, prefix, Completion field, and payload byte matches;
  and
- the action permits that port relationship.

The expectation moves to `completed`, and
`dynamic_complete_count` increments. A second matching TX without a live
expectation is fatal duplicate forwarding.

At the deferred-mode exit gate:

```text
pending_rx.size() == 0
expected.size() == 0
dynamic_complete_count == dynamic_event_count
```

Drop and unsupported-broadcast events are fatal before they enter the count of
completable events.

## 6. Required Route Forms

### 6.1 Ordinary Configuration forwarding

For a Configuration Request that traverses a bridge, the ingress event TLP is
the exact Type 1 Request received from the source link. If the target bus is
directly below the selected DSP, the egress event TLP is the actual Type 0
clone. The scoreboard therefore expects Type 1 on ingress and Type 0 on
egress; it does not pretend that a rewrite is transparent.

### 6.2 Local switch Configuration response

For USP or DSP Type-1 configuration space owned by `pcie_tl_switch`, the
event records:

```text
action  = LOCAL_RESPONSE
ingress = egress = requesting physical port
RX      = Configuration Read or Write
TX      = generated Completion or Completion with Data
```

Same-port traffic is legal only for this action. An ordinary `FORWARD` with
identical ingress and egress remains a forwarding-loop fatal.

### 6.3 Completion forwarding

The normalized Completion received through a sidecar/adapter is the event
ingress. The switch's `{Requester ID, Tag}` outstanding entry supplies the
egress port. The egress TLP is the actual object written to that port's FIFO.
Split Completions produce one event and one wire expectation per Completion;
the switch removes outstanding ownership only on the terminal Completion.

### 6.4 Drop

No drop is legal in the approved enumeration flow. `DROP`, cross-root drop,
bad destination, or unsupported broadcast causes an immediate
`SCOREBOARD_ROUTE_DROP`-class fatal containing event ID, route code, ingress,
and the full input signature. The final gate also requires all five adapter
drop counts and the switch drop delta for the enumeration stage to be zero.

## 7. Duplicate, Ambiguity, and Final Errors

The deferred implementation must diagnose these cases separately:

| Condition | Required result |
| --- | --- |
| Reused route `event_id` | fatal duplicate route event |
| Two pending RX entries match one event | fatal ambiguity |
| Two live expectations match one RX or TX | fatal ambiguity |
| Same unresolved RX observed twice | fatal duplicate RX |
| TX repeats a completed expectation | fatal duplicate TX |
| Signature exists on another ingress/egress | fatal wrong port |
| Header matches but payload differs | fatal payload mismatch |
| TX occurs before correlated RX | fatal missing ingress |
| Completion has no route event/ownership | fatal unmatched Completion |
| Route event has null/invalid TLP or port | fatal malformed route event |
| Deferred exit has pending RX | fatal missing route decision |
| Deferred exit has expectation with `rx_seen=0` | fatal missing RX |
| Deferred exit has expectation with `rx_seen=1` | fatal missing TX |

No timeout converts one of these failures into a pass. Existing bounded
sequence and service timeouts remain active.

## 8. STAR#9000762979 Workaround

R-2020.12 documents a false passive Data-Link Flow-Control initialization
check under STAR#9000762979. The official example is:

```text
/home/ubuntu/synopsys/designware_vip_R-2020.12/vip/svt/pcie_svt/
R-2020.12/examples/xlvip/tb_pcie_svt_uvm_xlvip_ea_sys/env/
pcie_device_basic_env.sv
```

The integration applies only the exact public call used there:

```systemverilog
void'(sidecar.agent.err_check.disable_checks(
    "PASSIVE_DL_TX", "FLOW_CTRL_INIT", "txn_06_01_16"));
```

Requirements:

- Apply it only to the five enabled passive sidecar Device Agents in a run
  that contains the official enumeration stage.
- Require non-null public `agent.err_check` handles before the call.
- Apply it during UVM connection/elaboration, before enumeration traffic.
- Emit exactly one marker per port:

  ```text
  SWITCH_STAR_9000762979_APPLIED port=<0..4> rule=PASSIVE_DL_TX/FLOW_CTRL_INIT/txn_06_01_16
  ```

- Emit no marker in Task 8 link-only runs.
- Do not disable `vc_initialization_start_check`, any ECRC/RCB/Completion
  rule, any wildcard category, or any additional STAR workaround.

This is a checker-specific public configuration call, not a report catcher.
All other UVM warnings, errors, and fatals retain their original severity.

## 9. Enumeration Lifetime

The Task 9 virtual sequence performs:

1. Validate switch, scoreboard, registry, adapter, and RC0 sequencer handles.
2. Snapshot switch/adapter drop counters.
3. Call `begin_deferred_enumeration()`.
4. Start the official sequence only on primary RC0.
5. Consume and validate the returned enumeration status.
6. Perform Task 9 bridge/BAR readback and Command-register programming through
   normal Configuration Requests.
7. Wait for switch, adapter, and wire-observation quiescence using the existing
   bounded waits.
8. Call `end_deferred_enumeration()`.
9. Require no drop-counter delta, empty switch outstanding state, and empty
   adapter queues.
10. Emit the existing
    `SWITCH_ENUM_PASS usp=1 dsp=4 ep=4 bars=12` marker.

The deferred lifetime includes the Task 9 post-sequence readbacks because they
also use SVT-assigned Tags. It ends before Task 10 traffic. Task 10 must
explicitly pre-register expectations through the existing strict APIs.

## 10. Regression Matrix

All VCS compilation and simulation runs execute on `10.11.10.53` through
`bash -lic`, with:

```bash
DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
PCIE_SVT_ROOT=$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12
```

Every positive run requires UVM W/E/F=`0/0/0`. Negative runs execute in
separate processes and require the named production fatal without a report
catcher or severity downgrade.

### 10.1 Task 4: switch routing unit

- Collect and validate events for ordinary request routing, Cfg1-to-Cfg0,
  local Configuration Read, local Configuration Write, and Completion return.
- Prove the subscriber observes the event before the target egress FIFO put.
- Require unique monotonically increasing event IDs and deep-cloned event TLPs.
- Exercise a drop event in a dedicated negative/collector case.
- Preserve all existing Type-1, BDF/window, split-Completion, duplicate-NP,
  unknown-Completion, and multi-root routing tests.

### 10.2 Task 6: adapter/scoreboard unit

- Preserve every existing strict pre-registration test unchanged.
- Add deferred positive tests for both RX-first and event-first order.
- Add deferred Cfg1-to-Cfg0, local read, local write, and Completion tests.
- Run independent negative cases for duplicate event ID, duplicate/ambiguous
  RX, wrong ingress, wrong egress, drop, payload mismatch, missing route event,
  missing RX, missing TX, and TX-before-RX.
- Require the deferred final marker to report equal accepted/completed counts
  and zero pending/expected entries.

### 10.3 Task 8: five-link regression

- Re-run Gen4 `+PCIE_LINK_ONLY +PCIE_DISABLE_SWITCH_SIDECARS`: five
  `LINK_PASS`, one disabled marker, no STAR markers.
- Re-run Gen4 `+PCIE_LINK_ONLY`: five `LINK_PASS`, five
  `SWITCH_SIDECAR_READY`, no STAR markers.
- Preserve the existing single-Endpoint x16 Gen4 peer smoke.

### 10.4 Task 9: official enumeration

Run Gen4 `+PCIE_ENUM_ONLY` and require:

- five `LINK_PASS`;
- five `SWITCH_SIDECAR_READY`;
- five exact `SWITCH_STAR_9000762979_APPLIED` markers;
- one deferred-scoreboard empty/pass marker;
- one `SWITCH_ENUM_PASS usp=1 dsp=4 ep=4 bars=12`;
- twelve validated 64-bit Prefetchable BAR apertures;
- no switch or adapter drops;
- no outstanding non-posted Request; and
- no residual pending RX or expectation.

Task 9 is not accepted if enumeration merely returns a non-null status. The
wire scoreboard, registry checks, normal Configuration readback, and final
empty-state gates must all pass.

## 11. Allowed Implementation File Range

The implementation plan may modify or create only these feature-relevant
files in addition to the current Task 9 WIP:

```text
pcie_tl_vip/src/pcie_tl_switch_pkg.sv
pcie_tl_vip/src/switch/pcie_tl_switch_route_event.sv       (new)
pcie_tl_vip/src/switch/pcie_tl_switch.sv
svt_pcie_integration/sim/pcie_tl_switch_proxy_unit_test.sv
svt_pcie_integration/sim/pcie_svt_switch_adapter_unit_test.sv
svt_pcie_integration/uvm/pcie_svt_switch_scoreboard.sv
svt_pcie_integration/uvm/pcie_svt_switch_sidecar_env.sv
svt_pcie_integration/uvm/pcie_svt_env.sv
svt_pcie_integration/uvm/pcie_svt_virtual_sequencer.sv
svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv
svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv
svt_pcie_integration/uvm/pcie_svt_switch_enum_registry.sv
svt_pcie_integration/uvm/sequences/pcie_svt_switch_enumeration_vseq.sv
svt_pcie_integration/sim/pcie_svt_switch_enum_registry_unit_test.sv
```

`pcie_svt.f` needs no change because the new route-event class is included
through `pcie_tl_switch_pkg.sv`, and the modified scoreboard is already
included through `pcie_svt_integration_pkg.sv`.
If implementation proves that a new standalone unit-test top or file-list
entry is essential, the written plan must name it and obtain review before it
is added. No unrelated refactor is authorized.

The existing uncommitted Task 9 registry, sequence, environment, sequencer,
test, and package changes remain owned by Task 9 and must not be discarded or
folded into the design-document commit.

## 12. Acceptance Criteria

This design increment is complete only when:

- final SVT wire Tags are correlated without private vendor access;
- both RX-first and route-event-first order pass;
- local responses, Cfg1-to-Cfg0 forwarding, and returning Completions are
  proven on the correct wires;
- drop, duplicate, ambiguity, wrong port, and every residual-state case fail
  deterministically;
- deferred mode is confined to Task 9 enumeration work;
- Task 6 and Task 10 retain strict pre-registration;
- only the exact STAR#9000762979 rule is disabled on the five enumeration
  sidecars; and
- the Task 4/6/8/9 regression matrix passes with all positive-run
  W/E/F=`0/0/0`.
