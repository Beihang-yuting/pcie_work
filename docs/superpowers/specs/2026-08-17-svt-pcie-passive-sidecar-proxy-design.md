# SVT PCIe Passive-Sidecar Transparent Proxy Feasibility Design

**Date:** 2026-08-17

**Status:** Design approved; written-spec review pending

## 1. Purpose and Scope

This design replaces the failed active-Agent receive boundaries in Task 1 of
the SVT PCIe Switch Proxy work. It defines a feasibility probe that keeps two
complete Gen4 x4 Serial links and four R-2020.12 full active Device Agents,
while adding independent standalone passive monitors to recover the public
raw-TLP observation boundary missing from an active Device Agent.

The Task 1 probe must demonstrate transparent forwarding of:

- one directed Memory Write from a source Root Complex to a sink Endpoint;
- one Type-0 Configuration Read on the same path; and
- the Configuration Completion on the reverse path.

Transparent means that the protocol-significant TLP header fields and payload
cross the Proxy unchanged. In particular, the Proxy must not terminate the
Configuration Read and create a new Driver App transaction. The original
Requester ID and full Tag must remain end-to-end visible.

This design covers only the public-API feasibility gate. It does not implement
enumeration, address routing, Type-1-to-Type-0 conversion, concurrent
transactions, Completion splitting, or the production five-port switch. Task
2 remains blocked until Task 1 passes and its implementation passes separate
specification and code-quality reviews.

This document supersedes the Task 1 architecture in:

- `2026-08-17-svt-pcie-app-callback-proxy-design.md`; and
- `2026-08-15-svt-pcie-switch-proxy-design.md`.

The earlier documents remain as evidence of the rejected receive boundaries.

## 2. Evidence Requiring This Revision

### 2.1 Active TL callback failure

The first probe registered an enabled
`svt_pcie_tl_callback::pre_tlp_out_put` on each actual Proxy TL component.
Callback-pool diagnostics confirmed the registration, both Serial links
reached Gen4 x4, and the active Target path received the directed Memory
Write. The TL receive callback was never called. This disqualifies that
callback as the active Target receive boundary for this R-2020.12 topology.

### 2.2 Active TL monitor absence

The second probe moved request capture to the documented
`svt_pcie_target_app_callback::post_rx_tlp_get` surface and attempted to
observe Completions through `pcie_agent.tl_mon`. Runtime handle diagnostics
showed that `tl_mon` is null in every active Agent. Setting
`pcie_cfg.enable_monitor=1` on an active Agent produces the documented fatal
because `enable_monitor` and `is_active` are mutually exclusive.

R-2020.12 documents `svt_pcie_tl_monitor` for a passive Device Agent configured
with:

```systemverilog
cfg.is_active = 0;
cfg.pcie_cfg.enable_monitor = 1;
```

It exposes separate public `rx_tlp_observed_port` and
`tx_tlp_observed_port` analysis ports. A standalone passive monitor therefore
remains the only documented R-2020.12 raw-TLP observation candidate that can
be added without changing the Synopsys installation or replacing the full
Serial active Agents.

### 2.3 Driver App reconstruction rejection

The public high-level Configuration Read sequence does not expose a Tag
attribute. Reissuing a captured Configuration Read through that sequence
would allocate a new downstream Tag and require a synthetic upstream
Completion. That is a transaction proxy, not the transparent forwarding path
implemented by a real PCIe switch. This design rejects that approach even
though `transaction_ended` can return Completion status, Completer ID, and
payload.

## 3. Hard Constraints

The feasibility probe must:

- retain four full active Device Agents forming two complete Serial/DL/PL/TL
  links;
- retain two physical Gen4 x4 links and wait for L0 on every active endpoint;
- use only declarations and behavior documented in the installed R-2020.12
  HTML and public examples;
- add passive observation through separate standalone SERDES interfaces;
- give every active and passive VIP instance its own interface handle;
- prevent passive instances from driving the observed links;
- capture and suppress Proxy-owned requests through the public Target App
  callback;
- clone every vendor transaction before retaining it outside a callback or
  analysis `write()` call;
- perform no blocking operation and start no sequence from a callback or
  analysis `write()` method;
- reinject raw clones only through the opposite active Proxy's public
  `pcie_agent.tlp_seqr`;
- preserve Requester ID, full Tag, TC, attributes, byte enables, address,
  length, Completion fields, and payload;
- produce no locally generated Proxy Target response;
- use no private vendor state, modified Synopsys source, hierarchical
  `force`, `deposit`, report catcher, or severity downgrade; and
- stop before Task 2 if any Task 1 gate fails.

The active Egress Agent is allowed to process the Completion it receives
normally. It is not allowed to emit an unexpected or spurious Completion
diagnostic. Whether R-2020.12 correctly accounts for a non-posted request
injected through `tlp_seqr` is deliberately treated as a feasibility result,
not assumed by the design.

## 4. Topology

### 4.1 Active data path

The active topology remains:

```text
Source RC  -- Gen4 x4 Serial --  Ingress Proxy EP
Egress Proxy RC  -- Gen4 x4 Serial --  Sink EP
```

All four participants are normal full active Device Agents. The Proxy consists
of the Ingress and Egress active Agents joined by the UVM raw-TLP bridge.

### 4.2 Passive sidecars

One standalone passive Device Agent observes each physical link from the
Proxy device's perspective:

```text
Ingress sidecar:
  RX = Source RC -> Ingress Proxy
  TX = Ingress Proxy -> Source RC

Egress sidecar:
  TX = Egress Proxy -> Sink EP
  RX = Sink EP -> Egress Proxy
```

Each sidecar owns a separate x4 standalone SERDES interface. The HDL tap
copies the existing differential data, transmit clocks, recovered clocks, and
reset information into that interface. No assignment may connect a passive
monitor output back into the active link.

The passive configuration does not call
`set_initial_values_via_unified_vif()`, which the R-2020.12 reference states
is inapplicable to passive monitors. It binds the documented standalone
SERDES interface and sets `is_active=0` and `enable_monitor=1`.

The sidecars are observation-only. Their TL configuration-space mode is
`CFG_SPACE_DISABLED`, a documented monitor mode. This avoids claiming that a
sidecar owns an accurate copy of the monitored Proxy's configuration space.
It may disable passive checks that depend on such a copy, but it does not
disable active-Agent Completion accounting and does not hide reports. The
probe does not claim passive configuration-space protocol checking as a Task
1 result.

## 5. Components and Ownership

### 5.1 Target callback

The Ingress Proxy Target App callback is the only owner allowed to suppress a
forward request. For a supported Memory Write or Type-0 Configuration Read,
`post_rx_tlp_get`:

1. validates all required handles;
2. clones the received TLP;
3. performs a nonblocking enqueue with `mailbox::try_put`;
4. increments the request-capture counter; and
5. sets `drop=1`.

The callback retains neither the vendor-owned object nor a pointer into its
dynamic payload. Unsupported request classes are fatal in Task 1.

The same callback's `pre_tx_tlp_put` acts only as a safety wall. It drops and
counts any response generated by a Proxy Target App. The final gate requires
that count to be zero; a nonzero count proves the request was not cleanly
suppressed and blocks further work.

### 5.2 Sidecar subscribers

Four probe-owned subscriber roles connect to the two passive TL monitors:

| Observation | Task 1 role | May enqueue for forwarding |
| --- | --- | --- |
| Ingress RX | Original request reference | No |
| Egress TX | Forwarded request reference | No |
| Egress RX | Original Completion and reverse-path source | Yes |
| Ingress TX | Returned Completion reference | No |

Every subscriber clones an accepted TLP before storing or enqueuing it. It
filters by both direction and TLP class. A request seen on an observation-only
stream cannot enter the bridge, and a returned Completion seen on Ingress TX
cannot be captured a second time. These rules prevent forwarding loops.

### 5.3 Raw-TLP bridge

The bridge owns separate unbounded request and Completion mailboxes. Its run
threads perform blocking `get` operations outside callbacks, clone the queued
TLP again, create a fresh raw sequence, and start it on the opposite active
Proxy's `tlp_seqr`.

The bridge increments a forwarding counter only after the raw sequence
returns. Enqueue success alone is never reported as forwarding success.

The complete paths are:

```text
Memory Write / Configuration Read:
  Source RC
    -> Ingress Target callback clone and drop
    -> request mailbox
    -> Egress Proxy tlp_seqr
    -> Sink EP

Configuration Completion:
  Sink EP
    -> Egress passive monitor RX clone
    -> Completion mailbox
    -> Ingress Proxy tlp_seqr
    -> Source RC
```

### 5.4 Independent comparison

The forwarding source and the proof of wire transmission have different
owners. The checker compares:

```text
Ingress passive RX request  == Egress passive TX request
Egress passive RX Completion == Ingress passive TX Completion
```

Equality covers protocol-significant TLP header fields and the full payload.
It excludes monitor-local timestamps, object identities, direction metadata,
Data Link sequence numbers, LCRC, and Physical Layer framing, which are
correctly regenerated on a different link.

## 6. Directed Traffic

### 6.1 Memory Write

The source Driver App sends one one-DWORD Memory Write with:

- address `64'h0000_0000_8000_1040`;
- `first_dw_be=4'hf` and `last_dw_be=4'h0`;
- Tag `10'h12a`;
- Requester ID `16'h0000`;
- Traffic Class zero;
- unpoisoned data and untranslated address; and
- payload `32'h4433_2211`.

The Memory Write is posted and must produce no Completion. The ingress and
egress sidecars must observe one matching request, and the sink Target App
must receive exactly one request with every directed field unchanged.

### 6.2 Type-0 Configuration Read

After the Memory Write stage passes, the source sends one Type-0
Configuration Read for the sink Vendor/Device ID DWORD:

- BDF `16'h0000`;
- register number `10'h000`;
- Requester ID `16'h0000`;
- `first_dw_be=4'hf`; and
- Traffic Class zero.

The source high-level sequence allocates the request Tag. The probe learns
the actual complete Tag from the observed/captured TLP and requires that exact
Tag on the Egress TX request and on the returned Completion. The Proxy may not
substitute a new Tag.

The sink returns one successful Completion with one payload DWORD. The Egress
RX Completion and Ingress TX Completion must match in Completion status,
Completer ID, Requester ID, full Tag, byte count, lower address, attributes,
length, and payload. The Source RC Driver App must complete exactly once.

## 7. Staged Feasibility Gates

### 7.1 Stage A: sidecar neutrality

Before forwarding logic is accepted, a minimal build must prove:

- four active Agents and two passive Agents compile and elaborate together;
- each passive Agent has a non-null `pcie_agent.tl_mon`;
- the passive RX and TX analysis ports are connectable;
- both active links still reach Gen4 x4 L0; and
- adding the HDL taps and passive decoders introduces no warning, error, or
  fatal.

Failure to bind or decode a standalone SERDES sidecar ends Task 1. The design
does not fall back to Driver App reconstruction.

### 7.2 Stage B: Memory Write

The exact stage gate requires:

- one Ingress passive RX request observation;
- one Ingress Target request capture;
- one request-mailbox capture;
- one completed Egress raw reinjection;
- one Egress passive TX request observation;
- one sink Target request observation;
- matching Ingress RX and Egress TX request fields;
- zero Completion observations; and
- zero Proxy Target transmissions.

### 7.3 Stage C: Configuration Read and Completion

The exact final gate requires cumulative request counts of two and:

- one Type-0 Configuration Read on both request observation boundaries;
- one Egress passive RX Completion;
- one Completion-mailbox capture;
- one completed Ingress raw reinjection;
- one Ingress passive TX Completion;
- one successful Source Driver App transaction end;
- matching request and Completion comparison pairs;
- zero duplicate request, Completion, or Target response; and
- zero unexpected or spurious Completion reports from any active Agent.

All link, request, and Completion waits are bounded to 100 microseconds. A
timeout prints every callback, observation, capture, reinjection, sink, source,
and Target-transmit counter before reporting failure.

## 8. Reports and Terminal Conditions

Any null handle, clone failure, nonblocking enqueue failure, unsupported TLP,
field mismatch, duplicate, timeout, passive-drive indication, or unexpected
Completion emits exactly one
`TL_PROXY_PASSIVE_SIDECAR_PROBE_BLOCKED` marker before a fatal report.

Task 1 is GREEN only when a fresh clean VCS build and run on `10.11.10.53`
produces all of the following:

- both active Serial links at Gen4 x4 L0;
- every Stage A, B, and C exact-count gate passing;
- `TL_PROXY_PASSIVE_SIDECAR_PROBE_PASS` exactly once;
- `TL_PROXY_PASSIVE_SIDECAR_PROBE_BLOCKED` zero times;
- no unexpected or spurious Completion text; and
- final UVM warning, error, and fatal counts of `0/0/0`.

The clean run must use a new build directory. A reused VCS `Mdir`, stale
binary, or filtered log is not acceptance evidence.

If any gate fails, Task 1 remains blocked. The implementation must not weaken
field checks, reduce the Tag width, disable active Completion accounting,
catch or downgrade a report, claim success from an analysis observation
alone, delete the old Mapper probe, or enter Task 2.

## 9. Instance Count and Performance Evidence

The Task 1 probe contains four active and two passive PCIe components, for six
total UVM PCIe component instances. The passive monitors do not train or drive
links, but they decode Serial, Data Link, and Transaction Layer traffic and
therefore consume simulation time and memory.

The Task 1 evidence must record wall-clock runtime and peak resident memory
for two link-neutrality runs that use the same seed, active configuration,
link-bring-up flow, and fixed post-L0 observation interval:

1. the four-active-Agent baseline without sidecars; and
2. the same workload with both sidecars enabled.

The full Stage B/C traffic run records its runtime and peak resident memory
separately; it is not compared directly with the link-only baseline.

No unmeasured performance threshold is imposed in Task 1. The measured cost
must be reported before scaling the architecture. A complete five-port Proxy
can require up to five additional passive sidecars, one per Proxy port that
must expose received Completions. That scaling decision belongs to the
five-port design after Task 1 is GREEN.

## 10. Delivery Boundary

Implementation proceeds only after this written specification is reviewed.
The implementation order is:

1. standalone passive-sidecar compile/elaboration and link-neutrality probe;
2. Memory Write capture, raw forwarding, and independent observation;
3. Configuration Read forwarding and raw Completion return;
4. fresh clean VCS acceptance run and performance measurement;
5. removal of the superseded Mapper probe only after GREEN;
6. one Task 1 implementation commit; and
7. separate specification-conformance and code-quality reviews.

No enumeration, address routing, multi-port arbitration, Type conversion, or
production integration is part of this implementation cycle.

## 11. Alternatives Rejected

### 11.1 Driver App reconstruction

This approach terminates a captured request, issues a new transaction, and
constructs a new Completion. It changes the downstream Tag and is not a
transparent switch path. It is rejected for Task 1.

### 11.2 Application Agent replacement

R-2020.12 Application Agent mode excludes the PCIe Agent and exposes TLM ports
for a DUT Application interface. It cannot directly replace the two full
active Serial Proxy ports required by this probe.

### 11.3 Modified vendor source or private hooks

Changing the SVT installation, accessing private implementation state, or
forcing internal HDL variables would not establish a portable public-API
integration. These methods remain prohibited.

### 11.4 Immediate use of the real DUT

Placing SVT RC and EP Agents around the actual DUT switch is the most faithful
production path, but it does not provide the requested self-contained
VIP-only feasibility probe. It remains the final integration target rather
than a replacement for Task 1.
