//------------------------------------------------------------------------------
// Backend-neutral PCIe stage sequence scaffold.
//
// The sequence defines the required ordering without hard-coding protocol
// objects.  Backend-specific derived sequences override the hooks and start
// existing TL or SVT sequences on their own virtual sequencers.
//------------------------------------------------------------------------------

class pcie_global_stage_vseq extends uvm_sequence #(uvm_sequence_item);
  `uvm_object_utils(pcie_global_stage_vseq)

  // The sequence is backend-neutral; derived sequences dispatch to TL or SVT
  // virtual sequencers while preserving this stage order.
  pcie_global_cfg global_cfg;

  function new(string name = "pcie_global_stage_vseq");
    super.new(name);
  endfunction

  // Hook 2: establish link training for enabled links only.
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

  // Hook 1: initialize local VIP/configuration-space state while links are
  // still down.  R-2020.12 requires its CFG refresh and reset release before
  // PHY/link enable sequences are started.
  virtual task initialize_devices();
    // Device initialization precedes physical link enable and enumeration.
    foreach (global_cfg.devices[i])
      if (global_cfg.devices[i] != null)
        `uvm_info("GLOBAL_STAGE", $sformatf(
          "configuration-space init requested: %s BDF=%04h",
          global_cfg.devices[i].device_id,
          global_cfg.devices[i].bdf), UVM_LOW)
  endtask

  // Hook 3: enumerate devices after every enabled physical link is ready.
  virtual task enumerate_devices();
    `uvm_info("GLOBAL_STAGE", "enumeration stage requested", UVM_LOW)
  endtask

  // Compatibility hook retained for existing derived tests that combined
  // enumeration and traffic.  New integrations override enumerate_devices()
  // and start_traffic() independently so DPU plans can run between them.
  virtual task enumerate_and_test_memory();
    `uvm_info("GLOBAL_STAGE", "traffic stage requested", UVM_LOW)
  endtask

  // Hook 4: start service traffic only after configuration plans complete.
  virtual task start_traffic();
    enumerate_and_test_memory();
  endtask

  virtual task body();
    if (global_cfg == null) begin
      `uvm_fatal("GLOBAL_STAGE", "global_cfg is required")
      return;
    end
    // Local VIP configuration must run with reset asserted and links down;
    // enumeration follows L0, and traffic is always last.
    initialize_devices();
    start_enabled_links();
    enumerate_devices();
    start_traffic();
  endtask
endclass
