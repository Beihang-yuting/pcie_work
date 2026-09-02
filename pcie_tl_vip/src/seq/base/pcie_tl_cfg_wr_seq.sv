class pcie_tl_cfg_wr_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_cfg_wr_seq)
    rand bit [15:0] target_bdf;
    rand bit [9:0]  reg_num;
    rand bit [3:0]  first_be;
    rand bit [31:0] wr_data;
    rand bit        is_type1;
    rand tlp_constraint_mode_e mode;
    pcie_rw_status_e status = PCIE_RW_OK;
    int rb_timeout_ns = 50000;
    constraint c_default { mode == CONSTRAINT_LEGAL; first_be == 4'hF; }
    function new(string name = "pcie_tl_cfg_wr_seq"); super.new(name); endfunction
    task body();
        pcie_tl_cfg_tlp tlp;
        tlp_kind_e k = is_type1 ? TLP_CFG_WR1 : TLP_CFG_WR0;

        // Configuration Writes are non-posted.  Set payload bytes before the
        // request leaves the sequencer, then wait for the Completion folded
        // back onto this same TLP by the requester monitor/driver.
        tlp = pcie_tl_cfg_tlp::type_id::create("cfg_wr_tlp");
        start_item(tlp);
        if (!tlp.randomize() with {
              tlp.kind == k;
              tlp.completer_id == local::target_bdf;
              tlp.reg_num == local::reg_num;
              tlp.first_be == local::first_be;
              tlp.constraint_mode_sel == local::mode;
            })
            `uvm_fatal("CFG_WR_SEQ", "Configuration Write randomize() failed")
        tlp.payload = new[4];
        foreach (tlp.payload[index])
            tlp.payload[index] = wr_data[index * 8 +: 8];
        finish_item(tlp);

        fork begin : completion_wait
            fork
                wait (tlp.rb_done);
                #(rb_timeout_ns * 1ns);
            join_any
            disable fork;
        end join
        if (!tlp.rb_done) begin
            status = PCIE_RW_TIMEOUT;
            `uvm_error("CFG_WR_SEQ", $sformatf(
                "Configuration Write timeout: BDF=%04x offset=0x%03x",
                target_bdf, {reg_num, 2'b00}))
            return;
        end
        status = (tlp.rb_status == CPL_STATUS_SC) ?
                 PCIE_RW_OK : PCIE_RW_ERR;
    endtask
endclass
