# SVT PCIe Switch Proxy Enumeration and Forwarding Design

> Date: 2026-08-15
>
> Status: Approved
>
> Validation host: `ubuntu@10.11.10.53`
>
> Synopsys release: SVT PCIe R-2020.12

## 1. Goal

Add a verification-only Switch Proxy to the existing SVT PCIe integration.
The proxy temporarily replaces the unavailable real controller DUT and proves
one coherent PCIe switch hierarchy through the same Serial boundaries that the
real DUT will later use:

```text
Primary SVT RC x16
        | Serial
        v
Proxy SVT USP ----------------+
                               |
                      SVT/TLP adapters
                               |
                        pcie_tl_switch
                               |
              +--------+-------+--------+
              |        |       |        |
        Proxy DSP0  DSP1    DSP2     DSP3
              |        |       |        | Serial
        Primary EP0 EP1     EP2      EP3
```

The completed environment must:

1. bring up one x16 USP link and four x4 DSP links at Gen4 or Gen5;
2. let primary RC0 use the official SVT switch-enumeration sequence to
   discover one USP, four DSPs, and four downstream SVT Endpoints;
3. program bus numbers and 64-bit Prefetchable windows dynamically through
   normal Configuration Requests;
4. forward downstream RC-to-EP memory traffic and upstream EP-to-RC memory
   traffic through the switch core; and
5. preserve the DUT-facing Serial interface so the proxy can later be
   replaced by the real controller RTL without changing the primary SVT
   environment or test sequences.

## 2. Confirmed Product Boundary

R-2020.12 provides public RC-side switch support, including:

- `svt_pcie_device_virtual_switch_enumeration_sequence`;
- `svt_pcie_switch_enumeration_seq_status`; and
- `svt_pcie_driver_app_mem_request_w_switch_env_enumerated_data_sequence`.

Those classes enumerate and exercise an external switch DUT. The installed
class reference and examples do not provide a drop-in 1-USP/4-DSP SVT switch
DUT with an internal forwarding fabric. Five independent RC/EP peer links also
do not form one switch hierarchy.

The proxy therefore combines full-stack SVT link endpoints with the existing
repository-owned `pcie_tl_switch` routing core. It must not copy, patch, or
force state inside the Synopsys installation.

## 3. Scope

### 3.1 Included

- A verification-only `PCIE_USE_SVT_SWITCH_PROXY` compile mode.
- Five opposing Proxy SVT ports:
  - an upstream-facing x16 port opposite primary RC0; and
  - four downstream-facing x4 ports opposite primary EP0 through EP3.
- Five SVT-to-`pcie_tl_tlp` adapters.
- Type 0/Type 1 Configuration Request routing and Completion return routing.
- Minimal standards-correct Type-1 configuration images for the USP and four
  DSP functions.
- Dynamic bus, subordinate-bus, non-prefetchable-memory, and 64-bit
  Prefetchable-memory windows.
- Four downstream Memory Write/Read checks and four upstream Memory Write
  checks.
- Gen4/Gen5 default and optional fast-training validation.

### 3.2 Deferred

- Endpoint-to-Endpoint P2P.
- Multiple functions or SR-IOV traffic behind a DSP.
- Nested switches.
- Hot plug, surprise removal, AER injection, power management, and reset
  propagation beyond initial link startup.
- PIPE connectivity.
- Performance, fairness, or sustained-bandwidth testing.
- Replacement with the real controller RTL.

## 4. Compile-Time Selection and Static Cost

`PCIE_USE_SVT_SWITCH_PROXY` is legal only with
`PCIE_TOPO_SWITCH_1X16_4X4`. It is mutually exclusive with
`PCIE_USE_SVT_PEER` and with the ordinary DUT placeholder.

Only this build instantiates the five Proxy SVT ports and switch core. The x16
Endpoint, 2x8 Endpoint, placeholder-DUT, and eventual real-DUT builds retain
their existing static agent counts and simulation cost.

## 5. API Feasibility Gate

Implementation starts with an isolated compile-and-run probe. Before the
switch core or topology is changed, the probe must demonstrate all of the
following with the shipped R-2020.12 service/API surface:

1. observe one received TLP on a Proxy SVT port;
2. convert all fields required by a Memory Write;
3. suppress an automatic local Target-App response when the proxy owns the
   request;
4. inject the equivalent transaction through a different Proxy SVT port; and
5. receive the unchanged address, length, byte enables, Tag/Requester ID where
   applicable, and payload at the far SVT peer.

Candidate receive surfaces include the shipped `pciesvc_*_uvm_api` analysis
ports, while egress uses an official SVT driver-transaction sequencer or an
equivalent shipped service API. The probe decides the exact supported surface;
production code must not depend on private class fields, hierarchical
`force`/`deposit`, or modified vendor source.

The probe also proves single-response ownership. A forwarded Configuration or
Memory Read must produce exactly one Completion. If the service surface cannot
observe, suppress, and reinject traffic without private-state access, this
feature is blocked and implementation stops for a design decision. It must not
silently fall back to five independent links or claim forwarding coverage.

## 6. Components

### 6.1 Switch Proxy HDL topology

The existing switch topology keeps the five primary agents:

```text
primary RC0 x16
primary EP0 x4
primary EP1 x4
primary EP2 x4
primary EP3 x4
```

Proxy mode adds five opposing Unified VIP HDL instances and Serial
cross-connects. The proxy USP behaves as the upstream component on the x16
link; each proxy DSP behaves as the downstream component on its x4 link. Each
physical link has a distinct interface ID, reset bit, clock mapping, and
diagnostic port name.

### 6.2 `pcie_svt_switch_port_adapter`

One adapter is created for each Proxy port. It has three responsibilities:

- receive and normalize supported SVT TLPs into `pcie_tl_tlp` objects;
- submit normalized ingress traffic to the matching switch `rx_fifo`; and
- consume the switch `tx_fifo`, convert the object back to an SVT transaction,
  and inject it through that port.

The first phase supports only the packet classes required for enumeration and
approved traffic:

- Configuration Read/Write Type 0 and Type 1;
- Memory Read and Memory Write;
- Completion and Completion with Data.

Conversion preserves Fmt/Type, TC, attributes, length, address, byte enables,
Requester ID, Completer ID, Tag, Completion Status, byte count, lower address,
and payload. An unsupported TLP received during the approved tests is a fatal
adapter error rather than an implicit drop.

### 6.3 `pcie_tl_switch` extensions

The existing switch remains the single routing authority, but its simplified
configuration behavior must be extended for real enumeration:

- replace device-number-to-array-index assumptions with an explicit BDF-to-
  port map;
- implement minimal Type-1 configuration images for one USP and four DSPs;
- report non-`FFFF` Vendor/Device IDs, Bridge class code, Header Type 1, and
  correct PCIe Upstream/Downstream Port type;
- implement Command, Primary/Secondary/Subordinate Bus Number, Memory
  Base/Limit, Prefetchable Memory Base/Limit, and Prefetchable Base/Limit
  Upper-32 registers with byte-enable semantics;
- store Prefetchable windows as 64-bit values;
- route addresses through non-prefetchable or Prefetchable bridge windows;
- convert a forwarded Configuration Request to Type 0 when its target bus is
  directly attached to a DSP, and otherwise retain Type 1; and
- use an outstanding non-posted-request table keyed by Requester ID and Tag to
  return Completions to the exact ingress port.

The switch local responder handles accesses to USP/DSP functions. It does not
consume requests targeting a downstream Endpoint. Proxy SVT Target Apps must
not independently respond to switch-owned Type-1 functions.

### 6.4 Enumeration result registry

A shared registry records the official enumeration result for each discovered
function:

- function kind: USP, DSP, or Endpoint;
- BDF and parent DSP;
- assigned secondary/subordinate buses;
- BAR base, aperture, width, and Prefetchable attribute; and
- programmed bridge window.

Traffic sequences obtain Endpoint addresses from this registry or directly
from `svt_pcie_switch_enumeration_seq_status`. Final Endpoint BDF and BAR
addresses are never hard-coded in the test.

### 6.5 Scoreboard

The proxy scoreboard records a signature at ingress and egress:

```text
direction, ingress, egress, Fmt/Type, Requester ID, Completer ID,
Tag, address, length, byte enables, payload digest
```

It checks exact routing, exactly-once forwarding, Completion matching, and
payload integrity. Endpoint and RC target-memory readback remains the final
data check; the forwarding signature prevents a coincidental target-memory
value from creating a false pass.

## 7. Startup and Link Bring-Up

The run uses this strict stage order:

1. create and validate five primary and five Proxy profiles;
2. initialize Endpoint configuration spaces and switch-port configuration
   images;
3. release all five resets together;
4. enable both ends of all links concurrently;
5. require Link Up and LTSSM L0 at both ends; and
6. check one x16 and four x4 negotiated widths at the selected generation.

No enumeration starts unless all five link pairs pass. Gen4 fast mode still
starts at Gen1 and uses the already approved non-standard Gen1-to-Gen4 policy;
Gen5 fast uses the approved bypass-to-highest-rate policy.

## 8. Dynamic Enumeration

Only primary RC0 starts:

```systemverilog
svt_pcie_device_virtual_switch_enumeration_sequence
```

with:

```systemverilog
switch_parms.root_hierarchy = 0;
switch_parms.enumerate_device_beneath_dsp = 1'b1;
```

The structural expectation is:

```text
upstream bus:  one USP
internal bus:  four DSP functions
DSP0 bus:      EP0
DSP1 bus:      EP1
DSP2 bus:      EP2
DSP3 bus:      EP3
```

The official sequence chooses the final downstream bus numbers and address
assignments. The proxy must accept and route the resulting Configuration
Requests rather than preloading their final values.

For every Endpoint, enumeration must observe the approved three 64-bit
Prefetchable BAR pairs:

| BAR pair | Aperture | Type |
|---|---:|---|
| BAR0/1 | 32 MiB | 64-bit Prefetchable |
| BAR2/3 | 64 KiB | 64-bit Prefetchable |
| BAR4/5 | 64 KiB | 64-bit Prefetchable |

After enumeration, the test reads back the switch bus/window registers and
Endpoint BARs. It then enables Memory Space and Bus Master only on successfully
enumerated functions required by the traffic phase.

## 9. Approved Forwarding Traffic

### 9.1 Downstream RC-to-Endpoint traffic

For each of the four Endpoints, primary RC0 issues a distinct Memory Write and
Memory Read using the enumerated BAR address. Each Endpoint uses a different
offset, Tag, and payload pattern. The read Completion must return the value
written through the same DSP.

### 9.2 Upstream Endpoint-to-RC traffic

The primary RC target-memory application exposes four non-overlapping receive
locations. Each Endpoint issues one distinct upstream Memory Write. An address
that does not match a downstream bridge window routes to the USP. RC target
memory and the scoreboard must both observe the expected source, address, and
payload.

Endpoint-to-Endpoint P2P remains disabled and is not counted as coverage in
this phase.

## 10. Error Handling and Diagnostics

Every wait is bounded. A failure in an earlier stage blocks later stages.

Fatal conditions include:

- missing or duplicate primary/Proxy port registration;
- any link timeout or negotiated speed/width mismatch;
- unsupported or lossy TLP conversion;
- more than one responder for a non-posted request;
- unknown or ambiguous BDF;
- invalid Type-1 bus/window programming;
- a 64-bit Prefetchable BAR outside its programmed bridge window;
- missing, duplicate, or misrouted Completion;
- scoreboard duplicate, drop, wrong egress, or payload mismatch; and
- enumeration or traffic timeout.

Diagnostics include the stage, ingress/egress port, Fmt/Type, Requester and
Completer IDs, Tag, address, length, payload digest, current BDF map, bridge
windows, per-port receive/forward/Completion/drop counts, and all five links'
LTSSM/speed/width status.

## 11. Validation Matrix

All VCS simulation runs execute on `10.11.10.53` under a Bash login shell.

### 11.1 Development gates

1. Service-API single-packet compile/run probe.
2. Five-link Gen4 default bring-up.
3. Five-link Gen5 default bring-up.
4. Dynamic switch enumeration and BAR/window readback.
5. Four downstream Write/Read paths.
6. Four upstream Write paths.
7. Fast-mode full-flow regressions.

### 11.2 Required full-flow runs

| Generation | Fast mode | Required result |
|---|---:|---|
| Gen4 | 0/default | five links, enumeration, eight traffic checks |
| Gen5 | 0/default | five links, enumeration, eight traffic checks |
| Gen4 | 1 | five links, enumeration, eight traffic checks |
| Gen5 | 1 | five links, enumeration, eight traffic checks |

Each run requires:

- exactly five `LINK_PASS` reports;
- one x16 and four x4 links at 16 GT/s or 32 GT/s as selected;
- one USP, four DSPs, and four downstream Endpoints enumerated;
- four downstream Write/Read checks and four upstream Write checks;
- zero unmatched requests or Completions;
- zero unexpected drops; and
- `UVM_WARNING/ERROR/FATAL = 0/0/0`.

The existing x16 Gen4/Gen5 default and fast tests remain regression gates.

## 12. Security and Vendor-Source Rules

- No Synopsys commercial source is copied into the repository.
- No Synopsys installation file is edited.
- No private vendor state is forced, deposited, or accessed through unstable
  hierarchy.
- No host password, GitHub token, license string, or credential-bearing URL is
  committed.
- Repository code may reference only shipped types and API entry points proven
  by the feasibility gate.

## 13. Completion Criteria

This phase is complete only when:

1. the API feasibility probe passes without private-state access;
2. all five Serial links pass at Gen4 and Gen5;
3. the official RC sequence dynamically enumerates one USP, four DSPs, and
   four Endpoints;
4. all Endpoint BARs and bridge Prefetchable windows are correct and
   non-overlapping;
5. all four downstream Write/Read and four upstream Write paths pass;
6. the four default/fast full-flow runs end with zero warnings, errors, and
   fatals;
7. the existing x16 regression remains clean; and
8. the README contains reproducible build, run, and evidence commands.

Passing this phase proves the verification-only Switch Proxy. It does not
prove the unavailable real controller RTL; that claim begins only after the
proxy is replaced by the actual DUT and the same tests pass unchanged.
