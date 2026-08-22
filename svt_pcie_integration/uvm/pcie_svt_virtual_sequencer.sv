class pcie_svt_virtual_sequencer extends uvm_sequencer #(uvm_sequence_item);
  svt_pcie_device_agent port_agent[PCIE_SVT_MAX_PORTS];
  svt_pcie_device_configuration port_cfg[PCIE_SVT_MAX_PORTS];
  svt_pcie_device_virtual_sequencer port_seqr[PCIE_SVT_MAX_PORTS];
  svt_pcie_device_status port_status[PCIE_SVT_MAX_PORTS];
  pcie_svt_port_profile port_profile[PCIE_SVT_MAX_PORTS];
  bit active_port[PCIE_SVT_MAX_PORTS];
  bit switch_proxy_port[PCIE_SVT_MAX_PORTS];
  pcie_svt_switch_sidecar_env switch_sidecar[5];
  uvm_analysis_port #(svt_pcie_tl_service) switch_sidecar_service_port[5];
  bit switch_sidecar_enabled[5];
  pcie_svt_switch_enum_registry switch_enum_registry;
  pcie_tl_switch switch_core;
  pcie_svt_switch_port_adapter switch_adapter[5];
  pcie_svt_switch_scoreboard switch_scoreboard;
  bit rc_host_memory_initialized;
  bit rc_host_memory_initialization_in_progress;
  bit [63:0] rc_host_memory_base;
  bit [63:0] rc_host_memory_limit;
  virtual pcie_svt_reset_if reset_vif;

  `uvm_component_utils(pcie_svt_virtual_sequencer)

  function new(string name = "pcie_svt_virtual_sequencer",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function bit try_reserve_rc_host_memory_initialization();
    if (rc_host_memory_initialized ||
        rc_host_memory_initialization_in_progress)
      return 1'b0;
    rc_host_memory_initialization_in_progress = 1'b1;
    return 1'b1;
  endfunction

  function void complete_rc_host_memory_initialization(
      bit [63:0] base,
      bit [63:0] limit);
    if (!rc_host_memory_initialization_in_progress ||
        rc_host_memory_initialized)
      `uvm_fatal("RC_HOST_MEMORY",
        "host-memory completion requires one active reservation")
    rc_host_memory_initialized = 1'b1;
    rc_host_memory_initialization_in_progress = 1'b0;
    rc_host_memory_base = base;
    rc_host_memory_limit = limit;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual pcie_svt_reset_if)::get(
          null, "uvm_test_top", "reset_vif", reset_vif) ||
        (reset_vif == null))
      `uvm_fatal("CFG_RESET", "missing or null reset_vif")
  endfunction
endclass
