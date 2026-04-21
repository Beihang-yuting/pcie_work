# PCIe TL VIP Implementation Plan

**Date:** 2026-04-20
**Spec:** `docs/superpowers/specs/2026-04-20-pcie-tl-vip-design.md`
**Language:** SystemVerilog / UVM

---

## Phase 1: Foundation — Types, Package, Interface

**Goal:** Establish the type system and project skeleton. All subsequent phases depend on this.

### Step 1.1: Project skeleton and package

**File:** `src/pcie_tl_pkg.sv`

- Create directory structure per spec Section 11
- Define the top-level package `pcie_tl_pkg` with `import uvm_pkg::*`
- Include all subsequent files via `` `include `` in dependency order

**Acceptance:** Package compiles cleanly with an empty testbench.

### Step 1.2: Type definitions

**File:** `src/types/pcie_tl_types.sv`

- `tlp_fmt_e`: 3DW_NO_DATA, 3DW_WITH_DATA, 4DW_NO_DATA, 4DW_WITH_DATA, TLP_PREFIX
- `tlp_type_e`: MEM_RD, MEM_WR, IO_RD, IO_WR, CFG_RD0, CFG_WR0, CFG_RD1, CFG_WR1, CPL, CPLD, MSG, MSGD, ATOMIC_FETCHADD, ATOMIC_SWAP, ATOMIC_CAS, VENDOR_MSG, LTR
- `tlp_constraint_mode_e`: LEGAL, ILLEGAL, CORNER_CASE
- `tlp_category_e`: POSTED, NON_POSTED, COMPLETION
- `fc_type_e`: POSTED_HDR, POSTED_DATA, NONPOSTED_HDR, NONPOSTED_DATA, CPL_HDR, CPL_DATA
- `pcie_tl_if_mode_e`: TLM_MODE, SV_IF_MODE
- `fc_credit_t`: struct with `int current, limit`
- Completion status enum: SC, UR, CRS, CA

**Acceptance:** All enums and typedefs compile. No dependencies on other files.

### Step 1.3: SV Interface

**File:** `src/pcie_tl_if.sv`

- 256-bit TLP data bus with valid/ready/sop/eop
- FC credit channels (6 channels: PH, PD, NPH, NPD, CPLH, CPLD)
- `fc_update` strobe
- `tlp_error` signal
- Three modports: master, slave, monitor

**Acceptance:** Interface compiles. Can be instantiated in a top module.

### Step 1.4: TLP base class and derived classes

**File:** `src/types/pcie_tl_tlp.sv`

- `pcie_tl_tlp` base class with all common fields, error injection metadata, UVM field macros, `do_compare()`, `do_print()`, `convert2string()`
- Default constraints: all `inject_*` fields constrained to 0
- 8 derived classes: mem, io, cfg, cpl, msg, atomic, vendor, ltr
- Each derived class adds type-specific fields (e.g., `pcie_tl_mem_tlp` adds `addr`, `first_be`, `last_be`, `is_64bit`)
- `requires_completion()` method on base class

**Acceptance:** All TLP classes can be randomized with `LEGAL` constraints. `do_compare` and `convert2string` work correctly.

---

## Phase 2: Shared Components

**Goal:** Implement the 6 utility components. These are independent of UVM agent structure and can be unit-tested individually.

**Dependencies:** Phase 1 complete.

### Step 2.1: TLP Codec

**File:** `src/shared/pcie_tl_codec.sv`

- `encode(pcie_tl_tlp) -> bit[7:0][]`: serialize TLP to byte stream
  - Build 3DW or 4DW header based on `fmt`
  - Append payload
  - Apply `field_bitmask` bit flips post-encoding
  - Calculate and append ECRC (optionally corrupt if `inject_ecrc_err`)
- `decode(bit[7:0][]) -> pcie_tl_tlp`: deserialize byte stream to TLP object
  - Parse fmt/type from first DW to determine header length
  - Create appropriate derived class via factory
  - Extract fields, payload, ECRC
- Helper: `calc_ecrc()`, `verify_ecrc()`

**Acceptance:** Round-trip test: randomize TLP -> encode -> decode -> compare. 100 iterations with all TLP types.

### Step 2.2: FC Manager

**File:** `src/shared/pcie_tl_fc_manager.sv`

- 6 credit counters (PH, PD, NPH, NPD, CPLH, CPLD) as `fc_credit_t`
- `init_credits()`: set initial values from config
- `check_credit(tlp) -> bit`: return 1 if sufficient credit, classify TLP into P/NP/CPL and check header + data credits
- `consume_credit(tlp)`: decrement after send
- `return_credit(fc_type_e, int)`: increment on credit update from peer
- `fc_enable` switch: when off, `check_credit` always returns 1
- `infinite_credit` switch: never decrement
- `force_credit_overflow()` / `force_credit_underflow()`: set credits to max/0

**Acceptance:** Unit test: consume until exhausted -> check returns 0 -> return credits -> check returns 1. Test infinite mode. Test overflow/underflow injection.

### Step 2.3: Bandwidth Shaper

**File:** `src/shared/pcie_tl_bw_shaper.sv`

- Token bucket: `token_count`, `avg_rate`, `burst_size`
- `can_send(int bytes) -> bit`: check if enough tokens
- `on_sent(int bytes)`: deduct tokens
- `refill_tokens()`: background task, add `avg_rate * elapsed_time` tokens, capped at `burst_size`
- `shaper_enable` switch: when off, `can_send` always returns 1
- Integration point: called by driver before sending

**Acceptance:** Unit test: configure rate, send burst, verify throttling kicks in at correct point. Verify disabled mode bypasses all checks.

### Step 2.4: Tag Manager

**File:** `src/shared/pcie_tl_tag_manager.sv`

- `tag_pool`: associative array `int func_id -> bit[9:0] queue[$]`
- `outstanding_txn`: associative array `bit[9:0] -> pcie_tl_tlp`
- `init_pool(int func_id, int tag_width, bit phantom)`: populate available tags
- `alloc_tag(int func_id) -> bit[9:0]`: pop from pool, push to outstanding
- `free_tag(bit[9:0])`: remove from outstanding, push back to pool
- `match_completion(pcie_tl_cpl_tlp) -> pcie_tl_tlp`: lookup by tag + requester_id
- `is_duplicate(bit[9:0]) -> bit`: check if tag already in outstanding
- `alloc_duplicate_tag() -> bit[9:0]`: error injection, return already-used tag
- `get_outstanding_count() -> int`

**Acceptance:** Unit test: alloc N tags, verify no duplicates, free and realloc, verify duplicate detection, test phantom function tag mapping.

### Step 2.5: Ordering Engine

**File:** `src/shared/pcie_tl_ordering_engine.sv`

- Three queues: `posted_queue`, `non_posted_queue`, `completion_queue`
- `classify(pcie_tl_tlp) -> tlp_category_e`: determine P/NP/CPL
- `enqueue(pcie_tl_tlp)`: add to appropriate queue
- `dequeue_next() -> pcie_tl_tlp`: select next TLP respecting Table 2-40 rules
  - Posted cannot be blocked by Non-Posted
  - Non-Posted cannot be blocked by Completion
  - Respect RO and IDO attributes for relaxation
- `check_ordering(pcie_tl_tlp) -> bit`: verify a TLP doesn't violate ordering relative to previously sent TLPs
- `bypass_ordering` switch: skip all ordering checks
- `force_ordering_violation()`: deliberately reorder

**Acceptance:** Unit test: enqueue mixed P/NP/CPL, verify dequeue order matches Table 2-40. Test RO relaxation. Test bypass mode. Test violation injection.

### Step 2.6: Config Space Manager

**File:** `src/shared/pcie_tl_cfg_space_manager.sv`

- `cfg_space[4096]`: 4KB byte array
- `init_type0_header()`: populate standard Type 0 header fields (Vendor ID, Device ID, Command, Status, BAR0-5, etc.)
- `register_capability(pcie_capability)`: insert into capability linked list, update next pointers
- `unregister_capability(bit[7:0] cap_id)`: remove and relink
- `register_ext_capability(pcie_ext_capability)`: extended config space capabilities
- `register_vendor_specific(bit[7:0] data[])`: add VS capability
- `read(bit[11:0] addr) -> bit[31:0]`: read with callback trigger
- `write(bit[11:0] addr, bit[31:0] data, bit[3:0] be)`: write with callback trigger, respect RO/RW/W1C field attributes
- `register_callback(bit[11:0] addr, pcie_cfg_callback cb)`: per-address callback
- Callback base class `pcie_cfg_callback` with `on_read()` and `on_write()` virtual methods

**Acceptance:** Unit test: init header, register MSI/MSI-X/PM/PCIe/AER capabilities, verify linked list, read/write with callbacks, test dynamic register/unregister.

---

## Phase 3: Agent Infrastructure

**Goal:** Build the UVM agent hierarchy. Depends on Phase 1 (types) and Phase 2 (shared components).

**Dependencies:** Phase 1 + Phase 2 complete.

### Step 3.1: Base driver

**File:** `src/agent/pcie_tl_base_driver.sv`

- Extends `uvm_driver #(pcie_tl_tlp)`
- Holds references to all shared components
- `send_tlp(pcie_tl_tlp)` virtual task: the core send pipeline
  - Tag allocation (if Non-Posted)
  - Ordering engine enqueue + wait
  - FC credit check + wait
  - BW shaper check + wait
  - Codec encode
  - Send via adapter
- `wait_for_send_permission(pcie_tl_tlp)`: blocking task that polls FC + ordering + BW

**Acceptance:** Compiles. Virtual methods can be overridden.

### Step 3.2: Base monitor

**File:** `src/agent/pcie_tl_base_monitor.sv`

- Extends `uvm_monitor`
- Two analysis ports: `tlp_ap`, `err_ap`
- Protocol check switches (4 independent bits)
- `monitor_tlp()` task: receive from adapter -> decode -> protocol checks -> broadcast
- Coverage callback registration
- Protocol checkers as internal methods: `check_tlp_format()`, `check_fc_compliance()`, `check_tag_validity()`, `check_ordering_compliance()`

**Acceptance:** Compiles. Can register and trigger callbacks.

### Step 3.3: Base agent

**File:** `src/agent/pcie_tl_base_agent.sv`

- Extends `uvm_agent`
- Creates driver (if active), monitor, sequencer (if active)
- Connects driver <-> sequencer via TLM
- Holds shared component references

**Acceptance:** Compiles. build_phase and connect_phase work correctly.

### Step 3.4: RC driver and agent

**Files:** `src/agent/pcie_tl_rc_driver.sv`, `src/agent/pcie_tl_rc_agent.sv`

- RC driver extends base driver:
  - Override `send_tlp()` to add Completion timeout tracking
  - `start_cpl_timeout(tlp)` fork task
  - `handle_completion(pcie_tl_cpl_tlp)`: match with outstanding, free tag
  - BAR address allocation logic
  - Interrupt receive handling (INTx/MSI/MSI-X recognition)
- RC agent creates RC driver, inherits rest from base

**Acceptance:** Can send Memory Read and receive Completion in TLM loopback. Timeout fires correctly.

### Step 3.5: EP driver and agent

**Files:** `src/agent/pcie_tl_ep_driver.sv`, `src/agent/pcie_tl_ep_agent.sv`

- EP driver extends base driver:
  - `auto_response_enable` switch
  - `handle_request(pcie_tl_tlp)`: dispatch by TLP type
    - Config R/W -> cfg_space_manager
    - Memory R/W -> internal memory model (simple associative array)
    - IO R/W -> internal IO space
  - `generate_completion(req) -> pcie_tl_cpl_tlp`: build Completion from request
  - Configurable response delay (min/max randomized)
  - `initiate_dma()`: Bus Master mode, uses base `send_tlp()`
  - MSI/MSI-X initiation
- EP agent creates EP driver

**Acceptance:** EP auto-responds to Config Read with correct data from cfg_space_manager. Response delay is within configured range.

---

## Phase 4: Interface Adapter

**Goal:** Bridge between UVM TLM and SV Interface. Enables both loopback and RTL integration.

**Dependencies:** Phase 1 (interface definition) + Phase 3 (agents).

### Step 4.1: Adapter implementation

**File:** `src/adapter/pcie_tl_if_adapter.sv`

- `pcie_tl_if_mode_e mode`
- TLM side: `uvm_tlm_fifo` for tx/rx
- SV IF side: `virtual pcie_tl_if vif`
- `send(pcie_tl_tlp)`: dispatch by mode
- `receive() -> pcie_tl_tlp`: dispatch by mode
- `switch_mode(pcie_tl_if_mode_e)`: runtime switch
- `drive_to_interface(tlp)`: encode -> multi-beat transfer with valid/ready/sop/eop
- `sample_from_interface() -> tlp`: capture beats -> decode
- `fc_credit_sync()`: background task for SV_IF_MODE, reads credit signals on fc_update

**Acceptance:** TLM mode: send from RC adapter, receive from EP adapter via connected FIFOs. SV_IF mode: drive and sample on interface with correct timing.

---

## Phase 5: Env, Scoreboard, Coverage

**Goal:** Top-level environment assembly and verification infrastructure.

**Dependencies:** Phase 3 + Phase 4 complete.

### Step 5.1: Config object

**File:** `src/env/pcie_tl_env_config.sv`

- All parameters per spec Section 10
- `uvm_object_utils` with field macros for all config fields

**Acceptance:** Can be created, randomized, printed, passed via uvm_config_db.

### Step 5.2: Virtual sequencer

**File:** `src/env/pcie_tl_virtual_sequencer.sv`

- Extends `uvm_sequencer`
- Holds references: `rc_seqr`, `ep_seqr`, `fc_mgr`, `tag_mgr`

**Acceptance:** Compiles. References assignable.

### Step 5.3: Scoreboard

**File:** `src/env/pcie_tl_scoreboard.sv`

- Dual analysis imports: `rc_imp`, `ep_imp`
- `pending_requests` associative array
- 5 check methods per spec Section 8
- Statistics counters
- `report_phase` summary output
- Per-check enable switches

**Acceptance:** Unit test: send request from RC, matching completion from EP, verify match. Send unexpected completion, verify detection. Verify report output.

### Step 5.4: Coverage collector

**File:** `src/env/pcie_tl_coverage_collector.sv`

- Master switch + 5 group switches, all default OFF
- Lazy covergroup construction
- 5 covergroups per spec Section 7
- `enable_all()` / `disable_all()`
- User callback registration
- `write()` method with switch-guarded sampling

**Acceptance:** Default: no covergroups constructed, zero overhead. Enable one group: only that covergroup constructed and sampled. Callback fires independently.

### Step 5.5: Top-level env

**File:** `src/env/pcie_tl_env.sv`

- `build_phase`: read config from uvm_config_db, create all components conditionally
- `connect_phase`: wire shared components into agents, connect monitor APs to scoreboard/coverage, bind virtual sequencer
- `apply_config()`: propagate config to all sub-components

**Acceptance:** Full env builds and connects without errors. Config propagation verified.

---

## Phase 6: Sequence Library

**Goal:** Complete sequence library for test development.

**Dependencies:** Phase 5 complete (need working env for testing sequences).

### Step 6.1: Base sequences

**Files:** `src/seq/base/pcie_tl_mem_rd_seq.sv`, `pcie_tl_mem_wr_seq.sv`, `pcie_tl_io_rd_seq.sv`, `pcie_tl_io_wr_seq.sv`, `pcie_tl_cfg_rd_seq.sv`, `pcie_tl_cfg_wr_seq.sv`, `pcie_tl_cpl_seq.sv`, `pcie_tl_msg_seq.sv`, `pcie_tl_atomic_seq.sv`, `pcie_tl_vendor_msg_seq.sv`, `pcie_tl_ltr_seq.sv`

- Each sequence: create TLP item, apply constraint mode, `start_item` / `finish_item`
- Parameterizable fields exposed as `rand` members

**Acceptance:** Each base sequence produces valid TLP when run on a sequencer. All 3 constraint modes work.

### Step 6.2: Constraint templates

**Files:** `src/seq/constraints/pcie_tl_legal_constraints.sv`, `pcie_tl_illegal_constraints.sv`, `pcie_tl_corner_constraints.sv`

- Legal: length/fmt consistency, valid BE, aligned addresses, valid Tag
- Illegal: length=0 with payload, invalid BE, fmt/addr mismatch, orphan Completion tag
- Corner: max length 1024, 4KB crossing, all-zero/all-one BE, Tag near-full

**Acceptance:** Randomize 1000 TLPs with each template, verify legal ones pass protocol checks, illegal ones are correctly malformed.

### Step 6.3: Scenario sequences

**Files:** `src/seq/scenario/pcie_tl_bar_enum_seq.sv`, `pcie_tl_dma_rdwr_seq.sv`, `pcie_tl_msi_seq.sv`, `pcie_tl_cpl_timeout_seq.sv`, error injection sequences (4 files)

- BAR enum: write all-1, read back, assign addr, enable
- DMA: configurable size, MPS splitting, direction
- MSI: vector selection, MSI vs MSI-X
- Timeout: send NP request, suppress EP response
- Error sequences: one per error type

**Acceptance:** Each scenario runs end-to-end in TLM loopback with correct behavior.

### Step 6.4: Virtual sequences

**Files:** `src/seq/virtual/pcie_tl_base_vseq.sv`, `pcie_tl_rc_ep_rdwr_vseq.sv`, `pcie_tl_enum_then_dma_vseq.sv`, `pcie_tl_backpressure_vseq.sv`

- Base vseq: holds rc_seqr, ep_seqr, shared component references
- RC-EP read/write: fork RC request + EP auto-response
- Enum then DMA: sequential composition
- Back-pressure: configure FC rate limiting, burst send

**Acceptance:** All virtual sequences run successfully coordinating both agents. Back-pressure vseq triggers FC blocking.

---

## Phase 7: Integration Test and Base Test

**Goal:** End-to-end validation with a base test class.

**Dependencies:** All previous phases complete.

### Step 7.1: Base test

**File:** `tests/pcie_tl_base_test.sv`

- Extends `uvm_test`
- Creates `pcie_tl_env_config` with sensible defaults
- Creates `pcie_tl_env`
- Provides convenience methods: `configure_fc()`, `configure_tags()`, `enable_coverage()`, `set_mode()`

### Step 7.2: Smoke tests

**File:** `tests/pcie_tl_smoke_test.sv`

- Test 1: TLM loopback — RC sends Memory Read, EP auto-responds, scoreboard matches
- Test 2: Config space — RC enumerates EP BAR, verifies config space
- Test 3: Error injection — Send poisoned TLP, verify scoreboard detects
- Test 4: FC back-pressure — Exhaust credits, verify blocking
- Test 5: Ordering — Send mixed P/NP/CPL, verify ordering compliance

### Step 7.3: Top module

**File:** `tests/pcie_tl_tb_top.sv`

- Instantiate `pcie_tl_if`
- Connect clock/reset
- Set interface in uvm_config_db
- Run UVM test

**Acceptance:** All 5 smoke tests pass. Scoreboard reports 0 mismatches. Coverage (when enabled) shows non-zero hits.

---

## Phase Summary

| Phase | Steps | Key Deliverables | Dependencies |
|-------|-------|-----------------|--------------|
| 1 | 1.1-1.4 | Types, Package, Interface, TLP classes | None |
| 2 | 2.1-2.6 | Codec, FC, BW, Tag, Ordering, Config | Phase 1 |
| 3 | 3.1-3.5 | Base/RC/EP agents with drivers and monitors | Phase 1+2 |
| 4 | 4.1 | Interface adapter (TLM + SV IF) | Phase 1+3 |
| 5 | 5.1-5.5 | Config, Sequencer, Scoreboard, Coverage, Env | Phase 3+4 |
| 6 | 6.1-6.4 | Base/Scenario/Virtual sequences + constraints | Phase 5 |
| 7 | 7.1-7.3 | Base test, smoke tests, top module | All |

## Risk Items

1. **Ordering Engine complexity** — Table 2-40 has subtle corner cases with RO+IDO combinations. Mitigate: write exhaustive unit tests in Phase 2.5 before integrating.
2. **Codec round-trip fidelity** — All TLP types must encode/decode without loss. Mitigate: 100-iteration fuzz test per type in Phase 2.1.
3. **FC + BW Shaper interaction** — Credit return rate throttling by shaper must not deadlock. Mitigate: dedicated integration test in Phase 7.
4. **Multi-function Tag isolation** — Phantom Function tag mapping is easy to get wrong. Mitigate: explicit unit test with 2+ functions sharing/isolating tags.
