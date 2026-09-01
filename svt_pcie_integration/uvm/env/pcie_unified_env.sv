//------------------------------------------------------------------------------
// Common PCIe environment management layer.
//
// Protocol-specific child environments remain in their own package/filelist;
// this component owns the shared policy and backend selection without forcing
// a full TL package into an SVT-only build.
//------------------------------------------------------------------------------

class pcie_unified_env extends uvm_env;
  `uvm_component_utils(pcie_unified_env)

  // One validated policy object is shared by every backend adapter.
  pcie_global_cfg global_cfg;

  // Adapter is an object so concrete protocol envs can be supplied by a
  // derived environment without introducing a package dependency cycle.
  pcie_backend_base backend_adapter;

  // SVT_REAL_DUT owns the actual Unified VIP environment below this manager.
  // It is created only for that backend; TL_ONLY never elaborates this child.
  pcie_svt_topology_env svt_env;

  function new(string name = "pcie_unified_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    string errors[$];

    super.build_phase(phase);
    if (!uvm_config_db#(pcie_global_cfg)::get(
          this, "", "global_cfg", global_cfg) || (global_cfg == null)) begin
      `uvm_fatal("UNIFIED_CFG", "non-null global_cfg is required")
      return;
    end
    global_cfg.validate(errors);
    if (errors.size() != 0) begin
      `uvm_fatal("UNIFIED_CFG", $sformatf(
        "global configuration is invalid: %s", errors[0]))
      return;
    end

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

    if (global_cfg.backend == PCIE_BACKEND_SVT_REAL_DUT) begin
      pcie_svt_topology_policy_cfg svt_policy;

      // Translate only management policy here.  The topology graph itself is
      // passed through unchanged so the SVT adapter and TL adapter cannot
      // disagree about link endpoints.
      svt_policy = pcie_svt_topology_policy_cfg::type_id::create(
        "svt_policy");
      svt_policy.init_defaults();
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

      foreach (global_cfg.links[i]) begin
        if ((global_cfg.links[i] != null) &&
            global_cfg.links[i].has_hdl_slot)
          svt_policy.hdl_slot_by_link[global_cfg.links[i].link_id] =
            global_cfg.links[i].hdl_slot;
      end
      uvm_config_db#(pcie_topology_cfg)::set(
        this, "svt_env", "topology_cfg", global_cfg.topology);
      uvm_config_db#(pcie_svt_topology_policy_cfg)::set(
        this, "svt_env", "policy_cfg", svt_policy);
      svt_env = pcie_svt_topology_env::type_id::create("svt_env", this);
    end
  endfunction
endclass
