class pcie_svt_expected_profile_error_catcher extends uvm_report_catcher;
  string expected_id;
  string expected_substring;
  int unsigned matched_count;

  `uvm_object_utils(pcie_svt_expected_profile_error_catcher)

  function new(string name = "pcie_svt_expected_profile_error_catcher");
    super.new(name);
  endfunction

  function void set_expected(string substring, string report_id = "PROFILE");
    expected_id = report_id;
    expected_substring = substring;
    matched_count = 0;
  endfunction

  function bit message_contains(string message, string substring);
    if ((substring.len() == 0) || (message.len() < substring.len()))
      return 0;
    for (int i = 0; i <= message.len() - substring.len(); i++)
      if (message.substr(i, i + substring.len() - 1) == substring)
        return 1;
    return 0;
  endfunction

  virtual function action_e catch();
    if ((get_id() == expected_id) &&
        message_contains(get_message(), expected_substring)) begin
      matched_count++;
      return CAUGHT;
    end
    return THROW;
  endfunction
endclass

class pcie_svt_profile_unit_test extends uvm_test;
  `uvm_component_utils(pcie_svt_profile_unit_test)

  function new(string name = "pcie_svt_profile_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void profile_check(bit condition, string message);
    if (!condition)
      `uvm_error("PROFILE_TEST", message)
  endfunction

  function void check_expected_failure(
      pcie_svt_expected_profile_error_catcher catcher,
      bit validation_result,
      string description);
    profile_check(!validation_result, {description, " must fail validation"});
    profile_check(catcher.matched_count == 1,
                  $sformatf("%s must emit exactly one matching %s report; got %0d",
                            description, catcher.expected_id,
                            catcher.matched_count));
  endfunction

  function pcie_svt_function_profile make_valid_function(string name);
    return pcie_svt_function_profile::type_id::create(name);
  endfunction

  function pcie_svt_port_profile make_valid_port(string name);
    pcie_svt_port_profile result;
    result = pcie_svt_port_profile::type_id::create(name);
    result.port_id = name;
    result.link_width = 4;
    result.max_gen = 4;
    result.functions.push_back(make_valid_function({name, "_pf0"}));
    return result;
  endfunction

  function void check_function_defaults(pcie_svt_function_profile fn,
                                        bit endpoint,
                                        bit [15:0] vendor_id,
                                        bit [15:0] device_id,
                                        string path);
    profile_check(fn != null, {path, ": PF0 is null"});
    if (fn == null)
      return;
    profile_check(fn.vendor_id == vendor_id, {path, ": vendor ID mismatch"});
    profile_check(fn.device_id == device_id, {path, ": device ID mismatch"});
    profile_check(fn.revision_id == 8'h00, {path, ": revision mismatch"});
    profile_check(fn.header_type == (endpoint ? 8'h00 : 8'h01),
          {path, ": header type mismatch"});
    profile_check(fn.class_code == (endpoint ? 24'h020000 : 24'h060400),
          {path, ": class code mismatch"});
    profile_check(fn.command_reset == 16'h0000, {path, ": command reset mismatch"});
    profile_check(fn.interrupt_pin == (endpoint ? 8'h01 : 8'h00),
          {path, ": interrupt pin mismatch"});
    profile_check(fn.max_payload_supported == 3'd0 &&
          fn.max_payload_size == 3'd0 &&
          fn.max_read_request_size == 3'd2,
          {path, ": payload/read request defaults mismatch"});
    profile_check(fn.completion_timeout_ranges == 4'b0001,
          {path, ": completion timeout default mismatch"});
    profile_check(!(fn.enable_msi || fn.enable_msix || fn.enable_aer ||
            fn.enable_sriov || fn.enable_ats || fn.enable_pri ||
            fn.enable_pasid || fn.enable_ari || fn.enable_acs ||
            fn.enable_rebar),
          {path, ": optional capabilities must default off"});
    profile_check(fn.expansion_rom != null && !fn.expansion_rom.implemented &&
          fn.expansion_rom.initial_base == 0,
          {path, ": expansion ROM default mismatch"});
    foreach (fn.bars[i])
      profile_check(fn.bars[i] != null,
            $sformatf("%s: BAR%0d handle is null", path, i));

    if (endpoint) begin
      profile_check(fn.subsystem_vendor_id == vendor_id &&
            fn.subsystem_device_id == device_id,
            {path, ": subsystem IDs mismatch"});
      foreach (fn.bars[i]) begin
        if ((i == 0) || (i == 2) || (i == 4)) begin
          profile_check(fn.bars[i].implemented && fn.bars[i].is_64bit &&
                fn.bars[i].prefetchable && fn.bars[i].initial_base == 0,
                $sformatf("%s: BAR%0d attributes mismatch", path, i));
          profile_check(fn.bars[i].aperture == ((i == 0) ? 64'd33554432 :
                                                   64'd65536),
                $sformatf("%s: BAR%0d aperture mismatch", path, i));
        end else begin
          profile_check(!fn.bars[i].implemented,
                $sformatf("%s: BAR%0d must be a paired upper DWORD", path, i));
        end
      end
    end else begin
      foreach (fn.bars[i])
        profile_check(!fn.bars[i].implemented,
              $sformatf("%s: RC BAR%0d must be unimplemented", path, i));
    end
  endfunction

  function void check_port(pcie_svt_port_profile port,
                           string port_id,
                           pcie_svt_role_e role,
                           int unsigned width,
                           int unsigned hierarchy,
                           int unsigned gen,
                           bit [15:0] vendor_id,
                           bit [15:0] device_id);
    profile_check(port != null, {port_id, ": port handle is null"});
    if (port == null)
      return;
    profile_check(port.port_id == port_id, {port_id, ": port ID mismatch"});
    profile_check(port.role == role, {port_id, ": role mismatch"});
    profile_check(port.link_width == width, {port_id, ": width mismatch"});
    profile_check(port.root_hierarchy == hierarchy,
          {port_id, ": root hierarchy mismatch"});
    profile_check(port.max_gen == gen, {port_id, ": generation mismatch"});
    profile_check(port.functions.size() >= 1, {port_id, ": PF0 is absent"});
    if (port.functions.size() >= 1)
      check_function_defaults(port.functions[0], role == PCIE_SVT_EP,
                              vendor_id, device_id, {port_id, ".PF0"});
    profile_check(port.validate(), {port_id, ": generated profile did not validate"});
  endfunction

  function void check_primary_topology(pcie_svt_topology_e topology,
                                       int unsigned gen);
    pcie_svt_profile_set profiles;
    profiles = pcie_svt_profile_set::type_id::create(
      $sformatf("primary_%0d_%0d", topology, gen));
    profiles.build_for_topology(topology, gen);
    case (topology)
      PCIE_SVT_TOPO_EP_X16: begin
        profile_check(profiles.active_count() == 1,
              "EP_X16 primary must contain one port");
        check_port(profiles.port[PCIE_SVT_PRIMARY_RC0], "rc0", PCIE_SVT_RC,
                   16, 0, gen, 16'h1d0f, 16'hf000);
      end
      PCIE_SVT_TOPO_EP_2X8: begin
        profile_check(profiles.active_count() == 2,
              "EP_2X8 primary must contain two ports");
        check_port(profiles.port[PCIE_SVT_PRIMARY_RC0], "rc0", PCIE_SVT_RC,
                   8, 0, gen, 16'h1d0f, 16'hf000);
        check_port(profiles.port[PCIE_SVT_PRIMARY_RC1], "rc1", PCIE_SVT_RC,
                   8, 1, gen, 16'h1d0f, 16'hf000);
      end
      PCIE_SVT_TOPO_SWITCH: begin
        profile_check(profiles.active_count() == 5,
              "switch primary must contain five ports");
        check_port(profiles.port[PCIE_SVT_PRIMARY_RC0], "rc0", PCIE_SVT_RC,
                   16, 0, gen, 16'h1d0f, 16'hf000);
        for (int i = 0; i < 4; i++)
          check_port(profiles.port[PCIE_SVT_PRIMARY_EP0+i],
                     $sformatf("ep%0d", i), PCIE_SVT_EP, 4, 0, gen,
                     16'h20f9, 16'h5011+i);
      end
      default: profile_check(0, "unexpected primary topology");
    endcase
  endfunction

  function void check_peer_topology(pcie_svt_topology_e topology,
                                    int unsigned gen);
    pcie_svt_profile_set profiles;
    profiles = pcie_svt_profile_set::type_id::create(
      $sformatf("peer_%0d_%0d", topology, gen));
    profiles.build_peer_for_topology(topology, gen);
    case (topology)
      PCIE_SVT_TOPO_EP_X16: begin
        profile_check(profiles.active_count() == 1,
              "EP_X16 peer must contain one port");
        check_port(profiles.port[PCIE_SVT_PEER_PORT0], "peer_ep0", PCIE_SVT_EP,
                   16, 0, gen, 16'h1af4, 16'h1000);
      end
      PCIE_SVT_TOPO_EP_2X8: begin
        profile_check(profiles.active_count() == 2,
              "EP_2X8 peer must contain two ports");
        check_port(profiles.port[PCIE_SVT_PEER_PORT0], "peer_ep0", PCIE_SVT_EP,
                   8, 0, gen, 16'h1af4, 16'h1000);
        check_port(profiles.port[PCIE_SVT_PEER_PORT1], "peer_ep1", PCIE_SVT_EP,
                   8, 1, gen, 16'h1af4, 16'h1001);
      end
      PCIE_SVT_TOPO_SWITCH: begin
        profile_check(profiles.active_count() == 5,
              "switch peer must contain five ports");
        check_port(profiles.port[PCIE_SVT_PEER_PORT0], "peer_ep_usp",
                   PCIE_SVT_EP, 16, 0, gen, 16'h1af4, 16'h1100);
        for (int i = 0; i < 4; i++)
          check_port(profiles.port[PCIE_SVT_PEER_PORT1+i],
                     $sformatf("peer_rc_dsp%0d", i), PCIE_SVT_RC, 4, i+1,
                     gen, 16'h1d0f, 16'hf000);
      end
      default: profile_check(0, "unexpected peer topology");
    endcase
  endfunction

  function void check_negative_validation();
    pcie_svt_expected_profile_error_catcher catcher;
    pcie_svt_bar_profile bar;
    pcie_svt_function_profile fn;
    pcie_svt_port_profile port_profile;

    catcher = pcie_svt_expected_profile_error_catcher::type_id::create(
      "expected_profile_errors");
    uvm_report_cb::add(null, catcher);

    bar = pcie_svt_bar_profile::type_id::create("small_bar");
    bar.implemented = 1;
    bar.aperture = 8;
    catcher.set_expected("small_bar: BAR aperture must be a power of two and at least 16 bytes");
    check_expected_failure(catcher, bar.validate("small_bar"),
                           "implemented BAR below 16 bytes");

    bar = pcie_svt_bar_profile::type_id::create("non_power_bar");
    bar.implemented = 1;
    bar.aperture = 48;
    catcher.set_expected("non_power_bar: BAR aperture must be a power of two and at least 16 bytes");
    check_expected_failure(catcher, bar.validate("non_power_bar"),
                           "non-power-of-two BAR");

    bar = pcie_svt_bar_profile::type_id::create("misaligned_bar");
    bar.implemented = 1;
    bar.aperture = 4096;
    bar.initial_base = 2048;
    catcher.set_expected("misaligned_bar: BAR base is not aperture aligned");
    check_expected_failure(catcher, bar.validate("misaligned_bar"),
                           "misaligned BAR");

    fn = make_valid_function("pri_fn");
    fn.enable_pri = 1;
    catcher.set_expected("pri_fn: PRI requires ATS");
    check_expected_failure(catcher, fn.validate("pri_fn"), "PRI without ATS");

    fn = make_valid_function("pasid_fn");
    fn.enable_pasid = 1;
    catcher.set_expected("pasid_fn: PASID requires ATS");
    check_expected_failure(catcher, fn.validate("pasid_fn"),
                           "PASID without ATS");

    fn = make_valid_function("msix_unimplemented_fn");
    fn.enable_msix = 1;
    fn.msix_table_bar = 0;
    fn.msix_pba_bar = 2;
    fn.bars[2].implemented = 1;
    fn.bars[2].aperture = 4096;
    catcher.set_expected("msix_unimplemented_fn.msix_table: MSI-X BIR selects an unimplemented BAR");
    check_expected_failure(catcher, fn.validate("msix_unimplemented_fn"),
                           "MSI-X BIR to unimplemented BAR");

    fn = make_valid_function("msix_upper_fn");
    fn.enable_msix = 1;
    fn.bars[0].implemented = 1;
    fn.bars[0].is_64bit = 1;
    fn.bars[0].aperture = 4096;
    fn.bars[2].implemented = 1;
    fn.bars[2].aperture = 4096;
    fn.msix_table_bar = 1;
    fn.msix_pba_bar = 2;
    catcher.set_expected("msix_upper_fn.msix_table: MSI-X BIR selects the upper half of a 64-bit BAR");
    check_expected_failure(catcher, fn.validate("msix_upper_fn"),
                           "MSI-X BIR to upper half of 64-bit BAR");

    fn = make_valid_function("msix_table_align_fn");
    fn.enable_msix = 1;
    fn.bars[0].implemented = 1;
    fn.bars[0].aperture = 4096;
    fn.bars[2].implemented = 1;
    fn.bars[2].aperture = 4096;
    fn.msix_table_bar = 0;
    fn.msix_pba_bar = 2;
    fn.msix_table_offset = 3;
    catcher.set_expected("msix_table_align_fn: MSI-X table offset must be 8-byte aligned");
    check_expected_failure(catcher, fn.validate("msix_table_align_fn"),
                           "unaligned MSI-X table offset");

    fn = make_valid_function("msix_pba_align_fn");
    fn.enable_msix = 1;
    fn.bars[0].implemented = 1;
    fn.bars[0].aperture = 4096;
    fn.bars[2].implemented = 1;
    fn.bars[2].aperture = 4096;
    fn.msix_table_bar = 0;
    fn.msix_pba_bar = 2;
    fn.msix_pba_offset = 4;
    catcher.set_expected("msix_pba_align_fn: MSI-X PBA offset must be 8-byte aligned");
    check_expected_failure(catcher, fn.validate("msix_pba_align_fn"),
                           "unaligned MSI-X PBA offset");

    fn = make_valid_function("rebar_unimplemented_fn");
    fn.enable_rebar = 1;
    fn.rebar_supported_sizes[4] = 32'h1;
    fn.rebar_current_size[4] = 0;
    catcher.set_expected("rebar_unimplemented_fn.BAR4: REBAR entry requires an implemented BAR");
    check_expected_failure(catcher, fn.validate("rebar_unimplemented_fn"),
                           "REBAR entry for an unimplemented BAR");

    fn = make_valid_function("rebar_empty_fn");
    fn.enable_rebar = 1;
    catcher.set_expected("rebar_empty_fn: REBAR requires at least one configured entry");
    check_expected_failure(catcher, fn.validate("rebar_empty_fn"),
                           "REBAR with no configured entries");

    fn = make_valid_function("rebar_bounds_fn");
    fn.enable_rebar = 1;
    fn.bars[4].implemented = 1;
    fn.bars[4].aperture = 4096;
    fn.rebar_supported_sizes[4] = 32'h1;
    fn.rebar_current_size[4] = 32;
    catcher.set_expected("rebar_bounds_fn.BAR4: REBAR current-size encoding is out of range");
    check_expected_failure(catcher, fn.validate("rebar_bounds_fn"),
                           "out-of-range REBAR encoding");

    fn = make_valid_function("rebar_unsupported_fn");
    fn.enable_rebar = 1;
    fn.bars[4].implemented = 1;
    fn.bars[4].aperture = 4096;
    fn.rebar_supported_sizes[4] = 32'h2;
    fn.rebar_current_size[4] = 2;
    catcher.set_expected("rebar_unsupported_fn.BAR4: REBAR current size is not supported");
    check_expected_failure(catcher, fn.validate("rebar_unsupported_fn"),
                           "unsupported REBAR current encoding");

    fn = make_valid_function("null_bar_fn");
    fn.bars[0] = null;
    catcher.set_expected("null_bar_fn.BAR0: null BAR handle");
    check_expected_failure(catcher, fn.validate("null_bar_fn"),
                           "null BAR handle");

    fn = make_valid_function("bar5_64bit_fn");
    fn.bars[5].implemented = 1;
    fn.bars[5].is_64bit = 1;
    fn.bars[5].aperture = 4096;
    catcher.set_expected("bar5_64bit_fn.BAR5: 64-bit BAR requires an upper DWORD");
    check_expected_failure(catcher, fn.validate("bar5_64bit_fn"),
                           "64-bit BAR at BAR5");

    fn = make_valid_function("bar_upper_implemented_fn");
    fn.bars[0].implemented = 1;
    fn.bars[0].is_64bit = 1;
    fn.bars[0].aperture = 4096;
    fn.bars[1].implemented = 1;
    fn.bars[1].aperture = 4096;
    catcher.set_expected("bar_upper_implemented_fn.BAR1: upper DWORD of BAR0 must be unimplemented");
    check_expected_failure(catcher, fn.validate("bar_upper_implemented_fn"),
                           "implemented upper half of a 64-bit BAR");

    port_profile = make_valid_port("invalid_width_port");
    port_profile.link_width = 2;
    catcher.set_expected("invalid_width_port: link width must be x4, x8, or x16");
    check_expected_failure(catcher, port_profile.validate(), "invalid link width");

    port_profile = make_valid_port("invalid_gen_port");
    port_profile.max_gen = 3;
    catcher.set_expected("invalid_gen_port: max_gen must be Gen4 or Gen5");
    check_expected_failure(catcher, port_profile.validate(), "invalid generation");

    port_profile = make_valid_port("empty_id_port");
    port_profile.port_id = "";
    catcher.set_expected("port_id must not be empty");
    check_expected_failure(catcher, port_profile.validate(), "empty port ID");

    port_profile = make_valid_port("missing_pf0_port");
    port_profile.functions.delete();
    catcher.set_expected("missing_pf0_port: PF0 must be present");
    check_expected_failure(catcher, port_profile.validate(), "missing PF0");

    uvm_report_cb::delete(null, catcher);
  endfunction

  function void check_deep_copy();
    pcie_svt_bar_profile source_bar;
    pcie_svt_bar_profile cloned_bar;
    pcie_svt_function_profile source_fn;
    pcie_svt_function_profile cloned_fn;
    pcie_svt_port_profile source_port;
    pcie_svt_port_profile cloned_port;
    pcie_svt_profile_set source_set;
    pcie_svt_profile_set cloned_set;
    pcie_svt_profile_set copied_set;

    source_bar = pcie_svt_bar_profile::type_id::create("source_bar");
    source_bar.implemented = 1;
    source_bar.is_64bit = 1;
    source_bar.prefetchable = 1;
    source_bar.aperture = 64'd65536;
    source_bar.initial_base = 64'h1_0000;
    profile_check($cast(cloned_bar, source_bar.clone()),
                  "BAR clone must preserve the factory type");
    if (cloned_bar != null) begin
      profile_check(cloned_bar.implemented == source_bar.implemented &&
                    cloned_bar.is_64bit == source_bar.is_64bit &&
                    cloned_bar.prefetchable == source_bar.prefetchable &&
                    cloned_bar.aperture == source_bar.aperture &&
                    cloned_bar.initial_base == source_bar.initial_base,
                    "BAR clone must copy all fields");
      cloned_bar.aperture = 64'd4096;
      profile_check(source_bar.aperture == 64'd65536,
                    "BAR clone mutation must not affect the source");
    end

    source_fn = make_valid_function("source_fn");
    source_fn.device_id = 16'h1234;
    source_fn.bars[0].implemented = 1;
    source_fn.bars[0].is_64bit = 1;
    source_fn.bars[0].aperture = 64'd65536;
    source_fn.raw_dw_override[32'h100] = 32'hdead_beef;
    profile_check($cast(cloned_fn, source_fn.clone()),
                  "function clone must preserve the factory type");
    if (cloned_fn != null) begin
      profile_check(cloned_fn.bars[0] != source_fn.bars[0] &&
                    cloned_fn.bars[0].aperture == source_fn.bars[0].aperture &&
                    cloned_fn.device_id == source_fn.device_id &&
                    cloned_fn.raw_dw_override.exists(32'h100) &&
                    cloned_fn.raw_dw_override[32'h100] == 32'hdead_beef,
                    "function clone must deep-copy BARs and raw overrides");
      cloned_fn.bars[0].aperture = 64'd4096;
      cloned_fn.device_id = 16'h5678;
      cloned_fn.raw_dw_override[32'h100] = 32'hcafe_f00d;
      profile_check(source_fn.bars[0].aperture == 64'd65536 &&
                    source_fn.device_id == 16'h1234 &&
                    source_fn.raw_dw_override[32'h100] == 32'hdead_beef,
                    "function clone mutation must not affect the source");
    end

    source_port = make_valid_port("source_port");
    source_port.role = PCIE_SVT_EP;
    source_port.functions[0].device_id = 16'h4321;
    source_port.functions[0].raw_dw_override[32'h104] = 32'h0123_4567;
    profile_check($cast(cloned_port, source_port.clone()),
                  "port clone must preserve the factory type");
    if ((cloned_port != null) && (cloned_port.functions.size() == 1) &&
        (cloned_port.functions[0] != null)) begin
      profile_check(cloned_port.functions.size() == 1 &&
                    cloned_port.functions[0] != source_port.functions[0] &&
                    cloned_port.functions[0].device_id == 16'h4321 &&
                    cloned_port.functions[0].raw_dw_override[32'h104] == 32'h0123_4567,
                    "port clone must deep-copy its function queue");
      cloned_port.functions[0].device_id = 16'h8765;
      profile_check(source_port.functions[0].device_id == 16'h4321,
                    "port clone mutation must not affect the source");
    end else begin
      profile_check(0, "port clone must retain a non-null function queue entry");
    end

    source_set = pcie_svt_profile_set::type_id::create("source_set");
    source_set.build_for_topology(PCIE_SVT_TOPO_SWITCH, 5);
    source_set.port[PCIE_SVT_PRIMARY_EP0].functions[0].raw_dw_override[32'h108] =
      32'ha5a5_5a5a;
    profile_check($cast(cloned_set, source_set.clone()),
                  "profile-set clone must preserve the factory type");
    copied_set = pcie_svt_profile_set::type_id::create("copied_set");
    copied_set.copy(source_set);
    if ((cloned_set != null) &&
        (cloned_set.port[PCIE_SVT_PRIMARY_EP0] != null)) begin
      profile_check(cloned_set.port[PCIE_SVT_PRIMARY_EP0] !=
                    source_set.port[PCIE_SVT_PRIMARY_EP0] &&
                    cloned_set.port[PCIE_SVT_PRIMARY_EP0].functions[0] !=
                    source_set.port[PCIE_SVT_PRIMARY_EP0].functions[0] &&
                    cloned_set.port[PCIE_SVT_PRIMARY_EP0].functions[0].bars[0] !=
                    source_set.port[PCIE_SVT_PRIMARY_EP0].functions[0].bars[0] &&
                    cloned_set.port[PCIE_SVT_PRIMARY_EP0].functions[0].raw_dw_override[32'h108] ==
                    32'ha5a5_5a5a,
                    "profile-set clone must deep-copy populated Endpoint state");
      cloned_set.port[PCIE_SVT_PRIMARY_EP0].functions[0].bars[0].aperture =
        64'd4096;
      cloned_set.port[PCIE_SVT_PRIMARY_EP0].functions[0].device_id = 16'hffff;
      cloned_set.port[PCIE_SVT_PRIMARY_EP0].functions[0].raw_dw_override[32'h108] =
        32'hffff_ffff;
      profile_check(source_set.port[PCIE_SVT_PRIMARY_EP0].functions[0].bars[0].aperture ==
                    64'd33554432 &&
                    source_set.port[PCIE_SVT_PRIMARY_EP0].functions[0].device_id ==
                    16'h5011 &&
                    source_set.port[PCIE_SVT_PRIMARY_EP0].functions[0].raw_dw_override[32'h108] ==
                    32'ha5a5_5a5a,
                    "profile-set clone mutation must not affect the source");
    end else begin
      profile_check(0, "profile-set clone must retain the Endpoint slot");
    end
    profile_check(copied_set.port[PCIE_SVT_PRIMARY_EP0] != null &&
                  copied_set.port[PCIE_SVT_PRIMARY_EP0] !=
                  source_set.port[PCIE_SVT_PRIMARY_EP0] &&
                  copied_set.port[PCIE_SVT_PRIMARY_EP0].functions[0].raw_dw_override[32'h108] ==
                  32'ha5a5_5a5a,
                  "profile-set copy must deep-copy populated Endpoint state");
  endfunction

  function void check_rebuild_and_independence();
    pcie_svt_profile_set profiles;
    pcie_svt_profile_set peers;
    pcie_svt_port_profile original;

    profiles = pcie_svt_profile_set::type_id::create("rebuild_profiles");
    peers = pcie_svt_profile_set::type_id::create("independent_peers");
    profiles.build_for_topology(PCIE_SVT_TOPO_SWITCH, 5);
    original = profiles.port[PCIE_SVT_PRIMARY_RC0];
    peers.build_peer_for_topology(PCIE_SVT_TOPO_SWITCH, 5);
    profile_check(original != peers.port[PCIE_SVT_PEER_PORT0],
          "primary and peer profiles must not alias");
    profiles.build_for_topology(PCIE_SVT_TOPO_EP_X16, 4);
    profile_check(profiles.active_count() == 1,
          "rebuild must clear previously active primary ports");
    profile_check(profiles.port[PCIE_SVT_PRIMARY_RC0] != original,
          "rebuild must create a fresh primary port object");
    profile_check(profiles.port[PCIE_SVT_PRIMARY_RC1] == null &&
          profiles.port[PCIE_SVT_PEER_PORT0] == null,
          "rebuild must clear unused primary and peer registry slots");
    peers.build_peer_for_topology(PCIE_SVT_TOPO_EP_X16, 4);
    profile_check(peers.active_count() == 1 &&
          peers.port[PCIE_SVT_PRIMARY_RC0] == null &&
          peers.port[PCIE_SVT_PEER_PORT1] == null,
          "peer rebuild must clear all previous contents");
  endfunction

  function void check_cfg_space_builder();
    pcie_svt_profile_set profiles;
    pcie_svt_port_profile bad;
    pcie_svt_cfg_space_builder b;
    pcie_svt_expected_profile_error_catcher catcher;
    bit [31:0] image[1024];

    profiles = pcie_svt_profile_set::type_id::create("builder_profiles");
    profiles.build_for_topology(PCIE_SVT_TOPO_SWITCH, 5);
    b = pcie_svt_cfg_space_builder::type_id::create("b");
    if (!b.build_function(profiles.port[1].functions[0], 4, 5, image))
      `uvm_error("CFG_BUILD", "EP0 PF0 image build failed")
    if (image['h000/4] !== 32'h5011_20f9)
      `uvm_error("CFG_BUILD", "Vendor/Device DWORD mismatch")
    if (image['h010/4] !== 32'h0000_000c ||
        image['h018/4] !== 32'h0000_000c ||
        image['h020/4] !== 32'h0000_000c)
      `uvm_error("CFG_BUILD", "64-bit Prefetchable BAR attributes mismatch")
    if (b.bar_sizing_dw(64'd32*1024*1024, 0) !== 32'hfe00_000c ||
        b.bar_sizing_dw(64'd32*1024*1024, 1) !== 32'hffff_ffff ||
        b.bar_sizing_dw(64'd64*1024, 0) !== 32'hffff_000c ||
        b.bar_sizing_dw(64'd64*1024, 1) !== 32'hffff_ffff)
      `uvm_error("CFG_BUILD", "BAR sizing DWORD mismatch")
    if (b.bar_ro_map(64'd32*1024*1024, 0) !== 32'h01ff_ffff ||
        b.bar_ro_map(64'd32*1024*1024, 1) !== 32'h0000_0000 ||
        b.bar_ro_map(64'd64*1024, 0) !== 32'h0000_ffff ||
        b.bar_ro_map(64'd64*1024, 1) !== 32'h0000_0000)
      `uvm_error("CFG_BUILD", "BAR read-only map mismatch")
    if (image['h034/4][7:0] !== 8'h40 ||
        image['h004/4][20] !== 1'b1 ||
        image['h040/4][7:0] !== 8'h10 ||
        image['h040/4][15:8] !== 8'h00 ||
        image['h04c/4][9:0] !== {6'd4, 4'd5} ||
        image['h064/4][3:0] !== 4'b0001 ||
        image['h06c/4][7:1] !== 7'b0011111)
      `uvm_error("CFG_BUILD", "PCIe capability encoding mismatch")

    if (!b.build_function(profiles.port[PCIE_SVT_PRIMARY_RC0].functions[0],
                          16, 5, image))
      `uvm_error("CFG_BUILD", "RC0 PF0 Type-1 image build failed")
    if (image['h00c/4][22:16] !== 7'h01 ||
        image['h040/4][23:20] !== 4'h4 ||
        image['h010/4] !== 32'h0000_0000 ||
        image['h014/4] !== 32'h0000_0000 ||
        image['h018/4] !== 32'h0000_0000 ||
        image['h01c/4][7:4] <= image['h01c/4][15:12] ||
        image['h020/4][15:4] <= image['h020/4][31:20] ||
        image['h024/4][15:4] <= image['h024/4][31:20] ||
        image['h028/4] !== 32'h0000_0000 ||
        image['h02c/4] !== 32'h0000_0000 ||
        image['h030/4] !== 32'h0000_0000)
      `uvm_error("CFG_BUILD", "Type-1 header reset image mismatch")

    profile_check($cast(bad, profiles.port[PCIE_SVT_PRIMARY_EP0].clone()),
                  "extended-head-positive port clone failed");
    bad.functions[0].enable_ats = 1;
    bad.functions[0].enable_ari = 1;
    profile_check(b.build_function(bad.functions[0], 4, 5, image),
                  "AER-disabled extended capability image build failed");
    profile_check(image['h100/4][15:0] == 16'h000f &&
                  image['h100/4][31:20] == 12'h2a0 &&
                  image['h240/4] == 32'h0000_0000 &&
                  image['h2a0/4][15:0] == 16'h000e &&
                  image['h2a0/4][31:20] == 12'h000,
                  "AER-disabled extended capability chain is unreachable");

    profile_check($cast(bad, profiles.port[PCIE_SVT_PRIMARY_EP0].clone()),
                  "REBAR-head-positive port clone failed");
    bad.functions[0].enable_rebar = 1;
    bad.functions[0].rebar_supported_sizes[0] = 32'h0000_0020;
    bad.functions[0].rebar_current_size[0] = 5;
    profile_check(b.build_function(bad.functions[0], 4, 5, image),
                  "AER-disabled REBAR image build failed");
    profile_check(image['h100/4][15:0] == 16'h0015 &&
                  image['h100/4][31:20] == 12'h000 &&
                  image['h104/4][31:4] == 28'h0000_020 &&
                  image['h300/4] == 32'h0000_0000,
                  "REBAR head and body are not contiguous at 0x100");

    catcher = pcie_svt_expected_profile_error_catcher::type_id::create(
      "expected_builder_errors");
    uvm_report_cb::add(null, catcher);

    profile_check($cast(bad, profiles.port[PCIE_SVT_PRIMARY_EP0].clone()),
                  "PRI-negative port clone failed");
    bad.functions[0].enable_pri = 1;
    bad.functions[0].enable_ats = 0;
    catcher.set_expected("PRI requires ATS");
    check_expected_failure(catcher,
      b.build_function(bad.functions[0], 4, 5, image), "PRI without ATS build");

    profile_check($cast(bad, profiles.port[PCIE_SVT_PRIMARY_EP0].clone()),
                  "BAR-negative port clone failed");
    bad.functions[0].bars[0].aperture = 64'd3*1024*1024;
    catcher.set_expected("BAR aperture must be a power of two");
    check_expected_failure(catcher,
      b.build_function(bad.functions[0], 4, 5, image), "non-power-of-two BAR build");

    profile_check($cast(bad, profiles.port[PCIE_SVT_PRIMARY_EP0].clone()),
                  "override-negative port clone failed");
    bad.functions[0].raw_dw_override['h034/4] = 32'hdead_beef;
    catcher.set_expected("raw override of Capability Pointer is forbidden",
                         "CFG_BUILD");
    check_expected_failure(catcher,
      b.build_function(bad.functions[0], 4, 5, image), "Capability Pointer override");

    profile_check($cast(bad, profiles.port[PCIE_SVT_PRIMARY_EP0].clone()),
                  "MSI-X-negative port clone failed");
    bad.functions[0].enable_msix = 1;
    bad.functions[0].msix_table_bar = 1;
    catcher.set_expected("MSI-X BIR selects the upper half");
    check_expected_failure(catcher,
      b.build_function(bad.functions[0], 4, 5, image), "MSI-X upper-half BIR build");

    profile_check($cast(bad, profiles.port[PCIE_SVT_PRIMARY_EP0].clone()),
                  "REBAR-negative port clone failed");
    bad.functions[0].enable_rebar = 1;
    bad.functions[0].rebar_supported_sizes[0] = '0;
    catcher.set_expected("REBAR requires at least one configured entry");
    check_expected_failure(catcher,
      b.build_function(bad.functions[0], 4, 5, image), "empty REBAR build");

    profile_check($cast(bad, profiles.port[PCIE_SVT_PRIMARY_EP0].clone()),
                  "capability-positive port clone failed");
    bad.functions[0].enable_msi = 1;
    bad.functions[0].enable_msix = 1;
    bad.functions[0].msix_table_bar = 0;
    bad.functions[0].msix_pba_bar = 2;
    bad.functions[0].enable_aer = 1;
    bad.functions[0].enable_sriov = 1;
    bad.functions[0].enable_ats = 1;
    bad.functions[0].enable_pri = 1;
    bad.functions[0].enable_pasid = 1;
    bad.functions[0].enable_ari = 1;
    bad.functions[0].enable_acs = 1;
    bad.functions[0].enable_rebar = 1;
    bad.functions[0].rebar_supported_sizes[0] = 32'h0000_0020;
    bad.functions[0].rebar_current_size[0] = 5;
    profile_check(b.build_function(bad.functions[0], 4, 5, image),
                  "capability-rich image build failed");
    profile_check(image['h040/4][15:8] == 8'h80 &&
                  image['h080/4][15:8] == 8'ha0 &&
                  image['h0a0/4][15:8] == 8'h00 &&
                  image['h100/4][31:20] == 12'h180 &&
                  image['h180/4][31:20] == 12'h240 &&
                  image['h240/4][31:20] == 12'h260 &&
                  image['h260/4][31:20] == 12'h280 &&
                  image['h280/4][31:20] == 12'h2a0 &&
                  image['h2a0/4][31:20] == 12'h2c0 &&
                  image['h2c0/4][31:20] == 12'h300 &&
                  image['h300/4][31:20] == 12'h000,
                  "standard or extended capability chain mismatch");

    catcher.set_expected("link_width must be x4, x8, or x16", "CFG_BUILD");
    check_expected_failure(catcher,
      b.build_function(profiles.port[PCIE_SVT_PRIMARY_EP0].functions[0],
                       2, 5, image), "invalid builder link width");
    catcher.set_expected("max_gen must be Gen4 or Gen5", "CFG_BUILD");
    check_expected_failure(catcher,
      b.build_function(profiles.port[PCIE_SVT_PRIMARY_EP0].functions[0],
                       4, 3, image), "invalid builder generation");

    profile_check($cast(bad, profiles.port[PCIE_SVT_PRIMARY_RC0].clone()),
                  "Type-1 BAR-negative port clone failed");
    bad.functions[0].bars[1].implemented = 1;
    bad.functions[0].bars[1].is_64bit = 1;
    bad.functions[0].bars[1].aperture = 4096;
    catcher.set_expected("BAR1: 64-bit BAR requires an upper DWORD within the header",
                         "CFG_BUILD");
    check_expected_failure(catcher,
      b.build_function(bad.functions[0], 16, 5, image),
      "Type-1 64-bit BAR in final slot");

    profile_check($cast(bad, profiles.port[PCIE_SVT_PRIMARY_EP0].clone()),
                  "REBAR-width-negative port clone failed");
    bad.functions[0].enable_rebar = 1;
    bad.functions[0].rebar_supported_sizes[0] = 32'h1000_0020;
    bad.functions[0].rebar_current_size[0] = 5;
    catcher.set_expected("BAR0: REBAR supported-size bitmap exceeds 28 bits",
                         "CFG_BUILD");
    check_expected_failure(catcher,
      b.build_function(bad.functions[0], 4, 5, image),
      "out-of-range REBAR supported-size bitmap");

    profile_check($cast(bad, profiles.port[PCIE_SVT_PRIMARY_RC0].clone()),
                  "32-bit BAR-negative port clone failed");
    bad.functions[0].bars[0].implemented = 1;
    bad.functions[0].bars[0].aperture = 64'h0000_0002_0000_0000;
    catcher.set_expected("BAR0: 32-bit BAR range exceeds 4 GiB", "CFG_BUILD");
    check_expected_failure(catcher,
      b.build_function(bad.functions[0], 16, 5, image),
      "32-bit BAR aperture above 4 GiB");

    uvm_report_cb::delete(null, catcher);
  endfunction

  task run_phase(uvm_phase phase);
    int selected_gen;
    phase.raise_objection(this);
    if (!$value$plusargs("PCIE_GEN=%d", selected_gen))
      `uvm_error("PROFILE_TEST", "+PCIE_GEN must select 4 or 5")
    profile_check((selected_gen == 4) || (selected_gen == 5),
          "+PCIE_GEN must select 4 or 5");
    profile_check(PCIE_SVT_PRIMARY_RC0 == 0 &&
                  PCIE_SVT_PRIMARY_RC1 == 1 &&
                  PCIE_SVT_PRIMARY_EP0 == 1 &&
                  PCIE_SVT_PRIMARY_EP1 == 2 &&
                  PCIE_SVT_PRIMARY_EP2 == 3 &&
                  PCIE_SVT_PRIMARY_EP3 == 4,
                  "semantic primary registry indices changed");

    check_primary_topology(PCIE_SVT_TOPO_EP_X16, 4);
    check_primary_topology(PCIE_SVT_TOPO_EP_2X8, 4);
    check_primary_topology(PCIE_SVT_TOPO_SWITCH, 4);
    check_primary_topology(PCIE_SVT_TOPO_EP_X16, 5);
    check_primary_topology(PCIE_SVT_TOPO_EP_2X8, 5);
    check_primary_topology(PCIE_SVT_TOPO_SWITCH, 5);
    check_peer_topology(PCIE_SVT_TOPO_EP_X16, 4);
    check_peer_topology(PCIE_SVT_TOPO_EP_2X8, 4);
    check_peer_topology(PCIE_SVT_TOPO_SWITCH, 4);
    check_peer_topology(PCIE_SVT_TOPO_EP_X16, 5);
    check_peer_topology(PCIE_SVT_TOPO_EP_2X8, 5);
    check_peer_topology(PCIE_SVT_TOPO_SWITCH, 5);
    check_negative_validation();
    check_rebuild_and_independence();
    check_deep_copy();
    check_cfg_space_builder();

    if (uvm_report_server::get_server().get_severity_count(UVM_ERROR) == 0 &&
        uvm_report_server::get_server().get_severity_count(UVM_FATAL) == 0)
      `uvm_info("PROFILE_TEST", "PCIE_SVT_PROFILE_TEST_PASS", UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
