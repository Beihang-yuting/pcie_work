class pcie_tl_cfg_rd_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_cfg_rd_seq)
    rand bit [15:0] target_bdf;
    rand bit [9:0]  reg_num;
    rand bit [3:0]  first_be;
    rand bit        is_type1;
    rand tlp_constraint_mode_e mode;
    bit [15:0] completer_id;  // alias for target_bdf (set either one)
    bit [31:0] rd_data;
    pcie_rw_status_e status = PCIE_RW_OK;
    int rb_timeout_ns = 50000;
    constraint c_default { mode == CONSTRAINT_LEGAL; first_be == 4'hF; }
    function new(string name = "pcie_tl_cfg_rd_seq"); super.new(name); endfunction
    task body();
        pcie_tl_cfg_tlp tlp;
        tlp_kind_e k = is_type1 ? TLP_CFG_RD1 : TLP_CFG_RD0;
        if (completer_id != 0) target_bdf = completer_id;

        tlp = pcie_tl_cfg_tlp::type_id::create("cfg_rd_tlp");
        start_item(tlp);
        if (!tlp.randomize() with {
              tlp.kind == k;
              tlp.completer_id == local::target_bdf;
              tlp.reg_num == local::reg_num;
              tlp.first_be == local::first_be;
              tlp.constraint_mode_sel == local::mode;
            })
            `uvm_fatal("CFG_RD_SEQ", "Configuration Read randomize() failed")
        finish_item(tlp);

        // A successful Configuration Read must return one complete DWORD.
        fork begin : completion_wait
            fork
                wait (tlp.rb_done);
                #(rb_timeout_ns * 1ns);
            join_any
            disable fork;
        end join
        rd_data = '0;
        if (!tlp.rb_done) begin
            status = PCIE_RW_TIMEOUT;
            `uvm_error("CFG_RD_SEQ", $sformatf(
                "Configuration Read timeout: BDF=%04x offset=0x%03x",
                target_bdf, {reg_num, 2'b00}))
            return;
        end
        status = (tlp.rb_status == CPL_STATUS_SC) ?
                 PCIE_RW_OK : PCIE_RW_ERR;
        if ((status == PCIE_RW_OK) && (tlp.rb_data.size() >= 4))
            rd_data = {tlp.rb_data[3], tlp.rb_data[2],
                       tlp.rb_data[1], tlp.rb_data[0]};
        else if (status == PCIE_RW_OK)
            status = PCIE_RW_ERR;
    endtask
endclass
