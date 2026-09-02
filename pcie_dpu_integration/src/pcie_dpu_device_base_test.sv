//------------------------------------------------------------------------------
// Public DPU-aware test entry point.
//
// User tests override build_system_cfg() exactly as native tests override
// build_global_cfg().  The factory override keeps the official
// pcie_device_base_test usage while moving resolution into a parent that can
// finish it before creating either protocol child.
//------------------------------------------------------------------------------

class pcie_dpu_device_base_test extends pcie_device_base_test;
  `uvm_component_utils(pcie_dpu_device_base_test)

  pcie_dpu_system_cfg system_cfg;
  pcie_dpu_system_env system_env;

  function new(string name = "pcie_dpu_device_base_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function bit environment_owns_global_cfg();
    return 1'b1;
  endfunction

  // Derived project tests populate dpu-common authoring data, physical PCIe
  // attachments, and the PCIe-side topology/link policy in this hook.
  virtual function void build_system_cfg();
    `uvm_fatal("DPU_SYSTEM_TEST",
      "derived test must override build_system_cfg()")
  endfunction

  virtual function void build_phase(uvm_phase phase);
    pcie_unified_env::type_id::set_type_override(
      pcie_dpu_system_env::get_type());
    system_cfg = pcie_dpu_system_cfg::type_id::create("system_cfg");
    build_system_cfg();
    uvm_config_db#(pcie_dpu_system_cfg)::set(
      this, "env", "system_cfg", system_cfg);

    super.build_phase(phase);
    if (!$cast(system_env, env))
      `uvm_fatal("DPU_SYSTEM_TEST",
        "pcie_unified_env factory override did not create pcie_dpu_system_env")
  endfunction

  virtual function void end_of_elaboration_phase(uvm_phase phase);
    super.end_of_elaboration_phase(phase);
    if (system_env != null)
      global_cfg = system_env.global_cfg;
  endfunction

  virtual task run_phase(uvm_phase phase);
    pcie_dpu_global_stage_vseq stage_sequence;

    phase.raise_objection(this);
    stage_sequence = pcie_dpu_global_stage_vseq::type_id::create(
      "global_stage_sequence");
    stage_sequence.system_env = system_env;
    stage_sequence.start(null);
    phase.drop_objection(this);
  endtask
endclass : pcie_dpu_device_base_test
