import uvm_pkg::*;
import pcie_tl_switch_pkg::*;

class pcie_tl_switch_proxy_unit_test extends uvm_test;
    `uvm_component_utils(pcie_tl_switch_proxy_unit_test)

    pcie_tl_switch_config cfg;
    pcie_tl_switch        sw;
    pcie_tl_switch_port   unit_usp;
    pcie_tl_switch_port   unit_dsp;

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

        unit_usp = new("unit_usp", this);
        unit_dsp = new("unit_dsp", this);
    endfunction

    function void pre_abort();
        int system_status;

        super.pre_abort();
        if ($test$plusargs("SWITCH_NEG_DUP_NP") ||
            $test$plusargs("SWITCH_NEG_UNKNOWN_CPL")) begin
            // Stock UVM 1.2 uses $finish for UVM_FATAL and this VCS build
            // returns status zero even for $fatal. The child shell's PPID is
            // the simulator, so terminate it after the fatal record is flushed.
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

    task automatic program_dsp0_pref_window(bit memory_enable);
        sw.dsp[0].cfg_write(12'h004,
                            memory_enable ? 32'h0000_0002 : 32'h0000_0000,
                            4'b0011);
        sw.dsp[0].cfg_write(12'h024, 32'h1071_1001, 4'hf);
        sw.dsp[0].cfg_write(12'h028, 32'h0000_0001, 4'hf);
        sw.dsp[0].cfg_write(12'h02c, 32'h0000_0001, 4'hf);
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
        pcie_tl_cfg_tlp cfg_req;
        pcie_tl_cfg_tlp routed_cfg;
        pcie_tl_cpl_tlp cpl;
        pcie_tl_tlp     forwarded;
        pcie_tl_tlp     returned_cpl;

        run_type1_config_tests();

        sw.refresh_local_bdf_map();
        check_route(sw.local_port_for_bdf(16'h0100), 0, "USP BDF");
        check_route(sw.local_port_for_bdf(16'h0200), 1, "DSP0 BDF");
        check_route(sw.local_port_for_bdf(16'h0208), 2, "DSP1 BDF");
        check_route(sw.local_port_for_bdf(16'h0210), 3, "DSP2 BDF");
        check_route(sw.local_port_for_bdf(16'h0218), 4, "DSP3 BDF");

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
        cfg_req.completer_id        = 16'h0200;
        cfg_req.reg_num             = 10'h2a5;
        cfg_req.first_be            = 4'ha;
        cfg_req.inject_ecrc_err     = 1'b1;
        cfg_req.inject_lcrc_err     = 1'b1;
        cfg_req.inject_poisoned     = 1'b1;
        cfg_req.violate_ordering    = 1'b1;
        cfg_req.field_bitmask       = 32'ha5a5_5a5a;
        cfg_req.constraint_mode_sel = CONSTRAINT_ILLEGAL;
        cfg_req.cq_route.valid      = 1'b1;
        cfg_req.cq_route.target_bdf = 16'h0200;
        cfg_req.cq_route.target_func = 8'h3c;

        sw.usp.rx_fifo.put(cfg_req);
        sw.dsp[0].tx_fifo.get(forwarded);
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
        check_route(sw.outstanding_count(), 1,
                    "one outstanding non-posted request");

        cpl = pcie_tl_cpl_tlp::type_id::create("cpl");
        cpl.kind         = TLP_CPL;
        cpl.fmt          = FMT_3DW_NO_DATA;
        cpl.type_f       = TLP_TYPE_CPL;
        cpl.requester_id = 16'h0000;
        cpl.tag          = 10'h155;
        cpl.completer_id = 16'h0200;
        cpl.cpl_status   = CPL_STATUS_SC;

        sw.dsp[0].rx_fifo.put(cpl);
        sw.usp.tx_fifo.get(returned_cpl);
        if (returned_cpl != cpl)
            $fatal(1, "Completion did not return unchanged to the USP");
        check_route(sw.outstanding_count(), 0,
                    "outstanding requests drained by Completion");

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
        req.completer_id = 16'h0200;
        req.reg_num      = 10'h001;
        req.first_be     = 4'hf;

        sw.usp.rx_fifo.put(req);
        sw.dsp[0].tx_fifo.get(forwarded);
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
        cpl.completer_id = 16'h0200;
        cpl.cpl_status   = CPL_STATUS_SC;

        sw.dsp[0].rx_fifo.put(cpl);
        #10;
        $fatal(1, "Unknown Completion did not terminate simulation");
    endtask

    task run_phase(uvm_phase phase);
        bit duplicate_mode;
        bit unknown_mode;

        phase.raise_objection(this);
        duplicate_mode = $test$plusargs("SWITCH_NEG_DUP_NP");
        unknown_mode   = $test$plusargs("SWITCH_NEG_UNKNOWN_CPL");

        if (duplicate_mode && unknown_mode)
            `uvm_fatal("SWITCH_BAD_MODE",
                       "Specify at most one SWITCH_NEG_* plusarg")
        if (duplicate_mode)
            run_duplicate_np_negative();
        else if (unknown_mode)
            run_unknown_completion_negative();
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
