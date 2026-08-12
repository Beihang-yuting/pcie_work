import uvm_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_tl_fix_probe_ep_driver extends pcie_tl_ep_driver;
    `uvm_component_utils(pcie_tl_fix_probe_ep_driver)

    function new(string name = "pcie_tl_fix_probe_ep_driver",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void seed_readback(bit [9:0] tag, pcie_tl_tlp req);
        rb_outstanding[tag] = req;
        req.rb_done = 0;
    endfunction

    function void note_completion(pcie_tl_cpl_tlp cpl);
        rb_note_completion(cpl);
    endfunction

    task apply_request(pcie_tl_tlp req);
        response_delay_min = 0;
        response_delay_max = 0;
        handle_request(req);
    endtask

    function pcie_tl_cpl_tlp make_completion(pcie_tl_tlp req);
        return generate_completion(req, CPL_STATUS_SC);
    endfunction

    task run_phase(uvm_phase phase);
    endtask
endclass

class pcie_tl_fix_probe_rc_driver extends pcie_tl_rc_driver;
    `uvm_component_utils(pcie_tl_fix_probe_rc_driver)

    function new(string name = "pcie_tl_fix_probe_rc_driver",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
    endtask
endclass

class pcie_tl_order_probe_ep_driver extends pcie_tl_ep_driver;
    `uvm_component_utils(pcie_tl_order_probe_ep_driver)

    int ordered_state;
    int ordering_failures;

    function new(string name = "pcie_tl_order_probe_ep_driver",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task handle_request(pcie_tl_tlp req);
        if (req.kind == TLP_MEM_WR) begin
            #100ns;
            ordered_state = 1;
        end else if (req.kind == TLP_MEM_RD && ordered_state != 1) begin
            ordering_failures++;
        end
    endtask
endclass

class pcie_tl_virtio_fix_unit_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_virtio_fix_unit_test)

    pcie_tl_fix_probe_ep_driver probe;
    pcie_tl_fix_probe_rc_driver rc_probe;
    pcie_tl_scoreboard          scb_probe;

    function new(string name = "pcie_tl_virtio_fix_unit_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        probe = pcie_tl_fix_probe_ep_driver::type_id::create("probe", this);
        rc_probe = pcie_tl_fix_probe_rc_driver::type_id::create("rc_probe", this);
        scb_probe = pcie_tl_scoreboard::type_id::create("scb_probe", this);
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        check_terminal_completion();
        check_sparse_byte_enables();
        check_scoreboard_byte_enables();
        check_1024dw_decode();
        check_config_read_byte_count();
        phase.drop_objection(this);
    endtask

    function void check_terminal_completion();
        pcie_tl_cfg_tlp req;
        pcie_tl_cpl_tlp cpl;
        pcie_tl_tag_manager tag_mgr;
        bit [9:0] tag;

        req = pcie_tl_cfg_tlp::type_id::create("terminal_req");
        req.kind = TLP_CFG_WR0;
        req.length = 1;
        req.requester_id = 16'h0000;

        cpl = pcie_tl_cpl_tlp::type_id::create("terminal_cpl");
        cpl.kind = TLP_CPL;
        cpl.fmt = FMT_3DW_NO_DATA;
        cpl.cpl_status = CPL_STATUS_SC;
        cpl.requester_id = req.requester_id;
        cpl.tag = 10'h12;

        probe.seed_readback(cpl.tag, req);
        probe.note_completion(cpl);
        if (!req.rb_done)
            `uvm_error("FIX_NO_DATA",
                       "successful no-data Completion did not finish read-back")

        tag_mgr = pcie_tl_tag_manager::type_id::create("terminal_tag_mgr");
        tag_mgr.init_pool(0, 1, 0);
        tag = tag_mgr.alloc_tag(0);
        req.tag = tag;
        tag_mgr.register_outstanding(tag, req);
        rc_probe.tag_mgr = tag_mgr;
        cpl.tag = tag;
        void'(rc_probe.handle_completion(cpl));
        if (tag_mgr.get_outstanding_count() != 0)
            `uvm_error("FIX_RC_TAG",
                       "RC retained tag after terminal no-data Completion")
    endfunction

    task check_sparse_byte_enables();
        pcie_tl_mem_tlp req;
        bit [63:0] addr = 64'h0000_0000_0000_1003;
        bit [63:0] base = 64'h0000_0000_0000_1000;

        req = pcie_tl_mem_tlp::type_id::create("sparse_be_req");
        req.kind = TLP_MEM_WR;
        req.fmt = FMT_3DW_WITH_DATA;
        req.addr = addr;
        req.length = 2;
        req.first_be = 4'b0101;
        req.last_be = 4'b1010;
        req.payload = new[8];
        foreach (req.payload[i]) req.payload[i] = 8'hA0 + i;

        probe.apply_request(req);
        if (!probe.mem_space.exists(base + 0) ||
            probe.mem_space[base + 0] != 8'hA0 ||
            probe.mem_space.exists(base + 1) ||
            !probe.mem_space.exists(base + 2) ||
            probe.mem_space[base + 2] != 8'hA2 ||
            probe.mem_space.exists(base + 3) ||
            probe.mem_space.exists(base + 4) ||
            !probe.mem_space.exists(base + 5) ||
            probe.mem_space[base + 5] != 8'hA5 ||
            probe.mem_space.exists(base + 6) ||
            !probe.mem_space.exists(base + 7) ||
            probe.mem_space[base + 7] != 8'hA7)
            `uvm_error("FIX_EP_BE",
                       "sparse EP memory ignored first_be/last_be")
    endtask

    function void check_scoreboard_byte_enables();
        pcie_tl_mem_tlp req;
        bit [63:0] addr = 64'h0000_0000_0000_2000;

        req = pcie_tl_mem_tlp::type_id::create("scoreboard_be_req");
        req.kind = TLP_MEM_WR;
        req.fmt = FMT_3DW_WITH_DATA;
        req.addr = addr;
        req.length = 2;
        req.first_be = 4'b0101;
        req.last_be = 4'b1010;
        req.payload = new[8];
        foreach (req.payload[i]) req.payload[i] = 8'hB0 + i;

        scb_probe.write_rc(req);
        if (!scb_probe.written_data.exists(addr + 0) ||
            scb_probe.written_data.exists(addr + 1) ||
            !scb_probe.written_data.exists(addr + 2) ||
            scb_probe.written_data.exists(addr + 3) ||
            scb_probe.written_data.exists(addr + 4) ||
            !scb_probe.written_data.exists(addr + 5) ||
            scb_probe.written_data.exists(addr + 6) ||
            !scb_probe.written_data.exists(addr + 7))
            `uvm_error("FIX_SCB_BE",
                       "scoreboard recorded a disabled byte lane")
    endfunction

    function void check_1024dw_decode();
        pcie_tl_codec codec;
        pcie_tl_mem_tlp original;
        pcie_tl_tlp decoded;
        bit [7:0] bytes[];

        codec = pcie_tl_codec::type_id::create("codec_probe");
        original = pcie_tl_mem_tlp::type_id::create("length_zero_req");
        original.kind = TLP_MEM_WR;
        original.fmt = FMT_3DW_WITH_DATA;
        original.type_f = TLP_TYPE_MEM_RD;
        original.length = 0;
        original.first_be = 4'hF;
        original.last_be = 4'hF;
        original.addr = 64'h3000;
        original.payload = new[4096];
        foreach (original.payload[i]) original.payload[i] = i[7:0];

        codec.encode(original, bytes);
        decoded = codec.decode(bytes);
        if (decoded.payload.size() != 4096)
            `uvm_error("FIX_1024DW", $sformatf(
                       "decoded payload size=%0d expected=4096",
                       decoded.payload.size()))
    endfunction

    function void check_config_read_byte_count();
        pcie_tl_cfg_tlp req;
        pcie_tl_cpl_tlp cpl;

        req = pcie_tl_cfg_tlp::type_id::create("cfg_read_req");
        req.kind = TLP_CFG_RD0;
        req.length = 1;
        cpl = probe.make_completion(req);
        if (cpl.byte_count != 12'd4)
            `uvm_error("FIX_CFG_BC", $sformatf(
                       "config read byte_count=%0d expected=4", cpl.byte_count))
    endfunction
endclass

class pcie_tl_virtio_fix_order_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_virtio_fix_order_test)

    function new(string name = "pcie_tl_virtio_fix_order_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        pcie_tl_ep_driver::type_id::set_type_override(
            pcie_tl_order_probe_ep_driver::get_type());
        super.build_phase(phase);
    endfunction

    task run_phase(uvm_phase phase);
        pcie_tl_order_probe_ep_driver probe;
        pcie_tl_mem_tlp wr;
        pcie_tl_mem_tlp rd;

        phase.raise_objection(this);
        if (!$cast(probe, env.ep_agent.ep_driver))
            `uvm_fatal("FIX_ORDER", "ordering probe factory override failed")

        wr = pcie_tl_mem_tlp::type_id::create("ordered_write");
        wr.kind = TLP_MEM_WR;
        rd = pcie_tl_mem_tlp::type_id::create("ordered_read");
        rd.kind = TLP_MEM_RD;

        env.rc_adapter.tlm_tx_fifo.put(wr);
        env.rc_adapter.tlm_tx_fifo.put(rd);
        #250ns;

        if (probe.ordering_failures != 0)
            `uvm_error("FIX_ORDER",
                       "endpoint ingress handled read before preceding posted write")
        phase.drop_objection(this);
    endtask
endclass
