class pcie_svt_tlp_metadata extends uvm_object;
  `uvm_object_utils(pcie_svt_tlp_metadata)

  bit source_was_dmem;
  bit [3:0] cfg_last_dw_be;
  bit ln;
  svt_pcie_tlp::ph_enum ph;
  bit [15:0] st;
  int num_local_tlp_prefixes;
  int num_end_to_end_tlp_prefixes;

  function new(string name = "pcie_svt_tlp_metadata");
    super.new(name);
    ph = svt_pcie_tlp::BIDIRECTIONAL;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_svt_tlp_metadata rhs_;
    super.do_copy(rhs);
    if (!$cast(rhs_, rhs))
      return;
    source_was_dmem           = rhs_.source_was_dmem;
    cfg_last_dw_be            = rhs_.cfg_last_dw_be;
    ln                        = rhs_.ln;
    ph                        = rhs_.ph;
    st                        = rhs_.st;
    num_local_tlp_prefixes    = rhs_.num_local_tlp_prefixes;
    num_end_to_end_tlp_prefixes = rhs_.num_end_to_end_tlp_prefixes;
  endfunction
endclass

class pcie_svt_mem_tlp extends pcie_tl_mem_tlp;
  `uvm_object_utils(pcie_svt_mem_tlp)

  pcie_svt_tlp_metadata metadata;

  function new(string name = "pcie_svt_mem_tlp");
    super.new(name);
    metadata = new("metadata");
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_svt_mem_tlp rhs_;
    super.do_copy(rhs);
    if (!$cast(rhs_, rhs))
      return;
    at = rhs_.at;
    if (rhs_.metadata == null) begin
      metadata = null;
    end else begin
      if (metadata == null)
        metadata = new("metadata");
      metadata.copy(rhs_.metadata);
    end
  endfunction
endclass

class pcie_svt_cfg_tlp extends pcie_tl_cfg_tlp;
  `uvm_object_utils(pcie_svt_cfg_tlp)

  pcie_svt_tlp_metadata metadata;

  function new(string name = "pcie_svt_cfg_tlp");
    super.new(name);
    metadata = new("metadata");
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_svt_cfg_tlp rhs_;
    super.do_copy(rhs);
    if (!$cast(rhs_, rhs))
      return;
    at           = rhs_.at;
    completer_id = rhs_.completer_id;
    reg_num      = rhs_.reg_num;
    first_be     = rhs_.first_be;
    if (rhs_.metadata == null) begin
      metadata = null;
    end else begin
      if (metadata == null)
        metadata = new("metadata");
      metadata.copy(rhs_.metadata);
    end
  endfunction
endclass

class pcie_svt_cpl_tlp extends pcie_tl_cpl_tlp;
  `uvm_object_utils(pcie_svt_cpl_tlp)

  pcie_svt_tlp_metadata metadata;

  function new(string name = "pcie_svt_cpl_tlp");
    super.new(name);
    metadata = new("metadata");
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_svt_cpl_tlp rhs_;
    super.do_copy(rhs);
    if (!$cast(rhs_, rhs))
      return;
    at = rhs_.at;
    if (rhs_.metadata == null) begin
      metadata = null;
    end else begin
      if (metadata == null)
        metadata = new("metadata");
      metadata.copy(rhs_.metadata);
    end
  endfunction
endclass

class pcie_svt_tlp_converter;

  static function bit svt_fmt_to_normalized(
      svt_pcie_tlp::fmt_enum svt_fmt, output tlp_fmt_e normalized_fmt);
    case (svt_fmt)
      svt_pcie_tlp::NO_DATA_3_DWORD: begin
        normalized_fmt = FMT_3DW_NO_DATA;
        return 1'b1;
      end
      svt_pcie_tlp::NO_DATA_4_DWORD: begin
        normalized_fmt = FMT_4DW_NO_DATA;
        return 1'b1;
      end
      svt_pcie_tlp::WITH_DATA_3_DWORD: begin
        normalized_fmt = FMT_3DW_WITH_DATA;
        return 1'b1;
      end
      svt_pcie_tlp::WITH_DATA_4_DWORD: begin
        normalized_fmt = FMT_4DW_WITH_DATA;
        return 1'b1;
      end
      default: return 1'b0;
    endcase
  endfunction

  static function bit normalized_fmt_to_svt(
      tlp_fmt_e normalized_fmt, output svt_pcie_tlp::fmt_enum svt_fmt);
    case (normalized_fmt)
      FMT_3DW_NO_DATA: begin
        svt_fmt = svt_pcie_tlp::NO_DATA_3_DWORD;
        return 1'b1;
      end
      FMT_4DW_NO_DATA: begin
        svt_fmt = svt_pcie_tlp::NO_DATA_4_DWORD;
        return 1'b1;
      end
      FMT_3DW_WITH_DATA: begin
        svt_fmt = svt_pcie_tlp::WITH_DATA_3_DWORD;
        return 1'b1;
      end
      FMT_4DW_WITH_DATA: begin
        svt_fmt = svt_pcie_tlp::WITH_DATA_4_DWORD;
        return 1'b1;
      end
      default: return 1'b0;
    endcase
  endfunction

  static function bit svt_status_to_normalized(
      svt_pcie_tlp::completion_status_enum svt_status,
      output cpl_status_e normalized_status);
    case (svt_status)
      svt_pcie_tlp::SUCCESSFUL: begin
        normalized_status = CPL_STATUS_SC;
        return 1'b1;
      end
      svt_pcie_tlp::UNSUPPORTED_REQ: begin
        normalized_status = CPL_STATUS_UR;
        return 1'b1;
      end
      svt_pcie_tlp::CONFIG_RETRY: begin
        normalized_status = CPL_STATUS_CRS;
        return 1'b1;
      end
      svt_pcie_tlp::COMPLETER_ABORT: begin
        normalized_status = CPL_STATUS_CA;
        return 1'b1;
      end
      default: return 1'b0;
    endcase
  endfunction

  static function bit normalized_status_to_svt(
      cpl_status_e normalized_status,
      output svt_pcie_tlp::completion_status_enum svt_status);
    case (normalized_status)
      CPL_STATUS_SC: begin
        svt_status = svt_pcie_tlp::SUCCESSFUL;
        return 1'b1;
      end
      CPL_STATUS_UR: begin
        svt_status = svt_pcie_tlp::UNSUPPORTED_REQ;
        return 1'b1;
      end
      CPL_STATUS_CRS: begin
        svt_status = svt_pcie_tlp::CONFIG_RETRY;
        return 1'b1;
      end
      CPL_STATUS_CA: begin
        svt_status = svt_pcie_tlp::COMPLETER_ABORT;
        return 1'b1;
      end
      default: return 1'b0;
    endcase
  endfunction

  static function pcie_svt_tlp_metadata get_metadata(
      pcie_tl_tlp normalized);
    pcie_svt_mem_tlp mem_tlp;
    pcie_svt_cfg_tlp cfg_tlp;
    pcie_svt_cpl_tlp cpl_tlp;

    if ($cast(mem_tlp, normalized))
      return mem_tlp.metadata;
    if ($cast(cfg_tlp, normalized))
      return cfg_tlp.metadata;
    if ($cast(cpl_tlp, normalized))
      return cpl_tlp.metadata;
    return null;
  endfunction

  static function void copy_common_from_svt(
      svt_pcie_tlp source, pcie_tl_tlp normalized,
      pcie_svt_tlp_metadata metadata);
    pcie_tl_prefix prefix;

    normalized.tc           = source.traffic_class;
    normalized.th           = source.th;
    normalized.td           = source.td;
    normalized.ep_bit       = source.ep;
    normalized.attr[0]      = source.attr_relaxed_ordering;
    normalized.attr[1]      = source.attr_id_order;
    normalized.attr[2]      = source.attr_no_snoop;
    normalized.at           = source.at;
    normalized.length       = source.length;
    normalized.requester_id = source.requester_id;
    normalized.tag          = source.tag;
    normalized.prefixes.delete();
    foreach (source.tlp_prefixes[prefix_index]) begin
      prefix = new($sformatf("prefix_%0d", prefix_index));
      prefix.raw_dw = source.tlp_prefixes[prefix_index];
      prefix.prefix_type =
        tlp_prefix_type_e'(source.tlp_prefixes[prefix_index][31:24]);
      normalized.prefixes.push_back(prefix);
    end
    normalized.has_prefix = (source.tlp_prefixes.size() != 0);
    normalized.payload      = new[source.payload.size() * 4];
    foreach (source.payload[dword_index])
      for (int unsigned byte_index = 0; byte_index < 4; byte_index++)
        normalized.payload[dword_index * 4 + byte_index] =
          source.payload[dword_index][8 * byte_index +: 8];
    metadata.ln = source.ln;
    metadata.ph = source.ph;
    metadata.st = source.st;
    metadata.num_local_tlp_prefixes = source.num_local_tlp_prefixes;
    metadata.num_end_to_end_tlp_prefixes =
      source.num_end_to_end_tlp_prefixes;
  endfunction

  static function void copy_common_to_svt(
      pcie_tl_tlp normalized, svt_pcie_tlp round_trip,
      pcie_svt_tlp_metadata metadata);
    int num_local_tlp_prefixes;
    int num_end_to_end_tlp_prefixes;

    round_trip.traffic_class         = normalized.tc;
    round_trip.th                    = normalized.th;
    round_trip.td                    = normalized.td;
    round_trip.ep                    = normalized.ep_bit;
    round_trip.attr_relaxed_ordering = normalized.attr[0];
    round_trip.attr_id_order         = normalized.attr[1];
    round_trip.attr_no_snoop         = normalized.attr[2];
    round_trip.at = svt_pcie_tlp::at_enum'(normalized.at);
    round_trip.length                = normalized.length;
    round_trip.requester_id          = normalized.requester_id;
    round_trip.tag                   = normalized.tag;
    round_trip.tlp_prefixes.delete();
    num_local_tlp_prefixes = 0;
    num_end_to_end_tlp_prefixes = 0;
    foreach (normalized.prefixes[prefix_index]) begin
      round_trip.tlp_prefixes.push_back(
        normalized.prefixes[prefix_index].raw_dw);
      if (normalized.prefixes[prefix_index].is_local())
        num_local_tlp_prefixes++;
      else
        num_end_to_end_tlp_prefixes++;
    end
    if (metadata == null) begin
      round_trip.ln = 1'b0;
      round_trip.ph = svt_pcie_tlp::BIDIRECTIONAL;
      round_trip.st = 16'h0000;
      round_trip.num_local_tlp_prefixes = num_local_tlp_prefixes;
      round_trip.num_end_to_end_tlp_prefixes =
        num_end_to_end_tlp_prefixes;
    end else begin
      round_trip.ln = metadata.ln;
      round_trip.ph = metadata.ph;
      round_trip.st = metadata.st;
      round_trip.num_local_tlp_prefixes =
        metadata.num_local_tlp_prefixes;
      round_trip.num_end_to_end_tlp_prefixes =
        metadata.num_end_to_end_tlp_prefixes;
    end
    round_trip.payload = new[normalized.payload.size() / 4];
    foreach (round_trip.payload[dword_index]) begin
      round_trip.payload[dword_index] = '0;
      for (int unsigned byte_index = 0; byte_index < 4; byte_index++)
        round_trip.payload[dword_index][8 * byte_index +: 8] =
          normalized.payload[dword_index * 4 + byte_index];
    end
  endfunction

  static function bit from_svt(
      input svt_pcie_tlp source,
      output pcie_tl_tlp normalized,
      output string reason);
    tlp_fmt_e normalized_fmt;
    tlp_kind_e normalized_kind;
    tlp_type_e normalized_type;
    pcie_svt_mem_tlp mem_tlp;
    pcie_svt_cfg_tlp cfg_tlp;
    pcie_svt_cpl_tlp cpl_tlp;
    cpl_status_e normalized_status;

    normalized = null;
    reason = "";
    if (source == null) begin
      reason = "from_svt received a null SVT TLP";
      return 1'b0;
    end
    if (!svt_fmt_to_normalized(source.fmt, normalized_fmt)) begin
      reason = $sformatf("unsupported SVT Fmt value %0d", source.fmt);
      return 1'b0;
    end
    if ((source.fmt inside {svt_pcie_tlp::NO_DATA_3_DWORD,
                            svt_pcie_tlp::NO_DATA_4_DWORD}) &&
        (source.payload.size() != 0)) begin
      reason = "no-data SVT Fmt cannot carry payload data";
      return 1'b0;
    end
    if (source.tlp_type inside {svt_pcie_tlp::MEM_REQ,
                                svt_pcie_tlp::DMEM_REQ}) begin
      if (source.address[1:0] != 2'b00) begin
        reason = "SVT Memory address is not DWORD aligned";
        return 1'b0;
      end
      if ((source.fmt inside {svt_pcie_tlp::NO_DATA_3_DWORD,
                              svt_pcie_tlp::WITH_DATA_3_DWORD}) &&
          (source.address[63:32] != 32'h0000_0000)) begin
        reason = "3-DWORD SVT Memory address exceeds 32 bits";
        return 1'b0;
      end
    end

    case (source.tlp_type)
      svt_pcie_tlp::MEM_REQ: begin
        case (source.fmt)
          svt_pcie_tlp::NO_DATA_3_DWORD,
          svt_pcie_tlp::NO_DATA_4_DWORD: normalized_kind = TLP_MEM_RD;
          svt_pcie_tlp::WITH_DATA_3_DWORD,
          svt_pcie_tlp::WITH_DATA_4_DWORD: normalized_kind = TLP_MEM_WR;
          default: begin
            reason = "unsupported MEM_REQ Fmt";
            return 1'b0;
          end
        endcase
        normalized_type = TLP_TYPE_MEM_RD;
        mem_tlp = new("normalized_mem_tlp");
        normalized = mem_tlp;
        mem_tlp.addr      = source.address;
        mem_tlp.first_be  = source.first_dw_be;
        mem_tlp.last_be   = source.last_dw_be;
        mem_tlp.is_64bit  = (source.fmt inside {
          svt_pcie_tlp::NO_DATA_4_DWORD,
          svt_pcie_tlp::WITH_DATA_4_DWORD});
      end
      svt_pcie_tlp::DMEM_REQ: begin
        if (!(source.fmt inside {svt_pcie_tlp::WITH_DATA_3_DWORD,
                                 svt_pcie_tlp::WITH_DATA_4_DWORD})) begin
          reason = "DMEM_REQ is supported only with a data Fmt";
          return 1'b0;
        end
        normalized_kind = TLP_MEM_WR;
        normalized_type = TLP_TYPE_MEM_RD;
        mem_tlp = new("normalized_dmem_tlp");
        normalized = mem_tlp;
        mem_tlp.metadata.source_was_dmem = 1'b1;
        mem_tlp.addr      = source.address;
        mem_tlp.first_be  = source.first_dw_be;
        mem_tlp.last_be   = source.last_dw_be;
        mem_tlp.is_64bit  =
          (source.fmt == svt_pcie_tlp::WITH_DATA_4_DWORD);
      end
      svt_pcie_tlp::TYPE_0_CFG_REQ,
      svt_pcie_tlp::TYPE_1_CFG_REQ: begin
        if (!(source.fmt inside {svt_pcie_tlp::NO_DATA_3_DWORD,
                                 svt_pcie_tlp::WITH_DATA_3_DWORD})) begin
          reason = "Configuration requests require a 3-DWORD Fmt";
          return 1'b0;
        end
        if (source.tlp_type == svt_pcie_tlp::TYPE_0_CFG_REQ) begin
          normalized_kind = (source.fmt == svt_pcie_tlp::NO_DATA_3_DWORD) ?
                            TLP_CFG_RD0 : TLP_CFG_WR0;
          normalized_type = TLP_TYPE_CFG_RD0;
        end else begin
          normalized_kind = (source.fmt == svt_pcie_tlp::NO_DATA_3_DWORD) ?
                            TLP_CFG_RD1 : TLP_CFG_WR1;
          normalized_type = TLP_TYPE_CFG_RD1;
        end
        cfg_tlp = new("normalized_cfg_tlp");
        normalized = cfg_tlp;
        cfg_tlp.metadata.cfg_last_dw_be = source.last_dw_be;
        cfg_tlp.completer_id = {source.bus_number, source.device_number,
                                source.function_number};
        cfg_tlp.reg_num      = source.register_number;
        cfg_tlp.first_be     = source.first_dw_be;
      end
      svt_pcie_tlp::CPL: begin
        if (!(source.fmt inside {svt_pcie_tlp::NO_DATA_3_DWORD,
                                 svt_pcie_tlp::WITH_DATA_3_DWORD})) begin
          reason = "Completions require a 3-DWORD Fmt";
          return 1'b0;
        end
        if (!svt_status_to_normalized(source.completion_status,
                                      normalized_status)) begin
          reason = $sformatf("unsupported Completion Status %0d",
                             source.completion_status);
          return 1'b0;
        end
        normalized_kind = (source.fmt == svt_pcie_tlp::NO_DATA_3_DWORD) ?
                          TLP_CPL : TLP_CPLD;
        normalized_type = TLP_TYPE_CPL;
        cpl_tlp = new("normalized_cpl_tlp");
        normalized = cpl_tlp;
        cpl_tlp.completer_id = source.completer_id;
        cpl_tlp.cpl_status   = normalized_status;
        cpl_tlp.bcm          = source.byte_count_modified;
        cpl_tlp.byte_count   = source.byte_count;
        cpl_tlp.lower_addr   = source.lower_address;
      end
      default: begin
        reason = $sformatf("unsupported SVT TLP Type %0d", source.tlp_type);
        return 1'b0;
      end
    endcase

    normalized.kind   = normalized_kind;
    normalized.fmt    = normalized_fmt;
    normalized.type_f = normalized_type;
    copy_common_from_svt(source, normalized, get_metadata(normalized));
    return 1'b1;
  endfunction

  static function bit to_svt(
      input pcie_tl_tlp normalized,
      output svt_pcie_tlp round_trip,
      output string reason);
    pcie_tl_mem_tlp mem_tlp;
    pcie_tl_cfg_tlp cfg_tlp;
    pcie_tl_cpl_tlp cpl_tlp;
    svt_pcie_tlp::fmt_enum svt_fmt;
    svt_pcie_tlp::completion_status_enum svt_status;
    pcie_svt_tlp_metadata metadata;

    round_trip = null;
    reason = "";
    if (normalized == null) begin
      reason = "to_svt received a null normalized TLP";
      return 1'b0;
    end
    if (!normalized_fmt_to_svt(normalized.fmt, svt_fmt)) begin
      reason = $sformatf("unsupported normalized Fmt value %0d",
                         normalized.fmt);
      return 1'b0;
    end
    if ((normalized.payload.size() % 4) != 0) begin
      reason = "normalized payload size is not DWORD aligned";
      return 1'b0;
    end
    if (normalized.has_prefix != (normalized.prefixes.size() != 0)) begin
      reason = "normalized has_prefix does not match prefix queue";
      return 1'b0;
    end
    foreach (normalized.prefixes[prefix_index]) begin
      if (normalized.prefixes[prefix_index] == null) begin
        reason = $sformatf("normalized prefix %0d is null", prefix_index);
        return 1'b0;
      end
    end
    metadata = get_metadata(normalized);

    case (normalized.kind)
      TLP_MEM_RD: begin
        if ((normalized.type_f != TLP_TYPE_MEM_RD) ||
            !(normalized.fmt inside {FMT_3DW_NO_DATA, FMT_4DW_NO_DATA}) ||
            !$cast(mem_tlp, normalized)) begin
          reason = "invalid TLP_MEM_RD Fmt/Type/object tuple";
          return 1'b0;
        end
        if (normalized.payload.size() != 0) begin
          reason = "TLP_MEM_RD cannot carry payload data";
          return 1'b0;
        end
        if (mem_tlp.is_64bit != (normalized.fmt == FMT_4DW_NO_DATA)) begin
          reason = "TLP_MEM_RD address width does not match Fmt";
          return 1'b0;
        end
      end
      TLP_MEM_WR: begin
        if ((normalized.type_f != TLP_TYPE_MEM_RD) ||
            !(normalized.fmt inside {FMT_3DW_WITH_DATA,
                                     FMT_4DW_WITH_DATA}) ||
            !$cast(mem_tlp, normalized)) begin
          reason = "invalid TLP_MEM_WR Fmt/Type/object tuple";
          return 1'b0;
        end
        if (mem_tlp.is_64bit != (normalized.fmt == FMT_4DW_WITH_DATA)) begin
          reason = "TLP_MEM_WR address width does not match Fmt";
          return 1'b0;
        end
      end
      TLP_CFG_RD0, TLP_CFG_WR0, TLP_CFG_RD1, TLP_CFG_WR1: begin
        if (!$cast(cfg_tlp, normalized)) begin
          reason = "Configuration kind is not a pcie_tl_cfg_tlp object";
          return 1'b0;
        end
        if (((normalized.kind inside {TLP_CFG_RD0, TLP_CFG_RD1}) &&
             (normalized.fmt != FMT_3DW_NO_DATA)) ||
            ((normalized.kind inside {TLP_CFG_WR0, TLP_CFG_WR1}) &&
             (normalized.fmt != FMT_3DW_WITH_DATA)) ||
            ((normalized.kind inside {TLP_CFG_RD0, TLP_CFG_WR0}) &&
             (normalized.type_f != TLP_TYPE_CFG_RD0)) ||
            ((normalized.kind inside {TLP_CFG_RD1, TLP_CFG_WR1}) &&
             (normalized.type_f != TLP_TYPE_CFG_RD1))) begin
          reason = "invalid Configuration Fmt/Type/kind tuple";
          return 1'b0;
        end
        if ((normalized.kind inside {TLP_CFG_RD0, TLP_CFG_RD1}) &&
            (normalized.payload.size() != 0)) begin
          reason = "Configuration Read cannot carry payload data";
          return 1'b0;
        end
      end
      TLP_CPL, TLP_CPLD: begin
        if ((normalized.type_f != TLP_TYPE_CPL) ||
            (((normalized.kind == TLP_CPL) &&
              (normalized.fmt != FMT_3DW_NO_DATA)) ||
             ((normalized.kind == TLP_CPLD) &&
              (normalized.fmt != FMT_3DW_WITH_DATA))) ||
            !$cast(cpl_tlp, normalized)) begin
          reason = "invalid Completion Fmt/Type/object tuple";
          return 1'b0;
        end
        if ((normalized.kind == TLP_CPL) &&
            (normalized.payload.size() != 0)) begin
          reason = "TLP_CPL cannot carry payload data";
          return 1'b0;
        end
        if (!normalized_status_to_svt(cpl_tlp.cpl_status, svt_status)) begin
          reason = $sformatf("unsupported normalized Completion Status %0d",
                             cpl_tlp.cpl_status);
          return 1'b0;
        end
      end
      default: begin
        reason = $sformatf("unsupported normalized TLP kind %0d",
                           normalized.kind);
        return 1'b0;
      end
    endcase

    if (normalized.kind inside {TLP_MEM_RD, TLP_MEM_WR}) begin
      if (mem_tlp.addr[1:0] != 2'b00) begin
        reason = "normalized Memory address is not DWORD aligned";
        return 1'b0;
      end
      if ((normalized.fmt inside {FMT_3DW_NO_DATA, FMT_3DW_WITH_DATA}) &&
          (mem_tlp.addr[63:32] != 32'h0000_0000)) begin
        reason = "3-DWORD normalized Memory address exceeds 32 bits";
        return 1'b0;
      end
    end

    round_trip = new("round_trip_svt_tlp");
    round_trip.fmt = svt_fmt;
    case (normalized.kind)
      TLP_MEM_RD, TLP_MEM_WR: begin
        round_trip.tlp_type = ((normalized.kind == TLP_MEM_WR) &&
                               (metadata != null) &&
                               metadata.source_was_dmem) ?
                              svt_pcie_tlp::DMEM_REQ :
                              svt_pcie_tlp::MEM_REQ;
        round_trip.address     = mem_tlp.addr;
        round_trip.first_dw_be = mem_tlp.first_be;
        round_trip.last_dw_be  = mem_tlp.last_be;
      end
      TLP_CFG_RD0, TLP_CFG_WR0: begin
        round_trip.tlp_type        = svt_pcie_tlp::TYPE_0_CFG_REQ;
        round_trip.bus_number      = cfg_tlp.completer_id[15:8];
        round_trip.device_number   = cfg_tlp.completer_id[7:3];
        round_trip.function_number = cfg_tlp.completer_id[2:0];
        round_trip.register_number = cfg_tlp.reg_num;
        round_trip.first_dw_be     = cfg_tlp.first_be;
        round_trip.last_dw_be = (metadata == null) ?
                                4'h0 : metadata.cfg_last_dw_be;
      end
      TLP_CFG_RD1, TLP_CFG_WR1: begin
        round_trip.tlp_type        = svt_pcie_tlp::TYPE_1_CFG_REQ;
        round_trip.bus_number      = cfg_tlp.completer_id[15:8];
        round_trip.device_number   = cfg_tlp.completer_id[7:3];
        round_trip.function_number = cfg_tlp.completer_id[2:0];
        round_trip.register_number = cfg_tlp.reg_num;
        round_trip.first_dw_be     = cfg_tlp.first_be;
        round_trip.last_dw_be = (metadata == null) ?
                                4'h0 : metadata.cfg_last_dw_be;
      end
      TLP_CPL, TLP_CPLD: begin
        round_trip.tlp_type            = svt_pcie_tlp::CPL;
        round_trip.completer_id         = cpl_tlp.completer_id;
        round_trip.completion_status    = svt_status;
        round_trip.byte_count_modified  = cpl_tlp.bcm;
        round_trip.byte_count           = cpl_tlp.byte_count;
        round_trip.lower_address        = cpl_tlp.lower_addr;
      end
    endcase
    copy_common_to_svt(normalized, round_trip, metadata);
    return 1'b1;
  endfunction

endclass
