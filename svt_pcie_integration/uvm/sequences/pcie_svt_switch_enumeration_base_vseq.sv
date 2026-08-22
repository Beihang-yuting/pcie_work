class pcie_svt_switch_enumeration_base_vseq extends
    uvm_sequence #(uvm_sequence_item);
  localparam time PCIE_SVT_ENUM_DL_TIMEOUT = 10us;

  `uvm_object_utils(pcie_svt_switch_enumeration_base_vseq)
  `uvm_declare_p_sequencer(pcie_svt_virtual_sequencer)

  svt_pcie_device_virtual_switch_enumeration_sequence enum_seq;

  function new(string name = "pcie_svt_switch_enumeration_base_vseq");
    super.new(name);
  endfunction

  protected virtual task read_config(
      bit [15:0] bdf,
      bit [11:0] byte_offset,
      output bit [31:0] data);
    svt_pcie_driver_app_transaction::completion_status_enum cpl_status;
    enum_seq.send_cfg_rd_w_switch_env(
      bdf[15:8], bdf[7:3], 8'h00, byte_offset, data, 16'h0000,
      4'hf, cpl_status);
    if (cpl_status != svt_pcie_driver_app_transaction::SUCCESSFUL)
      `uvm_fatal("SWITCH_ENUM_CFG_READ", $sformatf(
        "Configuration Read bdf=%04x offset=0x%03x completion_status=%0d",
        bdf, byte_offset, cpl_status))
  endtask

  protected virtual task write_config(
      bit [15:0] bdf,
      bit [11:0] byte_offset,
      bit [31:0] data,
      bit [3:0] first_dw_be = 4'hf);
    svt_pcie_driver_app_transaction::completion_status_enum cpl_status;
    enum_seq.send_cfg_wr_w_switch_env(
      bdf[15:8], bdf[7:3], 8'h00, byte_offset, data, 16'h0000,
      first_dw_be, cpl_status);
    if (cpl_status != svt_pcie_driver_app_transaction::SUCCESSFUL)
      `uvm_fatal("SWITCH_ENUM_CFG_WRITE", $sformatf(
        "Configuration Write bdf=%04x offset=0x%03x completion_status=%0d",
        bdf, byte_offset, cpl_status))
  endtask

  protected task read_bridge(
      pcie_svt_switch_enum_bridge_record bridge);
    bit [31:0] bus_numbers;
    bit [31:0] pref_base_limit;
    bit [31:0] pref_base_upper;
    bit [31:0] pref_limit_upper;
    read_config(bridge.bdf, 12'h018, bus_numbers);
    read_config(bridge.bdf, 12'h024, pref_base_limit);
    read_config(bridge.bdf, 12'h028, pref_base_upper);
    read_config(bridge.bdf, 12'h02c, pref_limit_upper);
    p_sequencer.switch_enum_registry.record_bridge_readback(
      bridge.is_usp, bridge.index, bus_numbers, pref_base_limit,
      pref_base_upper, pref_limit_upper);
  endtask

  protected task read_endpoint_bars(
      pcie_svt_switch_enum_endpoint_record endpoint);
    bit [31:0] low_dword;
    bit [31:0] high_dword;
    for (int unsigned pair = 0; pair < 3; pair++) begin
      int unsigned low_bar;
      low_bar = pair * 2;
      read_config(endpoint.bdf, 12'h010 + (low_bar * 4), low_dword);
      read_config(endpoint.bdf, 12'h010 + ((low_bar + 1) * 4),
                  high_dword);
      p_sequencer.switch_enum_registry.record_bar_readback(
        endpoint.index, pair, low_dword, high_dword);
    end
  endtask

  protected task enable_memory_and_bus_master(bit [15:0] bdf);
    bit [31:0] command_status;
    read_config(bdf, 12'h004, command_status);
    command_status[2:1] = 2'b11;
    write_config(bdf, 12'h004, command_status, 4'b0011);
    read_config(bdf, 12'h004, command_status);
    if (command_status[2:1] !== 2'b11)
      `uvm_fatal("SWITCH_ENUM_COMMAND", $sformatf(
        "bdf=%04x failed to retain Memory Space and Bus Master enables; command=0x%04x",
        bdf, command_status[15:0]))
  endtask

  protected task wait_for_root_dl_up();
    bit reached_dl_up;
    svt_pcie_device_status root_status;

    root_status = p_sequencer.port_status[PCIE_SVT_PRIMARY_RC0];
    if ((root_status == null) || (root_status.pcie_status == null) ||
        (root_status.pcie_status.dl_status == null))
      `uvm_fatal("SWITCH_ENUM_DL",
        "primary RC0 has no Data Link status for enumeration")
    reached_dl_up = 1'b0;
    fork
      begin
        wait (root_status.pcie_status.dl_status.dl_link_up == 1'b1);
        reached_dl_up = 1'b1;
      end
      begin
        #PCIE_SVT_ENUM_DL_TIMEOUT;
      end
    join_any
    disable fork;
    if (!reached_dl_up)
      `uvm_fatal("SWITCH_ENUM_DL", $sformatf(
        "primary RC0 Data Link did not reach DL_Up within %0t",
        PCIE_SVT_ENUM_DL_TIMEOUT))
  endtask

  protected virtual task before_official_enumeration();
  endtask

  protected virtual task after_official_enumeration();
  endtask

  protected virtual function void report_success();
  endfunction

  virtual task body();
    pcie_svt_switch_enum_registry registry;
    if (p_sequencer == null)
      `uvm_fatal("SWITCH_ENUM", "null integration virtual sequencer")
    if ((p_sequencer.port_seqr[PCIE_SVT_PRIMARY_RC0] == null) ||
        !p_sequencer.active_port[PCIE_SVT_PRIMARY_RC0] ||
        p_sequencer.switch_proxy_port[PCIE_SVT_PRIMARY_RC0])
      `uvm_fatal("SWITCH_ENUM",
        "primary RC0 is not an active non-Proxy enumeration initiator")
    registry = p_sequencer.switch_enum_registry;
    if (registry == null)
      `uvm_fatal("SWITCH_ENUM", "null switch enumeration registry")

    before_official_enumeration();
    wait_for_root_dl_up();

    enum_seq =
      svt_pcie_device_virtual_switch_enumeration_sequence::type_id::create(
        "enum_seq");
    if (enum_seq == null)
      `uvm_fatal("SWITCH_ENUM",
        "official switch enumeration sequence creation failed")
    enum_seq.set_sequencer(
      p_sequencer.port_seqr[PCIE_SVT_PRIMARY_RC0]);
    if (!enum_seq.randomize() with {
          switch_parms.root_hierarchy == 0;
          switch_parms.enumerate_device_beneath_dsp == 1'b1;
          switch_parms.max_sw_dsp_device_number == 3;
          switch_parms.root_port_sec_bus_num == 8'h01;
          switch_parms.sw_usp_dev_num == 5'h00;
          switch_parms.sys_pref_mem_base_addr ==
            64'h0000_0001_0000_0000;
          switch_parms.sys_pref_mem_limit_addr ==
            64'h0000_0001_7fff_ffff;
        })
      `uvm_fatal("SWITCH_ENUM", "enumeration controls failed to randomize")

    enum_seq.start(p_sequencer.port_seqr[PCIE_SVT_PRIMARY_RC0]);
    if (enum_seq.switch_enumeration_status == null)
      `uvm_fatal("SWITCH_ENUM", "official sequence returned null status")

    registry.load_from_status(enum_seq.switch_enumeration_status);
    read_bridge(registry.usp);
    foreach (registry.dsps[i])
      read_bridge(registry.dsps[i]);
    foreach (registry.endpoints[i])
      read_endpoint_bars(registry.endpoints[i]);
    registry.finalize_and_validate();

    enable_memory_and_bus_master(registry.usp.bdf);
    foreach (registry.dsps[i])
      enable_memory_and_bus_master(registry.dsps[i].bdf);
    foreach (registry.endpoints[i])
      enable_memory_and_bus_master(registry.endpoints[i].bdf);

    after_official_enumeration();
    registry.report_discovery();
    report_success();
  endtask
endclass
