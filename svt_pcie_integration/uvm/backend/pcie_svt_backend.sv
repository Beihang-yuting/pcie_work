//------------------------------------------------------------------------------
// SVT backend policy adapter.
//------------------------------------------------------------------------------

class pcie_svt_backend extends pcie_backend_base;
  `uvm_object_utils(pcie_svt_backend)

  function new(string name = "pcie_svt_backend");
    super.new(name);
  endfunction

  virtual function string backend_name();
    return "SVT";
  endfunction

  virtual function bit validate(output string errors[$]);
    errors.delete();
    if (!super.validate(errors))
      return 1'b0;
    foreach (global_cfg.links[i]) begin
      if ((global_cfg.links[i] != null) && global_cfg.links[i].enabled &&
          global_cfg.links[i].use_svt &&
          !global_cfg.links[i].has_hdl_slot)
        errors.push_back($sformatf(
          "SVT link '%s' has no static HDL slot binding",
          global_cfg.links[i].link_id));
    end
    return (errors.size() == 0);
  endfunction
endclass
