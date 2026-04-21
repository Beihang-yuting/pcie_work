# PCIe TL VIP Link Delay Model Design Spec

**Date:** 2026-04-21
**Status:** Approved
**Scope:** TLM Loopback Bridge link latency simulation

---

## 1. Overview

Add a link delay model to the PCIe TL VIP that simulates realistic link propagation latency in the TLM loopback path between RC and EP agents. The model operates as a pipeline — multiple TLPs can be in-flight simultaneously, preserving their relative spacing and ordering.

### 1.1 Design Principles

- Link delay is a link property, modeled as an independent component
- RC->EP and EP->RC directions have independent delay configurations
- Delay value is randomized within a configurable range
- Delay value updates periodically (every N TLPs), not per-TLP, to preserve ordering
- Same-direction TLPs are strictly ordered (no reordering from delay changes)
- Default disabled; zero overhead when off

---

## 2. Requirements

| Requirement | Decision |
|-------------|----------|
| Injection point | TLM Loopback Bridge (env.run_phase) |
| Direction control | RC->EP and EP->RC independently configurable |
| Delay form | Random range: latency_min ~ latency_max (ns) |
| Pipeline model | Multiple TLPs in-flight, relative spacing preserved |
| Randomization timing | Every N TLPs, N is configurable (update_interval) |
| Ordering guarantee | Same-direction TLPs strictly ordered |
| Default state | Disabled (enable = 0) |

---

## 3. Architecture

### 3.1 Component Placement

```
Before:
  RC tx_fifo ---------------------------> EP rx_fifo
  EP tx_fifo ---------------------------> RC rx_fifo

After:
  RC tx_fifo --> [link_delay rc2ep] --> EP rx_fifo
  EP tx_fifo --> [link_delay ep2rc] --> RC rx_fifo
```

### 3.2 Component: pcie_tl_link_delay_model

A uvm_component that sits in the TLM loopback path and introduces configurable pipeline delay.

```systemverilog
class pcie_tl_link_delay_model extends uvm_component;

    //--- Configuration ---
    bit     enable;                 // Master switch, default 0
    int     latency_min_ns;         // Minimum delay in ns
    int     latency_max_ns;         // Maximum delay in ns
    int     update_interval;        // Re-randomize delay every N TLPs

    //--- Runtime state ---
    int     current_latency_ns;     // Currently active delay value
    int     tlp_count;              // TLPs processed since last update
    realtime last_arrival_time;     // For ordering guarantee

    //--- Core interface ---
    task forward(input pcie_tl_tlp tlp, input uvm_tlm_fifo #(pcie_tl_tlp) dst);
endclass
```

---

## 4. Detailed Design

### 4.1 forward() Task -- Core Logic

```
1. If !enable: put directly to dst, return immediately
2. Increment tlp_count
3. If tlp_count >= update_interval:
   a. current_latency_ns = $urandom_range(latency_max_ns, latency_min_ns)
   b. tlp_count = 0
4. Calculate arrival_time = $realtime + current_latency_ns * 1ns
5. Ordering guard: arrival_time = max(arrival_time, last_arrival_time + 1ns)
6. Update last_arrival_time = arrival_time
7. Fork: wait until arrival_time, then dst.put(tlp)
   (fork-join_none to allow pipeline concurrency)
```

### 4.2 Ordering Guarantee

When the delay value changes at an update boundary, a shorter new delay could cause a later TLP to overtake an earlier one still in-flight. The ordering guard prevents this:

```systemverilog
arrival_time = max(entry_time + current_latency_ns, last_arrival_time + 1ns);
```

This ensures monotonically increasing arrival times regardless of delay value changes.

### 4.3 Pipeline Behavior

Each TLP is independently forked with its own delay. Multiple TLPs can be in the delay pipeline simultaneously:

```
T=0ns:    TLP1 enters, current_latency=2000ns -> arrives @ T=2000ns
T=10ns:   TLP2 enters, current_latency=2000ns -> arrives @ T=2010ns
T=20ns:   TLP3 enters, current_latency=2000ns -> arrives @ T=2020ns
```

Relative spacing (10ns between TLPs) is preserved.

### 4.4 Runtime Reconfiguration

The delay model supports runtime reconfiguration via public methods:

```systemverilog
// Update delay range
function void set_latency(int min_ns, int max_ns);

// Update interval
function void set_update_interval(int n);

// Force immediate re-randomization
function void force_update();

// Reset state (counter, last_arrival)
function void reset();
```

### 4.5 Statistics and Reporting

Track delay statistics for report_phase:

```systemverilog
int      total_forwarded;        // Total TLPs forwarded
int      total_delayed;          // TLPs that experienced non-zero delay
realtime total_delay_time;       // Cumulative delay applied
int      min_applied_ns;         // Minimum delay actually applied
int      max_applied_ns;         // Maximum delay actually applied
int      delay_updates;          // Number of times delay was re-randomized
```

Report in report_phase with format:
```
Link Delay Report [rc2ep]:
  Total forwarded: 200
  Delay range config: 1500-2500 ns
  Applied range: 1523-2487 ns
  Update interval: 16 TLPs
  Delay updates: 12
```

---

## 5. Configuration

### 5.1 New Parameters in pcie_tl_env_config

```systemverilog
//--- Link Delay ---
bit     link_delay_enable              = 0;
int     rc2ep_latency_min_ns           = 0;
int     rc2ep_latency_max_ns           = 0;
int     ep2rc_latency_min_ns           = 0;
int     ep2rc_latency_max_ns           = 0;
int     link_delay_update_interval     = 16;
```

### 5.2 Usage Examples

```systemverilog
// Fixed 2us delay both directions
cfg.link_delay_enable          = 1;
cfg.rc2ep_latency_min_ns       = 2000;
cfg.rc2ep_latency_max_ns       = 2000;
cfg.ep2rc_latency_min_ns       = 2000;
cfg.ep2rc_latency_max_ns       = 2000;

// Asymmetric random delay, update every 32 TLPs
cfg.link_delay_enable          = 1;
cfg.rc2ep_latency_min_ns       = 1500;
cfg.rc2ep_latency_max_ns       = 2500;
cfg.ep2rc_latency_min_ns       = 1000;
cfg.ep2rc_latency_max_ns       = 2000;
cfg.link_delay_update_interval = 32;
```

---

## 6. Integration into pcie_tl_env

### 6.1 New Members

```systemverilog
pcie_tl_link_delay_model  rc2ep_delay;
pcie_tl_link_delay_model  ep2rc_delay;
```

### 6.2 build_phase Changes

```systemverilog
rc2ep_delay = pcie_tl_link_delay_model::type_id::create("rc2ep_delay", this);
ep2rc_delay = pcie_tl_link_delay_model::type_id::create("ep2rc_delay", this);
```

### 6.3 apply_config Changes

```systemverilog
rc2ep_delay.enable          = cfg.link_delay_enable;
rc2ep_delay.latency_min_ns  = cfg.rc2ep_latency_min_ns;
rc2ep_delay.latency_max_ns  = cfg.rc2ep_latency_max_ns;
rc2ep_delay.update_interval = cfg.link_delay_update_interval;

ep2rc_delay.enable          = cfg.link_delay_enable;
ep2rc_delay.latency_min_ns  = cfg.ep2rc_latency_min_ns;
ep2rc_delay.latency_max_ns  = cfg.ep2rc_latency_max_ns;
ep2rc_delay.update_interval = cfg.link_delay_update_interval;
```

### 6.4 Loopback Task Changes

```systemverilog
// tlm_loopback_rc_to_ep -- before:
ep_adapter.tlm_rx_fifo.put(tlp);

// after:
rc2ep_delay.forward(tlp, ep_adapter.tlm_rx_fifo);

// tlm_loopback_ep_to_rc -- before:
rc_adapter.tlm_rx_fifo.put(tlp);

// after:
ep2rc_delay.forward(tlp, rc_adapter.tlm_rx_fifo);
```

Note: The replenish_credits() call and EP auto-response / RC completion handling remain in the loopback tasks, executed at TLP entry time (not delayed). Only the data delivery to the peer adapter is delayed.

---

## 7. File Changes

| File | Change |
|------|--------|
| src/shared/pcie_tl_link_delay_model.sv | NEW -- delay model component |
| src/pcie_tl_pkg.sv | Add include for new file |
| src/env/pcie_tl_env_config.sv | Add 6 delay parameters |
| src/env/pcie_tl_env.sv | Create delay models, wire into loopback |
| tests/pcie_tl_advanced_test.sv | Add link delay test case |

---

## 8. Test Plan

### 8.1 New Test: pcie_tl_link_delay_test

Objective: Verify link delay model correctness

Test phases:

1. Fixed delay verification
   - Set rc2ep = ep2rc = 2000ns (fixed)
   - Send 10 memory writes, record send/receive timestamps
   - Verify each TLP arrives ~2000ns after send
   - Verify relative spacing preserved

2. Asymmetric delay
   - Set rc2ep = 2000ns, ep2rc = 1000ns
   - Send memory read (RC->EP), receive completion (EP->RC)
   - Verify request delay ~2000ns, completion delay ~1000ns

3. Random range with ordering
   - Set range 1500-2500ns, update_interval = 4
   - Send 20 TLPs
   - Verify arrival order matches send order
   - Verify all delays within range

4. Disabled mode
   - Set enable = 0
   - Verify zero additional latency

---

## 9. Interactions with Existing Components

### 9.1 Completion Timeout

Link delay adds to the round-trip time. A 2us each-way delay adds 4us to completion round-trip. Users must ensure cpl_timeout_ns accounts for link delay:

```
effective_timeout >= rc2ep_latency_max + ep_response_delay_max + ep2rc_latency_max
```

### 9.2 Flow Control

FC credit replenishment occurs at TLP entry time (before delay), not at delivery time. This models the PCIe behavior where credits are returned based on receiver buffer space, not link transit time. No FC changes needed.

### 9.3 Bandwidth Shaper

BW shaper operates at the sender side (before link entry). Link delay does not affect shaper token consumption. No changes needed.

### 9.4 Scoreboard

Scoreboard receives TLPs from monitors, which see TLPs at adapter rx side (after delay). Ordering checks will see the delayed arrival order, which should be preserved by the ordering guard. No scoreboard changes needed.
