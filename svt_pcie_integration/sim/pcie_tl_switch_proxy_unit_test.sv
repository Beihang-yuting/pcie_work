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
        check_eq(usp.cfg_read(12'h008), 32'h0604_0001, "bridge class/revision");
        check_eq(usp.cfg_read(12'h00c) & 32'h00ff_0000,
                 32'h0001_0000, "header type 1");
        check_eq(usp.cfg_read(12'h034) & 32'hff, 32'h40, "PCIe cap pointer");
        check_eq((usp.cfg_read(12'h040) >> 20) & 4'hf, 4'h5,
                 "USP port type");
        check_eq((dsp.cfg_read(12'h040) >> 20) & 4'hf, 4'h6,
                 "DSP port type");

        usp.cfg_write(12'h018, 32'h0602_0100, 4'b1110);
        check_eq(usp.cfg_read(12'h018), 32'h0602_0100, "bus byte enables");
        usp.cfg_write(12'h004, 32'h0000_0002, 4'b0001);
        check_eq(usp.cfg_read(12'h004) & 32'h0000_0002,
                 32'h0000_0002, "Memory Space Enable");

        dsp.cfg_write(12'h024, 32'h1071_1001, 4'hf);
        dsp.cfg_write(12'h028, 32'h0000_0001, 4'hf);
        dsp.cfg_write(12'h02c, 32'h0000_0001, 4'hf);
        if ((dsp.pref_base != 64'h0000_0001_1000_0000) ||
            (dsp.pref_limit != 64'h0000_0001_107f_ffff))
            $fatal(1, "64-bit Prefetchable window decode failed");

        $display("TYPE1_CFG_PASS");
        $display("SWITCH_PACKAGE_SMOKE_PASS");
        $finish;
    end
endmodule
