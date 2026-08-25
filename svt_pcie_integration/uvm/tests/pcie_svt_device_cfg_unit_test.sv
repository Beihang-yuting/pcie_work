import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_svt_topology_pkg::*;
import svt_uvm_pkg::*;
import svt_pcie_uvm_pkg::*;
`include "uvm_macros.svh"

class pcie_svt_counting_device_configuration extends
    svt_pcie_device_configuration;
  int unsigned initial_values_call_count;

  `uvm_object_utils(pcie_svt_counting_device_configuration)

  function new(string name = "pcie_svt_counting_device_configuration");
    super.new(name);
  endfunction

  virtual function void set_initial_values_via_unified_vif(
      bit is_active, svt_pcie_vif unified_if);
    initial_values_call_count++;
    super.set_initial_values_via_unified_vif(is_active, unified_if);
  endfunction
endclass

class pcie_svt_device_cfg_unit_test extends uvm_test;
  svt_pcie_vif rc_vif;
  svt_pcie_vif ep_vif;

  `uvm_component_utils(pcie_svt_device_cfg_unit_test)

  function new(string name = "pcie_svt_device_cfg_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void require(bit condition, string message);
    if (!condition)
      `uvm_error("SVT_DEVICE_CFG", message)
  endfunction

  function pcie_svt_port_descriptor make_descriptor(
      string name,
      pcie_svt_role_e role,
      int unsigned physical_width,
      int unsigned link_width,
      int unsigned max_gen,
      bit fast_link_training,
      int unsigned slot_index = 0);
    pcie_svt_port_descriptor descriptor;
    descriptor = pcie_svt_port_descriptor::type_id::create(name);
    descriptor.link_id = name;
    descriptor.svt_node_id = name;
    descriptor.vif_key = {name, "_vif"};
    descriptor.slot_index = slot_index;
    descriptor.root_hierarchy = slot_index;
    descriptor.role = role;
    descriptor.physical_width = physical_width;
    descriptor.link_width = link_width;
    descriptor.max_gen = max_gen;
    descriptor.fast_link_training = fast_link_training;
    descriptor.transport = PCIE_SVT_TRANSPORT_SERIAL;
    descriptor.cfg_timeout = 1ms;
    descriptor.link_timeout = 3ms;
    descriptor.enum_timeout = 3ms;
    descriptor.traffic_timeout = 1ms;
    return descriptor;
  endfunction

  function void configure_ep_bars(pcie_svt_port_descriptor descriptor);
    foreach (descriptor.ep_bars[i]) begin
      descriptor.ep_bars[i].implemented = 1'b0;
      descriptor.ep_bars[i].is_64bit = 1'b0;
      descriptor.ep_bars[i].prefetchable = 1'b0;
      descriptor.ep_bars[i].aperture = 0;
      descriptor.ep_bars[i].initial_base = 0;
    end
    foreach (descriptor.ep_bars[i]) begin
      if ((i == 0) || (i == 2) || (i == 4)) begin
        descriptor.ep_bars[i].implemented = 1'b1;
        descriptor.ep_bars[i].is_64bit = 1'b1;
        descriptor.ep_bars[i].prefetchable = 1'b1;
        descriptor.ep_bars[i].aperture =
          (i == 0) ? 64'd33554432 : 64'd65536;
      end
    end
  endfunction

  function bit [31:0] expected_width_vector(int unsigned link_width);
    case (link_width)
      4: return 32'h0000_0007;
      8: return 32'h0000_000f;
      16: return 32'h0000_003f;
      default: return 0;
    endcase
  endfunction

  function bit [31:0] expected_speed_vector(int unsigned max_gen);
    bit [31:0] speeds;
    speeds = `SVT_PCIE_SPEED_2_5G |
             `SVT_PCIE_SPEED_5_0G |
             `SVT_PCIE_SPEED_8_0G |
             `SVT_PCIE_SPEED_16_0G;
    if (max_gen == 5)
      speeds |= `SVT_PCIE_SPEED_32_0G;
    return speeds;
  endfunction

  function void check_apply_case(
      pcie_svt_device_cfg_builder builder,
      int unsigned link_width,
      int unsigned max_gen,
      bit fast_link_training);
    pcie_svt_port_descriptor descriptor;
    pcie_svt_counting_device_configuration cfg;
    svt_pcie_device_configuration normal_cfg;
    bit [31:0] selected_speed;
    bit normal_direct_speed_up;
    svt_pcie_pl_configuration::link_eq_mode_enum eq_mode;
    svt_pcie_pl_configuration::link_eq_mode_enum normal_eq_mode;
    string case_name;

    case_name = $sformatf("rc_x%0d_gen%0d_fast%0d",
                          link_width, max_gen, fast_link_training);
    descriptor = make_descriptor(case_name, PCIE_SVT_ROLE_RC, 16,
                                 link_width, max_gen,
                                 fast_link_training);
    cfg = pcie_svt_counting_device_configuration::type_id::create(
      {case_name, "_cfg"});
    if (!fast_link_training) begin
      normal_cfg = svt_pcie_device_configuration::type_id::create(
        {case_name, "_normal_cfg"});
      normal_cfg.set_initial_values_via_unified_vif(1, rc_vif);
      normal_eq_mode =
        normal_cfg.pcie_cfg.pl_cfg.get_link_eq_attribute_values();
      normal_direct_speed_up = normal_cfg.pcie_cfg.pl_cfg.
        enable_direct_speed_up_from_2_5g_to_16g;
    end
    builder.apply(descriptor, rc_vif, cfg);

    selected_speed = (max_gen == 5) ?
      `SVT_PCIE_SPEED_32_0G : `SVT_PCIE_SPEED_16_0G;
    require(cfg.initial_values_call_count == 1,
            {case_name, ": VIF initialization was not called exactly once"});
    require(cfg.device_is_root == 1'b1,
            {case_name, ": RC role was not preserved"});
    require(cfg.pcie_spec_ver ==
              svt_pcie_device_configuration::PCIE_SPEC_VER_5_0,
            {case_name, ": PCIe 5.0 configuration was not selected"});
    require(cfg.pcie_cfg.pl_cfg.disable_ext_bit_clock_mode == 1'b1,
            {case_name, ": internal bit clock mode was not selected"});
    require(cfg.pcie_cfg.pl_cfg.get_link_width_value() == link_width,
            {case_name, ": active link width is wrong"});
    require(cfg.pcie_cfg.pl_cfg.get_supported_link_width_vector_value() ==
              expected_width_vector(link_width),
            {case_name, ": supported link-width vector is wrong"});
    require(cfg.pcie_cfg.pl_cfg.get_expected_link_width_value() == link_width,
            {case_name, ": expected link width is wrong"});
    require(cfg.pcie_cfg.pl_cfg.get_supported_link_speeds_value() ==
              expected_speed_vector(max_gen),
            {case_name, ": supported link-speed vector is wrong"});
    require(cfg.pcie_cfg.pl_cfg.get_target_link_speed_value() ==
              selected_speed,
            {case_name, ": target link speed is wrong"});
    require(cfg.pcie_cfg.pl_cfg.get_expected_link_speed_value() ==
              selected_speed,
            {case_name, ": expected link speed is wrong"});
    require(cfg.pcie_cfg.enable_multi_endpoint_mode == 1'b0,
            {case_name, ": RC incorrectly enabled Multi-Endpoint Mode"});

    eq_mode = cfg.pcie_cfg.pl_cfg.get_link_eq_attribute_values();
    if (fast_link_training && (max_gen == 5)) begin
      require(eq_mode ==
        svt_pcie_pl_configuration::LINK_EQ_MODE_EQ_BYPASS_TO_HIGHEST_RATE,
        {case_name, ": Gen5 fast EQ mode is wrong"});
      require(cfg.pcie_cfg.pl_cfg.
                enable_direct_speed_up_from_2_5g_to_16g == 1'b0,
              {case_name, ": Gen5 fast path enabled Gen4 direct speed-up"});
    end else if (fast_link_training) begin
      require(eq_mode ==
        svt_pcie_pl_configuration::LINK_EQ_MODE_FULL_EQUALIZATION_REQUIRED,
        {case_name, ": Gen4 fast EQ mode is wrong"});
      require(cfg.pcie_cfg.pl_cfg.
                enable_direct_speed_up_from_2_5g_to_16g == 1'b1,
              {case_name, ": Gen4 fast direct speed-up setting is wrong"});
    end else begin
      require(eq_mode == normal_eq_mode,
              {case_name, ": non-fast EQ mode changed"});
      require(cfg.pcie_cfg.pl_cfg.
                enable_direct_speed_up_from_2_5g_to_16g ==
                normal_direct_speed_up,
              {case_name, ": non-fast direct speed-up setting changed"});
    end
  endfunction

  function void check_endpoint_apply(pcie_svt_device_cfg_builder builder);
    pcie_svt_port_descriptor descriptor;
    pcie_svt_counting_device_configuration cfg;

    descriptor = make_descriptor("ep_x4_gen5_fast1", PCIE_SVT_ROLE_EP,
                                 4, 4, 5, 1'b1, 3);
    configure_ep_bars(descriptor);
    cfg = pcie_svt_counting_device_configuration::type_id::create("ep_cfg");
    builder.apply(descriptor, ep_vif, cfg);

    require(cfg.initial_values_call_count == 1,
            "EP VIF initialization was not called exactly once");
    require(cfg.device_is_root == 1'b0,
            "EP role was not preserved");
    require(cfg.pcie_cfg.enable_multi_endpoint_mode == 1'b1,
            "EP did not enable Multi-Endpoint Mode");
    require(cfg.target_cfg.exists(0),
            "EP target_cfg[0] does not exist");
    if (cfg.target_cfg.exists(0)) begin
      require(cfg.target_cfg[0] != null,
              "EP target_cfg[0] is null");
      if (cfg.target_cfg[0] != null)
        require(cfg.target_cfg[0].default_bar_ro_map == 32'h0000_ffff,
                "EP target_cfg[0] default BAR RO map is wrong");
    end
  endfunction

  function void check_cfg_space_builder();
    pcie_svt_cfg_space_builder builder;
    pcie_svt_port_descriptor descriptor;
    pcie_svt_bar_cfg null_bar;
    bit [31:0] image[1024];
    bit [15:0] device_id;

    builder = pcie_svt_cfg_space_builder::type_id::create(
      "cfg_space_builder");
    require(builder.bar_ro_map(64'd33554432, 1'b0) == 32'h01ff_ffff,
            "32 MiB BAR low RO map is wrong");
    require(builder.bar_ro_map(64'd33554432, 1'b1) == 32'h0000_0000,
            "32 MiB BAR high RO map is wrong");
    require(builder.bar_ro_map(64'd65536, 1'b0) == 32'h0000_ffff,
            "64 KiB BAR low RO map is wrong");
    require(builder.bar_initial_value(null_bar, 1'b0) == 32'h0000_0000,
            "null BAR initial value is not zero");

    descriptor = make_descriptor("ep_pf0", PCIE_SVT_ROLE_EP,
                                 4, 4, 5, 1'b0, 3);
    configure_ep_bars(descriptor);
    foreach (image[i])
      image[i] = 32'ha5a5_a5a5;
    builder.build_ep_pf0(descriptor, image);
    device_id = 16'h5011 + descriptor.slot_index;

    require(builder.bar_initial_value(descriptor.ep_bars[0], 1'b0) ==
              32'h0000_000c,
            "BAR0 initial low DWORD is wrong");
    require(builder.bar_initial_value(descriptor.ep_bars[0], 1'b1) ==
              32'h0000_0000,
            "BAR0 initial high DWORD is wrong");
    require(image[0] == {device_id, 16'h20f9},
            "PF0 vendor/device DWORD is wrong");
    require(image[1] == 32'h0010_0000,
            "PF0 command/status DWORD is wrong");
    require(image[2] == 32'h0200_0000,
            "PF0 class/revision DWORD is wrong");
    require(image[3] == 32'h0000_0000,
            "PF0 header DWORD is wrong");
    require(image[4] == 32'h0000_000c && image[5] == 32'h0000_0000,
            "PF0 BAR0/BAR1 pair is wrong");
    require(image[6] == 32'h0000_000c && image[7] == 32'h0000_0000,
            "PF0 BAR2/BAR3 pair is wrong");
    require(image[8] == 32'h0000_000c && image[9] == 32'h0000_0000,
            "PF0 BAR4/BAR5 pair is wrong");
    require(image[11] == {device_id, 16'h20f9},
            "PF0 subsystem vendor/device DWORD is wrong");
    require(image[15] == 32'h0000_0100,
            "PF0 interrupt DWORD is wrong");
    foreach (image[i]) begin
      if (!((i <= 9) || (i == 11) || (i == 15)))
        require(image[i] == 32'h0000_0000,
                $sformatf("PF0 image DWORD %0d was not cleared", i));
    end
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(svt_pcie_vif)::get(
          this, "", "primary_rc0_vif", rc_vif) || (rc_vif == null))
      `uvm_fatal("SVT_DEVICE_CFG", "missing primary_rc0_vif")
    if (!uvm_config_db#(svt_pcie_vif)::get(
          this, "", "primary_ep0_vif", ep_vif) || (ep_vif == null))
      `uvm_fatal("SVT_DEVICE_CFG", "missing primary_ep0_vif")
  endfunction

  task run_phase(uvm_phase phase);
    pcie_svt_device_cfg_builder builder;
    int unsigned widths[3] = '{4, 8, 16};
    int unsigned generations[2] = '{4, 5};

    phase.raise_objection(this);
    builder = pcie_svt_device_cfg_builder::type_id::create(
      "device_cfg_builder");
    foreach (widths[w])
      foreach (generations[g]) begin
        check_apply_case(builder, widths[w], generations[g], 1'b0);
        check_apply_case(builder, widths[w], generations[g], 1'b1);
      end
    check_endpoint_apply(builder);
    check_cfg_space_builder();
    phase.drop_objection(this);
  endtask
endclass
