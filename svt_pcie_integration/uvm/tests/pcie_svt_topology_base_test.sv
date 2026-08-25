import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_svt_topology_pkg::*;
import svt_uvm_pkg::*;
import svt_pcie_uvm_pkg::*;
`include "uvm_macros.svh"

class pcie_svt_topology_expected_fatal_catcher extends uvm_report_catcher;
  string expected_id;
  string expected_fragment;
  int unsigned matched_count;

  `uvm_object_utils(pcie_svt_topology_expected_fatal_catcher)

  function new(
      string name = "pcie_svt_topology_expected_fatal_catcher");
    super.new(name);
  endfunction

  function void configure(string id, string fragment);
    expected_id = id;
    expected_fragment = fragment;
    matched_count = 0;
  endfunction

  protected function bit message_contains(string message, string fragment);
    if ((fragment.len() == 0) || (fragment.len() > message.len()))
      return 1'b0;
    for (int i = 0; i <= message.len() - fragment.len(); i++) begin
      if (message.substr(i, i + fragment.len() - 1) == fragment)
        return 1'b1;
    end
    return 1'b0;
  endfunction

  virtual function action_e catch();
    if ((get_severity() == UVM_FATAL) &&
        (get_id() == expected_id) &&
        message_contains(get_message(), expected_fragment)) begin
      matched_count++;
      return CAUGHT;
    end
    return THROW;
  endfunction
endclass

class pcie_svt_topology_base_test extends uvm_test;
  `uvm_component_utils(pcie_svt_topology_base_test)

  string profile_name;
  int unsigned max_gen;
  bit fast_link_training;
  pcie_svt_transport_e transport;
  pcie_svt_run_mode_e run_mode;
  pcie_svt_link_override_cfg overrides[$];
  pcie_topology_cfg topology_cfg;
  pcie_svt_topology_policy_cfg policy_cfg;
  pcie_svt_topology_env env;
  pcie_svt_topology_virtual_sequencer scratch_register_vseqr;
  pcie_svt_topology_virtual_sequencer scratch_wrong_seqr_vseqr;
  pcie_svt_topology_virtual_sequencer scratch_duplicate_seqr_vseqr;
  pcie_svt_topology_virtual_sequencer scratch_host_window_vseqr;

  function new(string name = "pcie_svt_topology_base_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    pcie_svt_cli_parser parser;
    string errors[$];

    super.build_phase(phase);
    scratch_register_vseqr =
      pcie_svt_topology_virtual_sequencer::type_id::create(
        "scratch_register_vseqr", this);
    scratch_wrong_seqr_vseqr =
      pcie_svt_topology_virtual_sequencer::type_id::create(
        "scratch_wrong_seqr_vseqr", this);
    scratch_duplicate_seqr_vseqr =
      pcie_svt_topology_virtual_sequencer::type_id::create(
        "scratch_duplicate_seqr_vseqr", this);
    scratch_host_window_vseqr =
      pcie_svt_topology_virtual_sequencer::type_id::create(
        "scratch_host_window_vseqr", this);
    parser = pcie_svt_cli_parser::type_id::create("parser");
    parser.parse_command_line(profile_name, max_gen, fast_link_training,
                              transport, run_mode, overrides, errors);
    if (errors.size() != 0) begin
      `uvm_fatal("SVT_ENV_CLI", pcie_svt_join_errors(errors))
      return;
    end

    if (profile_name != pcie_svt_compiled_profile_name()) begin
      `uvm_fatal("SVT_ENV_PROFILE", $sformatf(
        "runtime profile=%s does not match compiled profile=%s",
        profile_name, pcie_svt_compiled_profile_name()))
      return;
    end

    pcie_svt_profile_factory::build(profile_name, max_gen, topology_cfg,
                                    policy_cfg, errors);
    if (errors.size() != 0) begin
      `uvm_fatal("SVT_ENV_PROFILE", pcie_svt_join_errors(errors))
      return;
    end
    policy_cfg.default_fast_link_training = fast_link_training;
    policy_cfg.transport = transport;
    pcie_svt_profile_factory::apply_overrides(
      topology_cfg, overrides, policy_cfg, errors);
    if (errors.size() != 0) begin
      `uvm_fatal("SVT_ENV_OVERRIDE", pcie_svt_join_errors(errors))
      return;
    end

    uvm_config_db#(pcie_topology_cfg)::set(
      this, "env", "topology_cfg", topology_cfg);
    uvm_config_db#(pcie_svt_topology_policy_cfg)::set(
      this, "env", "policy_cfg", policy_cfg);
    env = pcie_svt_topology_env::type_id::create("env", this);
  endfunction

  protected function bit string_contains(string value, string fragment);
    if ((fragment.len() == 0) || (fragment.len() > value.len()))
      return 1'b0;
    for (int i = 0; i <= value.len() - fragment.len(); i++) begin
      if (value.substr(i, i + fragment.len() - 1) == fragment)
        return 1'b1;
    end
    return 1'b0;
  endfunction

  protected function void topology_check(bit condition, string message);
    if (!condition)
      `uvm_error("SVT_ENV_CONTRACT", message)
  endfunction

  protected function pcie_svt_port_descriptor make_scratch_descriptor(
      pcie_svt_port_descriptor source,
      string object_name,
      string link_id,
      pcie_svt_role_e role,
      int unsigned root_hierarchy);
    pcie_svt_port_descriptor descriptor;
    descriptor = pcie_svt_port_descriptor::type_id::create(object_name);
    descriptor.copy(source);
    descriptor.link_id = link_id;
    descriptor.role = role;
    descriptor.root_hierarchy = root_hierarchy;
    return descriptor;
  endfunction

  protected function void arm_expected_fatal(
      pcie_svt_topology_expected_fatal_catcher catcher,
      string expected_id,
      string expected_fragment);
    catcher.configure(expected_id, expected_fragment);
    uvm_report_cb::add(null, catcher);
  endfunction

  protected function void finish_expected_fatal(
      pcie_svt_topology_expected_fatal_catcher catcher,
      string label);
    uvm_report_cb::delete(null, catcher);
    topology_check(catcher.matched_count == 1, $sformatf(
      "%s expected one exact fatal id=%s fragment='%s', observed %0d",
      label, catcher.expected_id, catcher.expected_fragment,
      catcher.matched_count));
  endfunction

  protected function void check_registration_absent(
      pcie_svt_topology_virtual_sequencer registry,
      string link_id,
      string label);
    topology_check(!registry.descriptor_by_link.exists(link_id),
                   {label, ": descriptor was partially registered"});
    topology_check(!registry.cfg_by_link.exists(link_id),
                   {label, ": configuration was partially registered"});
    topology_check(!registry.status_by_link.exists(link_id),
                   {label, ": status was partially registered"});
    topology_check(!registry.agent_by_link.exists(link_id),
                   {label, ": agent was partially registered"});
    topology_check(!registry.cfg_state.exists(link_id),
                   {label, ": CFG state was partially registered"});
    topology_check(!registry.link_state.exists(link_id),
                   {label, ": LINK state was partially registered"});
    topology_check(!registry.enum_state.exists(link_id),
                   {label, ": ENUM state was partially registered"});
    topology_check(!registry.traffic_state.exists(link_id),
                   {label, ": TRAFFIC state was partially registered"});
    topology_check(!registry.host_memory_window_valid.exists(link_id),
                   {label, ": host-memory state was partially registered"});
  endfunction

  protected function void check_window_state(
      pcie_svt_topology_virtual_sequencer registry,
      string link_id,
      bit expected_valid,
      bit [63:0] expected_base,
      bit [63:0] expected_limit,
      string label);
    bit valid;
    bit [63:0] base_address;
    bit [63:0] limit_address;
    base_address = '1;
    limit_address = '1;
    valid = registry.get_host_memory_window(
      link_id, base_address, limit_address);
    topology_check(valid == expected_valid,
                   {label, ": valid state changed unexpectedly"});
    topology_check(base_address == expected_base, $sformatf(
      "%s base expected=0x%016h actual=0x%016h",
      label, expected_base, base_address));
    topology_check(limit_address == expected_limit, $sformatf(
      "%s limit expected=0x%016h actual=0x%016h",
      label, expected_limit, limit_address));
  endfunction

  protected function void check_direct_agent_children();
    uvm_component children[$];
    bit agent_seen[];
    int unsigned direct_agent_count;

    agent_seen = new[env.port_agent.size()];
    env.get_children(children);
    foreach (children[i]) begin
      svt_pcie_device_agent direct_agent;
      if ($cast(direct_agent, children[i])) begin
        bit matched;
        direct_agent_count++;
        matched = 1'b0;
        foreach (env.port_agent[j]) begin
          if (direct_agent == env.port_agent[j]) begin
            topology_check(!agent_seen[j], $sformatf(
              "direct agent handle port_%0d appears more than once", j));
            agent_seen[j] = 1'b1;
            matched = 1'b1;
          end
        end
        topology_check(matched, $sformatf(
          "unexpected direct device agent child '%s'",
          direct_agent.get_full_name()));
      end
    end
    topology_check(direct_agent_count == env.descriptors.size(), $sformatf(
      "direct device-agent count expected=%0d actual=%0d",
      env.descriptors.size(), direct_agent_count));
    foreach (agent_seen[i]) begin
      topology_check(agent_seen[i], $sformatf(
        "env.port_agent[%0d] is not a direct child", i));
    end
  endfunction

  protected function void check_register_handle_ownership();
    pcie_svt_port_descriptor descriptor_a;
    pcie_svt_port_descriptor descriptor_b;
    pcie_svt_port_descriptor descriptor_c;
    pcie_svt_port_descriptor descriptor_d;
    svt_pcie_device_configuration synthetic_cfg_c;
    svt_pcie_device_configuration synthetic_cfg_d;
    svt_pcie_device_status synthetic_status_d;
    pcie_svt_topology_expected_fatal_catcher catcher;

    if (env.port_count() < 2)
      return;
    descriptor_a = make_scratch_descriptor(
      env.descriptors[0], "ownership_descriptor_a", "OWN_REG_A",
      PCIE_SVT_ROLE_RC, 0);
    descriptor_b = make_scratch_descriptor(
      env.descriptors[1], "ownership_descriptor_b", "OWN_DUP_CFG",
      PCIE_SVT_ROLE_RC, 1);
    descriptor_c = make_scratch_descriptor(
      env.descriptors[1], "ownership_descriptor_c", "OWN_DUP_STATUS",
      PCIE_SVT_ROLE_RC, 2);
    descriptor_d = make_scratch_descriptor(
      env.descriptors[1], "ownership_descriptor_d", "OWN_DUP_AGENT",
      PCIE_SVT_ROLE_RC, 3);
    synthetic_cfg_c = svt_pcie_device_configuration::type_id::create(
      "ownership_synthetic_cfg_c");
    synthetic_cfg_d = svt_pcie_device_configuration::type_id::create(
      "ownership_synthetic_cfg_d");
    synthetic_status_d = svt_pcie_device_status::type_id::create(
      "ownership_synthetic_status_d");
    catcher = pcie_svt_topology_expected_fatal_catcher::type_id::create(
      "register_ownership_catcher");

    scratch_register_vseqr.register_port(
      descriptor_a, env.port_cfg[0], env.port_status[0], env.port_agent[0]);

    arm_expected_fatal(catcher, "SVT_VSEQR_REGISTER",
      "configuration handle is already registered to link 'OWN_REG_A'");
    scratch_register_vseqr.register_port(
      descriptor_b, env.port_cfg[0], env.port_status[1], env.port_agent[1]);
    finish_expected_fatal(catcher, "duplicate configuration ownership");
    check_registration_absent(
      scratch_register_vseqr, descriptor_b.link_id,
      "duplicate configuration ownership");

    arm_expected_fatal(catcher, "SVT_VSEQR_REGISTER",
      "status handle is already registered to link 'OWN_REG_A'");
    scratch_register_vseqr.register_port(
      descriptor_c, synthetic_cfg_c, env.port_status[0], env.port_agent[1]);
    finish_expected_fatal(catcher, "duplicate status ownership");
    check_registration_absent(
      scratch_register_vseqr, descriptor_c.link_id,
      "duplicate status ownership");

    arm_expected_fatal(catcher, "SVT_VSEQR_REGISTER",
      "agent handle is already registered to link 'OWN_REG_A'");
    scratch_register_vseqr.register_port(
      descriptor_d, synthetic_cfg_d, synthetic_status_d, env.port_agent[0]);
    finish_expected_fatal(catcher, "duplicate agent ownership");
    check_registration_absent(
      scratch_register_vseqr, descriptor_d.link_id,
      "duplicate agent ownership");
    topology_check(scratch_register_vseqr.descriptor_by_link.num() == 1,
      "rejected handle registrations changed registry size");
  endfunction

  protected function void check_wrong_link_sequencer();
    pcie_svt_port_descriptor descriptor_a;
    pcie_svt_port_descriptor descriptor_b;
    pcie_svt_topology_expected_fatal_catcher catcher;

    if (env.port_count() < 2)
      return;
    descriptor_a = make_scratch_descriptor(
      env.descriptors[0], "wrong_seqr_descriptor_a", "OWN_WRONG_A",
      PCIE_SVT_ROLE_RC, 0);
    descriptor_b = make_scratch_descriptor(
      env.descriptors[1], "wrong_seqr_descriptor_b", "OWN_WRONG_B",
      PCIE_SVT_ROLE_RC, 1);
    scratch_wrong_seqr_vseqr.register_port(
      descriptor_a, env.port_cfg[0], env.port_status[0], env.port_agent[0]);
    scratch_wrong_seqr_vseqr.register_port(
      descriptor_b, env.port_cfg[1], env.port_status[1], env.port_agent[1]);
    catcher = pcie_svt_topology_expected_fatal_catcher::type_id::create(
      "wrong_link_seqr_catcher");
    arm_expected_fatal(catcher, "SVT_VSEQR_CONNECT",
      "link 'OWN_WRONG_A' sequencer does not belong to its registered agent");
    scratch_wrong_seqr_vseqr.connect_port(
      descriptor_a.link_id, env.port_agent[1].virt_seqr);
    finish_expected_fatal(catcher, "wrong-link sequencer ownership");
    topology_check(
      !scratch_wrong_seqr_vseqr.seqr_by_link.exists(descriptor_a.link_id),
      "wrong-link sequencer was partially connected");
    topology_check(scratch_wrong_seqr_vseqr.seqr_by_link.num() == 0,
      "wrong-link rejection changed sequencer registry size");
  endfunction

  protected function void check_duplicate_sequencer_ownership();
    pcie_svt_port_descriptor descriptor_a;
    pcie_svt_port_descriptor descriptor_b;
    pcie_svt_topology_expected_fatal_catcher catcher;

    if (env.port_count() < 2)
      return;
    descriptor_a = make_scratch_descriptor(
      env.descriptors[0], "duplicate_seqr_descriptor_a", "OWN_DUP_SEQR_A",
      PCIE_SVT_ROLE_RC, 0);
    descriptor_b = make_scratch_descriptor(
      env.descriptors[1], "duplicate_seqr_descriptor_b", "OWN_DUP_SEQR_B",
      PCIE_SVT_ROLE_RC, 1);
    scratch_duplicate_seqr_vseqr.register_port(
      descriptor_a, env.port_cfg[0], env.port_status[0], env.port_agent[0]);
    scratch_duplicate_seqr_vseqr.register_port(
      descriptor_b, env.port_cfg[1], env.port_status[1], env.port_agent[1]);
    scratch_duplicate_seqr_vseqr.connect_port(
      descriptor_a.link_id, env.port_agent[0].virt_seqr);
    catcher = pcie_svt_topology_expected_fatal_catcher::type_id::create(
      "duplicate_seqr_catcher");
    arm_expected_fatal(catcher, "SVT_VSEQR_CONNECT",
      "sequencer handle is already connected to link 'OWN_DUP_SEQR_A'");
    scratch_duplicate_seqr_vseqr.connect_port(
      descriptor_b.link_id, env.port_agent[0].virt_seqr);
    finish_expected_fatal(catcher, "duplicate sequencer ownership");
    topology_check(
      !scratch_duplicate_seqr_vseqr.seqr_by_link.exists(descriptor_b.link_id),
      "duplicate sequencer was partially connected");
    topology_check(
      scratch_duplicate_seqr_vseqr.get_port_seqr(descriptor_a.link_id) ==
        env.port_agent[0].virt_seqr,
      "duplicate sequencer rejection changed the existing owner");
    topology_check(scratch_duplicate_seqr_vseqr.seqr_by_link.num() == 1,
      "duplicate sequencer rejection changed registry size");
  endfunction

  protected function void check_host_memory_window_contract();
    pcie_svt_port_descriptor descriptor_a;
    pcie_svt_port_descriptor descriptor_b;
    pcie_svt_port_descriptor descriptor_c;
    pcie_svt_port_descriptor descriptor_d;
    pcie_svt_port_descriptor descriptor_e;

    if (env.port_count() < 5)
      return;
    descriptor_a = make_scratch_descriptor(
      env.descriptors[0], "host_descriptor_a", "HOST_A",
      PCIE_SVT_ROLE_RC, 0);
    descriptor_b = make_scratch_descriptor(
      env.descriptors[1], "host_descriptor_b", "HOST_B",
      PCIE_SVT_ROLE_RC, 0);
    descriptor_c = make_scratch_descriptor(
      env.descriptors[2], "host_descriptor_c", "HOST_C",
      PCIE_SVT_ROLE_RC, 1);
    descriptor_d = make_scratch_descriptor(
      env.descriptors[3], "host_descriptor_d", "HOST_EP",
      PCIE_SVT_ROLE_EP, 1);
    descriptor_e = make_scratch_descriptor(
      env.descriptors[4], "host_descriptor_e", "HOST_POINT",
      PCIE_SVT_ROLE_RC, 2);
    scratch_host_window_vseqr.register_port(
      descriptor_a, env.port_cfg[0], env.port_status[0], env.port_agent[0]);
    scratch_host_window_vseqr.register_port(
      descriptor_b, env.port_cfg[1], env.port_status[1], env.port_agent[1]);
    scratch_host_window_vseqr.register_port(
      descriptor_c, env.port_cfg[2], env.port_status[2], env.port_agent[2]);
    scratch_host_window_vseqr.register_port(
      descriptor_d, env.port_cfg[3], env.port_status[3], env.port_agent[3]);
    scratch_host_window_vseqr.register_port(
      descriptor_e, env.port_cfg[4], env.port_status[4], env.port_agent[4]);

    topology_check(!scratch_host_window_vseqr.reserve_host_memory_window(
      "HOST_UNKNOWN", 64'h1000, 64'h1fff),
      "unknown link host-memory reservation succeeded");
    topology_check(string_contains(
      scratch_host_window_vseqr.last_registry_error, "is not registered"),
      "unknown link rejection omitted its reason");
    check_window_state(scratch_host_window_vseqr, "HOST_UNKNOWN", 1'b0,
                       64'h0, 64'h0, "unknown link rejection");

    topology_check(!scratch_host_window_vseqr.reserve_host_memory_window(
      descriptor_d.link_id, 64'h4000, 64'h4fff),
      "EP host-memory reservation succeeded");
    topology_check(string_contains(
      scratch_host_window_vseqr.last_registry_error, "is not an RC"),
      "EP rejection omitted its reason");
    check_window_state(scratch_host_window_vseqr, descriptor_d.link_id, 1'b0,
                       64'h0, 64'h0, "EP rejection");

    topology_check(!scratch_host_window_vseqr.reserve_host_memory_window(
      descriptor_b.link_id, 64'h3000, 64'h2fff),
      "descending host-memory range succeeded");
    topology_check(string_contains(
      scratch_host_window_vseqr.last_registry_error, "base exceeds limit"),
      "descending-range rejection omitted its reason");
    check_window_state(scratch_host_window_vseqr, descriptor_b.link_id, 1'b0,
                       64'h0, 64'h0, "descending-range rejection");

    topology_check(scratch_host_window_vseqr.reserve_host_memory_window(
      descriptor_a.link_id, 64'h1000, 64'h1fff),
      "valid host-memory reservation failed");
    check_window_state(scratch_host_window_vseqr, descriptor_a.link_id, 1'b1,
                       64'h1000, 64'h1fff, "valid reservation");

    topology_check(!scratch_host_window_vseqr.reserve_host_memory_window(
      descriptor_b.link_id, 64'h1fff, 64'h2fff),
      "same-root inclusive endpoint overlap succeeded");
    topology_check(string_contains(
      scratch_host_window_vseqr.last_registry_error, "overlaps link 'HOST_A'"),
      "same-root overlap rejection omitted its owner");
    check_window_state(scratch_host_window_vseqr, descriptor_b.link_id, 1'b0,
                       64'h0, 64'h0, "same-root overlap rejection");

    topology_check(scratch_host_window_vseqr.reserve_host_memory_window(
      descriptor_b.link_id, 64'h2000, 64'h2fff),
      "same-root adjacent host-memory reservation failed");
    check_window_state(scratch_host_window_vseqr, descriptor_b.link_id, 1'b1,
                       64'h2000, 64'h2fff, "same-root adjacent reservation");

    topology_check(scratch_host_window_vseqr.reserve_host_memory_window(
      descriptor_c.link_id, 64'h1800, 64'h1900),
      "different-root overlapping host-memory reservation failed");
    check_window_state(scratch_host_window_vseqr, descriptor_c.link_id, 1'b1,
                       64'h1800, 64'h1900,
                       "different-root overlapping reservation");

    topology_check(scratch_host_window_vseqr.reserve_host_memory_window(
      descriptor_e.link_id, 64'h4000, 64'h4000),
      "one-address host-memory reservation failed");
    check_window_state(scratch_host_window_vseqr, descriptor_e.link_id, 1'b1,
                       64'h4000, 64'h4000, "one-address reservation");

    topology_check(!scratch_host_window_vseqr.reserve_host_memory_window(
      descriptor_a.link_id, 64'h5000, 64'h5fff),
      "repeated host-memory reservation succeeded");
    topology_check(string_contains(
      scratch_host_window_vseqr.last_registry_error,
      "already has a host-memory window"),
      "repeated reservation rejection omitted its reason");
    check_window_state(scratch_host_window_vseqr, descriptor_a.link_id, 1'b1,
                       64'h1000, 64'h1fff,
                       "repeated reservation rejection");
  endfunction

  protected function void reject_legacy_port_components(
      uvm_component component);
    uvm_component children[$];
    component.get_children(children);
    foreach (children[i]) begin
      for (int legacy_slot = 5; legacy_slot <= 9; legacy_slot++) begin
        if (string_contains(children[i].get_full_name(),
                            $sformatf("port[%0d]", legacy_slot))) begin
          `uvm_fatal("SVT_ENV_LEGACY", $sformatf(
            "legacy fixed-port component remains: %s",
            children[i].get_full_name()))
          return;
        end
      end
      reject_legacy_port_components(children[i]);
    end
  endfunction

  protected function int compiled_slot_count();
    case (pcie_svt_compiled_profile_name())
      "EP_X16": return 1;
      "EP_2X8": return 2;
      "SWITCH_1X16_4X4": return 5;
      default: return 0;
    endcase
  endfunction

  protected function int slot_for_link(string link_id);
    pcie_topology_link_cfg sorted_links[$];
    foreach (topology_cfg.links[i])
      sorted_links.push_back(topology_cfg.links[i]);
    for (int i = 0; i < sorted_links.size(); i++) begin
      for (int j = i + 1; j < sorted_links.size(); j++) begin
        if ((sorted_links[j] != null) &&
            ((sorted_links[i] == null) ||
             (sorted_links[j].link_id < sorted_links[i].link_id))) begin
          pcie_topology_link_cfg temporary;
          temporary = sorted_links[i];
          sorted_links[i] = sorted_links[j];
          sorted_links[j] = temporary;
        end
      end
    end
    foreach (sorted_links[i]) begin
      if ((sorted_links[i] != null) &&
          (sorted_links[i].link_id == link_id))
        return i;
    end
    return -1;
  endfunction

  virtual function void end_of_elaboration_phase(uvm_phase phase);
    pcie_svt_topology_adapter count_adapter;
    pcie_svt_port_descriptor expected_ports[$];
    pcie_svt_port_descriptor resolved_descriptor;
    svt_pcie_device_agent expected_root;
    svt_pcie_device_agent expected_endpoint;
    svt_pcie_device_configuration expected_root_cfg;
    svt_pcie_device_configuration expected_endpoint_cfg;
    svt_pcie_device_status expected_root_status;
    svt_pcie_device_status expected_endpoint_status;
    string adapter_errors[$];
    string expected_rc_links[$];
    string expected_ep_links[$];
    string actual_rc_links[$];
    string actual_ep_links[$];
    bit resolved_link[string];
    bit [63:0] unreserved_base;
    bit [63:0] unreserved_limit;

    super.end_of_elaboration_phase(phase);
    count_adapter = pcie_svt_topology_adapter::type_id::create(
      "count_adapter");
    count_adapter.translate(topology_cfg, policy_cfg,
                            expected_ports, adapter_errors);
    if (adapter_errors.size() != 0) begin
      `uvm_fatal("SVT_ENV_COUNT", pcie_svt_join_errors(adapter_errors))
      return;
    end
    if ((env == null) || (env.port_count() != expected_ports.size())) begin
      `uvm_fatal("SVT_ENV_COUNT", $sformatf(
        "profile=%s expected=%0d actual=%0d", profile_name,
        expected_ports.size(), (env == null) ? 0 : env.port_count()))
      return;
    end
    if (env.vseqr == null) begin
      `uvm_fatal("SVT_ENV_VSEQR", "topology virtual sequencer is null")
      return;
    end
    if (env.sys_virt_seqr == null) begin
      `uvm_fatal("SVT_ENV_VSEQR", "system virtual sequencer is null")
      return;
    end

    if (env.vseqr.get_port_descriptor("missing") != null)
      `uvm_fatal("SVT_ENV_LOOKUP", "missing descriptor lookup was non-null")
    if (env.vseqr.get_port_seqr("missing") != null)
      `uvm_fatal("SVT_ENV_LOOKUP", "missing sequencer lookup was non-null")
    if (env.vseqr.descriptor_by_link.num() != expected_ports.size()) begin
      `uvm_fatal("SVT_ENV_LOOKUP", $sformatf(
        "descriptor registry expected=%0d actual=%0d",
        expected_ports.size(), env.vseqr.descriptor_by_link.num()))
    end

    expected_root = null;
    expected_endpoint = null;
    expected_root_cfg = null;
    expected_endpoint_cfg = null;
    expected_root_status = null;
    expected_endpoint_status = null;
    foreach (expected_ports[i]) begin
      resolved_descriptor =
        env.vseqr.get_port_descriptor(expected_ports[i].link_id);
      if (resolved_descriptor == null) begin
        `uvm_fatal("SVT_ENV_LOOKUP", $sformatf(
          "descriptor '%s' did not resolve", expected_ports[i].link_id))
      end
      if (resolved_descriptor != env.descriptors[i]) begin
        `uvm_fatal("SVT_ENV_LOOKUP", $sformatf(
          "descriptor '%s' registry does not reference its sole env object",
          expected_ports[i].link_id))
      end
      if (resolved_link.exists(expected_ports[i].link_id)) begin
        `uvm_fatal("SVT_ENV_LOOKUP", $sformatf(
          "descriptor '%s' resolved more than once",
          expected_ports[i].link_id))
      end
      resolved_link[expected_ports[i].link_id] = 1'b1;
      if (env.vseqr.get_port_seqr(expected_ports[i].link_id) == null) begin
        `uvm_fatal("SVT_ENV_LOOKUP", $sformatf(
          "sequencer '%s' did not resolve", expected_ports[i].link_id))
      end
      if ((expected_root == null) &&
          (expected_ports[i].role == PCIE_SVT_ROLE_RC)) begin
        expected_root = env.port_agent[i];
        expected_root_cfg = env.port_cfg[i];
        expected_root_status = env.port_status[i];
      end
      if ((expected_endpoint == null) &&
          (expected_ports[i].role == PCIE_SVT_ROLE_EP)) begin
        expected_endpoint = env.port_agent[i];
        expected_endpoint_cfg = env.port_cfg[i];
        expected_endpoint_status = env.port_status[i];
      end
      if (expected_ports[i].role == PCIE_SVT_ROLE_RC)
        expected_rc_links.push_back(expected_ports[i].link_id);
      else
        expected_ep_links.push_back(expected_ports[i].link_id);
      if ((env.vseqr.cfg_state[expected_ports[i].link_id] !=
             PCIE_SVT_STAGE_NOT_RUN) ||
          (env.vseqr.link_state[expected_ports[i].link_id] !=
             PCIE_SVT_STAGE_NOT_RUN) ||
          (env.vseqr.enum_state[expected_ports[i].link_id] !=
             PCIE_SVT_STAGE_NOT_RUN) ||
          (env.vseqr.traffic_state[expected_ports[i].link_id] !=
             PCIE_SVT_STAGE_NOT_RUN)) begin
        `uvm_fatal("SVT_ENV_STAGE", $sformatf(
          "%s did not initialize every stage to NOT_RUN",
          expected_ports[i].link_id))
      end
    end
    env.vseqr.get_links_by_role(PCIE_SVT_ROLE_RC, actual_rc_links);
    env.vseqr.get_links_by_role(PCIE_SVT_ROLE_EP, actual_ep_links);
    if ((actual_rc_links.size() != expected_rc_links.size()) ||
        (actual_ep_links.size() != expected_ep_links.size()))
      `uvm_fatal("SVT_ENV_ROLE", "role lookup returned the wrong count")
    foreach (expected_rc_links[i]) begin
      if (actual_rc_links[i] != expected_rc_links[i])
        `uvm_fatal("SVT_ENV_ROLE", "RC lookup is not sorted and exact")
    end
    foreach (expected_ep_links[i]) begin
      if (actual_ep_links[i] != expected_ep_links[i])
        `uvm_fatal("SVT_ENV_ROLE", "EP lookup is not sorted and exact")
    end
    unreserved_base = '1;
    unreserved_limit = '1;
    if (env.vseqr.get_host_memory_window(
          "missing", unreserved_base, unreserved_limit) ||
        (unreserved_base != 0) || (unreserved_limit != 0)) begin
      `uvm_fatal("SVT_ENV_HOST_MEMORY",
        "unreserved host-memory lookup was not deterministic")
    end
    if (env.root != expected_root)
      `uvm_fatal("SVT_ENV_ALIAS", "root is not the first RC agent")
    if (env.endpoint != expected_endpoint)
      `uvm_fatal("SVT_ENV_ALIAS", "endpoint is not the first EP agent")
    if ((env.root_cfg != expected_root_cfg) ||
        (env.root_status != expected_root_status)) begin
      `uvm_fatal("SVT_ENV_ALIAS",
        "root cfg/status aliases do not match the first RC")
    end
    if ((env.endpoint_cfg != expected_endpoint_cfg) ||
        (env.endpoint_status != expected_endpoint_status)) begin
      `uvm_fatal("SVT_ENV_ALIAS",
        "endpoint cfg/status aliases do not match the first EP")
    end
    if (((expected_root == null) &&
         (env.sys_virt_seqr.root_virt_seqr != null)) ||
        ((expected_root != null) &&
         (env.sys_virt_seqr.root_virt_seqr != expected_root.virt_seqr))) begin
      `uvm_fatal("SVT_ENV_ALIAS",
        "system root sequencer alias has the wrong null/handle semantics")
    end
    if (((expected_endpoint == null) &&
         (env.sys_virt_seqr.endpoint_virt_seqr != null)) ||
        ((expected_endpoint != null) &&
         (env.sys_virt_seqr.endpoint_virt_seqr !=
            expected_endpoint.virt_seqr))) begin
      `uvm_fatal("SVT_ENV_ALIAS",
        "system endpoint sequencer alias has the wrong null/handle semantics")
    end

    check_direct_agent_children();
    reject_legacy_port_components(env);
    for (int slot = 0; slot < compiled_slot_count(); slot++) begin
      svt_pcie_vif compiled_vif;
      compiled_vif = null;
      if (!uvm_config_db#(svt_pcie_vif)::get(
            this, "", $sformatf("primary_vif_%0d", slot), compiled_vif) ||
          (compiled_vif == null)) begin
        `uvm_fatal("SVT_ENV_STATIC_SLOT", $sformatf(
          "compiled HDL slot %0d is not published", slot))
      end
    end
    foreach (overrides[i]) begin
      if ((overrides[i] != null) && overrides[i].has_enable &&
          !overrides[i].enabled) begin
        int disabled_slot;
        disabled_slot = slot_for_link(overrides[i].link_id);
        if ((disabled_slot < 0) ||
            (disabled_slot >= compiled_slot_count()))
          `uvm_fatal("SVT_ENV_DISABLED", "disabled link has no static slot")
        if (env.vseqr.get_port_descriptor(overrides[i].link_id) != null)
          `uvm_fatal("SVT_ENV_DISABLED", "disabled link has a descriptor")
        if (env.vseqr.agent_by_link.exists(overrides[i].link_id))
          `uvm_fatal("SVT_ENV_DISABLED", "disabled link has an agent")
        `uvm_info("PCIE_SVT_DISABLED_SLOT_IDLE", $sformatf(
          "link=%s slot=%0d published=1 agent=0",
          overrides[i].link_id, disabled_slot), UVM_NONE)
      end
    end

    check_register_handle_ownership();
    check_wrong_link_sequencer();
    check_duplicate_sequencer_ownership();
    check_host_memory_window_contract();

    `uvm_info("PCIE_SVT_ENV_READY", $sformatf(
      "profile=%s agents=%0d", profile_name, env.port_count()), UVM_NONE)
    env.vseqr.report_stage_table();
    uvm_top.print_topology();
  endfunction

  virtual task run_phase(uvm_phase phase);
    if (run_mode == PCIE_SVT_RUN_COMPILE) begin
      `uvm_info("PCIE_SVT_COMPILE_ONLY",
                "component construction complete; no sequence started",
                UVM_NONE)
    end
  endtask
endclass
