class pcie_svt_enumeration_vseq extends
    uvm_sequence #(uvm_sequence_item);
  pcie_svt_enumeration_registry registry;
  pcie_svt_endpoint_model_e peer_endpoint_model_by_link[string];

  `uvm_object_utils(pcie_svt_enumeration_vseq)
  `uvm_declare_p_sequencer(pcie_svt_topology_virtual_sequencer)

  function new(string name = "pcie_svt_enumeration_vseq");
    super.new(name);
  endfunction

  function bit peer_model_allows_official_enum(
    string link_id,
      output string diagnostic);
    diagnostic = "";
    if (!peer_endpoint_model_by_link.exists(link_id)) begin
      diagnostic = $sformatf(
        "%s peer Endpoint model mapping is missing", link_id);
      return 1'b0;
    end
    if (peer_endpoint_model_by_link[link_id] != PCIE_SVT_EP_SINGLE) begin
      diagnostic = $sformatf(
        {"%s peer model is Multiple-BDF; R-2020.12 full Endpoint ",
         "enumeration requires Single Endpoint"}, link_id);
      return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function bit [63:0] expected_aperture(
      int unsigned pair);
    case (pair)
      0: return 64'd33554432;
      1, 2: return 64'd65536;
      default: return '0;
    endcase
  endfunction

  protected function void collect_direct_links(output string link_ids[$]);
    link_ids.delete();
    foreach (p_sequencer.descriptor_by_link[link_id]) begin
      pcie_svt_port_descriptor descriptor;
      descriptor = p_sequencer.descriptor_by_link[link_id];
      if ((descriptor == null) ||
          (descriptor.role != PCIE_SVT_ROLE_RC)) begin
        `uvm_fatal("SVT_ENUM_TOPOLOGY", $sformatf(
          "direct Endpoint enumeration requires only RC descriptors; link=%s role=%s",
          link_id, (descriptor == null) ? "<null>" :
            descriptor.role.name()))
        return;
      end
      link_ids.push_back(link_id);
    end
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

  protected task read_config(
      string link_id,
      svt_pcie_device_virtual_ep_enumeration_sequence enum_seq,
      bit [11:0] byte_offset,
      output bit [31:0] data);
    svt_pcie_driver_app_transaction::completion_status_enum cpl_status;

    enum_seq.send_cfg_rd(8'h00, byte_offset, data, 16'h0000,
                         4'hf, cpl_status);
    if (cpl_status != svt_pcie_driver_app_transaction::SUCCESSFUL)
      `uvm_fatal("SVT_ENUM_CFG_READ", $sformatf(
        "%s Configuration Read offset=0x%03x completion_status=%0d",
        link_id, byte_offset, cpl_status))
  endtask

  protected task validate_bar_readback(
      string link_id,
      svt_pcie_device_virtual_ep_enumeration_sequence enum_seq,
      svt_pcie_ep_enumeration_seq_status status);
    for (int unsigned pair = 0; pair < 3; pair++) begin
      int unsigned low_bar;
      bit [31:0] low_dword;
      bit [31:0] high_dword;
      bit [63:0] observed_base;
      bit [63:0] observed_aperture;

      low_bar = pair * 2;
      if (status.non_virtual_bar_present[0][low_bar] != 2'b10)
        `uvm_fatal("SVT_ENUM_BAR_TYPE", $sformatf(
          "%s PF0 BAR%0d/%0d is not a 64-bit Memory BAR; type=%02b",
          link_id, low_bar, low_bar + 1,
          status.non_virtual_bar_present[0][low_bar]))
      if (status.max_per_bar_address_range[0][low_bar] <
          status.min_per_bar_address_range[0][low_bar])
        `uvm_fatal("SVT_ENUM_BAR_SIZE", $sformatf(
          "%s PF0 BAR%0d/%0d has reversed official range",
          link_id, low_bar, low_bar + 1))
      observed_aperture =
        status.max_per_bar_address_range[0][low_bar] -
        status.min_per_bar_address_range[0][low_bar] + 1;
      if (observed_aperture != expected_aperture(pair))
        `uvm_fatal("SVT_ENUM_BAR_SIZE", $sformatf(
          "%s PF0 BAR%0d/%0d aperture expected=0x%0h actual=0x%0h",
          link_id, low_bar, low_bar + 1, expected_aperture(pair),
          observed_aperture))

      read_config(link_id, enum_seq,
                  12'h010 + (low_bar * 4), low_dword);
      read_config(link_id, enum_seq,
                  12'h010 + ((low_bar + 1) * 4), high_dword);
      if ((low_dword[0] !== 1'b0) ||
          (low_dword[2:1] !== 2'b10))
        `uvm_fatal("SVT_ENUM_BAR_TYPE", $sformatf(
          "%s PF0 BAR%0d/%0d readback is not 64-bit Memory; low=0x%08x",
          link_id, low_bar, low_bar + 1, low_dword))
      if (low_dword[3] !== 1'b1)
        `uvm_fatal("SVT_ENUM_BAR_PREFETCH", $sformatf(
          "%s PF0 BAR%0d/%0d is not Prefetchable; low=0x%08x",
          link_id, low_bar, low_bar + 1, low_dword))
      observed_base = {high_dword, low_dword[31:4], 4'h0};
      if (observed_base !=
          status.min_per_bar_address_range[0][low_bar])
        `uvm_fatal("SVT_ENUM_BAR_READBACK", $sformatf(
          "%s PF0 BAR%0d/%0d base readback=0x%016h status=0x%016h",
          link_id, low_bar, low_bar + 1, observed_base,
          status.min_per_bar_address_range[0][low_bar]))
    end
  endtask

  protected task validate_command_readback(
      string link_id,
      svt_pcie_device_virtual_ep_enumeration_sequence enum_seq);
    bit [31:0] command_status;

    read_config(link_id, enum_seq, 12'h004, command_status);
    if (command_status[2:1] !== 2'b11)
      `uvm_fatal("SVT_ENUM_COMMAND", $sformatf(
        "%s PF0 failed to retain Memory Space and Bus Master enables; command=0x%04x",
        link_id, command_status[15:0]))
  endtask

  protected task enumerate_link(string link_id);
    pcie_svt_port_descriptor descriptor;
    svt_pcie_device_status status;
    svt_pcie_device_virtual_sequencer rc_seqr;
    svt_pcie_device_virtual_ep_enumeration_sequence enum_seq;
    bit enumeration_done;
    realtime start_time;
    realtime deadline;
    realtime completion_time;
    string model_diagnostic;

    descriptor = p_sequencer.get_port_descriptor(link_id);
    status = p_sequencer.status_by_link[link_id];
    rc_seqr = p_sequencer.require_port_seqr(
      link_id, "direct Endpoint enumeration");
    p_sequencer.enum_state[link_id] = PCIE_SVT_STAGE_FAIL;
    if ((descriptor == null) || (status == null) ||
        (status.pcie_status == null) ||
        (status.pcie_status.pl_status == null) ||
        (status.pcie_status.dl_status == null) ||
        (status.pcie_status.tl_status == null) ||
        (rc_seqr == null))
      `uvm_fatal("SVT_ENUM_HANDLE", $sformatf(
        "%s has incomplete descriptor/status/sequencer handles", link_id))
    if ((p_sequencer.cfg_state[link_id] != PCIE_SVT_STAGE_PASS) ||
        (p_sequencer.link_state[link_id] != PCIE_SVT_STAGE_PASS))
      `uvm_fatal("SVT_ENUM_ORDER", $sformatf(
        "%s requires CFG and LINK stages PASS", link_id))
    if (!peer_model_allows_official_enum(link_id, model_diagnostic))
      `uvm_fatal("SVT_ENUM_ENDPOINT_MODEL", model_diagnostic)

    enumeration_done = 1'b0;
    start_time = $realtime;
    deadline = start_time + descriptor.enum_timeout;
    completion_time = 0;
    fork
      begin
        // Keep the changing fields explicit for VCS wait sensitivity.
        wait ((status.pcie_status.pl_status.link_up === 1'b1) &&
              (status.pcie_status.pl_status.ltssm_state ==
                svt_pcie_types::L0) &&
              (status.pcie_status.dl_status.dl_link_up === 1'b1) &&
              (status.pcie_status.tl_status.vc_initialized[0] === 1'b1));
        enum_seq =
          svt_pcie_device_virtual_ep_enumeration_sequence::type_id::create(
            {link_id, "_enum"});
        if (enum_seq == null)
          `uvm_fatal("SVT_ENUM_HANDLE", $sformatf(
            "%s official Endpoint enumeration sequence creation failed",
            link_id))
        enum_seq.set_sequencer(rc_seqr);
        if (!enum_seq.randomize() with {
              device_parms.root_hierarchy == descriptor.root_hierarchy;
              device_parms.bus_number == 8'h01;
              device_parms.device_number == 5'h00;
              device_parms.max_num_functions_supported == 1;
              device_parms.enable_sriov == 1'b0;
              device_parms.enable_vf_memory_space == 1'b0;
              device_parms.get_atomic_op_cap == 1'b0;
              device_parms.enable_atomic_op_as_requester_support == 1'b0;
              device_parms.find_all_base_capabilities == 1'b0;
              device_parms.find_all_extended_capabilities == 1'b0;
              device_parms.enable_incremental_bar_allocation == 1'b1;
              device_parms.is_ep_device_vip == 1'b0;
              device_parms.min_pref_mem_base_addr ==
                (64'h0000_0001_0000_0000 +
                 (64'h0000_0000_1000_0000 *
                  descriptor.root_hierarchy));
              device_parms.max_pref_mem_base_addr ==
                (64'h0000_0001_0fff_ffff +
                 (64'h0000_0000_1000_0000 *
                  descriptor.root_hierarchy));
            })
          `uvm_fatal("SVT_ENUM_RANDOMIZE", $sformatf(
            "%s official Endpoint enumeration randomization failed",
            link_id))
        if (enum_seq.ep_enumeration_status == null)
          `uvm_fatal("SVT_ENUM_STATUS", $sformatf(
            "%s official sequence created null Endpoint status", link_id))
        // R-2020.12 configure_bars() consults the status copy rather than
        // device_parms.is_ep_device_vip and does not propagate it itself.
        enum_seq.ep_enumeration_status.is_ep_device_vip = 1'b0;
        if (enum_seq.device_parms.is_ep_device_vip ||
            enum_seq.ep_enumeration_status.is_ep_device_vip)
          `uvm_fatal("SVT_ENUM_BAR_MODE", $sformatf(
            "%s official sequence did not select DUT BAR probing", link_id))
        enum_seq.start(rc_seqr);
        if (enum_seq.ep_enumeration_status == null)
          `uvm_fatal("SVT_ENUM_STATUS", $sformatf(
            "%s official sequence returned null Endpoint status", link_id))
        validate_bar_readback(
          link_id, enum_seq, enum_seq.ep_enumeration_status);
        validate_command_readback(link_id, enum_seq);
        registry.record_direct_endpoint(
          link_id, descriptor.root_hierarchy,
          {enum_seq.ep_enumeration_status.captured_bus_number,
           enum_seq.ep_enumeration_status.captured_device_number, 3'h0},
          enum_seq.ep_enumeration_status);
        completion_time = $realtime;
        enumeration_done = 1'b1;
      end
      begin
        if ($realtime < deadline)
          #(deadline - $realtime);
        if (!enumeration_done)
          #1step;
      end
    join_any
    disable fork;

    if (!enumeration_done || (completion_time > deadline))
      `uvm_fatal("SVT_ENUM_TIMEOUT", $sformatf(
        {"%s enumeration timeout=%0t start=%0.6f deadline=%0.6f ",
         "completion=%0.6f current=%0.6f pl=%0b ltssm=%s dl=%0b vc0=%0b"},
        link_id, descriptor.enum_timeout, start_time, deadline,
        completion_time, $realtime,
        status.pcie_status.pl_status.link_up,
        status.pcie_status.pl_status.ltssm_state.name(),
        status.pcie_status.dl_status.dl_link_up,
        status.pcie_status.tl_status.vc_initialized[0]))
  endtask

  virtual task body();
    string direct_links[$];
    string errors[$];

    if (p_sequencer == null)
      `uvm_fatal("SVT_ENUM_HANDLE",
        "direct enumeration requires a topology virtual sequencer")
    if (registry == null)
      `uvm_fatal("SVT_ENUM_HANDLE",
        "direct enumeration requires a non-null registry")
    collect_direct_links(direct_links);
    if (direct_links.size() == 0)
      `uvm_fatal("SVT_ENUM_TOPOLOGY",
        "direct Endpoint enumeration found no RC links")

    foreach (direct_links[i]) begin
      fork
        automatic string link_id = direct_links[i];
        enumerate_link(link_id);
      join_none
    end
    wait fork;

    registry.finalize(errors);
    if (errors.size() != 0) begin
      foreach (direct_links[i])
        p_sequencer.enum_state[direct_links[i]] = PCIE_SVT_STAGE_FAIL;
      `uvm_fatal("SVT_ENUM_REGISTRY", pcie_svt_join_errors(errors))
    end
    foreach (direct_links[i]) begin
      pcie_svt_endpoint_record endpoint;
      endpoint = registry.find_endpoint(direct_links[i]);
      if (endpoint == null)
        `uvm_fatal("SVT_ENUM_REGISTRY", $sformatf(
          "%s missing from finalized registry: %s",
          direct_links[i], registry.last_error))
      p_sequencer.enum_state[direct_links[i]] = PCIE_SVT_STAGE_PASS;
      `uvm_info("PCIE_SVT_ENUM_PASS", $sformatf(
        "link=%s root_hierarchy=%0d bdf=%04x bars=3",
        direct_links[i], endpoint.root_hierarchy, endpoint.bdf), UVM_NONE)
    end
  endtask
endclass
