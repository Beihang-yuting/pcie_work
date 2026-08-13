class pcie_svt_virtual_sequencer extends uvm_sequencer #(uvm_sequence_item);
  svt_pcie_device_virtual_sequencer port_seqr[PCIE_SVT_MAX_PORTS];
  svt_pcie_device_status port_status[PCIE_SVT_MAX_PORTS];
  pcie_svt_port_profile port_profile[PCIE_SVT_MAX_PORTS];
  bit active_port[PCIE_SVT_MAX_PORTS];

  `uvm_component_utils(pcie_svt_virtual_sequencer)

  function new(string name = "pcie_svt_virtual_sequencer",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass
