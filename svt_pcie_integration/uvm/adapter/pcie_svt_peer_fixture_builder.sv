class pcie_svt_peer_fixture_builder extends uvm_object;
  `uvm_object_utils(pcie_svt_peer_fixture_builder)

  function new(string name = "pcie_svt_peer_fixture_builder");
    super.new(name);
  endfunction

  static function void build(
      input pcie_svt_port_descriptor primary_ports[$],
      output pcie_topology_cfg peer_topology,
      output pcie_svt_topology_policy_cfg peer_policy,
      output string errors[$]);
    bit slot_seen[int unsigned];
    bit primary_link_seen[string];
    pcie_topology_builder builder;
    pcie_topology_cfg candidate_topology;
    pcie_svt_topology_policy_cfg candidate_policy;
    string validation_errors[$];

    peer_topology = null;
    peer_policy = null;
    errors.delete();
    if (primary_ports.size() == 0) begin
      errors.push_back("primary port descriptor array is empty");
      return;
    end

    foreach (primary_ports[i]) begin
      if (primary_ports[i] == null) begin
        errors.push_back($sformatf(
          "primary port descriptor at index %0d is null", i));
        continue;
      end
      if ($isunknown(primary_ports[i].role) ||
          ((primary_ports[i].role != PCIE_SVT_ROLE_RC) &&
           (primary_ports[i].role != PCIE_SVT_ROLE_EP))) begin
        errors.push_back($sformatf(
          "primary port descriptor at index %0d has an illegal role", i));
      end
      if ((primary_ports[i].physical_width != 4) &&
          (primary_ports[i].physical_width != 8) &&
          (primary_ports[i].physical_width != 16)) begin
        errors.push_back($sformatf(
          "primary port descriptor at index %0d has illegal physical width x%0d",
          i, primary_ports[i].physical_width));
      end
      if ((primary_ports[i].max_gen != 4) &&
          (primary_ports[i].max_gen != 5)) begin
        errors.push_back($sformatf(
          "primary port descriptor at index %0d has illegal max_gen %0d",
          i, primary_ports[i].max_gen));
      end
      if (slot_seen.exists(primary_ports[i].slot_index)) begin
        errors.push_back($sformatf("duplicate primary slot %0d",
                                  primary_ports[i].slot_index));
      end else begin
        slot_seen[primary_ports[i].slot_index] = 1'b1;
      end
      if (primary_ports[i].link_id.len() == 0) begin
        errors.push_back($sformatf(
          "primary port descriptor at index %0d has an empty link ID", i));
      end else if (primary_link_seen.exists(primary_ports[i].link_id)) begin
        errors.push_back($sformatf("duplicate primary link ID '%s'",
                                  primary_ports[i].link_id));
      end else begin
        primary_link_seen[primary_ports[i].link_id] = 1'b1;
      end
    end
    if (errors.size() != 0)
      return;

    builder = pcie_topology_builder::type_id::create("peer_fixture_builder");
    candidate_policy = pcie_svt_topology_policy_cfg::type_id::create(
      "peer_fixture_policy");
    candidate_policy.init_defaults();
    candidate_policy.vif_prefix = "peer_vif_";
    candidate_policy.reset_vif_key = "peer_reset_vif";

    foreach (primary_ports[i]) begin
      string rc_node_id;
      string ep_node_id;
      string peer_link_id;

      rc_node_id = $sformatf("PEER_RC_%0d", primary_ports[i].slot_index);
      ep_node_id = $sformatf("PEER_EP_%0d", primary_ports[i].slot_index);
      peer_link_id = $sformatf("PEER_LINK_%0d",
                               primary_ports[i].slot_index);
      builder.add_rc(rc_node_id);
      builder.add_ep(ep_node_id);
      builder.connect(peer_link_id,
                      rc_node_id, PCIE_TOPO_PORT_RC, 0,
                      ep_node_id, PCIE_TOPO_PORT_EP, 0,
                      primary_ports[i].physical_width,
                      primary_ports[i].max_gen, 1'b1);
      if (primary_ports[i].role == PCIE_SVT_ROLE_RC)
        candidate_policy.dut_node_ids.push_back(rc_node_id);
      else
        candidate_policy.dut_node_ids.push_back(ep_node_id);
      candidate_policy.hdl_slot_by_link[peer_link_id] =
        primary_ports[i].slot_index;
    end
    candidate_topology = builder.finish();
    candidate_topology.validate(validation_errors);
    foreach (validation_errors[i])
      errors.push_back(validation_errors[i]);
    candidate_policy.validate(validation_errors);
    foreach (validation_errors[i])
      errors.push_back(validation_errors[i]);
    if (errors.size() != 0)
      return;

    peer_topology = candidate_topology;
    peer_policy = candidate_policy;
  endfunction
endclass
