class pcie_tl_mem_rd_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_mem_rd_seq)
    rand bit [63:0] addr;
    rand bit [9:0]  length;
    rand bit [3:0]  first_be, last_be;
    rand bit        is_64bit;
    rand tlp_constraint_mode_e mode;
    pcie_tl_prefix  prefixes[$];
    bit             has_prefix;
    // 实际发出的 Memory Read TLP，便于检查地址、长度、BE 和 Completion。
    pcie_tl_mem_tlp issued_tlp;
    // Completion 返回的字节副本。该队列与 issued_tlp.rb_data 分开保存，
    // 让上层 sequence 在 body() 返回后仍可稳定读取结果。
    bit [7:0]       rb_data[$];
    // 非 posted Memory Read 的回读等待预算；单位为 ns。
    int             rb_timeout_ns = 50000;
    constraint c_default { mode == CONSTRAINT_LEGAL; length inside {[1:128]}; first_be != 0; }
    function new(string name = "pcie_tl_mem_rd_seq"); super.new(name); endfunction
    task body();
        pcie_tl_mem_tlp tlp;

        // 每次启动 sequence 都清理上一次请求的可观测句柄和回读数据。
        issued_tlp = null;
        rb_data.delete();

        // Auto-derive is_64bit from address if not explicitly set
        if (addr[63:32] != 0) is_64bit = 1;
        // 显式 start/randomize/finish，确保 issued_tlp 在 driver 取得 item
        // 前就已经指向同一个对象。
        tlp = pcie_tl_mem_tlp::type_id::create("mem_rd_tlp");
        start_item(tlp);
        if (!tlp.randomize() with {
              tlp.kind == TLP_MEM_RD;
              tlp.addr == local::addr;
              tlp.length == local::length;
              tlp.first_be == local::first_be;
              tlp.last_be == local::last_be;
              tlp.is_64bit == local::is_64bit;
              tlp.constraint_mode_sel == local::mode;
            })
            `uvm_fatal("MEM_RD_SEQ", "Memory Read randomize() failed")
        if (has_prefix) begin
            tlp.prefixes = prefixes;
            tlp.has_prefix = 1;
        end
        issued_tlp = tlp;
        finish_item(tlp);

        // Memory Read 必须等待 Completion；在 adapter 模式下该 Completion
        // 由 monitor 写回 issued_tlp，在 TLM 模式下由 driver 完成同样的
        // 回写。使用有界等待避免没有对端时 sequence 永久阻塞。
        fork begin : completion_wait
            fork
                wait (tlp.rb_done);
                #(rb_timeout_ns * 1ns);
            join_any
            disable fork;
        end join

        // requester driver/monitor 将 Completion 折叠到同一个 TLP 对象；
        // sequence 对外再提供一份独立队列，避免调用者依赖内部实现。
        foreach (tlp.rb_data[index])
            rb_data.push_back(tlp.rb_data[index]);

        if (!tlp.rb_done)
            `uvm_error("MEM_RD_SEQ", $sformatf(
                "Memory Read Completion timeout: addr=0x%016h length=%0d",
                addr, length))
    endtask
endclass
