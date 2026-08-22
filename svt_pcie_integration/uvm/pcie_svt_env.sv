class pcie_svt_env extends uvm_env;
  pcie_svt_profile_set profiles;
  pcie_svt_profile_set peer_profiles;
  pcie_svt_port_env port[PCIE_SVT_MAX_PORTS];
  pcie_svt_virtual_sequencer vseqr;
  pcie_tl_switch_config switch_cfg;
  pcie_tl_switch switch_core;
  pcie_svt_switch_port_adapter switch_adapter[5];
  pcie_svt_switch_target_callback switch_target_callback[5];
  pcie_svt_switch_scoreboard switch_scoreboard;
  pcie_svt_switch_enum_registry switch_enum_registry;
  pcie_svt_switch_sidecar_env switch_sidecar[5];
  uvm_analysis_port #(svt_pcie_tl_service) switch_sidecar_service_port[5];
  pcie_svt_topology_e topology;
  int unsigned pcie_gen;
  bit fast_link_training;
  bit disable_switch_sidecars;
  bit enumeration_mode;

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
`ifdef PCIE_USE_SVT_SWITCH_PROXY
          PCIE_SVT_PEER_PORT0: return "proxy_usp_vif";
          PCIE_SVT_PEER_PORT1: return "proxy_dsp0_vif";
          PCIE_SVT_PEER_PORT2: return "proxy_dsp1_vif";
          PCIE_SVT_PEER_PORT3: return "proxy_dsp2_vif";
          PCIE_SVT_PEER_PORT4: return "proxy_dsp3_vif";
`else
          PCIE_SVT_PEER_PORT0: return "peer_ep_usp_vif";
          PCIE_SVT_PEER_PORT1: return "peer_rc_dsp0_vif";
          PCIE_SVT_PEER_PORT2: return "peer_rc_dsp1_vif";
          PCIE_SVT_PEER_PORT3: return "peer_rc_dsp2_vif";
          PCIE_SVT_PEER_PORT4: return "peer_rc_dsp3_vif";
`endif
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
    string fast_link_values[$];
    string fast_link_args[$];
    bit invalid_fast_link_arg;
    bit is_switch_proxy;
    string vif_key;
    svt_pcie_vif selected_vif;
    svt_pcie_configuration::svt_pcie_serdes_x16_vif sidecar_x16_vif;
    svt_pcie_configuration::svt_pcie_serdes_x4_vif sidecar_x4_vif;

    super.build_phase(phase);
    topology = compiled_topology();
    void'(uvm_cmdline_processor::get_inst().get_arg_values(
      "+PCIE_GEN=", gen_values));
    if ((gen_values.size() != 1) ||
        !((gen_values[0] == "4") || (gen_values[0] == "5")))
      `uvm_fatal("PCIE_GEN", "Required +PCIE_GEN must be 4 or 5")
    pcie_gen = (gen_values[0] == "4") ? 4 : 5;

    fast_link_training = 1'b0;
    void'(uvm_cmdline_processor::get_inst().get_arg_values(
      "+PCIE_FAST_LINK_TRAIN=", fast_link_values));
    void'(uvm_cmdline_processor::get_inst().get_arg_matches(
      "+PCIE_FAST_LINK_TRAIN", fast_link_args));
    invalid_fast_link_arg = 1'b0;
    foreach (fast_link_args[i])
      if (fast_link_args[i] == "+PCIE_FAST_LINK_TRAIN")
        invalid_fast_link_arg = 1'b1;
    if (invalid_fast_link_arg || (fast_link_values.size() > 1) ||
        ((fast_link_values.size() == 1) &&
         !((fast_link_values[0] == "0") ||
           (fast_link_values[0] == "1"))))
      `uvm_fatal("PCIE_FAST_LINK_TRAIN",
        "Optional +PCIE_FAST_LINK_TRAIN must occur at most once and be 0 or 1")
    if (fast_link_values.size() == 1)
      fast_link_training = (fast_link_values[0] == "1");

    profiles = pcie_svt_profile_set::type_id::create("profiles");
    profiles.build_for_topology(topology, pcie_gen);
`ifdef PCIE_USE_SVT_PEER
    peer_profiles = pcie_svt_profile_set::type_id::create("peer_profiles");
    peer_profiles.build_peer_for_topology(topology, pcie_gen);
    for (int unsigned i = PCIE_SVT_PEER_PORT0;
         i <= PCIE_SVT_PEER_PORT4; i++)
      if (peer_profiles.port[i] != null)
        profiles.port[i] = peer_profiles.port[i];
`elsif PCIE_USE_SVT_SWITCH_PROXY
    peer_profiles = pcie_svt_profile_set::type_id::create("proxy_profiles");
    peer_profiles.build_peer_for_topology(topology, pcie_gen);
    for (int unsigned i = PCIE_SVT_PEER_PORT0;
         i <= PCIE_SVT_PEER_PORT4; i++)
      if (peer_profiles.port[i] != null)
        profiles.port[i] = peer_profiles.port[i];
`endif
    vseqr = pcie_svt_virtual_sequencer::type_id::create("vseqr", this);
    if (topology == PCIE_SVT_TOPO_SWITCH) begin
      switch_enum_registry =
        pcie_svt_switch_enum_registry::type_id::create(
          "switch_enum_registry");
`ifndef PCIE_USE_SVT_SWITCH_PROXY
      if (switch_enum_registry == null)
        `uvm_fatal("SWITCH_ENUM_REGISTRY_CREATE",
          "switch enumeration registry creation failed")
`endif
    end

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
      uvm_config_db#(bit)::set(
        this, $sformatf("port[%0d]", i), "fast_link_training",
        fast_link_training);
      is_switch_proxy = 1'b0;
`ifdef PCIE_USE_SVT_SWITCH_PROXY
      is_switch_proxy = (i >= PCIE_SVT_PEER_PORT0);
`endif
      uvm_config_db#(bit)::set(
        this, $sformatf("port[%0d]", i), "is_switch_proxy",
        is_switch_proxy);
      port[i] = pcie_svt_port_env::type_id::create(
        $sformatf("port[%0d]", i), this);
    end

`ifdef PCIE_USE_SVT_SWITCH_PROXY
    if (!uvm_config_db#(bit)::get(
          this, "", "disable_switch_sidecars", disable_switch_sidecars))
      disable_switch_sidecars = 1'b0;
    if (!uvm_config_db#(bit)::get(
          this, "", "enumeration_mode", enumeration_mode))
      enumeration_mode = 1'b0;

    switch_cfg = pcie_tl_switch_config::type_id::create("switch_cfg");
    if (switch_cfg == null)
      `uvm_fatal("SWITCH_PROXY_CREATE",
        "switch configuration creation failed")
    switch_cfg.num_usp = 1;
    switch_cfg.num_ds_ports = 4;
    switch_cfg.enum_mode = 1'b1;
    switch_cfg.p2p_enable = 1'b0;
    switch_cfg.init_defaults();
    switch_core = pcie_tl_switch::type_id::create("switch_core", this);
    if (switch_core == null)
      `uvm_fatal("SWITCH_PROXY_CREATE", "switch core creation failed")
    switch_core.sw_cfg = switch_cfg;
    switch_scoreboard = pcie_svt_switch_scoreboard::type_id::create(
      "switch_scoreboard", this);
    if ((switch_scoreboard == null) || (switch_enum_registry == null))
      `uvm_fatal("SWITCH_PROXY_CREATE",
        "switch scoreboard/enum-registry creation failed")

    for (int unsigned i = 0; i < 5; i++) begin
      switch_adapter[i] = pcie_svt_switch_port_adapter::type_id::create(
        $sformatf("switch_adapter[%0d]", i), this);
      switch_target_callback[i] =
        pcie_svt_switch_target_callback::type_id::create(
          $sformatf("switch_target_callback[%0d]", i));
      if ((switch_adapter[i] == null) ||
          (switch_target_callback[i] == null))
        `uvm_fatal("SWITCH_PROXY_CREATE", $sformatf(
          "port=%0d adapter/callback creation failed", i))
      switch_adapter[i].port_index = i;
      switch_target_callback[i].adapter = switch_adapter[i];
    end

    if (disable_switch_sidecars) begin
      `uvm_info("SWITCH_SIDECARS_DISABLED_LINK_ONLY",
        "all five passive switch sidecars are disabled", UVM_NONE)
    end else begin
      for (int unsigned i = 0; i < 5; i++) begin
        int unsigned lanes;
        string sidecar_vif_key;
        lanes = (i == 0) ? 16 : 4;
        sidecar_vif_key = (i == 0) ? "proxy_usp_sidecar_vif" :
          $sformatf("proxy_dsp%0d_sidecar_vif", i-1);
        uvm_config_db#(int unsigned)::set(
          this, $sformatf("switch_sidecar[%0d]", i), "lanes", lanes);
        uvm_config_db#(int unsigned)::set(
          this, $sformatf("switch_sidecar[%0d]", i), "pcie_gen", pcie_gen);
        uvm_config_db#(int)::set(
          this, $sformatf("switch_sidecar[%0d]", i), "port_index", i);
        uvm_config_db#(bit)::set(
          this, $sformatf("switch_sidecar[%0d]", i),
          "apply_star_9000762979", enumeration_mode);
        uvm_config_db#(pcie_svt_switch_port_adapter)::set(
          this, $sformatf("switch_sidecar[%0d]", i), "adapter",
          switch_adapter[i]);
        uvm_config_db#(pcie_svt_switch_scoreboard)::set(
          this, $sformatf("switch_sidecar[%0d]", i), "scoreboard",
          switch_scoreboard);
        if (lanes == 16) begin
          if (!uvm_config_db#(
                svt_pcie_configuration::svt_pcie_serdes_x16_vif)::get(
                null, "uvm_test_top", sidecar_vif_key, sidecar_x16_vif) ||
              (sidecar_x16_vif == null))
            `uvm_fatal("SIDECAR_VIF", $sformatf(
              "missing x16 sidecar VIF key '%s'", sidecar_vif_key))
          uvm_config_db#(
            svt_pcie_configuration::svt_pcie_serdes_x16_vif)::set(
            this, $sformatf("switch_sidecar[%0d]", i),
            "serdes_x16_vif", sidecar_x16_vif);
        end else begin
          if (!uvm_config_db#(
                svt_pcie_configuration::svt_pcie_serdes_x4_vif)::get(
                null, "uvm_test_top", sidecar_vif_key, sidecar_x4_vif) ||
              (sidecar_x4_vif == null))
            `uvm_fatal("SIDECAR_VIF", $sformatf(
              "missing x4 sidecar VIF key '%s'", sidecar_vif_key))
          uvm_config_db#(
            svt_pcie_configuration::svt_pcie_serdes_x4_vif)::set(
            this, $sformatf("switch_sidecar[%0d]", i),
            "serdes_x4_vif", sidecar_x4_vif);
        end
        switch_sidecar_service_port[i] = new(
          $sformatf("switch_sidecar_service_port[%0d]", i), this);
        switch_sidecar[i] = pcie_svt_switch_sidecar_env::type_id::create(
          $sformatf("switch_sidecar[%0d]", i), this);
        if ((switch_sidecar_service_port[i] == null) ||
            (switch_sidecar[i] == null))
          `uvm_fatal("SWITCH_PROXY_CREATE", $sformatf(
            "port=%0d sidecar/service-port creation failed", i))
      end
    end
`else
    disable_switch_sidecars = 1'b1;
`endif
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
      vseqr.switch_proxy_port[i] = port[i].is_switch_proxy;
      `uvm_info("PCIE_SVT_PORT_ACTIVE", $sformatf(
        "index=%0d profile=%s agent=%s", i, port[i].profile.port_id,
        port[i].agent.get_full_name()), UVM_LOW)
    end

    if (topology == PCIE_SVT_TOPO_SWITCH)
      vseqr.switch_enum_registry = switch_enum_registry;

`ifdef PCIE_USE_SVT_SWITCH_PROXY
    if ((switch_core == null) || (switch_core.all_ports.size() != 5))
      `uvm_fatal("SWITCH_PROXY_CONNECT",
        "switch core does not expose exactly five ports")
    vseqr.switch_core = switch_core;
    vseqr.switch_scoreboard = switch_scoreboard;
    if ((switch_core.route_observed_port == null) ||
        (switch_scoreboard == null) ||
        (switch_scoreboard.route_event_export == null))
      `uvm_fatal("SWITCH_ROUTE_OBSERVER_CONNECT",
        "switch route observation port/export handle is missing")
    switch_core.route_observed_port.connect(
      switch_scoreboard.route_event_export);
    for (int unsigned i = 0; i < 5; i++) begin
      int unsigned proxy_index;
      proxy_index = PCIE_SVT_PEER_PORT0 + i;
      if ((port[proxy_index] == null) ||
          (port[proxy_index].agent == null) ||
          (port[proxy_index].agent.pcie_agent == null) ||
          (port[proxy_index].agent.pcie_agent.tlp_seqr == null) ||
          !port[proxy_index].agent.target.exists(0) ||
          (port[proxy_index].agent.target[0] == null))
        `uvm_fatal("SWITCH_PROXY_CONNECT", $sformatf(
          "Proxy port=%0d has incomplete public TLP/Target handles", i))
      switch_adapter[i].switch_port = switch_core.all_ports[i];
      switch_adapter[i].proxy_tlp_seqr =
        port[proxy_index].agent.pcie_agent.tlp_seqr;
      vseqr.switch_adapter[i] = switch_adapter[i];
      uvm_callbacks#(svt_pcie_target_app,
        svt_pcie_target_app_callback)::add(
          port[proxy_index].agent.target[0], switch_target_callback[i]);

      vseqr.switch_sidecar[i] = switch_sidecar[i];
      vseqr.switch_sidecar_service_port[i] =
        switch_sidecar_service_port[i];
      vseqr.switch_sidecar_enabled[i] = !disable_switch_sidecars;
      if (!disable_switch_sidecars) begin
        if ((switch_sidecar[i] == null) ||
            (switch_sidecar[i].cfg == null) ||
            (switch_sidecar[i].agent == null) ||
            (switch_sidecar[i].agent.tl_mon == null) ||
            (switch_sidecar[i].rx_subscriber == null) ||
            (switch_sidecar[i].tx_subscriber == null) ||
            (switch_sidecar[i].rx_subscriber.adapter != switch_adapter[i]) ||
            (switch_sidecar[i].tx_subscriber.adapter != switch_adapter[i]) ||
            (switch_sidecar[i].rx_subscriber.scoreboard != switch_scoreboard) ||
            (switch_sidecar[i].tx_subscriber.scoreboard != switch_scoreboard) ||
            (switch_sidecar[i].rx_subscriber.role != PCIE_SVT_SIDECAR_RX) ||
            (switch_sidecar[i].tx_subscriber.role != PCIE_SVT_SIDECAR_TX))
          `uvm_fatal("SIDECAR_CONNECT", $sformatf(
            "port=%0d passive monitor/subscriber ownership is incomplete", i))
        if (!switch_sidecar[i].cfg.enable_monitor)
          `uvm_fatal("SWITCH_PASSIVE_MONITOR", $sformatf(
            "port=%0d standalone sidecar monitor is disabled", i))
        switch_sidecar_service_port[i].connect(
          switch_sidecar[i].agent.tl_mon.tl_service_in_port);
      end
    end
`endif
  endfunction

  virtual function void end_of_elaboration_phase(uvm_phase phase);
    super.end_of_elaboration_phase(phase);
`ifdef PCIE_USE_SVT_SWITCH_PROXY
    if ((switch_core == null) ||
        (switch_core.route_observed_port == null) ||
        (switch_core.route_observed_port.size() != 1))
      `uvm_fatal("SWITCH_ROUTE_OBSERVER_CONNECT", $sformatf(
        "switch route observer connection count=%0d expected=1",
        ((switch_core == null) ||
         (switch_core.route_observed_port == null)) ? 0 :
          switch_core.route_observed_port.size()))
    if (!disable_switch_sidecars) begin
      for (int unsigned i = 0; i < 5; i++) begin
        if ((switch_sidecar[i] == null) ||
            (switch_sidecar[i].cfg == null) ||
            (switch_sidecar[i].agent == null) ||
            (switch_sidecar[i].agent.tl_mon == null) ||
            (switch_sidecar[i].agent.tl_mon.rx_tlp_observed_port == null) ||
            (switch_sidecar[i].agent.tl_mon.tx_tlp_observed_port == null) ||
            (switch_sidecar[i].agent.tl_mon.tl_service_in_port == null) ||
            (switch_sidecar[i].agent.tl_mon.
               rx_tlp_observed_port.size() != 1) ||
            (switch_sidecar[i].agent.tl_mon.
               tx_tlp_observed_port.size() != 1) ||
            (switch_sidecar_service_port[i] == null) ||
            (switch_sidecar_service_port[i].size() != 1))
          `uvm_fatal("SIDECAR_CONNECT", $sformatf(
            "port=%0d resolved RX/TX/service analysis connections are incomplete",
            i))
      end
    end
`endif
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
