class pcie_svt_env extends uvm_env;
  pcie_svt_profile_set profiles;
  pcie_svt_profile_set peer_profiles;
  pcie_svt_port_env port[PCIE_SVT_MAX_PORTS];
  pcie_svt_virtual_sequencer vseqr;
  pcie_svt_topology_e topology;
  int unsigned pcie_gen;

  `uvm_component_utils(pcie_svt_env)

  function new(string name = "pcie_svt_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function string primary_vif_key(int unsigned index);
    case (topology)
      PCIE_SVT_TOPO_EP_X16:
        if (index == PCIE_SVT_PRIMARY_RC0)
          return "primary_rc0_vif";
      PCIE_SVT_TOPO_EP_2X8:
        case (index)
          PCIE_SVT_PRIMARY_RC0: return "primary_rc0_vif";
          PCIE_SVT_PRIMARY_RC1: return "primary_rc1_vif";
          default: return "";
        endcase
      PCIE_SVT_TOPO_SWITCH:
        case (index)
          PCIE_SVT_PRIMARY_RC0: return "primary_rc0_vif";
          PCIE_SVT_PRIMARY_EP0: return "primary_ep0_vif";
          PCIE_SVT_PRIMARY_EP1: return "primary_ep1_vif";
          PCIE_SVT_PRIMARY_EP2: return "primary_ep2_vif";
          PCIE_SVT_PRIMARY_EP3: return "primary_ep3_vif";
          default: return "";
        endcase
      default: return "";
    endcase
    return "";
  endfunction

  function string peer_vif_key(int unsigned index);
    case (topology)
      PCIE_SVT_TOPO_EP_X16:
        if (index == PCIE_SVT_PEER_PORT0)
          return "peer_ep0_vif";
      PCIE_SVT_TOPO_EP_2X8:
        case (index)
          PCIE_SVT_PEER_PORT0: return "peer_ep0_vif";
          PCIE_SVT_PEER_PORT1: return "peer_ep1_vif";
          default: return "";
        endcase
      PCIE_SVT_TOPO_SWITCH:
        case (index)
          PCIE_SVT_PEER_PORT0: return "peer_ep_usp_vif";
          PCIE_SVT_PEER_PORT1: return "peer_rc_dsp0_vif";
          PCIE_SVT_PEER_PORT2: return "peer_rc_dsp1_vif";
          PCIE_SVT_PEER_PORT3: return "peer_rc_dsp2_vif";
          PCIE_SVT_PEER_PORT4: return "peer_rc_dsp3_vif";
          default: return "";
        endcase
      default: return "";
    endcase
    return "";
  endfunction

  function string selected_vif_key(int unsigned index);
    if (index <= PCIE_SVT_PRIMARY_PORT4)
      return primary_vif_key(index);
    return peer_vif_key(index);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    string gen_values[$];
    string vif_key;
    svt_pcie_vif selected_vif;

    super.build_phase(phase);
    topology = compiled_topology();
    void'(uvm_cmdline_processor::get_inst().get_arg_values(
      "+PCIE_GEN=", gen_values));
    if ((gen_values.size() != 1) ||
        !((gen_values[0] == "4") || (gen_values[0] == "5")))
      `uvm_fatal("PCIE_GEN", "Required +PCIE_GEN must be 4 or 5")
    pcie_gen = (gen_values[0] == "4") ? 4 : 5;

    profiles = pcie_svt_profile_set::type_id::create("profiles");
    profiles.build_for_topology(topology, pcie_gen);
`ifdef PCIE_USE_SVT_PEER
    peer_profiles = pcie_svt_profile_set::type_id::create("peer_profiles");
    peer_profiles.build_peer_for_topology(topology, pcie_gen);
    for (int unsigned i = PCIE_SVT_PEER_PORT0;
         i <= PCIE_SVT_PEER_PORT4; i++)
      if (peer_profiles.port[i] != null)
        profiles.port[i] = peer_profiles.port[i];
`endif
    vseqr = pcie_svt_virtual_sequencer::type_id::create("vseqr", this);

    for (int unsigned i = 0; i < PCIE_SVT_MAX_PORTS; i++) begin
      if (profiles.port[i] == null)
        continue;
      vif_key = selected_vif_key(i);
      if ((vif_key.len() == 0) ||
          !uvm_config_db#(svt_pcie_vif)::get(
            null, "uvm_test_top", vif_key, selected_vif) ||
          (selected_vif == null))
        `uvm_fatal("VIF", $sformatf(
          "missing VIF for port index %0d key '%s'", i, vif_key))
      uvm_config_db#(svt_pcie_vif)::set(
        this, $sformatf("port[%0d]", i), "vif", selected_vif);
      uvm_config_db#(pcie_svt_port_profile)::set(
        this, $sformatf("port[%0d]", i), "profile", profiles.port[i]);
      port[i] = pcie_svt_port_env::type_id::create(
        $sformatf("port[%0d]", i), this);
    end
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    for (int unsigned i = 0; i < PCIE_SVT_MAX_PORTS; i++) begin
      if (port[i] == null)
        continue;
      if ((port[i].profile == null) || (port[i].status == null) ||
          (port[i].cfg == null) || (port[i].agent == null) ||
          (port[i].agent.virt_seqr == null))
        `uvm_fatal("PORT_REGISTRY", $sformatf(
          "port index %0d has incomplete profile/status/agent/sequencer handles", i))
      vseqr.port_agent[i] = port[i].agent;
      vseqr.port_cfg[i] = port[i].cfg;
      vseqr.port_seqr[i] = port[i].agent.virt_seqr;
      vseqr.port_status[i] = port[i].status;
      vseqr.port_profile[i] = port[i].profile;
      vseqr.active_port[i] = 1'b1;
      `uvm_info("PCIE_SVT_PORT_ACTIVE", $sformatf(
        "index=%0d profile=%s agent=%s", i, port[i].profile.port_id,
        port[i].agent.get_full_name()), UVM_LOW)
    end
  endfunction

  function int unsigned active_primary_count();
    int unsigned count;
    for (int unsigned i = 0; i <= PCIE_SVT_PRIMARY_PORT4; i++)
      if ((port[i] != null) && vseqr.active_port[i])
        count++;
    return count;
  endfunction

  function int unsigned active_peer_count();
    int unsigned count;
    for (int unsigned i = PCIE_SVT_PEER_PORT0;
         i <= PCIE_SVT_PEER_PORT4; i++)
      if ((port[i] != null) && vseqr.active_port[i])
        count++;
    return count;
  endfunction
endclass
