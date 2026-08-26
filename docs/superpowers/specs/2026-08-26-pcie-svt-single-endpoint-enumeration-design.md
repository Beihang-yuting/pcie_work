# SVT PCIe Single-Endpoint Enumeration Design

**Date:** 2026-08-26

**Scope:** Correct the Endpoint Target App mode used by the topology
environment so the R-2020.12 official Endpoint enumeration sequence can run
against an SVT peer without removing future Multi-Endpoint support.

## 1. Problem and R-2020.12 Constraint

The current environment enables
`svt_pcie_configuration::enable_multi_endpoint_mode` for every Endpoint SVT.
That mode belongs to the receive-side Target App. It represents multiple BDFs
with independent Command bits and BARs, but R-2020.12 implements only Command
bits 0 and 1, BAR0 through BAR5, and the Expansion ROM BAR for each BDF.

`svt_pcie_device_virtual_ep_enumeration_sequence` performs full Function
discovery. Its first operations access Vendor/Device ID, Header Type,
Capability Pointer, and the PCI Express Capability. Those registers are not
implemented by the Multi-Endpoint Target App, so the first Configuration
request returns Unsupported Request. Later accesses, including offset `0xb8`,
are consequences of that initial failure rather than an independent
capability-chain defect.

The direct profiles and the first real-Switch profile use one Endpoint SVT per
physical Endpoint link. No current port needs one Target App to represent
multiple BDFs.

## 2. Decision

Endpoint modeling is an explicit per-port policy with two values:

- **Single Endpoint:** Use the standard Target App and a complete PF0
  configuration-space image. This is the mode for all current Endpoint SVTs.
- **Multiple BDFs:** Enable the R-2020.12 Multi-Endpoint Target App and use its
  documented BAR and completer-space service sequences. This is retained as an
  opt-in extension and is not passed to the official full Endpoint enumeration
  sequence.

The policy is copied into each normalized port descriptor. The device
configuration builder derives `enable_multi_endpoint_mode` only from that
descriptor; it does not infer the mode from the number of physical links.
Current profiles and the peer fixture select Single Endpoint. A future custom
topology can select Multiple BDFs independently on the ports that require it.

An attempt to run full official Endpoint enumeration on a Multiple-BDF port
fails before sending a Configuration TLP and reports the link ID and selected
Endpoint model.

## 3. Single-Endpoint Configuration Image

The standard Target App is backed by the SVT configuration database. PF0
contains at least:

- Vendor and Device ID;
- Command and Status;
- Class Code and Revision;
- Header Type;
- BAR0 through BAR5;
- Subsystem Vendor and Device ID;
- Capability Pointer at `0x34` pointing to `0x40`;
- a PCI Express Capability at `0x40` with Endpoint Device/Port Type;
- Device and Link capability/control registers required by R-2020.12 Function
  discovery; and
- a valid end to the standard and extended capability chains.

The image uses the descriptor's link width and maximum generation when
constructing Link Capabilities. Optional capabilities remain disabled unless
a later profile explicitly adds them.

The official sequence is run with `device_parms.is_ep_device_vip == 1`. In
R-2020.12 this tells `configure_bars()` not to write all ones before reading an
SVT Endpoint's BAR sizing value. The configuration image must therefore
preload sizing values rather than zero bases:

| BAR pair | Aperture | Low DWORD sizing value | High DWORD sizing value |
| --- | ---: | ---: | ---: |
| BAR0/1 | 32 MiB | `fe00_000c` | `ffff_ffff` |
| BAR2/3 | 64 KiB | `ffff_000c` | `ffff_ffff` |
| BAR4/5 | 64 KiB | `ffff_000c` | `ffff_ffff` |

The low DWORD values identify 64-bit Prefetchable Memory BARs. After sizing,
the official sequence writes allocated bases through the link. Configuration
readback and the official enumeration status must agree on BAR type, aperture,
and base address.

## 4. Configuration-Stage Flow

The reset and parallel-port barriers remain unchanged.

For every Endpoint, the CFG stage obtains the agent-current configuration,
clones and republishes it, and issues `REFRESH_CFG` while reset is asserted.
Validation checks that the runtime clone's Endpoint model matches the
descriptor.

After all refreshes complete, reset is released while DL and PHY remain
disabled. Each Endpoint then receives its complete PF0 configuration-space
image through `svt_pcie_cfg_database_service` and important DWORDs are read
back.

The mode-specific tail is:

- **Single Endpoint:** Do not start Multi-Endpoint Target App services. BAR
  sizing is already represented by the standard configuration-space image.
- **Multiple BDFs:** Run the documented `SET_BAR_RO_MAP`, `WRITE_ADDR`,
  `READ_ADDR`, `GET_BAR_RO_MAP`, and completer-space-enable sequences for each
  configured BDF.

Stage reporting distinguishes standard configuration-space checks from
Multi-Endpoint BAR service checks. A skipped Multi-Endpoint service is not a
skipped CFG stage.

## 5. Enumeration and Traffic

Direct `EP_X16` and `EP_2X8` profiles run the official Endpoint enumeration
sequence from their primary RC SVTs. The peer Endpoint SVTs use Single Endpoint
mode. Independent root hierarchies may both allocate BDF `01:00.0` because
their BDF and address registries are separate.

For a real Switch DUT, the upstream RC enumerates the Switch bridges and the
four downstream Endpoint SVTs. The Switch DUT owns USP/DSP Type-1
configuration spaces and routing. Each downstream Endpoint SVT owns one PF0
standard configuration space and one set of BARs. No Endpoint Target App
stands in for the Switch hierarchy.

After enumeration, Memory Write and Read traffic uses the allocated BAR
addresses. The standard Target App matches the request address against its
programmed BARs and returns completions from its single BDF. This is the normal
path for the direct peers and the four downstream Endpoint peers.

Multiple-BDF Target App operation remains available for a future test that
deliberately models multiple completers behind one SVT port, but that test must
use a flow compatible with the limited Multi-Endpoint configuration register
set.

## 6. Error Handling

The environment fails explicitly for:

- an unknown Endpoint model;
- disagreement between descriptor mode and runtime SVT configuration;
- a Single-Endpoint image without the PCI Express Capability or a terminated
  capability chain;
- a BAR sizing value inconsistent with its descriptor aperture or attributes;
- a Multi-Endpoint service started for a Single-Endpoint port;
- full official enumeration requested for a Multiple-BDF port; or
- configuration readback, official enumeration status, and registry results
  that disagree.

No warning suppression, severity demotion, source modification, `defparam`, or
forced HDL variable is used.

## 7. Verification

Unit tests cover:

- policy and descriptor copy behavior for both Endpoint models;
- device configuration construction for RC, Single Endpoint, and Multiple
  BDFs;
- the complete Single-Endpoint PF0 capability image;
- exact BAR sizing values for 32 MiB and 64 KiB 64-bit Prefetchable BARs;
- mode-specific CFG initialization service dispatch; and
- early rejection of official enumeration on a Multiple-BDF descriptor.

Remote VCS acceptance on `10.11.10.53` covers:

- the configuration initialization directed test;
- `EP_X16` Gen4 and Gen5 enumeration;
- `EP_2X8` Gen4 and Gen5 parallel enumeration;
- Switch peer link-only behavior with ENUM and TRAFFIC `NOT_RUN`; and
- the existing compile/profile/link regression matrix affected by the policy
  and image changes.

Passing direct enumeration requires exact CFG, LINK, and ENUM `PASS` states,
TRAFFIC `NOT_RUN`, the expected one or two enumeration records, correct BAR
types/apertures/bases, retained Memory Space and Bus Master enables, and final
UVM warning/error/fatal counts of `0/0/0`.

## 8. Out of Scope

This correction does not add ARI, SR-IOV, multiple PFs, full configuration
space support to the R-2020.12 Multi-Endpoint Target App, Switch forwarding,
or post-enumeration Memory traffic. Those remain separate topology extensions
or later implementation tasks.
