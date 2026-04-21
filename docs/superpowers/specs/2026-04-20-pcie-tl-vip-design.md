# PCIe Transaction Layer UVM VIP Design Spec

**Date:** 2026-04-20
**Status:** Approved
**Scope:** Transaction Layer only, other layers handled by commercial VIP

---

## 1. Overview

A UVM-based PCIe Transaction Layer VIP component that supports both Root Complex (RC) and Endpoint (EP) roles. The VIP covers complete TLP type support, full error injection capability, precise flow control modeling, bandwidth shaping, programmable ordering violation, and dual-mode interface adaptation (TLM / SV Interface).

### 1.1 Design Principles

- RC and EP are independent agents inheriting from a common base class
- Shared logic (codec, FC, Tag, ordering, config space, bandwidth shaper) extracted into reusable utility components
- All error injection capabilities controlled via configuration switches, disabled by default
- Interface layer supports TLM / SV Interface runtime switching via adapter pattern
- Coverage collection disabled by default, with per-group enable switches

---

## 2. Architecture

```
pcie_tl_env
├── rc_agent (driver, monitor, sequencer)
├── ep_agent (driver, monitor, sequencer)
├── virtual_sequencer
├── shared_utils
│   ├── tlp_codec
│   ├── fc_manager (on/off switch)
│   ├── tag_manager
│   ├── ordering_engine
│   ├── cfg_space_manager
│   └── bandwidth_shaper
├── scoreboard
├── coverage_collector
└── interface_adapter (TLM / SV IF switchable)
```

---

## 3. TLP Transaction Data Model

### 3.1 Base Class

```systemverilog
class pcie_tl_tlp extends uvm_sequence_item;
    rand tlp_fmt_e       fmt;
    rand tlp_type_e      type_e;
    rand bit [2:0]       tc;
    rand bit             th;
    rand bit             td;
    rand bit             ep;
    rand bit [1:0]       attr;       // RO, IDO
    rand bit [9:0]       length;
    rand bit [15:0]      requester_id;
    rand bit [9:0]       tag;        // 10-bit Extended Tag
    rand bit [7:0]       payload[];

    // Error injection metadata
    rand bit             inject_ecrc_err;
    rand bit             inject_lcrc_err;
    rand bit             inject_poisoned;
    rand bit             violate_ordering;
    rand bit [31:0]      field_bitmask;
    rand tlp_constraint_mode_e  constraint_mode_sel;
endclass
```

### 3.2 Derived TLP Types

| Class | TLP Type |
|-------|----------|
| `pcie_tl_mem_tlp` | Memory Read/Write |
| `pcie_tl_io_tlp` | IO Read/Write |
| `pcie_tl_cfg_tlp` | Config Read/Write (Type 0/1) |
| `pcie_tl_cpl_tlp` | Completion/CompletionD |
| `pcie_tl_msg_tlp` | Message (INTx/MSI/MSI-X/PME/ERR) |
| `pcie_tl_atomic_tlp` | AtomicOp (FetchAdd/Swap/CAS) |
| `pcie_tl_vendor_tlp` | Vendor Defined Message |
| `pcie_tl_ltr_tlp` | LTR |

### 3.3 Key Design Points

- Error injection fields are `rand` members with default constraints (`inject_* == 0`), overridden at sequence level when needed
- `field_bitmask` supports arbitrary bit-flip on encoded header for fully programmable field tampering
- `constraint_mode_sel` selects preset constraint templates: `LEGAL`, `ILLEGAL`, `CORNER_CASE`
- 10-bit Tag covers both 8-bit and Extended Tag scenarios; Phantom Function handled via Tag upper bits mapping to Function Number

---

## 4. Shared Components

### 4.1 TLP Codec (`pcie_tl_codec`)

- Bidirectional conversion: TLP object <-> byte stream
- Error injection applied during encode phase:
  1. Normal encode header + payload
  2. Apply `field_bitmask` bit flips
  3. Optionally corrupt ECRC based on `inject_ecrc_err`

### 4.2 FC Manager (`pcie_tl_fc_manager`)

- Independent credit management for three categories: Posted, Non-Posted, Completion (header + data each)
- Master switch: `fc_enable` (default on)
- Infinite credit mode: `infinite_credit` (default off)
- Core interface: `check_credit()`, `consume_credit()`, `return_credit()`
- Error injection: `force_credit_overflow()`, `force_credit_underflow()`

### 4.3 Bandwidth Shaper (`pcie_tl_bw_shaper`)

- Token bucket model with `avg_rate` (bytes/ns) and `burst_size` (bytes)
- Default disabled (`shaper_enable = 0`)
- Integrates with FC Manager: controls bandwidth by regulating credit return rate
- Interface: `can_send()`, `on_sent()`, `refill_tokens()`

### 4.4 Tag Manager (`pcie_tl_tag_manager`)

- Per-function tag pool with configurable sharing/isolation
- 10-bit Extended Tag support, Phantom Function support
- Configurable `max_outstanding` (default 1024)
- Completion matching: `match_completion()`
- Duplicate detection: `is_duplicate()`
- Error injection: `alloc_duplicate_tag()`

### 4.5 Ordering Engine (`pcie_tl_ordering_engine`)

- Three queues: Posted, Non-Posted, Completion
- Full PCIe Spec Table 2-40 ordering matrix implementation
- Relaxed Ordering and ID-Based Ordering attribute support
- Programmable violation: `bypass_ordering` switch + `force_ordering_violation()`
- Core interface: `enqueue()`, `dequeue_next()`, `check_ordering()`

### 4.6 Config Space Manager (`pcie_tl_cfg_space_manager`)

- 4KB configuration space (Type 0 + Extended)
- Dynamic Capability chain management (standard + extended)
- Register/unregister capabilities at runtime, including Vendor-Specific
- Read/Write with per-address callback hooks
- Callbacks triggered on config space access (e.g., BAR write triggers address remapping)

### 4.7 Component Collaboration Flow (Sending a Non-Posted TLP)

```
Sequence produces TLP
  -> Tag Manager allocates Tag
  -> Ordering Engine enqueues, waits for ordering permission
  -> FC Manager checks credit
  -> BW Shaper checks tokens
  -> TLP Codec encodes + applies error injection
  -> Driver sends to interface
```

---

## 5. Agent Architecture

### 5.1 Base Agent

- Contains: driver, monitor, sequencer
- Holds references to all shared components (injected by env)

### 5.2 RC Agent (`pcie_tl_rc_agent`)

- Initiates Config/Memory/IO requests
- Manages global address mapping (BAR allocation)
- Completion timeout management
- Interrupt reception (INTx/MSI/MSI-X)

### 5.3 EP Agent (`pcie_tl_ep_agent`)

- Responds to Config/Memory/IO requests
- Generates Completions
- Initiates MSI/MSI-X interrupts
- DMA initiation (Bus Master mode)
- Auto-response mode with configurable delay (`response_delay_min/max`)

### 5.4 Monitor (`pcie_tl_base_monitor`)

- Dual analysis ports: `tlp_ap` (all TLPs), `err_ap` (error TLPs)
- Independent protocol check switches: ordering, FC, Tag, TLP format
- Coverage callback hook for user-registered covergroups

### 5.5 RC vs EP Behavior Summary

| Behavior | RC | EP |
|----------|----|----|
| Config Request | Initiate | Respond |
| Memory Request | Initiate | Respond + Initiate (DMA) |
| Completion | Receive/Match | Generate/Send |
| Interrupt | Receive | Initiate (MSI/MSI-X) |
| Address Mgmt | Global BAR alloc | Local BAR mapping |
| Auto-response | N/A | Core feature |

---

## 6. Sequence Library

### 6.1 Base Sequences

One per TLP type (mem_rd, mem_wr, io_rd, io_wr, cfg_rd, cfg_wr, cpl, msg, atomic, vendor_msg, ltr). Each supports `constraint_mode_sel` for LEGAL/ILLEGAL/CORNER_CASE templates.

### 6.2 Scenario Sequences

| Sequence | Description |
|----------|-------------|
| `pcie_tl_bar_enum_seq` | BAR enumeration flow |
| `pcie_tl_dma_rdwr_seq` | DMA read/write with MPS-aligned splitting |
| `pcie_tl_msi_seq` | MSI/MSI-X interrupt trigger |
| `pcie_tl_cpl_timeout_seq` | Completion timeout scenario |
| `pcie_tl_err_malformed_seq` | Malformed TLP injection |
| `pcie_tl_err_poisoned_seq` | Poisoned TLP injection |
| `pcie_tl_err_unexpected_cpl_seq` | Unexpected Completion injection |
| `pcie_tl_err_tag_conflict_seq` | Tag conflict injection |

### 6.3 Virtual Sequences

- `pcie_tl_base_vseq`: holds references to both RC/EP sequencers and shared components
- `pcie_tl_rc_ep_rdwr_vseq`: RC sends request, EP auto-responds, RC receives Completion
- `pcie_tl_enum_then_dma_vseq`: enumeration followed by DMA traffic
- `pcie_tl_backpressure_vseq`: FC credit exhaustion / back-pressure testing

### 6.4 Constraint Templates

- **Legal**: length/fmt consistency, valid BE combinations, address alignment, valid Tag range
- **Illegal**: zero-length with payload, invalid BE, 64-bit addr with 3DW fmt, unmatched Completion tag
- **Corner case**: max length (1024), 4KB boundary crossing, all-zero/all-one BE, near-full Tag space

### 6.5 File Structure

```
sequence_lib/
├── base/          # Atomic sequence per TLP type
├── scenario/      # Preset scenarios (enum, dma, msi, error...)
├── virtual/       # Multi-agent coordination
└── constraints/   # Randomization templates (legal, illegal, corner_case)
```

---

## 7. Coverage Collection

### 7.1 Switch Control

- Master switch `cov_enable` (default OFF)
- Per-group switches: `tlp_basic_enable`, `fc_state_enable`, `tag_usage_enable`, `ordering_enable`, `error_inject_enable` (all default OFF)
- `enable_all()` / `disable_all()` convenience methods
- Covergroups are lazily constructed only when enabled, avoiding simulation overhead

### 7.2 Coverage Groups

| Group | Coverage Points |
|-------|-----------------|
| TLP Basic | type, fmt, length bins, tc, RO/IDO attributes |
| FC State | credit levels per category (empty/low/normal/high), infinite mode |
| Tag Usage | outstanding count bins (empty to full), phantom/extended enable |
| Ordering | prev/curr TLP category cross, RO/IDO active |
| Error Injection | ecrc_err, poisoned, ordering violation, tag dup, fc overflow, malformed |

### 7.3 User Extension

- `register_callback(pcie_tl_coverage_callback cb)` for user-defined covergroups
- User callbacks invoked independently of built-in covergroup enable switches

---

## 8. Scoreboard

### 8.1 Check Items

| Check | Description |
|-------|-------------|
| Request-Completion Match | Tag match, requester_id match, byte_count consistency, unexpected Completion detection |
| Ordering Compliance | Table 2-40 validation with RO/IDO relaxation |
| Data Integrity | Memory Write data vs Memory Read Completion data comparison |
| Config Consistency | Config Read return value vs cfg_space_manager internal state |
| Error Response | Verify DUT correctly detects injected errors (UR, CA, CRS) |

### 8.2 Statistics

- Tracks: total_requests, total_completions, matched, mismatched, unexpected, timed_out
- Reports summary in `report_phase`

---

## 9. Interface Adapter

### 9.1 Dual Mode

| Mode | Use Case |
|------|----------|
| `TLM_MODE` | Pure UVM loopback testing, no RTL needed |
| `SV_IF_MODE` | Connect to commercial VIP DLL via SV interface |

### 9.2 SV Interface (`pcie_tl_if`)

- TLP data channel: 256-bit bus with valid/ready handshake, SOP/EOP framing
- FC credit channel: per-category credit signals with update strobe
- Modports: master, slave, monitor

### 9.3 Adapter (`pcie_tl_if_adapter`)

- Runtime mode switching via `switch_mode()`
- TLM side: tx/rx FIFOs
- SV IF side: `drive_to_interface()` (encode + multi-beat drive), `sample_from_interface()` (capture + decode)
- FC credit synchronization task for SV_IF_MODE

### 9.4 Integration Topology

```
TLM_MODE:   [RC Agent] --TLM--> [EP Agent]                 (self-loop)
SV_IF_MODE: [RC Agent] --Adapter--> SV IF --> [Commercial VIP DLL] --> DUT
```

---

## 10. Configuration

### 10.1 Unified Config Object (`pcie_tl_env_config`)

| Category | Key Parameters | Defaults |
|----------|---------------|----------|
| Role | rc/ep_agent_enable, active/passive | Both active |
| Interface | if_mode | TLM_MODE |
| FC | fc_enable, infinite_credit, init credits | Enabled, finite, 32/256 |
| Bandwidth | shaper_enable, avg_rate, burst_size | Disabled |
| Tag | extended_tag, phantom_func, max_outstanding | Extended on, phantom off, 1024 |
| Ordering | RO, IDO, bypass_ordering | RO/IDO on, bypass off |
| Coverage | cov_enable + per-group enables | All off |
| Scoreboard | scb_enable + per-check enables | All on |
| EP Response | auto_response, delay_min/max | Auto on, 0-10 |
| Timeout | cpl_timeout_ns | 50000 (50us) |

---

## 11. File Structure

```
pcie_tl_vip/
├── src/
│   ├── pcie_tl_pkg.sv
│   ├── pcie_tl_if.sv
│   ├── types/
│   │   ├── pcie_tl_types.sv
│   │   └── pcie_tl_tlp.sv
│   ├── shared/
│   │   ├── pcie_tl_codec.sv
│   │   ├── pcie_tl_fc_manager.sv
│   │   ├── pcie_tl_bw_shaper.sv
│   │   ├── pcie_tl_tag_manager.sv
│   │   ├── pcie_tl_ordering_engine.sv
│   │   └── pcie_tl_cfg_space_manager.sv
│   ├── agent/
│   │   ├── pcie_tl_base_agent.sv
│   │   ├── pcie_tl_base_driver.sv
│   │   ├── pcie_tl_base_monitor.sv
│   │   ├── pcie_tl_rc_agent.sv
│   │   ├── pcie_tl_rc_driver.sv
│   │   ├── pcie_tl_ep_agent.sv
│   │   └── pcie_tl_ep_driver.sv
│   ├── adapter/
│   │   └── pcie_tl_if_adapter.sv
│   ├── env/
│   │   ├── pcie_tl_env_config.sv
│   │   ├── pcie_tl_env.sv
│   │   ├── pcie_tl_scoreboard.sv
│   │   ├── pcie_tl_coverage_collector.sv
│   │   └── pcie_tl_virtual_sequencer.sv
│   └── seq/
│       ├── base/
│       ├── scenario/
│       ├── virtual/
│       └── constraints/
└── tests/
    └── pcie_tl_base_test.sv
```
