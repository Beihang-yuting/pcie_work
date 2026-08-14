class pcie_svt_all_cfg_spaces_init_vseq extends
    uvm_sequence #(uvm_sequence_item);
  // Synopsys R-2020.12 unified VIP example initialization hold:
  // examples/sverilog/tb_pcie_svt_uvm_unified_vip_sys/top.sv (reset setup).
  localparam time PCIE_SVT_VIP_INIT_HOLD_TIME = 205ns;

  `uvm_object_utils(pcie_svt_all_cfg_spaces_init_vseq)
  `uvm_declare_p_sequencer(pcie_svt_virtual_sequencer)

  function new(string name = "pcie_svt_all_cfg_spaces_init_vseq");
    super.new(name);
  endfunction

  function void validate_active_registry();
    int unsigned active_count;

    active_count = 0;
    if (p_sequencer.reset_vif == null)
      `uvm_fatal("CFG_RESET", "null reset_vif")
    for (int unsigned i = 0; i < PCIE_SVT_MAX_PORTS; i++) begin
      if (!p_sequencer.active_port[i])
        continue;
      active_count++;
      if ((p_sequencer.port_seqr[i] == null) ||
          (p_sequencer.port_status[i] == null) ||
          (p_sequencer.port_status[i].pcie_status == null) ||
          (p_sequencer.port_status[i].pcie_status.pl_status == null) ||
          (p_sequencer.port_profile[i] == null))
        `uvm_fatal("PORT_REGISTRY", $sformatf(
          "active port index %0d has incomplete sequencer/status/profile handles",
          i))
    end
    if (active_count == 0)
      `uvm_fatal("PORT_REGISTRY", "configuration init has no active ports")
  endfunction

  function void check_active_links_down(string stage);
    for (int unsigned i = 0; i < PCIE_SVT_MAX_PORTS; i++) begin
      if (!p_sequencer.active_port[i])
        continue;
      if (p_sequencer.port_status[i].pcie_status.pl_status.link_up !== 1'b0)
        `uvm_fatal("CFG_LINK_STATE", $sformatf(
          "stage=%s port=%s link_up=%b, expected known zero",
          stage, p_sequencer.port_profile[i].port_id,
          p_sequencer.port_status[i].pcie_status.pl_status.link_up))
      `uvm_info("CFG_LINK_DOWN", $sformatf(
        "stage=%s port=%s link_up=0", stage,
        p_sequencer.port_profile[i].port_id), UVM_NONE)
    end
  endfunction

  task run_one_port(int unsigned index);
    pcie_svt_cfg_space_init_seq child;
    bit child_started;
    bit child_done;

    child = pcie_svt_cfg_space_init_seq::type_id::create(
      $sformatf("init_port%0d", index));
    if (child == null)
      `uvm_fatal("CFG_INIT", $sformatf(
        "port index %0d child sequence creation failed", index))
    child.port_index = index;
    child.port_seqr = p_sequencer.port_seqr[index];
    child.port_status = p_sequencer.port_status[index];
    child.profile = p_sequencer.port_profile[index];
    child_started = 1'b0;
    child_done = 1'b0;
    fork
      begin
        child_started = 1'b1;
        child.start(null);
        child_done = 1'b1;
      end
      begin
        wait (child_started);
        #1ms;
        // Let completion scheduled exactly at the deadline settle first.
        if (!child_done)
          #1step;
        if (!child_done)
          `uvm_fatal("CFG_INIT_TIMEOUT", {child.progress_context(),
            " exceeded 1ms watchdog"})
      end
    join_any
    disable fork;
  endtask

  virtual task body();
    if (p_sequencer == null)
      `uvm_fatal("CFG_INIT", "null PCIe SVT virtual sequencer")
    validate_active_registry();
    if (p_sequencer.reset_vif.asserted !== '1)
      `uvm_fatal("CFG_RESET", $sformatf(
        "stage=vip_init_hold expected all resets asserted, got 0x%0h",
        p_sequencer.reset_vif.asserted))
    `uvm_info("CFG_RESET_ASSERTED", $sformatf(
      "stage=vip_init_hold asserted=0x%0h hold=%0t",
      p_sequencer.reset_vif.asserted, PCIE_SVT_VIP_INIT_HOLD_TIME), UVM_NONE)

    #(PCIE_SVT_VIP_INIT_HOLD_TIME);
    check_active_links_down("before_release");
    p_sequencer.reset_vif.release_all();
    #0;
    if (p_sequencer.reset_vif.asserted !== '0)
      `uvm_fatal("CFG_RESET", $sformatf(
        "stage=cfg_init expected all resets released, got 0x%0h",
        p_sequencer.reset_vif.asserted))
    `uvm_info("CFG_RESET_RELEASED", $sformatf(
      "stage=cfg_init asserted=0x%0h",
      p_sequencer.reset_vif.asserted), UVM_NONE)
    check_active_links_down("before_cfg");

    for (int unsigned i = 0; i < PCIE_SVT_MAX_PORTS; i++) begin
      if (!p_sequencer.active_port[i])
        continue;
      fork
        automatic int unsigned index = i;
        run_one_port(index);
      join_none
    end
    wait fork;

    if (p_sequencer.reset_vif.asserted !== '0)
      `uvm_fatal("CFG_RESET", $sformatf(
        "stage=complete reset was reasserted, asserted=0x%0h",
        p_sequencer.reset_vif.asserted))
    check_active_links_down("after_cfg");
    for (int unsigned i = 0; i < PCIE_SVT_MAX_PORTS; i++)
      if (p_sequencer.active_port[i])
        `uvm_info("CFG_INIT_DONE", $sformatf(
          "port=%s cfg_reqs=%0d reset_asserted=0x%0h link_up=0",
          p_sequencer.port_profile[i].port_id,
          p_sequencer.port_seqr[i].cfg_database_seqr.get_num_reqs_sent(),
          p_sequencer.reset_vif.asserted), UVM_NONE)
  endtask
endclass
