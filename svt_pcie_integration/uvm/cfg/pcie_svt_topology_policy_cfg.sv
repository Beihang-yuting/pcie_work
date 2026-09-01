class pcie_svt_topology_policy_cfg extends uvm_object;
  // --------------------------------------------------------------------------
  // Topology-to-SVT selection.
  // --------------------------------------------------------------------------
  string dut_node_ids[$];
  string vif_prefix;
  string reset_vif_key;

  // --------------------------------------------------------------------------
  // Default transport and stage policy.
  // --------------------------------------------------------------------------
  pcie_svt_transport_e transport;
  pcie_svt_endpoint_model_e default_endpoint_model;
  bit default_fast_link_training;
  time cfg_timeout;
  time link_timeout;
  time enum_timeout;
  time traffic_timeout;

  // --------------------------------------------------------------------------
  // Endpoint image and explicit link overrides.
  // --------------------------------------------------------------------------
  pcie_svt_bar_cfg ep_bars[6];
  pcie_svt_link_override_cfg link_overrides[$];
  int unsigned hdl_slot_by_link[string];

  `uvm_object_utils(pcie_svt_topology_policy_cfg)

  function new(string name = "pcie_svt_topology_policy_cfg");
    super.new(name);
    foreach (ep_bars[i])
      ep_bars[i] = pcie_svt_bar_cfg::type_id::create(
        $sformatf("bar%0d", i));
  endfunction

  function void init_defaults();
    // Reset collection-valued overrides before applying deterministic defaults.
    dut_node_ids.delete();
    link_overrides.delete();
    hdl_slot_by_link.delete();
    transport = PCIE_SVT_TRANSPORT_SERIAL;
    default_endpoint_model = PCIE_SVT_EP_SINGLE;
    vif_prefix = "primary_vif_";
    reset_vif_key = "primary_reset_vif";
    default_fast_link_training = 1'b0;
    cfg_timeout = 1ms;
    link_timeout = 3ms;
    enum_timeout = 3ms;
    traffic_timeout = 1ms;

    // Start with no BARs implemented, then install the project profile below.
    foreach (ep_bars[i]) begin
      if (ep_bars[i] == null)
        ep_bars[i] = pcie_svt_bar_cfg::type_id::create(
          $sformatf("bar%0d", i));
      ep_bars[i].implemented = 1'b0;
      ep_bars[i].is_64bit = 1'b0;
      ep_bars[i].prefetchable = 1'b0;
      ep_bars[i].aperture = 0;
      ep_bars[i].initial_base = 0;
    end

    // BAR0/1 is 32 MiB; BAR2/3 and BAR4/5 are 64 KiB, all 64-bit prefetchable.
    ep_bars[0].implemented = 1'b1;
    ep_bars[0].is_64bit = 1'b1;
    ep_bars[0].prefetchable = 1'b1;
    ep_bars[0].aperture = 64'd33554432;
    ep_bars[2].implemented = 1'b1;
    ep_bars[2].is_64bit = 1'b1;
    ep_bars[2].prefetchable = 1'b1;
    ep_bars[2].aperture = 64'd65536;
    ep_bars[4].implemented = 1'b1;
    ep_bars[4].is_64bit = 1'b1;
    ep_bars[4].prefetchable = 1'b1;
    ep_bars[4].aperture = 64'd65536;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_svt_topology_policy_cfg source;
    super.do_copy(rhs);

    if (!$cast(source, rhs)) begin
      `uvm_fatal("SVT_COPY",
                 "pcie_svt_topology_policy_cfg source has the wrong type")
      return;
    end

    // Copy topology selection and stage defaults.
    dut_node_ids.delete();
    foreach (source.dut_node_ids[i])
      dut_node_ids.push_back(source.dut_node_ids[i]);
    vif_prefix = source.vif_prefix;
    reset_vif_key = source.reset_vif_key;
    transport = source.transport;
    default_endpoint_model = source.default_endpoint_model;
    default_fast_link_training = source.default_fast_link_training;
    cfg_timeout = source.cfg_timeout;
    link_timeout = source.link_timeout;
    enum_timeout = source.enum_timeout;
    traffic_timeout = source.traffic_timeout;

    // Deep-copy the endpoint BAR image.
    foreach (ep_bars[i]) begin
      if (source.ep_bars[i] == null) begin
        ep_bars[i] = null;
      end else begin
        if (ep_bars[i] == null)
          ep_bars[i] = pcie_svt_bar_cfg::type_id::create(
            $sformatf("bar%0d", i));
        ep_bars[i].copy(source.ep_bars[i]);
      end
    end

    // Deep-copy link overrides and preserve their order for diagnostics.
    link_overrides.delete();
    foreach (source.link_overrides[i]) begin
      pcie_svt_link_override_cfg override_copy;
      if (source.link_overrides[i] == null) begin
        override_copy = null;
      end else begin
        override_copy = pcie_svt_link_override_cfg::type_id::create(
          $sformatf("link_override%0d", i));
        override_copy.copy(source.link_overrides[i]);
      end
      link_overrides.push_back(override_copy);
    end

    // Slot ownership is a sparse map keyed by link ID.
    hdl_slot_by_link.delete();
    foreach (source.hdl_slot_by_link[link_id])
      hdl_slot_by_link[link_id] = source.hdl_slot_by_link[link_id];
  endfunction

  function void validate(output string errors[$]);
    bit dut_seen[string];
    bit override_seen[string];
    string slot_owner[int unsigned];
    int unsigned non_null_bar_count;

    errors.delete();

    // Validate DUT selection and reject duplicates before checking policy.

    if (dut_node_ids.size() == 0)
      errors.push_back("at least one DUT node is required");
    foreach (dut_node_ids[i]) begin
      if (dut_node_ids[i].len() == 0)
        errors.push_back($sformatf("DUT node ID at index %0d is empty", i));
      if (dut_seen.exists(dut_node_ids[i])) begin
        errors.push_back($sformatf("duplicate DUT node ID '%s'",
                                   dut_node_ids[i]));
      end else begin
        dut_seen[dut_node_ids[i]] = 1'b1;
      end
    end

    if (transport != PCIE_SVT_TRANSPORT_SERIAL)
      errors.push_back("PIPE transport is not implemented");
    if (!((default_endpoint_model == PCIE_SVT_EP_SINGLE) ||
          (default_endpoint_model == PCIE_SVT_EP_MULTI_BDF))) begin
      errors.push_back("default Endpoint model must be Single or Multiple-BDF");
    end

    if ($isunknown(cfg_timeout) || cfg_timeout == 0)
      errors.push_back("cfg_timeout must be positive");
    if ($isunknown(link_timeout) || link_timeout == 0)
      errors.push_back("link_timeout must be positive");
    if ($isunknown(enum_timeout) || enum_timeout == 0)
      errors.push_back("enum_timeout must be positive");
    if ($isunknown(traffic_timeout) || traffic_timeout == 0)
      errors.push_back("traffic_timeout must be positive");

    // Exactly six descriptors are kept so BAR indexing stays stable.
    non_null_bar_count = 0;
    foreach (ep_bars[i])
      if (ep_bars[i] != null)
        non_null_bar_count++;
    if (non_null_bar_count != 6)
      errors.push_back("exactly six non-null endpoint BAR handles are required");

    // Validate BAR aperture, alignment, and 64-bit pair ownership.
    foreach (ep_bars[i]) begin
      if ((ep_bars[i] != null) && ep_bars[i].implemented) begin
        if ((ep_bars[i].aperture < 16) ||
            ((ep_bars[i].aperture & (ep_bars[i].aperture - 1)) != 0)) begin
          errors.push_back($sformatf(
            "BAR%0d aperture must be a power of two and at least 16 bytes", i));
        end else if ((ep_bars[i].initial_base &
                     (ep_bars[i].aperture - 1)) != 0) begin
          errors.push_back($sformatf(
            "BAR%0d initial_base must be aligned to its aperture", i));
        end

        if (ep_bars[i].is_64bit) begin
          if (i == 5) begin
            errors.push_back("BAR5 cannot be the low DWORD of a 64-bit BAR");
          end else if ((ep_bars[i+1] == null) ||
                       ep_bars[i+1].implemented) begin
            errors.push_back($sformatf(
              "BAR%0d upper DWORD for BAR%0d must be unimplemented", i+1, i));
          end
        end
      end
    end

    foreach (link_overrides[i]) begin
      // Link overrides are sparse; null entries and duplicate IDs are errors.
      if (link_overrides[i] == null) begin
        errors.push_back($sformatf("link override at index %0d is null", i));
      end else begin
        if (link_overrides[i].link_id.len() == 0)
          errors.push_back($sformatf(
            "link override at index %0d has an empty link_id", i));
        if (override_seen.exists(link_overrides[i].link_id)) begin
          errors.push_back($sformatf("duplicate link override '%s'",
                                     link_overrides[i].link_id));
        end else begin
          override_seen[link_overrides[i].link_id] = 1'b1;
        end

        if (link_overrides[i].has_gen &&
            (link_overrides[i].max_gen != 4) &&
            (link_overrides[i].max_gen != 5)) begin
          errors.push_back($sformatf(
            "link override '%s' Gen must be 4 or 5",
            link_overrides[i].link_id));
        end
        if (link_overrides[i].has_width &&
            (link_overrides[i].link_width != 4) &&
            (link_overrides[i].link_width != 8) &&
            (link_overrides[i].link_width != 16)) begin
          errors.push_back($sformatf(
            "link override '%s' width must be 4, 8, or 16",
            link_overrides[i].link_id));
        end
        if (link_overrides[i].has_endpoint_model &&
            !((link_overrides[i].endpoint_model == PCIE_SVT_EP_SINGLE) ||
              (link_overrides[i].endpoint_model ==
                 PCIE_SVT_EP_MULTI_BDF))) begin
          errors.push_back($sformatf(
            "link override '%s' Endpoint model must be Single or Multiple-BDF",
            link_overrides[i].link_id));
        end
        if (link_overrides[i].has_link_timeout &&
            ($isunknown(link_overrides[i].link_timeout) ||
             link_overrides[i].link_timeout == 0)) begin
          errors.push_back($sformatf(
            "link override '%s' link_timeout must be positive",
            link_overrides[i].link_id));
        end
      end
    end

    foreach (hdl_slot_by_link[link_id]) begin
      if (link_id.len() == 0)
        errors.push_back("HDL-slot-map keys must be non-empty");
      if (slot_owner.exists(hdl_slot_by_link[link_id])) begin
        errors.push_back($sformatf(
          "HDL slot %0d is assigned to both '%s' and '%s'",
          hdl_slot_by_link[link_id],
          slot_owner[hdl_slot_by_link[link_id]], link_id));
      end else begin
        slot_owner[hdl_slot_by_link[link_id]] = link_id;
      end
    end
  endfunction
endclass
