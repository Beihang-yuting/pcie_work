//------------------------------------------------------------------------------
// Common PCIe environment management layer.
//
// Protocol-specific child environments remain in their own packages.  This
// component owns the shared policy and creates the selected child through the
// UVM factory, keeping the SVT package compilable when TL is not installed.
//------------------------------------------------------------------------------

class pcie_unified_env extends uvm_env;
  `uvm_component_utils(pcie_unified_env)

  // --------------------------------------------------------------------------
  // Shared management state.
  // --------------------------------------------------------------------------
  // One validated policy object is shared by every backend adapter.
  pcie_global_cfg global_cfg;

  // --------------------------------------------------------------------------
  // Backend selection state.
  // --------------------------------------------------------------------------
  // Adapter is an object so concrete protocol envs can be supplied by a
  // derived environment without introducing a package dependency cycle.
  pcie_backend_base backend_adapter;

  // --------------------------------------------------------------------------
  // Mutually exclusive protocol children.
  // --------------------------------------------------------------------------
  // The TL handle intentionally uses uvm_component.  A combined TL/SVT build
  // registers pcie_tl_custom_env with the factory; an SVT-only build can still
  // compile this manager and will reject TL selection with a clear fatal.
  uvm_component tl_env;

  // SVT_REAL_DUT owns the actual Unified VIP environment below this manager.
  // It is created only for that backend; TL_ONLY never elaborates this child.
  pcie_svt_topology_env svt_env;

  function new(string name = "pcie_unified_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    string errors[$];
    bit bridge_override;

    super.build_phase(phase);

    // The base test publishes exactly one global policy object through the
    // config DB.  All backend decisions below derive from that object.
    if (!uvm_config_db#(pcie_global_cfg)::get(
          this, "", "global_cfg", global_cfg) || (global_cfg == null)) begin
      `uvm_fatal("UNIFIED_CFG", "non-null global_cfg is required")
      return;
    end

    // 允许在 env/test 作用域通过稳定 Config DB 键覆盖，同时保留普通调用
    // 者直接设置 backend-neutral 字段的路径。
    bridge_override = 1'b0;
    if (uvm_config_db#(bit)::get(
          this, "", "pcie_svt_bridge_enable", bridge_override))
      global_cfg.svt_bridge_enable = bridge_override;

    // Validate before creating protocol children so failures are reported as
    // configuration errors instead of partial component-tree failures.
    global_cfg.validate(errors);
    if (errors.size() != 0) begin
      `uvm_fatal("UNIFIED_CFG", $sformatf(
        "global configuration is invalid: %s", errors[0]))
      return;
    end

    // Select the policy adapter without importing the opposite protocol stack.
    case (global_cfg.backend)
      PCIE_BACKEND_TL_ONLY,
      PCIE_BACKEND_SVT_TL_FORWARD:
        backend_adapter = pcie_tl_backend::type_id::create("tl_backend");
      PCIE_BACKEND_SVT_REAL_DUT:
        backend_adapter = pcie_svt_backend::type_id::create("svt_backend");
      default:
        `uvm_fatal("UNIFIED_BACKEND", "unsupported backend enum")
    endcase

    backend_adapter.configure(global_cfg);
    if (!backend_adapter.validate(errors))
      `uvm_fatal("UNIFIED_BACKEND", $sformatf(
        "%s backend rejected global configuration: %s",
        backend_adapter.backend_name(), errors[0]));

    // Exactly one protocol child is created.  Publish only backend-neutral
    // objects here; the TL child performs its native config translation.
    if (global_cfg.backend == PCIE_BACKEND_TL_ONLY) begin
      uvm_config_db#(pcie_topology_cfg)::set(
        this, "tl_env", "topology_cfg", global_cfg.topology);
      uvm_config_db#(pcie_global_cfg)::set(
        this, "tl_env", "global_cfg", global_cfg);
      tl_env = uvm_factory::get().create_component_by_name(
        "pcie_tl_custom_env", get_full_name(), "tl_env", this);
      if (tl_env == null)
        `uvm_fatal("UNIFIED_BACKEND",
          "TL backend selected but pcie_tl_custom_env is not registered")
    end else if ((global_cfg.backend == PCIE_BACKEND_SVT_REAL_DUT) ||
                 (global_cfg.backend == PCIE_BACKEND_SVT_TL_FORWARD)) begin
      pcie_svt_topology_policy_cfg svt_policy;

      // Translate only management policy here.  The topology graph itself is
      // passed through unchanged so the SVT adapter and TL adapter cannot
      // disagree about link endpoints.
      svt_policy = pcie_svt_topology_policy_cfg::type_id::create(
        "svt_policy");
      svt_policy.init_defaults();
      // 全局策略只携带后端无关的 bit；进入 SVT 包边界后再转换为专用枚举。
      if (global_cfg.svt_bridge_enable)
        svt_policy.bridge_mode = PCIE_SVT_BRIDGE_TL_SVT;

      // Preserve every device/function image.  The SVT topology adapter maps
      // these records to physical Endpoint descriptors by node/link ownership.
      foreach (global_cfg.devices[i]) begin
        pcie_device_cfg device_copy;

        if (global_cfg.devices[i] == null) begin
          svt_policy.device_cfgs.push_back(null);
        end else begin
          device_copy = pcie_device_cfg::type_id::create(
            $sformatf("svt_device_cfg%0d", i));
          device_copy.copy(global_cfg.devices[i]);
          svt_policy.device_cfgs.push_back(device_copy);
        end
      end

      // Select the DUT node(s): a switch graph exposes the switch; a direct
      // RC-to-EP graph exposes the endpoint as the real DUT.
      foreach (global_cfg.topology.nodes[i]) begin
        pcie_topology_node_cfg node;
        node = global_cfg.topology.nodes[i];
        if (node == null)
          continue;
        // For direct RC↔EP graphs the EP is the DUT.  For Switch graphs the
        // Switch node is the DUT and all RC/EP links are exposed to SVT.
        if (node.kind == PCIE_TOPO_NODE_SWITCH)
          svt_policy.dut_node_ids.push_back(node.node_id);
      end
      if (svt_policy.dut_node_ids.size() == 0)
        foreach (global_cfg.topology.nodes[i])
          if ((global_cfg.topology.nodes[i] != null) &&
              (global_cfg.topology.nodes[i].kind == PCIE_TOPO_NODE_EP))
            svt_policy.dut_node_ids.push_back(
              global_cfg.topology.nodes[i].node_id);

      // Convert backend-neutral link policy into explicit SVT overrides.  A
      // topology-disabled link is omitted because the adapter already skips it;
      // every other link carries enable/use_svt and its negotiated capability.
      foreach (global_cfg.links[i]) begin
        pcie_link_cfg link_cfg;
        pcie_topology_link_cfg topology_link;
        pcie_svt_link_override_cfg override_cfg;
        bit active;

        link_cfg = global_cfg.links[i];
        if (link_cfg == null)
          continue;

        topology_link = null;
        foreach (global_cfg.topology.links[topology_index])
          if ((global_cfg.topology.links[topology_index] != null) &&
              (global_cfg.topology.links[topology_index].link_id ==
               link_cfg.link_id))
            topology_link = global_cfg.topology.links[topology_index];
        if ((topology_link == null) || !topology_link.enabled)
          continue;

        active = link_cfg.enabled && link_cfg.use_svt;
        override_cfg = pcie_svt_link_override_cfg::type_id::create(
          $sformatf("global_link_override%0d", i));
        override_cfg.link_id = link_cfg.link_id;
        override_cfg.has_enable = 1'b1;
        override_cfg.enabled = active;

        if (active) begin
          override_cfg.has_gen = 1'b1;
          override_cfg.max_gen = link_cfg.max_gen;
          override_cfg.has_width = 1'b1;
          override_cfg.link_width = link_cfg.link_width;
          if (link_cfg.vif_key != "") begin
            override_cfg.has_vif_key = 1'b1;
            override_cfg.vif_key = link_cfg.vif_key;
          end else if (link_cfg.has_hdl_slot) begin
            override_cfg.has_vif_key = 1'b1;
            override_cfg.vif_key = {
              svt_policy.vif_prefix, $sformatf("%0d", link_cfg.hdl_slot)};
          end
          if (link_cfg.has_hdl_slot)
            svt_policy.hdl_slot_by_link[link_cfg.link_id] =
              link_cfg.hdl_slot;
        end

        svt_policy.link_overrides.push_back(override_cfg);
      end

      // The official top publishes VIFs at the test scope because the native
      // topology environment used to be a direct test child.  Preserve that
      // external contract while inserting this manager level: retrieve each
      // handle from our parent and republish it at the scope queried by
      // pcie_svt_topology_env.
      begin
        virtual pcie_svt_reset_if reset_vif;

        reset_vif = null;
        if (uvm_config_db#(virtual pcie_svt_reset_if)::get(
              get_parent(), "", svt_policy.reset_vif_key, reset_vif) &&
            (reset_vif != null))
          uvm_config_db#(virtual pcie_svt_reset_if)::set(
            this, "", svt_policy.reset_vif_key, reset_vif);
      end
      foreach (svt_policy.link_overrides[i]) begin
        svt_pcie_vif link_vif;

        if ((svt_policy.link_overrides[i] == null) ||
            !svt_policy.link_overrides[i].enabled)
          continue;

        link_vif = null;
        if (uvm_config_db#(svt_pcie_vif)::get(
              get_parent(), "", svt_policy.link_overrides[i].vif_key,
              link_vif) && (link_vif != null))
          uvm_config_db#(svt_pcie_vif)::set(
            this, "", svt_policy.link_overrides[i].vif_key, link_vif);
      end

      // The topology graph remains the single source of connectivity truth.
      uvm_config_db#(pcie_topology_cfg)::set(
        this, "svt_env", "topology_cfg", global_cfg.topology);
      uvm_config_db#(pcie_svt_topology_policy_cfg)::set(
        this, "svt_env", "policy_cfg", svt_policy);
      begin
        svt_pcie_tlp_mapper mapper_handle;
        mapper_handle = null;
        if (uvm_config_db#(svt_pcie_tlp_mapper)::get(
              this, "", "pcie_svt_mapper", mapper_handle) &&
            (mapper_handle != null))
          uvm_config_db#(svt_pcie_tlp_mapper)::set(
            this, "svt_env", "pcie_svt_mapper", mapper_handle);
      end
      uvm_config_db#(bit)::set(
        this, "svt_env", "pcie_svt_bridge_enable",
        global_cfg.svt_bridge_enable ||
        (global_cfg.backend == PCIE_BACKEND_SVT_TL_FORWARD));
      svt_env = pcie_svt_topology_env::type_id::create("svt_env", this);

      if (global_cfg.backend == PCIE_BACKEND_SVT_TL_FORWARD) begin
        // Forward mode保留TL child作为唯一控制面，并复用 SVT child 已发布的
        // per-link bridge adapter；TL-only 不创建该额外子环境。
        uvm_config_db#(pcie_topology_cfg)::set(
          this, "tl_env", "topology_cfg", global_cfg.topology);
        uvm_config_db#(pcie_global_cfg)::set(
          this, "tl_env", "global_cfg", global_cfg);
        uvm_config_db#(bit)::set(
          this, "tl_env", "pcie_svt_bridge_required", 1'b1);
        tl_env = uvm_factory::get().create_component_by_name(
          "pcie_tl_custom_env", get_full_name(), "tl_env", this);
        if (tl_env == null)
          `uvm_fatal("UNIFIED_BACKEND",
            "SVT_TL_FORWARD selected but TL child is unavailable")
      end
    end
  endfunction
endclass
