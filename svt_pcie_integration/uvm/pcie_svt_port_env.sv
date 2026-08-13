class pcie_svt_port_env extends uvm_env;
  svt_pcie_vif vif;
  pcie_svt_port_profile profile;
  svt_pcie_device_configuration cfg;
  svt_pcie_device_status status;
  svt_pcie_device_agent agent;

  `uvm_component_utils(pcie_svt_port_env)

  function new(string name = "pcie_svt_port_env",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void apply_profile_to_cfg(
      pcie_svt_port_profile port_profile,
      svt_pcie_device_configuration device_cfg);
    bit enable_ats;
    bit [31:0] supported_widths;
    bit [31:0] supported_speeds;
    bit [31:0] selected_speed;

    if ((port_profile == null) || (device_cfg == null))
      `uvm_fatal("PROFILE", "cannot apply a null port profile or configuration")
    if (!((port_profile.role == PCIE_SVT_RC) ||
          (port_profile.role == PCIE_SVT_EP)))
      `uvm_fatal("PROFILE", {port_profile.port_id, ": invalid port role"})
    if (!port_profile.validate())
      `uvm_fatal("PROFILE", {port_profile.port_id, ": invalid port profile"})

    device_cfg.pcie_spec_ver =
      svt_pcie_device_configuration::PCIE_SPEC_VER_5_0;
    case (port_profile.link_width)
      4: supported_widths = 32'h0000_0007;
      8: supported_widths = 32'h0000_000f;
      16: supported_widths = 32'h0000_003f;
      default: `uvm_fatal("PROFILE", {port_profile.port_id,
                                      ": unsupported link width"})
    endcase
    device_cfg.pcie_cfg.pl_cfg.set_link_width_values(
      port_profile.link_width, supported_widths, port_profile.link_width);
    if ((device_cfg.pcie_cfg.pl_cfg.get_link_width_value() !=
         port_profile.link_width) ||
        (device_cfg.pcie_cfg.pl_cfg.get_supported_link_width_vector_value() !=
         supported_widths) ||
        (device_cfg.pcie_cfg.pl_cfg.get_expected_link_width_value() !=
         port_profile.link_width))
      `uvm_fatal("LINK_WIDTH", $sformatf(
        "%s: failed to configure x%0d supported=0x%0h",
        port_profile.port_id, port_profile.link_width, supported_widths))
    `uvm_info("PCIE_SVT_LINK_WIDTH", $sformatf(
      "profile=%s max=x%0d supported=0x%0h expected=x%0d",
      port_profile.port_id,
      device_cfg.pcie_cfg.pl_cfg.get_link_width_value(),
      device_cfg.pcie_cfg.pl_cfg.get_supported_link_width_vector_value(),
      device_cfg.pcie_cfg.pl_cfg.get_expected_link_width_value()), UVM_LOW)

    supported_speeds = `SVT_PCIE_SPEED_2_5G |
                       `SVT_PCIE_SPEED_5_0G |
                       `SVT_PCIE_SPEED_8_0G |
                       `SVT_PCIE_SPEED_16_0G;
    selected_speed = `SVT_PCIE_SPEED_16_0G;
    if (port_profile.max_gen == 5) begin
      supported_speeds |= `SVT_PCIE_SPEED_32_0G;
      selected_speed = `SVT_PCIE_SPEED_32_0G;
    end
    device_cfg.pcie_cfg.pl_cfg.set_link_speed_values(
      supported_speeds, selected_speed, selected_speed);
    if ((device_cfg.pcie_cfg.pl_cfg.get_supported_link_speeds_value() !=
         supported_speeds) ||
        (device_cfg.pcie_cfg.pl_cfg.get_target_link_speed_value() !=
         selected_speed) ||
        (device_cfg.pcie_cfg.pl_cfg.get_expected_link_speed_value() !=
         selected_speed))
      `uvm_fatal("LINK_SPEED", $sformatf(
        "%s: failed to configure Gen%0d speed vector=0x%0h",
        port_profile.port_id, port_profile.max_gen, supported_speeds))
    `uvm_info("PCIE_SVT_LINK_SPEED", $sformatf(
      "profile=%s gen=%0d supported=0x%0h target=0x%0h expected=0x%0h",
      port_profile.port_id, port_profile.max_gen,
      device_cfg.pcie_cfg.pl_cfg.get_supported_link_speeds_value(),
      device_cfg.pcie_cfg.pl_cfg.get_target_link_speed_value(),
      device_cfg.pcie_cfg.pl_cfg.get_expected_link_speed_value()), UVM_LOW)

    if (port_profile.role == PCIE_SVT_EP)
      device_cfg.pcie_cfg.enable_multi_endpoint_mode = 1'b1;

    enable_ats = 1'b0;
    foreach (port_profile.functions[i])
      if ((port_profile.functions[i] != null) &&
          port_profile.functions[i].enable_ats)
        enable_ats = 1'b1;
    device_cfg.pcie_cfg.dut_capabilities.enable_ats_support = enable_ats;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db#(svt_pcie_vif)::get(this, "", "vif", vif) ||
        (vif == null))
      `uvm_fatal("PORT_CFG", {get_full_name(), ": missing or null vif"})
    if (!uvm_config_db#(pcie_svt_port_profile)::get(
          this, "", "profile", profile) || (profile == null))
      `uvm_fatal("PORT_CFG", {get_full_name(), ": missing or null profile"})

    cfg = svt_pcie_device_configuration::type_id::create("cfg", this);
    cfg.set_initial_values_via_unified_vif(1, vif);
    if (cfg.device_is_root != (profile.role == PCIE_SVT_RC))
      `uvm_fatal("PROFILE", $sformatf(
        "%s: profile role disagrees with Unified HDL device_is_root=%0d",
        profile.port_id, cfg.device_is_root))
    apply_profile_to_cfg(profile, cfg);
    status = svt_pcie_device_status::type_id::create("status", this);
    uvm_config_db#(svt_pcie_device_configuration)::set(
      this, "agent", "cfg", cfg);
    uvm_config_db#(svt_pcie_device_status)::set(
      this, "agent", "shared_status", status);
    agent = svt_pcie_device_agent::type_id::create("agent", this);
  endfunction
endclass
