class pcie_tl_mem_wr_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_mem_wr_seq)
    rand bit [63:0] addr;
    rand bit [9:0]  length;
    rand bit [3:0]  first_be, last_be;
    rand bit        is_64bit;
    rand tlp_constraint_mode_e mode;
    // 用户可选的完整 payload。为空时沿用原有随机 payload 行为。
    bit [7:0]       write_data[];
    // 实际发出的 Memory Write TLP，供上层检查地址、BE 和 payload。
    pcie_tl_mem_tlp issued_tlp;
    pcie_tl_prefix  prefixes[$];
    bit             has_prefix;
    constraint c_default { mode == CONSTRAINT_LEGAL; length inside {[1:128]}; first_be != 0;
                           // Mirror the TLP's own legality constraints so uvm_do_with never forces
                           // an illegal (addr,length,last_be) combo onto the tlp (was RNDFLD):
                           //  - a request must not cross a 4KB page boundary (pcie_tl_tlp c_4kb_boundary)
                           //  - single-DW transfers force last_be=0; multi-DW require last_be!=0
                           ((addr[11:0]) + (length * 4)) <= 4096;
                           (length == 1) -> last_be == 0;
                           (length >  1) -> last_be != 0; }
    function new(string name = "pcie_tl_mem_wr_seq"); super.new(name); endfunction
    task body();
        pcie_tl_mem_tlp tlp;
        // Auto-derive is_64bit from address if not explicitly set
        if (addr[63:32] != 0) is_64bit = 1;
        // 显式 start/randomize/finish，确保 write_data 在发送前写入 payload。
        tlp = pcie_tl_mem_tlp::type_id::create("mem_wr_tlp");
        start_item(tlp);
        if (!tlp.randomize() with {
              tlp.kind == TLP_MEM_WR;
              tlp.addr == local::addr;
              tlp.length == local::length;
              tlp.first_be == local::first_be;
              tlp.last_be == local::last_be;
              tlp.is_64bit == local::is_64bit;
              tlp.constraint_mode_sel == local::mode;
            })
            `uvm_fatal("MEM_WR_SEQ", "Memory Write randomize() failed")

        // write_data 表示完整 TLP payload，按调用者提供的字节原样复制；
        // 非 DWORD 对齐访问由 first_be/last_be 表达，不在此处额外偏移。
        if (write_data.size() != 0) begin
            tlp.payload = new[write_data.size()];
            foreach (write_data[index])
                tlp.payload[index] = write_data[index];
        end
        if (has_prefix) begin
            tlp.prefixes = prefixes;
            tlp.has_prefix = 1;
        end
        issued_tlp = tlp;
        finish_item(tlp);
    endtask
endclass
