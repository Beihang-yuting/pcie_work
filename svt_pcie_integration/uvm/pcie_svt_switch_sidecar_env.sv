class pcie_svt_switch_sidecar_env extends uvm_env;
  `uvm_component_utils(pcie_svt_switch_sidecar_env)

  svt_pcie_configuration::svt_pcie_serdes_x16_vif serdes_x16_vif;
  svt_pcie_configuration::svt_pcie_serdes_x4_vif serdes_x4_vif;
  int unsigned lanes;
  int unsigned pcie_gen;
  int port_index = -1;

  svt_pcie_device_configuration cfg;
  svt_pcie_device_status status;
  svt_pcie_device_agent agent;
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

  virtual function void build_phase(uvm_phase phase);
    bit [31:0] selected_speed;
    bit [31:0] supported_speeds;
    bit [31:0] supported_widths;
    bit got_x16;
    bit got_x4;

    super.build_phase(phase);
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

    cfg = svt_pcie_device_configuration::type_id::create("cfg", this);
    status = svt_pcie_device_status::type_id::create("status", this);
    if ((cfg == null) || (status == null))
      `uvm_fatal("SIDECAR_CREATE",
                 {get_full_name(), ": configuration/status creation failed"})

    cfg.pcie_spec_ver =
      svt_pcie_device_configuration::PCIE_SPEC_VER_5_0;
    supported_widths = (lanes == 16) ? 32'h0000_003f : 32'h0000_0007;
    cfg.pcie_cfg.pl_cfg.set_link_width_values(
      lanes, supported_widths, lanes);
    if ((cfg.pcie_cfg.pl_cfg.get_link_width_value() != lanes) ||
        (cfg.pcie_cfg.pl_cfg.get_supported_link_width_vector_value() !=
         supported_widths) ||
        (cfg.pcie_cfg.pl_cfg.get_expected_link_width_value() != lanes))
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
    cfg.pcie_cfg.pl_cfg.set_link_speed_values(
      supported_speeds, selected_speed, selected_speed);
    if ((cfg.pcie_cfg.pl_cfg.get_supported_link_speeds_value() !=
         supported_speeds) ||
        (cfg.pcie_cfg.pl_cfg.get_target_link_speed_value() !=
         selected_speed) ||
        (cfg.pcie_cfg.pl_cfg.get_expected_link_speed_value() !=
         selected_speed))
      `uvm_fatal("SIDECAR_LINK_SPEED", $sformatf(
        "%s: failed to configure Gen%0d speed vector=0x%0h",
        get_full_name(), pcie_gen, supported_speeds))

    cfg.is_active = 1'b0;
    cfg.device_is_root = (lanes == 4);
    cfg.pcie_cfg.enable_monitor = 1'b1;
    cfg.pcie_cfg.tl_cfg.cfg_space_mode =
      svt_pcie_tl_configuration::CFG_SPACE_BACKDOOR_UPDATE;
    if (lanes == 16)
      cfg.pcie_cfg.serdes_x16_if = serdes_x16_vif;
    else
      cfg.pcie_cfg.serdes_x4_if = serdes_x4_vif;

    uvm_config_db#(svt_pcie_device_configuration)::set(
      this, "agent", "cfg", cfg);
    uvm_config_db#(svt_pcie_device_status)::set(
      this, "agent", "shared_status", status);
    agent = svt_pcie_device_agent::type_id::create("agent", this);
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
    super.connect_phase(phase);
    if ((cfg == null) || (agent == null) || (agent.pcie_agent == null) ||
        (agent.pcie_agent.tl_mon == null))
      `uvm_fatal("SIDECAR_CONNECT",
                 {get_full_name(), ": cfg/agent/tl_mon handle is missing"})
    if ((agent.pcie_agent.tl_mon.rx_tlp_observed_port == null) ||
        (agent.pcie_agent.tl_mon.tx_tlp_observed_port == null) ||
        (rx_subscriber == null) || (rx_subscriber.analysis_export == null) ||
        (tx_subscriber == null) || (tx_subscriber.analysis_export == null))
      `uvm_fatal("SIDECAR_CONNECT",
                 {get_full_name(), ": passive monitor port is missing"})

    agent.pcie_agent.tl_mon.rx_tlp_observed_port.connect(
      rx_subscriber.analysis_export);
    agent.pcie_agent.tl_mon.tx_tlp_observed_port.connect(
      tx_subscriber.analysis_export);
  endfunction
endclass
