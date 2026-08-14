class pcie_svt_peer_smoke_vseq extends uvm_sequence #(uvm_sequence_item);
  `uvm_object_utils(pcie_svt_peer_smoke_vseq)
  `uvm_declare_p_sequencer(pcie_svt_virtual_sequencer)

  function new(string name = "pcie_svt_peer_smoke_vseq");
    super.new(name);
  endfunction

  virtual task body();
    pcie_svt_all_cfg_spaces_init_vseq cfg_init;
    pcie_svt_all_links_bringup_vseq link_bringup;

    cfg_init = pcie_svt_all_cfg_spaces_init_vseq::type_id::create("cfg_init");
    link_bringup =
      pcie_svt_all_links_bringup_vseq::type_id::create("link_bringup");
    if ((cfg_init == null) || (link_bringup == null))
      `uvm_fatal("PEER_SMOKE", "peer smoke child sequence creation failed")

    cfg_init.start(p_sequencer);
    link_bringup.start(p_sequencer);
  endtask
endclass
