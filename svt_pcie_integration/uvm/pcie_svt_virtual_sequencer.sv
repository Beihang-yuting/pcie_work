class pcie_svt_virtual_sequencer extends uvm_sequencer #(uvm_sequence_item);
  svt_pcie_device_agent port_agent[PCIE_SVT_MAX_PORTS];
  svt_pcie_device_configuration port_cfg[PCIE_SVT_MAX_PORTS];
  svt_pcie_device_virtual_sequencer port_seqr[PCIE_SVT_MAX_PORTS];
  svt_pcie_device_status port_status[PCIE_SVT_MAX_PORTS];
  pcie_svt_port_profile port_profile[PCIE_SVT_MAX_PORTS];
  bit active_port[PCIE_SVT_MAX_PORTS];
  virtual pcie_svt_reset_if reset_vif;

  `uvm_component_utils(pcie_svt_virtual_sequencer)

  function new(string name = "pcie_svt_virtual_sequencer",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual pcie_svt_reset_if)::get(
          null, "uvm_test_top", "reset_vif", reset_vif) ||
        (reset_vif == null))
      `uvm_fatal("CFG_RESET", "missing or null reset_vif")
  endfunction
endclass
