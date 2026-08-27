import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_svt_topology_pkg::*;
`include "uvm_macros.svh"

class pcie_svt_cli_parser_unit_test extends uvm_test;
  `uvm_component_utils(pcie_svt_cli_parser_unit_test)

  function new(string name = "pcie_svt_cli_parser_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void require(bit condition, string message);
    if (!condition)
      `uvm_error("SVT_CLI", message)
  endfunction

  function bit error_contains(input string errors[$], string fragment);
    foreach (errors[i])
      if (uvm_is_match({"*", fragment, "*"}, errors[i]))
        return 1'b1;
    return 1'b0;
  endfunction

  task check_parse_error(
      pcie_svt_cli_parser parser,
      string label,
      input string args[$],
      string expected_fragment);
    string profile_name;
    int unsigned max_gen;
    bit fast_link_training;
    pcie_svt_transport_e transport;
    pcie_svt_run_mode_e run_mode;
    pcie_svt_link_override_cfg overrides[$];
    pcie_svt_link_override_cfg stale_override;
    string errors[$];

    stale_override = pcie_svt_link_override_cfg::type_id::create(
      {label, "_stale_override"});
    profile_name = "STALE_PROFILE";
    max_gen = 99;
    fast_link_training = 1'b1;
    transport = PCIE_SVT_TRANSPORT_PIPE;
    run_mode = PCIE_SVT_RUN_TRAFFIC;
    overrides.push_back(stale_override);
    errors.push_back("stale error");
    parser.parse_tokens(args, profile_name, max_gen, fast_link_training,
                        transport, run_mode, overrides, errors);
    require(errors.size() != 0,
            $sformatf("%s returned no diagnostic", label));
    require(error_contains(errors, expected_fragment),
            $sformatf("%s omitted expected diagnostic '%s': %s", label,
                      expected_fragment, pcie_svt_join_errors(errors)));
    require(!error_contains(errors, "stale error"),
            $sformatf("%s retained stale diagnostics", label));
    require(profile_name == "" && max_gen == 0 && !fast_link_training &&
            transport == PCIE_SVT_TRANSPORT_SERIAL &&
            run_mode == PCIE_SVT_RUN_COMPILE,
            $sformatf("%s did not restore deterministic scalar defaults",
                      label));
    require(overrides.size() == 0,
            $sformatf("%s exposed %0d partial overrides", label,
                      overrides.size()));
  endtask

  task check_peer_fixture(
      string profile_name,
      int unsigned expected_port_count);
    pcie_topology_cfg topology;
    pcie_topology_cfg peer_topology;
    pcie_svt_topology_policy_cfg policy;
    pcie_svt_topology_policy_cfg peer_policy;
    pcie_svt_topology_adapter adapter;
    pcie_svt_port_descriptor primary_ports[$];
    pcie_svt_port_descriptor peer_ports[$];
    string errors[$];
    string validation_errors[$];

    pcie_svt_profile_factory::build(profile_name, 5, topology, policy,
                                    errors);
    require(errors.size() == 0,
            $sformatf("%s factory failed: %s", profile_name,
                      pcie_svt_join_errors(errors)));
    adapter = pcie_svt_topology_adapter::type_id::create(
      {profile_name, "_peer_adapter"});
    adapter.translate(topology, policy, primary_ports, errors);
    require(errors.size() == 0,
            $sformatf("%s primary adapter failed: %s", profile_name,
                      pcie_svt_join_errors(errors)));
    require(primary_ports.size() == expected_port_count,
            $sformatf("%s produced %0d primary ports, expected %0d",
                      profile_name, primary_ports.size(),
                      expected_port_count));

    pcie_svt_peer_fixture_builder::build(
      primary_ports, peer_topology, peer_policy, errors);
    require(errors.size() == 0,
            $sformatf("%s peer fixture failed: %s", profile_name,
                      pcie_svt_join_errors(errors)));
    require(peer_topology != null && peer_policy != null,
            $sformatf("%s peer fixture returned null outputs", profile_name));
    if ((peer_topology == null) || (peer_policy == null))
      return;

    peer_topology.validate(validation_errors);
    require(validation_errors.size() == 0,
            $sformatf("%s peer topology invalid: %s", profile_name,
                      pcie_svt_join_errors(validation_errors)));
    peer_policy.validate(validation_errors);
    require(validation_errors.size() == 0,
            $sformatf("%s peer policy invalid: %s", profile_name,
                      pcie_svt_join_errors(validation_errors)));
    require(peer_policy.vif_prefix == "peer_vif_" &&
            peer_policy.reset_vif_key == "peer_reset_vif",
            $sformatf("%s peer policy VIF keys are wrong", profile_name));
    require(peer_topology.nodes.size() == (2 * primary_ports.size()) &&
            peer_topology.links.size() == primary_ports.size(),
            $sformatf("%s peer fixture is not independent direct pairs",
                      profile_name));
    foreach (peer_topology.nodes[i]) begin
      if (peer_topology.nodes[i] != null)
        require(peer_topology.nodes[i].kind != PCIE_TOPO_NODE_SWITCH,
                $sformatf("%s peer fixture created a Switch", profile_name));
    end
    foreach (primary_ports[i]) begin
      string peer_link_id;
      string expected_rc_node_id;
      string expected_ep_node_id;
      pcie_topology_link_cfg peer_link;
      pcie_topology_node_cfg expected_rc_node;
      pcie_topology_node_cfg expected_ep_node;
      expected_rc_node_id = $sformatf("RC_%0d", i);
      expected_ep_node_id = $sformatf("EP_%0d", i);
      peer_link_id = $sformatf("PEER_LINK_%0d",
                               primary_ports[i].slot_index);
      expected_rc_node = peer_topology.find_node(expected_rc_node_id);
      expected_ep_node = peer_topology.find_node(expected_ep_node_id);
      require(expected_rc_node != null,
              $sformatf("%s omitted exact peer node %s", profile_name,
                        expected_rc_node_id));
      if (expected_rc_node != null)
        require(expected_rc_node.kind == PCIE_TOPO_NODE_RC,
                $sformatf("%s peer node %s is not an RC", profile_name,
                          expected_rc_node_id));
      require(expected_ep_node != null,
              $sformatf("%s omitted exact peer node %s", profile_name,
                        expected_ep_node_id));
      if (expected_ep_node != null)
        require(expected_ep_node.kind == PCIE_TOPO_NODE_EP,
                $sformatf("%s peer node %s is not an EP", profile_name,
                          expected_ep_node_id));
      peer_link = null;
      foreach (peer_topology.links[j]) begin
        if ((peer_topology.links[j] != null) &&
            (peer_topology.links[j].link_id == peer_link_id))
          peer_link = peer_topology.links[j];
      end
      require(peer_link != null,
              $sformatf("%s omitted %s", profile_name, peer_link_id));
      if (peer_link != null) begin
        require(peer_link.enabled &&
                peer_link.link_width == primary_ports[i].physical_width &&
                peer_link.max_gen == primary_ports[i].max_gen,
                $sformatf("%s physical parameters mismatch", peer_link_id));
        require(peer_link.upstream_node_id == expected_rc_node_id &&
                peer_link.downstream_node_id == expected_ep_node_id,
                $sformatf("%s does not connect exact pair %s/%s",
                          peer_link_id, expected_rc_node_id,
                          expected_ep_node_id));
      end
      require(peer_policy.hdl_slot_by_link.exists(peer_link_id) &&
              peer_policy.hdl_slot_by_link[peer_link_id] ==
                primary_ports[i].slot_index,
              $sformatf("%s slot map is wrong", peer_link_id));
    end

    adapter.translate(peer_topology, peer_policy, peer_ports, errors);
    require(errors.size() == 0,
            $sformatf("%s peer adapter failed: %s", profile_name,
                      pcie_svt_join_errors(errors)));
    require(peer_ports.size() == primary_ports.size(),
            $sformatf("%s peer descriptor count mismatch", profile_name));
    foreach (primary_ports[i]) begin
      pcie_svt_port_descriptor matching_peer;
      matching_peer = null;
      foreach (peer_ports[j]) begin
        if (peer_ports[j].slot_index == primary_ports[i].slot_index)
          matching_peer = peer_ports[j];
      end
      require(matching_peer != null,
              $sformatf("%s has no peer at slot %0d", profile_name,
                        primary_ports[i].slot_index));
      if (matching_peer != null) begin
        require(matching_peer.link_id ==
                  $sformatf("PEER_LINK_%0d", primary_ports[i].slot_index),
                $sformatf("%s peer link ID is wrong", profile_name));
        require(matching_peer.vif_key ==
                  $sformatf("peer_vif_%0d", primary_ports[i].slot_index),
                $sformatf("%s peer VIF key is wrong", profile_name));
        require(matching_peer.physical_width ==
                  primary_ports[i].physical_width &&
                matching_peer.link_width == primary_ports[i].link_width &&
                matching_peer.max_gen == primary_ports[i].max_gen,
                $sformatf("%s peer descriptor parameters mismatch",
                          profile_name));
        require(matching_peer.role ==
                  ((primary_ports[i].role == PCIE_SVT_ROLE_RC) ?
                    PCIE_SVT_ROLE_EP : PCIE_SVT_ROLE_RC),
                $sformatf("%s peer role was not inverted at slot %0d",
                          profile_name, primary_ports[i].slot_index));
      end
    end
  endtask

  task run_phase(uvm_phase phase);
    pcie_svt_cli_parser parser;
    pcie_svt_topology_adapter adapter;
    string args[$];
    string profile_name;
    int unsigned max_gen;
    bit fast_link_training;
    pcie_svt_transport_e transport;
    pcie_svt_run_mode_e run_mode;
    pcie_svt_link_override_cfg overrides[$];
    pcie_svt_link_override_cfg override_cfg;
    pcie_svt_link_override_cfg policy_sentinel;
    pcie_svt_link_override_cfg peer_width_override;
    pcie_svt_link_override_cfg invalid_overrides[$];
    pcie_topology_cfg topology;
    pcie_topology_cfg peer_topology;
    pcie_svt_topology_policy_cfg policy;
    pcie_svt_topology_policy_cfg peer_policy;
    pcie_svt_port_descriptor ports[$];
    pcie_svt_port_descriptor peer_ports[$];
    pcie_svt_port_descriptor invalid_primary_ports[$];
    pcie_svt_port_descriptor duplicate_port;
    pcie_svt_port_descriptor invalid_width_port;
    string errors[$];
    string validation_errors[$];

    phase.raise_objection(this);
    parser = pcie_svt_cli_parser::type_id::create("parser");
    adapter = pcie_svt_topology_adapter::type_id::create("adapter");

    args = '{"+PCIE_TOPOLOGY=EP_2X8", "+PCIE_GEN=5",
             "+PCIE_TRANSPORT=SERIAL", "+PCIE_FAST_LINK_TRAIN=1",
             "+PCIE_LINK_RC1_EP1_GEN=4",
             "+PCIE_LINK_RC1_EP1_WIDTH=4", "+PCIE_TRAFFIC"};
    parser.parse_tokens(args, profile_name, max_gen, fast_link_training,
                        transport, run_mode, overrides, errors);
    require(errors.size() == 0,
            {"legal CLI was rejected: ", pcie_svt_join_errors(errors)});
    require(profile_name == "EP_2X8" && max_gen == 5 &&
            fast_link_training &&
            transport == PCIE_SVT_TRANSPORT_SERIAL &&
            run_mode == PCIE_SVT_RUN_TRAFFIC,
            "global CLI values mismatch");
    require(overrides.size() == 1 &&
            overrides[0].link_id == "RC1_EP1" &&
            overrides[0].has_gen && overrides[0].max_gen == 4 &&
            overrides[0].has_width && overrides[0].link_width == 4,
            "per-link override merge mismatch");

    args = '{"simv", "+UVM_VERBOSITY=UVM_LOW",
             "+PCIE_TOPOLOGY=EP_X16", "+PCIE_GEN=4",
             "+PCIE_COMPILE_ONLY"};
    parser.parse_tokens(args, profile_name, max_gen, fast_link_training,
                        transport, run_mode, overrides, errors);
    require(errors.size() == 0 && profile_name == "EP_X16" &&
            max_gen == 4 && !fast_link_training &&
            transport == PCIE_SVT_TRANSPORT_SERIAL &&
            run_mode == PCIE_SVT_RUN_COMPILE && overrides.size() == 0,
            "default transport/fast parsing mismatch");

    args = '{"+PCIE_TOPOLOGY=EP_2X8", "+PCIE_GEN=5",
             "+PCIE_LINK_RC1_EP1_ENABLE=0",
             "+PCIE_LINK_RC1_EP1_FAST_LINK_TRAIN=1", "+PCIE_LINK_ONLY"};
    parser.parse_tokens(args, profile_name, max_gen, fast_link_training,
                        transport, run_mode, overrides, errors);
    require(errors.size() == 0 && overrides.size() == 1 &&
            overrides[0].link_id == "RC1_EP1" &&
            overrides[0].has_enable && !overrides[0].enabled &&
            overrides[0].has_fast_link_training &&
            overrides[0].fast_link_training,
            "ENABLE/FAST_LINK_TRAIN merge mismatch");

    args = '{"+PCIE_TOPOLOGY=EP_X16", "+PCIE_GEN=5",
             "+PCIE_TRANSPORT=PIPE", "+PCIE_ENUM_ONLY"};
    parser.parse_tokens(args, profile_name, max_gen, fast_link_training,
                        transport, run_mode, overrides, errors);
    require(errors.size() == 0 &&
            transport == PCIE_SVT_TRANSPORT_PIPE &&
            run_mode == PCIE_SVT_RUN_ENUM,
            "PIPE was not accepted syntactically");

    args = '{"+PCIE_GEN=4", "+PCIE_COMPILE_ONLY"};
    check_parse_error(parser, "missing topology", args,
                      "missing required +PCIE_TOPOLOGY");
    args = '{"+PCIE_TOPOLOGY=EP_X16", "+PCIE_COMPILE_ONLY"};
    check_parse_error(parser, "missing Gen", args,
                      "missing required +PCIE_GEN");
    args = '{"+PCIE_TOPOLOGY=EP_X16", "+PCIE_GEN=4"};
    check_parse_error(parser, "missing run mode", args,
                      "missing required PCIe run mode");
    args = '{"+PCIE_TOPOLOGY", "+PCIE_GEN=4", "+PCIE_COMPILE_ONLY"};
    check_parse_error(parser, "bare topology", args,
                      "argument '+PCIE_TOPOLOGY' requires '=value'");
    args = '{"+PCIE_TOPOLOGY=", "+PCIE_GEN=4", "+PCIE_COMPILE_ONLY"};
    check_parse_error(parser, "empty topology", args,
                      "argument '+PCIE_TOPOLOGY=' has an empty value");
    args = '{"+PCIE_TOPOLOGY=EP_X16", "+PCIE_TOPOLOGY=EP_X16",
             "+PCIE_GEN=4", "+PCIE_COMPILE_ONLY"};
    check_parse_error(parser, "duplicate topology", args,
                      "duplicate +PCIE_TOPOLOGY argument");
    args = '{"+PCIE_TOPOLOGY=BAD", "+PCIE_GEN=4",
             "+PCIE_COMPILE_ONLY"};
    check_parse_error(parser, "unknown profile", args,
                      "invalid +PCIE_TOPOLOGY value 'BAD'");
    args = '{"+PCIE_TOPOLOGY=EP_X16", "+PCIE_GEN=3",
             "+PCIE_COMPILE_ONLY"};
    check_parse_error(parser, "Gen3", args,
                      "invalid +PCIE_GEN value '3'");
    args = '{"+PCIE_TOPOLOGY=EP_X16", "+PCIE_GEN=4",
             "+PCIE_TRANSPORT=PARALLEL", "+PCIE_COMPILE_ONLY"};
    check_parse_error(parser, "invalid transport", args,
                      "invalid +PCIE_TRANSPORT value 'PARALLEL'");
    args = '{"+PCIE_TOPOLOGY=EP_X16", "+PCIE_GEN=4",
             "+PCIE_LINK_ONLY", "+PCIE_TRAFFIC"};
    check_parse_error(parser, "duplicate run mode", args,
                      "multiple PCIe run modes specified");
    args = '{"+PCIE_TOPOLOGY=EP_X16", "+PCIE_GEN=4",
             "+PCIE_FAST_LINK_TRAIN", "+PCIE_COMPILE_ONLY"};
    check_parse_error(parser, "bare fast", args,
                      "argument '+PCIE_FAST_LINK_TRAIN' requires '=value'");
    args = '{"+PCIE_TOPOLOGY=EP_X16", "+PCIE_GEN=4",
             "+PCIE_LINK_RC0_EP0_SPEED=4", "+PCIE_COMPILE_ONLY"};
    check_parse_error(parser, "unknown per-link field", args,
                      "unknown per-link field 'SPEED'");
    args = '{"+PCIE_TOPOLOGY=EP_X16", "+PCIE_GEN=4",
             "+PCIE_LINK__GEN=4", "+PCIE_COMPILE_ONLY"};
    check_parse_error(parser, "empty link ID", args,
                      "per-link argument has an empty link ID");
    args = '{"+PCIE_TOPOLOGY=EP_X16", "+PCIE_GEN=4",
             "+PCIE_LINK_RC0_EP0_GEN", "+PCIE_COMPILE_ONLY"};
    check_parse_error(parser, "missing per-link value", args,
                      "argument '+PCIE_LINK_RC0_EP0_GEN' requires '=value'");
    args = '{"+PCIE_TOPOLOGY=EP_X16", "+PCIE_GEN=4",
             "+PCIE_LINK_RC0_EP0_WIDTH=3", "+PCIE_COMPILE_ONLY"};
    check_parse_error(parser, "invalid per-link value", args,
                      "invalid WIDTH value '3'");
    args = '{"+PCIE_TOPOLOGY=EP_X16", "+PCIE_GEN=4",
             "+PCIE_LINK_RC0_EP0_GEN=4",
             "+PCIE_LINK_RC0_EP0_GEN=5", "+PCIE_COMPILE_ONLY"};
    check_parse_error(parser, "conflicting per-link field", args,
                      "duplicate per-link field 'GEN' for link 'RC0_EP0'");
    args = '{"+PCIE_TOPOLOGY=EP_X16", "+PCIE_GEN=4",
             "+PCIE_LINK_RC0_EP0_GEN=4",
             "+PCIE_LINK_RC0_EP0_GEN=4", "+PCIE_COMPILE_ONLY"};
    check_parse_error(parser, "identical per-link field", args,
                      "duplicate per-link field 'GEN' for link 'RC0_EP0'");
    args = '{"+PCIE_TOPOLOGY=EP_X16", "+PCIE_GEN=4",
             "+PCIE_BOGUS=1", "+PCIE_COMPILE_ONLY"};
    check_parse_error(parser, "unknown PCIe argument", args,
                      "unknown PCIe argument '+PCIE_BOGUS=1'");

    require(pcie_svt_compiled_profile_name() == "EP_X16",
            {"compiled profile is '", pcie_svt_compiled_profile_name(),
             "', expected EP_X16"});

    pcie_svt_profile_factory::build("EP_X16", 5, topology, policy, errors);
    require(errors.size() == 0 && topology != null && policy != null,
            "EP_X16 factory failed");
    topology.validate(validation_errors);
    require(validation_errors.size() == 0,
            {"EP_X16 topology invalid: ",
             pcie_svt_join_errors(validation_errors)});
    policy.validate(validation_errors);
    require(validation_errors.size() == 0,
            {"EP_X16 policy invalid: ",
             pcie_svt_join_errors(validation_errors)});
    adapter.translate(topology, policy, ports, errors);
    require(errors.size() == 0 && ports.size() == 1 &&
            ports[0].role == PCIE_SVT_ROLE_RC &&
            ports[0].physical_width == 16,
            "EP_X16 descriptor contract mismatch");

    pcie_svt_profile_factory::build("EP_2X8", 5, topology, policy, errors);
    topology.validate(validation_errors);
    require(errors.size() == 0 && validation_errors.size() == 0,
            "EP_2X8 factory topology failed validation");
    policy.validate(validation_errors);
    require(validation_errors.size() == 0,
            "EP_2X8 factory policy failed validation");
    adapter.translate(topology, policy, ports, errors);
    require(errors.size() == 0 && ports.size() == 2,
            "EP_2X8 descriptor count mismatch");
    foreach (ports[i]) begin
      require(ports[i].role == PCIE_SVT_ROLE_RC &&
              ports[i].physical_width == 8,
              $sformatf("EP_2X8 descriptor %0d contract mismatch", i));
    end

    override_cfg = pcie_svt_link_override_cfg::type_id::create(
      "factory_override");
    override_cfg.link_id = "RC1_EP1";
    override_cfg.has_width = 1'b1;
    override_cfg.link_width = 4;
    override_cfg.has_gen = 1'b1;
    override_cfg.max_gen = 4;
    override_cfg.has_fast_link_training = 1'b1;
    override_cfg.fast_link_training = 1'b1;
    override_cfg.has_link_timeout = 1'b1;
    override_cfg.link_timeout = 2ms;
    overrides.delete();
    overrides.push_back(override_cfg);
    pcie_svt_profile_factory::apply_overrides(topology, overrides, policy,
                                              errors);
    require(errors.size() == 0 && policy.link_overrides.size() == 1 &&
            policy.link_overrides[0] != override_cfg,
            "valid override was not deep-cloned into policy");
    override_cfg.link_width = 8;
    override_cfg.max_gen = 5;
    require(policy.link_overrides[0].link_width == 4 &&
            policy.link_overrides[0].max_gen == 4 &&
            policy.link_overrides[0].fast_link_training &&
            policy.link_overrides[0].link_timeout == 2ms,
            "source override mutation changed policy clone");
    adapter.translate(topology, policy, ports, errors);
    require(errors.size() == 0 && ports.size() == 2 &&
            ports[1].link_width == 4 && ports[1].max_gen == 4 &&
            ports[1].fast_link_training && ports[1].link_timeout == 2ms,
            "factory override did not reach adapter descriptor");

    pcie_svt_peer_fixture_builder::build(
      ports, peer_topology, peer_policy, errors);
    require(errors.size() == 0 && peer_topology != null &&
            peer_policy != null,
            {"active-width peer fixture failed: ",
             pcie_svt_join_errors(errors)});
    peer_width_override = null;
    if (peer_policy != null) begin
      foreach (peer_policy.link_overrides[i]) begin
        if ((peer_policy.link_overrides[i] != null) &&
            (peer_policy.link_overrides[i].link_id == "PEER_LINK_1"))
          peer_width_override = peer_policy.link_overrides[i];
      end
    end
    require(peer_width_override != null,
            "peer policy omitted its owned PEER_LINK_1 x4 override");
    if (peer_width_override != null) begin
      require(peer_width_override.has_width &&
              peer_width_override.link_width == 4 &&
              peer_width_override.has_fast_link_training &&
              peer_width_override.fast_link_training &&
              peer_width_override.has_link_timeout &&
              peer_width_override.link_timeout == 2ms &&
              peer_width_override != policy.link_overrides[0],
              "peer PEER_LINK_1 pair override is incomplete or aliased");
    end
    ports[1].link_width = 8;
    ports[1].fast_link_training = 1'b0;
    ports[1].link_timeout = 1ms;
    if (peer_width_override != null)
      require(peer_width_override.link_width == 4 &&
              peer_width_override.fast_link_training &&
              peer_width_override.link_timeout == 2ms,
              "peer pair override aliases the primary descriptor");
    adapter.translate(peer_topology, peer_policy, peer_ports, errors);
    require(errors.size() == 0 && peer_ports.size() == 2,
            {"active-width peer adapter failed: ",
             pcie_svt_join_errors(errors)});
    if (peer_ports.size() == 2) begin
      require(peer_ports[1].slot_index == 1 &&
              peer_ports[1].physical_width == 8 &&
              peer_ports[1].link_width == 4 &&
              peer_ports[1].fast_link_training &&
              peer_ports[1].link_timeout == 2ms,
              "peer descriptor lost an effective pair parameter");
    end

    invalid_overrides.delete();
    override_cfg = pcie_svt_link_override_cfg::type_id::create(
      "invalid_candidate_gen_override");
    override_cfg.link_id = "RC0_EP0";
    override_cfg.has_gen = 1'b1;
    override_cfg.max_gen = 3;
    invalid_overrides.push_back(override_cfg);
    policy_sentinel = policy.link_overrides[0];
    pcie_svt_profile_factory::apply_overrides(topology, invalid_overrides,
                                              policy, errors);
    require(error_contains(errors,
                           "link override 'RC0_EP0' Gen must be 4 or 5") &&
            policy.link_overrides.size() == 1 &&
            policy.link_overrides[0] == policy_sentinel &&
            policy_sentinel.link_id == "RC1_EP1" &&
            policy_sentinel.has_width &&
            policy_sentinel.link_width == 4 &&
            policy_sentinel.has_gen && policy_sentinel.max_gen == 4,
            "candidate validation failure mutated valid policy state");
    override_cfg.max_gen = 5;
    require(policy_sentinel.max_gen == 4,
            "failed candidate override aliases the valid policy sentinel");

    invalid_overrides.delete();
    override_cfg = pcie_svt_link_override_cfg::type_id::create(
      "unknown_factory_override");
    override_cfg.link_id = "UNKNOWN";
    invalid_overrides.push_back(override_cfg);
    pcie_svt_profile_factory::apply_overrides(topology, invalid_overrides,
                                              policy, errors);
    require(error_contains(errors, "override references unknown link 'UNKNOWN'") &&
            policy.link_overrides.size() == 1,
            "unknown override was not rejected atomically");
    invalid_overrides.delete();
    invalid_overrides.push_back(null);
    pcie_svt_profile_factory::apply_overrides(topology, invalid_overrides,
                                              policy, errors);
    require(error_contains(errors, "link override at index 0 is null") &&
            policy.link_overrides.size() == 1,
            "null override was not rejected atomically");
    pcie_svt_profile_factory::apply_overrides(null, overrides, policy,
                                              errors);
    require(errors.size() == 1 &&
            errors[0] == "topology and policy must both be non-null",
            "null topology diagnostic mismatch");
    pcie_svt_profile_factory::apply_overrides(topology, overrides, null,
                                              errors);
    require(errors.size() == 1 &&
            errors[0] == "topology and policy must both be non-null",
            "null policy diagnostic mismatch");

    pcie_svt_profile_factory::build("SWITCH_1X16_4X4", 5,
                                    topology, policy, errors);
    topology.validate(validation_errors);
    require(errors.size() == 0 && validation_errors.size() == 0,
            "Switch factory topology failed validation");
    policy.validate(validation_errors);
    require(validation_errors.size() == 0,
            "Switch factory policy failed validation");
    adapter.translate(topology, policy, ports, errors);
    require(errors.size() == 0 && ports.size() == 5,
            "Switch descriptor count mismatch");
    if (ports.size() == 5) begin
      require(ports[0].role == PCIE_SVT_ROLE_RC &&
              ports[0].physical_width == 16,
              "Switch USP descriptor contract mismatch");
      for (int i = 1; i < 5; i++) begin
        require(ports[i].role == PCIE_SVT_ROLE_EP &&
                ports[i].physical_width == 4,
                $sformatf("Switch DSP descriptor %0d contract mismatch", i));
      end
    end

    pcie_svt_profile_factory::build("UNKNOWN", 5, topology, policy, errors);
    require(topology == null && policy != null &&
            errors.size() == 1 &&
            errors[0] == "unknown topology profile 'UNKNOWN'" &&
            policy.get_name() == "UNKNOWN_policy",
            "unknown profile factory contract mismatch");

    check_peer_fixture("EP_X16", 1);
    check_peer_fixture("EP_2X8", 2);
    check_peer_fixture("SWITCH_1X16_4X4", 5);

    pcie_svt_profile_factory::build("EP_2X8", 5, topology, policy, errors);
    override_cfg = pcie_svt_link_override_cfg::type_id::create(
      "disable_peer_slot_zero");
    override_cfg.link_id = "RC0_EP0";
    override_cfg.has_enable = 1'b1;
    override_cfg.enabled = 1'b0;
    overrides.delete();
    overrides.push_back(override_cfg);
    pcie_svt_profile_factory::apply_overrides(topology, overrides, policy,
                                              errors);
    adapter.translate(topology, policy, ports, errors);
    require(errors.size() == 0 && ports.size() == 1 &&
            ports[0].slot_index == 1,
            "disabled primary link did not preserve slot-one gap");
    pcie_svt_peer_fixture_builder::build(
      ports, peer_topology, peer_policy, errors);
    require(errors.size() == 0 && peer_topology.links.size() == 1 &&
            peer_topology.links[0].link_id == "PEER_LINK_1" &&
            peer_topology.links[0].upstream_node_id == "RC_0" &&
            peer_topology.links[0].downstream_node_id == "EP_0" &&
            peer_topology.find_node("RC_0") != null &&
            peer_topology.find_node("EP_0") != null &&
            peer_policy.hdl_slot_by_link.exists("PEER_LINK_1") &&
            peer_policy.hdl_slot_by_link["PEER_LINK_1"] == 1,
            "peer fixture pair index or disabled primary slot gap is wrong");
    adapter.translate(peer_topology, peer_policy, invalid_primary_ports,
                      errors);
    require(errors.size() == 0 && invalid_primary_ports.size() == 1 &&
            invalid_primary_ports[0].slot_index == 1 &&
            invalid_primary_ports[0].vif_key == "peer_vif_1",
            "peer adapter compacted disabled primary slot gap");

    invalid_primary_ports.delete();
    peer_topology = pcie_topology_cfg::type_id::create("stale_peer_topology");
    peer_policy = pcie_svt_topology_policy_cfg::type_id::create(
      "stale_peer_policy");
    pcie_svt_peer_fixture_builder::build(
      invalid_primary_ports, peer_topology, peer_policy, errors);
    require(error_contains(errors, "primary port descriptor array is empty") &&
            peer_topology == null && peer_policy == null,
            "empty primary array was not rejected atomically");

    invalid_primary_ports.push_back(null);
    pcie_svt_peer_fixture_builder::build(
      invalid_primary_ports, peer_topology, peer_policy, errors);
    require(error_contains(errors, "primary port descriptor at index 0 is null") &&
            peer_topology == null && peer_policy == null,
            "null primary descriptor was not rejected atomically");

    pcie_svt_profile_factory::build("EP_2X8", 5, topology, policy, errors);
    adapter.translate(topology, policy, ports, errors);
    invalid_primary_ports.delete();
    invalid_primary_ports.push_back(ports[0]);
    $cast(duplicate_port, ports[1].clone());
    duplicate_port.slot_index = ports[0].slot_index;
    invalid_primary_ports.push_back(duplicate_port);
    pcie_svt_peer_fixture_builder::build(
      invalid_primary_ports, peer_topology, peer_policy, errors);
    require(error_contains(errors, "duplicate primary slot 0") &&
            peer_topology == null && peer_policy == null,
            "duplicate primary slot was not rejected atomically");

    invalid_primary_ports.delete();
    $cast(invalid_width_port, ports[0].clone());
    invalid_width_port.link_width = 3;
    invalid_primary_ports.push_back(invalid_width_port);
    peer_topology = pcie_topology_cfg::type_id::create(
      "stale_illegal_width_topology");
    peer_policy = pcie_svt_topology_policy_cfg::type_id::create(
      "stale_illegal_width_policy");
    pcie_svt_peer_fixture_builder::build(
      invalid_primary_ports, peer_topology, peer_policy, errors);
    require(error_contains(errors, "has illegal active width x3") &&
            peer_topology == null && peer_policy == null,
            "illegal primary active width was not rejected atomically");

    invalid_width_port.link_width = 16;
    peer_topology = pcie_topology_cfg::type_id::create(
      "stale_excess_width_topology");
    peer_policy = pcie_svt_topology_policy_cfg::type_id::create(
      "stale_excess_width_policy");
    pcie_svt_peer_fixture_builder::build(
      invalid_primary_ports, peer_topology, peer_policy, errors);
    require(error_contains(errors,
                           "active width x16 exceeds physical width x8") &&
            peer_topology == null && peer_policy == null,
            "excess primary active width was not rejected atomically");

    phase.drop_objection(this);
  endtask
endclass
