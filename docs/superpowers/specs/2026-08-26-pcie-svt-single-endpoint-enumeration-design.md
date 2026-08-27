# SVT PCIe Single-Endpoint Enumeration Design

**Date:** 2026-08-26

**Revised:** 2026-08-27
**Status:** Approved approach; written specification awaiting review

**Scope:** Make the R-2020.12 standard Endpoint Target App respond to real
PCIe BAR sizing probes during official Endpoint enumeration, without enabling
Multi-Endpoint Mode or intercepting normal Configuration and Memory traffic.

## 1. Problem and Observed Behavior

The topology environment now selects an explicit Endpoint model per physical
port. Current direct profiles use one Single-Endpoint SVT peer per link, while
the Multiple-BDF model remains an opt-in extension.

The Single-Endpoint PF0 configuration image is sufficient for Vendor/Device
discovery and capability traversal, but it does not define a programmable BAR
aperture in the active HDL Target App. A configuration-database write and
readback proves only that the database contains the requested value. It does
not make the standard Target App return that aperture when software performs
the PCIe sizing algorithm.

The current wrapper also sets both copies of `is_ep_device_vip` to one:

- `device_parms.is_ep_device_vip`; and
- `ep_enumeration_status.is_ep_device_vip`.

R-2020.12 then skips the write-all-ones sizing probe and consumes the Target
App's default BAR data. The observed Gen4 x16 run links successfully, but the
official sequence reports BAR0/1 as 256 MiB, treats BAR2 through BAR5 as
unavailable, and ends with one fatal.

The documented `SET_BAR_RO_MAP` and `GET_BAR_RO_MAP` Target App services do not
solve this Single-Endpoint case. They are available only when
`enable_multi_endpoint_mode == 1`, and that mode lacks the complete standard
configuration register behavior needed by full official Endpoint
enumeration.

## 2. Decision

Single-Endpoint enumeration uses DUT semantics even when the physical peer is
another SVT instance:

1. Keep `enable_multi_endpoint_mode == 0`.
2. Load a complete PF0 configuration image with ordinary initial BAR values.
3. Register one active Target App BAR-sizing callback on each enabled
   Single-Endpoint port.
4. Run the official enumeration sequence with both copies of
   `is_ep_device_vip == 0`, so it writes all ones, reads the sizing mask, and
   assigns an address.
5. Let the callback alter only the BAR sizing response and the fixed type and
   Prefetchable bits of a low-DWORD BAR write.

This keeps BAR discovery on the same transaction path used for a real DUT.
The callback supplies only the behavior that the R-2020.12 standard Target
App cannot derive from the descriptor's aperture.

Multiple-BDF ports keep their existing documented Target App service flow.
They do not receive the callback and are not passed to the full official
Endpoint enumeration sequence.

## 3. Components and Ownership

### 3.1 Topology BAR-sizing callback

A topology-specific class extends `svt_pcie_target_app_callback`. It is
configured directly from one `pcie_svt_port_descriptor`, avoiding a dependency
on the retired profile-based integration package.

For BAR0 through BAR5 it stores:

- whether the DWORD belongs to an implemented BAR;
- whether it is the low DWORD of a BAR;
- the fixed low-DWORD attribute bits;
- the raw PCIe-order sizing response; and
- transient state for an outstanding sizing probe.

The class exposes counters and an idle check for focused tests and end-of-test
diagnostics. It never owns or substitutes the Target App.

### 3.2 Environment registration

`pcie_svt_topology_env` owns an array of callback handles so every callback
remains alive for the lifetime of its agent. For each descriptor whose role is
`PCIE_SVT_ROLE_EP` and model is `PCIE_SVT_EP_SINGLE`, the environment creates
and configures exactly one callback and registers it during `connect_phase`
on:

```systemverilog
uvm_callbacks#(
  svt_pcie_target_app,
  svt_pcie_target_app_callback
)::add(port_agent[i].target[0], callback_by_port[i]);
```

Registration fails explicitly if the selected Endpoint has no `target[0]`.
RC ports and Multiple-BDF Endpoint ports have no sizing callback. This rule is
per descriptor, so one topology may later mix Endpoint models without global
state.

### 3.3 Enumeration wrapper

The direct enumeration wrapper retains responsibility for sequence creation,
address windows, timeout handling, registry publication, and readback checks.
For a Single-Endpoint peer it fixes both the randomized parameter and the
R-2020.12 status copy to zero. The property is not derived from the fact that
the peer happens to be VIP, because the required behavior is DUT-style BAR
probing.

## 4. BAR Transaction Flow

The callback recognizes only one-DWORD, full-byte-enable, Type-0 PF0
Configuration requests to offsets `0x10` through `0x24`.

For each BAR DWORD, the normal sizing flow is:

1. A Configuration Write of `ffff_ffff` arms that BAR DWORD. The request is
   not dropped and continues into the Target App.
2. The following Configuration Read of the same armed DWORD records a mapping
   from `{requester_id, tag}` to the BAR number. The request is not dropped.
3. The successful one-DWORD Completion with Data matching that requester and
   tag has only its payload replaced with the descriptor-derived sizing mask.
4. The mapping is removed, leaving no state after the Completion.

Completion correlation uses requester ID and tag rather than callback order,
so multiple BAR reads may complete out of order. Payload conversion follows
the byte ordering used by SVT callback TLP objects.

An ordinary BAR allocation write cancels any armed sizing state for that
DWORD. For a low DWORD, the callback restores bits `[3:0]` to the descriptor's
I/O/Memory type, 32/64-bit type, and Prefetchable attributes before the Target
App consumes the write. Upper DWORDs are not given low-DWORD attributes.

The callback does not drop a request or Completion. It does not modify:

- ordinary BAR read Completions;
- non-BAR Configuration requests;
- requests to another function;
- Memory Read or Memory Write TLPs; or
- any transaction that does not belong to a recognized sizing probe.

Consequently, post-enumeration Memory traffic continues through the standard
Target App and its programmed BAR address path.

## 5. Exact BAR Contract

All current profiles define three 64-bit Prefetchable Memory BARs:

| BAR pair | Aperture | Low DWORD sizing response | High DWORD sizing response | Low attributes |
| --- | ---: | ---: | ---: | ---: |
| BAR0/1 | 32 MiB | `fe00_000c` | `ffff_ffff` | `0xC` |
| BAR2/3 | 64 KiB | `ffff_000c` | `ffff_ffff` | `0xC` |
| BAR4/5 | 64 KiB | `ffff_000c` | `ffff_ffff` | `0xC` |

The PF0 configuration image contains the configured initial base plus fixed
attributes, not the sizing masks above. Aperture is expressed dynamically by
the callback only while a write-all-ones probe is in progress. After the
official sequence assigns bases, link-side Configuration readback must match
the sequence's recorded ranges and must retain bit 3 (Prefetchable) and bits
`[2:1] == 2'b10` (64-bit Memory BAR).

## 6. Configuration and Enumeration Stages

Reset, refresh, and parallel-port barriers remain unchanged.

During CFG initialization, every Single-Endpoint port receives the complete
PF0 image through `svt_pcie_cfg_database_service`; selected DWORDs are read
back to validate the database handoff. No Multi-Endpoint Target App BAR
service is started for that port. Multiple-BDF ports retain their existing
`SET_BAR_RO_MAP`, `WRITE_ADDR`, `READ_ADDR`, `GET_BAR_RO_MAP`, and
completer-space-enable sequence flow.

After LINK is `PASS`, each direct RC starts the official Endpoint enumeration
sequence concurrently with other independent RC hierarchies. The official
sequence performs the real PCIe BAR algorithm across the serial link:

```text
write ffff_ffff -> read sizing mask -> calculate aperture
-> allocate aligned base -> write base -> enable Memory Space/Bus Master
```

The wrapper then validates all three BAR pairs, Configuration readback,
Command bits, and the enumeration registry before marking ENUM `PASS`.

For a real Switch DUT, the same callback is attached only to downstream
Single-Endpoint SVT peers. The real DUT continues to own USP/DSP Type-1
configuration spaces, bus-number routing, enumeration forwarding, and Memory
TLP forwarding. No Endpoint callback emulates Switch behavior.

## 7. Error Handling

The environment or callback fails explicitly for:

- a null descriptor, non-Endpoint descriptor, or Multiple-BDF descriptor
  supplied to the Single-Endpoint callback;
- an invalid aperture, illegal 64-bit BAR pairing, or missing Target App;
- more than one callback registration for the same Single-Endpoint port;
- a duplicate outstanding `{requester_id, tag}` sizing read;
- a matching sizing Completion with the wrong type, status, length, or
  payload shape;
- a callback that is not idle at the end of the test;
- a Single-Endpoint official enumeration launched with either
  `is_ep_device_vip` copy set to one; or
- BAR type, aperture, assigned base, Command readback, and official status
  that disagree.

No warning suppression, severity demotion, Synopsys source modification,
`defparam`, or forced HDL variable is used.

## 8. Verification

Implementation follows focused test-first steps.

Unit tests prove:

- exact sizing payloads for 32 MiB and 64 KiB 64-bit Prefetchable BARs;
- reversed Completion order still maps every response to the correct BAR;
- ordinary Configuration and Memory traffic is not modified or dropped;
- assigned low-DWORD writes retain fixed attributes;
- invalid descriptors and malformed matching Completions fail explicitly;
- the callback returns to idle with balanced sizing counters; and
- environment registration occurs exactly once for Single-Endpoint ports and
  never for RC or Multiple-BDF ports.

Enumeration-wrapper tests prove that Single Endpoint uses DUT semantics and
that Multiple-BDF mode is rejected before a full official enumeration starts.

Remote VCS acceptance on `10.11.10.53` proceeds in this order:

1. topology callback unit test with `W/E/F=0/0/0`;
2. environment registration/model-selection test with `W/E/F=0/0/0`;
3. enumeration registry unit test with `W/E/F=0/0/0`;
4. `EP_X16`, Gen4 x16 serial link and enumeration; and
5. `EP_2X8`, two independent Gen4 x8 serial links and enumerations.

The immediate x16 acceptance result is:

```text
1 PCIE_SVT_LINK_PASS, Gen4 x16
1 PCIE_SVT_ENUM_PASS, bars=3
CFG/LINK/ENUM=PASS
W/E/F=0/0/0
```

Gen5 and the broader compile/profile/link regression follow after these
focused checks pass. The real-Switch profile remains link-only until a real
Switch DUT is available; the environment retains the downstream Endpoint
callback, enumeration, registry, and future traffic hooks for that DUT.

## 9. Out of Scope

This correction does not add ARI, SR-IOV, multiple PFs, full configuration
space support to the R-2020.12 Multi-Endpoint Target App, Switch forwarding,
or the post-enumeration Memory traffic sequence itself. It preserves the
normal Target App path needed by those later traffic tests.
