# PCIe TL Switch Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a parameterized PCIe Switch model (1 USP + 1-16 DSPs) with address/ID/message routing, P2P, Type 1 config, and dual config mode to the existing PCIe TL VIP.

**Architecture:** The switch is a standalone UVM component (`pcie_tl_switch`) containing port objects (`pcie_tl_switch_port`) and a stateless routing fabric (`pcie_tl_switch_fabric`). It plugs into the existing env between RC and EP agents via TLM FIFOs. When `switch_enable=0` (default), the env behaves identically to before.

**Tech Stack:** SystemVerilog, UVM 1.2, VCS Q-2020.03

**Spec:** `docs/superpowers/specs/2026-04-22-pcie-switch-model-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `src/switch/pcie_tl_switch_config.sv` | Create | Switch configuration object (port count, bus numbers, address windows, P2P, FC, delay) |
| `src/switch/pcie_tl_switch_port.sv` | Create | Port with Type 1 config space, TLM FIFOs, per-port FC and link delay |
| `src/switch/pcie_tl_switch_fabric.sv` | Create | Routing lookup: (TLP, ingress_port) to egress_port |
| `src/switch/pcie_tl_switch.sv` | Create | Top-level container: USP + DSP[] + fabric + forwarding loops |
| `src/types/pcie_tl_types.sv` | Modify | Add `switch_port_role_e`, `switch_route_entry_t` |
| `src/pcie_tl_pkg.sv` | Modify | Add switch file includes |
| `src/env/pcie_tl_env_config.sv` | Modify | Add `switch_enable`, `switch_cfg` |
| `src/env/pcie_tl_env.sv` | Modify | Multi-EP creation, switch wiring, per-port loopback |
| `tests/pcie_tl_advanced_test.sv` | Modify | Tests 10-14 |

---

### Task 1: Switch Types and Config Object

**Files:**
- Modify: `pcie_tl_vip/src/types/pcie_tl_types.sv` (append at end)
- Create: `pcie_tl_vip/src/switch/pcie_tl_switch_config.sv`

- [ ] **Step 1: Add switch types to pcie_tl_types.sv**

Append after the last typedef (after `ext_cap_id_e`):

```systemverilog
// Switch port role
typedef enum int {
    SWITCH_USP,
    SWITCH_DSP
} switch_port_role_e;

// Switch routing result
typedef enum int {
    SWITCH_ROUTE_USP    = 0,    // Forward to upstream port
    SWITCH_ROUTE_LOCAL  = -1,   // Consume locally (switch's own config space)
    SWITCH_ROUTE_DROP   = -2,   // Drop (no route found from USP)
    SWITCH_ROUTE_BCAST  = -3    // Broadcast to all DSPs
} switch_route_special_e;

// Switch route table entry (per port)
typedef struct {
    bit [7:0]  primary_bus;
    bit [7:0]  secondary_bus;
    bit [7:0]  subordinate_bus;
    bit [31:0] mem_base;        // [31:20] significant, 1MB aligned
    bit [31:0] mem_limit;       // [31:20] significant
    bit [63:0] pref_base;       // prefetchable
    bit [63:0] pref_limit;
    bit [15:0] io_base;         // [15:12] significant, 4KB aligned
    bit [15:0] io_limit;
} switch_route_entry_t;
```

- [ ] **Step 2: Create switch config object**

Create `pcie_tl_vip/src/switch/pcie_tl_switch_config.sv`:

```systemverilog
//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Switch Configuration
//-----------------------------------------------------------------------------

class pcie_tl_switch_config extends uvm_object;
    `uvm_object_utils(pcie_tl_switch_config)

    //--- Topology ---
    int num_ds_ports = 4;               // 1-16 downstream ports

    //--- Switch identity ---
    bit [15:0] switch_bdf = 16'h0100;   // Bus 1, Dev 0, Func 0

    //--- Mode ---
    bit enum_mode  = 0;                 // 0=static, 1=enumeration via Config TLP
    bit p2p_enable = 1;                 // Allow DSP-to-DSP direct forwarding

    //--- USP config (static mode) ---
    bit [7:0] usp_primary_bus     = 8'h00;
    bit [7:0] usp_secondary_bus   = 8'h01;
    bit [7:0] usp_subordinate_bus = 8'h0F;

    //--- DSP config arrays (static mode, sized by num_ds_ports) ---
    bit [7:0]  ds_secondary_bus[];
    bit [7:0]  ds_subordinate_bus[];
    bit [31:0] ds_mem_base[];
    bit [31:0] ds_mem_limit[];

    //--- Per-port FC credits ---
    int port_ph_credit   = 32;
    int port_pd_credit   = 256;
    int port_nph_credit  = 32;
    int port_npd_credit  = 256;
    int port_cplh_credit = 32;
    int port_cpld_credit = 256;

    //--- Per-port link delay ---
    bit port_link_delay_enable = 0;
    int port_latency_min_ns    = 0;
    int port_latency_max_ns    = 0;

    function new(string name = "pcie_tl_switch_config");
        super.new(name);
    endfunction

    // Initialize DSP arrays with sensible defaults
    // Call after setting num_ds_ports
    function void init_defaults();
        ds_secondary_bus   = new[num_ds_ports];
        ds_subordinate_bus = new[num_ds_ports];
        ds_mem_base        = new[num_ds_ports];
        ds_mem_limit       = new[num_ds_ports];

        for (int i = 0; i < num_ds_ports; i++) begin
            ds_secondary_bus[i]   = usp_secondary_bus + 1 + i;
            ds_subordinate_bus[i] = ds_secondary_bus[i];
            // 256MB per EP, starting at 0x8000_0000
            ds_mem_base[i]  = 32'h8000_0000 + (i * 32'h1000_0000);
            ds_mem_limit[i] = ds_mem_base[i] + 32'h0FFF_FFFF;
        end
        // Update USP subordinate to cover all DSPs
        usp_subordinate_bus = ds_subordinate_bus[num_ds_ports - 1];
    endfunction

endclass
```

- [ ] **Step 3: Commit**

```
git add pcie_tl_vip/src/types/pcie_tl_types.sv pcie_tl_vip/src/switch/pcie_tl_switch_config.sv
git commit -m "feat: add switch types and config object"
```

---

### Task 2: Switch Port

**Files:**
- Create: `pcie_tl_vip/src/switch/pcie_tl_switch_port.sv`

- [ ] **Step 1: Create switch port**

```systemverilog
//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Switch Port (USP/DSP)
//-----------------------------------------------------------------------------

class pcie_tl_switch_port extends uvm_component;
    `uvm_component_utils(pcie_tl_switch_port)

    //--- Port identity ---
    switch_port_role_e  role;
    int                 port_id;     // 0=USP, 1..N=DSP

    //--- TLM FIFOs ---
    uvm_tlm_fifo #(pcie_tl_tlp) rx_fifo;   // TLPs arriving at this port
    uvm_tlm_fifo #(pcie_tl_tlp) tx_fifo;   // TLPs departing from this port

    //--- Type 1 Config Space ---
    switch_route_entry_t route_entry;

    //--- Per-port FC ---
    pcie_tl_fc_manager fc_mgr;

    //--- Per-port Link Delay ---
    pcie_tl_link_delay_model ingress_delay;
    pcie_tl_link_delay_model egress_delay;

    //--- Statistics ---
    int forwarded_count = 0;
    int dropped_count   = 0;

    function new(string name = "pcie_tl_switch_port", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        rx_fifo       = new("rx_fifo", this, 256);
        tx_fifo       = new("tx_fifo", this, 256);
        fc_mgr        = pcie_tl_fc_manager::type_id::create($sformatf("fc_mgr_p%0d", port_id));
        ingress_delay = pcie_tl_link_delay_model::type_id::create(
                            $sformatf("ingress_delay_p%0d", port_id), this);
        egress_delay  = pcie_tl_link_delay_model::type_id::create(
                            $sformatf("egress_delay_p%0d", port_id), this);
    endfunction

    // Apply static config from pcie_tl_switch_config
    function void apply_config(pcie_tl_switch_config sw_cfg, int idx);
        if (role == SWITCH_USP) begin
            route_entry.primary_bus     = sw_cfg.usp_primary_bus;
            route_entry.secondary_bus   = sw_cfg.usp_secondary_bus;
            route_entry.subordinate_bus = sw_cfg.usp_subordinate_bus;
            route_entry.mem_base  = 0;
            route_entry.mem_limit = 0;
        end else begin
            route_entry.primary_bus     = sw_cfg.usp_secondary_bus;
            route_entry.secondary_bus   = sw_cfg.ds_secondary_bus[idx];
            route_entry.subordinate_bus = sw_cfg.ds_subordinate_bus[idx];
            route_entry.mem_base        = sw_cfg.ds_mem_base[idx];
            route_entry.mem_limit       = sw_cfg.ds_mem_limit[idx];
        end

        fc_mgr.fc_enable       = 1;
        fc_mgr.infinite_credit = 0;
        fc_mgr.init_credits(sw_cfg.port_ph_credit, sw_cfg.port_pd_credit,
                            sw_cfg.port_nph_credit, sw_cfg.port_npd_credit,
                            sw_cfg.port_cplh_credit, sw_cfg.port_cpld_credit);

        ingress_delay.enable         = sw_cfg.port_link_delay_enable;
        ingress_delay.latency_min_ns = sw_cfg.port_latency_min_ns;
        ingress_delay.latency_max_ns = sw_cfg.port_latency_max_ns;
        egress_delay.enable          = sw_cfg.port_link_delay_enable;
        egress_delay.latency_min_ns  = sw_cfg.port_latency_min_ns;
        egress_delay.latency_max_ns  = sw_cfg.port_latency_max_ns;
    endfunction

    // Type 1 Config Space read (for enumeration mode)
    function bit [31:0] cfg_read(bit [11:0] addr);
        case (addr)
            12'h018: return {route_entry.subordinate_bus,
                             route_entry.secondary_bus,
                             route_entry.primary_bus, 8'h0};
            12'h020: return {route_entry.mem_limit[31:20], 4'h0,
                             route_entry.mem_base[31:20], 4'h0};
            default: return 32'h0;
        endcase
    endfunction

    // Type 1 Config Space write (for enumeration mode)
    function void cfg_write(bit [11:0] addr, bit [31:0] data, bit [3:0] be);
        case (addr)
            12'h018: begin
                if (be[1]) route_entry.primary_bus     = data[15:8];
                if (be[2]) route_entry.secondary_bus   = data[23:16];
                if (be[3]) route_entry.subordinate_bus = data[31:24];
            end
            12'h020: begin
                if (be[0] || be[1]) route_entry.mem_base[31:20]  = data[15:4];
                if (be[2] || be[3]) route_entry.mem_limit[31:20] = data[31:20];
            end
        endcase
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info(get_name(), $sformatf(
            "\n===== Switch Port %0d (%s) =====\n  Bus: pri=%0d sec=%0d sub=%0d\n  Mem: [0x%08h - 0x%08h]\n  Forwarded: %0d  Dropped: %0d\n================================",
            port_id, role.name(),
            route_entry.primary_bus, route_entry.secondary_bus, route_entry.subordinate_bus,
            route_entry.mem_base, route_entry.mem_limit,
            forwarded_count, dropped_count), UVM_LOW)
    endfunction

endclass
```

- [ ] **Step 2: Commit**

```
git add pcie_tl_vip/src/switch/pcie_tl_switch_port.sv
git commit -m "feat: add switch port with Type 1 config space"
```

---

### Task 3: Switch Fabric (Routing Engine)

**Files:**
- Create: `pcie_tl_vip/src/switch/pcie_tl_switch_fabric.sv`

- [ ] **Step 1: Create routing fabric**

```systemverilog
//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Switch Routing Fabric
//-----------------------------------------------------------------------------

class pcie_tl_switch_fabric extends uvm_object;
    `uvm_object_utils(pcie_tl_switch_fabric)

    //--- Port references (set by pcie_tl_switch) ---
    pcie_tl_switch_port ports[];   // [0]=USP, [1..N]=DSP
    int num_ports;                 // 1 + num_ds_ports

    //--- Config ---
    bit p2p_enable = 1;

    function new(string name = "pcie_tl_switch_fabric");
        super.new(name);
    endfunction

    //=========================================================================
    // Main routing function: returns egress port_id
    // Returns: 0=USP, 1..N=DSP, or SWITCH_ROUTE_LOCAL/DROP/BCAST
    //=========================================================================
    function int route(pcie_tl_tlp tlp, int ingress_port_id);
        // 1. Completion routing (ID-based)
        if (tlp.get_category() == TLP_CAT_COMPLETION) begin
            pcie_tl_cpl_tlp cpl;
            if ($cast(cpl, tlp))
                return route_by_id(cpl.requester_id[15:8], ingress_port_id);
        end

        // 2. Config routing (ID-based)
        if (tlp.kind inside {TLP_CFG_RD0, TLP_CFG_WR0, TLP_CFG_RD1, TLP_CFG_WR1}) begin
            pcie_tl_cfg_tlp cfg_tlp;
            if ($cast(cfg_tlp, tlp)) begin
                bit [7:0] target_bus = cfg_tlp.completer_id[15:8];
                // Check if targeting the switch itself
                if (target_bus == ports[0].route_entry.secondary_bus)
                    return SWITCH_ROUTE_LOCAL;
                return route_by_id(target_bus, ingress_port_id);
            end
        end

        // 3. Memory/IO routing (address-based)
        if (tlp.kind inside {TLP_MEM_RD, TLP_MEM_RD_LK, TLP_MEM_WR,
                             TLP_IO_RD, TLP_IO_WR}) begin
            pcie_tl_mem_tlp mem_tlp;
            pcie_tl_io_tlp  io_tlp;
            bit [63:0] addr;

            if ($cast(mem_tlp, tlp))
                addr = mem_tlp.addr;
            else if ($cast(io_tlp, tlp))
                addr = {32'h0, io_tlp.addr};
            else
                addr = 0;

            return route_by_address(addr, ingress_port_id);
        end

        // 4. Message routing (implicit)
        if (tlp.kind inside {TLP_MSG, TLP_MSGD}) begin
            return route_message(tlp, ingress_port_id);
        end

        // 5. Default: upstream if from DSP, drop if from USP
        if (ingress_port_id > 0)
            return SWITCH_ROUTE_USP;
        return SWITCH_ROUTE_DROP;
    endfunction

    //=========================================================================
    // ID-based routing: find port whose secondary-subordinate range contains bus
    //=========================================================================
    protected function int route_by_id(bit [7:0] target_bus, int ingress_port_id);
        for (int i = 1; i < num_ports; i++) begin
            if (target_bus >= ports[i].route_entry.secondary_bus &&
                target_bus <= ports[i].route_entry.subordinate_bus) begin
                if (ingress_port_id > 0 && i != ingress_port_id && !p2p_enable)
                    return SWITCH_ROUTE_USP;
                return i;
            end
        end
        if (ingress_port_id > 0)
            return SWITCH_ROUTE_USP;
        return SWITCH_ROUTE_DROP;
    endfunction

    //=========================================================================
    // Address-based routing: find port whose memory window contains addr
    //=========================================================================
    protected function int route_by_address(bit [63:0] addr, int ingress_port_id);
        for (int i = 1; i < num_ports; i++) begin
            if (addr >= {32'h0, ports[i].route_entry.mem_base} &&
                addr <= {32'h0, ports[i].route_entry.mem_limit}) begin
                if (ingress_port_id > 0 && i != ingress_port_id && !p2p_enable)
                    return SWITCH_ROUTE_USP;
                return i;
            end
        end
        if (ingress_port_id > 0)
            return SWITCH_ROUTE_USP;
        return SWITCH_ROUTE_DROP;
    endfunction

    //=========================================================================
    // Message routing
    //=========================================================================
    protected function int route_message(pcie_tl_tlp tlp, int ingress_port_id);
        case (tlp.type_f)
            TLP_TYPE_MSG_BCAST:  return SWITCH_ROUTE_BCAST;
            TLP_TYPE_MSG_LOCAL:  return SWITCH_ROUTE_LOCAL;
            TLP_TYPE_MSG_RC:     return SWITCH_ROUTE_USP;
            TLP_TYPE_MSG_ADDR: begin
                pcie_tl_msg_tlp msg;
                if ($cast(msg, tlp))
                    return route_by_address(msg.msg_addr, ingress_port_id);
            end
            TLP_TYPE_MSG_ID: begin
                pcie_tl_msg_tlp msg;
                if ($cast(msg, tlp))
                    return route_by_id(msg.target_id[15:8], ingress_port_id);
            end
            default: begin
                if (ingress_port_id > 0) return SWITCH_ROUTE_USP;
                return SWITCH_ROUTE_BCAST;
            end
        endcase
        return SWITCH_ROUTE_USP;
    endfunction

endclass
```

- [ ] **Step 2: Commit**

```
git add pcie_tl_vip/src/switch/pcie_tl_switch_fabric.sv
git commit -m "feat: add switch routing fabric (address/ID/message)"
```

---

### Task 4: Switch Top-Level Component

**Files:**
- Create: `pcie_tl_vip/src/switch/pcie_tl_switch.sv`

- [ ] **Step 1: Create switch top-level**

```systemverilog
//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Switch Top-Level
//-----------------------------------------------------------------------------

class pcie_tl_switch extends uvm_component;
    `uvm_component_utils(pcie_tl_switch)

    //--- Configuration ---
    pcie_tl_switch_config  sw_cfg;

    //--- Ports ---
    pcie_tl_switch_port    usp;
    pcie_tl_switch_port    dsp[];

    //--- All ports flat array for fabric ---
    pcie_tl_switch_port    all_ports[];

    //--- Routing Fabric ---
    pcie_tl_switch_fabric  fabric;

    //--- Statistics ---
    int total_routed   = 0;
    int total_dropped  = 0;
    int total_p2p      = 0;
    int total_bcast    = 0;

    function new(string name = "pcie_tl_switch", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        int n;
        super.build_phase(phase);

        if (sw_cfg == null)
            `uvm_fatal("SWITCH", "sw_cfg is null")

        n = sw_cfg.num_ds_ports;

        usp = pcie_tl_switch_port::type_id::create("usp", this);
        usp.role    = SWITCH_USP;
        usp.port_id = 0;

        dsp = new[n];
        for (int i = 0; i < n; i++) begin
            dsp[i] = pcie_tl_switch_port::type_id::create($sformatf("dsp_%0d", i), this);
            dsp[i].role    = SWITCH_DSP;
            dsp[i].port_id = i + 1;
        end

        all_ports = new[n + 1];
        all_ports[0] = usp;
        for (int i = 0; i < n; i++)
            all_ports[i + 1] = dsp[i];

        fabric = pcie_tl_switch_fabric::type_id::create("fabric");
        fabric.ports      = all_ports;
        fabric.num_ports  = n + 1;
        fabric.p2p_enable = sw_cfg.p2p_enable;
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (!sw_cfg.enum_mode) begin
            usp.apply_config(sw_cfg, 0);
            for (int i = 0; i < sw_cfg.num_ds_ports; i++)
                dsp[i].apply_config(sw_cfg, i);
        end
    endfunction

    task run_phase(uvm_phase phase);
        fork
            usp_forward_loop();
            for (int i = 0; i < sw_cfg.num_ds_ports; i++) begin
                automatic int idx = i;
                fork
                    dsp_forward_loop(idx);
                join_none
            end
        join_none
    endtask

    protected task usp_forward_loop();
        pcie_tl_tlp tlp;
        forever begin
            usp.rx_fifo.get(tlp);
            route_and_forward(tlp, 0);
        end
    endtask

    protected task dsp_forward_loop(int port_idx);
        pcie_tl_tlp tlp;
        forever begin
            dsp[port_idx].rx_fifo.get(tlp);
            route_and_forward(tlp, port_idx + 1);
        end
    endtask

    protected task route_and_forward(pcie_tl_tlp tlp, int ingress_port_id);
        int dst = fabric.route(tlp, ingress_port_id);

        case (dst)
            SWITCH_ROUTE_LOCAL: begin
                handle_local_config(tlp, ingress_port_id);
            end
            SWITCH_ROUTE_DROP: begin
                total_dropped++;
                all_ports[ingress_port_id].dropped_count++;
                `uvm_info("SWITCH", $sformatf("DROPPED from port %0d: %s",
                    ingress_port_id, tlp.convert2string()), UVM_MEDIUM)
            end
            SWITCH_ROUTE_BCAST: begin
                total_bcast++;
                for (int i = 1; i <= sw_cfg.num_ds_ports; i++) begin
                    if (i != ingress_port_id) begin
                        all_ports[i].tx_fifo.put(tlp);
                        all_ports[i].forwarded_count++;
                    end
                end
            end
            default: begin
                if (dst >= 0 && dst < all_ports.size() && dst != ingress_port_id) begin
                    all_ports[dst].tx_fifo.put(tlp);
                    all_ports[dst].forwarded_count++;
                    total_routed++;
                    if (ingress_port_id > 0 && dst > 0)
                        total_p2p++;
                end else begin
                    total_dropped++;
                    `uvm_warning("SWITCH", $sformatf("Bad route dst=%0d from port %0d",
                        dst, ingress_port_id))
                end
            end
        endcase
    endtask

    protected task handle_local_config(pcie_tl_tlp tlp, int ingress_port_id);
        pcie_tl_cfg_tlp cfg_tlp;
        pcie_tl_cpl_tlp cpl;

        if (!$cast(cfg_tlp, tlp)) return;

        begin
            int dev_num = cfg_tlp.completer_id[7:3];
            int target_port = (dev_num < all_ports.size()) ? dev_num : 0;

            if (tlp.kind inside {TLP_CFG_RD0, TLP_CFG_RD1}) begin
                bit [31:0] data = all_ports[target_port].cfg_read({cfg_tlp.reg_num, 2'b00});
                cpl = pcie_tl_cpl_tlp::type_id::create("sw_cfg_cpl");
                cpl.kind         = TLP_CPLD;
                cpl.fmt          = FMT_3DW_WITH_DATA;
                cpl.type_f       = TLP_TYPE_CPL;
                cpl.tc           = tlp.tc;
                cpl.attr         = tlp.attr;
                cpl.length       = 1;
                cpl.requester_id = tlp.requester_id;
                cpl.tag          = tlp.tag;
                cpl.completer_id = sw_cfg.switch_bdf;
                cpl.cpl_status   = CPL_STATUS_SC;
                cpl.byte_count   = 4;
                cpl.lower_addr   = {cfg_tlp.reg_num[0], 2'b00};
                cpl.payload      = new[4];
                cpl.payload[0]   = data[7:0];
                cpl.payload[1]   = data[15:8];
                cpl.payload[2]   = data[23:16];
                cpl.payload[3]   = data[31:24];
                all_ports[ingress_port_id].tx_fifo.put(cpl);
            end else begin
                bit [31:0] data = 0;
                if (tlp.payload.size() >= 4)
                    data = {tlp.payload[3], tlp.payload[2], tlp.payload[1], tlp.payload[0]};
                all_ports[target_port].cfg_write({cfg_tlp.reg_num, 2'b00}, data, cfg_tlp.first_be);
                cpl = pcie_tl_cpl_tlp::type_id::create("sw_cfg_cpl");
                cpl.kind         = TLP_CPL;
                cpl.fmt          = FMT_3DW_NO_DATA;
                cpl.type_f       = TLP_TYPE_CPL;
                cpl.tc           = tlp.tc;
                cpl.attr         = tlp.attr;
                cpl.length       = 0;
                cpl.requester_id = tlp.requester_id;
                cpl.tag          = tlp.tag;
                cpl.completer_id = sw_cfg.switch_bdf;
                cpl.cpl_status   = CPL_STATUS_SC;
                cpl.byte_count   = 0;
                cpl.lower_addr   = 0;
                all_ports[ingress_port_id].tx_fifo.put(cpl);
            end
        end
    endtask

    function void report_phase(uvm_phase phase);
        `uvm_info("SWITCH", $sformatf(
            "\n============ Switch Report ============\n  Ports: 1 USP + %0d DSP\n  Total routed:  %0d\n  Total P2P:     %0d\n  Total bcast:   %0d\n  Total dropped: %0d\n=======================================",
            sw_cfg.num_ds_ports, total_routed, total_p2p, total_bcast, total_dropped), UVM_LOW)
    endfunction

endclass
```

- [ ] **Step 2: Commit**

```
git add pcie_tl_vip/src/switch/pcie_tl_switch.sv
git commit -m "feat: add switch top-level with forwarding loops"
```

---

### Task 5: Package Include and Env Config Extension

**Files:**
- Modify: `pcie_tl_vip/src/pcie_tl_pkg.sv` (insert after adapter section, line 24)
- Modify: `pcie_tl_vip/src/env/pcie_tl_env_config.sv` (insert before `function new`, line 78)

- [ ] **Step 1: Add switch includes to pcie_tl_pkg.sv**

Insert after line 24 (`adapter/pcie_tl_if_adapter.sv`), before `//--- Agent ---`:

```systemverilog
    //--- Switch ---
    `include "switch/pcie_tl_switch_config.sv"
    `include "switch/pcie_tl_switch_port.sv"
    `include "switch/pcie_tl_switch_fabric.sv"
    `include "switch/pcie_tl_switch.sv"
```

- [ ] **Step 2: Add switch fields to pcie_tl_env_config.sv**

Insert before the `function new` (before line 78):

```systemverilog
    //--- Switch ---
    bit                    switch_enable = 0;
    pcie_tl_switch_config  switch_cfg;
```

- [ ] **Step 3: Commit**

```
git add pcie_tl_vip/src/pcie_tl_pkg.sv pcie_tl_vip/src/env/pcie_tl_env_config.sv
git commit -m "feat: add switch package includes and env config extension"
```

---

### Task 6: Env Integration (Multi-EP + Switch Wiring)

**Files:**
- Modify: `pcie_tl_vip/src/env/pcie_tl_env.sv`

- [ ] **Step 1: Add multi-EP members**

After the existing `ep_adapter` declaration (after line 29), add:

```systemverilog
    //--- Multi-EP (switch mode) ---
    pcie_tl_switch         sw;
    pcie_tl_ep_agent       ep_agents[];
    pcie_tl_if_adapter     ep_adapters[];
```

- [ ] **Step 2: Extend build_phase for switch mode**

After the existing `if (cfg.ep_agent_enable)` block (after line 79), add:

```systemverilog
        // 4b. Switch mode: create switch + N EP agents
        if (cfg.switch_enable && cfg.switch_cfg != null) begin
            int n = cfg.switch_cfg.num_ds_ports;
            cfg.switch_cfg.init_defaults();

            sw = pcie_tl_switch::type_id::create("sw", this);
            sw.sw_cfg = cfg.switch_cfg;

            ep_agents  = new[n];
            ep_adapters = new[n];
            for (int i = 0; i < n; i++) begin
                uvm_config_db#(uvm_active_passive_enum)::set(
                    this, $sformatf("ep_agent_%0d", i), "is_active", cfg.ep_is_active);
                ep_agents[i]  = pcie_tl_ep_agent::type_id::create(
                    $sformatf("ep_agent_%0d", i), this);
                ep_adapters[i] = pcie_tl_if_adapter::type_id::create(
                    $sformatf("ep_adapter_%0d", i), this);
            end
        end
```

- [ ] **Step 3: Extend connect_phase for switch mode**

After the existing coverage connections (after line 155), add:

```systemverilog
        // 7. Switch mode wiring
        if (cfg.switch_enable && sw != null) begin
            for (int i = 0; i < cfg.switch_cfg.num_ds_ports; i++) begin
                ep_agents[i].fc_mgr    = sw.dsp[i].fc_mgr;
                ep_agents[i].tag_mgr   = tag_mgr;
                ep_agents[i].ord_eng   = ord_eng;
                ep_agents[i].cfg_mgr   = cfg_mgr;
                ep_agents[i].bw_shaper = bw_shaper;
                ep_agents[i].codec     = codec;
                ep_agents[i].adapter   = ep_adapters[i];
                ep_agents[i].inject_shared_components();
                if (ep_agents[i].ep_driver != null) begin
                    ep_agents[i].ep_driver.mps_bytes = int'(cfg.max_payload_size);
                    ep_agents[i].ep_driver.rcb_bytes = int'(cfg.read_completion_boundary);
                end
                ep_adapters[i].mode   = cfg.if_mode;
                ep_adapters[i].codec  = codec;
                ep_adapters[i].fc_mgr = sw.dsp[i].fc_mgr;
            end
        end
```

- [ ] **Step 4: Replace run_phase with switch-aware version**

Replace the existing `run_phase` task with:

```systemverilog
    task run_phase(uvm_phase phase);
        if (cfg.if_mode == TLM_MODE && rc_agent != null) begin
            if (cfg.switch_enable && sw != null) begin
                fork
                    rc_to_switch_loopback();
                    switch_to_rc_loopback();
                    for (int i = 0; i < cfg.switch_cfg.num_ds_ports; i++) begin
                        automatic int idx = i;
                        fork
                            switch_to_ep_loopback(idx);
                            ep_to_switch_loopback(idx);
                        join_none
                    end
                join_none
            end else if (ep_agent != null) begin
                fork
                    tlm_loopback_rc_to_ep();
                    tlm_loopback_ep_to_rc();
                join_none
            end
        end
    endtask
```

- [ ] **Step 5: Add switch loopback tasks**

Add after the existing `rc_auto_respond` task:

```systemverilog
    //=========================================================================
    // Switch Mode Loopback Tasks
    //=========================================================================

    protected task rc_to_switch_loopback();
        pcie_tl_tlp tlp;
        forever begin
            rc_adapter.tlm_tx_fifo.get(tlp);
            if (scb != null && tlp.requires_completion())
                scb.register_pending(tlp);
            sw.usp.rx_fifo.put(tlp);
        end
    endtask

    protected task switch_to_rc_loopback();
        pcie_tl_tlp tlp;
        forever begin
            sw.usp.tx_fifo.get(tlp);
            rc_adapter.tlm_rx_fifo.put(tlp);
            replenish_credits(tlp);
            if (tlp.get_category() == TLP_CAT_COMPLETION) begin
                if (scb != null)
                    scb.write_rc(tlp);
                if (rc_agent.rc_driver != null) begin
                    pcie_tl_cpl_tlp cpl;
                    if ($cast(cpl, tlp))
                        void'(rc_agent.rc_driver.handle_completion(cpl));
                end
            end
        end
    endtask

    protected task switch_to_ep_loopback(int idx);
        pcie_tl_tlp tlp;
        forever begin
            sw.dsp[idx].tx_fifo.get(tlp);
            ep_adapters[idx].tlm_rx_fifo.put(tlp);
            replenish_credits(tlp);
            if (cfg.ep_auto_response && ep_agents[idx].ep_driver != null) begin
                if (tlp.kind inside {TLP_MEM_RD, TLP_MEM_RD_LK, TLP_MEM_WR,
                                     TLP_CFG_RD0, TLP_CFG_WR0, TLP_IO_RD, TLP_IO_WR}) begin
                    fork
                        begin
                            automatic pcie_tl_tlp t = tlp;
                            automatic int i = idx;
                            ep_agents[i].ep_driver.handle_request(t);
                        end
                    join_none
                end
            end
        end
    endtask

    protected task ep_to_switch_loopback(int idx);
        pcie_tl_tlp tlp;
        forever begin
            ep_adapters[idx].tlm_tx_fifo.get(tlp);
            sw.dsp[idx].rx_fifo.put(tlp);
        end
    endtask
```

- [ ] **Step 6: Compile and regression test**

```bash
# Compile with switch include path
vcs ... +incdir+src/switch ...
# Run existing Test 9 to verify backward compatibility
./simv +UVM_TESTNAME=pcie_tl_bidir_traffic_test +UVM_VERBOSITY=UVM_LOW
```

Expected: `*** ALL 10K TRAFFIC CHECKS PASSED ***`

- [ ] **Step 7: Commit**

```
git add pcie_tl_vip/src/env/pcie_tl_env.sv
git commit -m "feat: integrate switch into env with multi-EP and per-port loopback"
```

---

### Task 7: Test 10 -- Switch Basic Routing

**Files:**
- Modify: `pcie_tl_vip/tests/pcie_tl_advanced_test.sv` (append)

- [ ] **Step 1: Add Test 10**

Append to `pcie_tl_advanced_test.sv`:

```systemverilog
//=============================================================================
// Test 10: Switch Basic Routing -- RC to 4 EPs via Switch
//=============================================================================
class pcie_tl_switch_basic_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_switch_basic_test)

    function new(string name = "pcie_tl_switch_basic_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void configure_test();
        pcie_tl_switch_config sw_cfg;
        super.configure_test();

        sw_cfg = new("sw_cfg");
        sw_cfg.num_ds_ports = 4;
        sw_cfg.p2p_enable   = 1;
        sw_cfg.init_defaults();

        cfg.switch_enable    = 1;
        cfg.switch_cfg       = sw_cfg;
        configure_fc(1, 1);
        cfg.ep_auto_response = 1;
        cfg.cpl_timeout_ns   = 100000;
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info("SW_BASIC", "=== Test 10: Switch Basic Routing (4 EPs) ===", UVM_LOW)

        // Phase 1: RC writes to each EP
        `uvm_info("SW_BASIC", "--- Phase 1: RC writes to EP0-EP3 ---", UVM_LOW)
        for (int ep = 0; ep < 4; ep++) begin
            for (int i = 0; i < 10; i++) begin
                pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create(
                    $sformatf("wr_ep%0d_%0d", ep, i));
                wr.addr     = cfg.switch_cfg.ds_mem_base[ep] + (i * 64);
                wr.length   = 16;
                wr.first_be = 4'hF;
                wr.last_be  = 4'hF;
                wr.is_64bit = 0;
                wr.start(env.rc_agent.sequencer);
                #10ns;
            end
        end
        #2000ns;

        // Phase 2: RC reads from each EP
        `uvm_info("SW_BASIC", "--- Phase 2: RC reads from EP0-EP3 ---", UVM_LOW)
        for (int ep = 0; ep < 4; ep++) begin
            for (int i = 0; i < 5; i++) begin
                pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create(
                    $sformatf("rd_ep%0d_%0d", ep, i));
                rd.addr     = cfg.switch_cfg.ds_mem_base[ep] + (i * 64);
                rd.length   = 8;
                rd.first_be = 4'hF;
                rd.last_be  = 4'hF;
                rd.is_64bit = 0;
                rd.start(env.rc_agent.sequencer);
                #20ns;
            end
        end
        #5000ns;

        `uvm_info("SW_BASIC", $sformatf("Switch routed=%0d, dropped=%0d, P2P=%0d",
            env.sw.total_routed, env.sw.total_dropped, env.sw.total_p2p), UVM_LOW)
        `uvm_info("SW_BASIC", $sformatf("Per-DSP fwd: [%0d, %0d, %0d, %0d]",
            env.sw.dsp[0].forwarded_count, env.sw.dsp[1].forwarded_count,
            env.sw.dsp[2].forwarded_count, env.sw.dsp[3].forwarded_count), UVM_LOW)

        if (env.sw.total_dropped == 0 && env.scb.unexpected == 0)
            `uvm_info("SW_BASIC", "*** SWITCH BASIC ROUTING PASSED ***", UVM_LOW)
        else
            `uvm_error("SW_BASIC", "SWITCH BASIC ROUTING FAILED")

        phase.drop_objection(this);
    endtask
endclass
```

- [ ] **Step 2: Run and commit**

```bash
./simv +UVM_TESTNAME=pcie_tl_switch_basic_test +UVM_VERBOSITY=UVM_LOW -l run_sw_basic.log
git add pcie_tl_vip/tests/pcie_tl_advanced_test.sv
git commit -m "feat: add Test 10 -- switch basic routing"
```

---

### Task 8: Test 11 -- P2P Direct Transfer

**Files:**
- Modify: `pcie_tl_vip/tests/pcie_tl_advanced_test.sv` (append)

- [ ] **Step 1: Add Test 11 and run**

Append `pcie_tl_switch_p2p_test` class: EP0 DMA writes to EP1 address space (20 writes, verify `total_p2p==20`), then disable P2P and verify `total_p2p` doesn't increase for 10 more writes.

- [ ] **Step 2: Commit**

```
git commit -m "feat: add Test 11 -- P2P direct transfer"
```

---

### Task 9: Test 12 -- Switch Enumeration

**Files:**
- Modify: `pcie_tl_vip/tests/pcie_tl_advanced_test.sv` (append)

- [ ] **Step 1: Add Test 12 and run**

Append `pcie_tl_switch_enum_test` class: `enum_mode=1`, manually configure bus/mem windows, send traffic, verify per-DSP forwarded counts.

- [ ] **Step 2: Commit**

```
git commit -m "feat: add Test 12 -- switch enumeration"
```

---

### Task 10: Tests 13-14 -- Stress + FC Isolation

**Files:**
- Modify: `pcie_tl_vip/tests/pcie_tl_advanced_test.sv` (append)

- [ ] **Step 1: Add Test 13 (Multi-EP Stress)**

2000 RC writes (500 per EP concurrent) + 400 EP DMA writes (100 per EP) + 100 P2P cross-traffic. Verify `total_dropped==0`.

- [ ] **Step 2: Add Test 14 (FC Isolation)**

Tight per-port FC (PH=4), exhaust DSP0 via `force_credit_underflow()`, verify DSP1 forwards 20 writes unaffected.

- [ ] **Step 3: Run and commit**

```bash
./simv +UVM_TESTNAME=pcie_tl_switch_stress_test +UVM_VERBOSITY=UVM_LOW
./simv +UVM_TESTNAME=pcie_tl_switch_fc_isolation_test +UVM_VERBOSITY=UVM_LOW
git commit -m "feat: add Tests 13-14 -- switch stress and FC isolation"
```

---

### Task 11: Final Regression and Push

- [ ] **Step 1: Run all switch tests**

```bash
for test in pcie_tl_switch_basic_test pcie_tl_switch_p2p_test pcie_tl_switch_enum_test pcie_tl_switch_stress_test pcie_tl_switch_fc_isolation_test; do
    echo "=== $test ==="
    ./simv +UVM_TESTNAME=$test +UVM_VERBOSITY=UVM_LOW -l run_${test}.log 2>&1 | grep -E "PASS|FAIL|UVM_ERROR"
done
```

- [ ] **Step 2: Regression -- existing tests**

```bash
./simv +UVM_TESTNAME=pcie_tl_bidir_traffic_test +UVM_VERBOSITY=UVM_LOW 2>&1 | grep "ALL.*PASS"
```

- [ ] **Step 3: Push**

```bash
git push origin main
```
