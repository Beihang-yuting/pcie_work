class pcie_svt_all_links_bringup_vseq extends
    uvm_sequence #(uvm_sequence_item);
  localparam time PCIE_SVT_LINK_TIMEOUT = 3ms;

  `uvm_object_utils(pcie_svt_all_links_bringup_vseq)
  `uvm_declare_p_sequencer(pcie_svt_virtual_sequencer)

  function new(string name = "pcie_svt_all_links_bringup_vseq");
    super.new(name);
  endfunction

  function string speed_text(int unsigned max_gen);
    return (max_gen == 5) ? "32GT/s" : "16GT/s";
  endfunction

  function void validate_port(int unsigned index);
    if ((index >= PCIE_SVT_MAX_PORTS) || !p_sequencer.active_port[index] ||
        (p_sequencer.port_agent[index] == null) ||
        (p_sequencer.port_cfg[index] == null) ||
        (p_sequencer.port_profile[index] == null) ||
        (p_sequencer.port_seqr[index] == null) ||
        (p_sequencer.port_agent[index].pcie_agent == null) ||
        (p_sequencer.port_agent[index].pcie_agent.tlp_seqr == null) ||
        (p_sequencer.port_status[index] == null) ||
        (p_sequencer.port_status[index].pcie_status == null) ||
        (p_sequencer.port_status[index].pcie_status.pl_status == null))
      `uvm_fatal("LINK_REGISTRY", $sformatf(
        "inactive or incomplete link port index=%0d", index))
  endfunction

  task automatic enable_port(int unsigned index);
    pcie_svt_link_bringup_seq child;
    child = pcie_svt_link_bringup_seq::type_id::create(
      $sformatf("enable_port_%0d", index));
    if (child == null)
      `uvm_fatal("LINK_EN", $sformatf(
        "link-enable child creation failed for index=%0d", index))
    child.port_id = p_sequencer.port_profile[index].port_id;
    child.port_seqr = p_sequencer.port_seqr[index];
    child.start(null);
  endtask

  task automatic wait_for_pair(int unsigned primary_index,
                               int unsigned peer_index);
    pcie_svt_port_profile primary_profile;
    pcie_svt_port_profile peer_profile;
    svt_pcie_device_status primary_status;
    svt_pcie_device_status peer_status;
    svt_pcie_pl_status::link_speed_enum expected_speed;
    bit reached_l0;

    primary_profile = p_sequencer.port_profile[primary_index];
    peer_profile = p_sequencer.port_profile[peer_index];
    primary_status = p_sequencer.port_status[primary_index];
    peer_status = p_sequencer.port_status[peer_index];
    expected_speed = (primary_profile.max_gen == 5) ?
      svt_pcie_pl_status::SPEED_32_0G : svt_pcie_pl_status::SPEED_16_0G;
    reached_l0 = 1'b0;

    fork
      begin
        wait (primary_status.pcie_status.pl_status.link_up == 1'b1 &&
              peer_status.pcie_status.pl_status.link_up == 1'b1 &&
              primary_status.pcie_status.pl_status.ltssm_state ==
                svt_pcie_types::L0 &&
              peer_status.pcie_status.pl_status.ltssm_state ==
                svt_pcie_types::L0 &&
              primary_status.pcie_status.pl_status.current_speed ==
                expected_speed &&
              peer_status.pcie_status.pl_status.current_speed ==
                expected_speed &&
              primary_status.pcie_status.pl_status.negotiated_link_width ==
                primary_profile.link_width &&
              peer_status.pcie_status.pl_status.negotiated_link_width ==
                primary_profile.link_width);
        reached_l0 = 1'b1;
      end
      begin
        #(PCIE_SVT_LINK_TIMEOUT);
      end
    join_any
    disable fork;

    if (!reached_l0)
      `uvm_fatal("LINK_TIMEOUT", $sformatf(
        {"primary=%s peer=%s primary_up=%0b peer_up=%0b ",
         "primary_state=%s peer_state=%s primary_speed=%s peer_speed=%s ",
         "primary_width=%0d peer_width=%0d expected_speed=%s ",
         "expected_width=%0d timeout=%0t"},
        primary_profile.port_id, peer_profile.port_id,
        primary_status.pcie_status.pl_status.link_up,
        peer_status.pcie_status.pl_status.link_up,
        primary_status.pcie_status.pl_status.ltssm_state.name(),
        peer_status.pcie_status.pl_status.ltssm_state.name(),
        primary_status.pcie_status.pl_status.current_speed.name(),
        peer_status.pcie_status.pl_status.current_speed.name(),
        primary_status.pcie_status.pl_status.negotiated_link_width,
        peer_status.pcie_status.pl_status.negotiated_link_width,
        expected_speed.name(), primary_profile.link_width,
        PCIE_SVT_LINK_TIMEOUT))

    if ((primary_profile.max_gen != peer_profile.max_gen) ||
        (primary_profile.link_width != peer_profile.link_width) ||
        (primary_status.pcie_status.pl_status.current_speed != expected_speed) ||
        (peer_status.pcie_status.pl_status.current_speed != expected_speed) ||
        (primary_status.pcie_status.pl_status.negotiated_link_width !=
          primary_profile.link_width) ||
        (peer_status.pcie_status.pl_status.negotiated_link_width !=
          primary_profile.link_width))
      `uvm_fatal("LINK_RESULT", $sformatf(
        {"primary=%s peer=%s negotiated speed or width mismatch: ",
         "primary_speed=%s peer_speed=%s primary_width=%0d peer_width=%0d ",
         "expected_speed=%s expected_width=%0d"},
        primary_profile.port_id, peer_profile.port_id,
        primary_status.pcie_status.pl_status.current_speed.name(),
        peer_status.pcie_status.pl_status.current_speed.name(),
        primary_status.pcie_status.pl_status.negotiated_link_width,
        peer_status.pcie_status.pl_status.negotiated_link_width,
        expected_speed.name(), primary_profile.link_width))

    `uvm_info("LINK_PASS", $sformatf(
      "primary=%s peer=%s width=%0d speed=%s",
      primary_profile.port_id, peer_profile.port_id,
      primary_profile.link_width, speed_text(primary_profile.max_gen)), UVM_NONE)
  endtask

  virtual task body();
    if (p_sequencer == null)
      `uvm_fatal("LINK_REGISTRY", "null PCIe SVT virtual sequencer")
    if (p_sequencer.reset_vif.asserted !== '0)
      `uvm_fatal("LINK_RESET", $sformatf(
        "link enable requires released resets, asserted=0x%0h",
        p_sequencer.reset_vif.asserted))

`ifdef PCIE_TOPO_EP_X16
    validate_port(PCIE_SVT_PRIMARY_RC0);
    validate_port(PCIE_SVT_PEER_PORT0);
    fork
      enable_port(PCIE_SVT_PRIMARY_RC0);
      enable_port(PCIE_SVT_PEER_PORT0);
    join
    wait_for_pair(PCIE_SVT_PRIMARY_RC0, PCIE_SVT_PEER_PORT0);
`elsif PCIE_TOPO_SWITCH_1X16_4X4
    for (int unsigned i = 0; i < PCIE_SVT_MAX_PORTS; i++)
      validate_port(i);
    for (int unsigned i = 0; i < PCIE_SVT_MAX_PORTS; i++) begin
      fork
        automatic int unsigned index = i;
        enable_port(index);
      join_none
    end
    wait fork;
    fork
      wait_for_pair(PCIE_SVT_PRIMARY_RC0, PCIE_SVT_PEER_PORT0);
      wait_for_pair(PCIE_SVT_PRIMARY_EP0, PCIE_SVT_PEER_PORT1);
      wait_for_pair(PCIE_SVT_PRIMARY_EP1, PCIE_SVT_PEER_PORT2);
      wait_for_pair(PCIE_SVT_PRIMARY_EP2, PCIE_SVT_PEER_PORT3);
      wait_for_pair(PCIE_SVT_PRIMARY_EP3, PCIE_SVT_PEER_PORT4);
    join
`else
    `uvm_fatal("LINK_TOPOLOGY",
      "link bring-up supports only EP_X16 or SWITCH_1X16_4X4")
`endif
  endtask
endclass
