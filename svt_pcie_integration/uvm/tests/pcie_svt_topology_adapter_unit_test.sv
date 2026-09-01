import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_svt_topology_pkg::*;
`include "uvm_macros.svh"

class pcie_svt_topology_adapter_unit_test extends uvm_test;
  `uvm_component_utils(pcie_svt_topology_adapter_unit_test)

  function new(string name = "pcie_svt_topology_adapter_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void require(bit condition, string message);
    if (!condition)
      `uvm_error("SVT_ADAPTER", message)
  endfunction

  function bit error_contains(input string errors[$], string fragment);
    foreach (errors[i])
      if (uvm_is_match({"*", fragment, "*"}, errors[i]))
        return 1'b1;
    return 1'b0;
  endfunction

  task check_error(
      string label,
      pcie_svt_topology_adapter adapter,
      pcie_topology_cfg topology,
      pcie_svt_topology_policy_cfg policy,
      string expected_fragment);
    pcie_svt_port_descriptor ports[$];
    string errors[$];

    adapter.translate(topology, policy, ports, errors);
    require(errors.size() != 0,
            $sformatf("%s returned no diagnostic", label));
    require(error_contains(errors, expected_fragment),
            $sformatf("%s omitted expected diagnostic '%s'", label,
                      expected_fragment));
    require(ports.size() == 0,
            $sformatf("%s returned %0d non-atomic descriptors", label,
                      ports.size()));
  endtask

  task run_phase(uvm_phase phase);
    pcie_svt_topology_adapter adapter;
    pcie_topology_cfg topology;
    pcie_svt_topology_policy_cfg policy;
    pcie_svt_topology_policy_cfg disabled_policy;
    pcie_svt_topology_policy_cfg invalid_policy;
    pcie_svt_topology_policy_cfg mapped_policy;
    pcie_svt_topology_policy_cfg propagation_policy;
    pcie_topology_cfg invalid_topology;
    pcie_topology_cfg disabled_link_topology;
    pcie_topology_link_cfg disabled_link;
    pcie_svt_link_override_cfg override_cfg;
    pcie_svt_port_descriptor ports[$];
    string errors[$];
    string expected_switch_ids[5];

    phase.raise_objection(this);
    adapter = pcie_svt_topology_adapter::type_id::create("adapter");

    expected_switch_ids[0] = "RC0_SW0_USP0";
    expected_switch_ids[1] = "SW0_DSP0_EP0";
    expected_switch_ids[2] = "SW0_DSP1_EP1";
    expected_switch_ids[3] = "SW0_DSP2_EP2";
    expected_switch_ids[4] = "SW0_DSP3_EP3";

    topology = pcie_topology_builder::build_switch_1x16_4x4(5);
    topology.links.reverse();
    policy = pcie_svt_topology_policy_cfg::type_id::create("switch_policy");
    policy.init_defaults();
    policy.dut_node_ids.push_back("SW0");
    adapter.translate(topology, policy, ports, errors);
    require(errors.size() == 0, "Switch profile was rejected");
    require(ports.size() == 5, "Switch profile did not produce five ports");
    foreach (expected_switch_ids[i]) begin
      if (i < ports.size()) begin
        require(ports[i].link_id == expected_switch_ids[i],
                $sformatf("Switch port %0d has link ID '%s', expected '%s'",
                          i, ports[i].link_id, expected_switch_ids[i]));
        require(ports[i].slot_index == i,
                $sformatf("Switch port %0d has slot %0d", i,
                          ports[i].slot_index));
        require(ports[i].vif_key == $sformatf("primary_vif_%0d", i),
                $sformatf("Switch port %0d has VIF key '%s'", i,
                          ports[i].vif_key));
        require(ports[i].root_hierarchy == 0,
                $sformatf("Switch port %0d has root hierarchy %0d", i,
                          ports[i].root_hierarchy));
      end
    end
    if (ports.size() == 5) begin
      require(ports[0].role == PCIE_SVT_ROLE_RC,
              "Switch USP descriptor is not an RC");
      require(ports[0].physical_width == 16,
              "Switch USP physical width is not x16");
      for (int i = 1; i < 5; i++) begin
        require(ports[i].role == PCIE_SVT_ROLE_EP,
                $sformatf("Switch DSP descriptor %0d is not an EP", i));
        require(ports[i].physical_width == 4,
                $sformatf("Switch DSP descriptor %0d is not x4", i));
      end
    end

    topology = pcie_topology_builder::build_ep_x16(4);
    policy = pcie_svt_topology_policy_cfg::type_id::create("ep_x16_policy");
    policy.init_defaults();
    policy.dut_node_ids.push_back("EP0");
    adapter.translate(topology, policy, ports, errors);
    require(errors.size() == 0, "EP_X16 profile was rejected");
    require(ports.size() == 1, "EP_X16 profile did not produce one port");
    if (ports.size() == 1) begin
      require(ports[0].link_id == "RC0_EP0",
              "EP_X16 link ordering is wrong");
      require(ports[0].role == PCIE_SVT_ROLE_RC,
              "EP_X16 SVT role is not RC");
      require(ports[0].physical_width == 16,
              "EP_X16 physical width is not x16");
      require(ports[0].root_hierarchy == 0,
              "EP_X16 root hierarchy is not zero");
      require(ports[0].slot_index == 0 &&
              ports[0].vif_key == "primary_vif_0",
              "EP_X16 slot or VIF key is wrong");
    end

    topology = pcie_topology_builder::build_ep_2x8(5);
    topology.links.reverse();
    policy = pcie_svt_topology_policy_cfg::type_id::create("ep_2x8_policy");
    policy.init_defaults();
    policy.dut_node_ids.push_back("EP0");
    policy.dut_node_ids.push_back("EP1");
    adapter.translate(topology, policy, ports, errors);
    require(errors.size() == 0, "EP_2X8 profile was rejected");
    require(ports.size() == 2, "EP_2X8 profile did not produce two ports");
    if (ports.size() == 2) begin
      require(ports[0].link_id == "RC0_EP0" &&
              ports[1].link_id == "RC1_EP1",
              "EP_2X8 link ordering is wrong");
      foreach (ports[i]) begin
        require(ports[i].role == PCIE_SVT_ROLE_RC,
                $sformatf("EP_2X8 port %0d is not an RC", i));
        require(ports[i].physical_width == 8,
                $sformatf("EP_2X8 port %0d is not x8", i));
        require(ports[i].root_hierarchy == i,
                $sformatf("EP_2X8 port %0d has root hierarchy %0d", i,
                          ports[i].root_hierarchy));
        require(ports[i].slot_index == i,
                $sformatf("EP_2X8 port %0d has slot %0d", i,
                          ports[i].slot_index));
        require(ports[i].vif_key == $sformatf("primary_vif_%0d", i),
                $sformatf("EP_2X8 port %0d has VIF key '%s'", i,
                          ports[i].vif_key));
      end
    end

    require(policy.default_endpoint_model == PCIE_SVT_EP_SINGLE,
            "default Endpoint model is not Single Endpoint");
    $cast(propagation_policy, policy.clone());
    override_cfg = pcie_svt_link_override_cfg::type_id::create(
      "endpoint_model_override");
    override_cfg.link_id = "RC0_EP0";
    override_cfg.has_endpoint_model = 1'b1;
    override_cfg.endpoint_model = PCIE_SVT_EP_MULTI_BDF;
    propagation_policy.link_overrides.push_back(override_cfg);
    adapter.translate(topology, propagation_policy, ports, errors);
    require(errors.size() == 0, "Endpoint model override was rejected");
    require(ports[0].endpoint_model == PCIE_SVT_EP_MULTI_BDF,
            "per-link Multiple-BDF model did not propagate");
    require(ports[1].endpoint_model == PCIE_SVT_EP_SINGLE,
            "Single-Endpoint default did not remain on the other link");

    $cast(mapped_policy, policy.clone());
    mapped_policy.hdl_slot_by_link["RC0_EP0"] = 1;
    mapped_policy.hdl_slot_by_link["RC1_EP1"] = 0;
    adapter.translate(topology, mapped_policy, ports, errors);
    require(errors.size() == 0, "non-identity HDL-slot map was rejected");
    require(ports.size() == 2,
            "non-identity HDL-slot map changed the descriptor count");
    if (ports.size() == 2) begin
      require(ports[0].link_id == "RC0_EP0" &&
              ports[1].link_id == "RC1_EP1",
              "non-identity HDL-slot map changed lexical link order");
      require(ports[0].slot_index == 1 &&
              ports[0].vif_key == "primary_vif_1",
              "non-identity HDL-slot map did not remap RC0_EP0");
      require(ports[1].slot_index == 0 &&
              ports[1].vif_key == "primary_vif_0",
              "non-identity HDL-slot map did not remap RC1_EP1");
      require(ports[0].root_hierarchy == 0 &&
              ports[1].root_hierarchy == 1,
              "HDL-slot mapping changed physical root hierarchies");
    end

    $cast(propagation_policy, policy.clone());
    propagation_policy.cfg_timeout = 11us;
    propagation_policy.link_timeout = 12us;
    propagation_policy.enum_timeout = 14us;
    propagation_policy.traffic_timeout = 15us;
    propagation_policy.ep_bars[0].initial_base = 64'd33554432;
    propagation_policy.enum_cfg.pref_mem_base_addr =
      64'h0000_0002_0000_0000;
    propagation_policy.enum_cfg.pref_mem_limit_addr =
      64'h0000_0002_0fff_ffff;
    propagation_policy.enum_cfg.pref_mem_window_stride =
      64'h0000_0000_2000_0000;
    propagation_policy.enum_cfg.bus_number = 8'h20;
    propagation_policy.enum_cfg.device_number = 5'h03;
    override_cfg = pcie_svt_link_override_cfg::type_id::create(
      "combined_override");
    override_cfg.link_id = "RC0_EP0";
    override_cfg.has_width = 1'b1;
    override_cfg.link_width = 4;
    override_cfg.has_gen = 1'b1;
    override_cfg.max_gen = 4;
    override_cfg.has_fast_link_training = 1'b1;
    override_cfg.fast_link_training = 1'b1;
    override_cfg.has_link_timeout = 1'b1;
    override_cfg.link_timeout = 13us;
    propagation_policy.link_overrides.push_back(override_cfg);
    adapter.translate(topology, propagation_policy, ports, errors);
    require(errors.size() == 0, "legal combined override was rejected");
    require(ports.size() == 2,
            "legal combined override changed the descriptor count");
    if (ports.size() == 2) begin
      require(ports[0].link_width == 4 && ports[0].max_gen == 4 &&
              ports[0].fast_link_training,
              "combined override did not propagate to RC0_EP0");
      require(ports[1].link_width == 8 && ports[1].max_gen == 5 &&
              !ports[1].fast_link_training,
              "policy defaults did not remain on RC1_EP1");
      require(ports[0].transport == PCIE_SVT_TRANSPORT_SERIAL &&
              ports[1].transport == PCIE_SVT_TRANSPORT_SERIAL,
              "Serial transport did not propagate");
      require(ports[0].cfg_timeout == 11us &&
              ports[0].link_timeout == 13us &&
              ports[0].enum_timeout == 14us &&
              ports[0].traffic_timeout == 15us,
              "override descriptor timeouts are wrong");
      require(ports[1].cfg_timeout == 11us &&
              ports[1].link_timeout == 12us &&
              ports[1].enum_timeout == 14us &&
              ports[1].traffic_timeout == 15us,
              "default descriptor timeouts are wrong");
      require(ports[0].enum_cfg != null && ports[1].enum_cfg != null,
              "enumeration configuration was not copied to descriptors");
      if ((ports[0].enum_cfg != null) && (ports[1].enum_cfg != null)) begin
        require(ports[0].enum_cfg != propagation_policy.enum_cfg &&
                ports[1].enum_cfg != propagation_policy.enum_cfg &&
                ports[0].enum_cfg != ports[1].enum_cfg,
                "descriptor enumeration configurations alias policy or peer");
        require(ports[0].enum_cfg.pref_mem_base_addr ==
                  64'h0000_0002_0000_0000 &&
                ports[0].enum_cfg.pref_mem_limit_addr ==
                  64'h0000_0002_0fff_ffff &&
                ports[0].enum_cfg.pref_mem_window_stride ==
                  64'h0000_0000_2000_0000,
                "enumeration memory window override did not propagate");
        require(ports[0].enum_cfg.bus_number == 8'h20 &&
                ports[0].enum_cfg.device_number == 5'h03,
                "enumeration BDF override did not propagate");
      end
      require(ports[0].ep_bars[0] != propagation_policy.ep_bars[0] &&
              ports[1].ep_bars[0] != propagation_policy.ep_bars[0] &&
              ports[0].ep_bars[0] != ports[1].ep_bars[0],
              "translated BAR handles alias policy or another descriptor");
      propagation_policy.ep_bars[0].initial_base = 0;
      ports[0].ep_bars[0].aperture = 64'd4096;
      require(ports[0].ep_bars[0].initial_base == 64'd33554432,
              "descriptor BAR payload aliases policy BAR payload");
      require(ports[1].ep_bars[0].aperture == 64'd33554432,
              "descriptor BAR payload aliases another descriptor");
    end

    $cast(disabled_policy, policy.clone());
    override_cfg = pcie_svt_link_override_cfg::type_id::create(
      "disable_rc0_ep0");
    override_cfg.link_id = "RC0_EP0";
    override_cfg.has_enable = 1'b1;
    override_cfg.enabled = 1'b0;
    disabled_policy.link_overrides.push_back(override_cfg);
    adapter.translate(topology, disabled_policy, ports, errors);
    require(errors.size() == 0, "enable-only disabled link was rejected");
    require(ports.size() == 1,
            "disabled EP_2X8 link did not leave exactly one descriptor");
    if (ports.size() == 1) begin
      require(ports[0].link_id == "RC1_EP1",
              "disabled EP_2X8 link left the wrong descriptor");
      require(ports[0].slot_index == 1,
              "disabled EP_2X8 link compacted the HDL slot");
      require(ports[0].vif_key == "primary_vif_1",
              "disabled EP_2X8 link compacted the VIF key");
      require(ports[0].root_hierarchy == 1,
              "disabled EP_2X8 link compacted the root hierarchy");
    end

    disabled_link_topology = pcie_topology_builder::build_ep_x16(4);
    disabled_link = pcie_topology_link_cfg::type_id::create(
      "disabled_duplicate");
    disabled_link.copy(disabled_link_topology.links[0]);
    disabled_link.link_id = "A_DISABLED_RC0_EP0";
    disabled_link.enabled = 1'b0;
    disabled_link_topology.links.push_back(disabled_link);
    disabled_policy = pcie_svt_topology_policy_cfg::type_id::create(
      "physical_disabled_policy");
    disabled_policy.init_defaults();
    disabled_policy.dut_node_ids.push_back("EP0");
    adapter.translate(disabled_link_topology, disabled_policy, ports, errors);
    require(errors.size() == 0,
            "physical disabled link without override was rejected");
    require(ports.size() == 1,
            "physical disabled link without override was not omitted");
    if (ports.size() == 1) begin
      require(ports[0].link_id == "RC0_EP0" &&
              ports[0].slot_index == 1 &&
              ports[0].vif_key == "primary_vif_1" &&
              ports[0].root_hierarchy == 1,
              "physical disabled link compacted sorted physical positions");
    end

    override_cfg = pcie_svt_link_override_cfg::type_id::create(
      "resurrect_disabled_link");
    override_cfg.link_id = "A_DISABLED_RC0_EP0";
    override_cfg.has_enable = 1'b1;
    override_cfg.enabled = 1'b1;
    disabled_policy.link_overrides.push_back(override_cfg);
    check_error("physical disabled resurrection", adapter,
                disabled_link_topology, disabled_policy,
                "override references disabled link");

    invalid_policy = pcie_svt_topology_policy_cfg::type_id::create(
      "physical_disabled_gen_policy");
    invalid_policy.init_defaults();
    invalid_policy.dut_node_ids.push_back("EP0");
    override_cfg = pcie_svt_link_override_cfg::type_id::create(
      "override_disabled_link_gen");
    override_cfg.link_id = "A_DISABLED_RC0_EP0";
    override_cfg.has_gen = 1'b1;
    override_cfg.max_gen = 4;
    invalid_policy.link_overrides.push_back(override_cfg);
    check_error("physical disabled non-enable override", adapter,
                disabled_link_topology, invalid_policy,
                "override references disabled link");

    invalid_policy = pcie_svt_topology_policy_cfg::type_id::create(
      "physical_unknown_policy");
    invalid_policy.init_defaults();
    invalid_policy.dut_node_ids.push_back("EP0");
    invalid_topology = pcie_topology_builder::build_ep_x16(4);
    invalid_topology.links[0].link_width = 'x;
    check_error("unknown physical width", adapter, invalid_topology,
                invalid_policy, "has unsupported width x0");

    invalid_topology = pcie_topology_builder::build_ep_x16(4);
    invalid_topology.links[0].max_gen = 'x;
    check_error("unknown physical max_gen", adapter, invalid_topology,
                invalid_policy, "has unsupported max_gen 0");

    check_error("null topology", adapter, null, policy,
                "topology and policy must both be non-null");
    check_error("null policy", adapter, topology, null,
                "topology and policy must both be non-null");

    invalid_policy = pcie_svt_topology_policy_cfg::type_id::create(
      "no_dut_policy");
    invalid_policy.init_defaults();
    check_error("no DUT nodes", adapter,
                pcie_topology_builder::build_ep_x16(4), invalid_policy,
                "at least one DUT node is required");

    invalid_policy = pcie_svt_topology_policy_cfg::type_id::create(
      "both_dut_policy");
    invalid_policy.init_defaults();
    invalid_policy.dut_node_ids.push_back("RC0");
    invalid_policy.dut_node_ids.push_back("EP0");
    check_error("both link ends DUT-owned", adapter,
                pcie_topology_builder::build_ep_x16(4), invalid_policy,
                "exactly one endpoint must be DUT-owned");

    invalid_policy = pcie_svt_topology_policy_cfg::type_id::create(
      "missing_dut_policy");
    invalid_policy.init_defaults();
    invalid_policy.dut_node_ids.push_back("EP0");
    invalid_policy.dut_node_ids.push_back("MISSING");
    check_error("missing DUT", adapter,
                pcie_topology_builder::build_ep_x16(4), invalid_policy,
                "DUT node 'MISSING' is absent");

    invalid_policy = pcie_svt_topology_policy_cfg::type_id::create(
      "pipe_policy");
    invalid_policy.init_defaults();
    invalid_policy.dut_node_ids.push_back("EP0");
    invalid_policy.transport = PCIE_SVT_TRANSPORT_PIPE;
    check_error("PIPE transport", adapter,
                pcie_topology_builder::build_ep_x16(4), invalid_policy,
                "PIPE transport is not implemented");

    $cast(invalid_policy, policy.clone());
    override_cfg = pcie_svt_link_override_cfg::type_id::create(
      "oversized_width_override");
    override_cfg.link_id = "RC0_EP0";
    override_cfg.has_width = 1'b1;
    override_cfg.link_width = 16;
    invalid_policy.link_overrides.push_back(override_cfg);
    check_error("active width exceeds physical", adapter, topology,
                invalid_policy,
                "active width x16 exceeds physical width x8");

    $cast(invalid_policy, policy.clone());
    override_cfg = pcie_svt_link_override_cfg::type_id::create(
      "unknown_link_override");
    override_cfg.link_id = "UNKNOWN";
    invalid_policy.link_overrides.push_back(override_cfg);
    check_error("unknown override", adapter, topology, invalid_policy,
                "override references unknown link");

    $cast(invalid_policy, policy.clone());
    override_cfg = pcie_svt_link_override_cfg::type_id::create(
      "disabled_active_override");
    override_cfg.link_id = "RC0_EP0";
    override_cfg.has_enable = 1'b1;
    override_cfg.enabled = 1'b0;
    override_cfg.has_gen = 1'b1;
    override_cfg.max_gen = 5;
    invalid_policy.link_overrides.push_back(override_cfg);
    check_error("disabled link active override", adapter, topology,
                invalid_policy,
                "disabled link also carries an active override");

    $cast(invalid_policy, policy.clone());
    invalid_policy.hdl_slot_by_link["RC1_EP1"] = 0;
    check_error("duplicate effective HDL slot", adapter, topology,
                invalid_policy, "effective HDL slot 0 is used by both");

    $cast(invalid_policy, policy.clone());
    invalid_policy.hdl_slot_by_link["UNKNOWN"] = 7;
    check_error("unknown HDL-slot-map link", adapter, topology,
                invalid_policy,
                "HDL-slot-map entry references unknown topology link");

    $cast(invalid_policy, policy.clone());
    for (int i = 0; i < 2; i++) begin
      override_cfg = pcie_svt_link_override_cfg::type_id::create(
        $sformatf("disable_all_%0d", i));
      override_cfg.link_id = $sformatf("RC%0d_EP%0d", i, i);
      override_cfg.has_enable = 1'b1;
      override_cfg.enabled = 1'b0;
      invalid_policy.link_overrides.push_back(override_cfg);
    end
    check_error("empty descriptor result", adapter, topology,
                invalid_policy, "topology produced no SVT port descriptors");

    phase.drop_objection(this);
  endtask
endclass
