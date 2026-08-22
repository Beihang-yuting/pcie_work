class pcie_svt_cfg_space_init_seq extends uvm_sequence #(uvm_sequence_item);
  svt_pcie_device_virtual_sequencer port_seqr;
  svt_pcie_device_status port_status;
  pcie_svt_port_profile profile;
  int unsigned port_index;
  string stage = "not_started";
  int current_function = -1;
  int current_dword = -1;

  `uvm_object_utils(pcie_svt_cfg_space_init_seq)

  function new(string name = "pcie_svt_cfg_space_init_seq");
    super.new(name);
  endfunction

  function string progress_context();
    string port_id;
    string cfg_seqr_state;
    port_id = (profile == null) ? "<null>" : profile.port_id;
    if ((port_seqr == null) || (port_seqr.cfg_database_seqr == null))
      cfg_seqr_state = "cfg_seqr=<null>";
    else
      cfg_seqr_state = $sformatf("cfg_reqs=%0d cfg_current=%0d",
        port_seqr.cfg_database_seqr.get_num_reqs_sent(),
        port_seqr.cfg_database_seqr.get_current_item() != null);
    return $sformatf(
      "port=%s index=%0d stage=%s function=%0d dword=0x%03h %s",
      port_id, port_index, stage, current_function, current_dword,
      cfg_seqr_state);
  endfunction

  task cfg_write(int unsigned function_num,
                 int unsigned dword_addr,
                 bit [31:0] value);
    svt_pcie_cfg_database_service req;
    uvm_sequencer_base mapped_seqr;

    current_function = function_num;
    current_dword = dword_addr;
    stage = "cfg_write_create";
    req = svt_pcie_cfg_database_service::type_id::create(
      $sformatf("write_pf%0d_dw%03h", function_num, dword_addr));
    if (req == null)
      `uvm_fatal("CFG_INIT", {progress_context(),
        " cfg database write request creation failed"})

    stage = "cfg_write_map";
    mapped_seqr = port_seqr.map_data_item_to_seqr(req);
    if (mapped_seqr == null)
      `uvm_fatal("CFG_INIT", {progress_context(),
        " cfg database write request sequencer mapping failed"})

    stage = "cfg_write_wait_grant";
    start_item(req, -1, mapped_seqr);
    stage = "cfg_write_randomize";
    if (!req.randomize() with {
          service_type == svt_pcie_cfg_database_service::WRITE_CFG_DWORD;
          function_num == local::function_num;
          dword_addr == local::dword_addr;
          byte_enables == 4'hf;
          dword_data == local::value;
        })
      `uvm_fatal("CFG_INIT", {progress_context(),
        " cfg database write request randomization failed"})
    stage = "cfg_write_wait_done";
    finish_item(req);
    if (req.command_status != `SVT_PCIE_CFG_DATABASE_STATUS_SUCCESSFUL)
      `uvm_fatal("CFG_INIT", $sformatf(
        "%s service_status=0x%08h", progress_context(), req.command_status))
  endtask

  task cfg_read_check(int unsigned function_num,
                      int unsigned dword_addr,
                      bit [31:0] expected);
    svt_pcie_cfg_database_service req;
    current_function = function_num;
    current_dword = dword_addr;
    stage = "cfg_readback";
    req = svt_pcie_cfg_database_service::type_id::create(
      $sformatf("read_pf%0d_dw%03h", function_num, dword_addr));
    start_item(req, -1, port_seqr.cfg_database_seqr);
    if (!req.randomize() with {
          service_type == svt_pcie_cfg_database_service::READ_CFG_DWORD;
          function_num == local::function_num;
          dword_addr == local::dword_addr;
          byte_enables == 4'hf;
        })
      `uvm_fatal("CFG_INIT", {progress_context(),
        " cfg database read request randomization failed"})
    finish_item(req);
    if (req.command_status != `SVT_PCIE_CFG_DATABASE_STATUS_SUCCESSFUL)
      `uvm_fatal("CFG_INIT", $sformatf(
        "%s service_status=0x%08h", progress_context(), req.command_status))
    if (req.dword_data !== expected)
      `uvm_fatal("CFG_INIT", $sformatf(
        "%s expected=%08h got=%08h", progress_context(), expected,
        req.dword_data))
    if (dword_addr == 0)
      `uvm_info("CFG_DW0_CHECK", $sformatf(
        "port=%s function=%0d data=%08h", profile.port_id, function_num,
        req.dword_data), UVM_NONE)
  endtask

  task check_important_dwords(int unsigned function_num,
                              pcie_svt_function_profile fn,
                              ref bit [31:0] image[1024]);
    int unsigned max_bars;
    cfg_read_check(function_num, 0, image[0]);
    cfg_read_check(function_num, 'h00c/4, image['h00c/4]);
    cfg_read_check(function_num, 'h034/4, image['h034/4]);
    cfg_read_check(function_num, 'h040/4, image['h040/4]);

    max_bars = (fn.header_type[6:0] == 7'h00) ? 6 : 2;
    for (int unsigned bar = 0; bar < max_bars; bar++)
      cfg_read_check(function_num, ('h010/4) + bar,
                     image[('h010/4) + bar]);

    if (fn.enable_msi)
      cfg_read_check(function_num, 'h080/4, image['h080/4]);
    if (fn.enable_msix)
      cfg_read_check(function_num, 'h0a0/4, image['h0a0/4]);
    if (fn.enable_aer || fn.enable_sriov || fn.enable_ats || fn.enable_pri ||
        fn.enable_pasid || fn.enable_ari || fn.enable_acs || fn.enable_rebar)
      cfg_read_check(function_num, 'h100/4, image['h100/4]);
    if (fn.enable_sriov)
      cfg_read_check(function_num, 'h180/4, image['h180/4]);
    if (fn.enable_ats)
      cfg_read_check(function_num, 'h240/4, image['h240/4]);
    if (fn.enable_pri)
      cfg_read_check(function_num, 'h260/4, image['h260/4]);
    if (fn.enable_pasid)
      cfg_read_check(function_num, 'h280/4, image['h280/4]);
    if (fn.enable_ari)
      cfg_read_check(function_num, 'h2a0/4, image['h2a0/4]);
    if (fn.enable_acs)
      cfg_read_check(function_num, 'h2c0/4, image['h2c0/4]);
    if (fn.enable_rebar)
      cfg_read_check(function_num, 'h300/4, image['h300/4]);
  endtask

`ifndef PCIE_USE_SVT_SWITCH_PROXY
  task target_bar_write_read_check(int unsigned bar_num,
                                   bit [15:0] bdf_num,
                                   bit [31:0] expected_map,
                                   bit [31:0] expected_value);
    svt_pcie_target_app_service_set_bar_ro_map_sequence set_map_seq;
    svt_pcie_target_app_service_write_addr_sequence write_addr_seq;
    svt_pcie_target_app_service_read_addr_sequence read_addr_seq;
    svt_pcie_target_app_service_get_bar_ro_map_sequence get_map_seq;
    bit [27:0] ecam_addr;

    current_function = bdf_num[2:0];
    current_dword = ('h010/4) + bar_num;
    ecam_addr = {bdf_num, 12'('h010 + (4 * bar_num))};

    stage = $sformatf("bar%0d_set_map", bar_num);
    set_map_seq =
      svt_pcie_target_app_service_set_bar_ro_map_sequence::type_id::create(
        $sformatf("set_bar%0d_map", bar_num));
    if ((set_map_seq == null) ||
        !set_map_seq.randomize() with {
          bar_num == local::bar_num;
          bdf_num == local::bdf_num;
          data == local::expected_map;
        })
      `uvm_fatal("BAR_INIT", {progress_context(),
        " SET_BAR_RO_MAP sequence creation/randomization failed"})
    set_map_seq.start(port_seqr.target_seqr[0]);

    stage = $sformatf("bar%0d_write", bar_num);
    write_addr_seq =
      svt_pcie_target_app_service_write_addr_sequence::type_id::create(
        $sformatf("write_bar%0d", bar_num));
    if ((write_addr_seq == null) ||
        !write_addr_seq.randomize() with {
          ecam_addr == local::ecam_addr;
          bit_mask == 32'hffff_ffff;
          data == local::expected_value;
        })
      `uvm_fatal("BAR_INIT", {progress_context(),
        " WRITE_ADDR sequence creation/randomization failed"})
    write_addr_seq.start(port_seqr.target_seqr[0]);

    stage = $sformatf("bar%0d_read", bar_num);
    read_addr_seq =
      svt_pcie_target_app_service_read_addr_sequence::type_id::create(
        $sformatf("read_bar%0d", bar_num));
    if ((read_addr_seq == null) ||
        !read_addr_seq.randomize() with {
          ecam_addr == local::ecam_addr;
        })
      `uvm_fatal("BAR_INIT", {progress_context(),
        " READ_ADDR sequence creation/randomization failed"})
    read_addr_seq.start(port_seqr.target_seqr[0]);

    stage = $sformatf("bar%0d_get_map", bar_num);
    get_map_seq =
      svt_pcie_target_app_service_get_bar_ro_map_sequence::type_id::create(
        $sformatf("get_bar%0d_map", bar_num));
    if ((get_map_seq == null) ||
        !get_map_seq.randomize() with {
          bar_num == local::bar_num;
          bdf_num == local::bdf_num;
        })
      `uvm_fatal("BAR_INIT", {progress_context(),
        " GET_BAR_RO_MAP sequence creation/randomization failed"})
    get_map_seq.start(port_seqr.target_seqr[0]);

    if (read_addr_seq.data !== expected_value)
      `uvm_fatal("BAR_VALUE", $sformatf(
        "%s bdf=%04h BAR%0d expected=%08h got=%08h",
        progress_context(), bdf_num, bar_num, expected_value,
        read_addr_seq.data))
    if (get_map_seq.data !== expected_map)
      `uvm_fatal("BAR_MAP", $sformatf(
        "%s bdf=%04h BAR%0d expected=%08h got=%08h",
        progress_context(), bdf_num, bar_num, expected_map,
        get_map_seq.data))
    `uvm_info("MULTI_EP_BAR_CHECK", $sformatf(
      "port=%s bdf=%04h BAR%0d value=%08h ro_map=%08h link_up=0",
      profile.port_id, bdf_num, bar_num, read_addr_seq.data,
      get_map_seq.data), UVM_NONE)
  endtask

  task init_target_bars(pcie_svt_cfg_space_builder builder);
    pcie_svt_function_profile fn;
    bit [31:0] bar_value;

    if (profile.role == PCIE_SVT_RC) begin
      `uvm_info("MULTI_EP_BAR_SKIP", $sformatf(
        "port=%s role=RC Target App BAR initialization skipped",
        profile.port_id), UVM_NONE)
      return;
    end
    if (!port_seqr.target_seqr.exists(0) ||
        (port_seqr.target_seqr[0] == null))
      `uvm_fatal("BAR_INIT", {progress_context(),
        " EP has null target_seqr[0]"})
    if (profile.functions.size() != 1)
      `uvm_fatal("BAR_INIT", {progress_context(),
        " expected exactly one function mapped to BDF 0000"})

    fn = profile.functions[0];
    for (int unsigned bar = 0; bar < 6; bar++) begin
      if ((bar > 0) && fn.bars[bar-1].implemented &&
          fn.bars[bar-1].is_64bit) begin
        bar_value = fn.bars[bar-1].initial_base[63:32];
        target_bar_write_read_check(
          bar, 16'h0000, builder.bar_ro_map(fn.bars[bar-1].aperture, 1'b1),
          bar_value);
      end else if (fn.bars[bar].implemented) begin
        bar_value = fn.bars[bar].initial_base[31:0];
        if (fn.bars[bar].is_64bit)
          bar_value[2:1] = 2'b10;
        bar_value[3] = fn.bars[bar].prefetchable;
        target_bar_write_read_check(
          bar, 16'h0000, builder.bar_ro_map(fn.bars[bar].aperture, 1'b0),
          bar_value);
      end
    end
  endtask
`endif

  virtual task body();
    pcie_svt_cfg_space_builder builder;
    bit [31:0] image[1024];

    stage = "validate";
    if (profile == null)
      `uvm_fatal("CFG_INIT", {progress_context(), " null profile"})
    if (port_seqr == null)
      `uvm_fatal("CFG_INIT", {progress_context(), " null port sequencer"})
    if (port_status == null)
      `uvm_fatal("CFG_INIT", {progress_context(), " null port status"})
    if (port_seqr.cfg_database_seqr == null)
      `uvm_fatal("CFG_INIT", {progress_context(),
        " null configuration database sequencer"})
    if (!profile.validate())
      `uvm_fatal("CFG_INIT", {progress_context(), " invalid profile"})
    if ((profile.functions.size() == 0) ||
        (profile.functions.size() > 256))
      `uvm_fatal("CFG_INIT", {progress_context(),
        " implemented function count must be 1 through 256"})

    builder = pcie_svt_cfg_space_builder::type_id::create("builder");
    if (builder == null)
      `uvm_fatal("CFG_INIT", {progress_context(), " null image builder"})

    foreach (profile.functions[function_num]) begin
      current_function = function_num;
      current_dword = -1;
      stage = "build_image";
      if (profile.functions[function_num] == null)
        `uvm_fatal("CFG_INIT", {progress_context(),
          " null function profile"})
      if (!builder.build_function(profile.functions[function_num],
                                  profile.link_width, profile.max_gen, image))
        `uvm_fatal("CFG_INIT", {progress_context(),
          " configuration image build failed"})

      // R-2020.12 documents DWORD addresses across the complete 4-KiB
      // configuration image. Zeros are meaningful reset data, so preload all
      // 1024 DWORDs rather than inferring an incomplete valid-address mask.
      for (int unsigned dword_addr = 0; dword_addr < 1024; dword_addr++)
        cfg_write(function_num, dword_addr, image[dword_addr]);
      check_important_dwords(function_num, profile.functions[function_num],
                             image);
    end

`ifndef PCIE_USE_SVT_SWITCH_PROXY
    init_target_bars(builder);
`endif

    stage = "complete";
    current_function = -1;
    current_dword = -1;
  endtask
endclass
