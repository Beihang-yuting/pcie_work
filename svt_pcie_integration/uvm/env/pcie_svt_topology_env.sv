`include "pcie_svt_hdl_slot_cfg.svh"

class pcie_svt_topology_env extends pcie_device_unified_vip_env;
  `uvm_component_utils(pcie_svt_topology_env)

  // --------------------------------------------------------------------------
  // Translated topology policy.
  // --------------------------------------------------------------------------
  pcie_topology_cfg topology_cfg;
  pcie_svt_topology_policy_cfg policy_cfg;
  pcie_svt_port_descriptor descriptors[$];

  // --------------------------------------------------------------------------
  // One configuration/status/agent tuple per dynamic descriptor.
  // --------------------------------------------------------------------------
  svt_pcie_device_configuration port_cfg[];
  svt_pcie_device_status port_status[];
  svt_pcie_device_agent port_agent[];
  pcie_svt_topology_ep_bar_sizing_callback
    bar_sizing_callback_by_link[string];
  bit bar_sizing_callback_registered_by_link[string];

  // --------------------------------------------------------------------------
  // Virtual sequencing and translation helpers.
  // --------------------------------------------------------------------------
  pcie_svt_topology_virtual_sequencer vseqr;
  pcie_svt_topology_adapter adapter;
  string errors[$];

  // --------------------------------------------------------------------------
  // Optional TL/SVT Mapper bridge.
  // --------------------------------------------------------------------------
  // These handles are intentionally kept separate from the native SVT agent
  // arrays.  TL-only and legacy native tests therefore retain the same aliases
  // and component hierarchy when the bridge is disabled.
  bit bridge_enable;
  svt_pcie_tlp_mapper bridge_mapper;
  pcie_svt_route_info bridge_route_info;
  pcie_svt_if_adapter bridge_adapters[];

  function int unsigned bridge_adapter_count();
    int unsigned count;

    count = 0;
    foreach (bridge_adapters[i])
      if (bridge_adapters[i] != null)
        count++;
    return count;
  endfunction

  function new(string name = "pcie_svt_topology_env",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function int unsigned port_count();
    return descriptors.size();
  endfunction

  static function string sanitize_link_id(string link_id);
    string sanitized;

    sanitized = link_id;
    for (int unsigned i = 0; i < sanitized.len(); i++) begin
      byte unsigned character;

      character = sanitized.getc(i);
      if (!(((character >= 8'h30) && (character <= 8'h39)) ||
            ((character >= 8'h41) && (character <= 8'h5a)) ||
            ((character >= 8'h61) && (character <= 8'h7a)) ||
            (character == 8'h5f)))
        sanitized.putc(i, 8'h5f);
    end
    return sanitized;
  endfunction

  static function string port_owned_name(
      string prefix, pcie_svt_port_descriptor descriptor);
    return $sformatf("%s_s%0d_%s", prefix, descriptor.slot_index,
                     sanitize_link_id(descriptor.link_id));
  endfunction

  static function bit requires_bar_sizing_callback(
      pcie_svt_port_descriptor descriptor);
    return (descriptor != null) &&
           (descriptor.role == PCIE_SVT_ROLE_EP) &&
           (descriptor.endpoint_model == PCIE_SVT_EP_SINGLE);
  endfunction

  function bit has_bar_sizing_callback(string link_id);
    return bar_sizing_callback_by_link.exists(link_id) &&
           (bar_sizing_callback_by_link[link_id] != null);
  endfunction

  function bit bar_sizing_callback_is_registered(string link_id);
    return bar_sizing_callback_registered_by_link.exists(link_id) &&
           bar_sizing_callback_registered_by_link[link_id];
  endfunction

  function bit bar_sizing_callbacks_are_idle();
    foreach (bar_sizing_callback_by_link[link_id])
      if ((bar_sizing_callback_by_link[link_id] == null) ||
          !bar_sizing_callback_by_link[link_id].is_idle())
        return 0;
    return 1;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    pcie_svt_device_cfg_builder cfg_builder;
    bit configured_bridge_enable;

    // Deliberately do not call super: the official example always creates one
    // fixed Root and one fixed Endpoint agent.
    if (!uvm_config_db#(pcie_topology_cfg)::get(
          this, "", "topology_cfg", topology_cfg) ||
        (topology_cfg == null)) begin
      `uvm_fatal("SVT_ENV_CFG", "non-null topology_cfg is required")
      return;
    end
    if (!uvm_config_db#(pcie_svt_topology_policy_cfg)::get(
          this, "", "policy_cfg", policy_cfg) ||
        (policy_cfg == null)) begin
      `uvm_fatal("SVT_ENV_CFG", "non-null policy_cfg is required")
      return;
    end

    // Config DB is the stable integration contract.  A policy value remains
    // the fallback so existing direct SVT tests need no new setup call.
    bridge_enable = (policy_cfg.bridge_mode == PCIE_SVT_BRIDGE_TL_SVT);
    configured_bridge_enable = 1'b0;
    if (uvm_config_db#(bit)::get(
          this, "", "pcie_svt_bridge_enable", configured_bridge_enable))
      bridge_enable = configured_bridge_enable;
    bridge_mapper = null;
    void'(uvm_config_db#(svt_pcie_tlp_mapper)::get(
      this, "", "pcie_svt_mapper", bridge_mapper));
    bridge_route_info = pcie_svt_route_info_default();
    void'(uvm_config_db#(pcie_svt_route_info)::get(
      this, "", "pcie_svt_route_info", bridge_route_info));

    // A bridge without its public Mapper endpoint cannot make progress; fail
    // during build rather than deferring a null dereference to run time.
    if (bridge_enable && (bridge_mapper == null)) begin
      `uvm_fatal("SVT_BRIDGE_CFG",
        "pcie_svt_bridge_enable is set but pcie_svt_mapper is null")
      return;
    end

    adapter = pcie_svt_topology_adapter::type_id::create("adapter");
    adapter.translate(topology_cfg, policy_cfg, descriptors, errors);
    if (errors.size() != 0) begin
      `uvm_fatal("SVT_ENV_CFG", pcie_svt_join_errors(errors))
      return;
    end

    // The UVM descriptor array is dynamic, but its SVT VIF handles still map to
    // statically elaborated HDL slots.  Reject an oversized policy here rather
    // than allowing a later config_db lookup to fail with an opaque VIF error.
    if (descriptors.size() > `PCIE_SVT_ENV_MAX_NUM_LINKS) begin
      `uvm_fatal("SVT_ENV_LIMIT", $sformatf(
        "descriptor count=%0d exceeds PCIE_SVT_ENV_MAX_NUM_LINKS=%0d",
        descriptors.size(), `PCIE_SVT_ENV_MAX_NUM_LINKS))
      return;
    end
    foreach (descriptors[i]) begin
      if ((descriptors[i] == null) ||
          (descriptors[i].slot_index >= `PCIE_SVT_ENV_MAX_HDL_AGENTS)) begin
        `uvm_fatal("SVT_ENV_LIMIT", $sformatf(
          "descriptor slot=%0d exceeds PCIE_SVT_ENV_MAX_HDL_AGENTS=%0d",
          (descriptors[i] == null) ? 0 : descriptors[i].slot_index,
          `PCIE_SVT_ENV_MAX_HDL_AGENTS))
        return;
      end
    end

    port_cfg = new[descriptors.size()];
    port_status = new[descriptors.size()];
    port_agent = new[descriptors.size()];
    bridge_adapters = new[0];
    if (bridge_enable)
      bridge_adapters = new[descriptors.size()];
    vseqr = pcie_svt_topology_virtual_sequencer::type_id::create(
      "vseqr", this);
    sys_virt_seqr =
      svt_pcie_device_system_virtual_sequencer::type_id::create(
        "sys_virt_seqr", this);
    if (!uvm_config_db#(virtual pcie_svt_reset_if)::get(
          get_parent(), "", policy_cfg.reset_vif_key, vseqr.reset_vif) ||
        (vseqr.reset_vif == null)) begin
      `uvm_fatal("SVT_ENV_CFG", $sformatf(
        "non-null reset VIF '%s' is required", policy_cfg.reset_vif_key))
      return;
    end

    cfg_builder = pcie_svt_device_cfg_builder::type_id::create(
      "cfg_builder");
    foreach (descriptors[i]) begin
      string child_name;
      svt_pcie_vif vif;

      child_name = port_owned_name("port", descriptors[i]);
      vif = null;
      if (!uvm_config_db#(svt_pcie_vif)::get(
            get_parent(), "", descriptors[i].vif_key, vif) ||
          (vif == null)) begin
        `uvm_fatal("SVT_ENV_VIF", $sformatf(
          "%s requires non-null Unified VIF '%s'",
          descriptors[i].link_id, descriptors[i].vif_key))
        return;
      end

      port_cfg[i] = svt_pcie_device_configuration::type_id::create(
        port_owned_name("port_cfg", descriptors[i]));
      port_status[i] = svt_pcie_device_status::type_id::create(
        port_owned_name("port_status", descriptors[i]));
      cfg_builder.apply(descriptors[i], vif, port_cfg[i]);

      uvm_config_db#(svt_pcie_device_configuration)::set(
        this, child_name, "cfg", port_cfg[i]);
      uvm_config_db#(svt_pcie_device_status)::set(
        this, child_name, "shared_status", port_status[i]);
      port_agent[i] = svt_pcie_device_agent::type_id::create(
        child_name, this);

      if (bridge_enable && (descriptors[i] != null)) begin
        pcie_svt_route_info route;

        // Route identity defaults to the translated descriptor.  A caller may
        // override application_id/requester metadata through the stable route
        // config-DB object while link and hierarchy remain topology-owned.
        route = bridge_route_info;
        route.link_id = descriptors[i].slot_index;
        route.link_name = descriptors[i].link_id;
        route.root_index = descriptors[i].root_hierarchy;
        // application_id=0 合法；仅在调用方未声明有效值时使用 slot 默认值。
        if (!route.application_id_valid) begin
          route.application_id = descriptors[i].slot_index;
          route.application_id_valid = 1'b1;
        end
        bridge_adapters[i] = pcie_svt_if_adapter::type_id::create(
          port_owned_name("bridge_adapter", descriptors[i]), this);
        // Per-adapter Config DB entries may override the shared route object;
        // this is how multi-link tests assign distinct application IDs.
        void'(uvm_config_db#(pcie_svt_route_info)::get(
          this, bridge_adapters[i].get_name(), "pcie_svt_route_info", route));
        bridge_adapters[i].mapper = bridge_mapper;
        bridge_adapters[i].route = route;
        // 适配器的 send()/receive() 直接走 Mapper，但 mode 必须标记为
        // SV_IF_MODE，使 TL monitor 启用 read-back registry/completion 清理。
        // bridge 不绑定父类 vif，因此继承的 FC worker 不会被启动。
        bridge_adapters[i].mode = SV_IF_MODE;
        uvm_config_db#(svt_pcie_tlp_mapper)::set(
          this, bridge_adapters[i].get_name(), "pcie_svt_mapper",
          bridge_mapper);
        uvm_config_db#(pcie_svt_route_info)::set(
          this, bridge_adapters[i].get_name(), "pcie_svt_route_info", route);
        // 将同一适配器发布给并行的 TL child；TL env 在 build 前读取该键，
        // 因而不会生成孤立的原生 TLM adapter。
        if (descriptors[i].role == PCIE_SVT_ROLE_RC) begin
          // TL RC adapters are indexed by root hierarchy, not descriptor
          // order; sparse/reordered links must therefore publish this key
          // using the physical root index to avoid cross-root misrouting.
          uvm_config_db#(pcie_tl_if_adapter)::set(
            null, {get_parent().get_full_name(), ".tl_env"},
            $sformatf("pcie_svt_bridge_rc_adapter_%0d",
                      descriptors[i].root_hierarchy), bridge_adapters[i]);
        end
      end
      if (requires_bar_sizing_callback(descriptors[i])) begin
        bar_sizing_callback_by_link[descriptors[i].link_id] =
          pcie_svt_topology_ep_bar_sizing_callback::type_id::create(
            port_owned_name("bar_sizing_callback", descriptors[i]));
        if (bar_sizing_callback_by_link[descriptors[i].link_id] == null)
          `uvm_fatal("SVT_ENV_BAR_CB", $sformatf(
            "%s callback creation failed", descriptors[i].link_id))
        bar_sizing_callback_by_link[descriptors[i].link_id].configure(
          descriptors[i]);
      end
      vseqr.register_port(descriptors[i], port_cfg[i], port_status[i],
                          port_agent[i]);
    end

    root = null;
    endpoint = null;
    root_cfg = null;
    endpoint_cfg = null;
    root_status = null;
    endpoint_status = null;
    foreach (descriptors[i]) begin
      if ((root == null) && (descriptors[i].role == PCIE_SVT_ROLE_RC)) begin
        root = port_agent[i];
        root_cfg = port_cfg[i];
        root_status = port_status[i];
      end
      if ((endpoint == null) &&
          (descriptors[i].role == PCIE_SVT_ROLE_EP)) begin
        endpoint = port_agent[i];
        endpoint_cfg = port_cfg[i];
        endpoint_status = port_status[i];
      end
    end
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    // Deliberately do not call super: aliases may legitimately be null and no
    // second official agent pair exists.
    foreach (descriptors[i]) begin
      if ((port_agent[i] == null) || (port_agent[i].virt_seqr == null)) begin
        `uvm_fatal("SVT_ENV_CONNECT", $sformatf(
          "%s has no device virtual sequencer", descriptors[i].link_id))
        return;
      end
      vseqr.connect_port(descriptors[i].link_id, port_agent[i].virt_seqr);
      if (requires_bar_sizing_callback(descriptors[i])) begin
        string link_id = descriptors[i].link_id;
        if ((port_agent[i] == null) || !port_agent[i].target.exists(0) ||
            (port_agent[i].target[0] == null))
          `uvm_fatal("SVT_ENV_BAR_CB", $sformatf(
            "%s active Target App target[0] is missing", link_id))
        if (!has_bar_sizing_callback(link_id) ||
            bar_sizing_callback_is_registered(link_id))
          `uvm_fatal("SVT_ENV_BAR_CB", $sformatf(
            "%s callback ownership/registration state is invalid", link_id))
        uvm_callbacks#(
          svt_pcie_target_app,
          svt_pcie_target_app_callback
        )::add(port_agent[i].target[0], bar_sizing_callback_by_link[link_id]);
        bar_sizing_callback_registered_by_link[link_id] = 1'b1;
      end
    end
    if (root != null)
      sys_virt_seqr.root_virt_seqr = root.virt_seqr;
    if (endpoint != null)
      sys_virt_seqr.endpoint_virt_seqr = endpoint.virt_seqr;
  endfunction
endclass
