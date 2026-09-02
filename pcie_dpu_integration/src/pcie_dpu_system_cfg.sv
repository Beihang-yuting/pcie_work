//------------------------------------------------------------------------------
// DPU-aware system authoring configuration.
//
// Device identity and resource placement come from dpu-common.  The PCIe
// policy object owns only topology, backend choice, active links, and static
// SVT slot/VIF bindings.  The system environment resolves both inputs once
// and publishes an immutable pair of DPU snapshots plus one projected policy.
//------------------------------------------------------------------------------

class pcie_dpu_system_cfg extends uvm_object;
  `uvm_object_utils(pcie_dpu_system_cfg)

  // --------------------------------------------------------------------------
  // dpu-common authoring inputs.
  // --------------------------------------------------------------------------
  dpu_device_cfg device_cfg;
  dpu_resource_placement_cfg placement_cfg;
  pcie_dpu_attachment_cfg attachments;

  // --------------------------------------------------------------------------
  // PCIe-owned physical and backend policy.
  // --------------------------------------------------------------------------
  pcie_global_cfg pcie_policy;

  // A supplied executor is useful for a custom transport or a controlled
  // test.  A null handle asks pcie_dpu_system_env to create the selected TL or
  // SVT executor after the protocol child has connected its sequencers.
  dpu_reg_executor executor;
  int unsigned rc_index;
  string root_link_id;
  bit use_switch_routing;

  // Plan stages are enabled independently so a derived test can stop at a
  // well-defined bring-up boundary without changing the stage implementation.
  bit enable_bootstrap_plan;
  bit enable_vio_plan;

  dpu_vio_register_plan_policy vio_policy;
  dpu_vio_dataplane_plan_extension vio_dataplane_extension;

  function new(string name = "pcie_dpu_system_cfg");
    super.new(name);
    device_cfg = null;
    placement_cfg = null;
    attachments = null;
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

    if (pcie_policy == null) begin
      errors.push_back("PCIe physical/backend policy is null");
    end else begin
      pcie_policy.validate(policy_errors);
      foreach (policy_errors[index])
        errors.push_back({"PCIe policy: ", policy_errors[index]});
    end

    if ((pcie_policy != null) &&
        (pcie_policy.backend == PCIE_BACKEND_SVT_REAL_DUT) &&
        (root_link_id == ""))
      errors.push_back("SVT backend requires a non-empty root_link_id");
  endfunction

  // Copy only PCIe-owned policy into the projected object.  Device records
  // deliberately remain untouched because their BDF/BAR fields came from the
  // frozen DPU snapshot and must never be replaced by authoring defaults.
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
      if (pcie_policy.links[index] == null) begin
        projected_cfg.links.push_back(null);
      end else begin
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
