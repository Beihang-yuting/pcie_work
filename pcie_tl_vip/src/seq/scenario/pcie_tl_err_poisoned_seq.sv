class pcie_tl_err_poisoned_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_err_poisoned_seq)
    function new(string name = "pcie_tl_err_poisoned_seq"); super.new(name); endfunction
    task body();
        pcie_tl_mem_tlp tlp;
        `uvm_do_with(tlp, {
            tlp.kind == TLP_MEM_WR;
            tlp.constraint_mode_sel == CONSTRAINT_ILLEGAL;

            // Keep poisoning as the sole illegal dimension.  The rest is a
            // deterministic, legal-shaped 1-DW Memory Write.
            tlp.inject_poisoned == 1;
            tlp.inject_ecrc_err == 0;
            tlp.inject_lcrc_err == 0;
            tlp.violate_ordering == 0;
            tlp.field_bitmask == 0;
            tlp.ep_bit == 0;

            tlp.has_prefix == 0;
            tlp.prefixes.size() == 0;
            tlp.tc == 0;
            tlp.th == 0;
            tlp.td == 0;
            tlp.attr == 0;
            tlp.at == 0;
            tlp.is_64bit == 0;
            tlp.addr == 64'h0000_0000_0000_1000;
            tlp.length == 1;
            tlp.first_be == 4'hF;
            tlp.last_be == 4'h0;
            tlp.payload.size() == 4;
            foreach (tlp.payload[i]) tlp.payload[i] == 8'hA5;
        })
    endtask
endclass
