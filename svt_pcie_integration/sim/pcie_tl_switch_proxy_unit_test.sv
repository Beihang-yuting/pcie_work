import uvm_pkg::*;
import pcie_tl_switch_pkg::*;

class pcie_tl_route_event_collector extends uvm_component;
    `uvm_component_utils(pcie_tl_route_event_collector)

    uvm_analysis_imp #(pcie_tl_switch_route_event,
                       pcie_tl_route_event_collector) analysis_export;
    pcie_tl_switch source_switch;
    pcie_tl_switch_route_event events[$];

    function new(string name = "pcie_tl_route_event_collector",
                 uvm_component parent = null);
        super.new(name, parent);
        analysis_export = new("analysis_export", this);
    endfunction

    function void write(pcie_tl_switch_route_event route_event);
        if (route_event == null)
            `uvm_fatal("ROUTE_EVENT_TEST", "collector received null event")
        if (route_event.action == PCIE_TL_ROUTE_UNSUPPORTED_BROADCAST) begin
            int ingress_root;
            ingress_root = source_switch.fabric.root_of(
                route_event.ingress_port);
            for (int i = source_switch.sw_cfg.num_usp;
                 i < source_switch.all_ports.size(); i++) begin
                if ((i != route_event.ingress_port) &&
                    (source_switch.all_ports[i].owner_usp == ingress_root) &&
                    (source_switch.all_ports[i].tx_fifo.used() != 0))
                    `uvm_fatal("ROUTE_EVENT_ORDER",
                               "broadcast event was not published before fan-out")
            end
        end
        if ((route_event.action inside {PCIE_TL_ROUTE_FORWARD,
                                        PCIE_TL_ROUTE_LOCAL_RESPONSE}) &&
            (source_switch.all_ports[route_event.egress_port].tx_fifo.used() != 0))
            `uvm_fatal("ROUTE_EVENT_ORDER",
                       "event was not published before egress FIFO put")
        events.push_back(route_event);
    endfunction
endclass

class pcie_tl_switch_proxy_unit_test extends uvm_test;
    `uvm_component_utils(pcie_tl_switch_proxy_unit_test)

    pcie_tl_switch_config cfg;
    pcie_tl_switch        sw;
    pcie_tl_switch_config mr_cfg;
    pcie_tl_switch        mr_sw;
    pcie_tl_switch_config custom_bdf_cfg;
    pcie_tl_switch        custom_bdf_sw;
    pcie_tl_switch_port   unit_usp;
    pcie_tl_switch_port   unit_dsp;
    pcie_tl_route_event_collector route_collector;

    function new(string name = "pcie_tl_switch_proxy_unit_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        cfg = new("cfg");
        cfg.num_usp      = 1;
        cfg.num_ds_ports = 4;
        cfg.init_defaults();

        sw = pcie_tl_switch::type_id::create("sw", this);
        sw.sw_cfg = cfg;

        mr_cfg = new("mr_cfg");
        mr_cfg.num_usp      = 2;
        mr_cfg.num_ds_ports = 4;
        mr_cfg.init_defaults();
        mr_cfg.cross_root_check_enable = 0;
        mr_sw = pcie_tl_switch::type_id::create("mr_sw", this);
        mr_sw.sw_cfg = mr_cfg;

        custom_bdf_cfg = new("custom_bdf_cfg");
        custom_bdf_cfg.num_ds_ports = 1;
        custom_bdf_cfg.init_defaults();
        custom_bdf_cfg.switch_bdf = 16'h0500;
        custom_bdf_sw = pcie_tl_switch::type_id::create("custom_bdf_sw", this);
        custom_bdf_sw.sw_cfg = custom_bdf_cfg;

        unit_usp = new("unit_usp", this);
        unit_dsp = new("unit_dsp", this);

        route_collector = pcie_tl_route_event_collector::type_id::create(
            "route_collector", this);
        route_collector.source_switch = sw;
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        sw.route_observed_port.connect(route_collector.analysis_export);
    endfunction

    function void pre_abort();
        int system_status;

        super.pre_abort();
        if ($test$plusargs("SWITCH_NEG_DUP_NP") ||
            $test$plusargs("SWITCH_NEG_UNKNOWN_CPL") ||
            $test$plusargs("SWITCH_NEG_DUP_BDF")) begin
            // Stock UVM 1.2 uses $finish for UVM_FATAL and this VCS build
            // returns status zero even for $fatal. This VCS/Linux-only harness
            // uses the child shell's PPID to terminate the simulator after the
            // production UVM fatal record is flushed; no report is caught or
            // downgraded.
            system_status = $system("kill -TERM $PPID");
            $fatal(1, "negative switch routing mode termination failed (%0d)",
                   system_status);
        end
    endfunction

    task automatic check_eq(bit [31:0] actual, bit [31:0] expected,
                            string label);
        if (actual !== expected)
            $fatal(1, "%s expected=%08h actual=%08h", label, expected, actual);
    endtask

    task automatic check_route(int actual, int expected, string label);
        if (actual != expected)
            $fatal(1, "%s expected=%0d actual=%0d", label, expected, actual);
    endtask

    task automatic get_tlp_with_timeout(
        uvm_tlm_fifo #(pcie_tl_tlp) fifo,
        output pcie_tl_tlp tlp,
        input string label,
        input int unsigned max_polls = 100
    );
        tlp = null;
        for (int unsigned poll = 0; poll < max_polls; poll++) begin
            if (fifo.try_get(tlp))
                return;
            #1;
        end
        $fatal(1, "%s timed out after %0d polls", label, max_polls);
    endtask

    task automatic expect_no_tlp(
        uvm_tlm_fifo #(pcie_tl_tlp) fifo,
        string label,
        int unsigned max_polls = 10
    );
        pcie_tl_tlp unexpected;
        for (int unsigned poll = 0; poll < max_polls; poll++) begin
            if (fifo.try_get(unexpected))
                $fatal(1, "%s unexpectedly received %s",
                       label, unexpected.convert2string());
            #1;
        end
    endtask

    task automatic program_dsp0_pref_window(bit memory_enable);
        sw.dsp[0].cfg_write(12'h004,
                            memory_enable ? 32'h0000_0002 : 32'h0000_0000,
                            4'b0011);
        sw.dsp[0].cfg_write(12'h024, 32'h1071_1001, 4'hf);
        sw.dsp[0].cfg_write(12'h028, 32'h0000_0001, 4'hf);
        sw.dsp[0].cfg_write(12'h02c, 32'h0000_0001, 4'hf);
    endtask

    task automatic check_local_cfg_read(
        pcie_tl_switch target_sw,
        int ingress_root,
        bit [15:0] target_bdf,
        bit [31:0] expected_data,
        bit [9:0] tag,
        string label
    );
        pcie_tl_cfg_tlp req;
        pcie_tl_tlp response;
        pcie_tl_cpl_tlp cpl;
        bit [31:0] data;

        req = pcie_tl_cfg_tlp::type_id::create("local_cfg_read_req");
        req.kind         = TLP_CFG_RD1;
        req.fmt          = FMT_3DW_NO_DATA;
        req.type_f       = TLP_TYPE_CFG_RD1;
        req.length       = 1;
        req.requester_id = 16'(ingress_root << 8);
        req.tag          = tag;
        req.completer_id = target_bdf;
        req.reg_num      = 10'h000;
        req.first_be     = 4'hf;
        target_sw.usps[ingress_root].rx_fifo.put(req);
        get_tlp_with_timeout(target_sw.usps[ingress_root].tx_fifo,
                             response, label);
        if (!$cast(cpl, response) || cpl.payload.size() != 4)
            $fatal(1, "%s did not return a 4-byte Completion", label);
        data = {cpl.payload[3], cpl.payload[2], cpl.payload[1], cpl.payload[0]};
        check_eq(data, expected_data, label);
        if (cpl.completer_id != target_bdf)
            $fatal(1, "%s completer expected=%04h actual=%04h",
                   label, target_bdf, cpl.completer_id);
    endtask

    task automatic check_length_zero_mrd_route();
        pcie_tl_mem_tlp req;
        pcie_tl_cpl_tlp cpl;
        pcie_tl_tlp forwarded;
        pcie_tl_tlp returned;
        pcie_tl_switch_route_event route_event;
        int event_index;

        req = pcie_tl_mem_tlp::type_id::create("length_zero_mrd");
        req.kind         = TLP_MEM_RD;
        req.fmt          = FMT_3DW_NO_DATA;
        req.type_f       = TLP_TYPE_MEM_RD;
        req.length       = 10'h000; // PCIe encoding for 1024 DW
        req.requester_id = 16'h0000;
        req.tag          = 10'h158;
        req.addr         = {32'h0, cfg.ds_mem_base[0] + 32'h1000};
        req.is_64bit     = 1'b0;
        req.first_be     = 4'hf;
        req.last_be      = 4'hf;

        event_index = route_collector.events.size();
        sw.usp.rx_fifo.put(req);
        get_tlp_with_timeout(sw.dsp[0].tx_fifo, forwarded,
                             "4096-byte Memory Read forwarding");
        if (forwarded != req)
            $fatal(1, "4096-byte Memory Read was not forwarded unchanged");
        if (route_collector.events.size() <= event_index)
            $fatal(1, "ordinary forward route event was not observed");
        route_event = route_collector.events[event_index];
        if ((route_event.action != PCIE_TL_ROUTE_FORWARD) ||
            (route_event.ingress_port != 0) ||
            (route_event.egress_port != 1) ||
            (route_event.route_code != 1) ||
            (route_event.ingress_tlp.kind != TLP_MEM_RD) ||
            (route_event.egress_tlp.kind != TLP_MEM_RD) ||
            (route_event.ingress_tlp == req) ||
            (route_event.egress_tlp == forwarded))
            $fatal(1, "ordinary forward route event contract failed");
        check_route(sw.outstanding_count(), 1,
                    "4096-byte Memory Read outstanding");

        cpl = pcie_tl_cpl_tlp::type_id::create("length_zero_terminal_cpl");
        cpl.kind         = TLP_CPL;
        cpl.fmt          = FMT_3DW_NO_DATA;
        cpl.type_f       = TLP_TYPE_CPL;
        cpl.requester_id = req.requester_id;
        cpl.tag          = req.tag;
        cpl.completer_id = 16'h02f8;
        cpl.cpl_status   = CPL_STATUS_UR;
        sw.dsp[0].rx_fifo.put(cpl);
        get_tlp_with_timeout(sw.usp.tx_fifo, returned,
                             "4096-byte Memory Read terminal Completion");
        check_route(sw.outstanding_count(), 0,
                    "4096-byte Memory Read ownership drained");
    endtask

    task automatic check_unaligned_split_completion();
        pcie_tl_mem_tlp req;
        pcie_tl_cpl_tlp cpl;
        pcie_tl_tlp forwarded;
        pcie_tl_tlp returned;

        req = pcie_tl_mem_tlp::type_id::create("unaligned_split_req");
        req.kind         = TLP_MEM_RD;
        req.fmt          = FMT_3DW_NO_DATA;
        req.type_f       = TLP_TYPE_MEM_RD;
        req.length       = 10'd17;
        req.requester_id = 16'h0000;
        req.tag          = 10'h159;
        req.addr         = {32'h0, cfg.ds_mem_base[0] + 32'h300};
        req.is_64bit     = 1'b0;
        req.first_be     = 4'h8;
        req.last_be      = 4'h1;
        sw.usp.rx_fifo.put(req);
        get_tlp_with_timeout(sw.dsp[0].tx_fifo, forwarded,
                             "unaligned split request forwarding");
        check_route(sw.outstanding_count(), 1,
                    "unaligned split request outstanding");

        cpl = pcie_tl_cpl_tlp::type_id::create("unaligned_split_first");
        cpl.kind         = TLP_CPLD;
        cpl.fmt          = FMT_3DW_WITH_DATA;
        cpl.type_f       = TLP_TYPE_CPL;
        cpl.length       = 10'd16;
        cpl.requester_id = req.requester_id;
        cpl.tag          = req.tag;
        cpl.completer_id = 16'h02f8;
        cpl.cpl_status   = CPL_STATUS_SC;
        cpl.byte_count   = 12'd62;
        cpl.lower_addr   = 7'h03;
        cpl.payload      = new[64];
        sw.dsp[0].rx_fifo.put(cpl);
        get_tlp_with_timeout(sw.usp.tx_fifo, returned,
                             "first unaligned split Completion return");
        check_route(sw.outstanding_count(), 1,
                    "intermediate unaligned split Completion keeps route");

        cpl = pcie_tl_cpl_tlp::type_id::create("unaligned_split_final");
        cpl.kind         = TLP_CPLD;
        cpl.fmt          = FMT_3DW_WITH_DATA;
        cpl.type_f       = TLP_TYPE_CPL;
        cpl.length       = 10'd1;
        cpl.requester_id = req.requester_id;
        cpl.tag          = req.tag;
        cpl.completer_id = 16'h02f8;
        cpl.cpl_status   = CPL_STATUS_SC;
        cpl.byte_count   = 12'd1;
        cpl.lower_addr   = 7'h00;
        cpl.payload      = new[4];
        sw.dsp[0].rx_fifo.put(cpl);
        get_tlp_with_timeout(sw.usp.tx_fifo, returned,
                             "final unaligned split Completion return");
        check_route(sw.outstanding_count(), 0,
                    "final unaligned split Completion drains route");
    endtask

    task automatic run_type1_config_tests();
        pcie_tl_switch_port usp_port;
        pcie_tl_switch_port dsp_port;

        usp_port = unit_usp;
        dsp_port = unit_dsp;

        if (cfg.usp_sec_bus.size() != 1)
            $fatal(1, "usp_sec_bus size mismatch: expected 1, got %0d",
                   cfg.usp_sec_bus.size());
        if (cfg.ds_secondary_bus.size() != 4)
            $fatal(1, "ds_secondary_bus size mismatch: expected 4, got %0d",
                   cfg.ds_secondary_bus.size());

        unit_usp.init_type1_image(SWITCH_USP, 0, 16'h0100);
        unit_dsp.init_type1_image(SWITCH_DSP, 2, 16'h0202);

        check_eq(unit_usp.cfg_read(12'h000), 32'h5010_20f9,
                 "USP vendor/device");
        check_eq(unit_dsp.cfg_read(12'h000), 32'h5022_20f9,
                 "DSP vendor/device");
        check_eq(unit_usp.cfg_read(12'h008), 32'h0604_0001,
                 "bridge class/revision");
        check_eq(unit_usp.cfg_read(12'h00c), 32'h0001_0000,
                 "USP header type 1");
        check_eq(unit_dsp.cfg_read(12'h00c), 32'h0001_0000,
                 "DSP header type 1");
        check_eq(unit_usp.cfg_read(12'h034), 32'h0000_0040,
                 "PCIe cap pointer");
        check_eq(unit_usp.cfg_read(12'h040), 32'h0052_0010,
                 "USP PCIe capability");
        check_eq(unit_dsp.cfg_read(12'h040), 32'h0062_0010,
                 "DSP PCIe capability");

        usp_port.cfg_write(12'h000, 32'hffff_ffff, 4'hf);
        usp_port.cfg_write(12'h008, 32'hffff_ffff, 4'hf);
        usp_port.cfg_write(12'h00c, 32'hffff_ffff, 4'hf);
        usp_port.cfg_write(12'h034, 32'hffff_ffff, 4'hf);
        usp_port.cfg_write(12'h040, 32'hffff_ffff, 4'hf);
        dsp_port.cfg_write(12'h040, 32'hffff_ffff, 4'hf);
        check_eq(usp_port.cfg_read(12'h000), 32'h5010_20f9,
                 "vendor/device read-only");
        check_eq(usp_port.cfg_read(12'h008), 32'h0604_0001,
                 "class/revision read-only");
        check_eq(usp_port.cfg_read(12'h00c), 32'h0001_0000,
                 "header read-only");
        check_eq(usp_port.cfg_read(12'h034), 32'h0000_0040,
                 "capability pointer read-only");
        check_eq(usp_port.cfg_read(12'h040), 32'h0052_0010,
                 "USP capability read-only");
        check_eq(dsp_port.cfg_read(12'h040), 32'h0062_0010,
                 "DSP capability read-only");

        usp_port.cfg_write(12'h004, 32'hffff_0000, 4'b1100);
        check_eq(usp_port.cfg_read(12'h004), 32'h0010_0000,
                 "status read-only");
        usp_port.cfg_write(12'h004, 32'h0000_a5c3, 4'b0011);
        check_eq(usp_port.cfg_read(12'h004), 32'h0010_a5c3,
                 "command nonzero sentinel");
        usp_port.cfg_write(12'h004, 32'h0000_005a, 4'b0001);
        check_eq(usp_port.cfg_read(12'h004), 32'h0010_a55a,
                 "command low byte enable");
        usp_port.cfg_write(12'h004, 32'h0000_3c00, 4'b0010);
        check_eq(usp_port.cfg_read(12'h004), 32'h0010_3c5a,
                 "command high byte enable");

        usp_port.cfg_write(12'h018, 32'hb3a2_7100, 4'b1110);
        check_eq(usp_port.cfg_read(12'h018), 32'hb3a2_7100,
                 "bus nonzero sentinel");
        usp_port.cfg_write(12'h018, 32'h0000_5c00, 4'b0010);
        check_eq(usp_port.cfg_read(12'h018), 32'hb3a2_5c00,
                 "primary bus byte enable");
        usp_port.cfg_write(12'h018, 32'h00d4_0000, 4'b0100);
        check_eq(usp_port.cfg_read(12'h018), 32'hb3d4_5c00,
                 "secondary bus byte enable");
        usp_port.cfg_write(12'h018, 32'he600_0000, 4'b1000);
        check_eq(usp_port.cfg_read(12'h018), 32'he6d4_5c00,
                 "subordinate bus byte enable");

        usp_port.cfg_write(12'h020, 32'hc3d0_a5b0, 4'hf);
        check_eq(usp_port.cfg_read(12'h020), 32'hc3d0_a5b0,
                 "memory window nonzero sentinel");
        usp_port.cfg_write(12'h020, 32'h0000_0070, 4'b0001);
        check_eq(usp_port.cfg_read(12'h020), 32'hc3d0_a570,
                 "memory base low byte enable");
        usp_port.cfg_write(12'h020, 32'h0000_5a00, 4'b0010);
        check_eq(usp_port.cfg_read(12'h020), 32'hc3d0_5a70,
                 "memory base high byte enable");
        usp_port.cfg_write(12'h020, 32'h00e0_0000, 4'b0100);
        check_eq(usp_port.cfg_read(12'h020), 32'hc3e0_5a70,
                 "memory limit low byte enable");
        usp_port.cfg_write(12'h020, 32'h7400_0000, 4'b1000);
        check_eq(usp_port.cfg_read(12'h020), 32'h74e0_5a70,
                 "memory limit high byte enable");

        dsp_port.cfg_write(12'h024, 32'h1071_1001, 4'hf);
        dsp_port.cfg_write(12'h028, 32'h0000_0001, 4'hf);
        dsp_port.cfg_write(12'h02c, 32'h0000_0001, 4'hf);
        if ((dsp_port.pref_base != 64'h0000_0001_1000_0000) ||
            (dsp_port.pref_limit != 64'h0000_0001_107f_ffff))
            $fatal(1, "64-bit Prefetchable window decode failed");

        dsp_port.cfg_write(12'h024, 32'hab71_cd21, 4'hf);
        dsp_port.cfg_write(12'h024, 32'h0000_00e4, 4'b0001);
        check_eq(dsp_port.cfg_read(12'h024), 32'hab71_cde1,
                 "prefetch base low byte enable");
        dsp_port.cfg_write(12'h024, 32'h0000_5a00, 4'b0010);
        check_eq(dsp_port.cfg_read(12'h024), 32'hab71_5ae1,
                 "prefetch base high byte enable");
        dsp_port.cfg_write(12'h024, 32'h0066_0000, 4'b0100);
        check_eq(dsp_port.cfg_read(12'h024), 32'hab61_5ae1,
                 "prefetch limit low byte enable");
        dsp_port.cfg_write(12'h024, 32'hd700_0000, 4'b1000);
        check_eq(dsp_port.cfg_read(12'h024), 32'hd761_5ae1,
                 "prefetch limit high byte enable");
        check_eq(dsp_port.pref_base_reg[3:0], 4'h1,
                 "prefetch base 64-bit type");
        check_eq(dsp_port.pref_limit_reg[3:0], 4'h1,
                 "prefetch limit 64-bit type");

        dsp_port.cfg_write(12'h028, 32'h1122_3344, 4'hf);
        dsp_port.cfg_write(12'h028, 32'h00aa_00bb, 4'b0101);
        check_eq(dsp_port.cfg_read(12'h028), 32'h11aa_33bb,
                 "prefetch base upper partial byte enables");
        dsp_port.cfg_write(12'h02c, 32'h99aa_bbcc, 4'hf);
        dsp_port.cfg_write(12'h02c, 32'hdd00_ee00, 4'b1010);
        check_eq(dsp_port.cfg_read(12'h02c), 32'hddaa_eecc,
                 "prefetch limit upper partial byte enables");
        if ((dsp_port.pref_base != 64'h11aa_33bb_5ae0_0000) ||
            (dsp_port.pref_limit != 64'hddaa_eecc_d76f_ffff))
            $fatal(1,
                   "Partial-BE prefetch decode failed base=%016h limit=%016h",
                   dsp_port.pref_base, dsp_port.pref_limit);

        $display("TYPE1_CFG_PASS");
        $display("SWITCH_PACKAGE_SMOKE_PASS");
    endtask

    task automatic run_positive_tests();
        pcie_tl_mem_tlp route_req;
        pcie_tl_mem_tlp nonpref_req;
        pcie_tl_mem_tlp unmatched_req;
        pcie_tl_cfg_tlp exact_cfg_req;
        pcie_tl_cfg_tlp unknown_cfg_req;
        pcie_tl_cfg_tlp cfg_req;
        pcie_tl_cfg_tlp routed_cfg;
        pcie_tl_cfg_tlp event_ingress_cfg;
        pcie_tl_cfg_tlp event_egress_cfg;
        pcie_tl_cpl_tlp cpl;
        pcie_tl_cpl_tlp local_cpl;
        pcie_tl_cpl_tlp event_ingress_cpl;
        pcie_tl_cpl_tlp event_egress_cpl;
        pcie_tl_tlp     forwarded;
        pcie_tl_tlp     returned_cpl;
        pcie_tl_tlp     local_response;
        bit [31:0]       local_data;
        pcie_tl_mem_tlp mr_mem_req;
        pcie_tl_cfg_tlp mr_down_req;
        pcie_tl_cfg_tlp mr_down_forwarded;
        pcie_tl_cfg_tlp mr_cross_req;
        pcie_tl_cfg_tlp cfg_wr_req;
        pcie_tl_cfg_tlp local_cfg_wr_req;
        pcie_tl_cfg_tlp routed_cfg_wr;
        pcie_tl_msg_tlp bcast_req;
        pcie_tl_cpl_tlp mr_cpl;
        pcie_tl_cpl_tlp wr_cpl;
        pcie_tl_mem_tlp split_req;
        pcie_tl_cpl_tlp split_cpl;
        pcie_tl_tlp     mr_forwarded;
        pcie_tl_tlp     mr_returned;
        pcie_tl_tlp     cfg_wr_forwarded;
        pcie_tl_tlp     bcast_forwarded;
        pcie_tl_tlp     wr_returned;
        pcie_tl_tlp     split_forwarded;
        pcie_tl_tlp     split_returned;
        bit [31:0] saved_mem_base;
        bit [31:0] saved_mem_limit;
        bit [63:0] saved_pref_base;
        bit [63:0] saved_pref_limit;
        pcie_tl_switch_route_event route_event;
        pcie_tl_switch_route_event cfg_route_event;
        pcie_tl_switch_route_event cfg_wr_route_event;
        pcie_tl_switch_route_event bcast_route_event;
        int local_read_event_index;
        int local_write_event_index;
        int drop_event_index;
        int cfg_event_index;
        int completion_event_index;
        int cfg_wr_event_index;
        int bcast_event_index;

        run_type1_config_tests();
        check_length_zero_mrd_route();
        check_unaligned_split_completion();

        sw.refresh_local_bdf_map();
        check_route(sw.local_port_for_bdf(16'h0100), 0, "USP BDF");
        check_route(sw.local_port_for_bdf(16'h0200), 1, "DSP0 BDF");
        check_route(sw.local_port_for_bdf(16'h0208), 2, "DSP1 BDF");
        check_route(sw.local_port_for_bdf(16'h0210), 3, "DSP2 BDF");
        check_route(sw.local_port_for_bdf(16'h0218), 4, "DSP3 BDF");

        custom_bdf_sw.refresh_local_bdf_map();
        check_route(custom_bdf_sw.local_port_for_bdf(16'h0500), 0,
                    "custom single-root USP BDF");
        check_route(custom_bdf_sw.local_port_for_bdf(16'h0100),
                    SWITCH_ROUTE_DROP, "old default USP BDF is absent");
        check_local_cfg_read(custom_bdf_sw, 0, 16'h0500, 32'h5010_20f9,
                             10'h15a, "custom single-root local access");

        foreach (sw.dsp[i]) begin
            if (!sw.dsp[i].command[1])
                $fatal(1, "static DSP%0d Memory Space Enable is clear", i);
        end

        nonpref_req = pcie_tl_mem_tlp::type_id::create("nonpref_req");
        nonpref_req.kind         = TLP_MEM_RD;
        nonpref_req.fmt          = FMT_3DW_NO_DATA;
        nonpref_req.type_f       = TLP_TYPE_MEM_RD;
        nonpref_req.length       = 1;
        nonpref_req.addr         = {32'h0, cfg.ds_mem_base[0] + 32'h100};
        nonpref_req.is_64bit     = 0;
        nonpref_req.first_be     = 4'hf;
        nonpref_req.last_be      = 4'h0;
        check_route(sw.fabric.route(nonpref_req, 0), 1,
                    "static 32-bit non-Prefetchable window");

        unmatched_req = pcie_tl_mem_tlp::type_id::create("unmatched_req");
        unmatched_req.copy(nonpref_req);
        unmatched_req.addr = 64'h0;
        check_route(sw.fabric.route(unmatched_req, 0), SWITCH_ROUTE_DROP,
                    "unconfigured Prefetchable reset window stays disabled");
        unmatched_req.addr = 64'h0000_0000_7000_0000;
        check_route(sw.fabric.route(unmatched_req, 0), SWITCH_ROUTE_DROP,
                    "unmatched USP request");
        check_route(sw.fabric.route(unmatched_req, 1), 0,
                    "unmatched DSP request to owning USP");
        mr_sw.refresh_local_bdf_map();
        check_route(mr_sw.local_port_for_bdf(16'h0100), 0,
                    "multi-root root0 USP BDF");
        check_route(mr_sw.local_port_for_bdf(16'h8100), 1,
                    "multi-root root1 USP BDF");
        check_route(mr_sw.local_port_for_bdf(16'h0200), 2,
                    "multi-root root0 DSP0 BDF");
        check_route(mr_sw.local_port_for_bdf(16'h0208), 3,
                    "multi-root root0 DSP1 BDF");
        check_route(mr_sw.local_port_for_bdf(16'h8200), 4,
                    "multi-root root1 DSP2 BDF");
        check_route(mr_sw.local_port_for_bdf(16'h8208), 5,
                    "multi-root root1 DSP3 BDF");

        check_local_cfg_read(mr_sw, 0, 16'h0100, 32'h5010_20f9,
                             10'h150, "multi-root root0 local access");
        check_local_cfg_read(mr_sw, 1, 16'h8100, 32'h5010_20f9,
                             10'h151, "multi-root root1 local access");

        mr_mem_req = pcie_tl_mem_tlp::type_id::create("mr_mem_req");
        mr_mem_req.copy(nonpref_req);
        mr_mem_req.addr = {32'h0, mr_cfg.ds_mem_base[2] + 32'h100};
        check_route(mr_sw.fabric.route(mr_mem_req, 1), 4,
                    "multi-root owning root memory route");
        check_route(mr_sw.fabric.route(mr_mem_req, 0),
                    SWITCH_ROUTE_CROSS_ROOT,
                    "multi-root cross-root memory rejection");

        mr_down_req = pcie_tl_cfg_tlp::type_id::create("mr_down_req");
        mr_down_req.kind         = TLP_CFG_RD1;
        mr_down_req.fmt          = FMT_3DW_NO_DATA;
        mr_down_req.type_f       = TLP_TYPE_CFG_RD1;
        mr_down_req.length       = 1;
        mr_down_req.requester_id = 16'h8100;
        mr_down_req.tag          = 10'h160;
        mr_down_req.completer_id = 16'h82f8;
        mr_down_req.reg_num      = 10'h010;
        mr_down_req.first_be     = 4'hf;
        mr_sw.usps[1].rx_fifo.put(mr_down_req);
        get_tlp_with_timeout(mr_sw.dsp[2].tx_fifo, mr_forwarded,
                             "multi-root root1 downstream forwarding");
        if (!$cast(mr_down_forwarded, mr_forwarded) ||
            mr_down_forwarded.kind != TLP_CFG_RD0 ||
            mr_down_forwarded.type_f != TLP_TYPE_CFG_RD0)
            $fatal(1, "multi-root root1 request did not convert to Type 0");

        mr_cpl = pcie_tl_cpl_tlp::type_id::create("mr_cpl");
        mr_cpl.kind         = TLP_CPL;
        mr_cpl.fmt          = FMT_3DW_NO_DATA;
        mr_cpl.type_f       = TLP_TYPE_CPL;
        mr_cpl.requester_id = mr_down_req.requester_id;
        mr_cpl.tag          = mr_down_req.tag;
        mr_cpl.completer_id = mr_down_req.completer_id;
        mr_cpl.cpl_status   = CPL_STATUS_SC;
        mr_sw.dsp[2].rx_fifo.put(mr_cpl);
        get_tlp_with_timeout(mr_sw.usps[1].tx_fifo, mr_returned,
                             "multi-root root1 Completion return");
        check_route(mr_sw.outstanding_count(), 0,
                    "multi-root outstanding requests drained");

        mr_cross_req = pcie_tl_cfg_tlp::type_id::create("mr_cross_req");
        mr_cross_req.kind         = TLP_CFG_RD1;
        mr_cross_req.fmt          = FMT_3DW_NO_DATA;
        mr_cross_req.type_f       = TLP_TYPE_CFG_RD1;
        mr_cross_req.length       = 1;
        mr_cross_req.requester_id = 16'h0000;
        mr_cross_req.tag          = 10'h161;
        mr_cross_req.completer_id = 16'h8200;
        mr_cross_req.reg_num      = 10'h000;
        mr_cross_req.first_be     = 4'hf;
        mr_sw.usps[0].rx_fifo.put(mr_cross_req);
        expect_no_tlp(mr_sw.usps[0].tx_fifo,
                      "multi-root cross-root local response");
        expect_no_tlp(mr_sw.dsp[2].tx_fifo,
                      "multi-root cross-root downstream forwarding");
        check_route(mr_sw.outstanding_count(), 0,
                    "multi-root final outstanding count");
        $display("SWITCH_MULTI_ROOT_PASS");

        exact_cfg_req = pcie_tl_cfg_tlp::type_id::create("exact_cfg_req");
        exact_cfg_req.kind         = TLP_CFG_RD1;
        exact_cfg_req.fmt          = FMT_3DW_NO_DATA;
        exact_cfg_req.type_f       = TLP_TYPE_CFG_RD1;
        exact_cfg_req.length       = 1;
        exact_cfg_req.requester_id = 16'h0000;
        exact_cfg_req.tag          = 10'h140;
        exact_cfg_req.completer_id = 16'h0208;
        exact_cfg_req.reg_num      = 10'h000;
        exact_cfg_req.first_be     = 4'hf;
        local_read_event_index = route_collector.events.size();
        sw.usp.rx_fifo.put(exact_cfg_req);
        get_tlp_with_timeout(sw.usp.tx_fifo, local_response,
                             "exact DSP1 BDF local response");
        if (!$cast(local_cpl, local_response) || local_cpl.payload.size() != 4)
            $fatal(1, "Exact DSP1 BDF did not return a 4-byte Completion");
        local_data = {local_cpl.payload[3], local_cpl.payload[2],
                      local_cpl.payload[1], local_cpl.payload[0]};
        check_eq(local_data, 32'h5021_20f9, "exact DSP1 BDF vendor/device");
        if (route_collector.events.size() <= local_read_event_index)
            $fatal(1, "local Configuration Read route event was not observed");
        route_event = route_collector.events[local_read_event_index];
        if ((route_event.action != PCIE_TL_ROUTE_LOCAL_RESPONSE) ||
            (route_event.ingress_port != 0) ||
            (route_event.egress_port != 0) ||
            (route_event.route_code != SWITCH_ROUTE_LOCAL) ||
            (route_event.ingress_tlp.kind != TLP_CFG_RD1) ||
            (route_event.egress_tlp.kind != TLP_CPLD))
            $fatal(1, "local Configuration Read route event contract failed");

        local_cfg_wr_req = pcie_tl_cfg_tlp::type_id::create(
            "local_cfg_wr_req");
        local_cfg_wr_req.kind         = TLP_CFG_WR1;
        local_cfg_wr_req.fmt          = FMT_3DW_WITH_DATA;
        local_cfg_wr_req.type_f       = TLP_TYPE_CFG_WR1;
        local_cfg_wr_req.length       = 1;
        local_cfg_wr_req.requester_id = 16'h0000;
        local_cfg_wr_req.tag          = 10'h142;
        local_cfg_wr_req.completer_id = 16'h0208;
        local_cfg_wr_req.reg_num      = 10'h001;
        local_cfg_wr_req.first_be     = 4'b0011;
        local_cfg_wr_req.payload      = new[4];
        local_cfg_wr_req.payload[0]   = 8'h02;
        local_cfg_wr_req.payload[1]   = 8'h00;
        local_cfg_wr_req.payload[2]   = 8'h00;
        local_cfg_wr_req.payload[3]   = 8'h00;
        local_write_event_index = route_collector.events.size();
        sw.usp.rx_fifo.put(local_cfg_wr_req);
        get_tlp_with_timeout(sw.usp.tx_fifo, local_response,
                             "exact DSP1 BDF local write response");
        if (!$cast(local_cpl, local_response) ||
            local_cpl.kind != TLP_CPL)
            $fatal(1, "Exact DSP1 BDF local write did not return Completion");
        if (route_collector.events.size() <= local_write_event_index)
            $fatal(1, "local Configuration Write route event was not observed");
        route_event = route_collector.events[local_write_event_index];
        if ((route_event.action != PCIE_TL_ROUTE_LOCAL_RESPONSE) ||
            (route_event.ingress_port != 0) ||
            (route_event.egress_port != 0) ||
            (route_event.route_code != SWITCH_ROUTE_LOCAL) ||
            (route_event.ingress_tlp.kind != TLP_CFG_WR1) ||
            (route_event.egress_tlp.kind != TLP_CPL))
            $fatal(1, "local Configuration Write route event contract failed");

        unknown_cfg_req = pcie_tl_cfg_tlp::type_id::create("unknown_cfg_req");
        unknown_cfg_req.kind         = TLP_CFG_RD1;
        unknown_cfg_req.fmt          = FMT_3DW_NO_DATA;
        unknown_cfg_req.type_f       = TLP_TYPE_CFG_RD1;
        unknown_cfg_req.length       = 1;
        unknown_cfg_req.requester_id = 16'h0000;
        unknown_cfg_req.tag          = 10'h141;
        unknown_cfg_req.completer_id = 16'h0108;
        unknown_cfg_req.reg_num      = 10'h000;
        unknown_cfg_req.first_be     = 4'hf;
        drop_event_index = route_collector.events.size();
        sw.usp.rx_fifo.put(unknown_cfg_req);
        expect_no_tlp(sw.usp.tx_fifo, "unknown exact BDF response");
        if (route_collector.events.size() <= drop_event_index)
            $fatal(1, "drop route event was not observed");
        route_event = route_collector.events[drop_event_index];
        if ((route_event.action != PCIE_TL_ROUTE_DROP) ||
            (route_event.ingress_port != 0) ||
            (route_event.egress_port != SWITCH_ROUTE_DROP) ||
            (route_event.route_code != SWITCH_ROUTE_DROP) ||
            (route_event.ingress_tlp.kind != TLP_CFG_RD1) ||
            (route_event.egress_tlp != null))
            $fatal(1, "drop route event contract failed");

        bcast_req = pcie_tl_msg_tlp::type_id::create("bcast_req");
        bcast_req.kind         = TLP_MSG;
        bcast_req.fmt          = FMT_4DW_NO_DATA;
        bcast_req.type_f       = TLP_TYPE_MSG_BCAST;
        bcast_req.tc           = 3'h4;
        bcast_req.at           = 2'b10;
        bcast_req.length       = 0;
        bcast_req.requester_id = 16'h0000;
        bcast_req.tag          = 10'h143;
        bcast_req.prefixes.push_back(
            pcie_tl_prefix::create_pasid(20'h54321, 1'b0, 1'b1));
        bcast_req.has_prefix = 1'b1;
        bcast_event_index = route_collector.events.size();
        sw.usp.rx_fifo.put(bcast_req);
        foreach (sw.dsp[i]) begin
            get_tlp_with_timeout(sw.dsp[i].tx_fifo, bcast_forwarded,
                                 $sformatf("broadcast forwarding to DSP%0d", i));
            if (bcast_forwarded != bcast_req)
                $fatal(1, "broadcast forwarding to DSP%0d changed the TLP", i);
        end
        if (route_collector.events.size() != (bcast_event_index + 1))
            $fatal(1, "broadcast expected exactly one route event, got %0d",
                   route_collector.events.size() - bcast_event_index);
        bcast_route_event = route_collector.events[bcast_event_index];
        if ((bcast_route_event.action !=
             PCIE_TL_ROUTE_UNSUPPORTED_BROADCAST) ||
            (bcast_route_event.ingress_port != 0) ||
            (bcast_route_event.egress_port != SWITCH_ROUTE_BCAST) ||
            (bcast_route_event.route_code != SWITCH_ROUTE_BCAST) ||
            (bcast_route_event.ingress_tlp == null) ||
            (bcast_route_event.egress_tlp == null) ||
            (bcast_route_event.ingress_tlp == bcast_req) ||
            (bcast_route_event.egress_tlp == bcast_req) ||
            (bcast_route_event.ingress_tlp == bcast_route_event.egress_tlp) ||
            (bcast_route_event.ingress_tlp.kind != TLP_MSG) ||
            (bcast_route_event.egress_tlp.kind != TLP_MSG) ||
            (bcast_route_event.ingress_tlp.at != 2'b10) ||
            (bcast_route_event.egress_tlp.at != 2'b10) ||
            (bcast_route_event.ingress_tlp.prefixes.size() != 1) ||
            (bcast_route_event.egress_tlp.prefixes.size() != 1) ||
            (bcast_route_event.ingress_tlp.prefixes[0] ==
             bcast_req.prefixes[0]) ||
            (bcast_route_event.egress_tlp.prefixes[0] ==
             bcast_req.prefixes[0]) ||
            (bcast_route_event.ingress_tlp.prefixes[0] ==
             bcast_route_event.egress_tlp.prefixes[0]))
            $fatal(1, "broadcast route event contract failed");
        bcast_req.at = 2'b00;
        bcast_req.prefixes[0].raw_dw = 32'h9100_0000;
        if ((bcast_route_event.ingress_tlp.at != 2'b10) ||
            (bcast_route_event.egress_tlp.at != 2'b10) ||
            (bcast_route_event.ingress_tlp.prefixes[0].raw_dw !=
             32'h9145_4321) ||
            (bcast_route_event.egress_tlp.prefixes[0].raw_dw !=
             32'h9145_4321))
            $fatal(1, "broadcast snapshots changed with original request");

        route_req = pcie_tl_mem_tlp::type_id::create("route_req");
        route_req.kind         = TLP_MEM_RD;
        route_req.fmt          = FMT_4DW_NO_DATA;
        route_req.type_f       = TLP_TYPE_MEM_RD;
        route_req.length       = 1;
        route_req.addr         = 64'h0000_0001_1040_0000;
        route_req.is_64bit     = 1;
        route_req.first_be     = 4'hf;
        route_req.last_be      = 4'h0;

        program_dsp0_pref_window(1);
        check_route(sw.fabric.route(route_req, 0), 1,
                    "enabled 64-bit Prefetchable window");
        program_dsp0_pref_window(0);
        check_route(sw.fabric.route(route_req, 0), SWITCH_ROUTE_DROP,
                    "disabled Memory Space Enable");

        saved_mem_base  = sw.dsp[0].route_entry.mem_base;
        saved_mem_limit = sw.dsp[0].route_entry.mem_limit;
        saved_pref_base = sw.dsp[0].pref_base;
        saved_pref_limit = sw.dsp[0].pref_limit;
        sw.dsp[0].command[1] = 1'b1;
        sw.dsp[0].route_entry.mem_base  = 32'h8800_0000;
        sw.dsp[0].route_entry.mem_limit = 32'h8700_0000;
        nonpref_req.addr = 64'h0000_0000_8780_0000;
        check_route(sw.fabric.route(nonpref_req, 0), SWITCH_ROUTE_DROP,
                    "invalid non-Prefetchable base greater than limit");
        sw.dsp[0].route_entry.mem_base  = saved_mem_base;
        sw.dsp[0].route_entry.mem_limit = saved_mem_limit;

        sw.dsp[0].pref_base  = 64'h0000_0001_1080_0000;
        sw.dsp[0].pref_limit = 64'h0000_0001_1000_0000;
        route_req.addr = 64'h0000_0001_1040_0000;
        check_route(sw.fabric.route(route_req, 0), SWITCH_ROUTE_DROP,
                    "invalid Prefetchable base greater than limit");
        sw.dsp[0].pref_base  = saved_pref_base;
        sw.dsp[0].pref_limit = saved_pref_limit;

        cfg_req = pcie_tl_cfg_tlp::type_id::create("cfg_req");
        cfg_req.kind                = TLP_CFG_RD1;
        cfg_req.fmt                 = FMT_3DW_NO_DATA;
        cfg_req.type_f              = TLP_TYPE_CFG_RD1;
        cfg_req.tc                  = 3'h5;
        cfg_req.th                  = 1'b1;
        cfg_req.td                  = 1'b1;
        cfg_req.ep_bit              = 1'b1;
        cfg_req.attr                = 3'b101;
        cfg_req.at                  = 2'b10;
        cfg_req.length              = 10'h001;
        cfg_req.requester_id        = 16'h0000;
        cfg_req.tag                 = 10'h155;
        cfg_req.completer_id        = 16'h02f8;
        cfg_req.reg_num             = 10'h2a5;
        cfg_req.first_be            = 4'ha;
        cfg_req.inject_ecrc_err     = 1'b1;
        cfg_req.inject_lcrc_err     = 1'b1;
        cfg_req.inject_poisoned     = 1'b1;
        cfg_req.violate_ordering    = 1'b1;
        cfg_req.field_bitmask       = 32'ha5a5_5a5a;
        cfg_req.constraint_mode_sel = CONSTRAINT_ILLEGAL;
        cfg_req.cq_route.valid      = 1'b1;
        cfg_req.cq_route.target_bdf = 16'h02f8;
        cfg_req.cq_route.target_func = 8'h3c;
        cfg_req.prefixes.push_back(
            pcie_tl_prefix::create_pasid(20'h12345, 1'b1, 1'b0));
        cfg_req.has_prefix = 1'b1;

        cfg_event_index = route_collector.events.size();
        sw.usp.rx_fifo.put(cfg_req);
        get_tlp_with_timeout(sw.dsp[0].tx_fifo, forwarded,
                             "Type-1 Configuration Read forwarding");
        if (!$cast(routed_cfg, forwarded))
            $fatal(1, "Forwarded Type-1 request is not pcie_tl_cfg_tlp");
        if (routed_cfg == cfg_req)
            $fatal(1, "Forwarded Configuration Request was not cloned");
        if ((routed_cfg.kind != TLP_CFG_RD0) ||
            (routed_cfg.type_f != TLP_TYPE_CFG_RD0))
            $fatal(1, "Type-1 Configuration Read was not converted to Type 0");
        if ((routed_cfg.fmt !== cfg_req.fmt) ||
            (routed_cfg.tc !== cfg_req.tc) ||
            (routed_cfg.th !== cfg_req.th) ||
            (routed_cfg.td !== cfg_req.td) ||
            (routed_cfg.ep_bit !== cfg_req.ep_bit) ||
            (routed_cfg.attr !== cfg_req.attr) ||
            (routed_cfg.at !== cfg_req.at) ||
            (routed_cfg.length !== cfg_req.length) ||
            (routed_cfg.requester_id !== cfg_req.requester_id) ||
            (routed_cfg.tag !== cfg_req.tag) ||
            (routed_cfg.completer_id !== cfg_req.completer_id) ||
            (routed_cfg.reg_num !== cfg_req.reg_num) ||
            (routed_cfg.first_be !== cfg_req.first_be) ||
            (routed_cfg.inject_ecrc_err !== cfg_req.inject_ecrc_err) ||
            (routed_cfg.inject_lcrc_err !== cfg_req.inject_lcrc_err) ||
            (routed_cfg.inject_poisoned !== cfg_req.inject_poisoned) ||
            (routed_cfg.violate_ordering !== cfg_req.violate_ordering) ||
            (routed_cfg.field_bitmask !== cfg_req.field_bitmask) ||
            (routed_cfg.constraint_mode_sel != cfg_req.constraint_mode_sel) ||
            (routed_cfg.cq_route !== cfg_req.cq_route) ||
            (routed_cfg.payload.size() != cfg_req.payload.size()))
            $fatal(1, "Forwarded Type-0 request did not preserve supported fields");
        if ((cfg_req.kind != TLP_CFG_RD1) ||
            (cfg_req.type_f != TLP_TYPE_CFG_RD1))
            $fatal(1, "Source Type-1 Configuration Request was mutated");
        if (route_collector.events.size() <= cfg_event_index)
            $fatal(1, "Cfg1-to-Cfg0 route event was not observed");
        cfg_route_event = route_collector.events[cfg_event_index];
        if ((cfg_route_event.action != PCIE_TL_ROUTE_FORWARD) ||
            (cfg_route_event.ingress_port != 0) ||
            (cfg_route_event.egress_port != 1) ||
            (cfg_route_event.route_code != 1) ||
            (cfg_route_event.ingress_tlp.kind != TLP_CFG_RD1) ||
            (cfg_route_event.egress_tlp.kind != TLP_CFG_RD0) ||
            !$cast(event_ingress_cfg, cfg_route_event.ingress_tlp) ||
            !$cast(event_egress_cfg, cfg_route_event.egress_tlp) ||
            (event_ingress_cfg.at != 2'b10) ||
            (event_egress_cfg.at != 2'b10) ||
            (event_ingress_cfg.completer_id != 16'h02f8) ||
            (event_egress_cfg.completer_id != 16'h02f8) ||
            (event_ingress_cfg.reg_num != 10'h2a5) ||
            (event_egress_cfg.reg_num != 10'h2a5) ||
            (event_ingress_cfg.first_be != 4'ha) ||
            (event_egress_cfg.first_be != 4'ha) ||
            (event_ingress_cfg.prefixes.size() != 1) ||
            (event_egress_cfg.prefixes.size() != 1) ||
            (event_ingress_cfg.prefixes[0].raw_dw !=
             cfg_req.prefixes[0].raw_dw) ||
            (event_egress_cfg.prefixes[0].raw_dw !=
             cfg_req.prefixes[0].raw_dw))
            $fatal(1, "Cfg1-to-Cfg0 route event contract failed");
        check_route(sw.outstanding_count(), 1,
                    "one outstanding non-posted request");

        cpl = pcie_tl_cpl_tlp::type_id::create("cpl");
        cpl.kind         = TLP_CPL;
        cpl.fmt          = FMT_3DW_NO_DATA;
        cpl.type_f       = TLP_TYPE_CPL;
        cpl.requester_id = 16'h0000;
        cpl.tag          = 10'h155;
        cpl.completer_id = 16'h02f8;
        cpl.cpl_status   = CPL_STATUS_SC;
        cpl.tc           = 3'h6;
        cpl.attr         = 3'b011;
        cpl.at           = 2'b01;
        cpl.bcm          = 1'b1;
        cpl.byte_count   = 12'h321;
        cpl.lower_addr   = 7'h45;

        completion_event_index = route_collector.events.size();
        sw.dsp[0].rx_fifo.put(cpl);
        get_tlp_with_timeout(sw.usp.tx_fifo, returned_cpl,
                             "Completion return to USP");
        if (returned_cpl != cpl)
            $fatal(1, "Completion did not return unchanged to the USP");
        if (route_collector.events.size() <= completion_event_index)
            $fatal(1, "Completion route event was not observed");
        route_event = route_collector.events[completion_event_index];
        if ((route_event.action != PCIE_TL_ROUTE_FORWARD) ||
            (route_event.ingress_port != 1) ||
            (route_event.egress_port != 0) ||
            (route_event.route_code != 0) ||
            !$cast(event_ingress_cpl, route_event.ingress_tlp) ||
            !$cast(event_egress_cpl, route_event.egress_tlp) ||
            (event_ingress_cpl.kind != cpl.kind) ||
            (event_egress_cpl.kind != cpl.kind) ||
            (event_ingress_cpl.requester_id != cpl.requester_id) ||
            (event_egress_cpl.requester_id != cpl.requester_id) ||
            (event_ingress_cpl.tag != cpl.tag) ||
            (event_egress_cpl.tag != cpl.tag) ||
            (event_ingress_cpl.completer_id != cpl.completer_id) ||
            (event_egress_cpl.completer_id != cpl.completer_id) ||
            (event_ingress_cpl.cpl_status != cpl.cpl_status) ||
            (event_egress_cpl.cpl_status != cpl.cpl_status) ||
            (event_ingress_cpl.at != cpl.at) ||
            (event_egress_cpl.at != cpl.at) ||
            (event_ingress_cpl.bcm != cpl.bcm) ||
            (event_egress_cpl.bcm != cpl.bcm) ||
            (event_ingress_cpl.byte_count != cpl.byte_count) ||
            (event_egress_cpl.byte_count != cpl.byte_count) ||
            (event_ingress_cpl.lower_addr != cpl.lower_addr) ||
            (event_egress_cpl.lower_addr != cpl.lower_addr))
            $fatal(1, "Completion route event contract failed");
        check_route(sw.outstanding_count(), 0,
                    "outstanding requests drained by Completion");

        cfg_wr_req = pcie_tl_cfg_tlp::type_id::create("cfg_wr_req");
        cfg_wr_req.kind         = TLP_CFG_WR1;
        cfg_wr_req.fmt          = FMT_3DW_WITH_DATA;
        cfg_wr_req.type_f       = TLP_TYPE_CFG_WR1;
        cfg_wr_req.tc           = 3'h3;
        cfg_wr_req.attr         = 3'b110;
        cfg_wr_req.at           = 2'b01;
        cfg_wr_req.length       = 1;
        cfg_wr_req.requester_id = 16'h0000;
        cfg_wr_req.tag          = 10'h156;
        cfg_wr_req.completer_id = 16'h02f8;
        cfg_wr_req.reg_num      = 10'h033;
        cfg_wr_req.first_be     = 4'hd;
        cfg_wr_req.payload      = new[4];
        cfg_wr_req.payload[0]   = 8'h11;
        cfg_wr_req.payload[1]   = 8'h22;
        cfg_wr_req.payload[2]   = 8'h33;
        cfg_wr_req.payload[3]   = 8'h44;
        cfg_wr_req.prefixes.push_back(pcie_tl_prefix::create_mriov(8'h5a));
        cfg_wr_req.has_prefix = 1'b1;
        cfg_wr_event_index = route_collector.events.size();
        sw.usp.rx_fifo.put(cfg_wr_req);
        get_tlp_with_timeout(sw.dsp[0].tx_fifo, cfg_wr_forwarded,
                             "Type-1 Configuration Write forwarding");
        if (!$cast(routed_cfg_wr, cfg_wr_forwarded) ||
            routed_cfg_wr == cfg_wr_req ||
            routed_cfg_wr.kind != TLP_CFG_WR0 ||
            routed_cfg_wr.type_f != TLP_TYPE_CFG_WR0)
            $fatal(1, "Type-1 Configuration Write was not cloned as Type 0");
        if (routed_cfg_wr.payload.size() != 4)
            $fatal(1, "Cloned Configuration Write payload size is %0d",
                   routed_cfg_wr.payload.size());
        foreach (cfg_wr_req.payload[i]) begin
            if (routed_cfg_wr.payload[i] !== cfg_wr_req.payload[i])
                $fatal(1, "Cloned Configuration Write payload[%0d] mismatch", i);
        end
        if (cfg_wr_req.kind != TLP_CFG_WR1 ||
            cfg_wr_req.type_f != TLP_TYPE_CFG_WR1 ||
            cfg_wr_req.payload.size() != 4 ||
            cfg_wr_req.payload[0] != 8'h11 ||
            cfg_wr_req.payload[1] != 8'h22 ||
            cfg_wr_req.payload[2] != 8'h33 ||
            cfg_wr_req.payload[3] != 8'h44)
            $fatal(1, "Source Configuration Write was mutated");
        if (routed_cfg_wr.tc !== cfg_wr_req.tc ||
            routed_cfg_wr.attr !== cfg_wr_req.attr ||
            routed_cfg_wr.at !== cfg_wr_req.at ||
            routed_cfg_wr.requester_id !== cfg_wr_req.requester_id ||
            routed_cfg_wr.tag !== cfg_wr_req.tag ||
            routed_cfg_wr.reg_num !== cfg_wr_req.reg_num ||
            routed_cfg_wr.first_be !== cfg_wr_req.first_be ||
            routed_cfg_wr.length !== cfg_wr_req.length ||
            routed_cfg_wr.completer_id !== cfg_wr_req.completer_id)
            $fatal(1, "Cloned Configuration Write fields were not preserved");

        if (route_collector.events.size() <= cfg_wr_event_index)
            $fatal(1, "Configuration Write route event was not observed");
        cfg_wr_route_event = route_collector.events[cfg_wr_event_index];
        if ((cfg_wr_route_event.action != PCIE_TL_ROUTE_FORWARD) ||
            (cfg_wr_route_event.ingress_port != 0) ||
            (cfg_wr_route_event.egress_port != 1) ||
            (cfg_wr_route_event.route_code != 1) ||
            !$cast(event_ingress_cfg, cfg_wr_route_event.ingress_tlp) ||
            !$cast(event_egress_cfg, cfg_wr_route_event.egress_tlp) ||
            (event_ingress_cfg.kind != TLP_CFG_WR1) ||
            (event_egress_cfg.kind != TLP_CFG_WR0) ||
            (event_ingress_cfg.at != 2'b01) ||
            (event_egress_cfg.at != 2'b01) ||
            (event_ingress_cfg.reg_num != 10'h033) ||
            (event_egress_cfg.reg_num != 10'h033) ||
            (event_ingress_cfg.first_be != 4'hd) ||
            (event_egress_cfg.first_be != 4'hd) ||
            (event_ingress_cfg.payload.size() != 4) ||
            (event_egress_cfg.payload.size() != 4) ||
            (event_ingress_cfg.prefixes.size() != 1) ||
            (event_egress_cfg.prefixes.size() != 1) ||
            (event_ingress_cfg.prefixes[0] == cfg_wr_req.prefixes[0]) ||
            (event_egress_cfg.prefixes[0] == cfg_wr_req.prefixes[0]))
            $fatal(1, "Configuration Write route event snapshot failed");

        cfg_wr_req.at = 2'b00;
        cfg_wr_req.reg_num = 10'h000;
        cfg_wr_req.first_be = 4'h0;
        cfg_wr_req.payload[0] = 8'hff;
        cfg_wr_req.prefixes[0].raw_dw = 32'h8000_0000;
        if ((event_ingress_cfg.at != 2'b01) ||
            (event_ingress_cfg.reg_num != 10'h033) ||
            (event_ingress_cfg.first_be != 4'hd) ||
            (event_ingress_cfg.payload[0] != 8'h11) ||
            (event_ingress_cfg.prefixes[0].raw_dw != 32'h8000_5a00) ||
            (event_egress_cfg.at != 2'b01) ||
            (event_egress_cfg.reg_num != 10'h033) ||
            (event_egress_cfg.first_be != 4'hd) ||
            (event_egress_cfg.payload[0] != 8'h11) ||
            (event_egress_cfg.prefixes[0].raw_dw != 32'h8000_5a00))
            $fatal(1, "route event snapshots changed with original request");

        wr_cpl = pcie_tl_cpl_tlp::type_id::create("wr_cpl");
        wr_cpl.kind         = TLP_CPL;
        wr_cpl.fmt          = FMT_3DW_NO_DATA;
        wr_cpl.type_f       = TLP_TYPE_CPL;
        wr_cpl.requester_id = cfg_wr_req.requester_id;
        wr_cpl.tag          = cfg_wr_req.tag;
        wr_cpl.completer_id = cfg_wr_req.completer_id;
        wr_cpl.cpl_status   = CPL_STATUS_SC;
        sw.dsp[0].rx_fifo.put(wr_cpl);
        get_tlp_with_timeout(sw.usp.tx_fifo, wr_returned,
                             "Configuration Write Completion return");
        check_route(sw.outstanding_count(), 0,
                    "final outstanding request count");

        split_req = pcie_tl_mem_tlp::type_id::create("split_req");
        split_req.kind         = TLP_MEM_RD;
        split_req.fmt          = FMT_3DW_NO_DATA;
        split_req.type_f       = TLP_TYPE_MEM_RD;
        split_req.length       = 10'd32;
        split_req.requester_id = 16'h0000;
        split_req.tag          = 10'h157;
        split_req.addr         = {32'h0, cfg.ds_mem_base[0] + 32'h200};
        split_req.is_64bit     = 0;
        split_req.first_be     = 4'hf;
        split_req.last_be      = 4'hf;
        sw.usp.rx_fifo.put(split_req);
        get_tlp_with_timeout(sw.dsp[0].tx_fifo, split_forwarded,
                             "split Completion request forwarding");
        check_route(sw.outstanding_count(), 1,
                    "split Completion request outstanding");

        split_cpl = pcie_tl_cpl_tlp::type_id::create("split_cpl_first");
        split_cpl.kind         = TLP_CPLD;
        split_cpl.fmt          = FMT_3DW_WITH_DATA;
        split_cpl.type_f       = TLP_TYPE_CPL;
        split_cpl.length       = 10'd16;
        split_cpl.requester_id = split_req.requester_id;
        split_cpl.tag          = split_req.tag;
        split_cpl.completer_id = 16'h02f8;
        split_cpl.cpl_status   = CPL_STATUS_SC;
        split_cpl.byte_count   = 12'd128;
        split_cpl.payload      = new[64];
        sw.dsp[0].rx_fifo.put(split_cpl);
        get_tlp_with_timeout(sw.usp.tx_fifo, split_returned,
                             "first split Completion return");
        check_route(sw.outstanding_count(), 1,
                    "intermediate split Completion keeps route");

        split_cpl = pcie_tl_cpl_tlp::type_id::create("split_cpl_final");
        split_cpl.kind         = TLP_CPLD;
        split_cpl.fmt          = FMT_3DW_WITH_DATA;
        split_cpl.type_f       = TLP_TYPE_CPL;
        split_cpl.length       = 10'd16;
        split_cpl.requester_id = split_req.requester_id;
        split_cpl.tag          = split_req.tag;
        split_cpl.completer_id = 16'h02f8;
        split_cpl.cpl_status   = CPL_STATUS_SC;
        split_cpl.byte_count   = 12'd64;
        split_cpl.payload      = new[64];
        sw.dsp[0].rx_fifo.put(split_cpl);
        get_tlp_with_timeout(sw.usp.tx_fifo, split_returned,
                             "final split Completion return");
        check_route(sw.outstanding_count(), 0,
                    "final split Completion drains route");

        if (route_collector.events.size() == 0)
            $fatal(1, "no switch route events were observed");
        foreach (route_collector.events[i]) begin
            if (route_collector.events[i].event_id != i)
                $fatal(1, "route event ID expected=%0d actual=%0d", i,
                       route_collector.events[i].event_id);
            if (route_collector.events[i].ingress_tlp == null)
                $fatal(1, "route event %0d has null ingress snapshot", i);
            if ((route_collector.events[i].action == PCIE_TL_ROUTE_DROP) !=
                (route_collector.events[i].egress_tlp == null))
                $fatal(1, "route event %0d egress snapshot contract failed", i);
        end

        $display("SWITCH_ROUTE_OBSERVER_PASS forward=1 rewrite=1 local_read=1 local_write=1 completion=1 clone=1");

        $display("SWITCH_ROUTE_PASS");
    endtask

    task automatic run_duplicate_np_negative();
        pcie_tl_cfg_tlp req;
        pcie_tl_tlp     forwarded;

        req = pcie_tl_cfg_tlp::type_id::create("dup_req");
        req.kind         = TLP_CFG_RD1;
        req.fmt          = FMT_3DW_NO_DATA;
        req.type_f       = TLP_TYPE_CFG_RD1;
        req.length       = 1;
        req.requester_id = 16'h0000;
        req.tag          = 10'h155;
        req.completer_id = 16'h02f8;
        req.reg_num      = 10'h001;
        req.first_be     = 4'hf;

        sw.usp.rx_fifo.put(req);
        get_tlp_with_timeout(sw.dsp[0].tx_fifo, forwarded,
                             "first duplicate-key request forwarding");
        sw.usp.rx_fifo.put(req);
        #10;
        $fatal(1, "Duplicate non-posted request did not terminate simulation");
    endtask

    task automatic run_unknown_completion_negative();
        pcie_tl_cpl_tlp cpl;

        cpl = pcie_tl_cpl_tlp::type_id::create("unknown_cpl");
        cpl.kind         = TLP_CPL;
        cpl.fmt          = FMT_3DW_NO_DATA;
        cpl.type_f       = TLP_TYPE_CPL;
        cpl.requester_id = 16'h0000;
        cpl.tag          = 10'h155;
        cpl.completer_id = 16'h02f8;
        cpl.cpl_status   = CPL_STATUS_SC;

        sw.dsp[0].rx_fifo.put(cpl);
        #10;
        $fatal(1, "Unknown Completion did not terminate simulation");
    endtask

    task automatic run_duplicate_bdf_negative();
        sw.dsp[1].bdf = sw.dsp[0].bdf;
        sw.refresh_local_bdf_map();
        #10;
        $fatal(1, "Duplicate local BDF did not terminate simulation");
    endtask

    task run_phase(uvm_phase phase);
        bit duplicate_mode;
        bit unknown_mode;
        bit duplicate_bdf_mode;
        int mode_count;

        phase.raise_objection(this);
        duplicate_mode = $test$plusargs("SWITCH_NEG_DUP_NP");
        unknown_mode   = $test$plusargs("SWITCH_NEG_UNKNOWN_CPL");
        duplicate_bdf_mode = $test$plusargs("SWITCH_NEG_DUP_BDF");
        mode_count = duplicate_mode + unknown_mode + duplicate_bdf_mode;

        if (mode_count > 1)
            `uvm_fatal("SWITCH_BAD_MODE",
                       "Specify at most one SWITCH_NEG_* plusarg")
        if (duplicate_mode)
            run_duplicate_np_negative();
        else if (unknown_mode)
            run_unknown_completion_negative();
        else if (duplicate_bdf_mode)
            run_duplicate_bdf_negative();
        else
            run_positive_tests();
        phase.drop_objection(this);
    endtask
endclass

module pcie_tl_switch_proxy_unit_top;
    import uvm_pkg::*;
    import pcie_tl_switch_pkg::*;

    initial run_test("pcie_tl_switch_proxy_unit_test");

endmodule
