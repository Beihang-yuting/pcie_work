import uvm_pkg::*;
`include "uvm_macros.svh"
import pcie_svt_integration_pkg::*;

class pcie_svt_switch_proxy_test extends pcie_svt_base_test;
  bit link_only;
  bit enum_only;
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
    enum_only = parse_bare_optional_plusarg(
      "+PCIE_ENUM_ONLY", "PCIE_ENUM_ONLY");
    disable_switch_sidecars = parse_bare_optional_plusarg(
      "+PCIE_DISABLE_SWITCH_SIDECARS", "PCIE_DISABLE_SWITCH_SIDECARS");
    if (compile_only || cfg_init_only)
      `uvm_fatal("PCIE_RUN_MODE",
        "switch proxy test rejects compile-only and cfg-init-only modes")
    if (link_only && enum_only)
      `uvm_fatal("PCIE_RUN_MODE",
        "+PCIE_LINK_ONLY and +PCIE_ENUM_ONLY are mutually exclusive")
    if (!link_only && !enum_only)
      `uvm_fatal("PCIE_RUN_MODE",
        "switch proxy test requires exactly one of +PCIE_LINK_ONLY or +PCIE_ENUM_ONLY")
    if (disable_switch_sidecars && !link_only)
      `uvm_fatal("PCIE_SWITCH_SIDECARS",
        "+PCIE_DISABLE_SWITCH_SIDECARS requires +PCIE_LINK_ONLY")
    uvm_config_db#(bit)::set(this, "env", "enumeration_mode", enum_only);
    uvm_config_db#(bit)::set(this, "env", "disable_switch_sidecars",
      disable_switch_sidecars);
  endfunction

  virtual function void end_of_elaboration_phase(uvm_phase phase);
    svt_uvm_pkg::svt_configuration tl_mon_cfg_base;
    svt_pcie_uvm_pkg::svt_pcie_configuration effective_pcie_cfg;

    super.end_of_elaboration_phase(phase);
    if ((env.topology != PCIE_SVT_TOPO_SWITCH) ||
        (env.active_primary_count() != 5) ||
        (env.active_peer_count() != 5))
      `uvm_fatal("SWITCH_PROXY_TOPOLOGY", $sformatf(
        "requires switch topology with five primary and five Proxy active handles; primary=%0d proxy=%0d",
        env.active_primary_count(), env.active_peer_count()))
    if ((env.switch_core == null) ||
        (env.switch_core.route_observed_port == null) ||
        (env.switch_core.route_observed_port.size() != 1))
      `uvm_fatal("SWITCH_ROUTE_OBSERVER_CONNECT", $sformatf(
        "proxy test requires exactly one switch route observer; connections=%0d",
        ((env.switch_core == null) ||
         (env.switch_core.route_observed_port == null)) ? 0 :
          env.switch_core.route_observed_port.size()))
    for (int unsigned i = 0; i < 5; i++) begin
      if (disable_switch_sidecars) begin
        if (env.switch_sidecar[i] != null)
          `uvm_fatal("SWITCH_STAR_9000762979", $sformatf(
            "port=%0d disabled link-only mode created a sidecar", i))
      end else begin
        if ((env.switch_sidecar[i] == null) ||
            (env.switch_sidecar[i].cfg == null) ||
            (env.switch_sidecar[i].agent == null) ||
            (env.switch_sidecar[i].agent.tl_mon == null)) begin
          `uvm_fatal("SWITCH_STAR_9000762979", $sformatf(
            "port=%0d sidecar direct monitor handle is missing", i))
          continue;
        end
        tl_mon_cfg_base = null;
        effective_pcie_cfg = null;
        env.switch_sidecar[i].agent.tl_mon.get_cfg(tl_mon_cfg_base);
        if (!$cast(effective_pcie_cfg, tl_mon_cfg_base) ||
            (effective_pcie_cfg == null) ||
            (effective_pcie_cfg.tl_cfg == null)) begin
          `uvm_fatal("SWITCH_SIDECAR_ROLE_DIAG", $sformatf(
            "port=%0d failed to read effective TL-monitor configuration type=%s",
            i, (tl_mon_cfg_base == null) ? "<null>" :
               tl_mon_cfg_base.get_type_name()))
          continue;
        end
        `uvm_info("SWITCH_SIDECAR_ROLE_DIAG", $sformatf(
          {"port=%0d input=%0b tl_monitor=%0b tx_downstream=%0b ",
          "cfg_space_mode=%0d"},
          i, env.switch_sidecar[i].cfg.tl_cfg.is_switch,
          effective_pcie_cfg.tl_cfg.is_switch,
          effective_pcie_cfg.tl_cfg.is_tx_downstream,
          effective_pcie_cfg.tl_cfg.cfg_space_mode), UVM_NONE)
        if ((env.switch_sidecar[i].cfg.tl_cfg.is_switch !== 1'b1) ||
            (effective_pcie_cfg.tl_cfg.is_switch !== 1'b1) ||
            (effective_pcie_cfg.tl_cfg.is_tx_downstream !== (i != 0)))
          `uvm_fatal("SWITCH_SIDECAR_ROLE", $sformatf(
            "port=%0d effective direct-agent switch role is invalid", i))
        if (effective_pcie_cfg.tl_cfg.cfg_space_mode !==
            svt_pcie_uvm_pkg::svt_pcie_tl_configuration::
              CFG_SPACE_ENUMERATION_UPDATE)
          `uvm_fatal("SWITCH_SIDECAR_CFG_SPACE_MODE", $sformatf(
            "port=%0d effective cfg_space_mode=%0d expected enumeration-update",
            i, effective_pcie_cfg.tl_cfg.cfg_space_mode))
        if ((env.switch_sidecar[i].apply_star_9000762979 !== enum_only) ||
            (env.switch_sidecar[i].star_9000762979_applied !== enum_only))
          `uvm_fatal("SWITCH_STAR_9000762979", $sformatf(
            "port=%0d enum_only=%0b configured=%0b applied=%0b",
            i, enum_only,
            env.switch_sidecar[i].apply_star_9000762979,
            env.switch_sidecar[i].star_9000762979_applied))
      end
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    pcie_svt_all_cfg_spaces_init_vseq cfg_init_vseq;
    pcie_svt_all_links_bringup_vseq links_vseq;
    pcie_svt_switch_sidecars_ready_vseq sidecars_prime_vseq;
    pcie_svt_switch_sidecars_ready_vseq sidecars_ready_vseq;
    pcie_svt_switch_enumeration_vseq enum_vseq;

    phase.raise_objection(this);
    if (!(link_only ^ enum_only))
      `uvm_fatal("PCIE_RUN_MODE",
        "switch proxy test run mode changed after build phase")

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
    if (enum_only) begin
      enum_vseq = pcie_svt_switch_enumeration_vseq::type_id::create(
        "enum_vseq");
      if (enum_vseq == null)
        `uvm_fatal("SWITCH_PROXY_RUN",
          "switch enumeration sequence creation failed")
      enum_vseq.start(env.vseqr);
    end
    phase.drop_objection(this);
  endtask
endclass
