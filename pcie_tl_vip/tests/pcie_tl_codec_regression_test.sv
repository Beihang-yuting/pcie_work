import uvm_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_tl_codec_regression_test extends uvm_test;
    `uvm_component_utils(pcie_tl_codec_regression_test)

    pcie_tl_codec codec;

    function new(string name = "pcie_tl_codec_regression_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        codec = pcie_tl_codec::type_id::create("codec");
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        check_memory_tag_encode("legacy tag", 10'h0a6,
                                96'h00000001_1234a60f_00001000);
        check_memory_tag_encode("T8 tag", 10'h1a6,
                                96'h00080001_1234a60f_00001000);
        check_memory_tag_encode("T9 tag", 10'h2a6,
                                96'h00800001_1234a60f_00001000);
        check_memory_tag_encode("T9/T8 tag", 10'h3a6,
                                96'h00880001_1234a60f_00001000);

        check_memory_tag_decode("legacy tag", 10'h0a6,
                                96'h00000001_1234a60f_00001000);
        check_memory_tag_decode("T8 tag", 10'h1a6,
                                96'h00080001_1234a60f_00001000);
        check_memory_tag_decode("T9 tag", 10'h2a6,
                                96'h00800001_1234a60f_00001000);
        check_memory_tag_decode("T9/T8 tag", 10'h3a6,
                                96'h00880001_1234a60f_00001000);

        check_completion_codec(0, 96'h0a880000_abcd0000_1357b724);
        check_completion_codec(1, 96'h4a880001_abcd0004_1357b724);
        check_clone_contract();
        phase.drop_objection(this);
    endtask

    function void expect_header(string label, bit [7:0] bytes[],
                                bit [95:0] expected, int expected_size);
        bit [95:0] actual;

        if (bytes.size() != expected_size) begin
            `uvm_error("CODEC_SIZE", $sformatf(
                "%s encoded %0d bytes, expected %0d",
                label, bytes.size(), expected_size))
            return;
        end
        actual = {bytes[0], bytes[1], bytes[2], bytes[3],
                  bytes[4], bytes[5], bytes[6], bytes[7],
                  bytes[8], bytes[9], bytes[10], bytes[11]};
        if (actual !== expected)
            `uvm_error("CODEC_HEADER", $sformatf(
                "%s header=0x%024h expected=0x%024h",
                label, actual, expected))
    endfunction

    function void literal_to_bytes(bit [95:0] header, bit with_payload,
                                   output bit [7:0] bytes[]);
        bytes = new[with_payload ? 16 : 12];
        for (int i = 0; i < 12; i++)
            bytes[i] = header[95-(i*8) -: 8];
        if (with_payload) begin
            bytes[12] = 8'hde;
            bytes[13] = 8'had;
            bytes[14] = 8'hbe;
            bytes[15] = 8'hef;
        end
    endfunction

    function void check_memory_tag_encode(string label, bit [9:0] tag,
                                          bit [95:0] expected);
        pcie_tl_mem_tlp req;
        bit [7:0] bytes[];

        req = pcie_tl_mem_tlp::type_id::create({"encode_", label});
        req.kind = TLP_MEM_RD;
        req.fmt = FMT_3DW_NO_DATA;
        req.type_f = TLP_TYPE_MEM_RD;
        req.length = 1;
        req.requester_id = 16'h1234;
        req.tag = tag;
        req.first_be = 4'hf;
        req.last_be = 4'h0;
        req.addr = 64'h0000_1000;
        codec.encode(req, bytes);
        expect_header({"memory encode ", label}, bytes, expected, 12);
    endfunction

    function void check_memory_tag_decode(string label, bit [9:0] expected_tag,
                                          bit [95:0] header);
        bit [7:0] bytes[];
        pcie_tl_tlp decoded;
        pcie_tl_mem_tlp mem;

        literal_to_bytes(header, 0, bytes);
        decoded = codec.decode(bytes);
        if (!$cast(mem, decoded)) begin
            `uvm_error("CODEC_MEM_TYPE", {"memory decode ", label,
                       " did not create pcie_tl_mem_tlp"})
            return;
        end
        if (mem.tag !== expected_tag || mem.requester_id !== 16'h1234 ||
            mem.first_be !== 4'hf || mem.last_be !== 4'h0 ||
            mem.addr !== 64'h0000_1000)
            `uvm_error("CODEC_MEM_DECODE", $sformatf(
                "%s decoded tag=0x%03h requester=0x%04h BE=%h/%h addr=0x%016h",
                label, mem.tag, mem.requester_id, mem.first_be, mem.last_be,
                mem.addr))
    endfunction

    function void check_completion_codec(bit with_data, bit [95:0] header);
        string label;
        pcie_tl_cpl_tlp source;
        pcie_tl_cpl_tlp decoded_cpl;
        pcie_tl_tlp decoded;
        bit [7:0] bytes[];

        label = with_data ? "CplD" : "Cpl";
        source = pcie_tl_cpl_tlp::type_id::create({"encode_", label});
        source.kind = with_data ? TLP_CPLD : TLP_CPL;
        source.fmt = with_data ? FMT_3DW_WITH_DATA : FMT_3DW_NO_DATA;
        source.type_f = TLP_TYPE_CPL;
        source.length = with_data ? 1 : 0;
        source.completer_id = 16'habcd;
        source.cpl_status = CPL_STATUS_SC;
        source.bcm = 0;
        source.byte_count = with_data ? 12'd4 : 12'd0;
        source.requester_id = 16'h1357;
        source.tag = 10'h3b7;
        source.lower_addr = 7'h24;
        if (with_data) begin
            source.payload = new[4];
            source.payload[0] = 8'hde;
            source.payload[1] = 8'had;
            source.payload[2] = 8'hbe;
            source.payload[3] = 8'hef;
        end

        codec.encode(source, bytes);
        expect_header({label, " encode"}, bytes, header,
                      with_data ? 16 : 12);
        if (with_data &&
            ({bytes[12], bytes[13], bytes[14], bytes[15]} !== 32'hdead_beef))
            `uvm_error("CODEC_CPL_PAYLOAD", "CplD payload changed during encode")

        literal_to_bytes(header, with_data, bytes);
        decoded = codec.decode(bytes);
        if (!$cast(decoded_cpl, decoded)) begin
            `uvm_error("CODEC_CPL_TYPE", {label,
                       " decode did not create pcie_tl_cpl_tlp"})
            return;
        end
        if (decoded_cpl.kind !== (with_data ? TLP_CPLD : TLP_CPL) ||
            decoded_cpl.requester_id !== 16'h1357 ||
            decoded_cpl.tag !== 10'h3b7 ||
            decoded_cpl.completer_id !== 16'habcd ||
            decoded_cpl.byte_count !== (with_data ? 12'd4 : 12'd0) ||
            decoded_cpl.lower_addr !== 7'h24)
            `uvm_error("CODEC_CPL_DECODE", $sformatf(
                "%s decoded kind=%s requester=0x%04h tag=0x%03h completer=0x%04h byte_count=%0d lower=0x%02h",
                label, decoded_cpl.kind.name(), decoded_cpl.requester_id,
                decoded_cpl.tag, decoded_cpl.completer_id,
                decoded_cpl.byte_count, decoded_cpl.lower_addr))
        if (with_data && (decoded_cpl.payload.size() != 4 ||
            {decoded_cpl.payload[0], decoded_cpl.payload[1],
             decoded_cpl.payload[2], decoded_cpl.payload[3]} !== 32'hdead_beef))
            `uvm_error("CODEC_CPLD_DECODE", "CplD payload changed during decode")
    endfunction

    function void check_clone_contract();
        uvm_object cloned_object;
        pcie_tl_mem_tlp mem_source, mem_clone;
        pcie_tl_io_tlp io_source, io_clone;
        pcie_tl_cfg_tlp cfg_source, cfg_clone;
        pcie_tl_msg_tlp msg_source, msg_clone;
        pcie_tl_vendor_tlp vendor_source, vendor_clone;
        pcie_tl_ltr_tlp ltr_source, ltr_clone;

        mem_source = pcie_tl_mem_tlp::type_id::create("clone_mem_source");
        mem_source.at = 2'b10;
        mem_source.prefixes.push_back(pcie_tl_prefix::create_pasid(20'h5a123));
        mem_source.has_prefix = 1;
        cloned_object = mem_source.clone();
        if (!$cast(mem_clone, cloned_object))
            `uvm_error("CLONE_MEM_TYPE", "Memory clone lost its dynamic type")
        else begin
            if (mem_clone.at !== 2'b10)
                `uvm_error("CLONE_AT", "clone lost the common AT field")
            if (mem_clone.prefixes.size() != 1 ||
                mem_clone.prefixes[0].raw_dw !== mem_source.prefixes[0].raw_dw)
                `uvm_error("CLONE_PREFIX_VALUE", "clone lost the Prefix value")
            else if (mem_clone.prefixes[0] == mem_source.prefixes[0])
                `uvm_error("CLONE_PREFIX_ALIAS", "clone retained the source Prefix handle")
            else begin
                mem_clone.prefixes[0].raw_dw[0] =
                    ~mem_clone.prefixes[0].raw_dw[0];
                if (mem_clone.prefixes[0].raw_dw === mem_source.prefixes[0].raw_dw)
                    `uvm_error("CLONE_PREFIX_MUTATION",
                               "mutating clone Prefix changed the source Prefix")
            end
        end

        io_source = pcie_tl_io_tlp::type_id::create("clone_io_source");
        io_source.addr = 32'h1234_5678;
        io_source.first_be = 4'h6;
        cloned_object = io_source.clone();
        if (!$cast(io_clone, cloned_object) ||
            io_clone.addr !== 32'h1234_5678 || io_clone.first_be !== 4'h6)
            `uvm_error("CLONE_IO", "IO clone lost addr/first_be")

        cfg_source = pcie_tl_cfg_tlp::type_id::create("clone_cfg_source");
        cfg_source.completer_id = 16'h4567;
        cfg_source.reg_num = 10'h2ab;
        cfg_source.first_be = 4'hc;
        cloned_object = cfg_source.clone();
        if (!$cast(cfg_clone, cloned_object) ||
            cfg_clone.completer_id !== 16'h4567 ||
            cfg_clone.reg_num !== 10'h2ab || cfg_clone.first_be !== 4'hc)
            `uvm_error("CLONE_CFG", "Config clone lost target/register/first_be")

        msg_source = pcie_tl_msg_tlp::type_id::create("clone_msg_source");
        msg_source.msg_code = MSG_ERR_NONFATAL;
        msg_source.msg_addr = 64'h0123_4567_89ab_cdef;
        msg_source.target_id = 16'h89ab;
        cloned_object = msg_source.clone();
        if (!$cast(msg_clone, cloned_object) ||
            msg_clone.msg_code !== MSG_ERR_NONFATAL ||
            msg_clone.msg_addr !== 64'h0123_4567_89ab_cdef ||
            msg_clone.target_id !== 16'h89ab)
            `uvm_error("CLONE_MSG", "Message clone lost code/address/target")

        vendor_source = pcie_tl_vendor_tlp::type_id::create(
            "clone_vendor_source");
        vendor_source.vendor_id = 16'h1af4;
        vendor_source.vendor_data = new[3];
        vendor_source.vendor_data[0] = 8'h12;
        vendor_source.vendor_data[1] = 8'h34;
        vendor_source.vendor_data[2] = 8'h56;
        cloned_object = vendor_source.clone();
        if (!$cast(vendor_clone, cloned_object) ||
            vendor_clone.vendor_id !== 16'h1af4 ||
            vendor_clone.vendor_data.size() != 3 ||
            {vendor_clone.vendor_data[0], vendor_clone.vendor_data[1],
             vendor_clone.vendor_data[2]} !== 24'h123456)
            `uvm_error("CLONE_VENDOR", "Vendor clone lost ID/data")
        else begin
            vendor_clone.vendor_data[0] = 8'hff;
            if (vendor_source.vendor_data[0] !== 8'h12)
                `uvm_error("CLONE_VENDOR_ALIAS",
                           "mutating clone Vendor data changed the source")
        end

        ltr_source = pcie_tl_ltr_tlp::type_id::create("clone_ltr_source");
        ltr_source.snoop_latency_value = 10'h155;
        ltr_source.snoop_latency_scale = 3'h5;
        ltr_source.snoop_requirement = 1;
        ltr_source.no_snoop_latency_value = 10'h2aa;
        ltr_source.no_snoop_latency_scale = 3'h3;
        ltr_source.no_snoop_requirement = 1;
        cloned_object = ltr_source.clone();
        if (!$cast(ltr_clone, cloned_object) ||
            ltr_clone.snoop_latency_value !== 10'h155 ||
            ltr_clone.snoop_latency_scale !== 3'h5 ||
            ltr_clone.snoop_requirement !== 1'b1 ||
            ltr_clone.no_snoop_latency_value !== 10'h2aa ||
            ltr_clone.no_snoop_latency_scale !== 3'h3 ||
            ltr_clone.no_snoop_requirement !== 1'b1)
            `uvm_error("CLONE_LTR", "LTR clone lost latency fields")
    endfunction
endclass
