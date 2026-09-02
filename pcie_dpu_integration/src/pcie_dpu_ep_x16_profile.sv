//------------------------------------------------------------------------------
// Single PF0 Endpoint x16 example profile.
//
// The DPU authoring values below are independent of transport.  Only the
// backend/link-policy block consumes +PCIE_BACKEND, proving that TL and SVT
// receive the same resolved BDF and BAR placement.
//------------------------------------------------------------------------------

class pcie_dpu_ep_x16_profile;
  static function dpu_function_key_t pf0_key();
    return '{host_id: 0, pf_id: 0, kind: DPU_FUNCTION_PF, vf_id: 0};
  endfunction

  static function dpu_bar_request make_bar(
      dpu_bar_role_e role,
      int unsigned even_bar_id,
      bit [63:0] size,
      bit [63:0] base);
    dpu_bar_request bar;

    bar = dpu_bar_request::type_id::create(
      $sformatf("ep_x16_bar%0d", even_bar_id));
    bar.role = role;
    bar.even_bar_id = even_bar_id;
    bar.size = size;
    bar.alignment = size;
    bar.placement = DPU_ALLOC_PINNED;
    bar.pinned_base = base;
    return bar;
  endfunction

  static function dpu_device_cfg make_device_cfg();
    dpu_device_cfg cfg;
    dpu_host_cfg host;
    dpu_pcie_domain_cfg domain;
    dpu_mmio_window_cfg window;
    dpu_bdf_range_t bdf_range;
    dpu_function_cfg function_cfg;

    cfg = dpu_device_cfg::type_id::create("ep_x16_device_cfg");
    host = dpu_host_cfg::type_id::create("ep_x16_host0");
    host.host_id = 0;

    // BDF 01:00.0 matches the direct Endpoint enumeration default.  The
    // domain and BAR window remain dpu-common inputs, not SVT sequence knobs.
    domain = dpu_pcie_domain_cfg::type_id::create("ep_x16_domain0");
    domain.key.host_id = 0;
    domain.key.segment_id = 0;
    bdf_range.first_bdf = 16'h0100;
    bdf_range.last_bdf = 16'h0107;
    domain.bdf_ranges.push_back(bdf_range);

    window = dpu_mmio_window_cfg::type_id::create("ep_x16_mmio_window");
    window.base = 64'h0000_0001_0000_0000;
    window.limit = 64'h0000_0001_1000_0000;
    window.allowed_roles = '{DPU_BAR_DEVICE_MEMORY,
                             DPU_BAR_MAILBOX,
                             DPU_BAR_MSIX};
    domain.mmio_windows.push_back(window);
    host.pcie_domains.push_back(domain);
    cfg.hosts.push_back(host);

    function_cfg = dpu_function_cfg::type_id::create("ep_x16_pf0");
    function_cfg.key = pf0_key();
    function_cfg.domain_key = domain.key;
    function_cfg.bdf_mode = DPU_ALLOC_PINNED;
    function_cfg.pinned_bdf = 16'h0100;
    function_cfg.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);

    // Three prefetchable 64-bit pairs use the project profile exactly:
    // BAR0/1=32 MiB, BAR2/3=64 KiB, BAR4/5=64 KiB.
    function_cfg.bars.push_back(make_bar(
      DPU_BAR_DEVICE_MEMORY, 0, 64'h0200_0000,
      64'h0000_0001_0000_0000));
    function_cfg.bars.push_back(make_bar(
      DPU_BAR_MAILBOX, 2, 64'h0001_0000,
      64'h0000_0001_0200_0000));
    function_cfg.bars.push_back(make_bar(
      DPU_BAR_MSIX, 4, 64'h0001_0000,
      64'h0000_0001_0201_0000));
    cfg.functions.push_back(function_cfg);
    cfg.af_request.mode = DPU_AF_SELECTED;
    cfg.af_request.requester = function_cfg.key;
    return cfg;
  endfunction

  static function dpu_resource_placement_cfg make_placement_cfg();
    dpu_resource_placement_cfg placement;
    dpu_resource_pool_config_t profile;
    dpu_vio_placement_request request;
    dpu_vio_qpair_override qpair_override;

    placement = dpu_resource_placement_cfg::type_id::create(
      "ep_x16_placement_cfg");
    profile.name = "virtio.qpair";
    profile.class_id = 0;
    profile.kind = DPU_RESOURCE_KIND_QUEUE;
    profile.capacity = 32;
    profile.max_per_function = 32;
    placement.profiles.push_back(profile);

    // One deterministic queue pair keeps the example small while exercising
    // bootstrap and VIO plan creation through the same resolved snapshot.
    request = dpu_vio_placement_request::type_id::create(
      "ep_x16_vio_request");
    request.request_id = 0;
    request.total_qpairs = 1;
    request.candidate_kind = DPU_VIO_CANDIDATE_PF_ONLY;
    request.device_policy = DPU_VIO_DEVICE_FIXED;
    request.fixed_devices.push_back(pf0_key());

    qpair_override = dpu_vio_qpair_override::type_id::create(
      "ep_x16_qpair0");
    qpair_override.request_pair_index = 0;
    qpair_override.owner_mode = DPU_ASSIGN_PINNED;
    qpair_override.requested_owner = pf0_key();
    qpair_override.local_mode = DPU_ASSIGN_PINNED;
    qpair_override.requested_local_pair_id = 0;
    qpair_override.global_mode = DPU_ASSIGN_PINNED;
    qpair_override.requested_global_qpair_id = 0;
    request.qpair_overrides.push_back(qpair_override);
    placement.vio_requests.push_back(request);
    return placement;
  endfunction

  static function bit populate(
      pcie_dpu_system_cfg system_cfg,
      output string why);
    string backend_name;
    int unsigned max_gen;

    why = "";
    if (system_cfg == null) begin
      why = "system_cfg is null";
      return 1'b0;
    end

    backend_name = "TL_ONLY";
    void'($value$plusargs("PCIE_BACKEND=%s", backend_name));
    max_gen = 4;
    void'($value$plusargs("PCIE_GEN=%d", max_gen));
    if (!((max_gen == 4) || (max_gen == 5))) begin
      why = $sformatf("PCIE_GEN must be 4 or 5, got %0d", max_gen);
      return 1'b0;
    end

    system_cfg.device_cfg = make_device_cfg();
    system_cfg.placement_cfg = make_placement_cfg();
    system_cfg.attachments = pcie_dpu_attachment_cfg::type_id::create(
      "ep_x16_attachments");
    if (!system_cfg.attachments.add(
          pf0_key(), "EP0", "RC0_EP0", 1'b1, 0, why))
      return 1'b0;

    system_cfg.pcie_policy = pcie_global_cfg::type_id::create(
      "ep_x16_pcie_policy");
    system_cfg.pcie_policy.build_default_for_topology(
      pcie_topology_builder::build_ep_x16(max_gen));
    system_cfg.root_link_id = "RC0_EP0";

    if ((backend_name == "TL") || (backend_name == "TL_ONLY")) begin
      system_cfg.pcie_policy.backend = PCIE_BACKEND_TL_ONLY;
    end else if ((backend_name == "SVT") ||
                 (backend_name == "SVT_REAL_DUT")) begin
      system_cfg.pcie_policy.backend = PCIE_BACKEND_SVT_REAL_DUT;
      system_cfg.pcie_policy.links[0].use_svt = 1'b1;
      system_cfg.pcie_policy.links[0].has_hdl_slot = 1'b1;
      system_cfg.pcie_policy.links[0].hdl_slot = 0;
      system_cfg.pcie_policy.links[0].vif_key = "primary_vif_0";
    end else begin
      why = {"unsupported PCIE_BACKEND='", backend_name,
             "'; use TL_ONLY or SVT_REAL_DUT"};
      return 1'b0;
    end

    // The repository's generic TL Endpoint has configuration/memory protocol
    // behavior but does not implement DPU AF register semantics.  Controlled
    // smoke mode therefore injects the official dpu-common spy executor to
    // validate complete plan generation and ordering.  Omitting this plusarg
    // keeps the real TL/SVT transport executor for a DUT register model.
    if ($test$plusargs("PCIE_DPU_CONTROLLED_EXECUTOR"))
      system_cfg.executor = dpu_spy_reg_executor::type_id::create(
        "ep_x16_controlled_executor");
    return 1'b1;
  endfunction
endclass : pcie_dpu_ep_x16_profile
