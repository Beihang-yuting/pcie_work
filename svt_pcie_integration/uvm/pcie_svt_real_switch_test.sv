import uvm_pkg::*;
`include "uvm_macros.svh"
import pcie_svt_integration_pkg::*;

class pcie_svt_real_switch_test extends pcie_svt_base_test;
  bit link_only;
  bit enum_only;
  bit traffic_mode;

  `uvm_component_utils(pcie_svt_real_switch_test)

  function new(string name = "pcie_svt_real_switch_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  protected function bit parse_bare_mode_plusarg(string arg_name);
    string arg_matches[$];

    void'(uvm_cmdline_processor::get_inst().get_arg_matches(
      arg_name, arg_matches));
    if ((arg_matches.size() != 0) &&
        !((arg_matches.size() == 1) && (arg_matches[0] == arg_name)))
      `uvm_fatal("PCIE_RUN_MODE", $sformatf(
        "Use at most one bare %s argument", arg_name))
    return (arg_matches.size() == 1);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    bit parsed_compile_only;
    bit parsed_cfg_init_only;
    int unsigned mode_count;

    // Preflight the inherited modes before super.build_phase so this derived
    // test consistently owns every five-mode contract failure under
    // PCIE_RUN_MODE, including valued or duplicate compile/cfg arguments.
    parsed_compile_only = parse_bare_mode_plusarg("+PCIE_COMPILE_ONLY");
    parsed_cfg_init_only = parse_bare_mode_plusarg("+PCIE_CFG_INIT_ONLY");
    link_only = parse_bare_mode_plusarg("+PCIE_LINK_ONLY");
    enum_only = parse_bare_mode_plusarg("+PCIE_ENUM_ONLY");
    traffic_mode = parse_bare_mode_plusarg("+PCIE_TRAFFIC");

    mode_count = parsed_compile_only + parsed_cfg_init_only + link_only +
                 enum_only + traffic_mode;
    if (mode_count != 1)
      `uvm_fatal("PCIE_RUN_MODE",
        "real Switch test requires exactly one of +PCIE_COMPILE_ONLY, +PCIE_CFG_INIT_ONLY, +PCIE_LINK_ONLY, +PCIE_ENUM_ONLY, or +PCIE_TRAFFIC")

`ifndef PCIE_USE_REAL_SWITCH_DUT
    if (link_only || enum_only || traffic_mode)
      `uvm_fatal("PCIE_RUN_MODE",
        "real Switch link/enum/traffic requires PCIE_USE_REAL_SWITCH_DUT")
`endif

    super.build_phase(phase);
    if (env == null)
      `uvm_fatal("REAL_SWITCH_TOPOLOGY",
        "real Switch environment creation failed")
  endfunction

  virtual function void end_of_elaboration_phase(uvm_phase phase);
    int unsigned primary_index;

    super.end_of_elaboration_phase(phase);
    if ((env == null) || (env.vseqr == null))
      `uvm_fatal("REAL_SWITCH_SEQUENCER",
        "real Switch environment or virtual sequencer is null")
    if ((env.topology != PCIE_SVT_TOPO_SWITCH) ||
        (env.active_primary_count() != 5) ||
        (env.active_peer_count() != 0))
      `uvm_fatal("REAL_SWITCH_TOPOLOGY", $sformatf(
        "requires Switch topology with five primary and zero peer ports; topology=%0d primary=%0d peer=%0d",
        env.topology, env.active_primary_count(), env.active_peer_count()))
    if ((env.switch_enum_registry == null) ||
        (env.vseqr.switch_enum_registry == null) ||
        (env.vseqr.switch_enum_registry != env.switch_enum_registry))
      `uvm_fatal("REAL_SWITCH_ENUM_REGISTRY",
        "environment and virtual sequencer must share one non-null Switch enumeration registry")

    for (int unsigned slot = 0; slot < 5; slot++) begin
      primary_index = PCIE_SVT_PRIMARY_RC0 + slot;
      if (!env.vseqr.active_port[primary_index] ||
          (env.vseqr.port_seqr[primary_index] == null))
        `uvm_fatal("REAL_SWITCH_SEQUENCER", $sformatf(
          "primary port index=%0d is inactive or has no Device virtual sequencer",
          primary_index))
      if (!env.vseqr.port_seqr[primary_index].driver_transaction_seqr.exists(0) ||
          (env.vseqr.port_seqr[primary_index].driver_transaction_seqr[0] == null))
        `uvm_fatal("REAL_SWITCH_SEQUENCER", $sformatf(
          "primary port index=%0d has no Driver App transaction sequencer[0]",
          primary_index))
    end

    if (env.vseqr.port_seqr[PCIE_SVT_PRIMARY_RC0].mem_target_seqr == null)
      `uvm_fatal("REAL_SWITCH_SEQUENCER",
        "primary RC0 has no Memory Target service sequencer")
    for (int unsigned ep = 0; ep < 4; ep++) begin
      primary_index = PCIE_SVT_PRIMARY_EP0 + ep;
      if (!env.vseqr.port_seqr[primary_index].target_seqr.exists(0) ||
          (env.vseqr.port_seqr[primary_index].target_seqr[0] == null))
        `uvm_fatal("REAL_SWITCH_SEQUENCER", $sformatf(
          "Endpoint=%0d primary_index=%0d has no Target App service sequencer[0]",
          ep, primary_index))
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    pcie_svt_all_cfg_spaces_init_vseq cfg_init;
    pcie_svt_rc_host_memory_init_vseq host_memory_init;
    pcie_svt_real_switch_links_vseq links;
    pcie_svt_real_switch_enumeration_vseq enumeration;
    pcie_svt_real_switch_traffic_vseq traffic;

    phase.raise_objection(this);

    if (!compile_only) begin
      cfg_init = pcie_svt_all_cfg_spaces_init_vseq::type_id::create(
        "cfg_init");
      host_memory_init =
        pcie_svt_rc_host_memory_init_vseq::type_id::create(
          "host_memory_init");
      if ((cfg_init == null) || (host_memory_init == null))
        `uvm_fatal("REAL_SWITCH_SEQUENCE_CREATE",
          "configuration or host-memory sequence creation failed")
      if (!cfg_init_only) begin
        links = pcie_svt_real_switch_links_vseq::type_id::create("links");
        if (links == null)
          `uvm_fatal("REAL_SWITCH_SEQUENCE_CREATE",
            "real Switch links sequence creation failed")
      end
      if (enum_only || traffic_mode) begin
        enumeration =
          pcie_svt_real_switch_enumeration_vseq::type_id::create(
            "enumeration");
        if (enumeration == null)
          `uvm_fatal("REAL_SWITCH_SEQUENCE_CREATE",
            "real Switch enumeration sequence creation failed")
      end
      if (traffic_mode) begin
        traffic =
          pcie_svt_real_switch_traffic_vseq::type_id::create("traffic");
        if (traffic == null)
          `uvm_fatal("REAL_SWITCH_SEQUENCE_CREATE",
            "real Switch traffic sequence creation failed")
      end
    end

    if (compile_only) begin
      `uvm_info("REAL_SWITCH_COMPILE_READY",
        "active_primary=5 peer=0", UVM_NONE)
    end else begin
      cfg_init.start(env.vseqr);
      host_memory_init.start(env.vseqr);
      if (cfg_init_only) begin
        `uvm_info("REAL_SWITCH_CFG_INIT_PASS",
          "active_primary=5 bar_checks=24 rc_skips=1", UVM_NONE)
      end else begin
        links.start(env.vseqr);
        if (enum_only || traffic_mode)
          enumeration.start(env.vseqr);
        if (traffic_mode)
          traffic.start(env.vseqr);
      end
    end

    phase.drop_objection(this);
  endtask
endclass
