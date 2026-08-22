class pcie_svt_switch_sidecar_env extends uvm_env;
  `uvm_component_utils(pcie_svt_switch_sidecar_env)

  svt_pcie_configuration::svt_pcie_serdes_x16_vif serdes_x16_vif;
  svt_pcie_configuration::svt_pcie_serdes_x4_vif serdes_x4_vif;
  int unsigned lanes;
  int unsigned pcie_gen;
  int port_index = -1;
  bit apply_star_9000762979;
  bit star_9000762979_applied;

  svt_pcie_configuration cfg;
  svt_pcie_agent agent;
  pcie_svt_switch_sidecar_subscriber rx_subscriber;
  pcie_svt_switch_sidecar_subscriber tx_subscriber;

  // Task 8-11 owners inject these before build. Keeping the handles public
  // makes the sidecar's runtime data path explicit and independently auditable.
  pcie_svt_switch_port_adapter adapter;
  pcie_svt_switch_scoreboard scoreboard;

  function new(string name = "pcie_svt_switch_sidecar_env",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  static function void configure_monitor_role(
      svt_pcie_configuration role_cfg,
      int role_port_index);
    uvm_root report_root;

    report_root = uvm_root::get();
    if (role_cfg == null) begin
      `uvm_fatal_context("SIDECAR_ROLE_POLICY", "direct role cfg is null",
                         report_root)
      return;
    end
    if ((role_port_index < 0) || (role_port_index >= 5)) begin
      `uvm_fatal_context("SIDECAR_ROLE_POLICY", $sformatf(
        "invalid switch sidecar port=%0d (expected 0 through 4)",
        role_port_index), report_root)
      return;
    end
    role_cfg.tl_cfg.is_switch = 1'b1;
    role_cfg.tl_cfg.is_tx_downstream = (role_port_index != 0);
    role_cfg.pl_cfg.is_tx_downstream = (role_port_index != 0);
    role_cfg.tl_cfg.cfg_space_mode =
      svt_pcie_tl_configuration::CFG_SPACE_ENUMERATION_UPDATE;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    bit [31:0] selected_speed;
    bit [31:0] supported_speeds;
    bit [31:0] supported_widths;
    bit got_x16;
    bit got_x4;

    super.build_phase(phase);
    apply_star_9000762979 = 1'b0;
    star_9000762979_applied = 1'b0;
    void'(uvm_config_db#(bit)::get(
      this, "", "apply_star_9000762979", apply_star_9000762979));
    if (!uvm_config_db#(int unsigned)::get(this, "", "lanes", lanes))
      `uvm_fatal("SIDECAR_CFG", {get_full_name(), ": missing lanes"})
    if (!uvm_config_db#(int unsigned)::get(
          this, "", "pcie_gen", pcie_gen) ||
        !((pcie_gen == 4) || (pcie_gen == 5)))
      `uvm_fatal("SIDECAR_CFG", $sformatf(
        "%s: missing or invalid pcie_gen=%0d (expected 4 or 5)",
        get_full_name(), pcie_gen))
    if (!uvm_config_db#(int)::get(this, "", "port_index", port_index) ||
        (port_index < 0))
      `uvm_fatal("SIDECAR_CFG",
                 {get_full_name(), ": missing or invalid port_index"})

    got_x16 = uvm_config_db#(
      svt_pcie_configuration::svt_pcie_serdes_x16_vif)::get(
      this, "", "serdes_x16_vif", serdes_x16_vif);
    got_x4 = uvm_config_db#(
      svt_pcie_configuration::svt_pcie_serdes_x4_vif)::get(
      this, "", "serdes_x4_vif", serdes_x4_vif);
    if ((got_x16 && got_x4) || (!got_x16 && !got_x4) ||
        (got_x16 && (serdes_x16_vif == null)) ||
        (got_x4 && (serdes_x4_vif == null)))
      `uvm_fatal("SIDECAR_VIF", $sformatf(
        "%s: exactly one non-null width VIF is required",
        get_full_name()))
    if (((lanes == 16) && !got_x16) || ((lanes == 4) && !got_x4) ||
        !((lanes == 16) || (lanes == 4)))
      `uvm_fatal("SIDECAR_WIDTH", $sformatf(
        "%s: lanes=%0d must select only its width-matched VIF",
        get_full_name(), lanes))

    if (!uvm_config_db#(pcie_svt_switch_port_adapter)::get(
          this, "", "adapter", adapter) || (adapter == null))
      `uvm_fatal("SIDECAR_ADAPTER",
                 {get_full_name(), ": missing adapter injection"})
    if (!uvm_config_db#(pcie_svt_switch_scoreboard)::get(
          this, "", "scoreboard", scoreboard) || (scoreboard == null))
      `uvm_fatal("SIDECAR_SCOREBOARD",
                 {get_full_name(), ": missing scoreboard injection"})

    cfg = svt_pcie_configuration::type_id::create("cfg");
    if (cfg == null)
      `uvm_fatal("SIDECAR_CREATE",
                 {get_full_name(), ": direct configuration creation failed"})

    supported_widths = (lanes == 16) ? 32'h0000_003f : 32'h0000_0007;
    cfg.pl_cfg.set_link_width_values(lanes, supported_widths, lanes);
    if ((cfg.pl_cfg.get_link_width_value() != lanes) ||
        (cfg.pl_cfg.get_supported_link_width_vector_value() !=
         supported_widths) ||
        (cfg.pl_cfg.get_expected_link_width_value() != lanes))
      `uvm_fatal("SIDECAR_LINK_WIDTH", $sformatf(
        "%s: failed to configure x%0d supported=0x%0h",
        get_full_name(), lanes, supported_widths))

    supported_speeds = `SVT_PCIE_SPEED_2_5G |
                       `SVT_PCIE_SPEED_5_0G |
                       `SVT_PCIE_SPEED_8_0G |
                       `SVT_PCIE_SPEED_16_0G;
    selected_speed = `SVT_PCIE_SPEED_16_0G;
    if (pcie_gen == 5) begin
      supported_speeds |= `SVT_PCIE_SPEED_32_0G;
      selected_speed = `SVT_PCIE_SPEED_32_0G;
    end
    cfg.pl_cfg.set_link_speed_values(
      supported_speeds, selected_speed, selected_speed);
    if ((cfg.pl_cfg.get_supported_link_speeds_value() !=
         supported_speeds) ||
        (cfg.pl_cfg.get_target_link_speed_value() !=
         selected_speed) ||
        (cfg.pl_cfg.get_expected_link_speed_value() !=
         selected_speed))
      `uvm_fatal("SIDECAR_LINK_SPEED", $sformatf(
        "%s: failed to configure Gen%0d speed vector=0x%0h",
        get_full_name(), pcie_gen, supported_speeds))

    cfg.enable_monitor = 1'b1;
    configure_monitor_role(cfg, port_index);
    if (lanes == 16)
      cfg.serdes_x16_if = serdes_x16_vif;
    else
      cfg.serdes_x4_if = serdes_x4_vif;

    uvm_config_db#(svt_pcie_configuration)::set(
      this, "agent", "cfg", cfg);
    uvm_config_db#(uvm_active_passive_enum)::set(
      this, "agent", "is_active", UVM_PASSIVE);
    agent = svt_pcie_agent::type_id::create("agent", this);
    rx_subscriber = pcie_svt_switch_sidecar_subscriber::type_id::create(
      "rx_subscriber", this);
    tx_subscriber = pcie_svt_switch_sidecar_subscriber::type_id::create(
      "tx_subscriber", this);
    if ((agent == null) || (rx_subscriber == null) ||
        (tx_subscriber == null))
      `uvm_fatal("SIDECAR_CREATE",
                 {get_full_name(), ": agent/subscriber creation failed"})

    rx_subscriber.port_index = port_index;
    rx_subscriber.role = PCIE_SVT_SIDECAR_RX;
    rx_subscriber.adapter = adapter;
    rx_subscriber.scoreboard = scoreboard;
    tx_subscriber.port_index = port_index;
    tx_subscriber.role = PCIE_SVT_SIDECAR_TX;
    tx_subscriber.adapter = adapter;
    tx_subscriber.scoreboard = scoreboard;
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    int disabled_count;

    super.connect_phase(phase);
    if ((cfg == null) || (agent == null) || (agent.tl_mon == null))
      `uvm_fatal("SIDECAR_CONNECT",
                 {get_full_name(), ": cfg/agent/tl_mon handle is missing"})
    if (agent.get_is_active() != UVM_PASSIVE) begin
      `uvm_fatal("SIDECAR_ACTIVE_MODE", $sformatf(
        "port=%0d direct sidecar agent is not passive", port_index))
      return;
    end
    if (apply_star_9000762979) begin
      if (agent.err_check == null) begin
        `uvm_fatal("SWITCH_STAR_9000762979", $sformatf(
          "port=%0d sidecar err_check handle is missing", port_index))
        return;
      end
      disabled_count = agent.err_check.disable_checks(
        "PASSIVE_DL_TX", "FLOW_CTRL_INIT", "txn_06_01_16");
      if (disabled_count <= 0) begin
        `uvm_fatal("SWITCH_STAR_9000762979", $sformatf(
          "port=%0d STAR rule matched no enabled check", port_index))
        return;
      end
      star_9000762979_applied = 1'b1;
      `uvm_info("SWITCH_STAR_9000762979_APPLIED", $sformatf(
        "port=%0d rule=PASSIVE_DL_TX/FLOW_CTRL_INIT/txn_06_01_16",
        port_index), UVM_NONE)
    end
    if ((agent.tl_mon.rx_tlp_observed_port == null) ||
        (agent.tl_mon.tx_tlp_observed_port == null) ||
        (rx_subscriber == null) || (rx_subscriber.analysis_export == null) ||
        (tx_subscriber == null) || (tx_subscriber.analysis_export == null))
      `uvm_fatal("SIDECAR_CONNECT",
                 {get_full_name(), ": passive monitor port is missing"})

    agent.tl_mon.rx_tlp_observed_port.connect(rx_subscriber.analysis_export);
    agent.tl_mon.tx_tlp_observed_port.connect(tx_subscriber.analysis_export);
  endfunction
endclass
