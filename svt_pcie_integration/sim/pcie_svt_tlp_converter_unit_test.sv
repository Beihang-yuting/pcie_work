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
      bit [2:0] attr_pattern;
      source = new($sformatf("source_%0d", index));
      source.traffic_class        = ((index % 7) + 1);
      case (index)
        0: attr_pattern = 3'b001;
        1: attr_pattern = 3'b010;
        2: attr_pattern = 3'b100;
        3: attr_pattern = 3'b011;
        4: attr_pattern = 3'b101;
        5: attr_pattern = 3'b110;
        6: attr_pattern = 3'b001;
        default: attr_pattern = 3'b100;
      endcase
      source.attr_relaxed_ordering = attr_pattern[0];
      source.attr_id_order         = attr_pattern[1];
      source.attr_no_snoop         = attr_pattern[2];
      source.th                    = 1'b1;
      source.td                    = 1'b1;
      source.ep                    = 1'b1;
      source.at                    = svt_pcie_tlp::TRANSLATED;
      source.requester_id          = 16'h8100 + index;
      source.tag                   = 10'h280 + index;
      source.payload               = new[0];
      source.tlp_prefixes.delete();
      source.num_local_tlp_prefixes = 0;
      source.num_end_to_end_tlp_prefixes = 0;
      source.ln = 1'b0;
      source.ph = svt_pcie_tlp::BIDIRECTIONAL;
      source.st = 16'h0000;

      case (index)
        0: begin
          source.tlp_type    = svt_pcie_tlp::MEM_REQ;
          source.fmt         = svt_pcie_tlp::NO_DATA_4_DWORD;
          source.address     = 64'h0000_0001_2345_6080;
          source.length      = 10'd3;
          source.first_dw_be = 4'h7;
          source.last_dw_be  = 4'he;
          source.tlp_prefixes.push_back(32'h8000_5a00);
          source.tlp_prefixes.push_back(32'h9100_1234);
          source.num_local_tlp_prefixes = 1;
          source.num_end_to_end_tlp_prefixes = 1;
          source.ln = 1'b1;
          source.ph = svt_pcie_tlp::TARGET;
          source.st = 16'ha55a;
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
          source.last_dw_be      = 4'h9;
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
      require(normalized.has_prefix == (source.tlp_prefixes.size() != 0),
              {label_name, ": has_prefix mismatch"});
      require(normalized.prefixes.size() == source.tlp_prefixes.size(),
              {label_name, ": prefix count mismatch"});
      foreach (source.tlp_prefixes[prefix_index]) begin
        require(normalized.prefixes[prefix_index] != null,
                $sformatf("%s: prefix %0d is null", label_name,
                          prefix_index));
        require(normalized.prefixes[prefix_index].raw_dw ==
                source.tlp_prefixes[prefix_index],
                $sformatf("%s: prefix %0d raw DWORD mismatch", label_name,
                          prefix_index));
      end
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
          if (index == 1) begin
            require(mem_tlp.payload[0] == 8'h11,
                    {label_name, ": address byte 0 is not 0x11"});
            require(mem_tlp.payload[1] == 8'h22,
                    {label_name, ": address byte 1 is not 0x22"});
            require(mem_tlp.payload[2] == 8'h33,
                    {label_name, ": address byte 2 is not 0x33"});
            require(mem_tlp.payload[3] == 8'h44,
                    {label_name, ": address byte 3 is not 0x44"});
            require(mem_tlp.payload[4] == 8'h55,
                    {label_name, ": address byte 4 is not 0x55"});
            require(mem_tlp.payload[5] == 8'h66,
                    {label_name, ": address byte 5 is not 0x66"});
            require(mem_tlp.payload[6] == 8'h77,
                    {label_name, ": address byte 6 is not 0x77"});
            require(mem_tlp.payload[7] == 8'h88,
                    {label_name, ": address byte 7 is not 0x88"});
          end
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
      require(actual.ln == expected.ln,
              {label_name, ": round-trip LN mismatch"});
      require(actual.ph == expected.ph,
              {label_name, ": round-trip PH mismatch"});
      require(actual.st == expected.st,
              {label_name, ": round-trip ST mismatch"});
      require(actual.num_local_tlp_prefixes ==
              expected.num_local_tlp_prefixes,
              {label_name, ": round-trip local prefix count mismatch"});
      require(actual.num_end_to_end_tlp_prefixes ==
              expected.num_end_to_end_tlp_prefixes,
              {label_name, ": round-trip E2E prefix count mismatch"});
      require(actual.tlp_prefixes.size() == expected.tlp_prefixes.size(),
              {label_name, ": round-trip prefix queue size mismatch"});
      foreach (expected.tlp_prefixes[prefix_index])
        require(actual.tlp_prefixes[prefix_index] ==
                expected.tlp_prefixes[prefix_index],
                $sformatf("%s: round-trip prefix %0d mismatch", label_name,
                          prefix_index));

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
          require(actual.last_dw_be == expected.last_dw_be,
                  {label_name, ": round-trip last BE mismatch"});
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
      pcie_tl_tlp cloned_normalized;
      pcie_tl_mem_tlp mem_tlp;
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

        require($cast(cloned_normalized, normalized.clone()),
                {labels[index], ": normalized clone failed"});
        round_trip = null;
        reason = "stale";
        require(pcie_svt_tlp_converter::to_svt(cloned_normalized,
                                               round_trip, reason),
                {labels[index], ": cloned to_svt failed: ", reason});
        require(reason == "",
                {labels[index], ": cloned success reason not empty"});
        check_round_trip(index, source, round_trip,
                         {labels[index], "/clone"});
        if (source.tlp_prefixes.size() != 0) begin
          require(cloned_normalized.prefixes[0] != normalized.prefixes[0],
                  {labels[index], ": clone aliased prefix handle"});
          cloned_normalized.prefixes[0].raw_dw =
            source.tlp_prefixes[0] ^ 32'h0000_0001;
          require(normalized.prefixes[0].raw_dw == source.tlp_prefixes[0],
                  {labels[index], ": clone prefix mutation changed original"});
          round_trip = new("stale_original_after_clone_mutation");
          reason = "stale";
          require(pcie_svt_tlp_converter::to_svt(normalized,
                                                 round_trip, reason),
                  {labels[index],
                   ": original to_svt after clone mutation failed: ",
                   reason});
          require(reason == "",
                  {labels[index],
                   ": original success reason after clone mutation not empty"});
          check_round_trip(index, source, round_trip,
                           {labels[index], "/original-after-clone-mutation"});
        end
      end

      source = make_vector(1);
      source.tlp_type = svt_pcie_tlp::DMEM_REQ;
      require(pcie_svt_tlp_converter::from_svt(source, normalized, reason),
              {"DMEM_REQ/data alias was rejected: ", reason});
      require(normalized.kind == TLP_MEM_WR,
              "DMEM_REQ/data alias did not normalize to TLP_MEM_WR");
      round_trip = null;
      reason = "stale";
      require(pcie_svt_tlp_converter::to_svt(normalized, round_trip, reason),
              {"DMEM_REQ/data to_svt failed: ", reason});
      require(round_trip.tlp_type == svt_pcie_tlp::DMEM_REQ,
              "DMEM_REQ/data silently changed to MEM_REQ");
      check_round_trip(1, source, round_trip, "DMEM_REQ/data");
      require($cast(cloned_normalized, normalized.clone()),
              "DMEM_REQ normalized clone failed");
      round_trip = null;
      reason = "stale";
      require(pcie_svt_tlp_converter::to_svt(cloned_normalized,
                                             round_trip, reason),
              {"DMEM_REQ cloned to_svt failed: ", reason});
      require(round_trip.tlp_type == svt_pcie_tlp::DMEM_REQ,
              "DMEM_REQ clone lost DMEM provenance");

      source = make_vector(0);
      source.payload = new[1];
      source.payload[0] = 32'hdead_beef;
      normalized = new("stale_no_data_payload");
      reason = "";
      require(!pcie_svt_tlp_converter::from_svt(source, normalized, reason),
              "no-data Fmt with payload was accepted by from_svt");
      require(normalized == null,
              "no-data payload rejection did not clear normalized output");
      require(reason != "", "no-data payload rejection had no reason");

      source = make_vector(1);
      source.address[1] = 1'b1;
      normalized = new("stale_unaligned_from");
      reason = "";
      require(!pcie_svt_tlp_converter::from_svt(source, normalized, reason),
              "unaligned SVT Memory address was accepted");
      require((normalized == null) && (reason != ""),
              "unaligned from_svt rejection contract failed");

      source = make_vector(1);
      source.address[63:32] = 32'h0000_0001;
      normalized = new("stale_high_3dw_from");
      reason = "";
      require(!pcie_svt_tlp_converter::from_svt(source, normalized, reason),
              "3DW SVT Memory address above 4GB was accepted");
      require((normalized == null) && (reason != ""),
              "3DW high-address from_svt rejection contract failed");

      source = make_vector(1);
      require(pcie_svt_tlp_converter::from_svt(source, normalized, reason),
              {"to_svt address setup failed: ", reason});
      require($cast(mem_tlp, normalized),
              "to_svt address setup did not produce Memory subtype");
      mem_tlp.addr[1] = 1'b1;
      round_trip = new("stale_unaligned_to");
      reason = "";
      require(!pcie_svt_tlp_converter::to_svt(normalized,
                                              round_trip, reason),
              "unaligned normalized Memory address was accepted");
      require((round_trip == null) && (reason != ""),
              "unaligned to_svt rejection contract failed");

      mem_tlp.addr[1] = 1'b0;
      mem_tlp.addr[63:32] = 32'h0000_0001;
      round_trip = new("stale_high_3dw_to");
      reason = "";
      require(!pcie_svt_tlp_converter::to_svt(normalized,
                                              round_trip, reason),
              "3DW normalized Memory address above 4GB was accepted");
      require((round_trip == null) && (reason != ""),
              "3DW high-address to_svt rejection contract failed");

      source = make_vector(1);
      require(pcie_svt_tlp_converter::from_svt(source, normalized, reason),
              {"has_prefix setup failed: ", reason});
      normalized.has_prefix = 1'b1;
      round_trip = new("stale_has_prefix_to");
      reason = "";
      require(!pcie_svt_tlp_converter::to_svt(normalized,
                                              round_trip, reason),
              "inconsistent normalized has_prefix was accepted");
      require((round_trip == null) && (reason != ""),
              "has_prefix rejection contract failed");

      begin
        pcie_tl_prefix null_prefix;
        source = make_vector(1);
        require(pcie_svt_tlp_converter::from_svt(source,
                                                 normalized, reason),
                {"null prefix setup failed: ", reason});
        normalized.prefixes.push_back(null_prefix);
        normalized.has_prefix = 1'b1;
        round_trip = new("stale_null_prefix_to");
        reason = "";
        require(!pcie_svt_tlp_converter::to_svt(normalized,
                                                round_trip, reason),
                "null normalized prefix handle was accepted");
        require((round_trip == null) && (reason != ""),
                "null prefix rejection contract failed");
      end

      begin
        pcie_tl_mem_tlp base_mem;
        svt_pcie_tlp stale_round_trip;
        base_mem = new("base_mem_without_svt_provenance");
        base_mem.kind = TLP_MEM_WR;
        base_mem.fmt = FMT_3DW_WITH_DATA;
        base_mem.type_f = TLP_TYPE_MEM_WR;
        base_mem.length = 10'd1;
        base_mem.requester_id = 16'h1200;
        base_mem.tag = 10'h155;
        base_mem.addr = 64'h0000_0000_1234_5000;
        base_mem.first_be = 4'hf;
        base_mem.last_be = 4'h0;
        base_mem.is_64bit = 1'b0;
        base_mem.payload = new[4];
        base_mem.payload[0] = 8'ha1;
        base_mem.payload[1] = 8'hb2;
        base_mem.payload[2] = 8'hc3;
        base_mem.payload[3] = 8'hd4;
        stale_round_trip = new("stale_base_mem_round_trip");
        round_trip = stale_round_trip;
        reason = "stale";
        require(pcie_svt_tlp_converter::to_svt(base_mem,
                                               round_trip, reason),
                {"base normalized Memory conversion failed: ", reason});
        require(reason == "",
                "base normalized Memory success reason not empty");
        require((round_trip != null) && (round_trip != stale_round_trip),
                "base normalized Memory did not replace stale output");
        require(round_trip.tlp_type == svt_pcie_tlp::MEM_REQ,
                "base normalized Memory Write was emitted as DMEM_REQ");
      end

      begin
        pcie_tl_cfg_tlp base_cfg;
        base_cfg = new("base_cfg_without_svt_provenance");
        base_cfg.kind = TLP_CFG_WR0;
        base_cfg.fmt = FMT_3DW_WITH_DATA;
        base_cfg.type_f = TLP_TYPE_CFG_WR0;
        base_cfg.length = 10'd1;
        base_cfg.requester_id = 16'h2200;
        base_cfg.tag = 10'h2aa;
        base_cfg.completer_id = 16'h3300;
        base_cfg.reg_num = 10'h155;
        base_cfg.first_be = 4'hf;
        base_cfg.payload = new[4];
        base_cfg.payload[0] = 8'h11;
        base_cfg.payload[1] = 8'h22;
        base_cfg.payload[2] = 8'h33;
        base_cfg.payload[3] = 8'h44;
        round_trip = null;
        reason = "stale";
        require(pcie_svt_tlp_converter::to_svt(base_cfg,
                                               round_trip, reason),
                {"base normalized Cfg conversion failed: ", reason});
        require(round_trip.last_dw_be == 4'h0,
                "base normalized Cfg did not default last_dw_be to zero");
      end

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
