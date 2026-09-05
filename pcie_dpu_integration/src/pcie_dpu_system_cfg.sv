//------------------------------------------------------------------------------
// DPU-aware system authoring configuration.
//
// This optional object is the boundary between dpu-common and PCIe TL.  It
// carries frozen DPU inputs plus a PCIe policy, but does not select or create
// an SVT/unified environment.
//------------------------------------------------------------------------------

class pcie_dpu_system_cfg extends uvm_object;
  `uvm_object_utils(pcie_dpu_system_cfg)

  dpu_device_cfg device_cfg;
  dpu_resource_placement_cfg placement_cfg;
  pcie_dpu_attachment_cfg attachments;
  // PCIe-side physical ownership: dpu-common domains are mapped to concrete
  // RC Roots here, never inferred from Host/PF/VF array order.
  pcie_dpu_root_binding_cfg root_bindings;
  pcie_global_cfg pcie_policy;

  // Optional register executor supplied by a project-specific TL test.
  dpu_reg_executor executor;
  int unsigned rc_index;
  string root_link_id;
  bit use_switch_routing;

  bit enable_bootstrap_plan;
  bit enable_vio_plan;
  dpu_vio_register_plan_policy vio_policy;
  dpu_vio_dataplane_plan_extension vio_dataplane_extension;

  function new(string name = "pcie_dpu_system_cfg");
    super.new(name);
    device_cfg = null;
    placement_cfg = null;
    attachments = null;
    root_bindings = null;
    pcie_policy = null;
    executor = null;
    rc_index = 0;
    root_link_id = "";
    use_switch_routing = 1'b0;
    enable_bootstrap_plan = 1'b1;
    enable_vio_plan = 1'b1;
    vio_policy = dpu_vio_register_plan_policy::type_id::create(
      {name, "_vio_policy"});
    vio_dataplane_extension = null;
  endfunction

  function void validate(output string errors[$]);
    string policy_errors[$];
    string attachment_errors[$];

    errors.delete();
    if (device_cfg == null)
      errors.push_back("DPU device authoring configuration is null");
    if (placement_cfg == null)
      errors.push_back("DPU placement configuration is null");
    if (attachments == null) begin
      errors.push_back("DPU physical attachment map is null");
    end else begin
      attachments.validate(attachment_errors);
      foreach (attachment_errors[index])
        errors.push_back({"attachment: ", attachment_errors[index]});
    end
    if (root_bindings == null)
      errors.push_back("PCIe Root/domain binding configuration is null");
    else if ((pcie_policy != null) && (pcie_policy.topology != null)) begin
      int root_count;
      string root_errors[$];

      root_count = 0;
      foreach (pcie_policy.topology.nodes[node_index]) begin
        if ((pcie_policy.topology.nodes[node_index] != null) &&
            (pcie_policy.topology.nodes[node_index].kind == PCIE_TOPO_NODE_RC))
          root_count++;
      end
      root_bindings.validate(root_count, root_errors);
      foreach (root_errors[index])
        errors.push_back({"Root binding: ", root_errors[index]});
    end
    if (pcie_policy == null) begin
      errors.push_back("PCIe physical/backend policy is null");
    end else begin
      pcie_policy.validate(policy_errors);
      foreach (policy_errors[index])
        errors.push_back({"PCIe policy: ", policy_errors[index]});
    end
  endfunction

  // Project only PCIe-owned link policy; DPU-derived device images remain
  // authoritative and are never reallocated by this object.
  function bit apply_pcie_policy(
      pcie_global_cfg projected_cfg,
      output string errors[$]);
    pcie_link_cfg link_copy;
    string validation_errors[$];

    errors.delete();
    if ((projected_cfg == null) || (pcie_policy == null)) begin
      errors.push_back("projected and PCIe policy objects must be non-null");
      return 1'b0;
    end
    if (projected_cfg.topology != pcie_policy.topology) begin
      errors.push_back(
        "projected policy topology does not match the PCIe authoring policy");
      return 1'b0;
    end
    projected_cfg.backend = pcie_policy.backend;
    projected_cfg.runtime_num_links = pcie_policy.runtime_num_links;
    projected_cfg.links.delete();
    foreach (pcie_policy.links[index]) begin
      if (pcie_policy.links[index] == null)
        projected_cfg.links.push_back(null);
      else begin
        link_copy = pcie_link_cfg::type_id::create(
          $sformatf("projected_link%0d", index));
        link_copy.copy(pcie_policy.links[index]);
        projected_cfg.links.push_back(link_copy);
      end
    end
    projected_cfg.validate(validation_errors);
    foreach (validation_errors[index])
      errors.push_back(validation_errors[index]);
    return errors.size() == 0;
  endfunction
endclass : pcie_dpu_system_cfg
