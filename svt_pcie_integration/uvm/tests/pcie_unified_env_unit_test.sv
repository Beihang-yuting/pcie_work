//------------------------------------------------------------------------------
// Construction test for the common environment manager.
//
// The test intentionally uses TL_ONLY so no SVT HDL connection is required;
// it proves that backend selection and global-cfg validation happen before any
// protocol-specific environment is constructed.
//------------------------------------------------------------------------------
import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
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
    pcie_tl_custom_env tl_child;

    super.end_of_elaboration_phase(phase);
    if (env == null || env.backend_adapter == null)
      `uvm_fatal("UNIFIED_ENV_TEST", "backend adapter was not constructed")
    if (!$cast(tl_backend, env.backend_adapter))
      `uvm_fatal("UNIFIED_ENV_TEST", "TL_ONLY selected a non-TL adapter")
    // Regression target: TL_ONLY must own a real protocol child, while the
    // inactive SVT branch must remain absent from the component tree.
    if (env.tl_env == null)
      `uvm_fatal("UNIFIED_ENV_TEST", "TL_ONLY did not create its TL child")
    if (env.svt_env != null)
      `uvm_fatal("UNIFIED_ENV_TEST", "TL_ONLY also created an SVT child")
    if (!$cast(tl_child, env.tl_env))
      `uvm_fatal("UNIFIED_ENV_TEST",
                 "TL_ONLY child is not pcie_tl_custom_env")
    if ((tl_child.cfg == null) ||
        (tl_child.cfg.device_cfgs.size() != global_cfg.devices.size()))
      `uvm_fatal("UNIFIED_ENV_TEST",
                 "TL child did not receive global device policy")
  endfunction
endclass

//------------------------------------------------------------------------------
// SVT child-selection and policy-projection test.
//
// A real-DUT run must create only the Unified VIP child.  The checks below use
// hand-selected link and BAR values so a missing or partial global-to-SVT
// translation cannot accidentally pass by matching the project defaults.
//------------------------------------------------------------------------------
class pcie_unified_env_svt_unit_test extends pcie_device_base_test;
  `uvm_component_utils(pcie_unified_env_svt_unit_test)

  function new(string name = "pcie_unified_env_svt_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_global_cfg();
    super.build_global_cfg();

    global_cfg.backend = PCIE_BACKEND_SVT_REAL_DUT;
    global_cfg.runtime_num_links = 1;
    foreach (global_cfg.links[i]) begin
      global_cfg.links[i].enabled = (i == 0);
      global_cfg.links[i].use_svt = (i == 0);
      global_cfg.links[i].max_gen = 5;
      global_cfg.links[i].has_hdl_slot = (i == 0);
      global_cfg.links[i].hdl_slot = 0;
      global_cfg.links[i].vif_key = "primary_vif_0";
    end

    // BAR0 is deliberately smaller than the default 32 MiB profile.  The SVT
    // policy must preserve this device-owned value for later Target App setup.
    foreach (global_cfg.devices[i]) begin
      if ((global_cfg.devices[i] != null) &&
          (global_cfg.devices[i].role == PCIE_DEVICE_EP)) begin
        global_cfg.devices[i].bars[0].aperture = 64'd16777216;
        global_cfg.devices[i].bars[0].initial_base =
          64'h0000_0001_2000_0000;
      end
    end
  endfunction

  function void end_of_elaboration_phase(uvm_phase phase);
    pcie_svt_backend svt_backend;

    super.end_of_elaboration_phase(phase);

    if ((env == null) || (env.backend_adapter == null))
      `uvm_fatal("UNIFIED_SVT_TEST", "backend adapter was not constructed")
    if (!$cast(svt_backend, env.backend_adapter))
      `uvm_fatal("UNIFIED_SVT_TEST",
                 "SVT_REAL_DUT selected a non-SVT adapter")
    if (env.svt_env == null)
      `uvm_fatal("UNIFIED_SVT_TEST", "SVT child was not constructed")
    if (env.tl_env != null)
      `uvm_fatal("UNIFIED_SVT_TEST", "SVT run also constructed a TL child")

    if ((env.svt_env.policy_cfg == null) ||
        (env.svt_env.policy_cfg.link_overrides.size() != 1))
      `uvm_fatal("UNIFIED_SVT_TEST",
                 "global link policy was not projected into SVT")
    if (!env.svt_env.policy_cfg.link_overrides[0].has_vif_key ||
        (env.svt_env.policy_cfg.link_overrides[0].vif_key !=
         "primary_vif_0"))
      `uvm_fatal("UNIFIED_SVT_TEST",
                 "explicit VIF binding was not projected into SVT")
    if ((env.svt_env.descriptors.size() != 1) ||
        (env.svt_env.descriptors[0].slot_index != 0) ||
        (env.svt_env.descriptors[0].max_gen != 5))
      `uvm_fatal("UNIFIED_SVT_TEST",
                 "SVT descriptor lost slot or Gen policy")

    if ((env.svt_env.policy_cfg.device_cfgs.size() !=
         global_cfg.devices.size()) ||
        (env.svt_env.policy_cfg.device_cfgs[1].bars[0].aperture !=
         64'd16777216) ||
        (env.svt_env.policy_cfg.device_cfgs[1].bars[0].initial_base !=
         64'h0000_0001_2000_0000))
      `uvm_fatal("UNIFIED_SVT_TEST",
                 "global device/BAR policy was not projected into SVT")
  endfunction
endclass

//------------------------------------------------------------------------------
// Preflight failure test.
//------------------------------------------------------------------------------
class pcie_unified_cfg_fatal_catcher extends uvm_report_catcher;
  bit caught_expected_fatal;

  function new(string name = "pcie_unified_cfg_fatal_catcher");
    super.new(name);
  endfunction

  virtual function action_e catch();
    if ((get_severity() == UVM_FATAL) &&
        (get_id() == "UNIFIED_CFG")) begin
      caught_expected_fatal = 1'b1;
      set_severity(UVM_WARNING);
    end
    return THROW;
  endfunction
endclass

class pcie_unified_env_invalid_cfg_unit_test extends uvm_test;
  `uvm_component_utils(pcie_unified_env_invalid_cfg_unit_test)

  pcie_global_cfg global_cfg;
  pcie_unified_env env;
  pcie_unified_cfg_fatal_catcher fatal_catcher;

  function new(string name = "pcie_unified_env_invalid_cfg_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    fatal_catcher = new();
    uvm_report_cb::add(null, fatal_catcher);

    global_cfg = pcie_global_cfg::type_id::create("global_cfg");
    global_cfg.build_default_for_topology(
      pcie_topology_builder::build_ep_x16(4));

    // A null link record is invalid and must be rejected before either
    // protocol environment is constructed.
    global_cfg.links[0] = null;
    uvm_config_db#(pcie_global_cfg)::set(
      this, "env", "global_cfg", global_cfg);
    env = pcie_unified_env::type_id::create("env", this);
  endfunction

  function void end_of_elaboration_phase(uvm_phase phase);
    super.end_of_elaboration_phase(phase);

    if ((fatal_catcher == null) || !fatal_catcher.caught_expected_fatal)
      `uvm_fatal("UNIFIED_INVALID_TEST",
                 "invalid policy did not report UNIFIED_CFG")
    if ((env == null) || (env.tl_env != null) || (env.svt_env != null))
      `uvm_fatal("UNIFIED_INVALID_TEST",
                 "invalid policy created a protocol child")
  endfunction

  function void final_phase(uvm_phase phase);
    uvm_report_cb::delete(null, fatal_catcher);
    super.final_phase(phase);
  endfunction
endclass
