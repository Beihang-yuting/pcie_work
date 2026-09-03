// Field-level conversion between the project TL TLPs and Synopsys SVT TLPs.
class pcie_svt_tlp_codec;
  static function automatic bit encode(pcie_tl_tlp tlp,
                                       output svt_pcie_tlp svt_tlp,
                                       input pcie_svt_route_info route);
    pcie_tl_mem_tlp mem; pcie_tl_cfg_tlp cfg; pcie_tl_cpl_tlp cpl;
    if (tlp == null) begin `uvm_error("PCIE_SVT_CODEC", "encode called with null TL TLP"); return 0; end
    svt_tlp = new("svt_encoded_tlp");
    svt_tlp.traffic_class = tlp.tc;
    svt_tlp.th = tlp.th; svt_tlp.td = tlp.td; svt_tlp.ep = tlp.ep_bit;
    svt_tlp.attr_relaxed_ordering = tlp.attr[0];
    svt_tlp.attr_id_order = tlp.attr[1]; svt_tlp.attr_no_snoop = tlp.attr[2];
    svt_tlp.at = svt_pcie_tlp::UNTRANSLATED;
    // SVT 仅暴露两种 AT；01 无法无损表示，明确拒绝避免静默丢失。
    if (tlp.at == 2'b01) begin `uvm_error("PCIE_SVT_CODEC", "AT=01 unsupported by SVT"); svt_tlp=null; return 0; end
    if (tlp.at == 2'b10) svt_tlp.at = svt_pcie_tlp::TRANSLATED;
    if (tlp.inject_ecrc_err || tlp.inject_lcrc_err || tlp.inject_poisoned || tlp.violate_ordering || tlp.field_bitmask != 0) begin
      `uvm_error("PCIE_SVT_CODEC", "TL error-injection metadata unsupported by SVT codec"); svt_tlp=null; return 0;
    end
    svt_tlp.length = tlp.length; svt_tlp.requester_id = tlp.requester_id;
    svt_tlp.tag = tlp.tag;
    if (route.requester_id != 0 && route.requester_id != tlp.requester_id) begin `uvm_error("PCIE_SVT_CODEC", $sformatf("route requester_id mismatch (app=%0d link=%0d)", route.application_id, route.link_id)); return 0; end
    if (route.requester_tag != 0 && route.requester_tag != tlp.tag) begin `uvm_error("PCIE_SVT_CODEC", "route requester tag mismatch"); return 0; end
    case (tlp.fmt)
      FMT_3DW_NO_DATA: svt_tlp.fmt = svt_pcie_tlp::NO_DATA_3_DWORD;
      FMT_4DW_NO_DATA: svt_tlp.fmt = svt_pcie_tlp::NO_DATA_4_DWORD;
      FMT_3DW_WITH_DATA: svt_tlp.fmt = svt_pcie_tlp::WITH_DATA_3_DWORD;
      FMT_4DW_WITH_DATA: svt_tlp.fmt = svt_pcie_tlp::WITH_DATA_4_DWORD;
      default: begin `uvm_error("PCIE_SVT_CODEC", "unsupported TL format"); svt_tlp = null; return 0; end
    endcase
    case (tlp.kind)
      TLP_MEM_RD, TLP_MEM_RD_LK, TLP_MEM_WR: begin
        if (!$cast(mem, tlp)) begin `uvm_error("PCIE_SVT_CODEC", "memory TLP cast failed"); return 0; end
        if ((tlp.kind == TLP_MEM_WR) != (tlp.fmt inside {FMT_3DW_WITH_DATA,FMT_4DW_WITH_DATA})) begin `uvm_error("PCIE_SVT_CODEC", "memory kind/format mismatch"); return 0; end
        svt_tlp.tlp_type = svt_pcie_tlp::MEM_REQ; svt_tlp.address = mem.addr; svt_tlp.ln = (tlp.kind == TLP_MEM_RD_LK);
        svt_tlp.first_dw_be = mem.first_be; svt_tlp.last_dw_be = mem.last_be;
      end
      TLP_CFG_RD0, TLP_CFG_WR0, TLP_CFG_RD1, TLP_CFG_WR1: begin
        if (!$cast(cfg, tlp)) begin `uvm_error("PCIE_SVT_CODEC", "config TLP cast failed"); return 0; end
        svt_tlp.tlp_type = (tlp.kind inside {TLP_CFG_RD0,TLP_CFG_WR0}) ? svt_pcie_tlp::TYPE_0_CFG_REQ : svt_pcie_tlp::TYPE_1_CFG_REQ;
        svt_tlp.completer_id = cfg.completer_id; svt_tlp.register_number = cfg.reg_num;
        svt_tlp.first_dw_be = cfg.first_be;
        if ((tlp.kind inside {TLP_CFG_WR0,TLP_CFG_WR1}) != (tlp.fmt == FMT_3DW_WITH_DATA)) begin `uvm_error("PCIE_SVT_CODEC", "config kind/format mismatch"); return 0; end
      end
      TLP_CPL, TLP_CPLD, TLP_CPL_LK, TLP_CPLD_LK: begin
        if (!$cast(cpl, tlp)) begin `uvm_error("PCIE_SVT_CODEC", "completion TLP cast failed"); return 0; end
        if (route.completer_id != 0 && route.completer_id != cpl.completer_id) begin `uvm_error("PCIE_SVT_CODEC", "route completer_id mismatch"); return 0; end
        if (route.completion_status != 0 && route.completion_status != cpl.cpl_status) begin `uvm_error("PCIE_SVT_CODEC", "route completion status mismatch"); return 0; end
        svt_tlp.tlp_type = svt_pcie_tlp::CPL; svt_tlp.completer_id = cpl.completer_id; svt_tlp.ln = (tlp.kind inside {TLP_CPL_LK,TLP_CPLD_LK});
        svt_tlp.completion_status = cpl.cpl_status; svt_tlp.byte_count_modified = cpl.bcm;
        svt_tlp.byte_count = cpl.byte_count; svt_tlp.lower_address = cpl.lower_addr;
      end
      default: begin `uvm_error("PCIE_SVT_CODEC", "unsupported TL transaction kind"); return 0; end
    endcase
    if ((tlp.payload.size() % 4) != 0) begin `uvm_error("PCIE_SVT_CODEC", "SVT payload requires whole DWORDs"); svt_tlp = null; return 0; end
    svt_tlp.payload = new[tlp.payload.size()/4];
    foreach (tlp.payload[i]) svt_tlp.payload[i/4][31-8*(i%4)-:8] = tlp.payload[i];
    return 1;
  endfunction

  static function automatic bit decode(svt_pcie_tlp svt_tlp,
                                       output pcie_tl_tlp tlp,
                                       input pcie_svt_route_info route);
    pcie_tl_mem_tlp mem; pcie_tl_cfg_tlp cfg; pcie_tl_cpl_tlp cpl;
    if (svt_tlp == null) begin `uvm_error("PCIE_SVT_CODEC", "decode called with null SVT TLP"); tlp = null; return 0; end
    if (route.requester_id != 0 && route.requester_id != svt_tlp.requester_id) begin `uvm_error("PCIE_SVT_CODEC", "decoded requester_id disagrees with route"); tlp = null; return 0; end
    if (route.requester_tag != 0 && route.requester_tag != svt_tlp.tag) begin `uvm_error("PCIE_SVT_CODEC", "decoded tag disagrees with route"); tlp = null; return 0; end
    if (route.completer_id != 0 && route.completer_id != svt_tlp.completer_id) begin `uvm_error("PCIE_SVT_CODEC", "decoded completer_id disagrees with route"); tlp = null; return 0; end
    if (route.completion_status != 0 && route.completion_status != svt_tlp.completion_status) begin `uvm_error("PCIE_SVT_CODEC", "decoded completion status disagrees with route"); tlp = null; return 0; end
    if (svt_tlp.tlp_type == svt_pcie_tlp::MEM_REQ) begin
      // 配置/完成请求必须使用 3DW；内存请求可使用 3DW 或 4DW。
      mem = new("tl_mem"); tlp = mem; mem.addr = svt_tlp.address; mem.first_be = svt_tlp.first_dw_be; mem.last_be = svt_tlp.last_dw_be;
      mem.kind = (svt_tlp.fmt inside {svt_pcie_tlp::WITH_DATA_3_DWORD,svt_pcie_tlp::WITH_DATA_4_DWORD}) ? TLP_MEM_WR : (svt_tlp.ln ? TLP_MEM_RD_LK : TLP_MEM_RD);
      mem.is_64bit = (svt_tlp.fmt inside {svt_pcie_tlp::NO_DATA_4_DWORD,svt_pcie_tlp::WITH_DATA_4_DWORD});
      // 写请求的 type_f 必须与 kind/fmt 同步；否则 TL driver 会把回解后的
      // Memory Write 误判成 Read，导致桥接后的请求方向丢失。
      if (svt_tlp.fmt inside {
            svt_pcie_tlp::WITH_DATA_3_DWORD,
            svt_pcie_tlp::WITH_DATA_4_DWORD})
        mem.type_f = TLP_TYPE_MEM_WR;
      else
        mem.type_f = svt_tlp.ln ? TLP_TYPE_MEM_RD_LK : TLP_TYPE_MEM_RD;
    end else if (svt_tlp.tlp_type inside {svt_pcie_tlp::TYPE_0_CFG_REQ,svt_pcie_tlp::TYPE_1_CFG_REQ}) begin
      if (!(svt_tlp.fmt inside {svt_pcie_tlp::NO_DATA_3_DWORD,svt_pcie_tlp::WITH_DATA_3_DWORD})) begin
        `uvm_error("PCIE_SVT_CODEC", "malformed config request format"); tlp = null; return 0;
      end
      cfg = new("tl_cfg"); tlp = cfg; cfg.completer_id = svt_tlp.completer_id; cfg.reg_num = svt_tlp.register_number; cfg.first_be = svt_tlp.first_dw_be;
      cfg.kind = (svt_tlp.tlp_type == svt_pcie_tlp::TYPE_0_CFG_REQ) ? ((svt_tlp.fmt == svt_pcie_tlp::WITH_DATA_3_DWORD) ? TLP_CFG_WR0 : TLP_CFG_RD0) : ((svt_tlp.fmt == svt_pcie_tlp::WITH_DATA_3_DWORD) ? TLP_CFG_WR1 : TLP_CFG_RD1);
      cfg.type_f = (svt_tlp.tlp_type == svt_pcie_tlp::TYPE_0_CFG_REQ) ? TLP_TYPE_CFG_RD0 : TLP_TYPE_CFG_RD1;
    end else if (svt_tlp.tlp_type == svt_pcie_tlp::CPL) begin
      if (!(svt_tlp.fmt inside {svt_pcie_tlp::NO_DATA_3_DWORD,svt_pcie_tlp::WITH_DATA_3_DWORD})) begin
        `uvm_error("PCIE_SVT_CODEC", "malformed completion format"); tlp = null; return 0;
      end
      cpl = new("tl_cpl"); tlp = cpl; cpl.completer_id = svt_tlp.completer_id; cpl.cpl_status = svt_tlp.completion_status; cpl.bcm = svt_tlp.byte_count_modified; cpl.byte_count = svt_tlp.byte_count; cpl.lower_addr = svt_tlp.lower_address; cpl.kind = (svt_tlp.fmt == svt_pcie_tlp::WITH_DATA_3_DWORD) ? (svt_tlp.ln ? TLP_CPLD_LK : TLP_CPLD) : (svt_tlp.ln ? TLP_CPL_LK : TLP_CPL); cpl.type_f = svt_tlp.ln ? TLP_TYPE_CPL_LK : TLP_TYPE_CPL;
    end else begin `uvm_error("PCIE_SVT_CODEC", "unsupported SVT transaction type"); tlp = null; return 0; end
    tlp.tc = svt_tlp.traffic_class; tlp.th = svt_tlp.th; tlp.td = svt_tlp.td; tlp.ep_bit = svt_tlp.ep; tlp.attr = {svt_tlp.attr_no_snoop,svt_tlp.attr_id_order,svt_tlp.attr_relaxed_ordering}; tlp.length = svt_tlp.length; tlp.requester_id = svt_tlp.requester_id; tlp.tag = svt_tlp.tag;
    case (svt_tlp.fmt)
      svt_pcie_tlp::NO_DATA_3_DWORD: tlp.fmt = FMT_3DW_NO_DATA;
      svt_pcie_tlp::NO_DATA_4_DWORD: tlp.fmt = FMT_4DW_NO_DATA;
      svt_pcie_tlp::WITH_DATA_3_DWORD: tlp.fmt = FMT_3DW_WITH_DATA;
      svt_pcie_tlp::WITH_DATA_4_DWORD: tlp.fmt = FMT_4DW_WITH_DATA;
      default: begin `uvm_error("PCIE_SVT_CODEC", "unsupported SVT format"); tlp = null; return 0; end
    endcase
    case (svt_tlp.at)
      svt_pcie_tlp::UNTRANSLATED: tlp.at = 2'b00;
      svt_pcie_tlp::TRANSLATED: tlp.at = 2'b10;
      default: begin `uvm_error("PCIE_SVT_CODEC", "unsupported SVT AT"); tlp = null; return 0; end
    endcase
    tlp.payload = new[svt_tlp.payload.size()*4]; foreach (tlp.payload[i]) tlp.payload[i] = svt_tlp.payload[i/4][31-8*(i%4)-:8];
    return 1;
  endfunction
endclass
