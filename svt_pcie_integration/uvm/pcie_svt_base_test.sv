class pcie_svt_base_test extends uvm_test;
  pcie_svt_env env;
  bit compile_only;
  bit cfg_init_only;

  `uvm_component_utils(pcie_svt_base_test)

  function new(string name = "pcie_svt_base_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    string compile_only_args[$];
    string cfg_init_only_args[$];

    super.build_phase(phase);
    uvm_root::get().set_timeout(30ms, 1'b1);
    void'(uvm_cmdline_processor::get_inst().get_arg_matches(
      "+PCIE_COMPILE_ONLY", compile_only_args));
    if ((compile_only_args.size() != 0) &&
        !((compile_only_args.size() == 1) &&
          (compile_only_args[0] == "+PCIE_COMPILE_ONLY")))
      `uvm_fatal("PCIE_COMPILE_ONLY",
        "Use exactly one bare +PCIE_COMPILE_ONLY argument")
    compile_only = (compile_only_args.size() == 1);
    void'(uvm_cmdline_processor::get_inst().get_arg_matches(
      "+PCIE_CFG_INIT_ONLY", cfg_init_only_args));
    if ((cfg_init_only_args.size() != 0) &&
        !((cfg_init_only_args.size() == 1) &&
          (cfg_init_only_args[0] == "+PCIE_CFG_INIT_ONLY")))
      `uvm_fatal("PCIE_CFG_INIT_ONLY",
        "Use exactly one bare +PCIE_CFG_INIT_ONLY argument")
    cfg_init_only = (cfg_init_only_args.size() == 1);
    if (compile_only && cfg_init_only)
      `uvm_fatal("PCIE_RUN_MODE",
        "+PCIE_COMPILE_ONLY and +PCIE_CFG_INIT_ONLY are mutually exclusive")
    env = pcie_svt_env::type_id::create("env", this);
  endfunction

  virtual function void end_of_elaboration_phase(uvm_phase phase);
    super.end_of_elaboration_phase(phase);
    if (env.active_primary_count() != `PCIE_SVT_ACTIVE_PORTS)
      `uvm_fatal("TOPOLOGY", $sformatf("created %0d primary ports, expected %0d",
        env.active_primary_count(), `PCIE_SVT_ACTIVE_PORTS))
`ifdef PCIE_USE_SVT_PEER
    if (env.active_peer_count() != `PCIE_SVT_ACTIVE_PORTS)
      `uvm_fatal("TOPOLOGY", $sformatf("created %0d peer ports, expected %0d",
        env.active_peer_count(), `PCIE_SVT_ACTIVE_PORTS))
`else
    if (env.active_peer_count() != 0)
      `uvm_fatal("TOPOLOGY", $sformatf(
        "placeholder build unexpectedly created %0d peer ports",
        env.active_peer_count()))
`endif
  endfunction

  virtual task run_phase(uvm_phase phase);
    pcie_svt_all_cfg_spaces_init_vseq cfg_init_vseq;
    pcie_svt_peer_smoke_vseq peer_smoke_vseq;
    phase.raise_objection(this);
    if (compile_only) begin
      // READY is intentionally non-final. External log gating owns success and
      // must also require normal completion and zero final UVM error/fatal counts.
      `uvm_info("PCIE_SVT_COMPILE_ONLY_READY", $sformatf(
        "topology=%0d gen=%0d active_primary_count=%0d",
        env.topology, env.pcie_gen, env.active_primary_count()), UVM_NONE)
      phase.drop_objection(this);
      return;
    end
    if (cfg_init_only) begin
      cfg_init_vseq =
        pcie_svt_all_cfg_spaces_init_vseq::type_id::create("cfg_init_vseq");
      if (cfg_init_vseq == null)
        `uvm_fatal("CFG_INIT", "configuration init sequence creation failed")
      cfg_init_vseq.start(env.vseqr);
      // READY is intentionally non-final. External log gating also requires
      // normal completion and zero final UVM error/fatal counts.
      `uvm_info("PCIE_SVT_CFG_INIT_READY", $sformatf(
        "topology=%0d gen=%0d active=%0d", env.topology, env.pcie_gen,
        env.active_primary_count()), UVM_NONE)
      phase.drop_objection(this);
      return;
    end
`ifdef PCIE_USE_SVT_PEER
    peer_smoke_vseq =
      pcie_svt_peer_smoke_vseq::type_id::create("peer_smoke_vseq");
    if (peer_smoke_vseq == null)
      `uvm_fatal("PEER_SMOKE", "peer smoke sequence creation failed")
    peer_smoke_vseq.start(env.vseqr);
`else
    `uvm_fatal("PCIE_RUN_MODE",
      "placeholder builds require +PCIE_COMPILE_ONLY or +PCIE_CFG_INIT_ONLY")
`endif
    phase.drop_objection(this);
  endtask
endclass
