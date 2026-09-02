//------------------------------------------------------------------------------
// Project PCIe base test.
//
// The build ordering follows the official Unified VIP example while moving
// topology/device policy into pcie_global_cfg.  User tests override
// build_global_cfg() to select links, BDFs, BARs, and backend behavior.
//------------------------------------------------------------------------------

class pcie_device_base_test extends uvm_test;
  `uvm_component_utils(pcie_device_base_test)

  // Test-owned policy and common environment handle.
  pcie_global_cfg global_cfg;
  pcie_unified_env env;

  function new(string name = "pcie_device_base_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Select the compile-time topology graph.  Connectivity remains owned by
  // pcie_topology_builder; the global object only adds runtime policy.
  virtual function pcie_topology_cfg build_topology();
    int unsigned max_gen;

    // Gen4 is the default acceleration point; a plusarg may select Gen5.
    max_gen = 4;
    void'($value$plusargs("PCIE_GEN=%d", max_gen));
    if (max_gen != 4 && max_gen != 5)
      max_gen = 4;
`ifdef PCIE_TOPO_EP_X16
    return pcie_topology_builder::build_ep_x16(max_gen);
`elsif PCIE_TOPO_EP_2X8
    return pcie_topology_builder::build_ep_2x8(max_gen);
`elsif PCIE_TOPO_SWITCH_1X16_4X4
    return pcie_topology_builder::build_switch_1x16_4x4(max_gen);
`else
    return pcie_topology_builder::build_ep_x16(max_gen);
`endif
  endfunction

  // Hook for a scenario to edit backend, link enable/use_svt, BDF and BAR
  // policy after defaults have been generated but before env construction.
  virtual function void build_global_cfg();
    // Derived tests customize this object after defaults are materialized.
    global_cfg.build_default_for_topology(build_topology());
  endfunction

  // Native tests keep policy ownership here.  An integration extension may
  // return one when it must resolve an external authority (for example a
  // frozen DPU snapshot) inside the environment before protocol children are
  // created.  The factory still returns a pcie_unified_env-compatible handle.
  virtual function bit environment_owns_global_cfg();
    return 1'b0;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    string errors[$];

    super.build_phase(phase);

    if (!environment_owns_global_cfg()) begin
      // Build policy before publishing it to the child environment.
      global_cfg = pcie_global_cfg::type_id::create("global_cfg");
      build_global_cfg();
      global_cfg.validate(errors);
      if (errors.size() != 0) begin
        `uvm_fatal("GLOBAL_CFG", $sformatf(
          "base test global configuration invalid: %s", errors[0]))
        return;
      end

      // Native environments consume the same handle, avoiding a second
      // translation path that could diverge from test configuration.
      uvm_config_db#(pcie_global_cfg)::set(this, "env", "global_cfg",
                                           global_cfg);
    end else begin
      // The factory-selected integration environment owns policy publication.
      global_cfg = null;
    end

    env = pcie_unified_env::type_id::create("env", this);
  endfunction
endclass
