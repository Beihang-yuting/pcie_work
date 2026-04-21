# Link Delay Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a pipeline link delay model to the TLM loopback bridge, simulating configurable per-direction latency with ordering guarantees.

**Architecture:** A new `pcie_tl_link_delay_model` uvm_component is inserted into the RC-EP loopback path. Two instances (rc2ep, ep2rc) independently delay TLP delivery using fork-join_none for pipeline concurrency. Delay values are randomized within a range and updated every N TLPs to preserve ordering.

**Tech Stack:** SystemVerilog, UVM

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `pcie_tl_vip/src/shared/pcie_tl_link_delay_model.sv` | CREATE | Delay model component |
| `pcie_tl_vip/src/pcie_tl_pkg.sv` | MODIFY (line 20) | Add include for new file |
| `pcie_tl_vip/src/env/pcie_tl_env_config.sv` | MODIFY (line 68) | Add 6 delay config parameters |
| `pcie_tl_vip/src/env/pcie_tl_env.sv` | MODIFY (lines 21, 56, 153-200, 228-274) | Create delay models, wire into loopback |
| `pcie_tl_vip/tests/pcie_tl_advanced_test.sv` | MODIFY (append) | Add link delay test case |

---

### Task 1: Create `pcie_tl_link_delay_model` Component

**Files:**
- Create: `pcie_tl_vip/src/shared/pcie_tl_link_delay_model.sv`

- [ ] **Step 1: Create the link delay model file**

```systemverilog
//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Link Delay Model (Pipeline Latency Simulation)
//-----------------------------------------------------------------------------

class pcie_tl_link_delay_model extends uvm_component;
    `uvm_component_utils(pcie_tl_link_delay_model)

    //--- Configuration ---
    bit     enable          = 0;
    int     latency_min_ns  = 0;
    int     latency_max_ns  = 0;
    int     update_interval = 16;

    //--- Runtime state ---
    int      current_latency_ns = 0;
    int      tlp_count          = 0;
    realtime last_arrival_time  = 0;

    //--- Statistics ---
    int      total_forwarded = 0;
    int      total_delayed   = 0;
    int      min_applied_ns  = 0;
    int      max_applied_ns  = 0;
    int      delay_updates   = 0;

    function new(string name = "pcie_tl_link_delay_model", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (latency_min_ns > 0 || latency_max_ns > 0)
            update_latency();
    endfunction

    //=========================================================================
    // Core: Forward TLP through the delay pipeline
    //=========================================================================
    task forward(input pcie_tl_tlp tlp, input uvm_tlm_fifo #(pcie_tl_tlp) dst);
        // Bypass when disabled
        if (!enable) begin
            dst.put(tlp);
            total_forwarded++;
            return;
        end

        // Update delay value every N TLPs
        tlp_count++;
        if (tlp_count >= update_interval) begin
            update_latency();
            tlp_count = 0;
        end

        begin
            // Capture current state for this TLP's forked delay
            int this_latency_ns = current_latency_ns;
            realtime entry_time = $realtime;
            realtime arrival_time = entry_time + this_latency_ns * 1ns;

            // Ordering guard: ensure monotonic arrival
            if (arrival_time <= last_arrival_time)
                arrival_time = last_arrival_time + 1ns;

            last_arrival_time = arrival_time;

            // Track statistics
            total_forwarded++;
            if (this_latency_ns > 0) total_delayed++;
            if (total_delayed == 1 || this_latency_ns < min_applied_ns)
                min_applied_ns = this_latency_ns;
            if (this_latency_ns > max_applied_ns)
                max_applied_ns = this_latency_ns;

            // Pipeline: fork so multiple TLPs can be in-flight
            fork
                begin
                    pcie_tl_tlp fwd_tlp = tlp;
                    realtime fwd_arrival = arrival_time;
                    realtime wait_time = fwd_arrival - $realtime;
                    if (wait_time > 0)
                        #(wait_time);
                    dst.put(fwd_tlp);
                end
            join_none
        end
    endtask

    //=========================================================================
    // Randomize delay value
    //=========================================================================
    function void update_latency();
        if (latency_min_ns == latency_max_ns)
            current_latency_ns = latency_min_ns;
        else
            current_latency_ns = $urandom_range(latency_max_ns, latency_min_ns);
        delay_updates++;
        `uvm_info(get_name(), $sformatf("Delay updated: %0d ns (range: %0d-%0d)",
                  current_latency_ns, latency_min_ns, latency_max_ns), UVM_HIGH)
    endfunction

    //=========================================================================
    // Runtime reconfiguration
    //=========================================================================
    function void set_latency(int min_ns, int max_ns);
        latency_min_ns = min_ns;
        latency_max_ns = max_ns;
        update_latency();
    endfunction

    function void set_update_interval(int n);
        update_interval = n;
    endfunction

    function void force_update();
        update_latency();
        tlp_count = 0;
    endfunction

    function void reset();
        tlp_count          = 0;
        last_arrival_time  = 0;
        total_forwarded    = 0;
        total_delayed      = 0;
        min_applied_ns     = 0;
        max_applied_ns     = 0;
        delay_updates      = 0;
        update_latency();
    endfunction

    //=========================================================================
    // Report Phase
    //=========================================================================
    function void report_phase(uvm_phase phase);
        if (!enable) return;
        `uvm_info(get_name(), $sformatf(
            "\n========== Link Delay Report [%s] ==========\n  Total forwarded:  %0d\n  Total delayed:    %0d\n  Delay range cfg:  %0d-%0d ns\n  Applied range:    %0d-%0d ns\n  Update interval:  %0d TLPs\n  Delay updates:    %0d\n================================================",
            get_name(), total_forwarded, total_delayed,
            latency_min_ns, latency_max_ns,
            min_applied_ns, max_applied_ns,
            update_interval, delay_updates
        ), UVM_LOW)
    endfunction

endclass
```

- [ ] **Step 2: Commit**

```bash
git add pcie_tl_vip/src/shared/pcie_tl_link_delay_model.sv
git commit -m "feat: add pcie_tl_link_delay_model component"
```

---

### Task 2: Add Config Parameters

**Files:**
- Modify: `pcie_tl_vip/src/env/pcie_tl_env_config.sv:68` (before `function new`)

- [ ] **Step 1: Add link delay parameters to env_config**

Insert after the `cpl_timeout_ns` line (line 68) and before `function new`:

```systemverilog
    //--- Link Delay ---
    bit                       link_delay_enable              = 0;
    int                       rc2ep_latency_min_ns           = 0;
    int                       rc2ep_latency_max_ns           = 0;
    int                       ep2rc_latency_min_ns           = 0;
    int                       ep2rc_latency_max_ns           = 0;
    int                       link_delay_update_interval     = 16;
```

- [ ] **Step 2: Commit**

```bash
git add pcie_tl_vip/src/env/pcie_tl_env_config.sv
git commit -m "feat: add link delay config parameters"
```

---

### Task 3: Register in Package

**Files:**
- Modify: `pcie_tl_vip/src/pcie_tl_pkg.sv:20`

- [ ] **Step 1: Add include for link delay model**

Insert after line 20 (`pcie_tl_cfg_space_manager.sv`):

```systemverilog
    `include "shared/pcie_tl_link_delay_model.sv"
```

- [ ] **Step 2: Commit**

```bash
git add pcie_tl_vip/src/pcie_tl_pkg.sv
git commit -m "feat: register link_delay_model in pcie_tl_pkg"
```

---

### Task 4: Integrate into Environment

**Files:**
- Modify: `pcie_tl_vip/src/env/pcie_tl_env.sv:21,56,165-200,228-274`

- [ ] **Step 1: Add delay model members**

After line 31 (`pcie_tl_if_adapter ep_adapter;`), add:

```systemverilog
    //--- Link Delay Models ---
    pcie_tl_link_delay_model   rc2ep_delay;
    pcie_tl_link_delay_model   ep2rc_delay;
```

- [ ] **Step 2: Create delay models in build_phase**

After the adapter creation block (after line 60 `ep_adapter = ...`), add:

```systemverilog
        // 3b. Create link delay models
        rc2ep_delay = pcie_tl_link_delay_model::type_id::create("rc2ep_delay", this);
        ep2rc_delay = pcie_tl_link_delay_model::type_id::create("ep2rc_delay", this);
```

- [ ] **Step 3: Add delay config to apply_config**

At the end of the `apply_config()` function, before the closing `endfunction`, add:

```systemverilog
        // Link Delay
        rc2ep_delay.enable          = cfg.link_delay_enable;
        rc2ep_delay.latency_min_ns  = cfg.rc2ep_latency_min_ns;
        rc2ep_delay.latency_max_ns  = cfg.rc2ep_latency_max_ns;
        rc2ep_delay.update_interval = cfg.link_delay_update_interval;

        ep2rc_delay.enable          = cfg.link_delay_enable;
        ep2rc_delay.latency_min_ns  = cfg.ep2rc_latency_min_ns;
        ep2rc_delay.latency_max_ns  = cfg.ep2rc_latency_max_ns;
        ep2rc_delay.update_interval = cfg.link_delay_update_interval;
```

- [ ] **Step 4: Modify tlm_loopback_rc_to_ep to use delay model**

Replace the line:
```systemverilog
            ep_adapter.tlm_rx_fifo.put(tlp);
```
With:
```systemverilog
            rc2ep_delay.forward(tlp, ep_adapter.tlm_rx_fifo);
```

- [ ] **Step 5: Modify tlm_loopback_ep_to_rc to use delay model**

Replace the line:
```systemverilog
            rc_adapter.tlm_rx_fifo.put(tlp);
```
With:
```systemverilog
            ep2rc_delay.forward(tlp, rc_adapter.tlm_rx_fifo);
```

- [ ] **Step 6: Commit**

```bash
git add pcie_tl_vip/src/env/pcie_tl_env.sv
git commit -m "feat: integrate link delay model into env loopback"
```

---

### Task 5: Add Link Delay Test

**Files:**
- Modify: `pcie_tl_vip/tests/pcie_tl_advanced_test.sv` (append at end)

- [ ] **Step 1: Add link delay test case**

Append to the end of the file:

```systemverilog
//=============================================================================
// Test 8: Link Delay - Pipeline latency simulation
//=============================================================================
class pcie_tl_link_delay_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_link_delay_test)
    function new(string name = "pcie_tl_link_delay_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void configure_test();
        super.configure_test();
        cfg.link_delay_enable          = 1;
        cfg.rc2ep_latency_min_ns       = 2000;
        cfg.rc2ep_latency_max_ns       = 2000;
        cfg.ep2rc_latency_min_ns       = 2000;
        cfg.ep2rc_latency_max_ns       = 2000;
        cfg.link_delay_update_interval = 16;
        cfg.cpl_timeout_ns             = 100000;  // 100us to accommodate delay
        cfg.ep_auto_response           = 1;
        configure_fc(1, 0);
        cfg.init_ph_credit  = 64;
        cfg.init_pd_credit  = 512;
        cfg.init_nph_credit = 64;
        cfg.init_npd_credit = 256;
        cfg.init_cplh_credit = 64;
        cfg.init_cpld_credit = 512;
    endfunction
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);

        // Phase 1: Fixed delay - 10 memory writes, verify pipeline behavior
        `uvm_info("LINK_DELAY", "=== Phase 1: Fixed 2us delay, 10 memory writes ===", UVM_LOW)
        begin
            realtime t_start = $realtime;
            for (int i = 0; i < 10; i++) begin
                pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("dly_wr_%0d", i));
                wr.addr = 64'h0000_0001_0000_0000 + (i * 64);
                wr.length = 4;
                wr.first_be = 4'hF; wr.last_be = 4'hF; wr.is_64bit = 1;
                wr.start(env.rc_agent.sequencer);
                #10ns;
            end
            // Wait for all delayed TLPs to arrive
            #3000ns;
            `uvm_info("LINK_DELAY", $sformatf("Phase 1 done. RC2EP forwarded: %0d, delayed: %0d",
                env.rc2ep_delay.total_forwarded, env.rc2ep_delay.total_delayed), UVM_LOW)
        end

        // Phase 2: Asymmetric delay - RC->EP 2us, EP->RC 1us
        `uvm_info("LINK_DELAY", "=== Phase 2: Asymmetric delay (RC->EP=2us, EP->RC=1us) ===", UVM_LOW)
        begin
            env.rc2ep_delay.set_latency(2000, 2000);
            env.ep2rc_delay.set_latency(1000, 1000);

            // Memory read: request goes RC->EP (2us), completion comes EP->RC (1us)
            // Total round-trip ~3us
            begin
                realtime t_before = $realtime;
                pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create("dly_rd");
                rd.addr = 64'h0000_0001_0000_0000;
                rd.length = 4;
                rd.first_be = 4'hF; rd.last_be = 4'hF; rd.is_64bit = 1;
                rd.start(env.rc_agent.sequencer);
                #5000ns;  // Wait for round-trip
                `uvm_info("LINK_DELAY", $sformatf("Phase 2 done. EP2RC forwarded: %0d",
                    env.ep2rc_delay.total_forwarded), UVM_LOW)
            end
        end

        // Phase 3: Random range with ordering verification
        `uvm_info("LINK_DELAY", "=== Phase 3: Random delay 1500-2500ns, interval=4 ===", UVM_LOW)
        begin
            env.rc2ep_delay.set_latency(1500, 2500);
            env.rc2ep_delay.set_update_interval(4);
            env.ep2rc_delay.set_latency(1500, 2500);
            env.ep2rc_delay.set_update_interval(4);

            for (int i = 0; i < 20; i++) begin
                pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("rnd_wr_%0d", i));
                wr.addr = 64'h0000_0002_0000_0000 + (i * 64);
                wr.length = 4;
                wr.first_be = 4'hF; wr.last_be = 4'hF; wr.is_64bit = 1;
                wr.start(env.rc_agent.sequencer);
                #10ns;
            end
            #4000ns;
            `uvm_info("LINK_DELAY", $sformatf(
                "Phase 3 done. Applied delay range: %0d-%0d ns, updates: %0d",
                env.rc2ep_delay.min_applied_ns, env.rc2ep_delay.max_applied_ns,
                env.rc2ep_delay.delay_updates), UVM_LOW)
        end

        // Phase 4: Disabled mode - verify no extra latency
        `uvm_info("LINK_DELAY", "=== Phase 4: Delay disabled ===", UVM_LOW)
        begin
            int prev_forwarded = env.rc2ep_delay.total_forwarded;
            int prev_delayed   = env.rc2ep_delay.total_delayed;
            env.rc2ep_delay.enable = 0;
            env.ep2rc_delay.enable = 0;

            for (int i = 0; i < 5; i++) begin
                pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("nodly_wr_%0d", i));
                wr.addr = 64'h0000_0003_0000_0000 + (i * 64);
                wr.length = 4;
                wr.first_be = 4'hF; wr.last_be = 4'hF; wr.is_64bit = 1;
                wr.start(env.rc_agent.sequencer);
                #10ns;
            end
            #100ns;
            // When disabled, total_delayed should not increase
            if (env.rc2ep_delay.total_delayed == prev_delayed)
                `uvm_info("LINK_DELAY", "Phase 4 PASS: no delay applied when disabled", UVM_LOW)
            else
                `uvm_error("LINK_DELAY", "Phase 4 FAIL: delay applied when disabled")
        end

        #200ns;
        `uvm_info("LINK_DELAY", "=== Link Delay Test Complete ===", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
```

- [ ] **Step 2: Commit**

```bash
git add pcie_tl_vip/tests/pcie_tl_advanced_test.sv
git commit -m "test: add link delay verification test"
```

---

### Task 6: Final Integration Commit

- [ ] **Step 1: Verify all files are consistent**

Check that the include order in `pcie_tl_pkg.sv` places `pcie_tl_link_delay_model.sv` after `pcie_tl_cfg_space_manager.sv` and before the Adapter section, since the delay model depends on `pcie_tl_tlp` (from types) and `uvm_tlm_fifo` (from UVM) but not on any agent or env components.

- [ ] **Step 2: Final commit with all changes**

```bash
git add -A pcie_tl_vip/
git commit -m "feat: complete link delay model integration

- New pcie_tl_link_delay_model component with pipeline delay
- Per-direction configurable latency (RC->EP, EP->RC)
- Random range with periodic update and ordering guarantee
- Runtime reconfiguration API (set_latency, set_update_interval, force_update)
- Statistics reporting in report_phase
- Test coverage: fixed, asymmetric, random, disabled modes"
```
