class pcie_svt_real_switch_links_vseq extends
    uvm_sequence #(uvm_sequence_item);
  localparam int unsigned PCIE_SVT_REAL_SWITCH_PORT_COUNT = 5;
  localparam time PCIE_SVT_LINK_TIMEOUT = 3ms;
  localparam time PCIE_SVT_LINK_ENABLE_WATCHDOG_TIME = 10us;

  `uvm_object_utils(pcie_svt_real_switch_links_vseq)
  `uvm_declare_p_sequencer(pcie_svt_virtual_sequencer)

  function new(string name = "pcie_svt_real_switch_links_vseq");
    super.new(name);
  endfunction

  function automatic int unsigned primary_index(int unsigned slot);
    case (slot)
      0: return PCIE_SVT_PRIMARY_RC0;
      1: return PCIE_SVT_PRIMARY_EP0;
      2: return PCIE_SVT_PRIMARY_EP1;
      3: return PCIE_SVT_PRIMARY_EP2;
      4: return PCIE_SVT_PRIMARY_EP3;
      default: begin
        `uvm_fatal("REAL_SWITCH_LINK_REGISTRY", $sformatf(
          "invalid real-Switch primary slot=%0d", slot))
        return PCIE_SVT_PRIMARY_RC0;
      end
    endcase
  endfunction

  function void validate_port(int unsigned slot);
    int unsigned index;
    int unsigned expected_width;
    pcie_svt_role_e expected_role;

    index = primary_index(slot);
    expected_width = (slot == 0) ? 16 : 4;
    expected_role = (slot == 0) ? PCIE_SVT_RC : PCIE_SVT_EP;
    if (!p_sequencer.active_port[index] ||
        (p_sequencer.port_agent[index] == null) ||
        (p_sequencer.port_cfg[index] == null) ||
        (p_sequencer.port_profile[index] == null) ||
        (p_sequencer.port_seqr[index] == null) ||
        (p_sequencer.port_status[index] == null) ||
        (p_sequencer.port_status[index].pcie_status == null) ||
        (p_sequencer.port_status[index].pcie_status.pl_status == null) ||
        (p_sequencer.port_status[index].pcie_status.dl_status == null))
      `uvm_fatal("REAL_SWITCH_LINK_REGISTRY", $sformatf(
        "inactive or incomplete real-Switch primary port index=%0d", index))
    if ((p_sequencer.port_profile[index].role != expected_role) ||
        (p_sequencer.port_profile[index].link_width != expected_width) ||
        !((p_sequencer.port_profile[index].max_gen == 4) ||
          (p_sequencer.port_profile[index].max_gen == 5)))
      `uvm_fatal("REAL_SWITCH_LINK_PROFILE", $sformatf(
        {"port=%s index=%0d role=%0d expected_role=%0d width=%0d ",
         "expected_width=%0d max_gen=%0d expected_gen=4_or_5"},
        p_sequencer.port_profile[index].port_id, index,
        p_sequencer.port_profile[index].role, expected_role,
        p_sequencer.port_profile[index].link_width, expected_width,
        p_sequencer.port_profile[index].max_gen))
  endfunction

  protected function bit current_link_ready(
      pcie_svt_port_profile profile,
      svt_pcie_pl_status pl,
      svt_pcie_dl_status dl);
    int unsigned actual_gen;
    bit reached;

    actual_gen = (pl.current_speed == svt_pcie_pl_status::SPEED_32_0G) ? 5 :
                 (pl.current_speed == svt_pcie_pl_status::SPEED_16_0G) ? 4 : 0;
    reached = pcie_svt_real_switch_link_gate::ready(
      profile.max_gen, profile.link_width,
      pl.link_up, dl.dl_link_up,
      pl.ltssm_state == svt_pcie_types::L0,
      actual_gen, pl.negotiated_link_width);
    return reached;
  endfunction

  protected task wait_until_ready(
      pcie_svt_port_profile profile,
      svt_pcie_pl_status pl,
      svt_pcie_dl_status dl);
    wait (pcie_svt_real_switch_link_gate::ready(
      profile.max_gen, profile.link_width,
      pl.link_up, dl.dl_link_up,
      pl.ltssm_state == svt_pcie_types::L0,
      (pl.current_speed == svt_pcie_pl_status::SPEED_32_0G) ? 5 :
      (pl.current_speed == svt_pcie_pl_status::SPEED_16_0G) ? 4 : 0,
      pl.negotiated_link_width));
  endtask

  task automatic enable_port(int unsigned index);
    pcie_svt_link_bringup_seq child;
    bit child_done;
    realtime start_time;
    realtime deadline;
    realtime completion_time;

    child = pcie_svt_link_bringup_seq::type_id::create(
      $sformatf("enable_port_%0d", index));
    if (child == null)
      `uvm_fatal("LINK_EN", $sformatf(
        "link-enable child creation failed for index=%0d", index))
    child.port_id = p_sequencer.port_profile[index].port_id;
    child.port_seqr = p_sequencer.port_seqr[index];
    child_done = 1'b0;
    start_time = $realtime;
    deadline = start_time + PCIE_SVT_LINK_ENABLE_WATCHDOG_TIME;
    completion_time = 0;
    fork
      begin
        child.start(null);
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
    if (!child_done)
      `uvm_fatal("LINK_ENABLE_TIMEOUT", $sformatf(
        {"port=%s index=%0d exceeded watchdog=%0t start=%0.6f ",
         "deadline=%0.6f current=%0.6f"}, child.port_id, index,
        PCIE_SVT_LINK_ENABLE_WATCHDOG_TIME, start_time, deadline,
        $realtime))
    else if (completion_time > deadline)
      `uvm_fatal("LINK_ENABLE_TIMEOUT", $sformatf(
        {"port=%s index=%0d exceeded watchdog=%0t start=%0.6f ",
         "deadline=%0.6f completion=%0.6f"}, child.port_id, index,
        PCIE_SVT_LINK_ENABLE_WATCHDOG_TIME, start_time, deadline,
        completion_time))
  endtask

  task automatic wait_for_port(int unsigned index);
    pcie_svt_port_profile profile;
    svt_pcie_pl_status pl;
    svt_pcie_dl_status dl;
    int unsigned actual_gen;
    bit reached;
    realtime start_time;
    realtime deadline;
    realtime completion_time;

    profile = p_sequencer.port_profile[index];
    pl = p_sequencer.port_status[index].pcie_status.pl_status;
    dl = p_sequencer.port_status[index].pcie_status.dl_status;
    reached = 1'b0;
    start_time = $realtime;
    deadline = start_time + PCIE_SVT_LINK_TIMEOUT;
    completion_time = 0;

    fork
      begin
        wait_until_ready(profile, pl, dl);
        completion_time = $realtime;
        reached = 1'b1;
      end
      begin
        if ($realtime < deadline)
          #(deadline - $realtime);
        // Let completion scheduled exactly at the deadline settle first.
        if (!reached)
          #1step;
      end
    join_any
    disable fork;

    actual_gen =
      (pl.current_speed == svt_pcie_pl_status::SPEED_32_0G) ? 5 :
      (pl.current_speed == svt_pcie_pl_status::SPEED_16_0G) ? 4 : 0;
    if (!reached || (completion_time > deadline))
      `uvm_fatal("REAL_SWITCH_LINK_TIMEOUT", $sformatf(
        {"port=%s index=%0d pl_up=%0b dl_up=%0b ltssm=%s speed=%s ",
         "actual_width=%0d expected_gen=%0d expected_width=%0d ",
         "timeout=%0t start=%0.6f deadline=%0.6f current=%0.6f"},
        profile.port_id, index, pl.link_up, dl.dl_link_up,
        pl.ltssm_state.name(), pl.current_speed.name(),
        pl.negotiated_link_width, profile.max_gen, profile.link_width,
        PCIE_SVT_LINK_TIMEOUT, start_time, deadline, $realtime))

    `uvm_info("REAL_SWITCH_LINK_PASS", $sformatf(
      "port=%s index=%0d gen=%0d width=x%0d",
      profile.port_id, index, actual_gen, pl.negotiated_link_width), UVM_NONE)
  endtask

  virtual task body();
    if (p_sequencer == null)
      `uvm_fatal("REAL_SWITCH_LINK_REGISTRY",
        "null PCIe SVT virtual sequencer")
    if (p_sequencer.reset_vif == null)
      `uvm_fatal("REAL_SWITCH_LINK_RESET", "null reset_vif")
    if (p_sequencer.reset_vif.asserted !== '0)
      `uvm_fatal("REAL_SWITCH_LINK_RESET", $sformatf(
        "link enable requires released resets, asserted=0x%0h",
        p_sequencer.reset_vif.asserted))

    for (int unsigned slot = 0;
         slot < PCIE_SVT_REAL_SWITCH_PORT_COUNT; slot++)
      validate_port(slot);

    for (int unsigned slot = 0;
         slot < PCIE_SVT_REAL_SWITCH_PORT_COUNT; slot++) begin
      fork
        automatic int unsigned index = primary_index(slot);
        enable_port(index);
      join_none
    end
    wait fork;

    for (int unsigned slot = 0;
         slot < PCIE_SVT_REAL_SWITCH_PORT_COUNT; slot++) begin
      fork
        automatic int unsigned index = primary_index(slot);
        wait_for_port(index);
      join_none
    end
    wait fork;

    for (int unsigned slot = 0;
         slot < PCIE_SVT_REAL_SWITCH_PORT_COUNT; slot++) begin
      int unsigned index;
      pcie_svt_port_profile profile;
      svt_pcie_pl_status pl;
      svt_pcie_dl_status dl;
      int unsigned actual_gen;

      index = primary_index(slot);
      profile = p_sequencer.port_profile[index];
      pl = p_sequencer.port_status[index].pcie_status.pl_status;
      dl = p_sequencer.port_status[index].pcie_status.dl_status;
      actual_gen =
        (pl.current_speed == svt_pcie_pl_status::SPEED_32_0G) ? 5 :
        (pl.current_speed == svt_pcie_pl_status::SPEED_16_0G) ? 4 : 0;
      if (!current_link_ready(profile, pl, dl))
        `uvm_fatal("REAL_SWITCH_LINK_LOST", $sformatf(
          {"port=%s index=%0d pl_up=%0b dl_up=%0b ltssm=%s speed=%s ",
           "actual_gen=%0d actual_width=%0d expected_gen=%0d ",
           "expected_width=%0d stage=aggregate_recheck"},
          profile.port_id, index, pl.link_up, dl.dl_link_up,
          pl.ltssm_state.name(), pl.current_speed.name(), actual_gen,
          pl.negotiated_link_width, profile.max_gen, profile.link_width))
    end

    `uvm_info("REAL_SWITCH_ALL_LINKS_PASS", "count=5", UVM_NONE)
  endtask
endclass
