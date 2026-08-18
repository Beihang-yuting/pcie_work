class pcie_svt_raw_tlp_sequence extends uvm_sequence #(svt_pcie_tlp);
  `uvm_object_utils(pcie_svt_raw_tlp_sequence)

  svt_pcie_tlp request;

  function new(string name = "pcie_svt_raw_tlp_sequence");
    super.new(name);
  endfunction

  virtual task body();
    if (request == null) begin
      `uvm_fatal("RAW_SEQUENCE_NULL", "raw TLP request is null")
      return;
    end
    start_item(request);
    finish_item(request);
  endtask
endclass
