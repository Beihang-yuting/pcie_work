class pcie_svt_expected_profile_error_catcher extends uvm_report_catcher;
  int unsigned caught_count;

  `uvm_object_utils(pcie_svt_expected_profile_error_catcher)

  function new(string name = "pcie_svt_expected_profile_error_catcher");
    super.new(name);
  endfunction

  virtual function action_e catch();
    if (get_id() == "PROFILE") begin
      caught_count++;
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
        check_port(profiles.port[PCIE_SVT_PRIMARY_PORT0], "rc0", PCIE_SVT_RC,
                   16, 0, gen, 16'h1d0f, 16'hf000);
      end
      PCIE_SVT_TOPO_EP_2X8: begin
        profile_check(profiles.active_count() == 2,
              "EP_2X8 primary must contain two ports");
        check_port(profiles.port[PCIE_SVT_PRIMARY_PORT0], "rc0", PCIE_SVT_RC,
                   8, 0, gen, 16'h1d0f, 16'hf000);
        check_port(profiles.port[PCIE_SVT_PRIMARY_PORT1], "rc1", PCIE_SVT_RC,
                   8, 1, gen, 16'h1d0f, 16'hf000);
      end
      PCIE_SVT_TOPO_SWITCH: begin
        profile_check(profiles.active_count() == 5,
              "switch primary must contain five ports");
        check_port(profiles.port[PCIE_SVT_PRIMARY_PORT0], "rc0", PCIE_SVT_RC,
                   16, 0, gen, 16'h1d0f, 16'hf000);
        for (int i = 0; i < 4; i++)
          check_port(profiles.port[PCIE_SVT_PRIMARY_PORT1+i],
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
    int unsigned caught_before;

    catcher = pcie_svt_expected_profile_error_catcher::type_id::create(
      "expected_profile_errors");
    uvm_report_cb::add(null, catcher);

    bar = pcie_svt_bar_profile::type_id::create("small_bar");
    bar.implemented = 1;
    bar.aperture = 8;
    caught_before = catcher.caught_count;
    profile_check(!bar.validate("small_bar") && catcher.caught_count > caught_before,
          "implemented BAR below 16 bytes must fail validation");
    bar.aperture = 48;
    caught_before = catcher.caught_count;
    profile_check(!bar.validate("non_power_bar") && catcher.caught_count > caught_before,
          "non-power-of-two BAR must fail validation");
    bar.aperture = 4096;
    bar.initial_base = 2048;
    caught_before = catcher.caught_count;
    profile_check(!bar.validate("misaligned_bar") && catcher.caught_count > caught_before,
          "misaligned BAR must fail validation");

    fn = pcie_svt_function_profile::type_id::create("negative_fn");
    fn.enable_pri = 1;
    caught_before = catcher.caught_count;
    profile_check(!fn.validate("negative_fn") && catcher.caught_count > caught_before,
          "PRI without ATS must fail validation");
    fn.enable_pri = 0;
    fn.enable_pasid = 1;
    caught_before = catcher.caught_count;
    profile_check(!fn.validate("negative_fn") && catcher.caught_count > caught_before,
          "PASID without ATS must fail validation");
    fn.enable_pasid = 0;

    fn.enable_msix = 1;
    fn.msix_table_bar = 0;
    fn.msix_pba_bar = 2;
    caught_before = catcher.caught_count;
    profile_check(!fn.validate("negative_fn") && catcher.caught_count > caught_before,
          "MSI-X BIR to unimplemented BAR must fail validation");
    fn.bars[0].implemented = 1;
    fn.bars[0].is_64bit = 1;
    fn.bars[0].aperture = 4096;
    fn.bars[2].implemented = 1;
    fn.bars[2].aperture = 4096;
    fn.msix_table_bar = 1;
    caught_before = catcher.caught_count;
    profile_check(!fn.validate("negative_fn") && catcher.caught_count > caught_before,
          "MSI-X BIR to upper half of 64-bit BAR must fail validation");
    fn.msix_table_bar = 0;
    fn.msix_table_offset = 3;
    caught_before = catcher.caught_count;
    profile_check(!fn.validate("negative_fn") && catcher.caught_count > caught_before,
          "unaligned MSI-X table offset must fail validation");
    fn.msix_table_offset = 0;
    fn.msix_pba_offset = 4;
    caught_before = catcher.caught_count;
    profile_check(!fn.validate("negative_fn") && catcher.caught_count > caught_before,
          "unaligned MSI-X PBA offset must fail validation");
    fn.enable_msix = 0;

    fn.enable_rebar = 1;
    fn.rebar_supported_sizes[4] = 32'h1;
    fn.rebar_current_size[4] = 0;
    caught_before = catcher.caught_count;
    profile_check(!fn.validate("negative_fn") && catcher.caught_count > caught_before,
          "REBAR entry for an unimplemented BAR must fail validation");
    fn.bars[4].implemented = 1;
    fn.bars[4].aperture = 4096;
    fn.rebar_supported_sizes[4] = 32'h2;
    fn.rebar_current_size[4] = 32;
    caught_before = catcher.caught_count;
    profile_check(!fn.validate("negative_fn") && catcher.caught_count > caught_before,
          "out-of-range REBAR encoding must fail validation safely");
    fn.rebar_current_size[4] = 2;
    caught_before = catcher.caught_count;
    profile_check(!fn.validate("negative_fn") && catcher.caught_count > caught_before,
          "unsupported REBAR current encoding must fail validation");

    fn.enable_rebar = 0;
    fn.bars[0] = null;
    caught_before = catcher.caught_count;
    profile_check(!fn.validate("negative_fn") && catcher.caught_count > caught_before,
          "null BAR handle must fail validation");

    port_profile = pcie_svt_port_profile::type_id::create("negative_port");
    port_profile.port_id = "bad";
    port_profile.link_width = 2;
    port_profile.max_gen = 4;
    port_profile.functions.push_back(fn);
    caught_before = catcher.caught_count;
    profile_check(!port_profile.validate() && catcher.caught_count > caught_before,
          "invalid link width must fail validation");
    port_profile.link_width = 4;
    port_profile.max_gen = 3;
    caught_before = catcher.caught_count;
    profile_check(!port_profile.validate() && catcher.caught_count > caught_before,
          "invalid generation must fail validation");
    port_profile.max_gen = 4;
    port_profile.port_id = "";
    caught_before = catcher.caught_count;
    profile_check(!port_profile.validate() && catcher.caught_count > caught_before,
          "empty port ID must fail validation");
    port_profile.port_id = "bad";
    port_profile.functions.delete();
    caught_before = catcher.caught_count;
    profile_check(!port_profile.validate() && catcher.caught_count > caught_before,
          "missing PF0 must fail validation");

    uvm_report_cb::delete(null, catcher);
  endfunction

  function void check_rebuild_and_independence();
    pcie_svt_profile_set profiles;
    pcie_svt_profile_set peers;
    pcie_svt_port_profile original;

    profiles = pcie_svt_profile_set::type_id::create("rebuild_profiles");
    peers = pcie_svt_profile_set::type_id::create("independent_peers");
    profiles.build_for_topology(PCIE_SVT_TOPO_SWITCH, 5);
    original = profiles.port[PCIE_SVT_PRIMARY_PORT0];
    peers.build_peer_for_topology(PCIE_SVT_TOPO_SWITCH, 5);
    profile_check(original != peers.port[PCIE_SVT_PEER_PORT0],
          "primary and peer profiles must not alias");
    profiles.build_for_topology(PCIE_SVT_TOPO_EP_X16, 4);
    profile_check(profiles.active_count() == 1,
          "rebuild must clear previously active primary ports");
    profile_check(profiles.port[PCIE_SVT_PRIMARY_PORT0] != original,
          "rebuild must create a fresh primary port object");
    profile_check(profiles.port[PCIE_SVT_PRIMARY_PORT1] == null &&
          profiles.port[PCIE_SVT_PEER_PORT0] == null,
          "rebuild must clear unused primary and peer registry slots");
    peers.build_peer_for_topology(PCIE_SVT_TOPO_EP_X16, 4);
    profile_check(peers.active_count() == 1 &&
          peers.port[PCIE_SVT_PRIMARY_PORT0] == null &&
          peers.port[PCIE_SVT_PEER_PORT1] == null,
          "peer rebuild must clear all previous contents");
  endfunction

  task run_phase(uvm_phase phase);
    int selected_gen;
    phase.raise_objection(this);
    if (!$value$plusargs("PCIE_GEN=%d", selected_gen))
      `uvm_error("PROFILE_TEST", "+PCIE_GEN must select 4 or 5")
    profile_check((selected_gen == 4) || (selected_gen == 5),
          "+PCIE_GEN must select 4 or 5");

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

    if (uvm_report_server::get_server().get_severity_count(UVM_ERROR) == 0 &&
        uvm_report_server::get_server().get_severity_count(UVM_FATAL) == 0)
      `uvm_info("PROFILE_TEST", "PCIE_SVT_PROFILE_TEST_PASS", UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
