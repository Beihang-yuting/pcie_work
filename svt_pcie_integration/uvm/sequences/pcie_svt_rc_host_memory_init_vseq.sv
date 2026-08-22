class pcie_svt_rc_host_memory_init_vseq extends
    uvm_sequence #(uvm_sequence_item);
  `uvm_object_utils(pcie_svt_rc_host_memory_init_vseq)
  `uvm_declare_p_sequencer(pcie_svt_virtual_sequencer)

  function new(string name = "pcie_svt_rc_host_memory_init_vseq");
    super.new(name);
  endfunction

  virtual task body();
    svt_pcie_mem_target_service_mem_range_sequence add_range;

    if (p_sequencer == null)
      `uvm_fatal("RC_HOST_MEMORY", "null PCIe SVT virtual sequencer")
    if (!p_sequencer.active_port[PCIE_SVT_PRIMARY_RC0] ||
        (p_sequencer.port_seqr[PCIE_SVT_PRIMARY_RC0] == null))
      `uvm_fatal("RC_HOST_MEMORY",
        "primary RC0 is inactive or has no device virtual sequencer")
    if (p_sequencer.port_seqr[PCIE_SVT_PRIMARY_RC0].mem_target_seqr == null)
      `uvm_fatal("RC_HOST_MEMORY",
        "primary RC0 has no Memory Target service sequencer")
    if (!p_sequencer.try_reserve_rc_host_memory_initialization()) begin
      if (p_sequencer.rc_host_memory_initialized)
        `uvm_fatal("RC_HOST_MEMORY", $sformatf(
          "host-memory range already initialized base=0x%016h limit=0x%016h",
          p_sequencer.rc_host_memory_base,
          p_sequencer.rc_host_memory_limit))
      else
        `uvm_fatal("RC_HOST_MEMORY",
          "host-memory initialization is already in progress")
    end

    add_range =
      svt_pcie_mem_target_service_mem_range_sequence::type_id::create(
        "add_rc_host_memory");
    if (add_range == null)
      `uvm_fatal("RC_HOST_MEMORY", "host-memory service creation failed")
    if (!add_range.randomize() with {
          service_type == svt_pcie_mem_target_service::ADD_MEM_RANGE;
          min_addr == 64'h0000_0002_0000_0000;
          max_addr == 64'h0000_0002_0000_ffff;
          attributes == 32'h0;
        })
      `uvm_fatal("RC_HOST_MEMORY",
        "host-memory service randomization failed")
    add_range.start(
      p_sequencer.port_seqr[PCIE_SVT_PRIMARY_RC0].mem_target_seqr);

    p_sequencer.complete_rc_host_memory_initialization(
      64'h0000_0002_0000_0000, 64'h0000_0002_0000_ffff);
    `uvm_info("RC_HOST_MEMORY_RANGE_READY",
      "base=0x0000000200000000 limit=0x000000020000ffff", UVM_NONE)
  endtask
endclass
