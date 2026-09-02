//------------------------------------------------------------------------------
// Projection from the frozen dpu-common view into backend-neutral PCIe policy.
//
// dpu-common owns function identity and resolved resource placement.  This
// adapter is the only translation point: it copies those values, validates the
// physical attachment, and never invokes a PCIe allocator.
//------------------------------------------------------------------------------

class pcie_dpu_cfg_adapter extends uvm_object;
  `uvm_object_utils(pcie_dpu_cfg_adapter)

  function new(string name = "pcie_dpu_cfg_adapter");
    super.new(name);
  endfunction

  protected function int find_device(
      pcie_global_cfg cfg,
      string physical_node_id);
    foreach (cfg.devices[index]) begin
      if ((cfg.devices[index] != null) &&
          (cfg.devices[index].device_id == physical_node_id))
        return index;
    end
    return -1;
  endfunction

  protected function bit link_contains_node(
      pcie_topology_link_cfg link,
      string node_id);
    if (link == null)
      return 1'b0;
    return (link.upstream_node_id == node_id) ||
           (link.downstream_node_id == node_id);
  endfunction

  protected function bit map_bar(
      pcie_device_cfg device,
      dpu_bar_pair_lease_t lease,
      dpu_bar_role_e role,
      output string why);
    int expected_even_bar;
    int low;
    pcie_unified_bar_cfg low_cfg;
    pcie_unified_bar_cfg high_cfg;

    why = "";
    case (role)
      DPU_BAR_DEVICE_MEMORY: expected_even_bar = 0;
      DPU_BAR_MAILBOX:       expected_even_bar = 2;
      DPU_BAR_MSIX:          expected_even_bar = 4;
      default: begin
        why = $sformatf("unsupported DPU BAR role %0d", role);
        return 1'b0;
      end
    endcase

    if (lease.even_bar_id != expected_even_bar) begin
      why = $sformatf(
        "DPU BAR role %0d resolved to BAR%0d; expected BAR%0d",
        role, lease.even_bar_id, expected_even_bar);
      return 1'b0;
    end
    if ((lease.size < 16) ||
        ((lease.size & (lease.size - 1)) != 0)) begin
      why = $sformatf("DPU BAR%0d size %0h is not a power of two",
                      lease.even_bar_id, lease.size);
      return 1'b0;
    end
    if ((lease.base % lease.size) != 0) begin
      why = $sformatf("DPU BAR%0d base %0h is not size aligned",
                      lease.even_bar_id, lease.base);
      return 1'b0;
    end

    low = expected_even_bar;
    low_cfg = device.bars[low];
    high_cfg = device.bars[low + 1];
    if ((low_cfg == null) || (high_cfg == null)) begin
      why = $sformatf("device '%s' has no descriptor for BAR%0d pair",
                      device.device_id, low);
      return 1'b0;
    end

    // A dpu-common pair is represented as one 64-bit, prefetchable BAR.  The
    // high DWORD remains a placeholder and is deliberately not implemented.
    low_cfg.implemented  = 1'b1;
    low_cfg.is_64bit     = 1'b1;
    low_cfg.prefetchable = 1'b1;
    low_cfg.aperture     = lease.size;
    low_cfg.initial_base = lease.base;
    high_cfg.implemented = 1'b0;
    high_cfg.is_64bit = 1'b0;
    high_cfg.prefetchable = 1'b0;
    high_cfg.aperture = 0;
    high_cfg.initial_base = 0;
    return 1'b1;
  endfunction

  function bit project(
      dpu_device_snapshot device_snapshot,
      dpu_resource_snapshot resource_snapshot,
      pcie_topology_cfg topology,
      pcie_dpu_attachment_cfg attachments,
      output pcie_global_cfg global_cfg,
      output string errors[$]);
    dpu_function_key_t functions[$];
    pcie_global_cfg candidate;
    string why;
    bit seen_link[string];
    string link_node[string];

    global_cfg = null;
    errors.delete();

    // A snapshot is published only after dpu-common has frozen all indexes;
    // accepting an authoring object here would allow a backend to observe
    // partially allocated BDFs or BARs.
    if ((device_snapshot == null) || !device_snapshot.is_frozen())
      errors.push_back("device snapshot must be non-null and frozen");
    if ((resource_snapshot != null) && !resource_snapshot.is_frozen())
      errors.push_back("resource snapshot is present but not frozen");
    if ((resource_snapshot != null) &&
        resource_snapshot.is_frozen() &&
        !resource_snapshot.references_device_snapshot(device_snapshot))
      errors.push_back(
        "resource snapshot does not reference the supplied device snapshot");
    if (topology == null)
      errors.push_back("PCIe topology is null");
    if (attachments == null)
      errors.push_back("DPU physical attachment map is null");

    if (errors.size() != 0)
      return 1'b0;

    // Validate the physical graph and attachment ownership before allocating
    // any output records.  This guarantees failure is pre-backend creation.
    topology.validate(errors);
    attachments.validate(errors);
    if (errors.size() != 0)
      return 1'b0;

    // Every attachment must name a real graph link and one of its endpoints.
    foreach (attachments.attachments[index]) begin
      pcie_dpu_function_attachment attachment;
      pcie_topology_link_cfg link;

      attachment = attachments.attachments[index];
      if (attachment == null)
        continue;
      link = null;
      foreach (topology.links[link_index]) begin
        if ((topology.links[link_index] != null) &&
            (topology.links[link_index].link_id == attachment.link_id))
          link = topology.links[link_index];
      end
      if (link == null) begin
        errors.push_back($sformatf(
          "DPU function %s references unknown PCIe link '%s'",
          dpu_function_key_name(attachment.function_key),
          attachment.link_id));
        continue;
      end
      if (!link_contains_node(link, attachment.physical_node_id))
        errors.push_back($sformatf(
          "physical node '%s' is not an endpoint of link '%s'",
          attachment.physical_node_id, attachment.link_id));
      if (seen_link.exists(attachment.link_id) &&
          (link_node[attachment.link_id] != attachment.physical_node_id))
        errors.push_back($sformatf(
          "link '%s' is attached to both '%s' and '%s'",
          attachment.link_id, link_node[attachment.link_id],
          attachment.physical_node_id));
      else begin
        seen_link[attachment.link_id] = 1'b1;
        link_node[attachment.link_id] = attachment.physical_node_id;
      end
    end
    if (errors.size() != 0)
      return 1'b0;

    candidate = pcie_global_cfg::type_id::create("dpu_projected_global_cfg");
    candidate.build_default_for_topology(topology);
    device_snapshot.list_functions(functions);

    foreach (functions[index]) begin
      dpu_pcie_function_id_t pcie_id;
      string physical_node_id;
      string link_id;
      bit has_function_number;
      int unsigned function_number;
      int device_index;
      pcie_device_cfg device;
      dpu_bar_pair_lease_t lease;

      if (!device_snapshot.get_pcie_id(functions[index], pcie_id, why)) begin
        errors.push_back({"cannot read DPU PCIe ID: ", why});
        continue;
      end
      if (!attachments.find_by_function(
              functions[index], physical_node_id, link_id,
              has_function_number, function_number)) begin
        errors.push_back({"missing physical attachment for DPU function ",
                          dpu_function_key_name(functions[index])});
        continue;
      end

      device_index = find_device(candidate, physical_node_id);
      if (device_index < 0) begin
        errors.push_back($sformatf(
          "physical attachment '%s' has no matching topology node",
          physical_node_id));
        continue;
      end

      // One physical EP may expose multiple PF/VF functions.  The first
      // function reuses the topology device record; later functions receive
      // independent configuration-space images on the same physical node.
      if (candidate.devices[device_index].function_key_name != "") begin
        device = pcie_device_cfg::type_id::create($sformatf(
          "dpu_%s", dpu_function_key_name(functions[index])));
        device.init_default_bars();
        candidate.devices.push_back(device);
        device_index = candidate.devices.size() - 1;
      end
      device = candidate.devices[device_index];
      device.device_id = physical_node_id;
      device.role = PCIE_DEVICE_EP;
      device.header_type = 8'h00;
      device.bdf = pcie_id.bdf;
      device.domain_host_id = pcie_id.domain.host_id;
      device.domain_segment_id = pcie_id.domain.segment_id;
      device.physical_node_id = physical_node_id;
      device.link_id = link_id;
      device.function_key_name = dpu_function_key_name(functions[index]);
      device.cfg_space_enable = 1'b1;
      device.bus_master_enable = 1'b0;
      device.init_default_bars();

      foreach (device.bars[bar_index]) begin
        device.bars[bar_index].implemented = 1'b0;
        device.bars[bar_index].is_64bit = 1'b0;
        device.bars[bar_index].prefetchable = 1'b0;
        device.bars[bar_index].aperture = 0;
        device.bars[bar_index].initial_base = 0;
      end

      // Explicit role lookups keep the role-to-BAR mapping stable even if the
      // snapshot's internal BAR order changes in a future dpu-common release.
      if (!device_snapshot.get_bar(functions[index], DPU_BAR_DEVICE_MEMORY,
                                    lease, why) ||
          !map_bar(device, lease, DPU_BAR_DEVICE_MEMORY, why))
        errors.push_back({"invalid DPU device-memory BAR: ", why});
      if (!device_snapshot.get_bar(functions[index], DPU_BAR_MAILBOX,
                                    lease, why) ||
          !map_bar(device, lease, DPU_BAR_MAILBOX, why))
        errors.push_back({"invalid DPU mailbox BAR: ", why});
      if (!device_snapshot.get_bar(functions[index], DPU_BAR_MSIX,
                                    lease, why) ||
          !map_bar(device, lease, DPU_BAR_MSIX, why))
        errors.push_back({"invalid DPU MSI-X BAR: ", why});
    end

    if (errors.size() != 0)
      return 1'b0;

    // Run the backend-neutral policy validation only after all DPU overrides
    // are installed.  The caller receives no partially valid output.
    candidate.validate(errors);
    if (errors.size() != 0)
      return 1'b0;
    global_cfg = candidate;
    return 1'b1;
  endfunction
endclass
