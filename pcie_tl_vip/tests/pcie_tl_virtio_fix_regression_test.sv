import uvm_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_tl_expected_scb_error_catcher extends uvm_report_catcher;
    `uvm_object_utils(pcie_tl_expected_scb_error_catcher)

    int caught_count;

    function new(string name = "pcie_tl_expected_scb_error_catcher");
        super.new(name);
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) &&
            ((get_id() == "SCB_CPL_STATUS") ||
             (get_id() == "SCB_CPL_NODATA"))) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

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

class pcie_tl_fix_probe_monitor extends pcie_tl_base_monitor;
    `uvm_component_utils(pcie_tl_fix_probe_monitor)

    function new(string name = "pcie_tl_fix_probe_monitor",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
    endtask
endclass

class pcie_tl_virtio_fix_unit_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_virtio_fix_unit_test)

    pcie_tl_fix_probe_ep_driver probe;
    pcie_tl_fix_probe_rc_driver rc_probe;
    pcie_tl_scoreboard          scb_probe;
    pcie_tl_fix_probe_monitor    monitor_probe;
    pcie_tl_if_adapter           adapter_probe;
    pcie_tl_expected_scb_error_catcher scb_error_catcher;

    function new(string name = "pcie_tl_virtio_fix_unit_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        probe = pcie_tl_fix_probe_ep_driver::type_id::create("probe", this);
        rc_probe = pcie_tl_fix_probe_rc_driver::type_id::create("rc_probe", this);
        scb_probe = pcie_tl_scoreboard::type_id::create("scb_probe", this);
        monitor_probe = pcie_tl_fix_probe_monitor::type_id::create(
            "monitor_probe", this);
        adapter_probe = pcie_tl_if_adapter::type_id::create(
            "adapter_probe", this);
        scb_error_catcher = pcie_tl_expected_scb_error_catcher::type_id::create(
            "scb_error_catcher");
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        check_terminal_completion();
        uvm_report_cb::add(null, scb_error_catcher);
        check_scoreboard_error_completion();
        check_scoreboard_missing_read_data();
        check_scoreboard_no_data_write_completion();
        check_scoreboard_expected_error_completion();
        uvm_report_cb::delete(null, scb_error_catcher);
        if (scb_error_catcher.caught_count != 2)
            `uvm_error("FIX_SCB_REPORT", $sformatf(
                "caught %0d scoreboard errors, expected 2",
                scb_error_catcher.caught_count))
        check_same_handle_tag_reuse();
        check_tlm_error_materialization();
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

    task check_tlm_error_materialization();
        pcie_tl_codec codec;
        pcie_tl_mem_tlp poisoned;
        pcie_tl_mem_tlp malformed;
        pcie_tl_mem_tlp prefixed_malformed;
        pcie_tl_mem_tlp ecrc_only;
        pcie_tl_prefix  pasid_prefix;
        pcie_tl_tlp received;
        pcie_tl_mem_tlp received_mem;

        codec = pcie_tl_codec::type_id::create("tlm_error_codec");
        adapter_probe.mode = TLM_MODE;
        adapter_probe.codec = codec;

        poisoned = pcie_tl_mem_tlp::type_id::create("tlm_poisoned");
        poisoned.kind = TLP_MEM_WR;
        poisoned.fmt = FMT_3DW_WITH_DATA;
        poisoned.type_f = TLP_TYPE_MEM_RD;
        poisoned.length = 1;
        poisoned.first_be = 4'hF;
        poisoned.last_be = 4'h0;
        poisoned.addr = 64'h5000;
        poisoned.payload = new[4];
        poisoned.ep_bit = 0;
        poisoned.inject_poisoned = 1;

        adapter_probe.send(poisoned);
        adapter_probe.tlm_tx_fifo.get(received);
        if (!$cast(received_mem, received))
            `uvm_error("FIX_TLM_ERROR", "poisoned TLM transfer lost Memory TLP type")
        else begin
            if (!received_mem.ep_bit)
                `uvm_error("FIX_TLM_ERROR",
                           "poisoned TLM transfer did not materialize EP bit")
            if (!received_mem.wire_error_materialized)
                `uvm_error("FIX_TLM_ERROR",
                           "poisoned TLM transfer lacks materialization marker")
            if (received_mem.tc != poisoned.tc)
                `uvm_error("FIX_TLM_ERROR",
                           "poison injection corrupted TC instead of EP")
        end

        malformed = pcie_tl_mem_tlp::type_id::create("tlm_malformed");
        malformed.kind = TLP_MEM_WR;
        malformed.fmt = FMT_3DW_WITH_DATA;
        malformed.type_f = TLP_TYPE_MEM_RD;
        malformed.length = 1;
        malformed.first_be = 4'hF;
        malformed.last_be = 4'h0;
        malformed.addr = 64'h6000;
        malformed.payload = new[4];
        malformed.field_bitmask = 32'h0000_0001;

        adapter_probe.send(malformed);
        adapter_probe.tlm_tx_fifo.get(received);
        if (!$cast(received_mem, received))
            `uvm_error("FIX_TLM_ERROR", "malformed TLM transfer lost Memory TLP type")
        else begin
            if (received_mem.length != 0)
                `uvm_error("FIX_TLM_ERROR", $sformatf(
                    "malformed TLM length=%0d expected encoded corruption to 0",
                    received_mem.length))
            if (!received_mem.wire_error_materialized)
                `uvm_error("FIX_TLM_ERROR",
                           "malformed TLM transfer lacks materialization marker")
        end

        prefixed_malformed = pcie_tl_mem_tlp::type_id::create(
            "tlm_prefixed_malformed");
        prefixed_malformed.kind = TLP_MEM_WR;
        prefixed_malformed.fmt = FMT_3DW_WITH_DATA;
        prefixed_malformed.type_f = TLP_TYPE_MEM_RD;
        prefixed_malformed.length = 1;
        prefixed_malformed.first_be = 4'hF;
        prefixed_malformed.last_be = 4'h0;
        prefixed_malformed.addr = 64'h6800;
        prefixed_malformed.payload = new[4];
        prefixed_malformed.field_bitmask = 32'h0000_0001;
        pasid_prefix = pcie_tl_prefix::create_pasid(20'h5A123);
        prefixed_malformed.prefixes.push_back(pasid_prefix);
        prefixed_malformed.has_prefix = 1;

        adapter_probe.send(prefixed_malformed);
        adapter_probe.tlm_tx_fifo.get(received);
        if (!$cast(received_mem, received))
            `uvm_error("FIX_TLM_PREFIX_MASK",
                       "prefixed malformed transfer lost Memory TLP type")
        else begin
            if (received_mem.length != 0)
                `uvm_error("FIX_TLM_PREFIX_MASK", $sformatf(
                    "prefixed malformed length=%0d expected 0",
                    received_mem.length))
            if ((received_mem.prefixes.size() != 1) ||
                (received_mem.prefixes[0].raw_dw != pasid_prefix.raw_dw))
                `uvm_error("FIX_TLM_PREFIX_MASK",
                           "header bitmask corrupted the TLP Prefix")
        end

        // The object-level TLM transport has no receiver-side ECRC result:
        // decode() consumes the serialized digest and returns only TLP fields.
        // Until that API exposes ECRC validity, an ECRC-only request must keep
        // normal TLM object identity and must not claim wire materialization.
        ecrc_only = pcie_tl_mem_tlp::type_id::create("tlm_ecrc_only");
        ecrc_only.kind = TLP_MEM_WR;
        ecrc_only.fmt = FMT_3DW_WITH_DATA;
        ecrc_only.type_f = TLP_TYPE_MEM_RD;
        ecrc_only.length = 1;
        ecrc_only.first_be = 4'hF;
        ecrc_only.last_be = 4'h0;
        ecrc_only.addr = 64'h7000;
        ecrc_only.payload = new[4];
        ecrc_only.td = 1;
        ecrc_only.inject_ecrc_err = 1;

        adapter_probe.send(ecrc_only);
        adapter_probe.tlm_tx_fifo.get(received);
        if (received != ecrc_only)
            `uvm_error("FIX_TLM_ECRC_SCOPE",
                       "ECRC-only TLM transfer unexpectedly lost object identity")
        if (received.wire_error_materialized)
            `uvm_error("FIX_TLM_ECRC_SCOPE",
                       "ECRC-only TLM transfer falsely claims wire materialization")
    endtask

    function void check_same_handle_tag_reuse();
        pcie_tl_tag_manager tag_mgr;
        pcie_tl_mem_tlp req;
        bit [9:0] first_tag;
        bit [9:0] reused_tag;

        tag_mgr = pcie_tl_tag_manager::type_id::create("reuse_tag_mgr");
        tag_mgr.max_outstanding = 1;
        tag_mgr.init_pool(0, 1, 0);
        monitor_probe.tag_mgr = tag_mgr;

        req = pcie_tl_mem_tlp::type_id::create("reused_req_handle");
        req.kind = TLP_MEM_RD;
        req.fmt = FMT_3DW_NO_DATA;
        req.length = 1;
        req.requester_id = 16'h0000;
        req.addr = 64'h4000;

        first_tag = tag_mgr.alloc_tag(0);
        req.tag = first_tag;
        tag_mgr.register_outstanding(first_tag, req);
        if (!monitor_probe.check_tag_validity(req))
            `uvm_error("FIX_TAG_EPOCH",
                       "first observation of initial tag epoch was rejected")

        tag_mgr.free_tag(first_tag, 0);
        reused_tag = tag_mgr.alloc_tag(0);
        if (reused_tag != first_tag)
            `uvm_error("FIX_TAG_EPOCH", $sformatf(
                "one-entry pool returned tag 0x%03h after freeing 0x%03h",
                reused_tag, first_tag))
        req.tag = reused_tag;
        tag_mgr.register_outstanding(reused_tag, req);
        if (!monitor_probe.check_tag_validity(req))
            `uvm_error("FIX_TAG_EPOCH",
                       "same request handle was rejected in a new tag epoch")

        tag_mgr.free_tag(reused_tag, 0);
    endfunction

    function void check_scoreboard_error_completion();
        pcie_tl_mem_tlp req;
        pcie_tl_cpl_tlp cpl;

        req = pcie_tl_mem_tlp::type_id::create("error_status_req");
        req.kind = TLP_MEM_RD;
        req.fmt = FMT_3DW_NO_DATA;
        req.length = 1;
        req.requester_id = 16'h0000;
        req.tag = 10'h21;
        req.addr = 64'h1000;

        cpl = pcie_tl_cpl_tlp::type_id::create("error_status_cpl");
        cpl.kind = TLP_CPL;
        cpl.fmt = FMT_3DW_NO_DATA;
        cpl.cpl_status = CPL_STATUS_UR;
        cpl.requester_id = req.requester_id;
        cpl.tag = req.tag;

        scb_probe.register_pending(req);
        scb_probe.write_rc(cpl);
        if ((scb_probe.matched != 0) || (scb_probe.mismatched != 1))
            `uvm_error("FIX_SCB_STATUS", $sformatf(
                "MRd->UR accounting matched=%0d mismatched=%0d expected=0/1",
                scb_probe.matched, scb_probe.mismatched))
        if (scb_probe.pending_requests.exists(req.tag) ||
            scb_probe.cpl_trackers.exists(req.tag))
            `uvm_error("FIX_SCB_STATUS",
                       "MRd->UR did not terminate scoreboard tracking")

        // Keep the intentionally failing probe from polluting report_phase.
        scb_probe.matched = 0;
        scb_probe.mismatched = 0;
    endfunction

    function void check_scoreboard_missing_read_data();
        pcie_tl_mem_tlp req;
        pcie_tl_cpl_tlp cpl;

        req = pcie_tl_mem_tlp::type_id::create("missing_data_req");
        req.kind = TLP_MEM_RD;
        req.fmt = FMT_3DW_NO_DATA;
        req.length = 1;
        req.requester_id = 16'h0000;
        req.tag = 10'h22;
        req.addr = 64'h2000;

        cpl = pcie_tl_cpl_tlp::type_id::create("missing_data_cpl");
        cpl.kind = TLP_CPL;
        cpl.fmt = FMT_3DW_NO_DATA;
        cpl.cpl_status = CPL_STATUS_SC;
        cpl.requester_id = req.requester_id;
        cpl.tag = req.tag;

        scb_probe.register_pending(req);
        scb_probe.write_rc(cpl);
        if ((scb_probe.matched != 0) || (scb_probe.mismatched != 1))
            `uvm_error("FIX_SCB_NODATA", $sformatf(
                "MRd->no-data-SC accounting matched=%0d mismatched=%0d expected=0/1",
                scb_probe.matched, scb_probe.mismatched))
        if (scb_probe.pending_requests.exists(req.tag) ||
            scb_probe.cpl_trackers.exists(req.tag))
            `uvm_error("FIX_SCB_NODATA",
                       "MRd->no-data-SC did not terminate scoreboard tracking")

        scb_probe.matched = 0;
        scb_probe.mismatched = 0;
    endfunction

    function void check_scoreboard_no_data_write_completion();
        pcie_tl_cfg_tlp req;
        pcie_tl_cpl_tlp cpl;

        req = pcie_tl_cfg_tlp::type_id::create("no_data_write_req");
        req.kind = TLP_CFG_WR0;
        req.fmt = FMT_3DW_WITH_DATA;
        req.length = 1;
        req.requester_id = 16'h0000;
        req.tag = 10'h23;

        cpl = pcie_tl_cpl_tlp::type_id::create("no_data_write_cpl");
        cpl.kind = TLP_CPL;
        cpl.fmt = FMT_3DW_NO_DATA;
        cpl.cpl_status = CPL_STATUS_SC;
        cpl.requester_id = req.requester_id;
        cpl.tag = req.tag;

        scb_probe.register_pending(req);
        scb_probe.write_rc(cpl);
        if ((scb_probe.matched != 1) || (scb_probe.mismatched != 0))
            `uvm_error("FIX_SCB_NODATA", $sformatf(
                "CfgWr->no-data-SC accounting matched=%0d mismatched=%0d expected=1/0",
                scb_probe.matched, scb_probe.mismatched))
        if (scb_probe.pending_requests.exists(req.tag) ||
            scb_probe.cpl_trackers.exists(req.tag))
            `uvm_error("FIX_SCB_NODATA",
                       "CfgWr->no-data-SC did not terminate scoreboard tracking")

        scb_probe.matched = 0;
    endfunction

    function void check_scoreboard_expected_error_completion();
        pcie_tl_mem_tlp req;
        pcie_tl_cpl_tlp cpl;

        req = pcie_tl_mem_tlp::type_id::create("expected_error_req");
        req.kind = TLP_MEM_RD;
        req.fmt = FMT_3DW_NO_DATA;
        req.length = 1;
        req.requester_id = 16'h0000;
        req.tag = 10'h24;
        req.addr = 64'h3000;
        req.expected_cpl_status = CPL_STATUS_CA;

        cpl = pcie_tl_cpl_tlp::type_id::create("expected_error_cpl");
        cpl.kind = TLP_CPL;
        cpl.fmt = FMT_3DW_NO_DATA;
        cpl.cpl_status = CPL_STATUS_CA;
        cpl.requester_id = req.requester_id;
        cpl.tag = req.tag;

        scb_probe.register_pending(req);
        scb_probe.write_rc(cpl);
        if ((scb_probe.matched != 1) || (scb_probe.mismatched != 0))
            `uvm_error("FIX_SCB_EXPECTED", $sformatf(
                "expected MRd->CA accounting matched=%0d mismatched=%0d expected=1/0",
                scb_probe.matched, scb_probe.mismatched))
        if (scb_probe.pending_requests.exists(req.tag) ||
            scb_probe.cpl_trackers.exists(req.tag))
            `uvm_error("FIX_SCB_EXPECTED",
                       "expected MRd->CA did not terminate scoreboard tracking")

        scb_probe.matched = 0;
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
