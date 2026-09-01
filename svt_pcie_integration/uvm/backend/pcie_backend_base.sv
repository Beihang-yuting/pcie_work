//------------------------------------------------------------------------------
// Backend-neutral PCIe environment adapter.
//
// This object is deliberately not a uvm_component.  It lets the common
// pcie_unified_env validate and describe a backend without importing either the
// full TL package or Synopsys SVT implementation into the other build.
//------------------------------------------------------------------------------

virtual class pcie_backend_base extends uvm_object;
  // The adapter retains policy only; protocol components belong to the child
  // environment selected by the concrete backend.
  pcie_global_cfg global_cfg;

  // This is an abstract policy interface, not a constructible factory type.
  // Do not register it with `uvm_object_utils`: UVM's default object proxy
  // calls new() during factory setup, which VCS correctly rejects for a
  // class containing the pure-virtual backend_name() method.  Concrete
  // adapters below retain their own factory registration.

  function new(string name = "pcie_backend_base");
    super.new(name);
  endfunction

  // Store the one global policy object shared by all backend adapters.
  virtual function void configure(pcie_global_cfg cfg);
    global_cfg = cfg;
  endfunction

  // Concrete adapters may add backend-specific validation before construction.
  virtual function bit validate(output string errors[$]);
    errors.delete();
    if (global_cfg == null)
      errors.push_back("backend adapter received a null global configuration");
    return (errors.size() == 0);
  endfunction

  // A short name is used in logs and component-tree diagnostics.
  pure virtual function string backend_name();
endclass
