package pcie_svt_tlp_converter_unit_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import svt_uvm_pkg::*;
  import svt_pcie_uvm_pkg::*;
  import pcie_tl_switch_pkg::*;
  import pcie_svt_integration_pkg::*;

  class pcie_svt_tlp_converter_unit_test extends uvm_test;
    `uvm_component_utils(pcie_svt_tlp_converter_unit_test)

    function new(string name = "pcie_svt_tlp_converter_unit_test",
                 uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function automatic void require(bit condition, string message);
      if (!condition)
        `uvm_fatal("TLP_CONVERTER_TEST", message)
    endfunction

    function automatic bit [7:0] svt_payload_byte(svt_pcie_tlp tlp,
                                                   int unsigned index);
      return tlp.payload[index / 4][8 * (index % 4) +: 8];
    endfunction

    function automatic tlp_fmt_e expected_fmt(svt_pcie_tlp::fmt_enum fmt);
      case (fmt)
        svt_pcie_tlp::NO_DATA_3_DWORD:   return FMT_3DW_NO_DATA;
        svt_pcie_tlp::NO_DATA_4_DWORD:   return FMT_4DW_NO_DATA;
        svt_pcie_tlp::WITH_DATA_3_DWORD: return FMT_3DW_WITH_DATA;
        svt_pcie_tlp::WITH_DATA_4_DWORD: return FMT_4DW_WITH_DATA;
        default:                         return FMT_TLP_PREFIX;
      endcase
    endfunction

    function automatic tlp_kind_e expected_kind(int unsigned index);
      case (index)
        0: return TLP_MEM_RD;
        1: return TLP_MEM_WR;
        2: return TLP_CFG_RD0;
        3: return TLP_CFG_WR0;
        4: return TLP_CFG_RD1;
        5: return TLP_CFG_WR1;
        6: return TLP_CPL;
        7: return TLP_CPLD;
        default: return TLP_VENDOR_MSG;
      endcase
    endfunction

    function automatic tlp_type_e expected_type(tlp_kind_e kind);
      case (kind)
        TLP_MEM_RD, TLP_MEM_WR: return TLP_TYPE_MEM_RD;
        TLP_CFG_RD0, TLP_CFG_WR0: return TLP_TYPE_CFG_RD0;
        TLP_CFG_RD1, TLP_CFG_WR1: return TLP_TYPE_CFG_RD1;
        TLP_CPL, TLP_CPLD: return TLP_TYPE_CPL;
        default: return TLP_TYPE_VENDOR_MSG;
      endcase
    endfunction

    function automatic svt_pcie_tlp make_vector(int unsigned index);
      svt_pcie_tlp source;
      source = new($sformatf("source_%0d", index));
      source.traffic_class        = ((index % 7) + 1);
      source.attr_relaxed_ordering = 1'b1;
      source.attr_id_order         = 1'b1;
      source.attr_no_snoop         = 1'b1;
      source.th                    = 1'b1;
      source.td                    = 1'b1;
      source.ep                    = 1'b1;
      source.at                    = svt_pcie_tlp::TRANSLATED;
      source.requester_id          = 16'h8100 + index;
      source.tag                   = 10'h280 + index;
      source.payload               = new[0];

      case (index)
        0: begin
          source.tlp_type    = svt_pcie_tlp::MEM_REQ;
          source.fmt         = svt_pcie_tlp::NO_DATA_4_DWORD;
          source.address     = 64'h0000_0001_2345_6080;
          source.length      = 10'd3;
          source.first_dw_be = 4'h7;
          source.last_dw_be  = 4'he;
        end
        1: begin
          source.tlp_type    = svt_pcie_tlp::MEM_REQ;
          source.fmt         = svt_pcie_tlp::WITH_DATA_3_DWORD;
          source.address     = 64'h0000_0000_3456_7040;
          source.length      = 10'd2;
          source.first_dw_be = 4'hd;
          source.last_dw_be  = 4'hb;
          source.payload     = new[2];
          source.payload[0]  = 32'h4433_2211;
          source.payload[1]  = 32'h8877_6655;
        end
        2, 3, 4, 5: begin
          source.tlp_type = (index < 4) ? svt_pcie_tlp::TYPE_0_CFG_REQ :
                                          svt_pcie_tlp::TYPE_1_CFG_REQ;
          source.fmt = ((index == 3) || (index == 5)) ?
                       svt_pcie_tlp::WITH_DATA_3_DWORD :
                       svt_pcie_tlp::NO_DATA_3_DWORD;
          source.length          = 10'd1;
          source.first_dw_be     = 4'h6;
          source.last_dw_be      = 4'h0;
          source.bus_number      = 8'h40 + index;
          source.device_number   = 5'h10 + index;
          source.function_number = index[2:0];
          source.register_number = 10'h120 + index;
          if ((index == 3) || (index == 5)) begin
            source.payload = new[1];
            source.payload[0] = 32'ha500_1000 + index;
          end
        end
        6, 7: begin
          source.tlp_type            = svt_pcie_tlp::CPL;
          source.fmt = (index == 7) ? svt_pcie_tlp::WITH_DATA_3_DWORD :
                                      svt_pcie_tlp::NO_DATA_3_DWORD;
          source.length              = (index == 7) ? 10'd2 : 10'd1;
          source.completer_id         = 16'hc100 + index;
          source.completion_status    = svt_pcie_tlp::COMPLETER_ABORT;
          source.byte_count_modified  = 1'b1;
          source.byte_count           = 12'h125 + index;
          source.lower_address        = 7'h31 + index;
          if (index == 7) begin
            source.payload = new[2];
            source.payload[0] = 32'hd4c3_b2a1;
            source.payload[1] = 32'h1807_f6e5;
          end
        end
      endcase
      return source;
    endfunction

    function automatic void check_normalized_common(
        svt_pcie_tlp source, pcie_tl_tlp normalized,
        tlp_kind_e kind, string label_name);
      require(normalized != null, {label_name, ": null normalized object"});
      require(normalized.kind == kind, {label_name, ": kind mismatch"});
      require(normalized.fmt == expected_fmt(source.fmt),
              {label_name, ": fmt mismatch"});
      require(normalized.type_f == expected_type(kind),
              {label_name, ": Type mismatch"});
      require(normalized.tc == source.traffic_class,
              {label_name, ": traffic class mismatch"});
      require(normalized.attr[0] == source.attr_relaxed_ordering,
              {label_name, ": relaxed-ordering mismatch"});
      require(normalized.attr[1] == source.attr_id_order,
              {label_name, ": ID-ordering mismatch"});
      require(normalized.attr[2] == source.attr_no_snoop,
              {label_name, ": no-snoop mismatch"});
      require(normalized.th == source.th, {label_name, ": TH mismatch"});
      require(normalized.td == source.td, {label_name, ": TD mismatch"});
      require(normalized.ep_bit == source.ep, {label_name, ": EP mismatch"});
      require(normalized.at == source.at, {label_name, ": AT mismatch"});
      require(normalized.length == source.length,
              {label_name, ": length mismatch"});
      require(normalized.requester_id == source.requester_id,
              {label_name, ": Requester ID mismatch"});
      require(normalized.tag == source.tag,
              {label_name, ": 10-bit Tag mismatch"});
      require(normalized.payload.size() == source.payload.size() * 4,
              {label_name, ": payload byte count mismatch"});
      foreach (normalized.payload[byte_index])
        require(normalized.payload[byte_index] ==
                svt_payload_byte(source, byte_index),
                $sformatf("%s: payload byte %0d mismatch", label_name,
                          byte_index));
    endfunction

    function automatic void check_normalized_specific(
        int unsigned index, svt_pcie_tlp source,
        pcie_tl_tlp normalized, string label_name);
      pcie_tl_mem_tlp mem_tlp;
      pcie_tl_cfg_tlp cfg_tlp;
      pcie_tl_cpl_tlp cpl_tlp;
      case (index)
        0, 1: begin
          require($cast(mem_tlp, normalized),
                  {label_name, ": not pcie_tl_mem_tlp"});
          require(mem_tlp.addr == source.address,
                  {label_name, ": address mismatch"});
          require(mem_tlp.first_be == source.first_dw_be,
                  {label_name, ": first BE mismatch"});
          require(mem_tlp.last_be == source.last_dw_be,
                  {label_name, ": last BE mismatch"});
          require(mem_tlp.is_64bit == (source.fmt inside {
                    svt_pcie_tlp::NO_DATA_4_DWORD,
                    svt_pcie_tlp::WITH_DATA_4_DWORD}),
                  {label_name, ": address width mismatch"});
        end
        2, 3, 4, 5: begin
          require($cast(cfg_tlp, normalized),
                  {label_name, ": not pcie_tl_cfg_tlp"});
          require(cfg_tlp.completer_id ==
                  {source.bus_number, source.device_number,
                   source.function_number},
                  {label_name, ": Completer ID mismatch"});
          require(cfg_tlp.reg_num == source.register_number,
                  {label_name, ": register number mismatch"});
          require(cfg_tlp.first_be == source.first_dw_be,
                  {label_name, ": first BE mismatch"});
        end
        6, 7: begin
          require($cast(cpl_tlp, normalized),
                  {label_name, ": not pcie_tl_cpl_tlp"});
          require(cpl_tlp.completer_id == source.completer_id,
                  {label_name, ": Completer ID mismatch"});
          require(cpl_tlp.cpl_status == CPL_STATUS_CA,
                  {label_name, ": Completion Status mismatch"});
          require(cpl_tlp.bcm == source.byte_count_modified,
                  {label_name, ": BCM mismatch"});
          require(cpl_tlp.byte_count == source.byte_count,
                  {label_name, ": Byte Count mismatch"});
          require(cpl_tlp.lower_addr == source.lower_address,
                  {label_name, ": Lower Address mismatch"});
        end
      endcase
    endfunction

    function automatic void check_round_trip(
        int unsigned index, svt_pcie_tlp expected,
        svt_pcie_tlp actual, string label_name);
      require(actual != null, {label_name, ": null round-trip object"});
      require(actual != expected, {label_name, ": source object was returned"});
      require(actual.tlp_type == expected.tlp_type,
              {label_name, ": round-trip Type mismatch"});
      require(actual.fmt == expected.fmt,
              {label_name, ": round-trip Fmt mismatch"});
      require(actual.traffic_class == expected.traffic_class,
              {label_name, ": round-trip TC mismatch"});
      require(actual.attr_relaxed_ordering == expected.attr_relaxed_ordering,
              {label_name, ": round-trip RO mismatch"});
      require(actual.attr_id_order == expected.attr_id_order,
              {label_name, ": round-trip IDO mismatch"});
      require(actual.attr_no_snoop == expected.attr_no_snoop,
              {label_name, ": round-trip NS mismatch"});
      require(actual.th == expected.th, {label_name, ": round-trip TH mismatch"});
      require(actual.td == expected.td, {label_name, ": round-trip TD mismatch"});
      require(actual.ep == expected.ep, {label_name, ": round-trip EP mismatch"});
      require(actual.at == expected.at, {label_name, ": round-trip AT mismatch"});
      require(actual.length == expected.length,
              {label_name, ": round-trip length mismatch"});
      require(actual.requester_id == expected.requester_id,
              {label_name, ": round-trip Requester ID mismatch"});
      require(actual.tag == expected.tag,
              {label_name, ": round-trip 10-bit Tag mismatch"});

      case (index)
        0, 1: begin
          require(actual.address == expected.address,
                  {label_name, ": round-trip address mismatch"});
          require(actual.first_dw_be == expected.first_dw_be,
                  {label_name, ": round-trip first BE mismatch"});
          require(actual.last_dw_be == expected.last_dw_be,
                  {label_name, ": round-trip last BE mismatch"});
        end
        2, 3, 4, 5: begin
          require(actual.bus_number == expected.bus_number,
                  {label_name, ": round-trip bus number mismatch"});
          require(actual.device_number == expected.device_number,
                  {label_name, ": round-trip device number mismatch"});
          require(actual.function_number == expected.function_number,
                  {label_name, ": round-trip function number mismatch"});
          require(actual.register_number == expected.register_number,
                  {label_name, ": round-trip register number mismatch"});
          require(actual.first_dw_be == expected.first_dw_be,
                  {label_name, ": round-trip first BE mismatch"});
        end
        6, 7: begin
          require(actual.completer_id == expected.completer_id,
                  {label_name, ": round-trip Completer ID mismatch"});
          require(actual.completion_status == expected.completion_status,
                  {label_name, ": round-trip Completion Status mismatch"});
          require(actual.byte_count_modified == expected.byte_count_modified,
                  {label_name, ": round-trip BCM mismatch"});
          require(actual.byte_count == expected.byte_count,
                  {label_name, ": round-trip Byte Count mismatch"});
          require(actual.lower_address == expected.lower_address,
                  {label_name, ": round-trip Lower Address mismatch"});
        end
      endcase

      require(actual.payload.size() == expected.payload.size(),
              {label_name, ": round-trip payload DWORD count mismatch"});
      for (int unsigned byte_index = 0;
           byte_index < expected.payload.size() * 4; byte_index++)
        require(svt_payload_byte(actual, byte_index) ==
                svt_payload_byte(expected, byte_index),
                $sformatf("%s: round-trip payload byte %0d mismatch",
                          label_name, byte_index));
    endfunction

    virtual task run_phase(uvm_phase phase);
      string labels[8] = '{"MEM_REQ/no-data", "MEM_REQ/data",
                           "TYPE_0_CFG_REQ/no-data", "TYPE_0_CFG_REQ/data",
                           "TYPE_1_CFG_REQ/no-data", "TYPE_1_CFG_REQ/data",
                           "CPL/no-data", "CPL/data"};
      pcie_tl_tlp normalized;
      svt_pcie_tlp source;
      svt_pcie_tlp round_trip;
      string reason;

      phase.raise_objection(this);
      for (int unsigned index = 0; index < 8; index++) begin
        source = make_vector(index);
        normalized = null;
        reason = "stale";
        require(pcie_svt_tlp_converter::from_svt(source, normalized, reason),
                {labels[index], ": from_svt failed: ", reason});
        require(reason == "", {labels[index], ": success reason not empty"});
        check_normalized_common(source, normalized,
                                expected_kind(index), labels[index]);
        check_normalized_specific(index, source, normalized, labels[index]);

        round_trip = null;
        reason = "stale";
        require(pcie_svt_tlp_converter::to_svt(normalized, round_trip, reason),
                {labels[index], ": to_svt failed: ", reason});
        require(reason == "", {labels[index], ": success reason not empty"});
        check_round_trip(index, source, round_trip, labels[index]);
      end

      source = make_vector(1);
      source.tlp_type = svt_pcie_tlp::DMEM_REQ;
      require(pcie_svt_tlp_converter::from_svt(source, normalized, reason),
              {"DMEM_REQ/data alias was rejected: ", reason});
      require(normalized.kind == TLP_MEM_WR,
              "DMEM_REQ/data alias did not normalize to TLP_MEM_WR");

      source = new("unsupported_message");
      source.tlp_type = svt_pcie_tlp::MSG_REQ_TO_ROOT;
      source.fmt = svt_pcie_tlp::NO_DATA_4_DWORD;
      normalized = null;
      reason = "";
      require(!pcie_svt_tlp_converter::from_svt(source, normalized, reason),
              "Message TLP was silently accepted by from_svt");
      require(reason != "", "Message TLP from_svt rejection had no reason");
      require(normalized == null,
              "Message TLP from_svt rejection returned an object");

      begin
        pcie_tl_msg_tlp message_tlp;
        message_tlp = new("unsupported_normalized_message");
        message_tlp.kind = TLP_MSG;
        message_tlp.fmt = FMT_4DW_NO_DATA;
        message_tlp.type_f = TLP_TYPE_MSG_RC;
        round_trip = null;
        reason = "";
        require(!pcie_svt_tlp_converter::to_svt(message_tlp,
                                                round_trip, reason),
                "Message TLP was silently accepted by to_svt");
        require(reason != "", "Message TLP to_svt rejection had no reason");
        require(round_trip == null,
                "Message TLP to_svt rejection returned an object");
      end

      $display("TLP_CONVERTER_PASS");
      phase.drop_objection(this);
    endtask
  endclass
endpackage

module pcie_svt_tlp_converter_unit_top;
  import uvm_pkg::*;
  import pcie_svt_tlp_converter_unit_test_pkg::*;

  initial run_test("pcie_svt_tlp_converter_unit_test");
endmodule
