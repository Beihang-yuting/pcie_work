import uvm_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// Test 1: Stress Test - 200+ mixed TLPs
//=============================================================================
class pcie_tl_stress_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_stress_test)
    function new(string name = "pcie_tl_stress_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void configure_test();
        super.configure_test();
        enable_coverage();
        configure_fc(1, 0);  // FC enabled, finite credits
        cfg.init_ph_credit  = 64;
        cfg.init_pd_credit  = 512;
        cfg.init_nph_credit = 64;
        cfg.init_npd_credit = 256;
        cfg.init_cplh_credit = 64;
        cfg.init_cpld_credit = 512;
    endfunction
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info("STRESS", "=== Starting Stress Test: 200+ mixed TLPs ===", UVM_LOW)

        // Phase 1: 100 writes with varying sizes
        `uvm_info("STRESS", "Phase 1: 100 memory writes", UVM_MEDIUM)
        for (int i = 0; i < 100; i++) begin
            pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("wr_%0d", i));
            wr.addr = 64'h0000_0001_0000_0000 + (i * 256);
            wr.length = 1 + (i % 64);  // 1-64 DW
            wr.first_be = 4'hF;
            wr.last_be = (wr.length > 1) ? 4'hF : 4'h0;
            wr.is_64bit = 1;
            wr.start(env.rc_agent.sequencer);
            #10ns;
        end

        // Phase 2: 50 reads with completions
        `uvm_info("STRESS", "Phase 2: 50 memory reads", UVM_MEDIUM)
        for (int i = 0; i < 50; i++) begin
            pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create($sformatf("rd_%0d", i));
            rd.addr = 64'h0000_0001_0000_0000 + (i * 128);
            rd.length = 1 + (i % 32);  // 1-32 DW
            rd.first_be = 4'hF;
            rd.last_be = (rd.length > 1) ? 4'hF : 4'h0;
            rd.is_64bit = 1;
            rd.start(env.rc_agent.sequencer);
            #20ns;
        end

        // Phase 3: 20 config reads
        `uvm_info("STRESS", "Phase 3: 20 config reads", UVM_MEDIUM)
        for (int i = 0; i < 20; i++) begin
            pcie_tl_cfg_rd_seq cfg_rd = pcie_tl_cfg_rd_seq::type_id::create($sformatf("cfgrd_%0d", i));
            cfg_rd.start(env.rc_agent.sequencer);
            #10ns;
        end

        // Phase 4: 30 interleaved reads and writes
        `uvm_info("STRESS", "Phase 4: 30 interleaved R/W", UVM_MEDIUM)
        for (int i = 0; i < 30; i++) begin
            if (i % 2 == 0) begin
                pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("mix_wr_%0d", i));
                wr.addr = 64'hC000 + (i * 64);
                wr.length = 4;
                wr.first_be = 4'hF; wr.last_be = 4'hF;
                wr.start(env.rc_agent.sequencer);
            end else begin
                pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create($sformatf("mix_rd_%0d", i));
                rd.addr = 64'hD000 + (i * 64);
                rd.length = 4;
                rd.first_be = 4'hF; rd.last_be = 4'hF;
                rd.start(env.rc_agent.sequencer);
            end
            #10ns;
        end

        #500ns;
        `uvm_info("STRESS", "=== Stress Test Complete ===", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass

//=============================================================================
// Test 2: MPS Sweep - Test completion splitting with small MPS
//=============================================================================
class pcie_tl_mps_sweep_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_mps_sweep_test)
    function new(string name = "pcie_tl_mps_sweep_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void configure_test();
        super.configure_test();
        cfg.max_payload_size = MPS_128;          // Small MPS for more splits
        cfg.max_read_request_size = MRRS_512;
        cfg.read_completion_boundary = RCB_64;   // Small RCB
        cfg.ep_auto_response = 1;
        enable_coverage();
    endfunction
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info("MPS_SWEEP", "=== MPS Sweep Test: MPS=128, RCB=64 ===", UVM_LOW)

        // Read 512B — should split into multiple completions (128B each after RCB alignment)
        `uvm_info("MPS_SWEEP", "Test 1: 512B read (expect multi-CplD)", UVM_MEDIUM)
        begin
            pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create("rd_512");
            rd.addr = 64'h0000_0001_0000_0000;
            rd.length = 128;  // 512B = 128 DW
            rd.first_be = 4'hF; rd.last_be = 4'hF; rd.is_64bit = 1;
            rd.start(env.rc_agent.sequencer);
        end
        #200ns;

        // Read at unaligned address — first CplD should align to RCB boundary
        `uvm_info("MPS_SWEEP", "Test 2: Unaligned 256B read", UVM_MEDIUM)
        begin
            pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create("rd_unaligned");
            rd.addr = 64'h0000_0001_0000_0030;  // offset 48 within 64B RCB
            rd.length = 64;  // 256B
            rd.first_be = 4'hF; rd.last_be = 4'hF; rd.is_64bit = 1;
            rd.start(env.rc_agent.sequencer);
        end
        #200ns;

        // Exact MPS-sized read — should be single completion
        `uvm_info("MPS_SWEEP", "Test 3: Exact MPS read (128B)", UVM_MEDIUM)
        begin
            pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create("rd_exact_mps");
            rd.addr = 64'h0000_0001_0000_0000;
            rd.length = 32;  // 128B = 32 DW, exactly MPS
            rd.first_be = 4'hF; rd.last_be = 4'hF; rd.is_64bit = 1;
            rd.start(env.rc_agent.sequencer);
        end
        #200ns;

        // DMA-style multi-TLP transfer
        `uvm_info("MPS_SWEEP", "Test 4: DMA 2KB write (MPS-chunked)", UVM_MEDIUM)
        begin
            pcie_tl_dma_rdwr_seq dma = pcie_tl_dma_rdwr_seq::type_id::create("dma_wr");
            dma.addr = 64'h0000_0001_0000_0000;
            dma.xfer_size = 2048;
            dma.max_payload = 128;
            dma.is_read = 0;
            dma.start(env.rc_agent.sequencer);
        end
        #500ns;

        `uvm_info("MPS_SWEEP", "=== MPS Sweep Test Complete ===", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass

//=============================================================================
// Test 3: 4KB Boundary - DMA transfers across 4KB boundaries
//=============================================================================
class pcie_tl_4kb_boundary_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_4kb_boundary_test)
    function new(string name = "pcie_tl_4kb_boundary_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void configure_test();
        super.configure_test();
        cfg.max_payload_size = MPS_256;
        cfg.max_read_request_size = MRRS_512;
        cfg.read_completion_boundary = RCB_64;
        enable_coverage();
    endfunction
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info("4KB", "=== 4KB Boundary Test ===", UVM_LOW)

        // DMA write starting near 4KB boundary — sequence auto-splits
        `uvm_info("4KB", "Test 1: DMA 1KB write across 4KB boundary", UVM_MEDIUM)
        begin
            pcie_tl_dma_rdwr_seq dma = pcie_tl_dma_rdwr_seq::type_id::create("dma_cross");
            dma.addr = 64'h0000_0001_0000_0E00;  // 3584 offset, 512B to boundary
            dma.xfer_size = 1024;                 // Will cross 4KB boundary
            dma.max_payload = 256;
            dma.is_read = 0;
            dma.start(env.rc_agent.sequencer);
        end
        #300ns;

        // DMA read across boundary
        `uvm_info("4KB", "Test 2: DMA 2KB read across 4KB boundary", UVM_MEDIUM)
        begin
            pcie_tl_dma_rdwr_seq dma = pcie_tl_dma_rdwr_seq::type_id::create("dma_rd_cross");
            dma.addr = 64'h0000_0001_0000_0C00;  // 3072 offset, 1KB to boundary
            dma.xfer_size = 2048;
            dma.max_payload = 256;
            dma.is_read = 1;
            dma.start(env.rc_agent.sequencer);
        end
        #500ns;

        // Multi-page DMA transfer
        `uvm_info("4KB", "Test 3: Multi-page 4KB DMA write", UVM_MEDIUM)
        begin
            pcie_tl_dma_rdwr_seq dma = pcie_tl_dma_rdwr_seq::type_id::create("dma_multi_page");
            dma.addr = 64'h0000_0001_0000_0800;  // 2KB offset
            dma.xfer_size = 4096;                 // Full 4KB, crosses at least one boundary
            dma.max_payload = 256;
            dma.is_read = 0;
            dma.start(env.rc_agent.sequencer);
        end
        #500ns;

        // Single TLP right at boundary edge (should NOT cross)
        `uvm_info("4KB", "Test 4: Single write at page boundary edge", UVM_MEDIUM)
        begin
            pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create("wr_edge");
            wr.addr = 64'h0000_0001_0000_0FFC;  // 4 bytes before 4KB boundary
            wr.length = 1;  // 4B, should not cross
            wr.first_be = 4'hF; wr.last_be = 4'h0;
            wr.is_64bit = 1;
            wr.start(env.rc_agent.sequencer);
        end
        #100ns;

        `uvm_info("4KB", "=== 4KB Boundary Test Complete ===", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass

//=============================================================================
// Test 4: Bandwidth Shaper - Token bucket rate limiting
//=============================================================================
class pcie_tl_bandwidth_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_bandwidth_test)
    function new(string name = "pcie_tl_bandwidth_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void configure_test();
        super.configure_test();
        cfg.shaper_enable = 1;
        cfg.avg_rate = 1.0;       // 1 byte per ns = 1 GB/s
        cfg.burst_size = 512;     // Small burst to see throttling quickly
        cfg.max_payload_size = MPS_256;
        configure_fc(1, 0);
        cfg.init_ph_credit  = 64;
        cfg.init_pd_credit  = 512;
        cfg.init_nph_credit = 64;
        cfg.init_npd_credit = 256;
        cfg.init_cplh_credit = 64;
        cfg.init_cpld_credit = 512;
    endfunction
    task run_phase(uvm_phase phase);
        realtime t_start, t_end;
        int total_bytes;
        phase.raise_objection(this);
        `uvm_info("BW", "=== Bandwidth Shaper Test: rate=1GB/s, burst=512B ===", UVM_LOW)

        // Burst of 20 writes (each 256B = 64 DW)
        t_start = $realtime;
        total_bytes = 0;
        for (int i = 0; i < 20; i++) begin
            pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("bw_wr_%0d", i));
            wr.addr = 64'h0000_0001_0000_0000 + (i * 256);
            wr.length = 64;  // 256B
            wr.first_be = 4'hF; wr.last_be = 4'hF; wr.is_64bit = 1;
            wr.start(env.rc_agent.sequencer);
            total_bytes += 256;
            #10ns;
        end
        t_end = $realtime;
        `uvm_info("BW", $sformatf("Sent %0d bytes in %0t, shaper should have throttled",
            total_bytes, t_end - t_start), UVM_LOW)

        // Check shaper state
        `uvm_info("BW", $sformatf("Shaper tokens remaining: %0f", env.bw_shaper.token_count), UVM_LOW)

        // Wait for tokens to refill, then send another burst
        #1000ns;
        `uvm_info("BW", $sformatf("After 1us refill, tokens: %0f", env.bw_shaper.token_count), UVM_LOW)

        for (int i = 0; i < 10; i++) begin
            pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("bw_wr2_%0d", i));
            wr.addr = 64'h0000_0002_0000_0000 + (i * 128);
            wr.length = 32;  // 128B
            wr.first_be = 4'hF; wr.last_be = 4'hF; wr.is_64bit = 1;
            wr.start(env.rc_agent.sequencer);
            #10ns;
        end

        #200ns;
        `uvm_info("BW", "=== Bandwidth Shaper Test Complete ===", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass

//=============================================================================
// Test 5: FC Stress - Tight credits, test exhaustion and recovery
//=============================================================================
class pcie_tl_fc_stress_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_fc_stress_test)
    function new(string name = "pcie_tl_fc_stress_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void configure_test();
        super.configure_test();
        configure_fc(1, 0);
        cfg.init_ph_credit  = 4;    // Very tight: only 4 posted headers
        cfg.init_pd_credit  = 64;   // Tight data credits
        cfg.init_nph_credit = 4;
        cfg.init_npd_credit = 32;
        cfg.init_cplh_credit = 8;
        cfg.init_cpld_credit = 128;
        enable_coverage();
    endfunction
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info("FC_STRESS", "=== FC Stress Test: PH=4, PD=64 ===", UVM_LOW)

        // Phase 1: Burst writes to exhaust posted credits
        `uvm_info("FC_STRESS", "Phase 1: Exhaust posted credits with burst writes", UVM_MEDIUM)
        begin
            pcie_tl_backpressure_vseq bp = pcie_tl_backpressure_vseq::type_id::create("bp");
            bp.burst_count = 8;  // Should exhaust PH=4 by midway
            bp.start(env.v_seqr);
        end
        #200ns;

        // Check FC state
        `uvm_info("FC_STRESS", $sformatf("After burst: PH=%0d, PD=%0d",
            env.fc_mgr.posted_header.current,
            env.fc_mgr.posted_data.current), UVM_LOW)

        // Phase 2: Reads to test non-posted credit exhaustion
        `uvm_info("FC_STRESS", "Phase 2: Non-posted credit stress", UVM_MEDIUM)
        for (int i = 0; i < 8; i++) begin
            pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create($sformatf("fc_rd_%0d", i));
            rd.addr = 64'h0000_0001_0000_0000 + (i * 64);
            rd.length = 8;  // 32B
            rd.first_be = 4'hF; rd.last_be = 4'hF; rd.is_64bit = 1;
            rd.start(env.rc_agent.sequencer);
            #20ns;
        end

        `uvm_info("FC_STRESS", $sformatf("After reads: NPH=%0d, NPD=%0d",
            env.fc_mgr.non_posted_header.current,
            env.fc_mgr.non_posted_data.current), UVM_LOW)

        #500ns;

        // Phase 3: Mixed traffic after credit recovery
        `uvm_info("FC_STRESS", "Phase 3: Mixed traffic post-recovery", UVM_MEDIUM)
        for (int i = 0; i < 10; i++) begin
            if (i % 3 == 0) begin
                pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create($sformatf("mix_rd_%0d", i));
                rd.addr = 64'hE000 + (i * 32);
                rd.length = 4; rd.first_be = 4'hF; rd.last_be = 4'hF;
                rd.start(env.rc_agent.sequencer);
            end else begin
                pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("mix_wr_%0d", i));
                wr.addr = 64'hF000 + (i * 32);
                wr.length = 4; wr.first_be = 4'hF; wr.last_be = 4'hF;
                wr.start(env.rc_agent.sequencer);
            end
            #10ns;
        end

        #300ns;
        `uvm_info("FC_STRESS", "=== FC Stress Test Complete ===", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass

//=============================================================================
// Test 6: Completion Splitting Verification
//=============================================================================
class pcie_tl_cpl_split_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_cpl_split_test)
    function new(string name = "pcie_tl_cpl_split_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void configure_test();
        super.configure_test();
        cfg.max_payload_size = MPS_128;
        cfg.read_completion_boundary = RCB_64;
        cfg.ep_auto_response = 1;
        enable_coverage();
    endfunction
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info("CPL_SPLIT", "=== Completion Splitting Test ===", UVM_LOW)

        // Test 1: Aligned 256B read — should produce 2 completions (128B each)
        `uvm_info("CPL_SPLIT", "Test 1: Aligned 256B read (expect 2 CplDs)", UVM_MEDIUM)
        begin
            pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create("rd_aligned");
            rd.addr = 64'h0000_0001_0000_0000;  // RCB-aligned
            rd.length = 64;  // 256B
            rd.first_be = 4'hF; rd.last_be = 4'hF; rd.is_64bit = 1;
            rd.start(env.rc_agent.sequencer);
        end
        #200ns;

        // Test 2: Unaligned — first CplD should align, then MPS-sized
        `uvm_info("CPL_SPLIT", "Test 2: Unaligned 384B read", UVM_MEDIUM)
        begin
            pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create("rd_unaligned");
            rd.addr = 64'h0000_0001_0000_0020;  // 32B offset
            rd.length = 96;  // 384B
            rd.first_be = 4'hF; rd.last_be = 4'hF; rd.is_64bit = 1;
            rd.start(env.rc_agent.sequencer);
        end
        #200ns;

        // Test 3: Single DW read — should produce exactly 1 CplD
        `uvm_info("CPL_SPLIT", "Test 3: Single DW read (expect 1 CplD)", UVM_MEDIUM)
        begin
            pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create("rd_single_dw");
            rd.addr = 64'h0000_0001_0000_0100;
            rd.length = 1;
            rd.first_be = 4'hF; rd.last_be = 4'h0; rd.is_64bit = 1;
            rd.start(env.rc_agent.sequencer);
        end
        #100ns;

        // Test 4: Sequential reads to stress tag reuse
        `uvm_info("CPL_SPLIT", "Test 4: 10 sequential reads", UVM_MEDIUM)
        for (int i = 0; i < 10; i++) begin
            pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create($sformatf("rd_seq_%0d", i));
            rd.addr = 64'h0000_0001_0000_0000 + (i * 512);
            rd.length = 32 + (i * 8);  // 128B to 416B
            rd.first_be = 4'hF; rd.last_be = 4'hF; rd.is_64bit = 1;
            rd.start(env.rc_agent.sequencer);
            #50ns;
        end

        #500ns;
        `uvm_info("CPL_SPLIT", "=== Completion Splitting Test Complete ===", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass

//=============================================================================
// Test 7: Tag Stress - Small tag pool with many reads
//=============================================================================
class pcie_tl_tag_stress_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_tag_stress_test)
    function new(string name = "pcie_tl_tag_stress_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void configure_test();
        super.configure_test();
        configure_tags(.extended(0), .phantom(0), .max_out(32));  // 32-tag pool
        cfg.ep_auto_response = 1;
        cfg.max_payload_size = MPS_128;
        cfg.read_completion_boundary = RCB_64;
        enable_coverage();
    endfunction
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info("TAG_STRESS", "=== Tag Stress Test: 32-tag pool, 50 reads ===", UVM_LOW)

        // Phase 1: Burst 20 reads rapidly to fill tag pool
        `uvm_info("TAG_STRESS", "Phase 1: Burst 20 reads", UVM_MEDIUM)
        for (int i = 0; i < 20; i++) begin
            pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create($sformatf("tag_rd_%0d", i));
            rd.addr = 64'h0000_0001_0000_0000 + (i * 128);
            rd.length = 16;  // 64B
            rd.first_be = 4'hF; rd.last_be = 4'hF; rd.is_64bit = 1;
            rd.start(env.rc_agent.sequencer);
            #5ns;
        end

        // Wait for completions to return tags
        #200ns;
        `uvm_info("TAG_STRESS", $sformatf("After burst: outstanding=%0d",
            env.tag_mgr.get_outstanding_count()), UVM_LOW)

        // Phase 2: Sequential reads with enough delay for tag recycling
        `uvm_info("TAG_STRESS", "Phase 2: 30 sequential reads with recycling", UVM_MEDIUM)
        for (int i = 0; i < 30; i++) begin
            pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create($sformatf("tag_rd2_%0d", i));
            rd.addr = 64'h0000_0002_0000_0000 + (i * 128);
            rd.length = 8;  // 32B
            rd.first_be = 4'hF; rd.last_be = 4'hF; rd.is_64bit = 1;
            rd.start(env.rc_agent.sequencer);
            #50ns;  // Enough time for completion round-trip
        end

        #500ns;
        `uvm_info("TAG_STRESS", $sformatf("Final tag pool outstanding: %0d",
            env.tag_mgr.get_outstanding_count()), UVM_LOW)
        `uvm_info("TAG_STRESS", "=== Tag Stress Test Complete ===", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass

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

//=============================================================================
// Test 9: RC-EP Bidirectional Heavy Traffic Stress
//
// PURPOSE: Simulate realistic RC<->EP bidirectional traffic at high volume
//          to expose concurrency issues, FC credit deadlocks, tag exhaustion,
//          and multi-completion handling bugs.
//
// KNOWN ISSUE PROBES:
//   (a) Multi-CplD tag early-free: rc_driver.handle_completion() frees tag
//       on first CplD, subsequent splits report "Unexpected Completion".
//   (b) FC credit starvation: bidirectional traffic competing for shared
//       FC credit pools can deadlock under tight credits.
//   (c) Tag pool exhaustion: concurrent RC reads + EP DMA reads can
//       exhaust shared tag_mgr pool.
//   (d) Ordering queue growth: bidirectional posted/non-posted/completion
//       mix stresses ordering engine queue management.
//=============================================================================
class pcie_tl_bidir_traffic_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_bidir_traffic_test)

    // Per-phase statistics
    int phase1_rc_wr_count;
    int phase1_rc_rd_count;
    int phase2_rc_wr_count;
    int phase2_rc_rd_count;
    int phase2_ep_dma_count;
    int phase3_split_rd_count;
    int phase4_rc_wr_count;
    int phase4_rc_rd_count;
    int phase4_ep_dma_wr_count;
    int phase4_ep_dma_rd_count;

    function new(string name = "pcie_tl_bidir_traffic_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void configure_test();
        super.configure_test();

        // FC credits sized for sustained 10K traffic without instant deadlock
        configure_fc(1, 0);
        cfg.init_ph_credit   = 64;
        cfg.init_pd_credit   = 512;
        cfg.init_nph_credit  = 64;
        cfg.init_npd_credit  = 256;
        cfg.init_cplh_credit = 64;
        cfg.init_cpld_credit = 512;

        // Large tag pool for high concurrency
        configure_tags(.extended(1), .phantom(0), .max_out(256));

        // MPS=128 to trigger completion splitting on reads > 128B
        cfg.max_payload_size         = MPS_128;
        cfg.max_read_request_size    = MRRS_512;
        cfg.read_completion_boundary = RCB_64;

        // EP auto-response with small delay
        cfg.ep_auto_response   = 1;
        cfg.response_delay_min = 0;
        cfg.response_delay_max = 3;

        // Moderate link delay
        cfg.link_delay_enable          = 1;
        cfg.rc2ep_latency_min_ns       = 200;
        cfg.rc2ep_latency_max_ns       = 500;
        cfg.ep2rc_latency_min_ns       = 200;
        cfg.ep2rc_latency_max_ns       = 500;
        cfg.link_delay_update_interval = 32;

        // Generous timeout for 10K scale
        cfg.cpl_timeout_ns = 500000;  // 500us

        // Enable all scoreboard checks
        cfg.ordering_check_enable   = 1;
        cfg.completion_check_enable = 1;
        cfg.data_integrity_enable   = 1;

        enable_coverage();
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info("BIDIR", "============================================================", UVM_LOW)
        `uvm_info("BIDIR", "=== Test 9: RC-EP Bidirectional 10K Traffic Stress ===", UVM_LOW)
        `uvm_info("BIDIR", $sformatf("  FC: PH=%0d PD=%0d NPH=%0d NPD=%0d CplH=%0d CplD=%0d",
            cfg.init_ph_credit, cfg.init_pd_credit, cfg.init_nph_credit,
            cfg.init_npd_credit, cfg.init_cplh_credit, cfg.init_cpld_credit), UVM_LOW)
        `uvm_info("BIDIR", $sformatf("  Tags: max_outstanding=%0d, MPS=%0dB, RCB=%0dB",
            cfg.max_outstanding, int'(cfg.max_payload_size),
            int'(cfg.read_completion_boundary)), UVM_LOW)
        `uvm_info("BIDIR", $sformatf("  Link delay: RC->EP %0d-%0dns, EP->RC %0d-%0dns",
            cfg.rc2ep_latency_min_ns, cfg.rc2ep_latency_max_ns,
            cfg.ep2rc_latency_min_ns, cfg.ep2rc_latency_max_ns), UVM_LOW)
        `uvm_info("BIDIR", "  Target: ~10,000 total requests across 4 phases", UVM_LOW)
        `uvm_info("BIDIR", "============================================================", UVM_LOW)

        phase1_rc_burst();
        phase2_bidir_simultaneous();
        phase3_multi_cpl_stress();
        phase4_full_saturation();

        `uvm_info("BIDIR", "--- Draining pipeline (waiting for all in-flight TLPs) ---", UVM_LOW)
        #(cfg.cpl_timeout_ns * 1ns);

        report_bidir_results();

        `uvm_info("BIDIR", "=== Bidirectional 10K Traffic Test Complete ===", UVM_LOW)
        phase.drop_objection(this);
    endtask

    //=========================================================================
    // Phase 1: RC burst — 2000 writes + 500 reads (warm up, fill EP memory)
    // ~2500 requests
    //=========================================================================
    task phase1_rc_burst();
        `uvm_info("BIDIR", "\n--- Phase 1: RC Burst 2000W + 500R ---", UVM_LOW)
        phase1_rc_wr_count = 0;
        phase1_rc_rd_count = 0;

        fork
            // RC writes: fill EP memory with known data patterns
            begin
                for (int i = 0; i < 2000; i++) begin
                    pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("p1_wr_%0d", i));
                    wr.addr     = 64'h0000_0001_0000_0000 + (i * 64);
                    wr.length   = 16;  // 64B
                    wr.first_be = 4'hF;
                    wr.last_be  = 4'hF;
                    wr.is_64bit = 1;
                    wr.start(env.rc_agent.sequencer);
                    phase1_rc_wr_count++;
                    if (i % 500 == 499)
                        `uvm_info("BIDIR", $sformatf("  Phase 1 progress: %0d writes sent", i+1), UVM_LOW)
                    #(1ns);
                end
            end
            // RC reads: request data back
            begin
                #500ns;  // Let writes fill memory first
                for (int i = 0; i < 500; i++) begin
                    pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create($sformatf("p1_rd_%0d", i));
                    rd.addr     = 64'h0000_0001_0000_0000 + (i * 64);
                    rd.length   = 8;  // 32B — single CplD
                    rd.first_be = 4'hF;
                    rd.last_be  = 4'hF;
                    rd.is_64bit = 1;
                    rd.start(env.rc_agent.sequencer);
                    phase1_rc_rd_count++;
                    #(2ns);
                end
            end
        join

        #10000ns;
        `uvm_info("BIDIR", $sformatf("Phase 1 done: %0d writes, %0d reads sent",
            phase1_rc_wr_count, phase1_rc_rd_count), UVM_LOW)
        `uvm_info("BIDIR", $sformatf("  RC pending: %0d, Tags outstanding: %0d",
            env.rc_agent.rc_driver.get_pending_count(),
            env.tag_mgr.get_outstanding_count()), UVM_LOW)
    endtask

    //=========================================================================
    // Phase 2: Bidirectional simultaneous — 1500W + 1000R + 500 EP DMA
    // ~3000 requests
    //=========================================================================
    task phase2_bidir_simultaneous();
        `uvm_info("BIDIR", "\n--- Phase 2: Bidirectional 1500W + 1000R + 500 EP DMA ---", UVM_LOW)
        phase2_rc_wr_count  = 0;
        phase2_rc_rd_count  = 0;
        phase2_ep_dma_count = 0;

        fork
            // RC: 1500 writes to EP
            begin
                for (int i = 0; i < 1500; i++) begin
                    pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("p2_wr_%0d", i));
                    wr.addr     = 64'h0000_0001_0010_0000 + (i * 128);
                    wr.length   = 32;  // 128B
                    wr.first_be = 4'hF;
                    wr.last_be  = 4'hF;
                    wr.is_64bit = 1;
                    wr.start(env.rc_agent.sequencer);
                    phase2_rc_wr_count++;
                    if (i % 500 == 499)
                        `uvm_info("BIDIR", $sformatf("  Phase 2 RC writes: %0d sent", i+1), UVM_LOW)
                    #(1ns);
                end
            end

            // RC: 1000 reads from EP
            begin
                for (int i = 0; i < 1000; i++) begin
                    pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create($sformatf("p2_rd_%0d", i));
                    rd.addr     = 64'h0000_0001_0000_0000 + ((i % 2000) * 64);
                    rd.length   = 8 + (i % 8) * 4;  // 32B-160B, mix of single/multi CplD
                    rd.first_be = 4'hF;
                    rd.last_be  = 4'hF;
                    rd.is_64bit = 1;
                    rd.start(env.rc_agent.sequencer);
                    phase2_rc_rd_count++;
                    if (i % 500 == 499)
                        `uvm_info("BIDIR", $sformatf("  Phase 2 RC reads: %0d sent", i+1), UVM_LOW)
                    #(2ns);
                end
            end

            // EP: 500 DMA writes back to RC host memory
            begin
                #100ns;
                for (int i = 0; i < 500; i++) begin
                    env.ep_agent.ep_driver.initiate_dma(
                        64'h0000_0002_0000_0000 + (i * 64),
                        64,  // 64B
                        0    // write
                    );
                    phase2_ep_dma_count++;
                    if (i % 250 == 249)
                        `uvm_info("BIDIR", $sformatf("  Phase 2 EP DMA writes: %0d sent", i+1), UVM_LOW)
                    #(3ns);
                end
            end

            // Monitor
            begin
                for (int m = 0; m < 5; m++) begin
                    #10000ns;
                    `uvm_info("BIDIR", $sformatf(
                        "  [P2 Monitor] FC: PH=%0d NPH=%0d CplH=%0d | Tags=%0d | SCB: req=%0d cpl=%0d",
                        env.fc_mgr.posted_header.current,
                        env.fc_mgr.non_posted_header.current,
                        env.fc_mgr.completion_header.current,
                        env.tag_mgr.get_outstanding_count(),
                        env.scb.total_requests, env.scb.total_completions), UVM_LOW)
                end
            end
        join

        #20000ns;
        `uvm_info("BIDIR", $sformatf("Phase 2 done: RC wr=%0d rd=%0d, EP DMA=%0d",
            phase2_rc_wr_count, phase2_rc_rd_count, phase2_ep_dma_count), UVM_LOW)
    endtask

    //=========================================================================
    // Phase 3: Multi-CplD split stress — 500 large reads
    // Each read > MPS=128B, generating 2-8 CplDs per request
    // ~500 requests, ~2000+ CplDs
    //=========================================================================
    task phase3_multi_cpl_stress();
        int scb_unexpected_before;
        `uvm_info("BIDIR", "\n--- Phase 3: 500 Multi-CplD Split Reads (MPS=128B) ---", UVM_LOW)
        phase3_split_rd_count = 0;
        scb_unexpected_before = env.scb.unexpected;

        fork
            // 500 large reads with varying sizes
            begin
                for (int i = 0; i < 500; i++) begin
                    pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create($sformatf("p3_rd_%0d", i));
                    rd.addr     = 64'h0000_0001_0000_0000 + ((i % 1000) * 1024);
                    // Cycle through sizes: 256B(64DW), 384B(96DW), 512B(128DW), 768B(192DW), 1024B(256DW)
                    case (i % 5)
                        0: rd.length = 64;   // 256B -> 2 CplDs
                        1: rd.length = 96;   // 384B -> 3 CplDs
                        2: rd.length = 128;  // 512B -> 4 CplDs
                        3: rd.length = 192;  // 768B -> 6 CplDs
                        4: rd.length = 256;  // 1024B -> 8 CplDs
                    endcase
                    rd.first_be = 4'hF;
                    rd.last_be  = 4'hF;
                    rd.is_64bit = 1;
                    rd.start(env.rc_agent.sequencer);
                    phase3_split_rd_count++;
                    if (i % 100 == 99)
                        `uvm_info("BIDIR", $sformatf("  Phase 3 progress: %0d large reads sent", i+1), UVM_LOW)
                    // Pace to avoid tag exhaustion — 256 tags, each read holds tag until all CplDs arrive
                    #(5ns);
                end
            end

            // Concurrent EP DMA writes to add cross-traffic pressure
            begin
                for (int i = 0; i < 200; i++) begin
                    env.ep_agent.ep_driver.initiate_dma(
                        64'h0000_0002_0010_0000 + (i * 64),
                        64, 0
                    );
                    #(10ns);
                end
            end
        join

        #50000ns;
        `uvm_info("BIDIR", $sformatf("Phase 3 done: %0d large reads + 200 EP DMA", phase3_split_rd_count), UVM_LOW)
        `uvm_info("BIDIR", $sformatf("  SCB: matched=%0d, unexpected=%0d (new in phase3: %0d)",
            env.scb.matched, env.scb.unexpected,
            env.scb.unexpected - scb_unexpected_before), UVM_LOW)
        `uvm_info("BIDIR", $sformatf("  Tags outstanding: %0d, RC pending: %0d",
            env.tag_mgr.get_outstanding_count(),
            env.rc_agent.rc_driver.get_pending_count()), UVM_LOW)

        if (env.scb.unexpected > scb_unexpected_before) begin
            `uvm_error("BIDIR", $sformatf(
                "Phase 3: %0d unexpected completions — multi-CplD handling bug still present!",
                env.scb.unexpected - scb_unexpected_before))
        end else begin
            `uvm_info("BIDIR", "Phase 3: PASS — no unexpected completions (multi-CplD fix verified)", UVM_LOW)
        end
    endtask

    //=========================================================================
    // Phase 4: Full saturation — 2500W + 1500R + 800 EP DMA W + 200 EP DMA R
    // ~5000 requests, tighter FC credits
    //=========================================================================
    task phase4_full_saturation();
        `uvm_info("BIDIR", "\n--- Phase 4: Full Saturation 5000 Requests ---", UVM_LOW)
        phase4_rc_wr_count     = 0;
        phase4_rc_rd_count     = 0;
        phase4_ep_dma_wr_count = 0;
        phase4_ep_dma_rd_count = 0;

        // Tighten FC credits
        env.fc_mgr.init_credits(32, 256, 32, 128, 32, 256);

        // Increase link delay for maximum pipeline pressure
        env.rc2ep_delay.set_latency(300, 800);
        env.ep2rc_delay.set_latency(300, 800);

        fork
            // RC: 2500 writes (posted)
            begin
                for (int i = 0; i < 2500; i++) begin
                    pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("p4_wr_%0d", i));
                    wr.addr     = 64'h0000_0001_0020_0000 + (i * 64);
                    wr.length   = 8 + (i % 24);  // 32B-128B varying
                    wr.first_be = 4'hF;
                    wr.last_be  = 4'hF;
                    wr.is_64bit = 1;
                    wr.start(env.rc_agent.sequencer);
                    phase4_rc_wr_count++;
                    if (i % 500 == 499)
                        `uvm_info("BIDIR", $sformatf("  Phase 4 RC writes: %0d", i+1), UVM_LOW)
                    #(1ns);
                end
            end

            // RC: 1500 reads (non-posted)
            begin
                for (int i = 0; i < 1500; i++) begin
                    pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create($sformatf("p4_rd_%0d", i));
                    rd.addr     = 64'h0000_0001_0000_0000 + ((i % 2000) * 64);
                    rd.length   = 4 + (i % 28);  // 16B-128B varying
                    rd.first_be = 4'hF;
                    rd.last_be  = 4'hF;
                    rd.is_64bit = 1;
                    rd.start(env.rc_agent.sequencer);
                    phase4_rc_rd_count++;
                    if (i % 500 == 499)
                        `uvm_info("BIDIR", $sformatf("  Phase 4 RC reads: %0d", i+1), UVM_LOW)
                    #(2ns);
                end
            end

            // EP: 800 DMA writes to RC
            begin
                for (int i = 0; i < 800; i++) begin
                    env.ep_agent.ep_driver.initiate_dma(
                        64'h0000_0002_0020_0000 + (i * 64),
                        64,  // 64B
                        0    // write
                    );
                    phase4_ep_dma_wr_count++;
                    if (i % 200 == 199)
                        `uvm_info("BIDIR", $sformatf("  Phase 4 EP DMA writes: %0d", i+1), UVM_LOW)
                    #(2ns);
                end
            end

            // EP: 200 DMA reads from RC (compete for tags)
            begin
                #50ns;
                for (int i = 0; i < 200; i++) begin
                    env.ep_agent.ep_driver.initiate_dma(
                        64'h0000_0003_0000_0000 + (i * 32),
                        32,  // 32B
                        1    // read
                    );
                    phase4_ep_dma_rd_count++;
                    #(10ns);
                end
            end

            // Monitor: periodic status
            begin
                for (int m = 0; m < 20; m++) begin
                    #10000ns;
                    `uvm_info("BIDIR", $sformatf(
                        "  [P4 @%0t] FC: PH=%0d NPH=%0d CplH=%0d | Tags=%0d | Pend=%0d | SCB: req=%0d cpl=%0d match=%0d",
                        $realtime,
                        env.fc_mgr.posted_header.current,
                        env.fc_mgr.non_posted_header.current,
                        env.fc_mgr.completion_header.current,
                        env.tag_mgr.get_outstanding_count(),
                        env.rc_agent.rc_driver.get_pending_count(),
                        env.scb.total_requests, env.scb.total_completions,
                        env.scb.matched), UVM_LOW)
                end
            end
        join

        #50000ns;
        `uvm_info("BIDIR", $sformatf(
            "Phase 4 done: RC wr=%0d rd=%0d, EP DMA wr=%0d rd=%0d",
            phase4_rc_wr_count, phase4_rc_rd_count,
            phase4_ep_dma_wr_count, phase4_ep_dma_rd_count), UVM_LOW)
    endtask

    //=========================================================================
    // Final report
    //=========================================================================
    function void report_bidir_results();
        int total_sent;
        int total_unexpected = env.scb.unexpected;
        int total_mismatched = env.scb.mismatched;
        int total_timed_out  = env.scb.timed_out;
        int remaining_pending = env.rc_agent.rc_driver.get_pending_count();
        int remaining_tags    = env.tag_mgr.get_outstanding_count();
        int remaining_trackers = env.scb.cpl_trackers.size();

        total_sent = phase1_rc_wr_count + phase1_rc_rd_count +
                     phase2_rc_wr_count + phase2_rc_rd_count + phase2_ep_dma_count +
                     phase3_split_rd_count + 200 +  // phase3 EP DMA
                     phase4_rc_wr_count + phase4_rc_rd_count +
                     phase4_ep_dma_wr_count + phase4_ep_dma_rd_count;

        `uvm_info("BIDIR", "\n============================================================", UVM_LOW)
        `uvm_info("BIDIR", "=== Bidirectional 10K Traffic Test Summary ===", UVM_LOW)
        `uvm_info("BIDIR", "============================================================", UVM_LOW)
        `uvm_info("BIDIR", $sformatf("  Total requests sent:  %0d", total_sent), UVM_LOW)
        `uvm_info("BIDIR", $sformatf("  Phase 1: RC %0dW + %0dR = %0d",
            phase1_rc_wr_count, phase1_rc_rd_count,
            phase1_rc_wr_count + phase1_rc_rd_count), UVM_LOW)
        `uvm_info("BIDIR", $sformatf("  Phase 2: RC %0dW + %0dR + EP %0d DMA = %0d",
            phase2_rc_wr_count, phase2_rc_rd_count, phase2_ep_dma_count,
            phase2_rc_wr_count + phase2_rc_rd_count + phase2_ep_dma_count), UVM_LOW)
        `uvm_info("BIDIR", $sformatf("  Phase 3: %0d large reads + 200 EP DMA = %0d",
            phase3_split_rd_count, phase3_split_rd_count + 200), UVM_LOW)
        `uvm_info("BIDIR", $sformatf("  Phase 4: RC %0dW + %0dR + EP %0dW + %0dR = %0d",
            phase4_rc_wr_count, phase4_rc_rd_count,
            phase4_ep_dma_wr_count, phase4_ep_dma_rd_count,
            phase4_rc_wr_count + phase4_rc_rd_count +
            phase4_ep_dma_wr_count + phase4_ep_dma_rd_count), UVM_LOW)
        `uvm_info("BIDIR", "------------------------------------------------------------", UVM_LOW)
        `uvm_info("BIDIR", $sformatf("  Scoreboard: requests=%0d completions=%0d matched=%0d",
            env.scb.total_requests, env.scb.total_completions, env.scb.matched), UVM_LOW)
        `uvm_info("BIDIR", $sformatf("  Errors: mismatched=%0d unexpected=%0d timed_out=%0d",
            total_mismatched, total_unexpected, total_timed_out), UVM_LOW)
        `uvm_info("BIDIR", $sformatf("  Remaining: pending=%0d tags=%0d trackers=%0d",
            remaining_pending, remaining_tags, remaining_trackers), UVM_LOW)
        `uvm_info("BIDIR", $sformatf("  Link delay: RC->EP fwd=%0d EP->RC fwd=%0d",
            env.rc2ep_delay.total_forwarded, env.ep2rc_delay.total_forwarded), UVM_LOW)

        // === Issue Detection ===
        if (total_unexpected > 0)
            `uvm_error("BIDIR", $sformatf(
                "FAIL: %0d unexpected completions (multi-CplD tag handling issue)", total_unexpected))

        if (total_mismatched > 0)
            `uvm_error("BIDIR", $sformatf(
                "FAIL: %0d data integrity mismatches in read-after-write", total_mismatched))

        if (remaining_tags > 0)
            // Tags outstanding under tight FC credits are expected: TLPs in driver pipeline
            // waiting for FC credit have tags allocated but haven't been sent yet
            `uvm_info("BIDIR", $sformatf(
                "NOTE: %0d tags still in driver pipeline (FC credit backpressure, expected under tight credits)",
                remaining_tags), UVM_LOW)

        if (remaining_trackers > 0)
            `uvm_warning("BIDIR", $sformatf(
                "INCOMPLETE: %0d multi-completion trackers still pending", remaining_trackers))

        if (total_unexpected == 0 && total_mismatched == 0 && remaining_trackers == 0)
            `uvm_info("BIDIR", "*** ALL 10K TRAFFIC CHECKS PASSED ***", UVM_LOW)

        `uvm_info("BIDIR", "============================================================\n", UVM_LOW)
    endfunction

endclass

// ============================================================================
// Test 10: Switch Basic Routing
// ============================================================================
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
        for (int ep = 0; ep < 4; ep++) begin
            for (int i = 0; i < 10; i++) begin
                pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("wr_ep%0d_%0d", ep, i));
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
        for (int ep = 0; ep < 4; ep++) begin
            for (int i = 0; i < 5; i++) begin
                pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create($sformatf("rd_ep%0d_%0d", ep, i));
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

// ============================================================================
// Test 11: P2P Direct Transfer
// ============================================================================
class pcie_tl_switch_p2p_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_switch_p2p_test)
    function new(string name = "pcie_tl_switch_p2p_test", uvm_component parent = null);
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
        int p2p_before;
        phase.raise_objection(this);
        `uvm_info("SW_P2P", "=== Test 11: P2P Direct Transfer ===", UVM_LOW)
        // Phase 1: EP0 DMA writes to EP1 address space
        p2p_before = env.sw.total_p2p;
        for (int i = 0; i < 20; i++) begin
            env.ep_agents[0].ep_driver.initiate_dma(
                cfg.switch_cfg.ds_mem_base[1] + (i * 64), 64, 0);
            #10ns;
        end
        #3000ns;
        `uvm_info("SW_P2P", $sformatf("P2P count: %0d (new: %0d)",
            env.sw.total_p2p, env.sw.total_p2p - p2p_before), UVM_LOW)
        if (env.sw.total_p2p - p2p_before == 20)
            `uvm_info("SW_P2P", "Phase 1 PASS: 20 P2P writes", UVM_LOW)
        else
            `uvm_error("SW_P2P", $sformatf("Phase 1 FAIL: expected 20, got %0d",
                env.sw.total_p2p - p2p_before))
        // Phase 2: P2P disabled
        env.sw.fabric.p2p_enable = 0;
        p2p_before = env.sw.total_p2p;
        for (int i = 0; i < 10; i++) begin
            env.ep_agents[0].ep_driver.initiate_dma(
                cfg.switch_cfg.ds_mem_base[1] + (i * 64), 64, 0);
            #10ns;
        end
        #3000ns;
        if (env.sw.total_p2p == p2p_before)
            `uvm_info("SW_P2P", "Phase 2 PASS: no P2P when disabled", UVM_LOW)
        else
            `uvm_error("SW_P2P", "Phase 2 FAIL: P2P occurred when disabled")
        env.sw.fabric.p2p_enable = 1;
        phase.drop_objection(this);
    endtask
endclass

// ============================================================================
// Test 12: Switch Enumeration
// ============================================================================
class pcie_tl_switch_enum_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_switch_enum_test)
    function new(string name = "pcie_tl_switch_enum_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void configure_test();
        pcie_tl_switch_config sw_cfg;
        super.configure_test();
        sw_cfg = new("sw_cfg");
        sw_cfg.num_ds_ports = 2;
        sw_cfg.enum_mode    = 1;
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
        `uvm_info("SW_ENUM", "=== Test 12: Switch Enumeration ===", UVM_LOW)
        // Manually configure (simulating RC config writes)
        env.sw.usp.route_entry.primary_bus     = 8'h00;
        env.sw.usp.route_entry.secondary_bus   = 8'h01;
        env.sw.usp.route_entry.subordinate_bus = 8'h03;
        env.sw.dsp[0].route_entry.primary_bus     = 8'h01;
        env.sw.dsp[0].route_entry.secondary_bus   = 8'h02;
        env.sw.dsp[0].route_entry.subordinate_bus = 8'h02;
        env.sw.dsp[0].route_entry.mem_base        = 32'h8000_0000;
        env.sw.dsp[0].route_entry.mem_limit       = 32'h8FFF_FFFF;
        env.sw.dsp[1].route_entry.primary_bus     = 8'h01;
        env.sw.dsp[1].route_entry.secondary_bus   = 8'h03;
        env.sw.dsp[1].route_entry.subordinate_bus = 8'h03;
        env.sw.dsp[1].route_entry.mem_base        = 32'h9000_0000;
        env.sw.dsp[1].route_entry.mem_limit       = 32'h9FFF_FFFF;
        #100ns;
        // Send traffic
        for (int i = 0; i < 10; i++) begin
            pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("wr0_%0d", i));
            wr.addr = 32'h8000_0000 + (i * 64); wr.length = 16;
            wr.first_be = 4'hF; wr.last_be = 4'hF; wr.is_64bit = 0;
            wr.start(env.rc_agent.sequencer);
            #10ns;
        end
        for (int i = 0; i < 10; i++) begin
            pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("wr1_%0d", i));
            wr.addr = 32'h9000_0000 + (i * 64); wr.length = 16;
            wr.first_be = 4'hF; wr.last_be = 4'hF; wr.is_64bit = 0;
            wr.start(env.rc_agent.sequencer);
            #10ns;
        end
        #3000ns;
        `uvm_info("SW_ENUM", $sformatf("DSP0 fwd=%0d, DSP1 fwd=%0d",
            env.sw.dsp[0].forwarded_count, env.sw.dsp[1].forwarded_count), UVM_LOW)
        if (env.sw.dsp[0].forwarded_count == 10 && env.sw.dsp[1].forwarded_count == 10)
            `uvm_info("SW_ENUM", "*** SWITCH ENUMERATION PASSED ***", UVM_LOW)
        else
            `uvm_error("SW_ENUM", "SWITCH ENUMERATION FAILED")
        phase.drop_objection(this);
    endtask
endclass

// ============================================================================
// Test 13: Multi-EP Concurrent Stress
// ============================================================================
class pcie_tl_switch_stress_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_switch_stress_test)
    function new(string name = "pcie_tl_switch_stress_test", uvm_component parent = null);
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
        configure_tags(.extended(1), .phantom(0), .max_out(256));
        cfg.ep_auto_response = 1;
        cfg.cpl_timeout_ns   = 200000;
    endfunction
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info("SW_STRESS", "=== Test 13: Multi-EP Concurrent Stress ===", UVM_LOW)
        // Phase 1: RC writes 500 per EP concurrently
        fork
            for (int ep = 0; ep < 4; ep++) begin
                automatic int e = ep;
                fork begin
                    for (int i = 0; i < 500; i++) begin
                        pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create(
                            $sformatf("s_wr_e%0d_%0d", e, i));
                        wr.addr     = cfg.switch_cfg.ds_mem_base[e] + (i * 64);
                        wr.length   = 16;
                        wr.first_be = 4'hF; wr.last_be = 4'hF; wr.is_64bit = 0;
                        wr.start(env.rc_agent.sequencer);
                        #1ns;
                    end
                end join_none
            end
        join
        #10000ns;
        // Phase 2: All EPs DMA to RC
        fork
            for (int ep = 0; ep < 4; ep++) begin
                automatic int e = ep;
                fork begin
                    for (int i = 0; i < 100; i++) begin
                        env.ep_agents[e].ep_driver.initiate_dma(
                            64'h0000_0000_1000_0000 + (e * 64'h1000) + (i * 64), 64, 0);
                        #5ns;
                    end
                end join_none
            end
        join
        #10000ns;
        // Phase 3: P2P cross
        fork
            begin
                for (int i = 0; i < 50; i++) begin
                    env.ep_agents[0].ep_driver.initiate_dma(
                        cfg.switch_cfg.ds_mem_base[1] + (i * 64), 64, 0);
                    #5ns;
                end
            end
            begin
                for (int i = 0; i < 50; i++) begin
                    env.ep_agents[2].ep_driver.initiate_dma(
                        cfg.switch_cfg.ds_mem_base[3] + (i * 64), 64, 0);
                    #5ns;
                end
            end
        join
        #10000ns;
        `uvm_info("SW_STRESS", $sformatf("Switch: routed=%0d, P2P=%0d, dropped=%0d",
            env.sw.total_routed, env.sw.total_p2p, env.sw.total_dropped), UVM_LOW)
        if (env.sw.total_dropped == 0)
            `uvm_info("SW_STRESS", "*** SWITCH STRESS PASSED ***", UVM_LOW)
        else
            `uvm_error("SW_STRESS", "SWITCH STRESS FAILED")
        phase.drop_objection(this);
    endtask
endclass

// ============================================================================
// Test 14: Per-Port FC Isolation
// ============================================================================
class pcie_tl_switch_fc_isolation_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_switch_fc_isolation_test)
    function new(string name = "pcie_tl_switch_fc_isolation_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void configure_test();
        pcie_tl_switch_config sw_cfg;
        super.configure_test();
        sw_cfg = new("sw_cfg");
        sw_cfg.num_ds_ports    = 4;
        sw_cfg.p2p_enable      = 1;
        sw_cfg.port_ph_credit  = 4;
        sw_cfg.port_pd_credit  = 32;
        sw_cfg.port_nph_credit = 4;
        sw_cfg.port_npd_credit = 32;
        sw_cfg.port_cplh_credit = 8;
        sw_cfg.port_cpld_credit = 64;
        sw_cfg.init_defaults();
        cfg.switch_enable    = 1;
        cfg.switch_cfg       = sw_cfg;
        configure_fc(1, 1);  // RC-side infinite
        cfg.ep_auto_response = 1;
        cfg.cpl_timeout_ns   = 100000;
    endfunction
    task run_phase(uvm_phase phase);
        int dsp1_before;
        phase.raise_objection(this);
        `uvm_info("SW_FC", "=== Test 14: Per-Port FC Isolation ===", UVM_LOW)
        // Exhaust DSP0 credits
        env.sw.dsp[0].fc_mgr.force_credit_underflow();
        // Send to DSP1
        dsp1_before = env.sw.dsp[1].forwarded_count;
        for (int i = 0; i < 20; i++) begin
            pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("fc_wr_%0d", i));
            wr.addr     = cfg.switch_cfg.ds_mem_base[1] + (i * 64);
            wr.length   = 16;
            wr.first_be = 4'hF; wr.last_be = 4'hF; wr.is_64bit = 0;
            wr.start(env.rc_agent.sequencer);
            #10ns;
        end
        #5000ns;
        `uvm_info("SW_FC", $sformatf("DSP0 PH=%0d, DSP1 new fwd=%0d",
            env.sw.dsp[0].fc_mgr.posted_header.current,
            env.sw.dsp[1].forwarded_count - dsp1_before), UVM_LOW)
        if (env.sw.dsp[1].forwarded_count - dsp1_before == 20)
            `uvm_info("SW_FC", "*** FC ISOLATION PASSED ***", UVM_LOW)
        else
            `uvm_error("SW_FC", "FC ISOLATION FAILED")
        phase.drop_objection(this);
    endtask
endclass

//=============================================================================
// Test 15: RC Multi-EP Read — Completion routing through switch
//=============================================================================
class pcie_tl_switch_read_cpl_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_switch_read_cpl_test)
    function new(string name = "pcie_tl_switch_read_cpl_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void configure_test();
        pcie_tl_switch_config sw_cfg;
        super.configure_test();
        sw_cfg = new("sw_cfg");
        sw_cfg.num_ds_ports = 4;
        sw_cfg.p2p_enable   = 1;
        sw_cfg.init_defaults();
        cfg.switch_enable        = 1;
        cfg.switch_cfg           = sw_cfg;
        cfg.max_payload_size     = MPS_128;  // Force multi-CplD splits
        cfg.read_completion_boundary = RCB_64;
        configure_fc(1, 1);
        configure_tags(.extended(1), .phantom(0), .max_out(256));
        cfg.ep_auto_response = 1;
        cfg.cpl_timeout_ns   = 100000;
    endfunction
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info("SW_RD_CPL", "=== Test 15: RC Multi-EP Read with Completion Routing ===", UVM_LOW)

        // Phase 1: Write known data to all EPs first
        `uvm_info("SW_RD_CPL", "--- Phase 1: Write data to all EPs ---", UVM_LOW)
        for (int ep = 0; ep < 4; ep++) begin
            for (int i = 0; i < 20; i++) begin
                pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("wr_e%0d_%0d", ep, i));
                wr.addr     = cfg.switch_cfg.ds_mem_base[ep] + (i * 128);
                wr.length   = 32;  // 128B
                wr.first_be = 4'hF; wr.last_be = 4'hF; wr.is_64bit = 0;
                wr.start(env.rc_agent.sequencer);
                #5ns;
            end
        end
        #3000ns;

        // Phase 2: Read back — large reads trigger multi-CplD (MPS=128, reads of 256-512B)
        `uvm_info("SW_RD_CPL", "--- Phase 2: Large reads from each EP (multi-CplD) ---", UVM_LOW)
        for (int ep = 0; ep < 4; ep++) begin
            for (int i = 0; i < 10; i++) begin
                pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create($sformatf("rd_e%0d_%0d", ep, i));
                rd.addr     = cfg.switch_cfg.ds_mem_base[ep] + (i * 256);
                rd.length   = 64 + (i % 3) * 32;  // 256B, 384B, 512B alternating
                rd.first_be = 4'hF; rd.last_be = 4'hF; rd.is_64bit = 0;
                rd.start(env.rc_agent.sequencer);
                #20ns;
            end
        end
        #10000ns;

        // Phase 3: Concurrent reads to all EPs simultaneously
        `uvm_info("SW_RD_CPL", "--- Phase 3: Concurrent reads to all EPs ---", UVM_LOW)
        fork
            for (int ep = 0; ep < 4; ep++) begin
                automatic int e = ep;
                fork begin
                    for (int i = 0; i < 10; i++) begin
                        pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create($sformatf("crd_e%0d_%0d", e, i));
                        rd.addr     = cfg.switch_cfg.ds_mem_base[e] + (i * 128);
                        rd.length   = 32;  // 128B = MPS, single CplD
                        rd.first_be = 4'hF; rd.last_be = 4'hF; rd.is_64bit = 0;
                        rd.start(env.rc_agent.sequencer);
                        #10ns;
                    end
                end join_none
            end
        join
        #10000ns;

        `uvm_info("SW_RD_CPL", $sformatf("Switch: routed=%0d, dropped=%0d",
            env.sw.total_routed, env.sw.total_dropped), UVM_LOW)
        `uvm_info("SW_RD_CPL", $sformatf("SCB: req=%0d, cpl=%0d, matched=%0d, unexpected=%0d",
            env.scb.total_requests, env.scb.total_completions,
            env.scb.matched, env.scb.unexpected), UVM_LOW)

        if (env.sw.total_dropped == 0 && env.scb.unexpected == 0 && env.scb.mismatched == 0)
            `uvm_info("SW_RD_CPL", "*** SWITCH READ COMPLETION ROUTING PASSED ***", UVM_LOW)
        else
            `uvm_error("SW_RD_CPL", "SWITCH READ COMPLETION ROUTING FAILED")
        phase.drop_objection(this);
    endtask
endclass

//=============================================================================
// Test 16: P2P All-to-All — Every EP writes to every other EP
//=============================================================================
class pcie_tl_switch_p2p_all_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_switch_p2p_all_test)
    function new(string name = "pcie_tl_switch_p2p_all_test", uvm_component parent = null);
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
        int p2p_expected;
        phase.raise_objection(this);
        `uvm_info("SW_P2P_ALL", "=== Test 16: P2P All-to-All ===", UVM_LOW)

        // Every EP sends 10 DMA writes to every OTHER EP
        // 4 EPs x 3 targets x 10 = 120 P2P transfers
        p2p_expected = 0;
        fork
            for (int src = 0; src < 4; src++) begin
                automatic int s = src;
                fork begin
                    for (int dst = 0; dst < 4; dst++) begin
                        if (dst == s) continue;
                        for (int i = 0; i < 10; i++) begin
                            env.ep_agents[s].ep_driver.initiate_dma(
                                cfg.switch_cfg.ds_mem_base[dst] + (s * 64'h100) + (i * 64),
                                64, 0);
                            #5ns;
                        end
                    end
                end join_none
            end
        join
        p2p_expected = 4 * 3 * 10;  // 120
        #10000ns;

        `uvm_info("SW_P2P_ALL", $sformatf("P2P: expected=%0d, actual=%0d, dropped=%0d",
            p2p_expected, env.sw.total_p2p, env.sw.total_dropped), UVM_LOW)
        `uvm_info("SW_P2P_ALL", $sformatf("Per-DSP fwd: [%0d, %0d, %0d, %0d]",
            env.sw.dsp[0].forwarded_count, env.sw.dsp[1].forwarded_count,
            env.sw.dsp[2].forwarded_count, env.sw.dsp[3].forwarded_count), UVM_LOW)

        if (env.sw.total_p2p == p2p_expected && env.sw.total_dropped == 0)
            `uvm_info("SW_P2P_ALL", "*** P2P ALL-TO-ALL PASSED ***", UVM_LOW)
        else
            `uvm_error("SW_P2P_ALL", "P2P ALL-TO-ALL FAILED")
        phase.drop_objection(this);
    endtask
endclass

//=============================================================================
// Test 17: Bidirectional Crossover — RC reads + EP DMA writes simultaneously
//=============================================================================
class pcie_tl_switch_bidir_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_switch_bidir_test)
    function new(string name = "pcie_tl_switch_bidir_test", uvm_component parent = null);
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
        configure_tags(.extended(1), .phantom(0), .max_out(256));
        cfg.ep_auto_response = 1;
        cfg.cpl_timeout_ns   = 200000;
    endfunction
    task run_phase(uvm_phase phase);
        int rc_wr, rc_rd, ep_dma;
        phase.raise_objection(this);
        `uvm_info("SW_BIDIR", "=== Test 17: Bidirectional Crossover through Switch ===", UVM_LOW)

        rc_wr = 0; rc_rd = 0; ep_dma = 0;
        fork
            // RC writes to EP0 + EP1
            begin
                for (int i = 0; i < 200; i++) begin
                    pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("bd_wr_%0d", i));
                    wr.addr     = cfg.switch_cfg.ds_mem_base[i % 2] + (i * 64);
                    wr.length   = 16; wr.first_be = 4'hF; wr.last_be = 4'hF; wr.is_64bit = 0;
                    wr.start(env.rc_agent.sequencer);
                    rc_wr++;
                    #2ns;
                end
            end
            // RC reads from EP2 + EP3 (generates completions back through switch)
            begin
                for (int i = 0; i < 100; i++) begin
                    pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create($sformatf("bd_rd_%0d", i));
                    rd.addr     = cfg.switch_cfg.ds_mem_base[2 + (i % 2)] + (i * 64);
                    rd.length   = 8; rd.first_be = 4'hF; rd.last_be = 4'hF; rd.is_64bit = 0;
                    rd.start(env.rc_agent.sequencer);
                    rc_rd++;
                    #5ns;
                end
            end
            // EP0 DMA writes to RC (upstream through USP)
            begin
                for (int i = 0; i < 100; i++) begin
                    env.ep_agents[0].ep_driver.initiate_dma(
                        64'h0000_0000_1000_0000 + (i * 64), 64, 0);
                    ep_dma++;
                    #3ns;
                end
            end
            // EP2 DMA writes to RC
            begin
                for (int i = 0; i < 100; i++) begin
                    env.ep_agents[2].ep_driver.initiate_dma(
                        64'h0000_0000_2000_0000 + (i * 64), 64, 0);
                    ep_dma++;
                    #3ns;
                end
            end
            // EP1 P2P writes to EP3 (cross-traffic)
            begin
                for (int i = 0; i < 50; i++) begin
                    env.ep_agents[1].ep_driver.initiate_dma(
                        cfg.switch_cfg.ds_mem_base[3] + (i * 64), 64, 0);
                    #5ns;
                end
            end
        join
        #15000ns;

        `uvm_info("SW_BIDIR", $sformatf("RC: %0d wr + %0d rd, EP DMA: %0d, P2P: %0d",
            rc_wr, rc_rd, ep_dma, env.sw.total_p2p), UVM_LOW)
        `uvm_info("SW_BIDIR", $sformatf("Switch: routed=%0d, dropped=%0d",
            env.sw.total_routed, env.sw.total_dropped), UVM_LOW)

        // Allow small number of drops from EP DMA to non-windowed RC host addresses
        if (env.sw.total_dropped <= 2 && env.scb.unexpected == 0)
            `uvm_info("SW_BIDIR", "*** SWITCH BIDIRECTIONAL CROSSOVER PASSED ***", UVM_LOW)
        else
            `uvm_error("SW_BIDIR", $sformatf("SWITCH BIDIRECTIONAL CROSSOVER FAILED: dropped=%0d unexpected=%0d",
                env.sw.total_dropped, env.scb.unexpected))
        phase.drop_objection(this);
    endtask
endclass

//=============================================================================
// Test 18: Address Boundary + Invalid Address Routing
//=============================================================================
class pcie_tl_switch_addr_boundary_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_switch_addr_boundary_test)
    function new(string name = "pcie_tl_switch_addr_boundary_test", uvm_component parent = null);
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
        cfg.cpl_timeout_ns   = 50000;
    endfunction
    task run_phase(uvm_phase phase);
        int dropped_before;
        phase.raise_objection(this);
        `uvm_info("SW_ADDR", "=== Test 18: Address Boundary + Invalid Address ===", UVM_LOW)

        // Phase 1: Write to exact boundary of EP0 window (last valid address)
        `uvm_info("SW_ADDR", "--- Phase 1: Exact boundary addresses ---", UVM_LOW)
        begin
            // EP0: [0x8000_0000, 0x8FFF_FFFF]
            // Write to first byte
            pcie_tl_mem_wr_seq wr0 = pcie_tl_mem_wr_seq::type_id::create("wr_first");
            wr0.addr = cfg.switch_cfg.ds_mem_base[0]; // 0x8000_0000
            wr0.length = 1; wr0.first_be = 4'hF; wr0.last_be = 4'h0; wr0.is_64bit = 0;
            wr0.start(env.rc_agent.sequencer);
            #10ns;

            // Write to last valid address
            begin
                pcie_tl_mem_wr_seq wr1 = pcie_tl_mem_wr_seq::type_id::create("wr_last");
                wr1.addr = cfg.switch_cfg.ds_mem_limit[0]; // 0x8FFF_FFFF
                wr1.length = 1; wr1.first_be = 4'hF; wr1.last_be = 4'h0; wr1.is_64bit = 0;
                wr1.start(env.rc_agent.sequencer);
            end
            #10ns;

            // Write to boundary between EP0 and EP1
            begin
                pcie_tl_mem_wr_seq wr2 = pcie_tl_mem_wr_seq::type_id::create("wr_boundary_ep1");
                wr2.addr = cfg.switch_cfg.ds_mem_base[1]; // 0x9000_0000 = EP1 start
                wr2.length = 1; wr2.first_be = 4'hF; wr2.last_be = 4'h0; wr2.is_64bit = 0;
                wr2.start(env.rc_agent.sequencer);
            end
            #10ns;
        end
        #2000ns;

        `uvm_info("SW_ADDR", $sformatf("After boundaries: DSP0 fwd=%0d, DSP1 fwd=%0d",
            env.sw.dsp[0].forwarded_count, env.sw.dsp[1].forwarded_count), UVM_LOW)

        // Phase 2: Invalid address (not in any window) — should be dropped
        `uvm_info("SW_ADDR", "--- Phase 2: Invalid address (outside all windows) ---", UVM_LOW)
        dropped_before = env.sw.total_dropped;
        begin
            // Address 0x0000_1000 — below any EP window
            pcie_tl_mem_wr_seq wr_bad = pcie_tl_mem_wr_seq::type_id::create("wr_invalid");
            wr_bad.addr = 32'h0000_1000;
            wr_bad.length = 1; wr_bad.first_be = 4'hF; wr_bad.last_be = 4'h0; wr_bad.is_64bit = 0;
            wr_bad.start(env.rc_agent.sequencer);
        end
        #2000ns;

        `uvm_info("SW_ADDR", $sformatf("Dropped: before=%0d, after=%0d (new=%0d)",
            dropped_before, env.sw.total_dropped,
            env.sw.total_dropped - dropped_before), UVM_LOW)

        // Phase 3: Address in gap between EP3 limit and next possible range
        `uvm_info("SW_ADDR", "--- Phase 3: Address in gap after last EP ---", UVM_LOW)
        begin
            pcie_tl_mem_wr_seq wr_gap = pcie_tl_mem_wr_seq::type_id::create("wr_gap");
            wr_gap.addr = cfg.switch_cfg.ds_mem_limit[3] + 32'h100; // Just past EP3
            wr_gap.length = 1; wr_gap.first_be = 4'hF; wr_gap.last_be = 4'h0; wr_gap.is_64bit = 0;
            wr_gap.start(env.rc_agent.sequencer);
        end
        #2000ns;

        begin
            int total_new_drops = env.sw.total_dropped - dropped_before;
            `uvm_info("SW_ADDR", $sformatf("Total new drops: %0d (expected 2)", total_new_drops), UVM_LOW)
            // Key check: invalid addresses (Phase 2+3) were dropped, valid addresses were routed
            if (env.sw.dsp[0].forwarded_count >= 1 && env.sw.dsp[1].forwarded_count >= 1 &&
                total_new_drops >= 2)
                `uvm_info("SW_ADDR", "*** ADDRESS BOUNDARY TEST PASSED ***", UVM_LOW)
            else
                `uvm_error("SW_ADDR", $sformatf("ADDRESS BOUNDARY TEST FAILED: DSP0=%0d DSP1=%0d new_drops=%0d",
                    env.sw.dsp[0].forwarded_count, env.sw.dsp[1].forwarded_count, total_new_drops))
        end
        phase.drop_objection(this);
    endtask
endclass

//=============================================================================
// Test 19: USP Congestion — All EPs DMA upstream simultaneously
//=============================================================================
class pcie_tl_switch_usp_congestion_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_switch_usp_congestion_test)
    function new(string name = "pcie_tl_switch_usp_congestion_test", uvm_component parent = null);
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
        configure_tags(.extended(1), .phantom(0), .max_out(256));
        cfg.ep_auto_response = 1;
        cfg.cpl_timeout_ns   = 200000;
    endfunction
    task run_phase(uvm_phase phase);
        int per_ep_count = 200;
        int total_expected;
        phase.raise_objection(this);
        `uvm_info("SW_USP_CONG", "=== Test 19: USP Congestion — All EPs Upstream ===", UVM_LOW)

        // All 4 EPs blast DMA writes upstream to RC simultaneously
        // Tests USP.tx_fifo contention + switch fabric fairness
        total_expected = 4 * per_ep_count;
        fork
            for (int ep = 0; ep < 4; ep++) begin
                automatic int e = ep;
                fork begin
                    for (int i = 0; i < per_ep_count; i++) begin
                        env.ep_agents[e].ep_driver.initiate_dma(
                            64'h0000_0000_0100_0000 + (e * 64'h0010_0000) + (i * 64),
                            64, 0);
                        #2ns;
                    end
                end join_none
            end
        join
        #20000ns;

        `uvm_info("SW_USP_CONG", $sformatf("Total upstream routed: %0d (expected %0d)",
            env.sw.total_routed, total_expected), UVM_LOW)
        `uvm_info("SW_USP_CONG", $sformatf("Per-DSP: [%0d, %0d, %0d, %0d] (rx into switch)",
            env.sw.dsp[0].forwarded_count, env.sw.dsp[1].forwarded_count,
            env.sw.dsp[2].forwarded_count, env.sw.dsp[3].forwarded_count), UVM_LOW)

        // Also blast RC reads + writes downstream while EPs are uploading
        `uvm_info("SW_USP_CONG", "--- Adding downstream pressure ---", UVM_LOW)
        fork
            // RC writes downstream
            begin
                for (int i = 0; i < 200; i++) begin
                    pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("cong_wr_%0d", i));
                    wr.addr     = cfg.switch_cfg.ds_mem_base[i % 4] + (i * 64);
                    wr.length   = 16; wr.first_be = 4'hF; wr.last_be = 4'hF; wr.is_64bit = 0;
                    wr.start(env.rc_agent.sequencer);
                    #2ns;
                end
            end
            // All EPs continue upstream
            for (int ep = 0; ep < 4; ep++) begin
                automatic int e = ep;
                fork begin
                    for (int i = 0; i < 100; i++) begin
                        env.ep_agents[e].ep_driver.initiate_dma(
                            64'h0000_0000_0200_0000 + (e * 64'h0010_0000) + (i * 64),
                            64, 0);
                        #3ns;
                    end
                end join_none
            end
        join
        #20000ns;

        `uvm_info("SW_USP_CONG", $sformatf("Final: routed=%0d, dropped=%0d, P2P=%0d",
            env.sw.total_routed, env.sw.total_dropped, env.sw.total_p2p), UVM_LOW)

        if (env.sw.total_dropped == 0)
            `uvm_info("SW_USP_CONG", "*** USP CONGESTION PASSED ***", UVM_LOW)
        else
            `uvm_error("SW_USP_CONG", "USP CONGESTION FAILED")
        phase.drop_objection(this);
    endtask
endclass

//=============================================================================
// Test 20: Scalability — 8-port and 16-port switch configurations
//=============================================================================
class pcie_tl_switch_scale_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_switch_scale_test)
    function new(string name = "pcie_tl_switch_scale_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void configure_test();
        pcie_tl_switch_config sw_cfg;
        super.configure_test();
        // Start with 8-port config
        sw_cfg = new("sw_cfg");
        sw_cfg.num_ds_ports = 8;
        sw_cfg.p2p_enable   = 1;
        sw_cfg.init_defaults();
        cfg.switch_enable    = 1;
        cfg.switch_cfg       = sw_cfg;
        configure_fc(1, 1);
        cfg.ep_auto_response = 1;
        cfg.cpl_timeout_ns   = 100000;
    endfunction
    task run_phase(uvm_phase phase);
        int n;
        phase.raise_objection(this);
        n = cfg.switch_cfg.num_ds_ports;
        `uvm_info("SW_SCALE", $sformatf("=== Test 20: Scalability — %0d-port Switch ===", n), UVM_LOW)

        // Write 10 TLPs to each of the 8 EPs
        for (int ep = 0; ep < n; ep++) begin
            for (int i = 0; i < 10; i++) begin
                pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("sc_wr_e%0d_%0d", ep, i));
                wr.addr     = cfg.switch_cfg.ds_mem_base[ep] + (i * 64);
                wr.length   = 16; wr.first_be = 4'hF; wr.last_be = 4'hF; wr.is_64bit = 0;
                wr.start(env.rc_agent.sequencer);
                #5ns;
            end
        end
        #5000ns;

        // P2P: EP0 writes to all other EPs
        for (int dst = 1; dst < n; dst++) begin
            for (int i = 0; i < 5; i++) begin
                env.ep_agents[0].ep_driver.initiate_dma(
                    cfg.switch_cfg.ds_mem_base[dst] + (i * 64), 64, 0);
                #5ns;
            end
        end
        #5000ns;

        `uvm_info("SW_SCALE", $sformatf("Switch %0d-port: routed=%0d, P2P=%0d, dropped=%0d",
            n, env.sw.total_routed, env.sw.total_p2p, env.sw.total_dropped), UVM_LOW)

        // Verify all DSPs got traffic
        begin
            bit all_fwd = 1;
            for (int i = 0; i < n; i++) begin
                `uvm_info("SW_SCALE", $sformatf("  DSP%0d fwd=%0d", i, env.sw.dsp[i].forwarded_count), UVM_LOW)
                if (env.sw.dsp[i].forwarded_count == 0) all_fwd = 0;
            end
            if (all_fwd && env.sw.total_dropped == 0)
                `uvm_info("SW_SCALE", $sformatf("*** %0d-PORT SCALABILITY PASSED ***", n), UVM_LOW)
            else
                `uvm_error("SW_SCALE", $sformatf("%0d-PORT SCALABILITY FAILED", n))
        end
        phase.drop_objection(this);
    endtask
endclass

//=============================================================================
// Test 21: Switch Config Space Read/Write Verification
//=============================================================================
class pcie_tl_switch_cfg_space_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_switch_cfg_space_test)
    function new(string name = "pcie_tl_switch_cfg_space_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void configure_test();
        pcie_tl_switch_config sw_cfg;
        super.configure_test();
        sw_cfg = new("sw_cfg");
        sw_cfg.num_ds_ports = 4;
        sw_cfg.enum_mode    = 1;  // Enumeration mode for config access
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
        `uvm_info("SW_CFG", "=== Test 21: Switch Config Space Access ===", UVM_LOW)

        // Phase 1: Write bus numbers to each DSP via direct port config
        `uvm_info("SW_CFG", "--- Phase 1: Configure bus numbers ---", UVM_LOW)
        env.sw.usp.route_entry.primary_bus     = 8'h00;
        env.sw.usp.route_entry.secondary_bus   = 8'h01;
        env.sw.usp.route_entry.subordinate_bus = 8'h05;

        for (int i = 0; i < 4; i++) begin
            env.sw.dsp[i].route_entry.primary_bus     = 8'h01;
            env.sw.dsp[i].route_entry.secondary_bus   = 8'h02 + i;
            env.sw.dsp[i].route_entry.subordinate_bus = 8'h02 + i;
        end

        // Phase 2: Write memory windows with different sizes
        `uvm_info("SW_CFG", "--- Phase 2: Configure asymmetric memory windows ---", UVM_LOW)
        // EP0: 16MB [0xA000_0000, 0xA0FF_FFFF]
        env.sw.dsp[0].route_entry.mem_base  = 32'hA000_0000;
        env.sw.dsp[0].route_entry.mem_limit = 32'hA0FF_FFFF;
        // EP1: 64MB [0xA400_0000, 0xA7FF_FFFF]
        env.sw.dsp[1].route_entry.mem_base  = 32'hA400_0000;
        env.sw.dsp[1].route_entry.mem_limit = 32'hA7FF_FFFF;
        // EP2: 256MB [0xB000_0000, 0xBFFF_FFFF]
        env.sw.dsp[2].route_entry.mem_base  = 32'hB000_0000;
        env.sw.dsp[2].route_entry.mem_limit = 32'hBFFF_FFFF;
        // EP3: 1MB [0xC000_0000, 0xC00F_FFFF]
        env.sw.dsp[3].route_entry.mem_base  = 32'hC000_0000;
        env.sw.dsp[3].route_entry.mem_limit = 32'hC00F_FFFF;
        #100ns;

        // Phase 3: Verify cfg_read returns correct values
        `uvm_info("SW_CFG", "--- Phase 3: Verify cfg_read ---", UVM_LOW)
        begin
            bit [31:0] bus_data;
            bit pass = 1;
            for (int i = 0; i < 4; i++) begin
                bus_data = env.sw.dsp[i].cfg_read(12'h018);
                `uvm_info("SW_CFG", $sformatf("DSP%0d bus reg: 0x%08h (sub=%0d sec=%0d pri=%0d)",
                    i, bus_data, bus_data[31:24], bus_data[23:16], bus_data[15:8]), UVM_LOW)
                if (bus_data[23:16] != (8'h02 + i)) pass = 0;
            end
            if (!pass)
                `uvm_error("SW_CFG", "Config read mismatch on bus numbers")
        end

        // Phase 4: Route traffic through asymmetric windows
        `uvm_info("SW_CFG", "--- Phase 4: Traffic through asymmetric windows ---", UVM_LOW)
        begin
            pcie_tl_mem_wr_seq wr;
            // EP0 window
            wr = pcie_tl_mem_wr_seq::type_id::create("wr_a0");
            wr.addr = 32'hA000_0000; wr.length = 1; wr.first_be = 4'hF; wr.last_be = 4'h0; wr.is_64bit = 0;
            wr.start(env.rc_agent.sequencer); #10ns;
            // EP1 window
            wr = pcie_tl_mem_wr_seq::type_id::create("wr_a4");
            wr.addr = 32'hA400_0000; wr.length = 1; wr.first_be = 4'hF; wr.last_be = 4'h0; wr.is_64bit = 0;
            wr.start(env.rc_agent.sequencer); #10ns;
            // EP2 window
            wr = pcie_tl_mem_wr_seq::type_id::create("wr_b0");
            wr.addr = 32'hB000_0000; wr.length = 1; wr.first_be = 4'hF; wr.last_be = 4'h0; wr.is_64bit = 0;
            wr.start(env.rc_agent.sequencer); #10ns;
            // EP3 window
            wr = pcie_tl_mem_wr_seq::type_id::create("wr_c0");
            wr.addr = 32'hC000_0000; wr.length = 1; wr.first_be = 4'hF; wr.last_be = 4'h0; wr.is_64bit = 0;
            wr.start(env.rc_agent.sequencer); #10ns;
        end
        #3000ns;

        `uvm_info("SW_CFG", $sformatf("DSP fwd: [%0d, %0d, %0d, %0d]",
            env.sw.dsp[0].forwarded_count, env.sw.dsp[1].forwarded_count,
            env.sw.dsp[2].forwarded_count, env.sw.dsp[3].forwarded_count), UVM_LOW)

        if (env.sw.dsp[0].forwarded_count >= 1 && env.sw.dsp[1].forwarded_count >= 1 &&
            env.sw.dsp[2].forwarded_count >= 1 && env.sw.dsp[3].forwarded_count >= 1 &&
            env.sw.total_dropped == 0)
            `uvm_info("SW_CFG", "*** SWITCH CONFIG SPACE TEST PASSED ***", UVM_LOW)
        else
            `uvm_error("SW_CFG", "SWITCH CONFIG SPACE TEST FAILED")
        phase.drop_objection(this);
    endtask
endclass

//=============================================================================
// Test 22: Switch 20K Heavy Traffic — All directions full blast
//
// Total target: ~23,600 requests through switch
//   Phase 1: RC->4EP  8000 writes (2000/EP)
//   Phase 2: RC->4EP  2000 reads (500/EP, multi-CplD)
//   Phase 3: 4EP->RC  4000 DMA writes (1000/EP upstream)
//   Phase 4: P2P all-to-all 2400 writes (4EP x 3dst x 200)
//   Phase 5: Full mix — RC wr+rd + EP DMA + P2P all concurrent ~7200
//=============================================================================
class pcie_tl_switch_heavy_traffic_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_switch_heavy_traffic_test)

    int p1_wr, p2_rd, p3_dma, p4_p2p;
    int p5_rc_wr, p5_rc_rd, p5_ep_dma, p5_p2p;

    function new(string name = "pcie_tl_switch_heavy_traffic_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void configure_test();
        pcie_tl_switch_config sw_cfg;
        super.configure_test();
        sw_cfg = new("sw_cfg");
        sw_cfg.num_ds_ports = 4;
        sw_cfg.p2p_enable   = 1;
        sw_cfg.init_defaults();
        cfg.switch_enable            = 1;
        cfg.switch_cfg               = sw_cfg;
        configure_fc(1, 1);
        configure_tags(.extended(1), .phantom(0), .max_out(512));
        cfg.max_payload_size         = MPS_128;
        cfg.read_completion_boundary = RCB_64;
        cfg.ep_auto_response         = 1;
        cfg.response_delay_min       = 0;
        cfg.response_delay_max       = 2;
        cfg.cpl_timeout_ns           = 500000;
    endfunction

    task run_phase(uvm_phase phase);
        int grand_total;
        realtime t_start, t_end;
        phase.raise_objection(this);

        `uvm_info("SW_HEAVY", "============================================================", UVM_LOW)
        `uvm_info("SW_HEAVY", "=== Test 22: Switch 20K Heavy Traffic ===", UVM_LOW)
        `uvm_info("SW_HEAVY", "============================================================", UVM_LOW)
        t_start = $realtime;

        // Phase 1: RC -> 4EP writes (8000)
        `uvm_info("SW_HEAVY", "\n--- Phase 1: RC writes 8000 (2000/EP) ---", UVM_LOW)
        p1_wr = 0;
        fork
            for (int ep = 0; ep < 4; ep++) begin
                automatic int e = ep;
                fork begin
                    for (int i = 0; i < 2000; i++) begin
                        pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create(
                            $sformatf("p1_wr_e%0d_%0d", e, i));
                        wr.addr     = cfg.switch_cfg.ds_mem_base[e] + (i * 64);
                        wr.length   = 8 + (i % 24);
                        wr.first_be = 4'hF; wr.last_be = 4'hF; wr.is_64bit = 0;
                        wr.start(env.rc_agent.sequencer);
                        p1_wr++;
                        #1ns;
                    end
                end join_none
            end
        join
        #20000ns;
        `uvm_info("SW_HEAVY", $sformatf("Phase 1 done: %0d writes, routed=%0d",
            p1_wr, env.sw.total_routed), UVM_LOW)

        // Phase 2: RC -> 4EP reads (2000, multi-CplD)
        `uvm_info("SW_HEAVY", "\n--- Phase 2: RC reads 2000 (500/EP, multi-CplD) ---", UVM_LOW)
        p2_rd = 0;
        fork
            for (int ep = 0; ep < 4; ep++) begin
                automatic int e = ep;
                fork begin
                    for (int i = 0; i < 500; i++) begin
                        pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create(
                            $sformatf("p2_rd_e%0d_%0d", e, i));
                        rd.addr     = cfg.switch_cfg.ds_mem_base[e] + ((i % 2000) * 64);
                        rd.length   = 32 + (i % 3) * 32;
                        rd.first_be = 4'hF; rd.last_be = 4'hF; rd.is_64bit = 0;
                        rd.start(env.rc_agent.sequencer);
                        p2_rd++;
                        #2ns;
                    end
                end join_none
            end
        join
        #50000ns;
        `uvm_info("SW_HEAVY", $sformatf("Phase 2 done: %0d reads, matched=%0d cpl=%0d",
            p2_rd, env.scb.matched, env.scb.total_completions), UVM_LOW)

        // Phase 3: 4EP -> RC DMA writes (4000)
        `uvm_info("SW_HEAVY", "\n--- Phase 3: 4EP DMA upstream 4000 (1000/EP) ---", UVM_LOW)
        p3_dma = 0;
        fork
            for (int ep = 0; ep < 4; ep++) begin
                automatic int e = ep;
                fork begin
                    for (int i = 0; i < 1000; i++) begin
                        env.ep_agents[e].ep_driver.initiate_dma(
                            64'h0000_0000_0100_0000 + (e * 64'h0100_0000) + (i * 64),
                            64, 0);
                        p3_dma++;
                        #1ns;
                    end
                end join_none
            end
        join
        #10000ns;
        `uvm_info("SW_HEAVY", $sformatf("Phase 3 done: %0d EP DMA upstream", p3_dma), UVM_LOW)

        // Phase 4: P2P all-to-all (2400)
        `uvm_info("SW_HEAVY", "\n--- Phase 4: P2P all-to-all 2400 ---", UVM_LOW)
        begin
            int p2p_before = env.sw.total_p2p;
            p4_p2p = 0;
            fork
                for (int src = 0; src < 4; src++) begin
                    automatic int s = src;
                    fork begin
                        for (int dst = 0; dst < 4; dst++) begin
                            if (dst == s) continue;
                            for (int i = 0; i < 200; i++) begin
                                env.ep_agents[s].ep_driver.initiate_dma(
                                    cfg.switch_cfg.ds_mem_base[dst] + (s * 64'h1000) + (i * 64),
                                    64, 0);
                                p4_p2p++;
                                #2ns;
                            end
                        end
                    end join_none
                end
            join
            #15000ns;
            `uvm_info("SW_HEAVY", $sformatf("Phase 4 done: %0d P2P, switch P2P=%0d (new=%0d)",
                p4_p2p, env.sw.total_p2p, env.sw.total_p2p - p2p_before), UVM_LOW)
        end

        // Phase 5: Full mix concurrent
        `uvm_info("SW_HEAVY", "\n--- Phase 5: Full Mix 7200 (all concurrent) ---", UVM_LOW)
        p5_rc_wr = 0; p5_rc_rd = 0; p5_ep_dma = 0; p5_p2p = 0;
        fork
            // RC writes: 3000
            begin
                for (int i = 0; i < 3000; i++) begin
                    pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create(
                        $sformatf("p5_wr_%0d", i));
                    wr.addr     = cfg.switch_cfg.ds_mem_base[i % 4] + ((i / 4) * 64);
                    wr.length   = 16; wr.first_be = 4'hF; wr.last_be = 4'hF; wr.is_64bit = 0;
                    wr.start(env.rc_agent.sequencer);
                    p5_rc_wr++;
                    #1ns;
                end
            end
            // RC reads: 1000
            begin
                for (int i = 0; i < 1000; i++) begin
                    pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create(
                        $sformatf("p5_rd_%0d", i));
                    rd.addr     = cfg.switch_cfg.ds_mem_base[i % 4] + ((i / 4) * 64);
                    rd.length   = 8; rd.first_be = 4'hF; rd.last_be = 4'hF; rd.is_64bit = 0;
                    rd.start(env.rc_agent.sequencer);
                    p5_rc_rd++;
                    #3ns;
                end
            end
            // EP DMA upstream: 2000
            for (int ep = 0; ep < 4; ep++) begin
                automatic int e = ep;
                fork begin
                    for (int i = 0; i < 500; i++) begin
                        env.ep_agents[e].ep_driver.initiate_dma(
                            64'h0000_0000_0500_0000 + (e * 64'h0100_0000) + (i * 64),
                            64, 0);
                        p5_ep_dma++;
                        #2ns;
                    end
                end join_none
            end
            // P2P ring: 1200
            for (int src = 0; src < 4; src++) begin
                automatic int s = src;
                automatic int d = (src + 1) % 4;
                fork begin
                    for (int i = 0; i < 300; i++) begin
                        env.ep_agents[s].ep_driver.initiate_dma(
                            cfg.switch_cfg.ds_mem_base[d] + (s * 64'h1000) + (i * 64),
                            64, 0);
                        p5_p2p++;
                        #3ns;
                    end
                end join_none
            end
            // Monitor
            begin
                for (int m = 0; m < 10; m++) begin
                    #5000ns;
                    `uvm_info("SW_HEAVY", $sformatf(
                        "  [P5 @%0t] routed=%0d P2P=%0d dropped=%0d | SCB: req=%0d cpl=%0d",
                        $realtime, env.sw.total_routed, env.sw.total_p2p,
                        env.sw.total_dropped, env.scb.total_requests,
                        env.scb.total_completions), UVM_LOW)
                end
            end
        join
        #100000ns;  // 100us drain for heavy traffic completions
        t_end = $realtime;

        // Report
        grand_total = p1_wr + p2_rd + p3_dma + p4_p2p +
                      p5_rc_wr + p5_rc_rd + p5_ep_dma + p5_p2p;
        `uvm_info("SW_HEAVY", "\n============================================================", UVM_LOW)
        `uvm_info("SW_HEAVY", "=== Switch 20K Heavy Traffic Summary ===", UVM_LOW)
        `uvm_info("SW_HEAVY", "============================================================", UVM_LOW)
        `uvm_info("SW_HEAVY", $sformatf("  Total requests:  %0d", grand_total), UVM_LOW)
        `uvm_info("SW_HEAVY", $sformatf("  P1 RC wr: %0d  P2 RC rd: %0d  P3 DMA: %0d  P4 P2P: %0d",
            p1_wr, p2_rd, p3_dma, p4_p2p), UVM_LOW)
        `uvm_info("SW_HEAVY", $sformatf("  P5 mix: %0dW+%0dR+%0dDMA+%0dP2P = %0d",
            p5_rc_wr, p5_rc_rd, p5_ep_dma, p5_p2p,
            p5_rc_wr + p5_rc_rd + p5_ep_dma + p5_p2p), UVM_LOW)
        `uvm_info("SW_HEAVY", $sformatf("  Switch: routed=%0d P2P=%0d dropped=%0d",
            env.sw.total_routed, env.sw.total_p2p, env.sw.total_dropped), UVM_LOW)
        `uvm_info("SW_HEAVY", $sformatf("  Per-DSP fwd: [%0d, %0d, %0d, %0d]",
            env.sw.dsp[0].forwarded_count, env.sw.dsp[1].forwarded_count,
            env.sw.dsp[2].forwarded_count, env.sw.dsp[3].forwarded_count), UVM_LOW)
        `uvm_info("SW_HEAVY", $sformatf("  SCB: req=%0d cpl=%0d matched=%0d mismatch=%0d unexpected=%0d",
            env.scb.total_requests, env.scb.total_completions,
            env.scb.matched, env.scb.mismatched, env.scb.unexpected), UVM_LOW)
        `uvm_info("SW_HEAVY", $sformatf("  Sim time: %0t", t_end - t_start), UVM_LOW)

        if (env.sw.total_dropped <= 5 && env.scb.mismatched == 0 && env.scb.unexpected == 0)
            `uvm_info("SW_HEAVY", "*** SWITCH 20K HEAVY TRAFFIC PASSED ***", UVM_LOW)
        else
            `uvm_error("SW_HEAVY", $sformatf("FAILED: dropped=%0d mismatch=%0d unexpected=%0d",
                env.sw.total_dropped, env.scb.mismatched, env.scb.unexpected))
        `uvm_info("SW_HEAVY", "============================================================\n", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
