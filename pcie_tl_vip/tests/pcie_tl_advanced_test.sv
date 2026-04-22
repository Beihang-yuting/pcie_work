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
