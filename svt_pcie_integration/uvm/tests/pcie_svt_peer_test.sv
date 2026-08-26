import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_svt_topology_pkg::*;
import svt_uvm_pkg::*;
import svt_pcie_uvm_pkg::*;
`include "uvm_macros.svh"

class pcie_svt_peer_test extends pcie_svt_topology_base_test;
  `uvm_component_utils(pcie_svt_peer_test)

  pcie_topology_cfg peer_topology_cfg;
  pcie_svt_topology_policy_cfg peer_policy_cfg;
  pcie_svt_topology_env peer_env;

  function new(string name = "pcie_svt_peer_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    pcie_svt_topology_adapter primary_adapter;
    pcie_svt_port_descriptor primary_ports[$];
    string errors[$];

    super.build_phase(phase);
    primary_adapter = pcie_svt_topology_adapter::type_id::create(
      "peer_primary_adapter");
    primary_adapter.translate(
      topology_cfg, policy_cfg, primary_ports, errors);
    if (errors.size() != 0) begin
      `uvm_fatal("SVT_PEER_CFG", pcie_svt_join_errors(errors))
      return;
    end
    pcie_svt_peer_fixture_builder::build(
      primary_ports, peer_topology_cfg, peer_policy_cfg, errors);
    if ((errors.size() != 0) || (peer_topology_cfg == null) ||
        (peer_policy_cfg == null)) begin
      `uvm_fatal("SVT_PEER_CFG", (errors.size() == 0) ?
        "peer fixture returned null topology/policy" :
        pcie_svt_join_errors(errors))
      return;
    end
    peer_policy_cfg.default_fast_link_training = fast_link_training;
    peer_policy_cfg.transport = transport;
    uvm_config_db#(pcie_topology_cfg)::set(
      this, "peer_env", "topology_cfg", peer_topology_cfg);
    uvm_config_db#(pcie_svt_topology_policy_cfg)::set(
      this, "peer_env", "policy_cfg", peer_policy_cfg);
    peer_env = pcie_svt_topology_env::type_id::create("peer_env", this);
  endfunction

  virtual function void end_of_elaboration_phase(uvm_phase phase);
    super.end_of_elaboration_phase(phase);
    if ((peer_env == null) || (env == null)) begin
      `uvm_fatal("SVT_PEER_COUNT", "primary/peer environment is null")
      return;
    end
    if (peer_env.port_count() != env.port_count()) begin
      `uvm_fatal("SVT_PEER_COUNT", $sformatf(
        "primary=%0d peer=%0d", env.port_count(), peer_env.port_count()))
      return;
    end
    foreach (env.descriptors[i]) begin
      pcie_svt_port_descriptor primary;
      pcie_svt_port_descriptor peer;
      primary = env.descriptors[i];
      peer = peer_env.descriptors[i];
      if ((primary == null) || (peer == null) ||
          (peer.role == primary.role) ||
          (peer.physical_width != primary.physical_width) ||
          (peer.link_width != primary.link_width) ||
          (peer.max_gen != primary.max_gen) ||
          (peer.slot_index != primary.slot_index) ||
          (peer.fast_link_training != primary.fast_link_training)) begin
        `uvm_fatal("SVT_PEER_PAIR", $sformatf(
          {"slot=%0d primary_role=%s peer_role=%s primary_phy=x%0d ",
           "peer_phy=x%0d primary_width=x%0d peer_width=x%0d ",
           "primary_gen=%0d peer_gen=%0d primary_fast=%0d peer_fast=%0d"},
          i,
          (primary == null) ? "<null>" : primary.role.name(),
          (peer == null) ? "<null>" : peer.role.name(),
          (primary == null) ? 0 : primary.physical_width,
          (peer == null) ? 0 : peer.physical_width,
          (primary == null) ? 0 : primary.link_width,
          (peer == null) ? 0 : peer.link_width,
          (primary == null) ? 0 : primary.max_gen,
          (peer == null) ? 0 : peer.max_gen,
          (primary == null) ? 0 : primary.fast_link_training,
          (peer == null) ? 0 : peer.fast_link_training))
      end
    end
    `uvm_info("PCIE_SVT_PEER_ENV_READY", $sformatf(
      "profile=%s agents=%0d", profile_name, peer_env.port_count()),
      UVM_NONE)
  endfunction

  protected function bit all_cfg_pass(
      pcie_svt_topology_virtual_sequencer selected_seqr);
    if (selected_seqr == null)
      return 1'b0;
    foreach (selected_seqr.descriptor_by_link[link_id]) begin
      if (!selected_seqr.cfg_state.exists(link_id) ||
          (selected_seqr.cfg_state[link_id] != PCIE_SVT_STAGE_PASS))
        return 1'b0;
    end
    return 1'b1;
  endfunction

  protected task run_paired_cfg();
    pcie_svt_cfg_init_vseq primary_cfg;
    pcie_svt_cfg_init_vseq peer_cfg;

    primary_cfg = pcie_svt_cfg_init_vseq::type_id::create("primary_cfg");
    peer_cfg = pcie_svt_cfg_init_vseq::type_id::create("peer_cfg");
    if ((primary_cfg == null) || (peer_cfg == null))
      `uvm_fatal("SVT_PEER_CFG", "paired cfg sequence creation failed")
    primary_cfg.program_target_bars = 1'b1;
    peer_cfg.program_target_bars = (profile_name != "SWITCH_1X16_4X4");
    fork
      primary_cfg.start(env.vseqr);
      peer_cfg.start(peer_env.vseqr);
    join
    if (!all_cfg_pass(env.vseqr) || !all_cfg_pass(peer_env.vseqr))
      `uvm_fatal("SVT_PEER_CFG", "primary/peer CFG stage did not pass")
    if ((env.vseqr.reset_vif.asserted !== '0) ||
        (peer_env.vseqr.reset_vif.asserted !== '0))
      `uvm_fatal("SVT_PEER_RESET", $sformatf(
        "CFG left reset asserted primary=0x%0h peer=0x%0h",
        env.vseqr.reset_vif.asserted, peer_env.vseqr.reset_vif.asserted))
  endtask

  virtual task run_phase(uvm_phase phase);
    pcie_svt_link_vseq link_sequence;

    if (run_mode == PCIE_SVT_RUN_COMPILE) begin
      super.run_phase(phase);
      return;
    end
    phase.raise_objection(this);
    run_paired_cfg();
    if (run_mode >= PCIE_SVT_RUN_LINK) begin
      link_sequence = pcie_svt_link_vseq::type_id::create("link_sequence");
      if (link_sequence == null)
        `uvm_fatal("SVT_PEER_LINK", "link sequence creation failed")
      link_sequence.primary_seqr = env.vseqr;
      link_sequence.peer_seqr = peer_env.vseqr;
      link_sequence.start(null);
    end
    env.vseqr.report_stage_table();
    phase.drop_objection(this);
  endtask
endclass
