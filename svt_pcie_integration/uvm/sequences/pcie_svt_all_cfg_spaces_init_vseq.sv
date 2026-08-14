class pcie_svt_r202012_multi_ep_warning_catcher extends uvm_report_catcher;
  int unsigned matched_count;

  `uvm_object_utils(pcie_svt_r202012_multi_ep_warning_catcher)

  function new(string name = "pcie_svt_r202012_multi_ep_warning_catcher");
    super.new(name);
  endfunction

  virtual function action_e catch();
    string expected_message;

    expected_message = {"Both enable_multi_endpoint_mode and device_is_root ",
      "are set.  Multi-Endpoint Mode is only valid when the vip is ",
      "configured as an endpoint.  Ignoring the value of ",
      "enable_multi_endpoint_mode."};
    if ((get_severity() == UVM_WARNING) &&
        (get_id() == "is_valid") &&
        (get_message() == expected_message)) begin
      matched_count++;
      return CAUGHT;
    end
    return THROW;
  endfunction
endclass

class pcie_svt_all_cfg_spaces_init_vseq extends
    uvm_sequence #(uvm_sequence_item);
  // Synopsys R-2020.12 unified VIP example initialization hold:
  // examples/sverilog/tb_pcie_svt_uvm_unified_vip_sys/top.sv (reset setup).
  localparam time PCIE_SVT_VIP_INIT_HOLD_TIME = 205ns;
  localparam time PCIE_SVT_CFG_INIT_WATCHDOG_TIME = 1ms;

  `uvm_object_utils(pcie_svt_all_cfg_spaces_init_vseq)
  `uvm_declare_p_sequencer(pcie_svt_virtual_sequencer)

  function new(string name = "pcie_svt_all_cfg_spaces_init_vseq");
    super.new(name);
  endfunction

  function void validate_active_registry();
    int unsigned active_count;

    active_count = 0;
    if (p_sequencer.reset_vif == null)
      `uvm_fatal("CFG_RESET", "null reset_vif")
    for (int unsigned i = 0; i < PCIE_SVT_MAX_PORTS; i++) begin
      if (!p_sequencer.active_port[i])
        continue;
      active_count++;
      if ((p_sequencer.port_seqr[i] == null) ||
          (p_sequencer.port_status[i] == null) ||
          (p_sequencer.port_status[i].pcie_status == null) ||
          (p_sequencer.port_status[i].pcie_status.pl_status == null) ||
          (p_sequencer.port_profile[i] == null))
        `uvm_fatal("PORT_REGISTRY", $sformatf(
          "active port index %0d has incomplete sequencer/status/profile handles",
          i))
    end
    if (active_count == 0)
      `uvm_fatal("PORT_REGISTRY", "configuration init has no active ports")
  endfunction

  function void check_active_links_down(string stage);
    for (int unsigned i = 0; i < PCIE_SVT_MAX_PORTS; i++) begin
      if (!p_sequencer.active_port[i])
        continue;
      if (p_sequencer.port_status[i].pcie_status.pl_status.link_up !== 1'b0)
        `uvm_fatal("CFG_LINK_STATE", $sformatf(
          "stage=%s port=%s link_up=%b, expected known zero",
          stage, p_sequencer.port_profile[i].port_id,
          p_sequencer.port_status[i].pcie_status.pl_status.link_up))
      `uvm_info("CFG_LINK_DOWN", $sformatf(
        "stage=%s port=%s link_up=0", stage,
        p_sequencer.port_profile[i].port_id), UVM_NONE)
    end
  endfunction

  task refresh_multi_endpoint_cfg(int unsigned index);
    svt_pcie_device_agent_service_sequence refresh_seq;

    if (p_sequencer.port_profile[index].role == PCIE_SVT_RC) begin
      `uvm_info("MULTI_EP_REFRESH_SKIP", $sformatf(
        "port=%s role=RC REFRESH_CFG skipped",
        p_sequencer.port_profile[index].port_id), UVM_NONE)
      return;
    end
    if (p_sequencer.port_seqr[index].device_agent_service_seqr == null)
      `uvm_fatal("MULTI_EP_REFRESH", $sformatf(
        "port=%s has null device_agent_service_seqr",
        p_sequencer.port_profile[index].port_id))
    if ((p_sequencer.port_agent[index] == null) ||
        (p_sequencer.port_cfg[index] == null))
      `uvm_fatal("MULTI_EP_REFRESH", $sformatf(
        "port=%s has null agent or configuration registry handle",
        p_sequencer.port_profile[index].port_id))
    if (p_sequencer.port_cfg[index].device_is_root != 1'b0)
      `uvm_fatal("MULTI_EP_REFRESH", $sformatf(
        "port=%s EP configuration has device_is_root=%0b before refresh",
        p_sequencer.port_profile[index].port_id,
        p_sequencer.port_cfg[index].device_is_root))
    if (p_sequencer.port_cfg[index].pcie_cfg.enable_multi_endpoint_mode !=
        1'b1)
      `uvm_fatal("MULTI_EP_REFRESH", $sformatf(
        "port=%s EP configuration has Multi-Endpoint Mode disabled",
        p_sequencer.port_profile[index].port_id))

    // R-2020.12 refresh_cfg() re-reads cfg from the target agent's exact
    // config_db scope. Re-publish the original per-port object immediately
    // before issuing REFRESH_CFG so a default root configuration cannot be
    // selected by a broader or stale config_db entry.
    uvm_config_db#(svt_pcie_device_configuration)::set(
      p_sequencer.port_agent[index], "", "cfg",
      p_sequencer.port_cfg[index]);

    refresh_seq = svt_pcie_device_agent_service_sequence::type_id::create(
      $sformatf("refresh_port%0d", index));
    if ((refresh_seq == null) ||
        !refresh_seq.randomize() with {
          service_type == svt_pcie_device_agent_service::REFRESH_CFG;
        })
      `uvm_fatal("MULTI_EP_REFRESH", $sformatf(
        "port=%s REFRESH_CFG sequence creation/randomization failed",
        p_sequencer.port_profile[index].port_id))
    `uvm_info("MULTI_EP_REFRESH", $sformatf(
      "stage=before port=%s device_is_root=0 multi_endpoint=1 reset_asserted=0 link_up=0",
      p_sequencer.port_profile[index].port_id), UVM_NONE)
    refresh_seq.start(
      p_sequencer.port_seqr[index].device_agent_service_seqr);
    `uvm_info("MULTI_EP_REFRESH", $sformatf(
      "stage=after port=%s reset_asserted=0 link_up=0",
      p_sequencer.port_profile[index].port_id), UVM_NONE)
  endtask

  task run_one_port(int unsigned index);
    pcie_svt_cfg_space_init_seq child;
    bit child_started;
    bit child_done;
    realtime start_time;
    realtime deadline;
    realtime completion_time;

    child = pcie_svt_cfg_space_init_seq::type_id::create(
      $sformatf("init_port%0d", index));
    if (child == null)
      `uvm_fatal("CFG_INIT", $sformatf(
        "port index %0d child sequence creation failed", index))
    child.port_index = index;
    child.port_seqr = p_sequencer.port_seqr[index];
    child.port_status = p_sequencer.port_status[index];
    child.profile = p_sequencer.port_profile[index];
    child_started = 1'b0;
    child_done = 1'b0;
    start_time = 0;
    deadline = 0;
    completion_time = 0;
    fork
      begin
        start_time = $realtime;
        deadline = start_time + PCIE_SVT_CFG_INIT_WATCHDOG_TIME;
        child_started = 1'b1;
        child.start(null);
        completion_time = $realtime;
        child_done = 1'b1;
        if (completion_time > deadline)
          `uvm_fatal("CFG_INIT_TIMEOUT", $sformatf(
            "%s exceeded watchdog=%0t start=%0.6f deadline=%0.6f completion=%0.6f",
            child.progress_context(), PCIE_SVT_CFG_INIT_WATCHDOG_TIME,
            start_time, deadline, completion_time))
      end
      begin
        wait (child_started);
        if ($realtime < deadline)
          #(deadline - $realtime);
        // Let completion scheduled exactly at the deadline settle first.
        if (!child_done)
          #1step;
        if (!child_done)
          `uvm_fatal("CFG_INIT_TIMEOUT", $sformatf(
            "%s exceeded watchdog=%0t start=%0.6f deadline=%0.6f current=%0.6f",
            child.progress_context(), PCIE_SVT_CFG_INIT_WATCHDOG_TIME,
            start_time, deadline, $realtime))
        else if (completion_time > deadline)
          `uvm_fatal("CFG_INIT_TIMEOUT", $sformatf(
            "%s exceeded watchdog=%0t start=%0.6f deadline=%0.6f completion=%0.6f",
            child.progress_context(), PCIE_SVT_CFG_INIT_WATCHDOG_TIME,
            start_time, deadline, completion_time))
      end
    join_any
    disable fork;
  endtask

  virtual task body();
    pcie_svt_r202012_multi_ep_warning_catcher warning_catcher;
    int unsigned expected_vendor_warnings;

    if (p_sequencer == null)
      `uvm_fatal("CFG_INIT", "null PCIe SVT virtual sequencer")
    validate_active_registry();
    if (p_sequencer.reset_vif.asserted !== '1)
      `uvm_fatal("CFG_RESET", $sformatf(
        "stage=vip_init_hold expected all resets asserted, got 0x%0h",
        p_sequencer.reset_vif.asserted))
    `uvm_info("CFG_RESET_ASSERTED", $sformatf(
      "stage=vip_init_hold asserted=0x%0h hold=%0t",
      p_sequencer.reset_vif.asserted, PCIE_SVT_VIP_INIT_HOLD_TIME), UVM_NONE)

    #(PCIE_SVT_VIP_INIT_HOLD_TIME);
    check_active_links_down("before_release");
    p_sequencer.reset_vif.release_all();
    #0;
    if (p_sequencer.reset_vif.asserted !== '0)
      `uvm_fatal("CFG_RESET", $sformatf(
        "stage=cfg_init expected all resets released, got 0x%0h",
        p_sequencer.reset_vif.asserted))
    `uvm_info("CFG_RESET_RELEASED", $sformatf(
      "stage=cfg_init asserted=0x%0h",
      p_sequencer.reset_vif.asserted), UVM_NONE)
    check_active_links_down("before_cfg");

    warning_catcher =
      pcie_svt_r202012_multi_ep_warning_catcher::type_id::create(
        "r202012_multi_ep_warning_catcher");
    if (warning_catcher == null)
      `uvm_fatal("MULTI_EP_REFRESH", "vendor warning catcher creation failed")
    expected_vendor_warnings = 0;
    uvm_report_cb::add(null, warning_catcher);
    for (int unsigned i = 0; i < PCIE_SVT_MAX_PORTS; i++) begin
      if (p_sequencer.active_port[i]) begin
        if (p_sequencer.port_profile[i].role == PCIE_SVT_EP)
          expected_vendor_warnings++;
        refresh_multi_endpoint_cfg(i);
      end
    end
    uvm_report_cb::delete(null, warning_catcher);
    if (warning_catcher.matched_count != expected_vendor_warnings)
      `uvm_fatal("MULTI_EP_REFRESH", $sformatf(
        "R-2020.12 vendor warning count expected=%0d got=%0d",
        expected_vendor_warnings, warning_catcher.matched_count))
    if (warning_catcher.matched_count != 0)
      `uvm_info("MULTI_EP_REFRESH_VENDOR_WORKAROUND", $sformatf(
        "caught %0d known R-2020.12 REFRESH_CFG role-validation warnings",
        warning_catcher.matched_count), UVM_NONE)

    for (int unsigned i = 0; i < PCIE_SVT_MAX_PORTS; i++) begin
      if (!p_sequencer.active_port[i])
        continue;
      fork
        automatic int unsigned index = i;
        run_one_port(index);
      join_none
    end
    wait fork;

    if (p_sequencer.reset_vif.asserted !== '0)
      `uvm_fatal("CFG_RESET", $sformatf(
        "stage=complete reset was reasserted, asserted=0x%0h",
        p_sequencer.reset_vif.asserted))
    check_active_links_down("after_cfg");
    for (int unsigned i = 0; i < PCIE_SVT_MAX_PORTS; i++)
      if (p_sequencer.active_port[i])
        `uvm_info("CFG_INIT_DONE", $sformatf(
          "port=%s cfg_reqs=%0d reset_asserted=0x%0h link_up=0",
          p_sequencer.port_profile[i].port_id,
          p_sequencer.port_seqr[i].cfg_database_seqr.get_num_reqs_sent(),
          p_sequencer.reset_vif.asserted), UVM_NONE)
  endtask
endclass
