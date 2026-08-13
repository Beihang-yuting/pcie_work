class pcie_svt_base_test extends uvm_test;
  pcie_svt_env env;

  `uvm_component_utils(pcie_svt_base_test)

  function new(string name = "pcie_svt_base_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = pcie_svt_env::type_id::create("env", this);
  endfunction

  virtual function void end_of_elaboration_phase(uvm_phase phase);
    super.end_of_elaboration_phase(phase);
    if (env.active_primary_count() != `PCIE_SVT_ACTIVE_PORTS)
      `uvm_fatal("TOPOLOGY", $sformatf("created %0d primary ports, expected %0d",
        env.active_primary_count(), `PCIE_SVT_ACTIVE_PORTS))
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    if ($test$plusargs("PCIE_COMPILE_ONLY")) begin
      `uvm_info("PCIE_SVT_COMPILE_ONLY_PASS", $sformatf(
        "topology=%0d gen=%0d active_primary_count=%0d",
        env.topology, env.pcie_gen, env.active_primary_count()), UVM_NONE)
      phase.drop_objection(this);
      return;
    end
    `uvm_fatal("TASK6_RUN_MODE",
      "Task 6 supports only +PCIE_COMPILE_ONLY; link/config sequences are not implemented")
    phase.drop_objection(this);
  endtask
endclass
