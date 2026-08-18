module pcie_tl_switch_proxy_unit_top;
    import uvm_pkg::*;
    import pcie_tl_switch_pkg::*;

    task automatic check_eq(bit [31:0] actual, bit [31:0] expected,
                            string label);
        if (actual !== expected)
            $fatal(1, "%s expected=%08h actual=%08h", label, expected, actual);
    endtask

    initial begin
        pcie_tl_switch_config cfg;
        pcie_tl_switch_port usp;
        pcie_tl_switch_port dsp;

        cfg = new("cfg");
        cfg.num_usp      = 1;
        cfg.num_ds_ports = 4;
        cfg.init_defaults();

        if (cfg.usp_sec_bus.size() != 1)
            $fatal(1, "usp_sec_bus size mismatch: expected 1, got %0d",
                   cfg.usp_sec_bus.size());
        if (cfg.ds_secondary_bus.size() != 4)
            $fatal(1, "ds_secondary_bus size mismatch: expected 4, got %0d",
                   cfg.ds_secondary_bus.size());

        usp = new("usp", null);
        dsp = new("dsp", null);
        usp.init_type1_image(SWITCH_USP, 0, 16'h0100);
        dsp.init_type1_image(SWITCH_DSP, 2, 16'h0202);

        check_eq(usp.cfg_read(12'h000), 32'h5010_20f9, "USP vendor/device");
        check_eq(dsp.cfg_read(12'h000), 32'h5022_20f9, "DSP vendor/device");
        check_eq(usp.cfg_read(12'h008), 32'h0604_0001, "bridge class/revision");
        check_eq(usp.cfg_read(12'h00c), 32'h0001_0000, "USP header type 1");
        check_eq(dsp.cfg_read(12'h00c), 32'h0001_0000, "DSP header type 1");
        check_eq(usp.cfg_read(12'h034), 32'h0000_0040, "PCIe cap pointer");
        check_eq(usp.cfg_read(12'h040), 32'h0052_0010, "USP PCIe capability");
        check_eq(dsp.cfg_read(12'h040), 32'h0062_0010, "DSP PCIe capability");

        usp.cfg_write(12'h000, 32'hffff_ffff, 4'hf);
        usp.cfg_write(12'h008, 32'hffff_ffff, 4'hf);
        usp.cfg_write(12'h00c, 32'hffff_ffff, 4'hf);
        usp.cfg_write(12'h034, 32'hffff_ffff, 4'hf);
        usp.cfg_write(12'h040, 32'hffff_ffff, 4'hf);
        dsp.cfg_write(12'h040, 32'hffff_ffff, 4'hf);
        check_eq(usp.cfg_read(12'h000), 32'h5010_20f9,
                 "vendor/device read-only");
        check_eq(usp.cfg_read(12'h008), 32'h0604_0001,
                 "class/revision read-only");
        check_eq(usp.cfg_read(12'h00c), 32'h0001_0000,
                 "header read-only");
        check_eq(usp.cfg_read(12'h034), 32'h0000_0040,
                 "capability pointer read-only");
        check_eq(usp.cfg_read(12'h040), 32'h0052_0010,
                 "USP capability read-only");
        check_eq(dsp.cfg_read(12'h040), 32'h0062_0010,
                 "DSP capability read-only");

        usp.cfg_write(12'h004, 32'hffff_0000, 4'b1100);
        check_eq(usp.cfg_read(12'h004), 32'h0010_0000, "status read-only");
        usp.cfg_write(12'h004, 32'h0000_a5c3, 4'b0011);
        check_eq(usp.cfg_read(12'h004), 32'h0010_a5c3,
                 "command nonzero sentinel");
        usp.cfg_write(12'h004, 32'h0000_005a, 4'b0001);
        check_eq(usp.cfg_read(12'h004), 32'h0010_a55a,
                 "command low byte enable");
        usp.cfg_write(12'h004, 32'h0000_3c00, 4'b0010);
        check_eq(usp.cfg_read(12'h004), 32'h0010_3c5a,
                 "command high byte enable");

        usp.cfg_write(12'h018, 32'hb3a2_7100, 4'b1110);
        check_eq(usp.cfg_read(12'h018), 32'hb3a2_7100,
                 "bus nonzero sentinel");
        usp.cfg_write(12'h018, 32'h0000_5c00, 4'b0010);
        check_eq(usp.cfg_read(12'h018), 32'hb3a2_5c00,
                 "primary bus byte enable");
        usp.cfg_write(12'h018, 32'h00d4_0000, 4'b0100);
        check_eq(usp.cfg_read(12'h018), 32'hb3d4_5c00,
                 "secondary bus byte enable");
        usp.cfg_write(12'h018, 32'he600_0000, 4'b1000);
        check_eq(usp.cfg_read(12'h018), 32'he6d4_5c00,
                 "subordinate bus byte enable");

        usp.cfg_write(12'h020, 32'hc3d0_a5b0, 4'hf);
        check_eq(usp.cfg_read(12'h020), 32'hc3d0_a5b0,
                 "memory window nonzero sentinel");
        usp.cfg_write(12'h020, 32'h0000_0070, 4'b0001);
        check_eq(usp.cfg_read(12'h020), 32'hc3d0_a570,
                 "memory base low byte enable");
        usp.cfg_write(12'h020, 32'h0000_5a00, 4'b0010);
        check_eq(usp.cfg_read(12'h020), 32'hc3d0_5a70,
                 "memory base high byte enable");
        usp.cfg_write(12'h020, 32'h00e0_0000, 4'b0100);
        check_eq(usp.cfg_read(12'h020), 32'hc3e0_5a70,
                 "memory limit low byte enable");
        usp.cfg_write(12'h020, 32'h7400_0000, 4'b1000);
        check_eq(usp.cfg_read(12'h020), 32'h74e0_5a70,
                 "memory limit high byte enable");

        dsp.cfg_write(12'h024, 32'h1071_1001, 4'hf);
        dsp.cfg_write(12'h028, 32'h0000_0001, 4'hf);
        dsp.cfg_write(12'h02c, 32'h0000_0001, 4'hf);
        if ((dsp.pref_base != 64'h0000_0001_1000_0000) ||
            (dsp.pref_limit != 64'h0000_0001_107f_ffff))
            $fatal(1, "64-bit Prefetchable window decode failed");

        dsp.cfg_write(12'h024, 32'hab71_cd21, 4'hf);
        dsp.cfg_write(12'h024, 32'h0000_00e4, 4'b0001);
        check_eq(dsp.cfg_read(12'h024), 32'hab71_cde1,
                 "prefetch base low byte enable");
        dsp.cfg_write(12'h024, 32'h0000_5a00, 4'b0010);
        check_eq(dsp.cfg_read(12'h024), 32'hab71_5ae1,
                 "prefetch base high byte enable");
        dsp.cfg_write(12'h024, 32'h0066_0000, 4'b0100);
        check_eq(dsp.cfg_read(12'h024), 32'hab61_5ae1,
                 "prefetch limit low byte enable");
        dsp.cfg_write(12'h024, 32'hd700_0000, 4'b1000);
        check_eq(dsp.cfg_read(12'h024), 32'hd761_5ae1,
                 "prefetch limit high byte enable");
        check_eq(dsp.pref_base_reg[3:0], 4'h1,
                 "prefetch base 64-bit type");
        check_eq(dsp.pref_limit_reg[3:0], 4'h1,
                 "prefetch limit 64-bit type");

        dsp.cfg_write(12'h028, 32'h1122_3344, 4'hf);
        dsp.cfg_write(12'h028, 32'h00aa_00bb, 4'b0101);
        check_eq(dsp.cfg_read(12'h028), 32'h11aa_33bb,
                 "prefetch base upper partial byte enables");
        dsp.cfg_write(12'h02c, 32'h99aa_bbcc, 4'hf);
        dsp.cfg_write(12'h02c, 32'hdd00_ee00, 4'b1010);
        check_eq(dsp.cfg_read(12'h02c), 32'hddaa_eecc,
                 "prefetch limit upper partial byte enables");
        if ((dsp.pref_base != 64'h11aa_33bb_5ae0_0000) ||
            (dsp.pref_limit != 64'hddaa_eecc_d76f_ffff))
            $fatal(1,
                   "Partial-BE prefetch decode failed base=%016h limit=%016h",
                   dsp.pref_base, dsp.pref_limit);

        $display("TYPE1_CFG_PASS");
        $display("SWITCH_PACKAGE_SMOKE_PASS");
        $finish;
    end
endmodule
