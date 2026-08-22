# SVT PCIe Real Switch DUT Environment Design

**Date:** 2026-08-21

**Status:** Approved

**Validation host:** `ubuntu@10.11.10.53`

**Synopsys release:** SVT PCIe R-2020.12

## 1. Purpose

Add the production-facing verification path for a real PCIe Switch DUT with
one x16 Upstream Port and four x4 Downstream Ports. The environment owns five
active SVT Device Agents:

```text
SVT RC0 x16  <->  real Switch DUT USP
SVT EP0 x4   <->  real Switch DUT DSP0
SVT EP1 x4   <->  real Switch DUT DSP1
SVT EP2 x4   <->  real Switch DUT DSP2
SVT EP3 x4   <->  real Switch DUT DSP3
```

The implementation must be useful before the real DUT is available. With the
idle DUT placeholder, it must compile, elaborate, create all five VIPs, and
initialize all five VIP configuration spaces. Once the real DUT adapter is
provided, the same environment must continue through five-link training,
official Switch enumeration, BAR validation, and bidirectional Memory Write /
Memory Read traffic without replacing the UVM topology or sequences.

This is distinct from the SVT Switch Proxy path. An early Proxy experiment
nested passive sidecars inside `svt_pcie_device_agent`; R-2020.12 wrapper
construction overwrote the intended passive-USP role. The implemented
standalone direct passive `svt_pcie_agent` sidecars avoid that wrapper-role
failure, so the current all-SVT Proxy remains supported and tested as a
pre-DUT/reference model. A real Switch DUT already implements the USP, DSPs,
routing, and bridge configuration spaces, so its production path owns only
the five external active VIPs and does not depend on the Proxy model.

## 2. Selected Approach

The selected approach is a stable HDL wrapper plus a dedicated real-Switch
test and sequence stack.

Two alternatives were rejected:

- Instantiating the final DUT directly in `pcie_svt_topology_top` would couple
  the common VIP top to vendor-specific clocks, resets, parameters, and port
  names. Every DUT integration change would then disturb the proven VIP
  wiring.
- Continuing to use the all-SVT Switch Proxy as the production environment
  would validate the Proxy model rather than the real Switch DUT. The Proxy
  remains a supported pre-DUT/reference environment, but it is not the
  production real-DUT dependency.

The stable wrapper keeps the five Serial lane bundles and reset contract fixed.
Only a small user-owned adapter below that wrapper knows the eventual DUT
module and its native pins.

## 3. Scope

### 3.1 Included

- One active SVT RC x16 on the DUT USP and four independent active SVT EP x4
  agents on the DUT DSPs.
- Run-time Gen4 or Gen5 selection through the existing required
  `+PCIE_GEN=4|5` argument.
- Existing optional run-wide fast-link policy through
  `+PCIE_FAST_LINK_TRAIN=0|1`.
- Serial PHY connection in this implementation.
- A stable real-DUT adapter contract selected by
  `PCIE_USE_REAL_SWITCH_DUT`.
- Five explicit run stages: compile/elaboration, VIP configuration-space
  initialization, link, enumeration, and traffic.
- Official `svt_pcie_device_virtual_switch_enumeration_sequence` execution
  from RC0.
- Validation of exactly one USP, four DSPs, four Endpoint functions, and
  twelve 64-bit Prefetchable BAR apertures.
- RC-to-each-EP and each-EP-to-RC MWr followed by blocking MRd/readback.
- Deterministic traffic addresses and payloads, completion checking, timeout
  checking, and final idle checking.
- Documentation and commands for placeholder and real-DUT builds.

### 3.2 Excluded

- Implementing or modifying the real Switch RTL.
- EP-to-EP peer-to-peer traffic.
- Requiring an SVT agent inside the DUT or representing a Switch port with a
  passive SVT Device Agent.
- Modifying the read-only Synopsys installation or relying on private vendor
  fields.
- Implementing PIPE in this change. The HDL connection boundary and all UVM
  behavior remain transport-independent so a PIPE adapter can be added later.
- Claiming that link, enumeration, or traffic passes before a real DUT is
  connected.

## 4. HDL Integration Boundary

### 4.1 Stable wrapper

Add `pcie_switch_dut_wrapper`. The common topology always instantiates this
wrapper in the non-Proxy Switch branch. Its contract contains:

- `reset_asserted[4:0]`, with index 0 for the USP link and indices 1 through 4
  for DSP0 through DSP3;
- one x16 differential Serial receive/transmit bundle for the USP; and
- four independent x4 differential Serial receive/transmit bundles for the
  DSPs.

Signal names are from the DUT point of view: each `*_rx_[pn]` input carries
VIP transmitted data into the DUT, and each `*_tx_[pn]` output carries DUT
transmitted data into the VIP. This matches the existing
`pcie_svt_serial_port_if` mapping.

Without `PCIE_USE_REAL_SWITCH_DUT`, the wrapper instantiates the existing idle
`pcie_dut_placeholder`. The placeholder drives legal idle differential values
but cannot train a link.

With `PCIE_USE_REAL_SWITCH_DUT`, the wrapper instantiates a user-supplied module
named `pcie_real_switch_dut_adapter` with the same reset and Serial port list.
That adapter converts reset polarity, supplies DUT reference clocks and other
native controls, applies DUT parameters, and maps the stable lane bundles to
the actual Switch RTL. The adapter source is added to the VCS invocation by
the user; it is not embedded in the reusable environment.

The topology checks reject `PCIE_USE_REAL_SWITCH_DUT` unless
`PCIE_TOPO_SWITCH_1X16_4X4` is selected, and reject combinations with
`PCIE_USE_SVT_SWITCH_PROXY` or `PCIE_USE_SVT_PEER`.

### 4.2 Future PIPE boundary

The profile, configuration-space, link, enumeration, registry, traffic, and
test layers do not access Serial signals. Only the topology/wrapper layer does.
A later PIPE implementation can therefore add a sibling transport adapter and
select it at compile time while preserving all five UVM agents, profiles,
virtual sequences, run modes, and acceptance checks.

## 5. VIP Configuration

The existing Switch profile is the source of truth:

| VIP | Role | Width | Hierarchy | Function template |
| --- | --- | ---: | ---: | --- |
| RC0 | RC | x16 | 0 | Root/host requester and completer |
| EP0 | EP | x4 | 0 | Vendor `20f9`, device `5011` |
| EP1 | EP | x4 | 0 | Vendor `20f9`, device `5012` |
| EP2 | EP | x4 | 0 | Vendor `20f9`, device `5013` |
| EP3 | EP | x4 | 0 | Vendor `20f9`, device `5014` |

Each Endpoint PF0 keeps the approved BAR template:

| BAR pair | Aperture | Type | Prefetchable | Low RO map | High RO map |
| --- | ---: | --- | --- | --- | --- |
| BAR0/1 | 32 MiB | 64-bit Memory | yes | `01ff_ffff` | `0000_0000` |
| BAR2/3 | 64 KiB | 64-bit Memory | yes | `0000_ffff` | `0000_0000` |
| BAR4/5 | 64 KiB | 64-bit Memory | yes | `0000_ffff` | `0000_0000` |

Before link enable, `pcie_svt_all_cfg_spaces_init_vseq` configures all five
active primary agents. RC0 records one intentional Target App BAR skip. Each
Endpoint enables Multi-Endpoint Mode, refreshes the configuration while the
link is down, programs all six BAR DWORDs and their RO maps through the
official Target App service sequences, and reads them back. The Switch
configuration-only gate is therefore:

```text
24 MULTI_EP_BAR_CHECK
1  MULTI_EP_BAR_SKIP
5  CFG_INIT_DONE
UVM_WARNING/UVM_ERROR/UVM_FATAL = 0/0/0
```

The RC Memory Target application also receives a deterministic 64 KiB host
memory range at `0000_0002_0000_0000` through a dedicated
`pcie_svt_rc_host_memory_init_vseq`, which starts
`svt_pcie_mem_target_service_mem_range_sequence::ADD_MEM_RANGE` on RC0's
`mem_target_seqr`. Four disjoint 4 KiB subranges are reserved for upstream EP
traffic. The real-Switch test runs this sequence beside the existing
configuration-space initializer in every mode except compile-only. This setup
is harmless in configuration-only mode and removes any test-time dependence
on a DUT BAR for EP-to-RC traffic.

## 6. Dedicated Real-Switch Test and Run Modes

Add `pcie_svt_real_switch_test`, derived from `pcie_svt_base_test`. It uses the
same `pcie_svt_env`, five profiles, virtual sequencer, reset handling, and
Gen/fast-link parsing. It does not create Proxy ports, sidecars, adapters,
callbacks, or the transaction-level Switch model.

Exactly one of these bare mode arguments is required:

| Argument | Work performed | Allowed with idle placeholder |
| --- | --- | --- |
| `+PCIE_COMPILE_ONLY` | Build/elaboration and five-handle checks | yes |
| `+PCIE_CFG_INIT_ONLY` | Configuration-space and host-memory initialization | yes |
| `+PCIE_LINK_ONLY` | Configuration initialization, then five-link bring-up | no |
| `+PCIE_ENUM_ONLY` | Configuration, link, then official enumeration/BAR checks | no |
| `+PCIE_TRAFFIC` | Configuration, link, enumeration, then bidirectional traffic | no |

Duplicate, valued, absent, or conflicting mode arguments are fatal. Link,
enumeration, and traffic modes are also fatal at build time unless
`PCIE_USE_REAL_SWITCH_DUT` was compiled. This prevents an idle placeholder run
from spending milliseconds waiting for impossible link training.

The existing base and Proxy tests retain their current behavior. The new test
is the only owner of the real-Switch staged flow.

## 7. Five-Link Bring-Up

Add a real-DUT link virtual sequence that operates only on the five primary
VIP handles. It never expects paired SVT peer indices.

The sequence validates all five profile, configuration, agent, sequencer, and
status handles; starts the existing public DL link-enable service on all five
ports concurrently; and waits for all ports concurrently. A port passes only
when all of these conditions are true before its deadline:

- Physical `link_up` is asserted;
- LTSSM state is `L0`;
- Data Link `dl_link_up` is asserted;
- current speed is 16 GT/s for Gen4 or 32 GT/s for Gen5; and
- negotiated width is x16 for RC0 or x4 for the corresponding Endpoint.

Each link emits one `REAL_SWITCH_LINK_PASS` record. The stage emits
`REAL_SWITCH_ALL_LINKS_PASS count=5` only after every worker has completed.
Timeouts report the port name, current LTSSM state, speed, width, PL-up, and
DL-up values. The implementation does not require internal DUT LTSSM handles;
the five external VIP observations are the acceptance boundary.

## 8. Official Switch Enumeration and BAR Validation

The current Proxy enumeration sequence contains two responsibilities: the
official SVT enumeration/BAR flow and Proxy-specific quiescence/drop checks.
Split the common flow into a reusable base virtual sequence with protected
pre/post hooks:

1. wait for RC0 DL-up;
2. create and randomize
   `svt_pcie_device_virtual_switch_enumeration_sequence`;
3. start it on RC0's `svt_pcie_device_virtual_sequencer`; the official
   sequence owns its internal Driver App accesses;
4. load its `switch_enumeration_status` into
   `pcie_svt_switch_enum_registry`;
5. read back USP/DSP bus windows and all Endpoint BARs;
6. require one USP, four DSPs, four EPs, and twelve BAR apertures;
7. require `primary < secondary <= subordinate` for the USP and every DSP,
   each DSP Primary Bus to equal the USP Secondary Bus, every DSP bus range
   to be downstream of and contained by the USP range, and sibling DSP
   inclusive bus ranges not to overlap;
8. require every DSP Prefetchable window to be contained by the USP window
   and sibling DSP inclusive Prefetchable windows not to overlap;
9. require every BAR to have the approved size, 64-bit type, Prefetchable
   attribute, unique non-overlapping address range, and containment in its
   parent DSP Prefetchable window; and
10. expose the configuration read/write helpers as protected virtual test
   seams, with `write_config` accepting
   `bit [3:0] first_dw_be = 4'hf`. Enabling Memory Space and Bus Master reads
   offset `0x004`, preserves every non-target Command bit, sets Command bits
   `[2:1]`, and writes that DWORD with `first_dw_be=4'b0011` so only the two
   Command bytes are enabled. The two Status bytes are never enabled for the
   write, preserving any W1C Status bits returned by the read. The flow then
   reads offset `0x004` back and requires both target Command bits to be
   retained.

The existing Proxy subclass retains its sidecar, Switch model, adapter,
scoreboard, drop-count, and quiescence hooks. The real-DUT subclass uses no-op
hooks and depends only on RC0 plus the shared registry. It emits:

```text
REAL_SWITCH_ENUM_PASS usp=1 dsp=4 ep=4 bars=12
```

No BDF or Endpoint BAR base is hard-coded outside the official enumeration
controls; later traffic consumes the validated registry.

## 9. Bidirectional Traffic

### 9.1 Public API and sequencing

Use the R-2020.12 public
`svt_pcie_driver_app_transaction_base_sequence` boundary and send explicit
`svt_pcie_driver_app_transaction` objects on each active Device Agent's
`driver_transaction_seqr[0]`. This API exposes deterministic `address`,
`length`, byte enables, `requester_id`, `payload`, blocking behavior,
returned `completion_status`, and read `payload`.

Eight workers start together:

- four RC0-to-EP workers, one per enumerated EP; and
- four EP-to-RC workers, one on each independent EP sequencer.

RC0 workers share one sequencer and are arbitrated by UVM, while upstream EP
workers can overlap on the four physical links. Every worker performs a
posted MWr followed by a blocking MRd to the same address. The MRd is the
ordering and data-integrity gate for the preceding write.

### 9.2 Address and data plan

For RC0-to-EP traffic, worker `i` uses Endpoint `i` BAR0/1 base from the
validated registry plus `0x100 + i*0x40`. For EP-to-RC traffic, worker `i`
uses host-memory base `0000_0002_0000_0000 + i*0x1000 + 0x100`. Each transfer
is four DWORDs with full first/last byte enables and remains within its
validated aperture.

The four-DWORD payload encodes direction, Endpoint index, and DWORD index:

```text
downstream: d000_0000 | (ep_index << 12) | dword_index
upstream:   e000_0000 | (ep_index << 12) | dword_index
```

RC0 uses Requester ID `00:00.0`. Each Endpoint VIP uses the BDF of the
Endpoint record whose `dsp_index` matches that VIP's DSP number. Every MRd must return
`SUCCESSFUL`, exactly four DWORDs, and an exact payload match.

### 9.3 Completion and idle gates

The traffic parent has one bounded deadline. At timeout it reports which of
the eight workers did not finish and the last completion status observed.
After all readbacks pass, the flow runs the public Driver App and Target App
wait-until-idle service sequences for all applicable agents and requires no
outstanding response owned by a worker. It then emits exactly eight
`REAL_SWITCH_TRAFFIC_FLOW_PASS` records and:

```text
REAL_SWITCH_TRAFFIC_PASS downstream=4 upstream=4 dwords_per_read=4
```

Completion failure, malformed read payload, data mismatch, address outside a
registry aperture, missing sequencer, timeout, or non-idle final state is
fatal. EP-to-EP P2P is not generated.

## 10. Error Handling and Ownership

- Every run checks for exactly five primary active ports and zero peer/Proxy
  ports.
- A missing profile, configuration, status, driver sequencer, target
  sequencer, or memory-target sequencer is fatal before its stage starts.
- Stage success records are emitted only after all child operations and final
  checks finish; external log gating also requires normal process exit and
  final Warnings/Errors/Fatals of `0/0/0`.
- The real-DUT test never references `switch_core`, `switch_adapter`, passive
  sidecars, or the Proxy scoreboard.
- The environment does not mask DUT/VIP errors and introduces no new report
  catcher or checker suppression.
- The Synopsys installation remains read-only.

## 11. Validation Strategy

All VCS compile and simulation validation runs serially on
`10.11.10.53` through a bash login shell.

Before a real DUT is available, required acceptance is:

1. focused unit tests for strict mode selection, real-link handle/status
   gating, enumeration registry validation, traffic address/data planning,
   and all negative cases. Registry negatives explicitly cover USP/DSP bus
   ordering, DSP Primary Bus mismatch, DSP containment outside the USP bus
   range, sibling DSP bus-range overlap, DSP Prefetchable-window containment,
   and sibling DSP Prefetchable-window overlap;
2. a focused enumeration-Command probe that begins with nonzero, W1C-like
   Status bits in the upper half of offset `0x004` plus non-target Command bits
   `0`, `8`, and `10`, captures the configuration write, and requires the exact
   RMW DWORD with those bits preserved, offset `0x004`,
   `first_dw_be=4'b0011`, target bits `[2:1]` set, and both Status-byte enables
   clear;
3. VCS compile/elaboration of the Switch image without
   `PCIE_USE_REAL_SWITCH_DUT`;
4. placeholder `+PCIE_COMPILE_ONLY` with five active primary VIPs and final
   counts `0/0/0`;
5. placeholder `+PCIE_CFG_INIT_ONLY` for Gen4 and Gen5 with the exact 24 BAR
   checks, one RC skip, five completed ports, host-memory range setup, and
   final counts `0/0/0`;
6. proof that placeholder link/enum/traffic modes fail immediately with the
   intended run-mode fatal instead of timing out;
7. the existing focused regression matrix, including EP x16, two EP x8,
   Switch configuration initialization, Proxy unit tests, and registry/BAR
   tests; and
8. `git diff --check`, credential scan, generated-artifact scan, and no
   modification beneath the Synopsys installation.

After the real DUT adapter is supplied, the additional acceptance matrix is
Gen4 and Gen5 for link, enum, and traffic modes. Each traffic run must prove
five links, `1/4/4/12` enumeration, all BAR checks, eight bidirectional flows,
normal completion, final idle, and Warnings/Errors/Fatals `0/0/0`. Fast-link
training is a separate optional matrix and is accepted only when the DUT
supports the same direct rate transition.

## 12. Delivery and Commit Policy

This design and its implementation stay in the existing Task 9 worktree and
remain uncommitted while validation is in progress. They will be included in
the single final Task 9 commit requested by the user; the design document is
not committed separately.
