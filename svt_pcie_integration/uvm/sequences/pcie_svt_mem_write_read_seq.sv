class pcie_svt_mem_write_read_seq extends
    svt_pcie_driver_app_transaction_base_sequence;
  int unsigned flow_index;
  int unsigned endpoint_index;
  pcie_svt_real_switch_flow_direction_e direction;
  bit [63:0] address;
  bit [15:0] requester_id;
  bit [31:0] expected_payload[4];

  bit completed;
  svt_pcie_driver_app_transaction::completion_status_enum last_status;

  `uvm_object_utils(pcie_svt_mem_write_read_seq)

  function new(string name = "pcie_svt_mem_write_read_seq");
    super.new(name);
    completed = 1'b0;
    last_status = svt_pcie_driver_app_transaction::AWAITED;
  endfunction

  virtual task body();
    svt_configuration sequencer_cfg;
    svt_pcie_device_configuration pcie_cfg;
    svt_pcie_driver_app_transaction write_tran;
    svt_pcie_driver_app_transaction read_tran;

    completed = 1'b0;
    last_status = svt_pcie_driver_app_transaction::AWAITED;
    super.body();

    if (p_sequencer == null)
      `uvm_fatal("REAL_SWITCH_TRAFFIC_CONFIG", $sformatf(
        "flow=%0d Endpoint=%0d has null Driver App transaction sequencer",
        flow_index, endpoint_index))
    p_sequencer.get_cfg(sequencer_cfg);
    if (sequencer_cfg == null)
      `uvm_fatal("REAL_SWITCH_TRAFFIC_CONFIG", $sformatf(
        "flow=%0d Endpoint=%0d Driver App sequencer returned null configuration",
        flow_index, endpoint_index))
    if (!$cast(pcie_cfg, sequencer_cfg))
      `uvm_fatal("REAL_SWITCH_TRAFFIC_CONFIG", $sformatf(
        {"flow=%0d Endpoint=%0d could not cast Driver App configuration ",
         "to svt_pcie_device_configuration"}, flow_index, endpoint_index))

    write_tran = svt_pcie_driver_app_transaction::type_id::create(
      "write_tran");
    if (write_tran == null)
      `uvm_fatal("REAL_SWITCH_TRAFFIC_CONFIG", $sformatf(
        "flow=%0d Endpoint=%0d MEM_WR transaction creation failed",
        flow_index, endpoint_index))
    write_tran.cfg = pcie_cfg;
    write_tran.transaction_type = svt_pcie_driver_app_transaction::MEM_WR;
    write_tran.address = address;
    write_tran.length = 4;
    write_tran.traffic_class = 0;
    write_tran.address_translation = 0;
    write_tran.first_dw_be = 4'hf;
    write_tran.last_dw_be = 4'hf;
    write_tran.requester_id = requester_id;
    write_tran.ep = 0;
    write_tran.block = 1;
    write_tran.payload = new[4];
    foreach (write_tran.payload[i])
      write_tran.payload[i] = expected_payload[i];
    start_item(write_tran);
    finish_item(write_tran);
    get_response(write_tran);

    read_tran = svt_pcie_driver_app_transaction::type_id::create("read_tran");
    if (read_tran == null)
      `uvm_fatal("REAL_SWITCH_TRAFFIC_CONFIG", $sformatf(
        "flow=%0d Endpoint=%0d MEM_RD transaction creation failed",
        flow_index, endpoint_index))
    read_tran.cfg = pcie_cfg;
    read_tran.transaction_type = svt_pcie_driver_app_transaction::MEM_RD;
    read_tran.address = address;
    read_tran.length = 4;
    read_tran.traffic_class = 0;
    read_tran.address_translation = 0;
    read_tran.first_dw_be = 4'hf;
    read_tran.last_dw_be = 4'hf;
    read_tran.requester_id = requester_id;
    read_tran.ep = 0;
    read_tran.block = 1;
    start_item(read_tran);
    finish_item(read_tran);
    get_response(read_tran);

    last_status = read_tran.completion_status;
    if (last_status != svt_pcie_driver_app_transaction::SUCCESSFUL)
      `uvm_fatal("REAL_SWITCH_TRAFFIC_COMPLETION", $sformatf(
        {"flow=%0d direction=%s Endpoint=%0d address=0x%016h ",
         "completion_status=%0d"}, flow_index, direction.name(),
        endpoint_index, address, last_status))
    if (read_tran.payload.size() != 4)
      `uvm_fatal("REAL_SWITCH_TRAFFIC_LENGTH", $sformatf(
        {"flow=%0d direction=%s Endpoint=%0d address=0x%016h ",
         "expected_dwords=4 actual_dwords=%0d"}, flow_index,
        direction.name(), endpoint_index, address, read_tran.payload.size()))
    foreach (expected_payload[i]) begin
      if (read_tran.payload[i] !== expected_payload[i])
        `uvm_fatal("REAL_SWITCH_TRAFFIC_DATA", $sformatf(
          {"flow=%0d direction=%s Endpoint=%0d address=0x%016h ",
           "dword=%0d expected=0x%08h actual=0x%08h"}, flow_index,
          direction.name(), endpoint_index, address, i,
          expected_payload[i], read_tran.payload[i]))
    end

    completed = 1'b1;
    `uvm_info("REAL_SWITCH_TRAFFIC_FLOW_PASS", $sformatf(
      "flow=%0d direction=%s Endpoint=%0d address=0x%016h",
      flow_index, direction.name(), endpoint_index, address), UVM_NONE)
  endtask
endclass
