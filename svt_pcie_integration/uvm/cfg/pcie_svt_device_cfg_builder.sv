class pcie_svt_device_cfg_builder extends uvm_object;
  `uvm_object_utils(pcie_svt_device_cfg_builder)

  function new(string name = "pcie_svt_device_cfg_builder");
    super.new(name);
  endfunction

  function void validate_descriptor(pcie_svt_port_descriptor descriptor);
    if (!((descriptor.role == PCIE_SVT_ROLE_RC) ||
          (descriptor.role == PCIE_SVT_ROLE_EP)))
      `uvm_fatal("SVT_DEVICE_CFG", $sformatf(
        "%s: role must be RC or EP", descriptor.link_id))
    if (!((descriptor.physical_width == 4) ||
          (descriptor.physical_width == 8) ||
          (descriptor.physical_width == 16)))
      `uvm_fatal("SVT_DEVICE_CFG", $sformatf(
        "%s: physical width must be x4, x8, or x16",
        descriptor.link_id))
    if (!((descriptor.link_width == 4) ||
          (descriptor.link_width == 8) ||
          (descriptor.link_width == 16)))
      `uvm_fatal("SVT_DEVICE_CFG", $sformatf(
        "%s: active width must be x4, x8, or x16",
        descriptor.link_id))
    if (descriptor.link_width > descriptor.physical_width)
      `uvm_fatal("SVT_DEVICE_CFG", $sformatf(
        "%s: active width x%0d exceeds physical width x%0d",
        descriptor.link_id, descriptor.link_width,
        descriptor.physical_width))
    if (!((descriptor.max_gen == 4) || (descriptor.max_gen == 5)))
      `uvm_fatal("SVT_DEVICE_CFG", $sformatf(
        "%s: max_gen must be Gen4 or Gen5", descriptor.link_id))
    if (descriptor.transport != PCIE_SVT_TRANSPORT_SERIAL)
      `uvm_fatal("SVT_DEVICE_CFG", $sformatf(
        "%s: only Serial transport is implemented", descriptor.link_id))
  endfunction

  function void apply(pcie_svt_port_descriptor descriptor,
                      svt_pcie_vif vif,
                      svt_pcie_device_configuration cfg);
    bit [31:0] selected_speed;
    bit [31:0] supported_speeds;
    bit [31:0] supported_widths;

    if (descriptor == null)
      `uvm_fatal("SVT_DEVICE_CFG", "cannot apply a null descriptor")
    if (vif == null)
      `uvm_fatal("SVT_DEVICE_CFG", "cannot apply a null Unified VIF")
    if (cfg == null)
      `uvm_fatal("SVT_DEVICE_CFG", "cannot apply to a null configuration")
    validate_descriptor(descriptor);

    cfg.set_initial_values_via_unified_vif(1, vif);
    if (cfg.device_is_root != (descriptor.role == PCIE_SVT_ROLE_RC))
      `uvm_fatal("SVT_DEVICE_CFG", $sformatf(
        "%s: descriptor role disagrees with Unified VIF device_is_root=%0d",
        descriptor.link_id, cfg.device_is_root))
    if (vif.num_physical_lanes != descriptor.physical_width)
      `uvm_fatal("SVT_DEVICE_CFG", $sformatf(
        "%s: descriptor physical width x%0d disagrees with Unified VIF lane count x%0d",
        descriptor.link_id, descriptor.physical_width,
        vif.num_physical_lanes))

    cfg.pcie_spec_ver = svt_pcie_device_configuration::PCIE_SPEC_VER_5_0;
    cfg.pcie_cfg.pl_cfg.disable_ext_bit_clock_mode = 1'b1;

    case (descriptor.link_width)
      4: supported_widths = 32'h0000_0007;
      8: supported_widths = 32'h0000_000f;
      16: supported_widths = 32'h0000_003f;
      default: supported_widths = 0;
    endcase
    cfg.pcie_cfg.pl_cfg.set_link_width_values(
      descriptor.link_width, supported_widths, descriptor.link_width);

    supported_speeds = `SVT_PCIE_SPEED_2_5G |
                       `SVT_PCIE_SPEED_5_0G |
                       `SVT_PCIE_SPEED_8_0G |
                       `SVT_PCIE_SPEED_16_0G;
    selected_speed = `SVT_PCIE_SPEED_16_0G;
    if (descriptor.max_gen == 5) begin
      supported_speeds |= `SVT_PCIE_SPEED_32_0G;
      selected_speed = `SVT_PCIE_SPEED_32_0G;
    end
    cfg.pcie_cfg.pl_cfg.set_link_speed_values(
      supported_speeds, selected_speed, selected_speed);

    if (descriptor.fast_link_training) begin
      if (descriptor.max_gen == 5)
        cfg.pcie_cfg.pl_cfg.set_link_eq_attribute_values(
          svt_pcie_pl_configuration::LINK_EQ_MODE_EQ_BYPASS_TO_HIGHEST_RATE,
          1'b0, 3);
      else
        cfg.pcie_cfg.pl_cfg.set_link_eq_attribute_values(
          svt_pcie_pl_configuration::LINK_EQ_MODE_FULL_EQUALIZATION_REQUIRED,
          1'b1, 3);
    end

    if (descriptor.role == PCIE_SVT_ROLE_EP) begin
      if (!cfg.target_cfg.exists(0))
        `uvm_fatal("SVT_DEVICE_CFG", $sformatf(
          "%s: Endpoint configuration has no target_cfg[0]",
          descriptor.link_id))
      if (cfg.target_cfg[0] == null)
        `uvm_fatal("SVT_DEVICE_CFG", $sformatf(
          "%s: Endpoint target_cfg[0] is null", descriptor.link_id))
      cfg.pcie_cfg.enable_multi_endpoint_mode = 1'b1;
      cfg.target_cfg[0].default_bar_ro_map = 32'h0000_ffff;
    end else begin
      cfg.pcie_cfg.enable_multi_endpoint_mode = 1'b0;
    end
  endfunction
endclass
