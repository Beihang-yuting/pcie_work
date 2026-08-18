module pcie_tl_switch_proxy_unit_top;
    import uvm_pkg::*;
    import pcie_tl_switch_pkg::*;

    initial begin
        pcie_tl_switch_config cfg;

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

        $display("SWITCH_PACKAGE_SMOKE_PASS");
        $finish;
    end
endmodule
