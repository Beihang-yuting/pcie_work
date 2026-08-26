// This factory-replaceable seam performs only the blocking handoff to an
// official VIP sequencer.  The production port sequence creates and
// randomizes each official operation, checks exposed request results, and owns
// ordering.
class pcie_svt_cfg_init_service_adapter extends uvm_object;
  string link_id;

  `uvm_object_utils(pcie_svt_cfg_init_service_adapter)

  function new(string name = "pcie_svt_cfg_init_service_adapter");
    super.new(name);
  endfunction

  virtual task start_refresh(
      svt_pcie_device_agent_service_sequence sequence_item,
      svt_pcie_device_agent_service_sequencer sequencer,
      svt_pcie_device_agent agent,
      svt_pcie_device_configuration cfg);
    sequence_item.start(sequencer);
  endtask

  virtual task execute_cfg_database(
      svt_pcie_cfg_database_service request,
      uvm_sequencer_base sequencer,
      uvm_sequence_base owner_sequence);
    owner_sequence.start_item(request, -1, sequencer);
    owner_sequence.finish_item(request);
  endtask

  virtual task start_set_bar_ro_map(
      svt_pcie_target_app_service_set_bar_ro_map_sequence sequence_item,
      svt_pcie_target_app_service_sequencer sequencer);
    sequence_item.start(sequencer);
  endtask

  virtual task start_write_addr(
      svt_pcie_target_app_service_write_addr_sequence sequence_item,
      svt_pcie_target_app_service_sequencer sequencer);
    sequence_item.start(sequencer);
  endtask

  virtual task start_read_addr(
      svt_pcie_target_app_service_read_addr_sequence sequence_item,
      svt_pcie_target_app_service_sequencer sequencer);
    sequence_item.start(sequencer);
  endtask

  virtual task start_get_bar_ro_map(
      svt_pcie_target_app_service_get_bar_ro_map_sequence sequence_item,
      svt_pcie_target_app_service_sequencer sequencer);
    sequence_item.start(sequencer);
  endtask

  virtual task start_set_completer_space_enable(
      svt_pcie_target_app_service_set_completer_space_enable_sequence
        sequence_item,
      svt_pcie_target_app_service_sequencer sequencer);
    sequence_item.start(sequencer);
  endtask
endclass

class pcie_svt_cfg_init_port_sequence extends
    uvm_sequence #(uvm_sequence_item);
  pcie_svt_port_descriptor descriptor;
  svt_pcie_device_configuration cfg;
  svt_pcie_device_configuration runtime_cfg;
  svt_pcie_device_status status;
  svt_pcie_device_agent agent;
  svt_pcie_device_virtual_sequencer port_seqr;
  pcie_svt_topology_virtual_sequencer topology_seqr;
  virtual pcie_svt_reset_if reset_vif;
  uvm_event refresh_done;
  bit allow_post_refresh;
  bit program_target_bars = 1'b1;
  bit completed;
  bit failed;
  int unsigned refresh_count;
  int unsigned bar_check_count;
  int unsigned bar_service_operation_count;
  int unsigned cfg_write_count;
  int unsigned cfg_read_count;
  pcie_svt_cfg_init_service_adapter service_adapter;

  `uvm_object_utils(pcie_svt_cfg_init_port_sequence)

  function new(string name = "pcie_svt_cfg_init_port_sequence");
    super.new(name);
    refresh_done = new({name, "_refresh_done"});
  endfunction

  function string operation_context(string operation);
    return $sformatf("link=%s operation=%s",
      (descriptor == null) ? "<null>" : descriptor.link_id, operation);
  endfunction

  function void mark_failed();
    failed = 1'b1;
    if ((topology_seqr != null) && (descriptor != null) &&
        topology_seqr.cfg_state.exists(descriptor.link_id))
      topology_seqr.cfg_state[descriptor.link_id] = PCIE_SVT_STAGE_FAIL;
  endfunction

  protected function void fail(string id, string message);
    mark_failed();
    `uvm_fatal(id, message)
  endfunction

  protected function bit handles_are_valid();
    if ((descriptor == null) || (cfg == null) || (status == null) ||
        (agent == null) || (port_seqr == null) ||
        (topology_seqr == null) || (reset_vif == null)) begin
      fail("SVT_CFG_HANDLE", "Endpoint cfg-init has a null registry handle");
      return 1'b0;
    end
    if (descriptor.role != PCIE_SVT_ROLE_EP) begin
      fail("SVT_CFG_HANDLE", {operation_context("validate"),
        " requires an Endpoint descriptor"});
      return 1'b0;
    end
    if ((status.pcie_status == null) ||
        (status.pcie_status.pl_status == null)) begin
      fail("SVT_CFG_HANDLE", {operation_context("validate"),
        " has incomplete PCIe status handles"});
      return 1'b0;
    end
    if ((port_seqr.device_agent_service_seqr == null) ||
        (port_seqr.cfg_database_seqr == null) ||
        !port_seqr.target_seqr.exists(0) ||
        (port_seqr.target_seqr[0] == null)) begin
      fail("SVT_CFG_HANDLE", {operation_context("validate"),
        " has incomplete service sequencers"});
      return 1'b0;
    end
    if (cfg.device_is_root != 1'b0) begin
      fail("SVT_CFG_HANDLE", {operation_context("validate"),
        " Endpoint cfg has device_is_root set"});
      return 1'b0;
    end
    if ((cfg.pcie_cfg == null) ||
        (cfg.pcie_cfg.enable_multi_endpoint_mode != 1'b1)) begin
      fail("SVT_CFG_HANDLE", {operation_context("validate"),
        " Endpoint cfg does not enable Multi-Endpoint Mode"});
      return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function bit link_is_down(string operation);
    if (status.pcie_status.pl_status.link_up !== 1'b0) begin
      fail("SVT_CFG_LINK", $sformatf(
        "%s link_up=%b expected known zero",
        operation_context(operation), status.pcie_status.pl_status.link_up));
      return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function bit reset_is_asserted(string operation);
    if (reset_vif.asserted !== '1) begin
      fail("SVT_CFG_RESET", $sformatf(
        "%s reset_asserted=0x%0h expected all asserted",
        operation_context(operation), reset_vif.asserted));
      return 1'b0;
    end
    return link_is_down(operation);
  endfunction

  protected function bit reset_is_released(string operation);
    if (reset_vif.asserted !== '0) begin
      fail("SVT_CFG_RESET", $sformatf(
        "%s reset_asserted=0x%0h expected all released",
        operation_context(operation), reset_vif.asserted));
      return 1'b0;
    end
    return link_is_down(operation);
  endfunction

  protected function bit post_refresh_environment_is_safe(
      string operation);
    return reset_is_released(operation);
  endfunction

  protected function uvm_sequencer_base map_cfg_request(
      svt_pcie_cfg_database_service request,
      string operation);
    uvm_sequencer_base mapped_seqr;

    mapped_seqr = port_seqr.map_data_item_to_seqr(request);
    if (mapped_seqr == null) begin
      fail("SVT_CFG_DATABASE", {operation_context(operation),
        " request sequencer mapping failed"});
      return null;
    end
    return mapped_seqr;
  endfunction

  protected task refresh_configuration();
    svt_configuration generic_cfg;
    svt_pcie_device_configuration current_cfg;
    svt_pcie_device_agent_service_sequence refresh_sequence;

    if (!reset_is_asserted("before_refresh"))
      return;
    generic_cfg = null;
    current_cfg = null;
    runtime_cfg = null;
    agent.get_cfg(generic_cfg);
    if ((generic_cfg == null) || !$cast(current_cfg, generic_cfg)) begin
      fail("SVT_CFG_REFRESH", {operation_context("REFRESH_CFG"),
        " could not fetch the current agent configuration"});
      return;
    end
    if (!$cast(runtime_cfg, current_cfg.clone()) || (runtime_cfg == null)) begin
      fail("SVT_CFG_REFRESH", {operation_context("REFRESH_CFG"),
        " could not clone the current agent configuration"});
      return;
    end
    if ((runtime_cfg.device_is_root != 1'b0) ||
        (runtime_cfg.pcie_cfg == null) ||
        (runtime_cfg.pcie_cfg.enable_multi_endpoint_mode != 1'b1) ||
        !runtime_cfg.target_cfg.exists(0) ||
        (runtime_cfg.target_cfg[0] == null)) begin
      fail("SVT_CFG_REFRESH", {operation_context("REFRESH_CFG"),
        " current agent configuration did not preserve Endpoint/Target state"});
      return;
    end
    uvm_config_db#(svt_pcie_device_configuration)::set(
      agent, "", "cfg", runtime_cfg);
    refresh_sequence =
      svt_pcie_device_agent_service_sequence::type_id::create(
        {descriptor.link_id, "_refresh_sequence"});
    if (refresh_sequence == null) begin
      fail("SVT_CFG_REFRESH", {operation_context("REFRESH_CFG"),
        " service sequence creation failed"});
      return;
    end
    if (!refresh_sequence.randomize() with {
          service_type == svt_pcie_device_agent_service::REFRESH_CFG;
        }) begin
      fail("SVT_CFG_REFRESH", {operation_context("REFRESH_CFG"),
        " service sequence randomization failed"});
      return;
    end
    service_adapter.start_refresh(
      refresh_sequence, port_seqr.device_agent_service_seqr, agent, cfg);
    refresh_count++;
    if (!reset_is_asserted("after_refresh"))
      return;
  endtask

  protected task cfg_write(
      int unsigned dword_addr,
      bit [31:0] value);
    svt_pcie_cfg_database_service request;
    uvm_sequencer_base mapped_seqr;

    request = svt_pcie_cfg_database_service::type_id::create(
      $sformatf("%s_write_pf0_dw%03h", descriptor.link_id, dword_addr));
    if (request == null) begin
      fail("SVT_CFG_DATABASE", {operation_context("WRITE_CFG_DWORD"),
        " request creation failed"});
      return;
    end
    mapped_seqr = map_cfg_request(request, "WRITE_CFG_DWORD");
    if (mapped_seqr == null)
      return;
    request.cfg = runtime_cfg;
    if (!request.randomize() with {
          service_type == svt_pcie_cfg_database_service::WRITE_CFG_DWORD;
          function_num == 0;
          dword_addr == local::dword_addr;
          byte_enables == 4'hf;
          dword_data == local::value;
        }) begin
      fail("SVT_CFG_DATABASE", {operation_context("WRITE_CFG_DWORD"),
        " request randomization failed"});
      return;
    end
    service_adapter.execute_cfg_database(
      request, mapped_seqr, this);
    if (request.command_status !=
        `SVT_PCIE_CFG_DATABASE_STATUS_SUCCESSFUL) begin
      fail("SVT_CFG_DATABASE", $sformatf(
        "%s dword=0x%03h command_status=0x%08h",
        operation_context("WRITE_CFG_DWORD"), dword_addr,
        request.command_status));
      return;
    end
    cfg_write_count++;
  endtask

  protected task cfg_read_check(
      int unsigned dword_addr,
      bit [31:0] expected);
    svt_pcie_cfg_database_service request;
    uvm_sequencer_base mapped_seqr;

    request = svt_pcie_cfg_database_service::type_id::create(
      $sformatf("%s_read_pf0_dw%03h", descriptor.link_id, dword_addr));
    if (request == null) begin
      fail("SVT_CFG_DATABASE", {operation_context("READ_CFG_DWORD"),
        " request creation failed"});
      return;
    end
    mapped_seqr = map_cfg_request(request, "READ_CFG_DWORD");
    if (mapped_seqr == null)
      return;
    request.cfg = runtime_cfg;
    if (!request.randomize() with {
          service_type == svt_pcie_cfg_database_service::READ_CFG_DWORD;
          function_num == 0;
          dword_addr == local::dword_addr;
          byte_enables == 4'hf;
        }) begin
      fail("SVT_CFG_DATABASE", {operation_context("READ_CFG_DWORD"),
        " request randomization failed"});
      return;
    end
    service_adapter.execute_cfg_database(
      request, mapped_seqr, this);
    if (request.command_status !=
        `SVT_PCIE_CFG_DATABASE_STATUS_SUCCESSFUL) begin
      fail("SVT_CFG_DATABASE", $sformatf(
        "%s dword=0x%03h command_status=0x%08h",
        operation_context("READ_CFG_DWORD"), dword_addr,
        request.command_status));
      return;
    end
    if (request.dword_data !== expected) begin
      fail("SVT_CFG_DATABASE", $sformatf(
        "%s dword=0x%03h expected=%08h actual=%08h",
        operation_context("READ_CFG_DWORD"), dword_addr, expected,
        request.dword_data));
      return;
    end
    cfg_read_count++;
  endtask

  protected task preload_pf0(
      pcie_svt_cfg_space_builder builder,
      ref bit [31:0] image[1024]);
    int unsigned checked_dwords[12] =
      '{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 15};

    builder.build_ep_pf0(descriptor, image);
    for (int unsigned dword_addr = 0; dword_addr < 1024; dword_addr++)
      cfg_write(dword_addr, image[dword_addr]);
    foreach (checked_dwords[i])
      cfg_read_check(checked_dwords[i], image[checked_dwords[i]]);
  endtask

  protected task program_one_bar(
      pcie_svt_cfg_space_builder builder,
      int unsigned bar_num);
    pcie_svt_bar_cfg source_bar;
    bit high_dword;
    bit [15:0] bdf_num;
    bit [27:0] ecam_addr;
    bit [31:0] expected_map;
    bit [31:0] expected_value;
    svt_pcie_target_app_service_set_bar_ro_map_sequence set_map_sequence;
    svt_pcie_target_app_service_write_addr_sequence write_addr_sequence;
    svt_pcie_target_app_service_read_addr_sequence read_addr_sequence;
    svt_pcie_target_app_service_get_bar_ro_map_sequence get_map_sequence;

    bdf_num = 16'h0000;
    ecam_addr = {16'h0000, 12'(12'h010 + 4 * bar_num)};
    high_dword = (bar_num > 0) &&
                 descriptor.ep_bars[bar_num-1].implemented &&
                 descriptor.ep_bars[bar_num-1].is_64bit;
    source_bar = high_dword ? descriptor.ep_bars[bar_num-1] :
                             descriptor.ep_bars[bar_num];
    expected_map = ((source_bar != null) && source_bar.implemented) ?
      builder.bar_ro_map(source_bar.aperture, high_dword) : 32'h0;
    expected_value = builder.bar_initial_value(source_bar, high_dword);

    set_map_sequence =
      svt_pcie_target_app_service_set_bar_ro_map_sequence::type_id::create(
        $sformatf("%s_set_bar%0d_map", descriptor.link_id, bar_num));
    if ((set_map_sequence == null) ||
        !set_map_sequence.randomize() with {
          bar_num == local::bar_num;
          bdf_num == local::bdf_num;
          data == local::expected_map;
        }) begin
      fail("SVT_CFG_BAR", {operation_context("SET_BAR_RO_MAP"),
        " sequence creation/randomization failed"});
      return;
    end
    service_adapter.start_set_bar_ro_map(
      set_map_sequence, port_seqr.target_seqr[0]);
    bar_service_operation_count++;

    write_addr_sequence =
      svt_pcie_target_app_service_write_addr_sequence::type_id::create(
        $sformatf("%s_write_bar%0d", descriptor.link_id, bar_num));
    if ((write_addr_sequence == null) ||
        !write_addr_sequence.randomize() with {
          ecam_addr == local::ecam_addr;
          bit_mask == 32'hffff_ffff;
          data == local::expected_value;
        }) begin
      fail("SVT_CFG_BAR", {operation_context("WRITE_ADDR"),
        " sequence creation/randomization failed"});
      return;
    end
    service_adapter.start_write_addr(
      write_addr_sequence, port_seqr.target_seqr[0]);
    bar_service_operation_count++;

    read_addr_sequence =
      svt_pcie_target_app_service_read_addr_sequence::type_id::create(
        $sformatf("%s_read_bar%0d", descriptor.link_id, bar_num));
    if ((read_addr_sequence == null) ||
        !read_addr_sequence.randomize() with {
          ecam_addr == local::ecam_addr;
        }) begin
      fail("SVT_CFG_BAR", {operation_context("READ_ADDR"),
        " sequence creation/randomization failed"});
      return;
    end
    service_adapter.start_read_addr(
      read_addr_sequence, port_seqr.target_seqr[0]);
    bar_service_operation_count++;

    get_map_sequence =
      svt_pcie_target_app_service_get_bar_ro_map_sequence::type_id::create(
        $sformatf("%s_get_bar%0d_map", descriptor.link_id, bar_num));
    if ((get_map_sequence == null) ||
        !get_map_sequence.randomize() with {
          bar_num == local::bar_num;
          bdf_num == local::bdf_num;
        }) begin
      fail("SVT_CFG_BAR", {operation_context("GET_BAR_RO_MAP"),
        " sequence creation/randomization failed"});
      return;
    end
    service_adapter.start_get_bar_ro_map(
      get_map_sequence, port_seqr.target_seqr[0]);
    bar_service_operation_count++;

    if (read_addr_sequence.data !== expected_value) begin
      fail("SVT_CFG_BAR_VALUE", $sformatf(
        "%s BAR%0d expected=%08h actual=%08h",
        operation_context("READ_ADDR"), bar_num, expected_value,
        read_addr_sequence.data));
      return;
    end
    if (get_map_sequence.data !== expected_map) begin
      fail("SVT_CFG_BAR_MAP", $sformatf(
        "%s BAR%0d expected=%08h actual=%08h",
        operation_context("GET_BAR_RO_MAP"), bar_num, expected_map,
        get_map_sequence.data));
      return;
    end
    bar_check_count++;
    `uvm_info("PCIE_SVT_BAR_CHECK", $sformatf(
      "link=%s bdf=%04h BAR%0d value=%08h ro_map=%08h",
      descriptor.link_id, bdf_num, bar_num, read_addr_sequence.data,
      get_map_sequence.data), UVM_NONE)
  endtask

  protected task enable_completer_memory_space();
    svt_pcie_target_app_service_set_completer_space_enable_sequence
      enable_sequence;

    enable_sequence =
      svt_pcie_target_app_service_set_completer_space_enable_sequence::
        type_id::create({descriptor.link_id, "_enable_memory_space"});
    if ((enable_sequence == null) ||
        !enable_sequence.randomize() with {
          io_select == 1'b0;
          data == 1'b1;
        }) begin
      fail("SVT_CFG_BAR", {
        operation_context("SET_COMPLETER_SPACE_ENABLE"),
        " sequence creation/randomization failed"});
      return;
    end
    service_adapter.start_set_completer_space_enable(
      enable_sequence, port_seqr.target_seqr[0]);
  endtask

  virtual task body();
    pcie_svt_cfg_space_builder builder;
    bit [31:0] image[1024];

    if (!handles_are_valid())
      return;
    service_adapter = pcie_svt_cfg_init_service_adapter::type_id::create(
      {descriptor.link_id, "_service_adapter"});
    if (service_adapter == null) begin
      fail("SVT_CFG_HANDLE", {operation_context("create_adapter"),
        " factory returned null"});
      return;
    end
    service_adapter.link_id = descriptor.link_id;
    refresh_configuration();
    refresh_done.trigger();
    wait (allow_post_refresh);
    if (failed || !post_refresh_environment_is_safe("before_pf0"))
      return;

    builder = pcie_svt_cfg_space_builder::type_id::create(
      {descriptor.link_id, "_cfg_space_builder"});
    if (builder == null) begin
      fail("SVT_CFG_HANDLE", {operation_context("create_builder"),
        " factory returned null"});
      return;
    end
    preload_pf0(builder, image);
    if (!post_refresh_environment_is_safe("after_pf0"))
      return;

    // Disabling target BAR programming still refreshes the final Endpoint
    // cfg and preloads/read-checks PF0.  This is the peer-safe boundary: it
    // suppresses Target-App BAR/completer operations without weakening the
    // configuration database contract.
    if (program_target_bars) begin
      for (int unsigned bar_num = 0; bar_num < 6; bar_num++)
        program_one_bar(builder, bar_num);
      enable_completer_memory_space();
    end
    if (!post_refresh_environment_is_safe("complete"))
      return;
    completed = 1'b1;
  endtask
endclass

class pcie_svt_cfg_init_vseq extends uvm_sequence #(uvm_sequence_item);
  localparam time PCIE_SVT_VIP_INIT_HOLD_TIME = 205ns;

  bit program_target_bars = 1'b1;
  int unsigned refresh_count;
  int unsigned bar_check_count;
  int unsigned bar_service_operation_count;
  int unsigned cfg_write_count;
  int unsigned cfg_read_count;
  pcie_svt_cfg_init_port_sequence endpoint_sequences[$];

  `uvm_object_utils(pcie_svt_cfg_init_vseq)
  `uvm_declare_p_sequencer(pcie_svt_topology_virtual_sequencer)

  function new(string name = "pcie_svt_cfg_init_vseq");
    super.new(name);
  endfunction

  protected function void mark_all_endpoints_failed();
    foreach (endpoint_sequences[i])
      if (endpoint_sequences[i] != null)
        endpoint_sequences[i].mark_failed();
  endfunction

  protected function bit validate_registered_link(string link_id);
    pcie_svt_port_descriptor descriptor;
    svt_pcie_device_configuration cfg;
    svt_pcie_device_status status;
    svt_pcie_device_agent agent;
    svt_pcie_device_virtual_sequencer port_seqr;

    descriptor = p_sequencer.get_port_descriptor(link_id);
    cfg = p_sequencer.cfg_by_link.exists(link_id) ?
      p_sequencer.cfg_by_link[link_id] : null;
    status = p_sequencer.status_by_link.exists(link_id) ?
      p_sequencer.status_by_link[link_id] : null;
    agent = p_sequencer.agent_by_link.exists(link_id) ?
      p_sequencer.agent_by_link[link_id] : null;
    port_seqr = p_sequencer.get_port_seqr(link_id);
    if ((descriptor == null) || (cfg == null) || (status == null) ||
        (agent == null) || (port_seqr == null)) begin
      if (p_sequencer.cfg_state.exists(link_id))
        p_sequencer.cfg_state[link_id] = PCIE_SVT_STAGE_FAIL;
      `uvm_fatal("SVT_CFG_HANDLE", $sformatf(
        "link=%s has incomplete descriptor/cfg/status/agent/seqr handles",
        link_id))
      return 1'b0;
    end
    if ((status.pcie_status == null) ||
        (status.pcie_status.pl_status == null)) begin
      p_sequencer.cfg_state[link_id] = PCIE_SVT_STAGE_FAIL;
      `uvm_fatal("SVT_CFG_HANDLE", $sformatf(
        "link=%s has incomplete PCIe status handles", link_id))
      return 1'b0;
    end
    if (status.pcie_status.pl_status.link_up !== 1'b0) begin
      p_sequencer.cfg_state[link_id] = PCIE_SVT_STAGE_FAIL;
      `uvm_fatal("SVT_CFG_LINK", $sformatf(
        "link=%s link_up=%b expected known zero", link_id,
        status.pcie_status.pl_status.link_up))
      return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function bit all_registered_links_are_down(string operation);
    foreach (p_sequencer.descriptor_by_link[link_id]) begin
      svt_pcie_device_status status;
      status = p_sequencer.status_by_link.exists(link_id) ?
        p_sequencer.status_by_link[link_id] : null;
      if ((status == null) || (status.pcie_status == null) ||
          (status.pcie_status.pl_status == null)) begin
        if (p_sequencer.cfg_state.exists(link_id))
          p_sequencer.cfg_state[link_id] = PCIE_SVT_STAGE_FAIL;
        `uvm_fatal("SVT_CFG_HANDLE", $sformatf(
          "link=%s operation=%s has incomplete PCIe status handles",
          link_id, operation))
        return 1'b0;
      end
      if (status.pcie_status.pl_status.link_up !== 1'b0) begin
        p_sequencer.cfg_state[link_id] = PCIE_SVT_STAGE_FAIL;
        `uvm_fatal("SVT_CFG_LINK", $sformatf(
          "link=%s operation=%s link_up=%b expected known zero",
          link_id, operation, status.pcie_status.pl_status.link_up))
        return 1'b0;
      end
    end
    return 1'b1;
  endfunction

  protected task run_endpoint_with_timeout(
      pcie_svt_cfg_init_port_sequence sequence_item);
    bit child_done;
    realtime start_time;
    realtime deadline;
    realtime completion_time;

    child_done = 1'b0;
    start_time = $realtime;
    deadline = start_time + sequence_item.descriptor.cfg_timeout;
    completion_time = 0;
    fork
      begin
        sequence_item.start(null);
        completion_time = $realtime;
        child_done = 1'b1;
      end
      begin
        if ($realtime < deadline)
          #(deadline - $realtime);
        // Let completion scheduled exactly at the deadline settle first.
        if (!child_done)
          #1step;
      end
    join_any
    disable fork;
    if (!child_done || (completion_time > deadline)) begin
      sequence_item.mark_failed();
      `uvm_fatal("SVT_CFG_TIMEOUT", $sformatf(
        {"link=%s phase=cfg_init exceeded total cfg_timeout=%0t ",
         "start=%0.6f deadline=%0.6f completion=%0.6f current=%0.6f ",
         "refresh_done=%0d reset_released=%0d ",
         "cfg_connections=%0d cfg_reqs=%0d cfg_current=%0d"},
        sequence_item.descriptor.link_id,
        sequence_item.descriptor.cfg_timeout,
        start_time, deadline, completion_time, $realtime,
        sequence_item.refresh_done.is_on(),
        sequence_item.reset_vif.asserted === '0,
        sequence_item.port_seqr.cfg_database_seqr.seq_item_export.size(),
        sequence_item.port_seqr.cfg_database_seqr.get_num_reqs_sent(),
        sequence_item.port_seqr.cfg_database_seqr.get_current_item() != null))
    end
  endtask

  virtual task body();
    string all_links[$];

    refresh_count = 0;
    bar_check_count = 0;
    bar_service_operation_count = 0;
    cfg_write_count = 0;
    cfg_read_count = 0;
    endpoint_sequences.delete();
    if ((p_sequencer == null) || (p_sequencer.reset_vif == null))
      `uvm_fatal("SVT_CFG_HANDLE", "cfg-init requires a topology sequencer and reset VIF")
    if (p_sequencer.reset_vif.asserted !== '1)
      `uvm_fatal("SVT_CFG_RESET", $sformatf(
        "before 205ns hold reset_asserted=0x%0h expected all asserted",
        p_sequencer.reset_vif.asserted))

    if (!all_registered_links_are_down("before_205ns_hold"))
      return;
    #(PCIE_SVT_VIP_INIT_HOLD_TIME);
    if (p_sequencer.reset_vif.asserted !== '1)
      `uvm_fatal("SVT_CFG_RESET", $sformatf(
        "after 205ns hold reset_asserted=0x%0h expected all asserted",
        p_sequencer.reset_vif.asserted))
    if (!all_registered_links_are_down("after_205ns_hold"))
      return;

    foreach (p_sequencer.descriptor_by_link[link_id])
      all_links.push_back(link_id);
    for (int i = 0; i < all_links.size(); i++) begin
      for (int j = i + 1; j < all_links.size(); j++) begin
        if (all_links[j] < all_links[i]) begin
          string temporary;
          temporary = all_links[i];
          all_links[i] = all_links[j];
          all_links[j] = temporary;
        end
      end
    end
    foreach (all_links[i]) begin
      pcie_svt_port_descriptor descriptor;
      string link_id;
      link_id = all_links[i];
      if (!validate_registered_link(link_id))
        return;
      descriptor = p_sequencer.descriptor_by_link[link_id];
      if (descriptor.role == PCIE_SVT_ROLE_RC) begin
        // RC validation is deliberately silent: no refresh and no skip record.
      end else begin
        pcie_svt_cfg_init_port_sequence child;
        child = pcie_svt_cfg_init_port_sequence::type_id::create(
          {link_id, "_cfg_init"});
        if (child == null) begin
          p_sequencer.cfg_state[link_id] = PCIE_SVT_STAGE_FAIL;
          `uvm_fatal("SVT_CFG_HANDLE", $sformatf(
            "link=%s Endpoint sequence factory returned null", link_id))
        end
        child.descriptor = descriptor;
        child.cfg = p_sequencer.cfg_by_link[link_id];
        child.status = p_sequencer.status_by_link[link_id];
        child.agent = p_sequencer.agent_by_link[link_id];
        child.port_seqr = p_sequencer.get_port_seqr(link_id);
        child.topology_seqr = p_sequencer;
        child.reset_vif = p_sequencer.reset_vif;
        child.program_target_bars = program_target_bars;
        endpoint_sequences.push_back(child);
      end
    end

    if (endpoint_sequences.size() != 0) begin
      foreach (endpoint_sequences[i]) begin
        fork
          automatic pcie_svt_cfg_init_port_sequence child =
            endpoint_sequences[i];
          run_endpoint_with_timeout(child);
        join_none
      end
      foreach (endpoint_sequences[i])
        endpoint_sequences[i].refresh_done.wait_on();
    end

    if (p_sequencer.reset_vif.asserted !== '1) begin
      mark_all_endpoints_failed();
      `uvm_fatal("SVT_CFG_RESET", $sformatf(
        "before reset release asserted=0x%0h expected all asserted",
        p_sequencer.reset_vif.asserted))
    end
    if (!all_registered_links_are_down("before_reset_release")) begin
      mark_all_endpoints_failed();
      return;
    end
    p_sequencer.reset_vif.release_all();
    #0;
    if (p_sequencer.reset_vif.asserted !== '0) begin
      mark_all_endpoints_failed();
      `uvm_fatal("SVT_CFG_RESET", $sformatf(
        "after reset release asserted=0x%0h expected all released",
        p_sequencer.reset_vif.asserted))
    end
    `uvm_info("PCIE_SVT_CFG_RESET_RELEASED", $sformatf(
      "asserted=0x%0h links_remain_down=1",
      p_sequencer.reset_vif.asserted), UVM_NONE)
    if (!all_registered_links_are_down("after_reset_release")) begin
      mark_all_endpoints_failed();
      return;
    end
    foreach (endpoint_sequences[i])
      endpoint_sequences[i].allow_post_refresh = 1'b1;
    wait fork;

    foreach (endpoint_sequences[i]) begin
      pcie_svt_cfg_init_port_sequence child;
      child = endpoint_sequences[i];
      refresh_count += child.refresh_count;
      bar_check_count += child.bar_check_count;
      bar_service_operation_count += child.bar_service_operation_count;
      cfg_write_count += child.cfg_write_count;
      cfg_read_count += child.cfg_read_count;
      if (child.failed || !child.completed) begin
        child.mark_failed();
        `uvm_fatal("SVT_CFG_INCOMPLETE", $sformatf(
          "link=%s did not complete cfg-init", child.descriptor.link_id))
      end
    end
    if (p_sequencer.reset_vif.asserted !== '0) begin
      mark_all_endpoints_failed();
      `uvm_fatal("SVT_CFG_RESET", $sformatf(
        "cfg-init completed after reset reasserted: 0x%0h",
        p_sequencer.reset_vif.asserted))
    end
    if (!all_registered_links_are_down("cfg_init_complete")) begin
      mark_all_endpoints_failed();
      return;
    end
    foreach (all_links[i])
      p_sequencer.cfg_state[all_links[i]] = PCIE_SVT_STAGE_PASS;
  endtask
endclass
