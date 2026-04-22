# PCIe TL Switch Model Design Spec

**Date:** 2026-04-22
**Status:** Approved
**Scope:** Standard PCIe Switch with parameterized ports, P2P, Type 1 config, dual config mode

---

## 1. Overview

Add a PCIe Transaction Layer Switch model to the existing VIP. The switch sits between the RC agent and N EP agents, providing TLP routing based on address, BDF, and message type. It supports Peer-to-Peer (P2P) direct forwarding between downstream ports.

### Goals

- Parameterized 1-16 downstream ports
- Three routing modes: address-based, ID-based, implicit (message)
- Full P2P: EP-to-EP direct forwarding without RC involvement
- Type 1 PCI config header per port with bus numbering and address windows
- Dual config mode: static (fast) and enumeration (realistic)
- Independent FC credit per port
- Standalone component integrating into existing env with zero changes to RC/EP agents

### Non-Goals (future increments)

- ACS (Access Control Services)
- Multicast
- QoS / TC arbitration
- Hot-plug
- Error forwarding / AER

---

## 2. Architecture

```
                         +------------------------------+
                         |       pcie_tl_switch          |
                         |                              |
RC Agent --[adapter]---- | USP ---- Switch ---- DSP[0] | ----[adapter]-- EP Agent 0
                         |         Fabric      DSP[1] | ----[adapter]-- EP Agent 1
                         |                     DSP[2] | ----[adapter]-- EP Agent 2
                         |                      ...    |       ...
                         |                     DSP[N] | ----[adapter]-- EP Agent N
                         +------------------------------+
```

### 2.1 Component Hierarchy

| Component | Class | Responsibility |
|-----------|-------|----------------|
| Switch top | `pcie_tl_switch` | UVM component container. Holds 1 USP + N DSP + fabric. Created by env. |
| Switch port | `pcie_tl_switch_port` | Port abstraction (USP and DSP share the same class, differentiated by `port_role_e`). Contains Type 1 config space, per-port FC credits, per-port link delay, and TLM FIFOs. |
| Switch fabric | `pcie_tl_switch_fabric` | Routing core. Receives TLP + ingress port ID, returns egress port ID. Stateless lookup -- all state lives in port config registers. |
| Switch config | `pcie_tl_switch_config` | UVM object. Parameterizes port count, bus numbers, address windows, P2P enable, enum mode, link delays. |

### 2.2 File Layout

```
pcie_tl_vip/src/switch/
  pcie_tl_switch.sv            # Top-level switch component
  pcie_tl_switch_port.sv       # Port (USP/DSP) with Type 1 config space
  pcie_tl_switch_fabric.sv     # Routing lookup engine
  pcie_tl_switch_config.sv     # Configuration object
```

---

## 3. Switch Port (`pcie_tl_switch_port`)

Each port (USP and DSP) contains:

### 3.1 TLM Interface

```systemverilog
uvm_tlm_fifo #(pcie_tl_tlp) rx_fifo;  // TLPs arriving at this port
uvm_tlm_fifo #(pcie_tl_tlp) tx_fifo;  // TLPs departing from this port
```

### 3.2 Port Role

```systemverilog
typedef enum {SWITCH_USP, SWITCH_DSP} switch_port_role_e;
```

- USP: connects to RC (or upstream switch)
- DSP: connects to EP (or downstream switch)

### 3.3 Type 1 Config Space (per port)

Each port maintains a Type 1 PCI header:

| Register | Offset | Description |
|----------|--------|-------------|
| Primary Bus | 18h[7:0] | Bus number of upstream link |
| Secondary Bus | 18h[15:8] | Bus number of downstream link |
| Subordinate Bus | 18h[23:16] | Highest bus number below this bridge |
| Memory Base | 20h[15:4] | Memory window base (1MB granularity) |
| Memory Limit | 20h[31:20] | Memory window limit |
| Prefetch Base | 24h[15:4] | Prefetchable memory base |
| Prefetch Limit | 24h[31:20] | Prefetchable memory limit |
| IO Base | 1Ch[7:4] | IO window base (4KB granularity) |
| IO Limit | 1Ch[15:12] | IO window limit |

### 3.4 Per-Port FC Credits

Each port has its own `pcie_tl_fc_manager` instance to manage credit independently. DSP0 backpressure does not affect DSP1 flow.

### 3.5 Per-Port Link Delay

Each port has its own `pcie_tl_link_delay_model` for ingress and egress directions.

---

## 4. Switch Fabric (`pcie_tl_switch_fabric`)

### 4.1 Routing Algorithm

The fabric receives `(tlp, ingress_port_id)` and returns `egress_port_id`.

**Priority order:**

1. **Completion routing (ID-based):** Match `requester_id` bus number to find the port whose secondary-subordinate range contains it.

2. **Config routing (ID-based):** Match `completer_id` (Type 0/1 config) bus number to secondary-subordinate range.

3. **Memory/IO routing (address-based):** Match target address against each port's memory/IO base-limit windows.

4. **Message routing (implicit):** Based on message routing field:
   - Broadcast: forward to all downstream ports
   - Upstream: forward to USP
   - Local: consume within switch

5. **Default route:** If no match found:
   - From DSP: forward to USP (upstream default)
   - From USP: drop or UR (Unsupported Request)

### 4.2 P2P Routing

P2P is the natural result of address-based routing:

```
1. EP0 sends MEM_WR to address 0x9000_0000
2. TLP arrives at DSP0.rx_fifo
3. Fabric lookup: 0x9000_0000 falls in DSP1 memory window [0x9000_0000, 0x9FFF_FFFF]
4. Route to DSP1.tx_fifo -> EP1 receives it
5. TLP never touches USP
```

P2P can be disabled globally via `sw_cfg.p2p_enable = 0`, forcing all DSP-to-DSP traffic through USP.

### 4.3 Routing Table Structure

```systemverilog
typedef struct {
    bit [7:0]  secondary_bus;
    bit [7:0]  subordinate_bus;
    bit [31:0] mem_base;       // [31:20] significant, 1MB aligned
    bit [31:0] mem_limit;      // [31:20] significant
    bit [63:0] pref_base;      // prefetchable
    bit [63:0] pref_limit;
    bit [15:0] io_base;        // [15:12] significant, 4KB aligned
    bit [15:0] io_limit;
} switch_route_entry_t;

// route_table[port_id] -> switch_route_entry_t
// USP route_table[0] is for upstream routing
// DSP route_table[1..N] for downstream routing
```

---

## 5. Switch Config (`pcie_tl_switch_config`)

```systemverilog
class pcie_tl_switch_config extends uvm_object;
    // --- Topology ---
    int num_ds_ports = 4;              // 1-16 downstream ports

    // --- Switch identity ---
    bit [15:0] switch_bdf = 16'h0100;  // Switch's own BDF (bus 1, dev 0, func 0)

    // --- Enumeration mode ---
    bit enum_mode = 0;                 // 0=static, 1=enumeration via Config TLP

    // --- P2P ---
    bit p2p_enable = 1;

    // --- Per-port config (static mode) ---
    bit [7:0]  usp_primary_bus   = 8'h00;
    bit [7:0]  usp_secondary_bus = 8'h01;
    bit [7:0]  usp_subordinate_bus = 8'h0F;

    // DSP arrays (sized by num_ds_ports)
    bit [7:0]  ds_secondary_bus[];     // e.g., [02, 03, 04, 05]
    bit [7:0]  ds_subordinate_bus[];   // e.g., [02, 03, 04, 05]
    bit [31:0] ds_mem_base[];          // e.g., [0x8000_0000, 0x9000_0000, ...]
    bit [31:0] ds_mem_limit[];         // e.g., [0x8FFF_FFFF, 0x9FFF_FFFF, ...]

    // --- Per-port FC credits ---
    int port_ph_credit  = 32;
    int port_pd_credit  = 256;
    int port_nph_credit = 32;
    int port_npd_credit = 256;
    int port_cplh_credit = 32;
    int port_cpld_credit = 256;

    // --- Per-port link delay ---
    bit port_link_delay_enable = 0;
    int port_latency_min_ns    = 0;
    int port_latency_max_ns    = 0;
endclass
```

---

## 6. Integration with Existing VIP

### 6.1 Config Extension

Add to `pcie_tl_env_config`:

```systemverilog
// --- Switch ---
bit                    switch_enable    = 0;
pcie_tl_switch_config  switch_cfg;
```

### 6.2 Env Changes (`pcie_tl_env`)

When `switch_enable = 1`:

- Replace single RC-EP loopback with: RC <-> switch USP, switch DSP[i] <-> EP[i]
- Create dynamic arrays: `ep_agents[]`, `ep_adapters[]`
- Wire RC adapter to switch USP FIFOs, switch DSP[i] FIFOs to EP adapter[i]

**New members:**

```systemverilog
pcie_tl_switch        sw;
pcie_tl_ep_agent      ep_agents[];       // dynamic array
pcie_tl_if_adapter    ep_adapters[];
```

**Run phase:** Replace single loopback with per-port loopback tasks:
- `rc_to_switch_loopback()` -- RC tx -> switch USP rx
- `switch_to_rc_loopback()` -- switch USP tx -> RC rx
- `switch_to_ep_loopback(int port_id)` -- switch DSP[i] tx -> EP[i] rx
- `ep_to_switch_loopback(int port_id)` -- EP[i] tx -> switch DSP[i] rx

### 6.3 Switch Internal Run Phase

```systemverilog
task run_phase(uvm_phase phase);
    fork
        usp_forward_loop();
        for (int i = 0; i < num_ds_ports; i++)
            dsp_forward_loop(i);
    join_none
endtask

task usp_forward_loop();
    forever begin
        usp.rx_fifo.get(tlp);
        int dst = fabric.route(tlp, 0);  // 0 = USP port_id
        if (dst == PORT_LOCAL)
            handle_switch_config(tlp);     // Config TLP targeting switch itself
        else
            ports[dst].tx_fifo.put(tlp);
    end
endtask

task dsp_forward_loop(int port_id);
    forever begin
        ports[port_id].rx_fifo.get(tlp);
        int dst = fabric.route(tlp, port_id);
        if (dst == PORT_USP)
            usp.tx_fifo.put(tlp);
        else if (dst != port_id)           // P2P: forward to another DSP
            ports[dst].tx_fifo.put(tlp);
        else
            ; // drop: routed back to ingress (error)
    end
endtask
```

### 6.4 Backward Compatibility

When `switch_enable = 0` (default), env behaves exactly as before: 1 RC <-> 1 EP direct loopback. Zero impact on existing tests.

---

## 7. Test Plan

### Test 10: Switch Basic Routing

| Phase | Description | Validation |
|-------|-------------|------------|
| 1 | RC writes to EP0, EP1, EP2, EP3 distinct addresses | Each EP receives only its own TLPs |
| 2 | RC reads from each EP | Completions route back correctly |
| 3 | Address isolation: write to EP0 space, verify EP1 doesn't see it | No cross-contamination |

### Test 11: P2P Direct Transfer

| Phase | Description | Validation |
|-------|-------------|------------|
| 1 | EP0 DMA writes to EP1 BAR address | TLP arrives at EP1, not RC |
| 2 | EP0 DMA reads from EP1 | Completion goes EP1->EP0, not through RC |
| 3 | P2P disabled: same addresses forced through USP | TLP goes DSP0->USP->DSP1 |

### Test 12: Switch Enumeration

| Phase | Description | Validation |
|-------|-------------|------------|
| 1 | RC sends Type 1 Config Write to set secondary/subordinate bus | Switch config space updated |
| 2 | RC sets memory base/limit per DSP | Address windows active |
| 3 | RC sends traffic through configured windows | Routing matches enumerated config |

### Test 13: Multi-EP Concurrent Stress

| Phase | Description | Validation |
|-------|-------------|------------|
| 1 | RC blasts writes to all 4 EPs simultaneously | All delivered, no mixing |
| 2 | All 4 EPs DMA write to RC simultaneously | Completions match, FC per-port |
| 3 | Mixed: RC->EP + EP->RC + P2P all concurrent | No deadlock, ordering maintained |

### Test 14: Per-Port FC Isolation

| Phase | Description | Validation |
|-------|-------------|------------|
| 1 | Exhaust DSP0 FC credits (tight config) | DSP0 traffic stalls |
| 2 | Verify DSP1-3 continue unaffected | No cross-port FC interference |
| 3 | Replenish DSP0, verify recovery | Traffic resumes |

---

## 8. New Files Summary

| File | Type | Description |
|------|------|-------------|
| `src/switch/pcie_tl_switch.sv` | New | Top-level switch component |
| `src/switch/pcie_tl_switch_port.sv` | New | Port with Type 1 config + FC + delay |
| `src/switch/pcie_tl_switch_fabric.sv` | New | Routing lookup engine |
| `src/switch/pcie_tl_switch_config.sv` | New | Configuration object |
| `src/pcie_tl_pkg.sv` | Modify | Add switch includes and new enums |
| `src/env/pcie_tl_env_config.sv` | Modify | Add switch_enable, switch_cfg |
| `src/env/pcie_tl_env.sv` | Modify | Multi-EP + switch integration |
| `tests/pcie_tl_advanced_test.sv` | Modify | Add Tests 10-14 |
