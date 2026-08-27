import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_svt_topology_pkg::*;
import svt_uvm_pkg::*;
import svt_pcie_uvm_pkg::*;
`include "uvm_macros.svh"

class pcie_svt_expected_fatal_catcher extends uvm_report_catcher;
  string expected_id;
  string last_message;
  int unsigned matched_count;

  `uvm_object_utils(pcie_svt_expected_fatal_catcher)

  function new(string name = "pcie_svt_expected_fatal_catcher");
    super.new(name);
  endfunction

  function void configure(string id);
    expected_id = id;
    last_message = "";
    matched_count = 0;
  endfunction

  function bit message_contains(string fragment);
    if ((fragment.len() == 0) || (last_message.len() < fragment.len()))
      return 0;
    for (int i = 0; i <= last_message.len() - fragment.len(); i++)
      if (last_message.substr(i, i + fragment.len() - 1) == fragment)
        return 1;
    return 0;
  endfunction

  virtual function action_e catch();
    if ((get_severity() == UVM_FATAL) && (get_id() == expected_id)) begin
      matched_count++;
      last_message = get_message();
      return CAUGHT;
    end
    return THROW;
  endfunction
endclass

class pcie_svt_counting_device_configuration extends
    svt_pcie_device_configuration;
  int unsigned initial_values_call_count;
  bit sentinel_target_present;

  `uvm_object_utils(pcie_svt_counting_device_configuration)

  function new(string name = "pcie_svt_counting_device_configuration");
    super.new(name);
  endfunction

  virtual function void set_initial_values_via_unified_vif(
      bit is_active, svt_pcie_vif unified_if);
    initial_values_call_count++;
    super.set_initial_values_via_unified_vif(is_active, unified_if);
    pcie_spec_ver = svt_pcie_device_configuration::PCIE_SPEC_VER_4_0;
    pcie_cfg.pl_cfg.disable_ext_bit_clock_mode = 1'b0;
    pcie_cfg.pl_cfg.set_link_width_values(4, 32'h0000_0007, 4);
    pcie_cfg.pl_cfg.set_link_speed_values(
      `SVT_PCIE_SPEED_2_5G,
      `SVT_PCIE_SPEED_2_5G,
      `SVT_PCIE_SPEED_2_5G);
    pcie_cfg.enable_multi_endpoint_mode = device_is_root;
    sentinel_target_present = target_cfg.exists(0) &&
                              (target_cfg[0] != null);
    if (sentinel_target_present)
      target_cfg[0].default_bar_ro_map = 32'hdead_beef;
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

  function void check_expected_fatal(
      pcie_svt_expected_fatal_catcher catcher,
      string label,
      string expected_fragment);
    require(catcher.matched_count == 1,
            $sformatf("%s: expected one caught fatal, observed %0d",
                      label, catcher.matched_count));
    require(catcher.message_contains(expected_fragment),
            $sformatf("%s: fatal message '%s' lacks '%s'",
                      label, catcher.last_message, expected_fragment));
  endfunction

  function void arm_expected_fatal(
      pcie_svt_expected_fatal_catcher catcher,
      string expected_id);
    catcher.configure(expected_id);
    uvm_report_cb::add(null, catcher);
  endfunction

  function void finish_cfg_fatal(
      pcie_svt_expected_fatal_catcher catcher,
      string label,
      string expected_fragment,
      ref bit [31:0] image[1024]);
    uvm_report_cb::delete(null, catcher);
    check_expected_fatal(catcher, label, expected_fragment);
    require(image_is(image, 32'ha5a5_a5a5),
            {label, ": rejected descriptor changed caller image"});
  endfunction

  function void fill_image(ref bit [31:0] image[1024],
                           input bit [31:0] value);
    foreach (image[i])
      image[i] = value;
  endfunction

  function bit image_is(ref bit [31:0] image[1024],
                        input bit [31:0] value);
    foreach (image[i])
      if (image[i] != value)
        return 0;
    return 1;
  endfunction

  function void check_policy_sentinel(
      pcie_svt_counting_device_configuration cfg,
      string label);
    require(cfg.pcie_spec_ver ==
              svt_pcie_device_configuration::PCIE_SPEC_VER_4_0,
            {label, ": PCIe spec sentinel changed"});
    require(cfg.pcie_cfg.pl_cfg.disable_ext_bit_clock_mode == 1'b0,
            {label, ": bit-clock sentinel changed"});
    require(cfg.pcie_cfg.pl_cfg.get_link_width_value() == 4 &&
            cfg.pcie_cfg.pl_cfg.get_supported_link_width_vector_value() ==
              32'h0000_0007 &&
            cfg.pcie_cfg.pl_cfg.get_expected_link_width_value() == 4,
            {label, ": link-width sentinel changed"});
    require(cfg.pcie_cfg.pl_cfg.get_supported_link_speeds_value() ==
              `SVT_PCIE_SPEED_2_5G &&
            cfg.pcie_cfg.pl_cfg.get_target_link_speed_value() ==
              `SVT_PCIE_SPEED_2_5G &&
            cfg.pcie_cfg.pl_cfg.get_expected_link_speed_value() ==
              `SVT_PCIE_SPEED_2_5G,
            {label, ": link-speed sentinel changed"});
    require(cfg.pcie_cfg.enable_multi_endpoint_mode == cfg.device_is_root,
            {label, ": Multi-Endpoint sentinel changed"});
    if (cfg.sentinel_target_present)
      require(cfg.target_cfg[0].default_bar_ro_map == 32'hdead_beef,
              {label, ": target BAR RO-map sentinel changed"});
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

  function void check_endpoint_apply(
      pcie_svt_device_cfg_builder builder,
      int unsigned max_gen,
      bit fast_link_training,
      pcie_svt_endpoint_model_e selected_model);
    pcie_svt_port_descriptor descriptor;
    pcie_svt_counting_device_configuration cfg;
    svt_pcie_device_configuration normal_cfg;
    bit [31:0] selected_speed;
    svt_pcie_pl_configuration::link_eq_mode_enum eq_mode;
    svt_pcie_pl_configuration::link_eq_mode_enum normal_eq_mode;
    bit normal_direct_speed_up;
    int unsigned ep_width;
    string case_name;

    ep_width = ep_vif.num_physical_lanes;
    case_name = $sformatf("ep_x%0d_gen%0d_fast%0d_%s",
                          ep_width, max_gen, fast_link_training,
                          selected_model.name());
    descriptor = make_descriptor(case_name, PCIE_SVT_ROLE_EP,
                                 ep_width, ep_width, max_gen,
                                 fast_link_training, 3);
    descriptor.endpoint_model = selected_model;
    configure_ep_bars(descriptor);
    cfg = pcie_svt_counting_device_configuration::type_id::create(
      {case_name, "_cfg"});
    if (!fast_link_training) begin
      normal_cfg = svt_pcie_device_configuration::type_id::create(
        {case_name, "_normal_cfg"});
      normal_cfg.set_initial_values_via_unified_vif(1, ep_vif);
      normal_eq_mode =
        normal_cfg.pcie_cfg.pl_cfg.get_link_eq_attribute_values();
      normal_direct_speed_up = normal_cfg.pcie_cfg.pl_cfg.
        enable_direct_speed_up_from_2_5g_to_16g;
    end
    builder.apply(descriptor, ep_vif, cfg);

    selected_speed = (max_gen == 5) ?
      `SVT_PCIE_SPEED_32_0G : `SVT_PCIE_SPEED_16_0G;
    require(cfg.initial_values_call_count == 1,
            {case_name, ": VIF initialization was not called exactly once"});
    require(cfg.device_is_root == 1'b0,
            {case_name, ": EP role was not preserved"});
    require(cfg.pcie_spec_ver ==
              svt_pcie_device_configuration::PCIE_SPEC_VER_5_0,
            {case_name, ": PCIe 5.0 configuration was not selected"});
    require(cfg.pcie_cfg.pl_cfg.disable_ext_bit_clock_mode == 1'b1,
            {case_name, ": internal bit clock mode was not selected"});
    require(cfg.pcie_cfg.pl_cfg.get_link_width_value() == ep_width &&
            cfg.pcie_cfg.pl_cfg.get_supported_link_width_vector_value() ==
              expected_width_vector(ep_width) &&
            cfg.pcie_cfg.pl_cfg.get_expected_link_width_value() == ep_width,
            {case_name, ": Endpoint width policy is wrong"});
    require(cfg.pcie_cfg.pl_cfg.get_supported_link_speeds_value() ==
              expected_speed_vector(max_gen) &&
            cfg.pcie_cfg.pl_cfg.get_target_link_speed_value() ==
              selected_speed &&
            cfg.pcie_cfg.pl_cfg.get_expected_link_speed_value() ==
              selected_speed,
            {case_name, ": Endpoint speed policy is wrong"});
    require(cfg.pcie_cfg.enable_multi_endpoint_mode ==
              (selected_model == PCIE_SVT_EP_MULTI_BDF),
            {case_name,
             ": Multi-Endpoint enable disagrees with descriptor"});
    require(cfg.target_cfg.exists(0),
            {case_name, ": EP target_cfg[0] does not exist"});
    if (cfg.target_cfg.exists(0)) begin
      require(cfg.target_cfg[0] != null,
              {case_name, ": EP target_cfg[0] is null"});
      if (cfg.target_cfg[0] != null) begin
        if (selected_model == PCIE_SVT_EP_MULTI_BDF)
          require(cfg.target_cfg[0].default_bar_ro_map == 32'h0000_ffff,
                  {case_name, ": EP target_cfg[0] BAR RO map is wrong"});
        else
          require(cfg.target_cfg[0].default_bar_ro_map == 32'hdead_beef,
                  {case_name,
                   ": Single-Endpoint mode changed target BAR RO map"});
      end
    end

    eq_mode = cfg.pcie_cfg.pl_cfg.get_link_eq_attribute_values();
    if (fast_link_training && (max_gen == 5)) begin
      require(eq_mode ==
        svt_pcie_pl_configuration::LINK_EQ_MODE_EQ_BYPASS_TO_HIGHEST_RATE,
        {case_name, ": Gen5 fast EQ mode is wrong"});
      require(cfg.pcie_cfg.pl_cfg.
                enable_direct_speed_up_from_2_5g_to_16g == 1'b0,
              {case_name, ": Gen5 enabled Gen4 direct speed-up"});
    end else if (fast_link_training) begin
      require(eq_mode ==
        svt_pcie_pl_configuration::LINK_EQ_MODE_FULL_EQUALIZATION_REQUIRED,
        {case_name, ": Gen4 fast EQ mode is wrong"});
      require(cfg.pcie_cfg.pl_cfg.
                enable_direct_speed_up_from_2_5g_to_16g == 1'b1,
              {case_name, ": Gen4 fast direct speed-up is wrong"});
    end else begin
      require(eq_mode == normal_eq_mode,
              {case_name, ": non-fast EQ mode changed"});
      require(cfg.pcie_cfg.pl_cfg.
                enable_direct_speed_up_from_2_5g_to_16g ==
                normal_direct_speed_up,
              {case_name, ": non-fast direct speed-up changed"});
    end
  endfunction

  function void check_device_mismatch_guards(
      pcie_svt_device_cfg_builder builder);
    pcie_svt_port_descriptor descriptor;
    pcie_svt_counting_device_configuration cfg;
    pcie_svt_expected_fatal_catcher catcher;

    descriptor = make_descriptor("role_mismatch", PCIE_SVT_ROLE_RC,
                                 4, 4, 5, 1'b1);
    cfg = pcie_svt_counting_device_configuration::type_id::create(
      "role_mismatch_cfg");
    catcher = pcie_svt_expected_fatal_catcher::type_id::create(
      "role_mismatch_catcher");
    catcher.configure("SVT_DEVICE_CFG");
    uvm_report_cb::add(null, catcher);
    builder.apply(descriptor, ep_vif, cfg);
    uvm_report_cb::delete(null, catcher);
    check_expected_fatal(catcher, "role mismatch",
                         "descriptor role disagrees");
    require(cfg.initial_values_call_count == 1,
            "role mismatch did not initialize from VIF exactly once");
    check_policy_sentinel(cfg, "role mismatch");

    descriptor = make_descriptor("lane_mismatch", PCIE_SVT_ROLE_RC,
                                 8, 4, 5, 1'b1);
    cfg = pcie_svt_counting_device_configuration::type_id::create(
      "lane_mismatch_cfg");
    catcher = pcie_svt_expected_fatal_catcher::type_id::create(
      "lane_mismatch_catcher");
    catcher.configure("SVT_DEVICE_CFG");
    uvm_report_cb::add(null, catcher);
    builder.apply(descriptor, rc_vif, cfg);
    uvm_report_cb::delete(null, catcher);
    check_expected_fatal(catcher, "lane mismatch",
                         "disagrees with Unified VIF lane count");
    require(cfg.initial_values_call_count == 1,
            "lane mismatch did not initialize from VIF exactly once");
    check_policy_sentinel(cfg, "lane mismatch");
  endfunction

  function void check_device_null_guards(
      pcie_svt_device_cfg_builder builder);
    pcie_svt_port_descriptor descriptor;
    pcie_svt_port_descriptor null_descriptor;
    pcie_svt_counting_device_configuration cfg;
    svt_pcie_device_configuration null_cfg;
    svt_pcie_vif null_vif;
    pcie_svt_expected_fatal_catcher catcher;

    catcher = pcie_svt_expected_fatal_catcher::type_id::create(
      "device_null_catcher");

    cfg = pcie_svt_counting_device_configuration::type_id::create(
      "null_descriptor_cfg");
    arm_expected_fatal(catcher, "SVT_DEVICE_CFG");
    builder.apply(null_descriptor, rc_vif, cfg);
    uvm_report_cb::delete(null, catcher);
    check_expected_fatal(catcher, "null descriptor",
                         "cannot apply a null descriptor");
    require(cfg.initial_values_call_count == 0,
            "null descriptor initialized the configuration");

    descriptor = make_descriptor("null_vif", PCIE_SVT_ROLE_RC,
                                 16, 16, 5, 1'b0);
    cfg = pcie_svt_counting_device_configuration::type_id::create(
      "null_vif_cfg");
    arm_expected_fatal(catcher, "SVT_DEVICE_CFG");
    builder.apply(descriptor, null_vif, cfg);
    uvm_report_cb::delete(null, catcher);
    check_expected_fatal(catcher, "null Unified VIF",
                         "cannot apply a null Unified VIF");
    require(cfg.initial_values_call_count == 0,
            "null Unified VIF initialized the configuration");

    arm_expected_fatal(catcher, "SVT_DEVICE_CFG");
    builder.apply(descriptor, rc_vif, null_cfg);
    uvm_report_cb::delete(null, catcher);
    check_expected_fatal(catcher, "null configuration",
                         "cannot apply to a null configuration");
  endfunction

  function void check_cfg_space_builder();
    pcie_svt_cfg_space_builder builder;
    pcie_svt_port_descriptor descriptor;
    pcie_svt_port_descriptor single_descriptor;
    pcie_svt_bar_cfg null_bar;
    bit [31:0] image[1024];
    bit [15:0] device_id;

    builder = pcie_svt_cfg_space_builder::type_id::create(
      "cfg_space_builder");
    descriptor = make_descriptor("single_ep_callback", PCIE_SVT_ROLE_RC,
                                 16, 16, 5, 1'b0);
    descriptor.endpoint_model = PCIE_SVT_EP_SINGLE;
    require(!pcie_svt_topology_env::requires_bar_sizing_callback(descriptor),
            "RC requested an Endpoint BAR callback");
    descriptor.role = PCIE_SVT_ROLE_EP;
    require(pcie_svt_topology_env::requires_bar_sizing_callback(descriptor),
            "Single Endpoint did not request a BAR callback");
    descriptor.endpoint_model = PCIE_SVT_EP_MULTI_BDF;
    require(!pcie_svt_topology_env::requires_bar_sizing_callback(descriptor),
            "Multiple-BDF Endpoint requested a Single-Endpoint callback");
    require(builder.bar_ro_map(64'd33554432, 1'b0) == 32'h01ff_ffff,
            "32 MiB BAR low RO map is wrong");
    require(builder.bar_ro_map(64'd33554432, 1'b1) == 32'h0000_0000,
            "32 MiB BAR high RO map is wrong");
    require(builder.bar_ro_map(64'd65536, 1'b0) == 32'h0000_ffff,
            "64 KiB BAR low RO map is wrong");
    require(builder.bar_ro_map(64'd65536, 1'b1) == 32'h0000_0000,
            "64 KiB BAR high RO map is wrong");
    require(builder.bar_ro_map(64'h0000_0001_0000_0000, 1'b0) ==
              32'hffff_ffff,
            "4 GiB BAR low RO map is wrong");
    require(builder.bar_ro_map(64'h0000_0001_0000_0000, 1'b1) ==
              32'h0000_0000,
            "4 GiB BAR high RO map is wrong");
    require(builder.bar_initial_value(null_bar, 1'b0) == 32'h0000_0000,
            "null BAR initial value is not zero");

    single_descriptor = make_descriptor(
      "single_ep_pf0", PCIE_SVT_ROLE_EP, 16, 16, 5, 1'b0, 0);
    single_descriptor.endpoint_model = PCIE_SVT_EP_SINGLE;
    configure_ep_bars(single_descriptor);
    builder.build_ep_pf0(single_descriptor, image);
    require(builder.bar_sizing_value(
              single_descriptor.ep_bars[0], 1'b0) == 32'hfe00_000c,
            "32 MiB BAR sizing low DWORD is wrong");
    require(builder.bar_sizing_value(
              single_descriptor.ep_bars[0], 1'b1) == 32'hffff_ffff,
            "32 MiB BAR sizing high DWORD is wrong");
    require(builder.bar_sizing_value(
              single_descriptor.ep_bars[2], 1'b0) == 32'hffff_000c,
            "64 KiB BAR sizing low DWORD is wrong");
    require(image['h010/4] == 32'h0000_000c &&
            image['h014/4] == 32'h0000_0000,
            "PF0 BAR0/1 initial pair is wrong");
    require(image['h018/4] == 32'h0000_000c &&
            image['h01c/4] == 32'h0000_0000,
            "PF0 BAR2/3 initial pair is wrong");
    require(image['h020/4] == 32'h0000_000c &&
            image['h024/4] == 32'h0000_0000,
            "PF0 BAR4/5 initial pair is wrong");
    require(image['h034/4] == 32'h0000_0040,
            "PF0 Capability Pointer is wrong");
    require(image['h040/4] == 32'h0002_0010,
            "PF0 PCI Express Capability header is wrong");
    require(image['h04c/4][9:4] == single_descriptor.link_width &&
            image['h04c/4][3:0] == single_descriptor.max_gen,
            "PF0 Link Capabilities width/generation is wrong");
    require(image['h100/4] == 32'h0000_0000,
            "PF0 extended capability chain is not terminated");

    descriptor = make_descriptor("ep_pf0", PCIE_SVT_ROLE_EP,
                                 4, 4, 5, 1'b0, 3);
    descriptor.endpoint_model = PCIE_SVT_EP_MULTI_BDF;
    descriptor.ep_bars[0].implemented = 1'b1;
    descriptor.ep_bars[0].is_64bit = 1'b1;
    descriptor.ep_bars[0].prefetchable = 1'b1;
    descriptor.ep_bars[0].aperture = 64'd65536;
    descriptor.ep_bars[0].initial_base = 64'h0000_0001_2345_0000;
    descriptor.ep_bars[2].implemented = 1'b1;
    descriptor.ep_bars[2].is_64bit = 1'b0;
    descriptor.ep_bars[2].prefetchable = 1'b0;
    descriptor.ep_bars[2].aperture = 64'h0000_0000_0100_0000;
    descriptor.ep_bars[2].initial_base = 64'h0000_0000_8000_0000;
    descriptor.ep_bars[4].implemented = 1'b1;
    descriptor.ep_bars[4].is_64bit = 1'b0;
    descriptor.ep_bars[4].prefetchable = 1'b0;
    descriptor.ep_bars[4].aperture = 64'h0000_0001_0000_0000;
    descriptor.ep_bars[4].initial_base = 0;
    fill_image(image, 32'ha5a5_a5a5);
    builder.build_ep_pf0(descriptor, image);
    device_id = 16'h5011 + descriptor.slot_index;

    require(builder.bar_initial_value(descriptor.ep_bars[0], 1'b0) ==
              32'h2345_000c,
            "BAR0 initial low DWORD is wrong");
    require(builder.bar_initial_value(descriptor.ep_bars[0], 1'b1) ==
              32'h0000_0001,
            "BAR0 initial high DWORD is wrong");
    require(builder.bar_initial_value(descriptor.ep_bars[2], 1'b0) ==
              32'h8000_0000,
            "32-bit non-prefetchable BAR2 attributes are wrong");
    require(builder.bar_initial_value(descriptor.ep_bars[4], 1'b0) ==
              32'h0000_0000,
            "4 GiB BAR4 base/attributes are wrong");
    require(image[0] == {device_id, 16'h20f9},
            "PF0 vendor/device DWORD is wrong");
    require(image[1] == 32'h0010_0000,
            "PF0 command/status DWORD is wrong");
    require(image[2] == 32'h0200_0000,
            "PF0 class/revision DWORD is wrong");
    require(image[3] == 32'h0000_0000,
            "PF0 header DWORD is wrong");
    require(image[4] == 32'h2345_000c && image[5] == 32'h0000_0001,
            "PF0 BAR0/BAR1 pair is wrong");
    require(image[6] == 32'h8000_0000 && image[7] == 32'h0000_0000,
            "PF0 32-bit BAR2/BAR3 slots are wrong");
    require(image[8] == 32'h0000_0000 && image[9] == 32'h0000_0000,
            "PF0 4 GiB BAR4/BAR5 slots are wrong");
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

  function void check_cfg_space_rejections();
    pcie_svt_cfg_space_builder builder;
    pcie_svt_port_descriptor descriptor;
    pcie_svt_port_descriptor null_descriptor;
    pcie_svt_expected_fatal_catcher catcher;
    bit [31:0] image[1024];

    builder = pcie_svt_cfg_space_builder::type_id::create(
      "reject_cfg_space_builder");
    catcher = pcie_svt_expected_fatal_catcher::type_id::create(
      "cfg_space_fatal_catcher");

    descriptor = make_descriptor("invalid_aperture", PCIE_SVT_ROLE_EP,
                                 4, 4, 5, 1'b0);
    descriptor.ep_bars[0].implemented = 1'b1;
    descriptor.ep_bars[0].is_64bit = 1'b1;
    descriptor.ep_bars[0].aperture = 24;
    fill_image(image, 32'ha5a5_a5a5);
    arm_expected_fatal(catcher, "SVT_BAR");
    builder.build_ep_pf0(descriptor, image);
    finish_cfg_fatal(catcher, "invalid aperture",
                     "power of two and at least 16 bytes", image);

    descriptor = make_descriptor("misaligned_base", PCIE_SVT_ROLE_EP,
                                 4, 4, 5, 1'b0);
    descriptor.ep_bars[0].implemented = 1'b1;
    descriptor.ep_bars[0].is_64bit = 1'b1;
    descriptor.ep_bars[0].aperture = 64'd65536;
    descriptor.ep_bars[0].initial_base = 64'h0000_0001_2345_0001;
    fill_image(image, 32'ha5a5_a5a5);
    arm_expected_fatal(catcher, "SVT_CFG_SPACE");
    builder.build_ep_pf0(descriptor, image);
    finish_cfg_fatal(catcher, "misaligned base",
                     "initial base is not aperture-aligned", image);

    descriptor = make_descriptor("bar32_aperture_overflow",
                                 PCIE_SVT_ROLE_EP, 4, 4, 5, 1'b0);
    descriptor.ep_bars[0].implemented = 1'b1;
    descriptor.ep_bars[0].is_64bit = 1'b0;
    descriptor.ep_bars[0].aperture = 64'h0000_0002_0000_0000;
    descriptor.ep_bars[0].initial_base = 0;
    fill_image(image, 32'ha5a5_a5a5);
    arm_expected_fatal(catcher, "SVT_CFG_SPACE");
    builder.build_ep_pf0(descriptor, image);
    finish_cfg_fatal(catcher, "32-bit aperture overflow",
                     "32-bit BAR aperture exceeds 4 GiB", image);

    descriptor = make_descriptor("bar32_range_overflow",
                                 PCIE_SVT_ROLE_EP, 4, 4, 5, 1'b0);
    descriptor.ep_bars[0].implemented = 1'b1;
    descriptor.ep_bars[0].is_64bit = 1'b0;
    descriptor.ep_bars[0].aperture = 64'd65536;
    descriptor.ep_bars[0].initial_base = 64'h0000_0001_0000_0000;
    fill_image(image, 32'ha5a5_a5a5);
    arm_expected_fatal(catcher, "SVT_CFG_SPACE");
    builder.build_ep_pf0(descriptor, image);
    finish_cfg_fatal(catcher, "32-bit range overflow",
                     "32-bit BAR range exceeds 4 GiB", image);

    descriptor = make_descriptor("bar32_4g_nonzero_base",
                                 PCIE_SVT_ROLE_EP, 4, 4, 5, 1'b0);
    descriptor.ep_bars[0].implemented = 1'b1;
    descriptor.ep_bars[0].is_64bit = 1'b0;
    descriptor.ep_bars[0].aperture = 64'h0000_0001_0000_0000;
    descriptor.ep_bars[0].initial_base = 64'h0000_0001_0000_0000;
    fill_image(image, 32'ha5a5_a5a5);
    arm_expected_fatal(catcher, "SVT_CFG_SPACE");
    builder.build_ep_pf0(descriptor, image);
    finish_cfg_fatal(catcher, "4 GiB BAR nonzero base",
                     "32-bit BAR range exceeds 4 GiB", image);

    descriptor = make_descriptor("bar5_64bit_low", PCIE_SVT_ROLE_EP,
                                 4, 4, 5, 1'b0);
    descriptor.ep_bars[5].implemented = 1'b1;
    descriptor.ep_bars[5].is_64bit = 1'b1;
    descriptor.ep_bars[5].aperture = 64'd65536;
    descriptor.ep_bars[5].initial_base = 0;
    fill_image(image, 32'ha5a5_a5a5);
    arm_expected_fatal(catcher, "SVT_CFG_SPACE");
    builder.build_ep_pf0(descriptor, image);
    finish_cfg_fatal(catcher, "BAR5 64-bit low",
                     "BAR5 cannot be the low DWORD of a 64-bit BAR", image);

    descriptor = make_descriptor("upper_collision", PCIE_SVT_ROLE_EP,
                                 4, 4, 5, 1'b0);
    descriptor.ep_bars[0].implemented = 1'b1;
    descriptor.ep_bars[0].is_64bit = 1'b1;
    descriptor.ep_bars[0].aperture = 64'd65536;
    descriptor.ep_bars[1].implemented = 1'b1;
    descriptor.ep_bars[1].is_64bit = 1'b0;
    descriptor.ep_bars[1].aperture = 64'd65536;
    fill_image(image, 32'ha5a5_a5a5);
    arm_expected_fatal(catcher, "SVT_CFG_SPACE");
    builder.build_ep_pf0(descriptor, image);
    finish_cfg_fatal(catcher, "upper DWORD collision",
                     "BAR1 is the upper DWORD of BAR0", image);

    descriptor = make_descriptor("slot_overflow", PCIE_SVT_ROLE_EP,
                                 4, 4, 5, 1'b0, 16'hafef);
    fill_image(image, 32'ha5a5_a5a5);
    arm_expected_fatal(catcher, "SVT_CFG_SPACE");
    builder.build_ep_pf0(descriptor, image);
    finish_cfg_fatal(catcher, "slot-ID overflow",
                     "slot index does not fit the PF0 device ID", image);

    descriptor = make_descriptor("non_ep_pf0", PCIE_SVT_ROLE_RC,
                                 4, 4, 5, 1'b0);
    fill_image(image, 32'ha5a5_a5a5);
    arm_expected_fatal(catcher, "SVT_CFG_SPACE");
    builder.build_ep_pf0(descriptor, image);
    finish_cfg_fatal(catcher, "non-Endpoint descriptor",
                     "requires an Endpoint descriptor", image);

    fill_image(image, 32'ha5a5_a5a5);
    arm_expected_fatal(catcher, "SVT_CFG_SPACE");
    builder.build_ep_pf0(null_descriptor, image);
    finish_cfg_fatal(catcher, "null PF0 descriptor",
                     "cannot build PF0 from a null descriptor", image);

    descriptor = make_descriptor("null_bar_descriptor", PCIE_SVT_ROLE_EP,
                                 4, 4, 5, 1'b0);
    descriptor.ep_bars[0] = null;
    fill_image(image, 32'ha5a5_a5a5);
    arm_expected_fatal(catcher, "SVT_CFG_SPACE");
    builder.build_ep_pf0(descriptor, image);
    finish_cfg_fatal(catcher, "null BAR descriptor",
                     "BAR0 descriptor is null", image);
  endfunction

  function void check_stable_port_owned_names();
    pcie_svt_port_descriptor descriptor;

    descriptor = make_descriptor("RC1-EP/1", PCIE_SVT_ROLE_RC,
                                 8, 8, 5, 1'b0, 7);
    require(pcie_svt_topology_env::sanitize_link_id(descriptor.link_id) ==
              "RC1_EP_1",
            "link ID sanitization is not hierarchy-safe");
    require(pcie_svt_topology_env::port_owned_name(
              "port", descriptor) == "port_s7_RC1_EP_1",
            "agent name is not derived from physical slot and link ID");
    require(pcie_svt_topology_env::port_owned_name(
              "port_cfg", descriptor) == "port_cfg_s7_RC1_EP_1",
            "configuration name is not stable across compacted arrays");
    require(pcie_svt_topology_env::port_owned_name(
              "port_status", descriptor) == "port_status_s7_RC1_EP_1",
            "status name is not stable across compacted arrays");
    require(pcie_svt_topology_env::port_owned_name(
              "bar_sizing_callback", descriptor) ==
                "bar_sizing_callback_s7_RC1_EP_1",
            "callback name is not stable across compacted arrays");
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(svt_pcie_vif)::get(
          this, "", "primary_rc0_vif", rc_vif) || (rc_vif == null)) begin
      if (!uvm_config_db#(svt_pcie_vif)::get(
            this, "", "primary_vif_0", rc_vif) || (rc_vif == null))
        `uvm_fatal("SVT_DEVICE_CFG",
                   "missing primary_rc0_vif and primary_vif_0")
    end
    if (!uvm_config_db#(svt_pcie_vif)::get(
          this, "", "primary_ep0_vif", ep_vif) || (ep_vif == null)) begin
      if (!uvm_config_db#(svt_pcie_vif)::get(
            this, "", "peer_vif_0", ep_vif) || (ep_vif == null))
        `uvm_fatal("SVT_DEVICE_CFG",
                   "missing primary_ep0_vif and peer_vif_0")
    end
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
    foreach (generations[g]) begin
      check_endpoint_apply(builder, generations[g], 1'b0,
                           PCIE_SVT_EP_SINGLE);
      check_endpoint_apply(builder, generations[g], 1'b1,
                           PCIE_SVT_EP_SINGLE);
      check_endpoint_apply(builder, generations[g], 1'b0,
                           PCIE_SVT_EP_MULTI_BDF);
      check_endpoint_apply(builder, generations[g], 1'b1,
                           PCIE_SVT_EP_MULTI_BDF);
    end
    check_device_mismatch_guards(builder);
    check_device_null_guards(builder);
    check_cfg_space_builder();
    check_cfg_space_rejections();
    check_stable_port_owned_names();
    phase.drop_objection(this);
  endtask
endclass
