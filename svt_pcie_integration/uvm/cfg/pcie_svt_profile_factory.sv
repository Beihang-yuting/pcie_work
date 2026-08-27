class pcie_svt_profile_factory extends uvm_object;
  `uvm_object_utils(pcie_svt_profile_factory)

  function new(string name = "pcie_svt_profile_factory");
    super.new(name);
  endfunction

  static function void build(
      string profile_name,
      int unsigned max_gen,
      output pcie_topology_cfg topology,
      output pcie_svt_topology_policy_cfg policy,
      output string errors[$]);
    errors.delete();
    topology = null;
    policy = pcie_svt_topology_policy_cfg::type_id::create(
      {profile_name, "_policy"});
    policy.init_defaults();

    case (profile_name)
      "EP_X16": begin
        topology = pcie_topology_builder::build_ep_x16(max_gen);
        policy.dut_node_ids.push_back("EP0");
      end
      "EP_2X8": begin
        topology = pcie_topology_builder::build_ep_2x8(max_gen);
        policy.dut_node_ids.push_back("EP0");
        policy.dut_node_ids.push_back("EP1");
      end
      "SWITCH_1X16_4X4": begin
        topology = pcie_topology_builder::build_switch_1x16_4x4(max_gen);
        policy.dut_node_ids.push_back("SW0");
      end
      default: begin
        errors.push_back($sformatf("unknown topology profile '%s'",
                                  profile_name));
      end
    endcase
  endfunction

  static function void apply_overrides(
      pcie_topology_cfg topology,
      input pcie_svt_link_override_cfg overrides[$],
      pcie_svt_topology_policy_cfg policy,
      output string errors[$]);
    bit topology_link_ids[string];
    pcie_svt_topology_policy_cfg candidate;

    errors.delete();
    if ((topology == null) || (policy == null)) begin
      errors.push_back("topology and policy must both be non-null");
      return;
    end

    foreach (topology.links[i]) begin
      if (topology.links[i] != null)
        topology_link_ids[topology.links[i].link_id] = 1'b1;
    end
    foreach (overrides[i]) begin
      if (overrides[i] == null) begin
        errors.push_back($sformatf("link override at index %0d is null", i));
      end else if (!topology_link_ids.exists(overrides[i].link_id)) begin
        errors.push_back($sformatf("override references unknown link '%s'",
                                  overrides[i].link_id));
      end
    end
    if (errors.size() != 0)
      return;

    $cast(candidate, policy.clone());
    candidate.link_overrides.delete();
    foreach (overrides[i]) begin
      pcie_svt_link_override_cfg override_copy;
      override_copy = pcie_svt_link_override_cfg::type_id::create(
        $sformatf("link_override%0d", i));
      override_copy.copy(overrides[i]);
      candidate.link_overrides.push_back(override_copy);
    end
    candidate.validate(errors);
    if (errors.size() != 0)
      return;
    policy.copy(candidate);
  endfunction
endclass
