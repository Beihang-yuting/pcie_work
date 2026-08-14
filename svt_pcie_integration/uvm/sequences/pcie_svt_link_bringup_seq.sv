class pcie_svt_link_bringup_seq extends uvm_sequence #(uvm_sequence_item);
  string port_id;
  svt_pcie_device_virtual_sequencer port_seqr;

  `uvm_object_utils(pcie_svt_link_bringup_seq)

  function new(string name = "pcie_svt_link_bringup_seq");
    super.new(name);
  endfunction

  virtual task body();
    svt_pcie_dl_service_set_link_en_sequence link_en_seq;
    svt_pcie_pl_service_set_phy_en_sequence phy_en_seq;

    if ((port_seqr == null) || (port_seqr.pcie_virt_seqr == null) ||
        (port_seqr.pcie_virt_seqr.dl_seqr == null) ||
        (port_seqr.pcie_virt_seqr.pl_seqr == null))
      `uvm_fatal("LINK_EN", {port_id,
        ": null device/PCIe/DL/PL virtual sequencer hierarchy"})
    link_en_seq =
      svt_pcie_dl_service_set_link_en_sequence::type_id::create(
        {port_id, "_link_en"});
    phy_en_seq = svt_pcie_pl_service_set_phy_en_sequence::type_id::create(
      {port_id, "_phy_en"});
    if ((link_en_seq == null) || (phy_en_seq == null))
      `uvm_fatal("LINK_EN", {port_id,
        ": link/PHY enable sequence creation failed"})
    if (!link_en_seq.randomize() with { enable == 1'b1; })
      `uvm_fatal("LINK_EN", {port_id, ": randomization failed"})
    if (!phy_en_seq.randomize() with { phy_enable == 1'b1; })
      `uvm_fatal("PHY_EN", {port_id, ": randomization failed"})
    fork
      link_en_seq.start(port_seqr.pcie_virt_seqr.dl_seqr);
      phy_en_seq.start(port_seqr.pcie_virt_seqr.pl_seqr);
    join
    `uvm_info("LINK_ENABLE_DONE", $sformatf(
      "port=%s dl_enable=1 phy_enable=1", port_id), UVM_LOW)
  endtask
endclass
