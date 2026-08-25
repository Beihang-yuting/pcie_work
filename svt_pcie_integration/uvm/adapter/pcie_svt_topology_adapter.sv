class pcie_svt_topology_adapter extends uvm_object;
  `uvm_object_utils(pcie_svt_topology_adapter)

  function new(string name = "pcie_svt_topology_adapter");
    super.new(name);
  endfunction

  function void translate(
      pcie_topology_cfg topology,
      pcie_svt_topology_policy_cfg policy,
      output pcie_svt_port_descriptor ports[$],
      output string errors[$]);
    string policy_errors[$];
    pcie_topology_link_cfg physical_links[$];
    bit topology_link_ids[string];
    bit descriptor_link_ids[string];
    string slot_owner[int unsigned];

    ports.delete();
    errors.delete();
    if ((topology == null) || (policy == null)) begin
      errors.push_back("topology and policy must both be non-null");
      return;
    end

    topology.validate(errors);
    policy.validate(policy_errors);
    foreach (policy_errors[i])
      errors.push_back(policy_errors[i]);

    foreach (topology.links[i]) begin
      if (topology.links[i] != null)
        topology_link_ids[topology.links[i].link_id] = 1'b1;
    end
    foreach (policy.dut_node_ids[i]) begin
      if (topology.find_node(policy.dut_node_ids[i]) == null)
        errors.push_back($sformatf("DUT node '%s' is absent",
                                  policy.dut_node_ids[i]));
    end
    foreach (policy.link_overrides[i]) begin
      if ((policy.link_overrides[i] != null) &&
          !topology_link_ids.exists(policy.link_overrides[i].link_id)) begin
        errors.push_back($sformatf(
          "override references unknown link '%s'",
          policy.link_overrides[i].link_id));
      end
    end
    foreach (policy.hdl_slot_by_link[link_id]) begin
      if (!topology_link_ids.exists(link_id)) begin
        errors.push_back($sformatf(
          "HDL-slot-map entry references unknown topology link '%s'",
          link_id));
      end
    end
    if (errors.size() != 0)
      return;

    foreach (topology.links[i])
      physical_links.push_back(topology.links[i]);
    sort_pending_links_by_link_id(physical_links);

    foreach (physical_links[physical_slot]) begin
      pcie_topology_link_cfg link;
      pcie_svt_link_override_cfg override_cfg;
      pcie_topology_node_cfg upstream_node;
      pcie_topology_node_cfg downstream_node;
      pcie_topology_node_cfg svt_node;
      pcie_svt_port_descriptor descriptor;
      bit effective_enabled;
      bit upstream_is_dut;
      bit downstream_is_dut;
      int unsigned active_width;
      int unsigned active_gen;

      link = physical_links[physical_slot];
      if (link == null) begin
        errors.push_back($sformatf("physical link at slot %0d is null",
                                  physical_slot));
        continue;
      end

      override_cfg = null;
      void'(find_override(policy, link.link_id, override_cfg));
      effective_enabled = link.enabled;
      if ((override_cfg != null) && override_cfg.has_enable)
        effective_enabled = override_cfg.enabled;
      if (!effective_enabled) begin
        if ((override_cfg != null) &&
            (override_cfg.has_gen || override_cfg.has_width ||
             override_cfg.has_fast_link_training ||
             override_cfg.has_link_timeout)) begin
          errors.push_back($sformatf(
            "link '%s': disabled link also carries an active override",
            link.link_id));
        end
        continue;
      end

      active_width = effective_width(link, override_cfg);
      active_gen = effective_gen(link, override_cfg);
      if (!((active_width == 4) || (active_width == 8) ||
            (active_width == 16))) begin
        errors.push_back($sformatf(
          "link '%s': active width x%0d must be x4, x8, or x16",
          link.link_id, active_width));
        continue;
      end
      if (active_width > link.link_width) begin
        errors.push_back($sformatf(
          "link '%s': active width x%0d exceeds physical width x%0d",
          link.link_id, active_width, link.link_width));
        continue;
      end
      if (!((active_gen == 4) || (active_gen == 5))) begin
        errors.push_back($sformatf(
          "link '%s': active Gen %0d must be 4 or 5",
          link.link_id, active_gen));
        continue;
      end

      upstream_node = topology.find_node(link.upstream_node_id);
      downstream_node = topology.find_node(link.downstream_node_id);
      if ((upstream_node == null) || (downstream_node == null)) begin
        errors.push_back($sformatf(
          "link '%s': both link endpoints must resolve to topology nodes",
          link.link_id));
        continue;
      end

      upstream_is_dut = 1'b0;
      downstream_is_dut = 1'b0;
      foreach (policy.dut_node_ids[i]) begin
        if (policy.dut_node_ids[i] == upstream_node.node_id)
          upstream_is_dut = 1'b1;
        if (policy.dut_node_ids[i] == downstream_node.node_id)
          downstream_is_dut = 1'b1;
      end
      if (upstream_is_dut == downstream_is_dut) begin
        errors.push_back($sformatf(
          "link '%s': exactly one endpoint must be DUT-owned",
          link.link_id));
        continue;
      end

      svt_node = upstream_is_dut ? downstream_node : upstream_node;
      if (svt_node.kind == PCIE_TOPO_NODE_SWITCH) begin
        errors.push_back($sformatf(
          "link '%s': SVT cannot implement a Switch node", link.link_id));
        continue;
      end

      descriptor = pcie_svt_port_descriptor::type_id::create(
        $sformatf("port_%0d", ports.size()));
      descriptor.link_id = link.link_id;
      descriptor.svt_node_id = svt_node.node_id;
      if (policy.hdl_slot_by_link.exists(link.link_id))
        descriptor.slot_index = policy.hdl_slot_by_link[link.link_id];
      else
        descriptor.slot_index = physical_slot;
      descriptor.vif_key = {policy.vif_prefix,
                            $sformatf("%0d", descriptor.slot_index)};
      descriptor.role = (svt_node.kind == PCIE_TOPO_NODE_RC) ?
                        PCIE_SVT_ROLE_RC : PCIE_SVT_ROLE_EP;
      descriptor.physical_width = link.link_width;
      descriptor.link_width = active_width;
      descriptor.max_gen = active_gen;
      descriptor.fast_link_training = effective_fast(policy, override_cfg);
      descriptor.transport = policy.transport;
      descriptor.cfg_timeout = policy.cfg_timeout;
      descriptor.link_timeout = effective_link_timeout(policy, override_cfg);
      descriptor.enum_timeout = policy.enum_timeout;
      descriptor.traffic_timeout = policy.traffic_timeout;
      foreach (descriptor.ep_bars[bar])
        descriptor.ep_bars[bar].copy(policy.ep_bars[bar]);
      ports.push_back(descriptor);
    end

    assign_root_hierarchies(topology, ports);

    foreach (ports[i]) begin
      if (descriptor_link_ids.exists(ports[i].link_id)) begin
        errors.push_back($sformatf("duplicate descriptor link ID '%s'",
                                  ports[i].link_id));
      end else begin
        descriptor_link_ids[ports[i].link_id] = 1'b1;
      end
      if (slot_owner.exists(ports[i].slot_index)) begin
        errors.push_back($sformatf(
          "effective HDL slot %0d is used by both '%s' and '%s'",
          ports[i].slot_index, slot_owner[ports[i].slot_index],
          ports[i].link_id));
      end else begin
        slot_owner[ports[i].slot_index] = ports[i].link_id;
      end
    end
    if ((ports.size() == 0) && (errors.size() == 0))
      errors.push_back("topology produced no SVT port descriptors");
  endfunction

  protected function bit find_override(
      pcie_svt_topology_policy_cfg policy,
      string link_id,
      output pcie_svt_link_override_cfg result);
    result = null;
    if (policy == null)
      return 1'b0;
    foreach (policy.link_overrides[i]) begin
      if ((policy.link_overrides[i] != null) &&
          (policy.link_overrides[i].link_id == link_id)) begin
        result = policy.link_overrides[i];
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  protected function int unsigned effective_width(
      pcie_topology_link_cfg link,
      pcie_svt_link_override_cfg override_cfg);
    if ((override_cfg != null) && override_cfg.has_width)
      return override_cfg.link_width;
    return link.link_width;
  endfunction

  protected function int unsigned effective_gen(
      pcie_topology_link_cfg link,
      pcie_svt_link_override_cfg override_cfg);
    if ((override_cfg != null) && override_cfg.has_gen)
      return override_cfg.max_gen;
    return link.max_gen;
  endfunction

  protected function bit effective_fast(
      pcie_svt_topology_policy_cfg policy,
      pcie_svt_link_override_cfg override_cfg);
    if ((override_cfg != null) && override_cfg.has_fast_link_training)
      return override_cfg.fast_link_training;
    return policy.default_fast_link_training;
  endfunction

  protected function time effective_link_timeout(
      pcie_svt_topology_policy_cfg policy,
      pcie_svt_link_override_cfg override_cfg);
    if ((override_cfg != null) && override_cfg.has_link_timeout)
      return override_cfg.link_timeout;
    return policy.link_timeout;
  endfunction

  protected function void sort_pending_links_by_link_id(
      ref pcie_topology_link_cfg links[$]);
    for (int i = 0; i < links.size(); i++) begin
      for (int j = i + 1; j < links.size(); j++) begin
        if ((links[j] != null) &&
            ((links[i] == null) ||
             (links[j].link_id < links[i].link_id))) begin
          pcie_topology_link_cfg temporary;
          temporary = links[i];
          links[i] = links[j];
          links[j] = temporary;
        end
      end
    end
  endfunction

  protected function void assign_root_hierarchies(
      pcie_topology_cfg topology,
      ref pcie_svt_port_descriptor ports[$]);
    pcie_topology_link_cfg physical_links[$];
    bit has_switch;

    has_switch = 1'b0;
    if (topology == null)
      return;
    foreach (topology.nodes[i]) begin
      if ((topology.nodes[i] != null) &&
          (topology.nodes[i].kind == PCIE_TOPO_NODE_SWITCH)) begin
        has_switch = 1'b1;
      end
    end
    if (has_switch) begin
      foreach (ports[i])
        ports[i].root_hierarchy = 0;
      return;
    end

    foreach (topology.links[i])
      physical_links.push_back(topology.links[i]);
    sort_pending_links_by_link_id(physical_links);
    foreach (ports[i]) begin
      foreach (physical_links[physical_slot]) begin
        if ((physical_links[physical_slot] != null) &&
            (physical_links[physical_slot].link_id == ports[i].link_id)) begin
          ports[i].root_hierarchy = physical_slot;
          break;
        end
      end
    end
  endfunction
endclass
