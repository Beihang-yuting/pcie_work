package pcie_svt_tlp_codec_unit_test_pkg;
  import uvm_pkg::*; `include "uvm_macros.svh"
  import pcie_tl_pkg::*; import pcie_svt_topology_pkg::*;
  class pcie_svt_tlp_codec_unit_test extends uvm_test;
    `uvm_component_utils(pcie_svt_tlp_codec_unit_test)
    function new(string name="pcie_svt_tlp_codec_unit_test", uvm_component parent=null); super.new(name,parent); endfunction
    task run_phase(uvm_phase phase);
      pcie_tl_cfg_tlp cfg; pcie_tl_mem_tlp mem; pcie_tl_cpl_tlp cpl; pcie_tl_tlp back; svt_pcie_tlp svt; pcie_svt_route_info r, rb;
      phase.raise_objection(this); r = pcie_svt_route_info_default(); r.application_id=32'h11; r.link_id=32'h22; r.root_index=32'h33; r.requester_id=16'h1234; r.requester_tag=10'h155;
      cfg = new("cfg"); cfg.kind=TLP_CFG_RD0; cfg.type_f=TLP_TYPE_CFG_RD0; cfg.fmt=FMT_3DW_NO_DATA; cfg.length=1; cfg.requester_id=16'h1234; cfg.tag=10'h155; cfg.completer_id=16'h5678; cfg.reg_num=10'h44; cfg.first_be=4'hf;
      if (!pcie_svt_tlp_codec::encode(cfg,svt,r) || !pcie_svt_tlp_codec::decode(svt,back,rb)) `uvm_fatal("CODEC","config round trip failed");
      if (back.fmt != FMT_3DW_NO_DATA || back.requester_id != cfg.requester_id || back.tag != cfg.tag) `uvm_fatal("CODEC","config fields mismatch");
      mem = new("mem"); mem.kind=TLP_MEM_WR; mem.type_f=TLP_TYPE_MEM_RD; mem.fmt=FMT_3DW_WITH_DATA; mem.length=2; mem.addr=64'h1000; mem.first_be=4'hf; mem.last_be=4'hf; mem.payload=new[8]; foreach(mem.payload[i]) mem.payload[i]=i;
      if (!pcie_svt_tlp_codec::encode(mem,svt,r) || !pcie_svt_tlp_codec::decode(svt,back,rb) || back.payload.size()!=8) `uvm_fatal("CODEC","memory round trip failed");
      if (back.fmt != FMT_3DW_WITH_DATA || back.kind != TLP_MEM_WR || back.payload[7] != 7) `uvm_fatal("CODEC","memory fields mismatch");
      cpl = new("cpl"); cpl.kind=TLP_CPLD; cpl.type_f=TLP_TYPE_CPL; cpl.fmt=FMT_3DW_WITH_DATA; cpl.length=1; cpl.completer_id=16'h9abc; cpl.cpl_status=CPL_STATUS_SC; cpl.payload=new[4]; cpl.payload='{8'hde,8'had,8'hbe,8'hef};
      if (!pcie_svt_tlp_codec::encode(cpl,svt,r) || !pcie_svt_tlp_codec::decode(svt,back,rb) || back.payload[0] != 8'hde) `uvm_fatal("CODEC","completion round trip failed");
      phase.drop_objection(this);
    endtask
  endclass
endpackage
