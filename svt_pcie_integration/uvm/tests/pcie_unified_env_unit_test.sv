//------------------------------------------------------------------------------
// Construction test for the common environment manager.
//
// The test intentionally uses TL_ONLY so no SVT HDL connection is required;
// it proves that backend selection and global-cfg validation happen before any
// protocol-specific environment is constructed.
//------------------------------------------------------------------------------
import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_svt_topology_pkg::*;
`include "uvm_macros.svh"

class pcie_unified_env_unit_test extends pcie_device_base_test;
  `uvm_component_utils(pcie_unified_env_unit_test)

  function new(string name = "pcie_unified_env_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_global_cfg();
    super.build_global_cfg();
    global_cfg.backend = PCIE_BACKEND_TL_ONLY;
    foreach (global_cfg.links[i]) begin
      global_cfg.links[i].enabled = (i == 0);
      global_cfg.links[i].use_svt = 1'b0;
    end
    global_cfg.runtime_num_links = 1;
  endfunction

  function void end_of_elaboration_phase(uvm_phase phase);
    pcie_tl_backend tl_backend;

    super.end_of_elaboration_phase(phase);
    if (env == null || env.backend_adapter == null)
      `uvm_fatal("UNIFIED_ENV_TEST", "backend adapter was not constructed")
    if (!$cast(tl_backend, env.backend_adapter))
      `uvm_fatal("UNIFIED_ENV_TEST", "TL_ONLY selected a non-TL adapter")
  endfunction
endclass
