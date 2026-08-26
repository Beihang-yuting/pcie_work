class pcie_svt_link_enable_port_sequence extends
    uvm_sequence #(uvm_sequence_item);
  string link_id;
  svt_pcie_device_virtual_sequencer port_seqr;

  `uvm_object_utils(pcie_svt_link_enable_port_sequence)

  function new(string name = "pcie_svt_link_enable_port_sequence");
    super.new(name);
  endfunction

  virtual task body();
    svt_pcie_dl_service_set_link_en_sequence link_enable;
    svt_pcie_pl_service_set_phy_en_sequence phy_enable;

    if ((port_seqr == null) || (port_seqr.pcie_virt_seqr == null) ||
        (port_seqr.pcie_virt_seqr.dl_seqr == null) ||
        (port_seqr.pcie_virt_seqr.pl_seqr == null)) begin
      `uvm_fatal("SVT_LINK_HANDLE", {link_id,
        ": incomplete device/PCIe/DL/PL sequencer hierarchy"})
      return;
    end
    link_enable =
      svt_pcie_dl_service_set_link_en_sequence::type_id::create(
        {link_id, "_link_enable"});
    phy_enable =
      svt_pcie_pl_service_set_phy_en_sequence::type_id::create(
        {link_id, "_phy_enable"});
    if ((link_enable == null) || (phy_enable == null)) begin
      `uvm_fatal("SVT_LINK_HANDLE", {link_id,
        ": link/PHY enable sequence creation failed"})
      return;
    end
    if (!link_enable.randomize() with { enable == 1'b1; }) begin
      `uvm_fatal("SVT_LINK_ENABLE", {link_id,
        ": DL link-enable randomization failed"})
      return;
    end
    if (!phy_enable.randomize() with { phy_enable == 1'b1; }) begin
      `uvm_fatal("SVT_LINK_ENABLE", {link_id,
        ": PL PHY-enable randomization failed"})
      return;
    end
    fork
      link_enable.start(port_seqr.pcie_virt_seqr.dl_seqr);
      phy_enable.start(port_seqr.pcie_virt_seqr.pl_seqr);
    join
  endtask
endclass

class pcie_svt_link_vseq extends uvm_sequence #(uvm_sequence_item);
  pcie_svt_topology_virtual_sequencer primary_seqr;
  pcie_svt_topology_virtual_sequencer peer_seqr;

  `uvm_object_utils(pcie_svt_link_vseq)

  function new(string name = "pcie_svt_link_vseq");
    super.new(name);
  endfunction

  protected function svt_pcie_pl_status::link_speed_enum expected_speed(
      int unsigned max_gen);
    return (max_gen == 5) ? svt_pcie_pl_status::SPEED_32_0G :
                            svt_pcie_pl_status::SPEED_16_0G;
  endfunction

  protected function void collect_sorted_primary_links(
      output string link_ids[$]);
    link_ids.delete();
    foreach (primary_seqr.descriptor_by_link[link_id])
      link_ids.push_back(link_id);
    for (int i = 0; i < link_ids.size(); i++) begin
      for (int j = i + 1; j < link_ids.size(); j++) begin
        if (link_ids[j] < link_ids[i]) begin
          string temporary;
          temporary = link_ids[i];
          link_ids[i] = link_ids[j];
          link_ids[j] = temporary;
        end
      end
    end
  endfunction

  protected function bit find_peer_by_slot(
      int unsigned slot_index,
      output string peer_link_id,
      output pcie_svt_port_descriptor peer_descriptor);
    bit found;

    found = 1'b0;
    peer_link_id = "";
    peer_descriptor = null;
    foreach (peer_seqr.descriptor_by_link[link_id]) begin
      pcie_svt_port_descriptor candidate;
      candidate = peer_seqr.descriptor_by_link[link_id];
      if ((candidate != null) &&
          (candidate.slot_index == slot_index)) begin
        if (found)
          return 1'b0;
        found = 1'b1;
        peer_link_id = link_id;
        peer_descriptor = candidate;
      end
    end
    return found;
  endfunction

  protected function bit link_handles_are_valid(
      pcie_svt_topology_virtual_sequencer selected_seqr,
      string link_id);
    svt_pcie_device_status status;
    svt_pcie_device_virtual_sequencer port_seqr;

    if ((selected_seqr == null) ||
        !selected_seqr.descriptor_by_link.exists(link_id) ||
        !selected_seqr.cfg_by_link.exists(link_id) ||
        !selected_seqr.status_by_link.exists(link_id) ||
        !selected_seqr.agent_by_link.exists(link_id))
      return 1'b0;
    status = selected_seqr.status_by_link[link_id];
    port_seqr = selected_seqr.get_port_seqr(link_id);
    return (selected_seqr.descriptor_by_link[link_id] != null) &&
           (selected_seqr.cfg_by_link[link_id] != null) &&
           (selected_seqr.agent_by_link[link_id] != null) &&
           (port_seqr != null) && (port_seqr.pcie_virt_seqr != null) &&
           (port_seqr.pcie_virt_seqr.dl_seqr != null) &&
           (port_seqr.pcie_virt_seqr.pl_seqr != null) &&
           (status != null) && (status.pcie_status != null) &&
           (status.pcie_status.pl_status != null) &&
           (status.pcie_status.dl_status != null);
  endfunction

  protected function bit pair_is_ready(
      pcie_svt_port_descriptor descriptor,
      svt_pcie_device_status primary_status,
      svt_pcie_device_status peer_status);
    svt_pcie_pl_status::link_speed_enum speed;

    speed = expected_speed(descriptor.max_gen);
    return (primary_status.pcie_status.pl_status.link_up === 1'b1) &&
      (primary_status.pcie_status.dl_status.dl_link_up === 1'b1) &&
      (primary_status.pcie_status.pl_status.ltssm_state ==
        svt_pcie_types::L0) &&
      (primary_status.pcie_status.pl_status.current_speed == speed) &&
      (primary_status.pcie_status.pl_status.negotiated_link_width ==
        descriptor.link_width) &&
      (peer_status.pcie_status.pl_status.link_up === 1'b1) &&
      (peer_status.pcie_status.dl_status.dl_link_up === 1'b1) &&
      (peer_status.pcie_status.pl_status.ltssm_state ==
        svt_pcie_types::L0) &&
      (peer_status.pcie_status.pl_status.current_speed == speed) &&
      (peer_status.pcie_status.pl_status.negotiated_link_width ==
        descriptor.link_width);
  endfunction

  protected task enable_port(
      pcie_svt_topology_virtual_sequencer selected_seqr,
      string link_id,
      string side);
    pcie_svt_link_enable_port_sequence child;

    child = pcie_svt_link_enable_port_sequence::type_id::create(
      {side, "_", link_id, "_enable"});
    if (child == null) begin
      `uvm_fatal("SVT_LINK_HANDLE", {side, " link=", link_id,
        " enable child creation failed"})
      return;
    end
    child.link_id = {side, ":", link_id};
    child.port_seqr = selected_seqr.get_port_seqr(link_id);
    child.start(null);
  endtask

  protected task train_pair(string primary_link_id);
    pcie_svt_port_descriptor primary_descriptor;
    pcie_svt_port_descriptor peer_descriptor;
    svt_pcie_device_status primary_status;
    svt_pcie_device_status peer_status;
    string peer_link_id;
    bit reached;
    realtime start_time;
    realtime deadline;
    realtime completion_time;
    svt_pcie_pl_status::link_speed_enum speed;

    primary_descriptor = primary_seqr.get_port_descriptor(primary_link_id);
    if ((primary_descriptor == null) ||
        !find_peer_by_slot(primary_descriptor.slot_index,
                           peer_link_id, peer_descriptor) ||
        (peer_descriptor == null)) begin
      primary_seqr.link_state[primary_link_id] = PCIE_SVT_STAGE_FAIL;
      `uvm_fatal("SVT_LINK_PAIR", $sformatf(
        "primary=%s slot=%0d does not resolve exactly one peer",
        primary_link_id, (primary_descriptor == null) ? 0 :
          primary_descriptor.slot_index))
      return;
    end
    if ((peer_descriptor.role == primary_descriptor.role) ||
        (peer_descriptor.physical_width !=
          primary_descriptor.physical_width) ||
        (peer_descriptor.link_width != primary_descriptor.link_width) ||
        (peer_descriptor.max_gen != primary_descriptor.max_gen) ||
        (peer_descriptor.fast_link_training !=
          primary_descriptor.fast_link_training) ||
        (peer_descriptor.link_timeout != primary_descriptor.link_timeout)) begin
      primary_seqr.link_state[primary_link_id] = PCIE_SVT_STAGE_FAIL;
      `uvm_fatal("SVT_LINK_PAIR", $sformatf(
        {"primary=%s peer=%s slot=%0d has role/physical-width/active-width/",
         "generation/fast/timeout mismatch"},
        primary_link_id, peer_link_id, primary_descriptor.slot_index))
      return;
    end
    if (!link_handles_are_valid(primary_seqr, primary_link_id) ||
        !link_handles_are_valid(peer_seqr, peer_link_id)) begin
      primary_seqr.link_state[primary_link_id] = PCIE_SVT_STAGE_FAIL;
      `uvm_fatal("SVT_LINK_HANDLE", $sformatf(
        "primary=%s peer=%s has incomplete link handles",
        primary_link_id, peer_link_id))
      return;
    end
    if ((primary_seqr.cfg_state[primary_link_id] != PCIE_SVT_STAGE_PASS) ||
        (peer_seqr.cfg_state[peer_link_id] != PCIE_SVT_STAGE_PASS)) begin
      primary_seqr.link_state[primary_link_id] = PCIE_SVT_STAGE_FAIL;
      `uvm_fatal("SVT_LINK_ORDER", $sformatf(
        "primary=%s peer=%s requires both CFG stages PASS",
        primary_link_id, peer_link_id))
      return;
    end

    primary_status = primary_seqr.status_by_link[primary_link_id];
    peer_status = peer_seqr.status_by_link[peer_link_id];
    speed = expected_speed(primary_descriptor.max_gen);
    reached = 1'b0;
    start_time = $realtime;
    deadline = start_time + primary_descriptor.link_timeout;
    completion_time = 0;
    fork
      begin
        fork
          enable_port(primary_seqr, primary_link_id, "primary");
          enable_port(peer_seqr, peer_link_id, "peer");
        join
        // Keep every changing status field in the wait expression.  Passing
        // only class handles through a helper function leaves VCS with no
        // member-field sensitivity and the wait never re-evaluates.
        wait (
          (primary_status.pcie_status.pl_status.link_up === 1'b1) &&
          (primary_status.pcie_status.dl_status.dl_link_up === 1'b1) &&
          (primary_status.pcie_status.pl_status.ltssm_state ==
            svt_pcie_types::L0) &&
          (primary_status.pcie_status.pl_status.current_speed == speed) &&
          (primary_status.pcie_status.pl_status.negotiated_link_width ==
            primary_descriptor.link_width) &&
          (peer_status.pcie_status.pl_status.link_up === 1'b1) &&
          (peer_status.pcie_status.dl_status.dl_link_up === 1'b1) &&
          (peer_status.pcie_status.pl_status.ltssm_state ==
            svt_pcie_types::L0) &&
          (peer_status.pcie_status.pl_status.current_speed == speed) &&
          (peer_status.pcie_status.pl_status.negotiated_link_width ==
            primary_descriptor.link_width));
        completion_time = $realtime;
        reached = 1'b1;
      end
      begin
        if ($realtime < deadline)
          #(deadline - $realtime);
        if (!reached)
          #1step;
      end
    join_any
    disable fork;

    if (!reached || (completion_time > deadline)) begin
      primary_seqr.link_state[primary_link_id] = PCIE_SVT_STAGE_FAIL;
      `uvm_fatal("SVT_LINK_TIMEOUT", $sformatf(
        {"primary=%s role=%s peer=%s role=%s primary_pl=%0b ",
         "primary_dl=%0b primary_ltssm=%s primary_speed=%s ",
         "primary_width=x%0d peer_pl=%0b peer_dl=%0b peer_ltssm=%s ",
         "peer_speed=%s peer_width=x%0d expected_speed=%s ",
         "expected_width=x%0d timeout=%0t start=%0.6f deadline=%0.6f ",
         "completion=%0.6f current=%0.6f"},
        primary_link_id, primary_descriptor.role.name(),
        peer_link_id, peer_descriptor.role.name(),
        primary_status.pcie_status.pl_status.link_up,
        primary_status.pcie_status.dl_status.dl_link_up,
        primary_status.pcie_status.pl_status.ltssm_state.name(),
        primary_status.pcie_status.pl_status.current_speed.name(),
        primary_status.pcie_status.pl_status.negotiated_link_width,
        peer_status.pcie_status.pl_status.link_up,
        peer_status.pcie_status.dl_status.dl_link_up,
        peer_status.pcie_status.pl_status.ltssm_state.name(),
        peer_status.pcie_status.pl_status.current_speed.name(),
        peer_status.pcie_status.pl_status.negotiated_link_width,
        speed.name(), primary_descriptor.link_width,
        primary_descriptor.link_timeout, start_time, deadline,
        completion_time, $realtime))
      return;
    end
    if (!pair_is_ready(primary_descriptor, primary_status, peer_status)) begin
      primary_seqr.link_state[primary_link_id] = PCIE_SVT_STAGE_FAIL;
      `uvm_fatal("SVT_LINK_RESULT", $sformatf(
        "primary=%s peer=%s failed final paired-link recheck",
        primary_link_id, peer_link_id))
      return;
    end
    primary_seqr.link_state[primary_link_id] = PCIE_SVT_STAGE_PASS;
    `uvm_info("PCIE_SVT_LINK_PASS", $sformatf(
      {"primary=%s peer=%s primary_role=%s peer_role=%s gen=%0d ",
       "speed=%s width=x%0d"},
      primary_link_id, peer_link_id, primary_descriptor.role.name(),
      peer_descriptor.role.name(), primary_descriptor.max_gen,
      speed.name(), primary_descriptor.link_width), UVM_NONE)
  endtask

  virtual task body();
    string primary_links[$];

    if ((primary_seqr == null) || (peer_seqr == null) ||
        (primary_seqr.reset_vif == null) ||
        (peer_seqr.reset_vif == null)) begin
      `uvm_fatal("SVT_LINK_HANDLE",
        "paired link training requires primary/peer sequencers and reset VIFs")
      return;
    end
    if (primary_seqr.descriptor_by_link.num() !=
        peer_seqr.descriptor_by_link.num()) begin
      `uvm_fatal("SVT_LINK_PAIR", $sformatf(
        "primary count=%0d peer count=%0d",
        primary_seqr.descriptor_by_link.num(),
        peer_seqr.descriptor_by_link.num()))
      return;
    end
    if ((primary_seqr.reset_vif.asserted !== '0) ||
        (peer_seqr.reset_vif.asserted !== '0)) begin
      `uvm_fatal("SVT_LINK_RESET", $sformatf(
        "link training requires released resets primary=0x%0h peer=0x%0h",
        primary_seqr.reset_vif.asserted, peer_seqr.reset_vif.asserted))
      return;
    end

    collect_sorted_primary_links(primary_links);
    if (primary_links.size() == 0) begin
      `uvm_fatal("SVT_LINK_PAIR", "no primary links are registered")
      return;
    end
    foreach (primary_links[i]) begin
      fork
        automatic string link_id = primary_links[i];
        train_pair(link_id);
      join_none
    end
    wait fork;
  endtask
endclass
