class pcie_svt_real_switch_enumeration_vseq extends
    pcie_svt_switch_enumeration_base_vseq;
  `uvm_object_utils(pcie_svt_real_switch_enumeration_vseq)

  function new(string name = "pcie_svt_real_switch_enumeration_vseq");
    super.new(name);
  endfunction

  protected virtual function void report_success();
    `uvm_info("REAL_SWITCH_ENUM_PASS", $sformatf(
      "usp=%0d dsp=%0d ep=%0d bars=%0d",
      p_sequencer.switch_enum_registry.usp_count(),
      p_sequencer.switch_enum_registry.dsp_count(),
      p_sequencer.switch_enum_registry.ep_count(),
      p_sequencer.switch_enum_registry.bar_count()), UVM_NONE)
  endfunction
endclass
