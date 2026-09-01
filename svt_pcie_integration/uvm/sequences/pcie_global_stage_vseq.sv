//------------------------------------------------------------------------------
// Backend-neutral PCIe stage sequence scaffold.
//
// The sequence defines the required ordering without hard-coding protocol
// objects.  Backend-specific derived sequences override the three hooks and
// start existing TL or SVT sequences on their own virtual sequencers.
//------------------------------------------------------------------------------

class pcie_global_stage_vseq extends uvm_sequence #(uvm_sequence_item);
  `uvm_object_utils(pcie_global_stage_vseq)

  // The sequence is backend-neutral; derived sequences dispatch to TL or SVT
  // virtual sequencers while preserving this stage order.
  pcie_global_cfg global_cfg;

  function new(string name = "pcie_global_stage_vseq");
    super.new(name);
  endfunction

  // Hook 1: establish link training for enabled links only.
  virtual task start_enabled_links();
    // Link bring-up is intentionally limited to enabled runtime policy.
    foreach (global_cfg.links[i]) begin
      if ((global_cfg.links[i] != null) && global_cfg.links[i].enabled)
        `uvm_info("GLOBAL_STAGE", $sformatf(
          "link bring-up requested: %s x%0d Gen%0d",
          global_cfg.links[i].link_id,
          global_cfg.links[i].link_width,
          global_cfg.links[i].max_gen), UVM_LOW)
    end
  endtask

  // Hook 2: initialize configuration space/BAR policy in backend order.
  virtual task initialize_devices();
    // Device initialization follows link readiness and precedes enumeration.
    foreach (global_cfg.devices[i])
      if (global_cfg.devices[i] != null)
        `uvm_info("GLOBAL_STAGE", $sformatf(
          "configuration-space init requested: %s BDF=%04h",
          global_cfg.devices[i].device_id,
          global_cfg.devices[i].bdf), UVM_LOW)
  endtask

  // Hook 3: enumerate and perform backend-specific memory traffic.
  virtual task enumerate_and_test_memory();
    // Concrete backends replace this hook with enumeration and traffic.
    `uvm_info("GLOBAL_STAGE", "enumeration/traffic stage requested", UVM_LOW)
  endtask

  virtual task body();
    if (global_cfg == null) begin
      `uvm_fatal("GLOBAL_STAGE", "global_cfg is required")
      return;
    end
    // PCIe verification ordering is intentional: traffic before link/config
    // completion would create false failures and can deadlock completions.
    start_enabled_links();
    initialize_devices();
    enumerate_and_test_memory();
  endtask
endclass
