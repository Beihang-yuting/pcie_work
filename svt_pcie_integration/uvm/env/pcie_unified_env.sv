//------------------------------------------------------------------------------
// Common PCIe environment management layer.
//
// Protocol-specific child environments remain in their own package/filelist;
// this component owns the shared policy and backend selection without forcing
// a full TL package into an SVT-only build.
//------------------------------------------------------------------------------

class pcie_unified_env extends uvm_env;
  `uvm_component_utils(pcie_unified_env)

  // One validated policy object is shared by every backend adapter.
  pcie_global_cfg global_cfg;

  // Adapter is an object so concrete protocol envs can be supplied by a
  // derived environment without introducing a package dependency cycle.
  pcie_backend_base backend_adapter;

  function new(string name = "pcie_unified_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    string errors[$];

    super.build_phase(phase);
    if (!uvm_config_db#(pcie_global_cfg)::get(
          this, "", "global_cfg", global_cfg) || (global_cfg == null)) begin
      `uvm_fatal("UNIFIED_CFG", "non-null global_cfg is required")
      return;
    end
    global_cfg.validate(errors);
    if (errors.size() != 0) begin
      `uvm_fatal("UNIFIED_CFG", $sformatf(
        "global configuration is invalid: %s", errors[0]))
      return;
    end

    case (global_cfg.backend)
      PCIE_BACKEND_TL_ONLY,
      PCIE_BACKEND_SVT_TL_FORWARD:
        backend_adapter = pcie_tl_backend::type_id::create("tl_backend");
      PCIE_BACKEND_SVT_REAL_DUT:
        backend_adapter = pcie_svt_backend::type_id::create("svt_backend");
      default:
        `uvm_fatal("UNIFIED_BACKEND", "unsupported backend enum")
    endcase
    backend_adapter.configure(global_cfg);
    if (!backend_adapter.validate(errors))
      `uvm_fatal("UNIFIED_BACKEND", $sformatf(
        "%s backend rejected global configuration: %s",
        backend_adapter.backend_name(), errors[0]));
  endfunction
endclass
