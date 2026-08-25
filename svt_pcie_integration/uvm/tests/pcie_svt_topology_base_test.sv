import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_svt_topology_pkg::*;
`include "uvm_macros.svh"

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

  function new(string name = "pcie_svt_topology_base_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    pcie_svt_cli_parser parser;
    string errors[$];

    super.build_phase(phase);
    parser = pcie_svt_cli_parser::type_id::create("parser");
    parser.parse_command_line(profile_name, max_gen, fast_link_training,
                              transport, run_mode, overrides, errors);
    if (errors.size() != 0)
      `uvm_fatal("SVT_ENV_CLI", pcie_svt_join_errors(errors))

    if (profile_name != pcie_svt_compiled_profile_name()) begin
      `uvm_fatal("SVT_ENV_PROFILE", $sformatf(
        "runtime profile=%s does not match compiled profile=%s",
        profile_name, pcie_svt_compiled_profile_name()))
    end

    pcie_svt_profile_factory::build(profile_name, max_gen, topology_cfg,
                                    policy_cfg, errors);
    if (errors.size() != 0)
      `uvm_fatal("SVT_ENV_PROFILE", pcie_svt_join_errors(errors))
    policy_cfg.default_fast_link_training = fast_link_training;
    policy_cfg.transport = transport;
    pcie_svt_profile_factory::apply_overrides(
      topology_cfg, overrides, policy_cfg, errors);
    if (errors.size() != 0)
      `uvm_fatal("SVT_ENV_OVERRIDE", pcie_svt_join_errors(errors))

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
    if (adapter_errors.size() != 0)
      `uvm_fatal("SVT_ENV_COUNT", pcie_svt_join_errors(adapter_errors))
    if ((env == null) || (env.port_count() != expected_ports.size())) begin
      `uvm_fatal("SVT_ENV_COUNT", $sformatf(
        "profile=%s expected=%0d actual=%0d", profile_name,
        expected_ports.size(), (env == null) ? 0 : env.port_count()))
    end
    if (env.vseqr == null)
      `uvm_fatal("SVT_ENV_VSEQR", "topology virtual sequencer is null")

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
          (expected_ports[i].role == PCIE_SVT_ROLE_RC))
        expected_root = env.port_agent[i];
      if ((expected_endpoint == null) &&
          (expected_ports[i].role == PCIE_SVT_ROLE_EP))
        expected_endpoint = env.port_agent[i];
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
