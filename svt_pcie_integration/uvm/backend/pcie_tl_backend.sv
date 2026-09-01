//------------------------------------------------------------------------------
// TL backend policy adapter.  The full pcie_tl_custom_env remains the
// protocol implementation; this object avoids importing it into SVT builds.
//------------------------------------------------------------------------------

class pcie_tl_backend extends pcie_backend_base;
  `uvm_object_utils(pcie_tl_backend)

  function new(string name = "pcie_tl_backend");
    super.new(name);
  endfunction

  virtual function string backend_name();
    return "TL";
  endfunction
endclass
