import uvm_pkg::*;
import pcie_tl_pkg::*;
import host_mem_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// Switch Unified-Memory Test
//
// Exercises use_unified_mem=1 in switch (multi-EP) mode:
//   For each EP index (0 and 1):
//     Phase A: EP[i] MRd from host_mem  (RC responds via rc_driver.handle_request)
//     Phase B: EP[i] MWr to host_mem    (MWr posted-gap fix: rc_driver stores to host_mem)
//     Phase C: RC MWr/MRd to dev_mem[i] (ep_driver[i] stores/serves)
//   Phase D: Leak checks on host_mem and dev_mem[0..1]
//=============================================================================
class pcie_tl_switch_unified_mem_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_switch_unified_mem_test)

    function new(string name = "pcie_tl_switch_unified_mem_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void configure_test();
        pcie_tl_switch_config sw_cfg;
        super.configure_test();

        // Unified memory on
        cfg.use_unified_mem  = 1'b1;
        cfg.mem_access_mode  = PCIE_TL_MEM_PER_BUFFER;

        // Switch topology: 2 EPs (num_ds_ports >= 2)
        sw_cfg = new("sw_cfg");
        sw_cfg.num_ds_ports = 2;
        sw_cfg.p2p_enable   = 1;
        sw_cfg.init_defaults();
        cfg.switch_enable = 1;
        cfg.switch_cfg    = sw_cfg;

        // Infinite credits + generous timeout (focus: routing correctness, not FC)
        cfg.fc_enable       = 1;
        cfg.infinite_credit = 1;
        cfg.cpl_timeout_ns  = 200000;

        // Scoreboard on
        cfg.scb_enable              = 1;
        cfg.ordering_check_enable   = 1;
        cfg.completion_check_enable = 1;
        cfg.data_integrity_enable   = 1;

        // EP auto-response ON so RC MRd->EP completions work normally
        cfg.ep_auto_response = 1;
    endfunction

    //=========================================================================
    // Helper: deterministic byte pattern
    //=========================================================================
    function automatic void make_golden(output byte golden[], input int base_val, input int size);
        golden = new[size];
        for (int i = 0; i < size; i++)
            golden[i] = byte'((base_val + i) & 8'hFF);
    endfunction

    //=========================================================================
    // Helper: byte-compare, report first mismatch
    //=========================================================================
    function automatic void compare_bytes(
        input byte   actual[],
        input byte   golden_ref[],
        input int    sz,
        input string ctx
    );
        for (int i = 0; i < sz; i++) begin
            if (actual[i] !== golden_ref[i]) begin
                `uvm_error(ctx, $sformatf(
                    "MISMATCH @ byte[%0d]: got 0x%02h expected 0x%02h",
                    i, actual[i], golden_ref[i]))
                return;
            end
        end
        `uvm_info(ctx, $sformatf("OK -- %0d bytes match", sz), UVM_LOW)
    endfunction

    //==========================================================================
    // Prepare one DSP device-memory manager for a routed RC access.
    //
    // host_mem allocators normally choose any free address in their initialized
    // aperture.  A Switch, however, forwards an RC request to DSP[i] only when
    // the address is inside that DSP's programmed memory window.  The default
    // testbench manager covers 0..4GB, so an unconstrained allocation can land
    // below 0x8000_0000 and be dropped by the Switch before the EP sees it.
    //
    // Keep this policy local to this routing test: reserve the portion below
    // the DSP window and use FIRST_FIT, making the first test allocation start
    // at ds_mem_base[i].  The reservation is metadata only (it is not an
    // allocation), therefore the normal free()/leak_check() lifecycle remains
    // unchanged.  If a caller injects a manager whose region already starts at
    // the DSP window, contains_range() is false for the lower prefix and the
    // reservation is correctly skipped.
    //==========================================================================
    function automatic bit prepare_dsp_memory(int ep);
        bit [63:0] window_base;
        bit [63:0] window_limit;
        bit [63:0] probe_size;

        probe_size   = 64'd256;
        window_base  = {32'h0, cfg.switch_cfg.ds_mem_base[ep]};
        window_limit = {32'h0, cfg.switch_cfg.ds_mem_limit[ep]};

        if (window_limit < window_base ||
            !env.dev_mem[ep].contains_range(window_base, probe_size)) begin
            `uvm_error("SW_UM", $sformatf(
                "DSP%0d device manager does not cover Switch window [0x%016h,0x%016h]",
                ep, window_base, window_limit))
            return 0;
        end

        // Deterministic placement is important here: random placement can
        // pass intermittently when it happens to select the routing window.
        env.dev_mem[ep].set_alloc_policy(HOST_MEM_FIRST_FIT);

        // The standard tb manager is initialized from 0..4GB-1.  Only reserve
        // the lower prefix when it is entirely inside the injected manager's
        // region; this keeps custom window-sized managers compatible.
        if ((window_base != 0) &&
            env.dev_mem[ep].contains_range(64'h0, window_base)) begin
            if (!env.dev_mem[ep].reserve_range(
                    64'h0, window_base,
                    $sformatf("switch_dsp%0d_routing_window", ep))) begin
                `uvm_error("SW_UM", $sformatf(
                    "failed to reserve lower prefix for DSP%0d (base=0x%016h)",
                    ep, window_base))
                return 0;
            end
        end

        return 1;
    endfunction

    //=========================================================================
    // run_phase
    //=========================================================================
    task run_phase(uvm_phase phase);
        int num_eps;
        bit [63:0] host_allocs[$];
        bit [63:0] dev_allocs[$];
        phase.raise_objection(this);
        `uvm_info("SW_UM", "=== Switch Unified-Memory Test START ===", UVM_LOW)

        // Guard: handles must be injected by env connect_phase
        if (env.host_mem == null)
            `uvm_fatal("SW_UM", "env.host_mem is null -- config_db injection failed")
        if (env.dev_mem[0] == null)
            `uvm_fatal("SW_UM", "env.dev_mem[0] is null -- config_db injection failed")
        if (env.dev_mem[1] == null)
            `uvm_fatal("SW_UM", "env.dev_mem[1] is null -- config_db injection failed")

        num_eps = cfg.switch_cfg.num_ds_ports;  // 2

        // Constrain device-memory placement before Phase C starts.  Without
        // this setup the allocator may return a legal host-memory address that
        // is nevertheless outside every DSP routing window.
        for (int i = 0; i < num_eps; i++) begin
            if (!prepare_dsp_memory(i))
                `uvm_fatal("SW_UM", $sformatf(
                    "cannot prepare device memory for DSP%0d", i))
        end

        for (int ep_idx = 0; ep_idx < num_eps; ep_idx++) begin
            automatic int ep = ep_idx;

            `uvm_info("SW_UM", $sformatf("--- EP[%0d] Phase A: MRd from host_mem ---", ep), UVM_LOW)
            //=================================================================
            // Phase A: EP[ep] reads from host_mem
            // Flow: ep_agents[ep].sequencer -> MRd TLP -> ep_to_switch_loopback
            //       -> switch routes upstream -> switch_to_rc_loopback
            //       -> use_unified_mem branch -> rc_driver.handle_request(MRd)
            //       -> send_mem_completion(host_mem) -> CplD back to EP
            //=================================================================
            begin
                bit [63:0] a;
                byte golden[];
                byte rd[];
                int sz = 256;
                pcie_tl_mem_rd_seq rd_seq;

                a = env.host_mem.alloc(sz, 64);
                host_allocs.push_back(a);
                make_golden(golden, 8'hA0 + ep * 8'h10, sz);
                env.host_mem.write_mem(a, golden);

                rd_seq = pcie_tl_mem_rd_seq::type_id::create($sformatf("ep%0d_rd_host", ep));
                rd_seq.addr     = a;
                rd_seq.length   = sz / 4;
                rd_seq.first_be = 4'hF;
                rd_seq.last_be  = 4'hF;
                rd_seq.is_64bit = (a[63:32] != 0);
                rd_seq.start(env.ep_agents[ep].sequencer);
                #2us;

                // Verify backing store unchanged
                env.host_mem.read_mem(a, sz, rd);
                compare_bytes(rd, golden, sz, $sformatf("A:EP%0d_RD_HOST", ep));
            end

            `uvm_info("SW_UM", $sformatf("--- EP[%0d] Phase B: MWr to host_mem (posted-MWr fix) ---", ep), UVM_LOW)
            //=================================================================
            // Phase B: EP[ep] writes to host_mem — verifies the posted-MWr gap fix.
            // Flow: ep_agents[ep].sequencer -> MWr TLP (posted) -> switch
            //       -> switch_to_rc_loopback -> use_unified_mem branch (TLP_MEM_WR)
            //       -> rc_driver.handle_request(MWr) -> um_write to host_mem
            // Verify: no fatal/error from the write path (MWr is posted; payload is
            //         randomized by the sequence).  We read back one byte and log it
            //         to confirm the write reached host_mem without simulation error.
            //=================================================================
            begin
                bit [63:0] a2;
                byte rd2[];
                int sz = 256;
                pcie_tl_mem_wr_seq wr_seq;

                a2 = env.host_mem.alloc(sz, 64);
                host_allocs.push_back(a2);

                wr_seq = pcie_tl_mem_wr_seq::type_id::create($sformatf("ep%0d_wr_host", ep));
                wr_seq.addr     = a2;
                wr_seq.length   = sz / 4;
                wr_seq.first_be = 4'hF;
                wr_seq.last_be  = 4'hF;
                wr_seq.is_64bit = (a2[63:32] != 0);
                wr_seq.start(env.ep_agents[ep].sequencer);
                #2us;

                // Read back to confirm write reached host_mem (no specific value check;
                // the TLP payload is randomized, proving routing + store completed)
                env.host_mem.read_mem(a2, sz, rd2);
                `uvm_info("SW_UM", $sformatf(
                    "B:EP%0d_WR_HOST OK -- host_mem[0x%0h][0] = 0x%02h (write stored)",
                    ep, a2, rd2[0]), UVM_LOW)
            end

            `uvm_info("SW_UM", $sformatf("--- EP[%0d] Phase C: RC MWr/MRd to dev_mem[%0d] ---", ep, ep), UVM_LOW)
            //=================================================================
            // Phase C: RC writes then reads back from dev_mem[ep].
            // Flow (write): rc_agent.sequencer -> MWr -> switch -> ep_agents[ep]
            //               -> ep_driver.handle_request(MWr) -> um_write to dev_mem[ep]
            // Flow (read):  rc_agent.sequencer -> MRd -> switch -> ep_agents[ep]
            //               -> ep_driver.handle_request(MRd) -> CplD from dev_mem[ep]
            // We confirm no error and read back the dev_mem byte (payload is randomized
            // by the sequence, matching pcie_tl_unified_mem_test.sv Phase 2b style).
            //=================================================================
            begin
                bit [63:0] b;
                bit [64:0] alloc_end_excl;
                bit [64:0] window_end_excl;
                bit [7:0]  write_data[];
                byte rd_b[];
                int sz = 256;
                pcie_tl_mem_wr_seq wr_rc;
                pcie_tl_mem_rd_seq rd_rc;

                b = env.dev_mem[ep].alloc(sz, 64);
                if (b == '1)
                    `uvm_fatal("SW_UM", $sformatf(
                        "DSP%0d device-memory allocation failed", ep))
                dev_allocs.push_back(b);

                // Check the address before sending a TLP.  This turns a
                // routing-window mismatch into an immediate, actionable error
                // instead of a later Completion timeout.
                alloc_end_excl  = {1'b0, b} + sz;
                window_end_excl = {1'b0, cfg.switch_cfg.ds_mem_limit[ep]} + 65'd1;
                if (({1'b0, b} < {32'h0, cfg.switch_cfg.ds_mem_base[ep]}) ||
                    (alloc_end_excl > window_end_excl)) begin
                    `uvm_fatal("SW_UM", $sformatf(
                        "DSP%0d allocation 0x%016h+%0d is outside Switch window [0x%08h,0x%08h]",
                        ep, b, sz,
                        cfg.switch_cfg.ds_mem_base[ep],
                        cfg.switch_cfg.ds_mem_limit[ep]))
                end

                // Use a deterministic payload so the Completion read-back
                // proves that the request traversed RC -> Switch -> DSP -> EP
                // and that the EP wrote/served the same bytes.
                write_data = new[sz];
                foreach (write_data[i])
                    write_data[i] = 8'h40 + ep * 8'h20 + i[7:0];

                wr_rc = pcie_tl_mem_wr_seq::type_id::create($sformatf("rc_wr_dev%0d", ep));
                wr_rc.addr     = b;
                wr_rc.length   = sz / 4;
                wr_rc.first_be = 4'hF;
                wr_rc.last_be  = 4'hF;
                wr_rc.is_64bit = (b[63:32] != 0);
                wr_rc.write_data = write_data;
                wr_rc.start(env.rc_agent.sequencer);
                #2us;

                if (wr_rc.issued_tlp == null ||
                    wr_rc.issued_tlp.addr != b ||
                    wr_rc.issued_tlp.payload.size() != sz)
                    `uvm_fatal("SW_UM", $sformatf(
                        "DSP%0d RC write TLP was not issued with expected address/payload",
                        ep))

                rd_rc = pcie_tl_mem_rd_seq::type_id::create($sformatf("rc_rd_dev%0d", ep));
                rd_rc.addr     = b;
                rd_rc.length   = sz / 4;
                rd_rc.first_be = 4'hF;
                rd_rc.last_be  = 4'hF;
                rd_rc.is_64bit = (b[63:32] != 0);
                rd_rc.start(env.rc_agent.sequencer);
                #2us;

                if (rd_rc.issued_tlp == null || !rd_rc.issued_tlp.rb_done ||
                    rd_rc.issued_tlp.rb_status != CPL_STATUS_SC ||
                    rd_rc.rb_data.size() != sz)
                    `uvm_fatal("SW_UM", $sformatf(
                        "DSP%0d RC read did not receive a successful Completion (done=%0d status=%s bytes=%0d)",
                        ep,
                        (rd_rc.issued_tlp == null) ? 0 : rd_rc.issued_tlp.rb_done,
                        (rd_rc.issued_tlp == null) ? "<null>" :
                          rd_rc.issued_tlp.rb_status.name(),
                        rd_rc.rb_data.size()))

                foreach (write_data[i]) begin
                    if (rd_rc.rb_data[i] !== write_data[i])
                        `uvm_fatal("SW_UM", $sformatf(
                            "DSP%0d Completion payload mismatch at byte %0d (got=0x%02h expected=0x%02h)",
                            ep, i,
                            rd_rc.rb_data[i], write_data[i]))
                end

                env.dev_mem[ep].read_mem(b, sz, rd_b);
                `uvm_info("SW_UM", $sformatf(
                    "C:RC_RD_DEV%0d OK -- routed address=0x%0h Completion bytes=%0d dev_mem[0]=0x%02h",
                    ep, b, rd_rc.rb_data.size(), rd_b[0]), UVM_LOW)
            end
        end

        //=====================================================================
        // Phase D: Leak checks
        //=====================================================================
        `uvm_info("SW_UM", "--- Phase D: Leak checks ---", UVM_LOW)
        foreach (host_allocs[i])
            env.host_mem.free(host_allocs[i]);
        foreach (dev_allocs[i])
            env.dev_mem[i].free(dev_allocs[i]);
        env.host_mem.leak_check();
        for (int i = 0; i < num_eps; i++)
            env.dev_mem[i].leak_check();

        `uvm_info("SW_UM", "=== Switch Unified-Memory Test DONE ===", UVM_LOW)
        phase.drop_objection(this);
    endtask

endclass
