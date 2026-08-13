class pcie_svt_base_test extends uvm_test;
  pcie_svt_env env;
  bit compile_only;

  `uvm_component_utils(pcie_svt_base_test)

  function new(string name = "pcie_svt_base_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    string compile_only_args[$];

    super.build_phase(phase);
    void'(uvm_cmdline_processor::get_inst().get_arg_matches(
      "+PCIE_COMPILE_ONLY", compile_only_args));
    if ((compile_only_args.size() != 0) &&
        !((compile_only_args.size() == 1) &&
          (compile_only_args[0] == "+PCIE_COMPILE_ONLY")))
      `uvm_fatal("PCIE_COMPILE_ONLY",
        "Use exactly one bare +PCIE_COMPILE_ONLY argument")
    compile_only = (compile_only_args.size() == 1);
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
    if (compile_only) begin
      `uvm_info("PCIE_SVT_COMPILE_ONLY_READY", $sformatf(
        "topology=%0d gen=%0d active_primary_count=%0d",
        env.topology, env.pcie_gen, env.active_primary_count()), UVM_NONE)
      phase.drop_objection(this);
      return;
    end
    `uvm_fatal("TASK6_RUN_MODE",
      "Task 6 supports only +PCIE_COMPILE_ONLY; link/config sequences are not implemented")
    phase.drop_objection(this);
  endtask

  virtual function void final_phase(uvm_phase phase);
    uvm_report_server report_server;

    super.final_phase(phase);
    report_server = uvm_report_server::get_server();
    if (compile_only &&
        (report_server.get_severity_count(UVM_ERROR) == 0) &&
        (report_server.get_severity_count(UVM_FATAL) == 0))
      `uvm_info("PCIE_SVT_COMPILE_ONLY_PASS", $sformatf(
        "topology=%0d gen=%0d active_primary_count=%0d",
        env.topology, env.pcie_gen, env.active_primary_count()), UVM_NONE)
  endfunction
endclass
