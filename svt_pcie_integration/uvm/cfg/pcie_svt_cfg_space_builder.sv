class pcie_svt_cfg_space_builder extends uvm_object;
  `uvm_object_utils(pcie_svt_cfg_space_builder)

  function new(string name = "pcie_svt_cfg_space_builder");
    super.new(name);
  endfunction

  function automatic bit [31:0] bar_ro_map(
      longint unsigned aperture,
      bit high_dword);
    bit [63:0] ro_map;

    if ((aperture < 16) || ((aperture & (aperture - 1)) != 0)) begin
      `uvm_fatal("SVT_BAR",
        "BAR aperture must be a power of two and at least 16 bytes")
      return 0;
    end
    ro_map = aperture - 1;
    return high_dword ? ro_map[63:32] : ro_map[31:0];
  endfunction

  function automatic bit [31:0] bar_initial_value(
      pcie_svt_bar_cfg bar,
      bit high_dword);
    bit [31:0] value;

    if ((bar == null) || !bar.implemented)
      return 0;
    if (high_dword)
      return bar.initial_base[63:32];
    value = bar.initial_base[31:0] & 32'hffff_fff0;
    value[2:1] = bar.is_64bit ? 2'b10 : 2'b00;
    value[3] = bar.prefetchable;
    return value;
  endfunction

  function void validate_ep_descriptor(
      pcie_svt_port_descriptor descriptor);
    if (descriptor.role != PCIE_SVT_ROLE_EP)
      `uvm_fatal("SVT_CFG_SPACE", $sformatf(
        "%s: PF0 image requires an Endpoint descriptor",
        descriptor.link_id))
    if (descriptor.slot_index > 16'hafee)
      `uvm_fatal("SVT_CFG_SPACE", $sformatf(
        "%s: slot index does not fit the PF0 device ID",
        descriptor.link_id))
    foreach (descriptor.ep_bars[i]) begin
      if (descriptor.ep_bars[i] == null)
        `uvm_fatal("SVT_CFG_SPACE", $sformatf(
          "%s: BAR%0d descriptor is null", descriptor.link_id, i))
      if ((i > 0) && descriptor.ep_bars[i-1].implemented &&
          descriptor.ep_bars[i-1].is_64bit &&
          descriptor.ep_bars[i].implemented)
        `uvm_fatal("SVT_CFG_SPACE", $sformatf(
          "%s: BAR%0d is the upper DWORD of BAR%0d",
          descriptor.link_id, i, i - 1))
      if (descriptor.ep_bars[i].implemented) begin
        void'(bar_ro_map(descriptor.ep_bars[i].aperture, 1'b0));
        if (descriptor.ep_bars[i].is_64bit && (i == 5))
          `uvm_fatal("SVT_CFG_SPACE", $sformatf(
            "%s: BAR5 cannot be the low DWORD of a 64-bit BAR",
            descriptor.link_id))
        if ((descriptor.ep_bars[i].initial_base &
             (descriptor.ep_bars[i].aperture - 1)) != 0)
          `uvm_fatal("SVT_CFG_SPACE", $sformatf(
            "%s: BAR%0d initial base is not aperture-aligned",
            descriptor.link_id, i))
      end
    end
  endfunction

  function void build_ep_pf0(
      pcie_svt_port_descriptor descriptor,
      ref bit [31:0] image[1024]);
    bit [15:0] device_id;

    foreach (image[i])
      image[i] = 0;
    if (descriptor == null)
      `uvm_fatal("SVT_CFG_SPACE",
                 "cannot build PF0 from a null descriptor")
    validate_ep_descriptor(descriptor);

    device_id = 16'h5011 + descriptor.slot_index;
    image[0] = {device_id, 16'h20f9};
    image[1] = 32'h0010_0000;
    image[2] = 32'h0200_0000;
    image[3] = 32'h0000_0000;
    for (int unsigned i = 0; i < 6; i++) begin
      if ((i > 0) && descriptor.ep_bars[i-1].implemented &&
          descriptor.ep_bars[i-1].is_64bit)
        image[4+i] = bar_initial_value(descriptor.ep_bars[i-1], 1'b1);
      else
        image[4+i] = bar_initial_value(descriptor.ep_bars[i], 1'b0);
    end
    image[11] = {device_id, 16'h20f9};
    image[15] = 32'h0000_0100;
  endfunction
endclass
