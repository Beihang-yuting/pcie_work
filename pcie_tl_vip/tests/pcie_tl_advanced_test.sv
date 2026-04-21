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
