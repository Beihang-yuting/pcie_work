import uvm_pkg::*;
`include "uvm_macros.svh"
import pcie_svt_integration_pkg::*;

class pcie_svt_switch_proxy_test extends pcie_svt_base_test;
  bit link_only;
  bit disable_switch_sidecars;

  `uvm_component_utils(pcie_svt_switch_proxy_test)

  function new(string name = "pcie_svt_switch_proxy_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  protected function bit parse_bare_optional_plusarg(
      string arg_name, string report_id);
    string arg_matches[$];

    void'(uvm_cmdline_processor::get_inst().get_arg_matches(
      arg_name, arg_matches));
    if ((arg_matches.size() != 0) &&
        !((arg_matches.size() == 1) && (arg_matches[0] == arg_name)))
      `uvm_fatal(report_id, $sformatf(
        "Use at most one bare %s argument", arg_name))
    return (arg_matches.size() == 1);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    link_only = parse_bare_optional_plusarg(
      "+PCIE_LINK_ONLY", "PCIE_LINK_ONLY");
    disable_switch_sidecars = parse_bare_optional_plusarg(
      "+PCIE_DISABLE_SWITCH_SIDECARS", "PCIE_DISABLE_SWITCH_SIDECARS");
    if (compile_only || cfg_init_only)
      `uvm_fatal("PCIE_RUN_MODE",
        "Task 8 switch proxy test accepts only +PCIE_LINK_ONLY")
    if (disable_switch_sidecars && !link_only)
      `uvm_fatal("PCIE_SWITCH_SIDECARS",
        "+PCIE_DISABLE_SWITCH_SIDECARS requires +PCIE_LINK_ONLY")
    uvm_config_db#(bit)::set(this, "env", "disable_switch_sidecars",
      disable_switch_sidecars);
  endfunction

  virtual function void end_of_elaboration_phase(uvm_phase phase);
    super.end_of_elaboration_phase(phase);
    if ((env.topology != PCIE_SVT_TOPO_SWITCH) ||
        (env.active_primary_count() != 5) ||
        (env.active_peer_count() != 5))
      `uvm_fatal("SWITCH_PROXY_TOPOLOGY", $sformatf(
        "requires switch topology with five primary and five Proxy active handles; primary=%0d proxy=%0d",
        env.active_primary_count(), env.active_peer_count()))
  endfunction

  virtual task run_phase(uvm_phase phase);
    pcie_svt_all_cfg_spaces_init_vseq cfg_init_vseq;
    pcie_svt_all_links_bringup_vseq links_vseq;
    pcie_svt_switch_sidecars_ready_vseq sidecars_prime_vseq;
    pcie_svt_switch_sidecars_ready_vseq sidecars_ready_vseq;

    phase.raise_objection(this);
    if (!link_only)
      `uvm_fatal("PCIE_RUN_MODE",
        "Task 8 switch proxy test requires +PCIE_LINK_ONLY")

    cfg_init_vseq = pcie_svt_all_cfg_spaces_init_vseq::type_id::create(
      "cfg_init_vseq");
    links_vseq = pcie_svt_all_links_bringup_vseq::type_id::create(
      "links_vseq");
    if ((cfg_init_vseq == null) || (links_vseq == null))
      `uvm_fatal("SWITCH_PROXY_RUN",
        "configuration/link sequence creation failed")
    cfg_init_vseq.start(env.vseqr);
    if (!disable_switch_sidecars) begin
      sidecars_prime_vseq =
        pcie_svt_switch_sidecars_ready_vseq::type_id::create(
          "sidecars_prime_vseq");
      if (sidecars_prime_vseq == null)
        `uvm_fatal("SWITCH_PROXY_RUN",
          "sidecar configuration priming sequence creation failed")
      sidecars_prime_vseq.prime_headers_only = 1'b1;
      sidecars_prime_vseq.start(env.vseqr);
    end
    links_vseq.start(env.vseqr);

    if (!disable_switch_sidecars) begin
      sidecars_ready_vseq =
        pcie_svt_switch_sidecars_ready_vseq::type_id::create(
          "sidecars_ready_vseq");
      if (sidecars_ready_vseq == null)
        `uvm_fatal("SWITCH_PROXY_RUN",
          "sidecar readiness sequence creation failed")
      sidecars_ready_vseq.start(env.vseqr);
    end
    phase.drop_objection(this);
  endtask
endclass
