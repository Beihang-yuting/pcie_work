//------------------------------------------------------------------------------
// Backend-neutral execution contract for frozen DPU register plans.
//
// This class owns validation, dependency-ordered dispatch, BDF/BAR address
// resolution, masked writes, polling, and result reporting.  Protocol adapters
// implement only the four transport hooks at the bottom of the class.
//------------------------------------------------------------------------------

virtual class pcie_dpu_reg_executor_base extends dpu_reg_executor;
  protected pcie_global_cfg global_cfg;
  protected dpu_execution_report configured_report;

  protected string result_operation_ids[$];
  protected dpu_reg_op_result_e result_values[$];

  protected dpu_reg_plan authorized_plan;
  protected bit execution_authorized;

  function new(string name = "pcie_dpu_reg_executor_base");
    super.new(name);
    reset_execution_state();
  endfunction

  // Derived configure() methods call this after recording their sequencer.
  // Reconfiguration invalidates any earlier preflight authorization.
  protected function void configure_common(
      pcie_global_cfg new_global_cfg,
      dpu_execution_report new_report = null);
    global_cfg = new_global_cfg;
    configured_report = new_report;
    reset_execution_state();
  endfunction

  protected function void reset_execution_state();
    result_operation_ids.delete();
    result_values.delete();
    authorized_plan = null;
    execution_authorized = 1'b0;
    set_last_error("");
  endfunction

  protected function bit [63:0] access_mask(int unsigned width_bytes);
    case (width_bytes)
      1: return 64'h0000_0000_0000_00ff;
      2: return 64'h0000_0000_0000_ffff;
      4: return 64'h0000_0000_ffff_ffff;
      8: return 64'hffff_ffff_ffff_ffff;
      default: return '0;
    endcase
  endfunction

  // DPU snapshots preserve a domain-qualified BDF.  Every operation must
  // resolve to exactly one projected PCIe device; accepting only the 16-bit
  // BDF would route identical requester IDs in different roots incorrectly.
  protected function bit find_target_device(
      dpu_reg_op operation,
      output pcie_device_cfg device,
      output string why);
    int unsigned match_count;

    device = null;
    why = "";
    match_count = 0;
    if (global_cfg == null) begin
      why = "PCIe global configuration is null";
      return 1'b0;
    end

    foreach (global_cfg.devices[index]) begin
      pcie_device_cfg candidate;

      candidate = global_cfg.devices[index];
      if ((candidate == null) ||
          (candidate.domain_host_id != operation.host_id) ||
          (candidate.domain_segment_id != operation.segment_id) ||
          (candidate.bdf != operation.bdf))
        continue;

      device = candidate;
      match_count++;
    end

    if (match_count == 0) begin
      why = $sformatf(
        {"operation %s cannot resolve host=%0d segment=%0d BDF=%04x ",
         "in projected PCIe policy"},
        operation.op_id, operation.host_id, operation.segment_id,
        operation.bdf);
      return 1'b0;
    end
    if (match_count != 1) begin
      why = $sformatf(
        {"operation %s resolves to %0d devices for host=%0d segment=%0d ",
         "BDF=%04x"},
        operation.op_id, match_count, operation.host_id,
        operation.segment_id, operation.bdf);
      device = null;
      return 1'b0;
    end
    return 1'b1;
  endfunction

  // Config-space addresses remain byte offsets.  MMIO addresses are offsets
  // in the frozen DPU plan and become bus addresses only after adding the
  // corresponding DPU-owned BAR base.
  protected function bit resolve_operation_target(
      dpu_reg_op operation,
      output pcie_device_cfg device,
      output bit [63:0] resolved_address,
      output string why);
    int unsigned bar_id;
    bit [63:0] access_end;

    resolved_address = '0;
    if (!find_target_device(operation, device, why))
      return 1'b0;

    if (operation.target_space == DPU_REG_TARGET_PCI_CONFIG) begin
      resolved_address = operation.address;
      return 1'b1;
    end

    if (operation.target_space == DPU_REG_TARGET_AF_BAR0)
      bar_id = 0;
    else if (operation.target_space == DPU_REG_TARGET_FUNCTION_BAR)
      bar_id = operation.bar_id;
    else begin
      why = $sformatf("operation %s has unsupported target space %0d",
                      operation.op_id, operation.target_space);
      return 1'b0;
    end

    if ((bar_id > 5) || (device.bars[bar_id] == null) ||
        !device.bars[bar_id].implemented) begin
      why = $sformatf(
        "operation %s targets unimplemented BAR%0d on device %s",
        operation.op_id, bar_id, device.device_id);
      return 1'b0;
    end

    access_end = operation.address + operation.width_bytes;
    if ((access_end < operation.address) ||
        (access_end > device.bars[bar_id].aperture)) begin
      why = $sformatf(
        {"operation %s range offset=0x%0h width=%0d exceeds BAR%0d ",
         "aperture=0x%0h"},
        operation.op_id, operation.address, operation.width_bytes,
        bar_id, device.bars[bar_id].aperture);
      return 1'b0;
    end

    resolved_address = device.bars[bar_id].initial_base + operation.address;
    if (resolved_address < device.bars[bar_id].initial_base) begin
      why = $sformatf("operation %s BAR address addition overflowed",
                      operation.op_id);
      return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function bit operation_is_supported(
      dpu_reg_op operation,
      output string why);
    pcie_device_cfg device;
    bit [63:0] ignored_address;

    why = "";
    if (operation == null) begin
      why = "register plan contains a null operation";
      return 1'b0;
    end

    if (operation.kind == DPU_REG_OP_BARRIER)
      return 1'b1;
    if (!(operation.kind inside {
          DPU_REG_OP_PCI_CFG_WRITE,
          DPU_REG_OP_MMIO_WRITE,
          DPU_REG_OP_READ_VERIFY,
          DPU_REG_OP_POLL_UNTIL,
          DPU_REG_OP_COMMIT})) begin
      why = $sformatf("operation %s has unsupported kind %0d",
                      operation.op_id, operation.kind);
      return 1'b0;
    end
    if (!resolve_operation_target(
          operation, device, ignored_address, why))
      return 1'b0;
    return backend_accepts_device(operation, device, why);
  endfunction

  virtual function bit preflight(
      dpu_reg_plan plan,
      output string why);
    dpu_reg_op ordered[$];

    reset_execution_state();
    why = "";
    if (plan == null) begin
      why = "PCIe DPU executor received a null register plan";
      set_last_error(why);
      return 1'b0;
    end
    if (!plan.is_frozen()) begin
      why = "PCIe DPU executor requires a frozen register plan";
      set_last_error(why);
      return 1'b0;
    end
    if (!backend_ready(why)) begin
      if (why == "")
        why = "PCIe DPU backend is not ready";
      set_last_error(why);
      return 1'b0;
    end
    if (!plan.ordered_operations(ordered, why)) begin
      set_last_error(why);
      return 1'b0;
    end
    foreach (ordered[index]) begin
      if (!operation_is_supported(ordered[index], why)) begin
        set_last_error(why);
        return 1'b0;
      end
    end

    authorized_plan = plan;
    execution_authorized = 1'b1;
    return 1'b1;
  endfunction

  protected task read_operation(
      dpu_reg_op operation,
      bit [63:0] resolved_address,
      output bit [63:0] data,
      output bit succeeded,
      output string why);
    if (operation.target_space == DPU_REG_TARGET_PCI_CONFIG) begin
      transport_cfg_read(operation.bdf, resolved_address[11:0],
                         operation.width_bytes, data, succeeded, why);
    end else begin
      transport_mmio_read(resolved_address, operation.width_bytes,
                          data, succeeded, why);
    end
  endtask

  protected task write_operation(
      dpu_reg_op operation,
      bit [63:0] resolved_address,
      bit [63:0] data,
      output bit succeeded,
      output string why);
    if (operation.target_space == DPU_REG_TARGET_PCI_CONFIG) begin
      transport_cfg_write(operation.bdf, resolved_address[11:0],
                          operation.width_bytes, data, succeeded, why);
    end else begin
      transport_mmio_write(resolved_address, operation.width_bytes,
                           data, succeeded, why);
    end
  endtask

  protected task execute_write(
      dpu_reg_op operation,
      bit [63:0] resolved_address,
      output bit succeeded,
      output string why);
    bit [63:0] full_mask;
    bit [63:0] current_value;
    bit [63:0] write_value;

    full_mask = access_mask(operation.width_bytes);
    current_value = '0;
    if (operation.write_mask != full_mask) begin
      read_operation(operation, resolved_address, current_value,
                     succeeded, why);
      if (!succeeded)
        return;
    end

    write_value = (current_value & ~operation.write_mask) |
                  (operation.payload & operation.write_mask);
    write_value &= full_mask;
    write_operation(operation, resolved_address, write_value,
                    succeeded, why);
  endtask

  protected task execute_read_check(
      dpu_reg_op operation,
      bit [63:0] resolved_address,
      output bit succeeded,
      output string why);
    int unsigned attempt_count;
    bit [63:0] read_value;

    attempt_count = (operation.kind == DPU_REG_OP_POLL_UNTIL) ?
                    operation.max_attempts : 1;
    for (int unsigned attempt = 0; attempt < attempt_count; attempt++) begin
      read_operation(operation, resolved_address, read_value,
                     succeeded, why);
      if (!succeeded)
        return;

      if (((read_value ^ operation.expected_value) &
           operation.read_mask) == 0) begin
        succeeded = 1'b1;
        why = "";
        return;
      end

      if ((operation.kind == DPU_REG_OP_POLL_UNTIL) &&
          ((attempt + 1) < attempt_count))
        #(operation.retry_interval);
    end

    succeeded = 1'b0;
    why = $sformatf(
      {"operation %s readback mismatch: expected=0x%016h mask=0x%016h ",
       "actual=0x%016h"},
      operation.op_id, operation.expected_value,
      operation.read_mask, read_value);
  endtask

  protected task execute_one(
      dpu_reg_op operation,
      output bit succeeded,
      output string why);
    pcie_device_cfg ignored_device;
    bit [63:0] resolved_address;

    succeeded = 1'b0;
    why = "";
    if (operation.kind == DPU_REG_OP_BARRIER) begin
      succeeded = 1'b1;
      return;
    end
    if (!resolve_operation_target(
          operation, ignored_device, resolved_address, why))
      return;

    case (operation.kind)
      DPU_REG_OP_PCI_CFG_WRITE,
      DPU_REG_OP_MMIO_WRITE,
      DPU_REG_OP_COMMIT:
        execute_write(operation, resolved_address, succeeded, why);

      DPU_REG_OP_READ_VERIFY,
      DPU_REG_OP_POLL_UNTIL:
        execute_read_check(operation, resolved_address, succeeded, why);

      default: begin
        why = $sformatf("operation %s has unsupported kind %0d",
                        operation.op_id, operation.kind);
        succeeded = 1'b0;
      end
    endcase
  endtask

  protected function void update_configured_report(
      dpu_cfg_status_e status);
    if (configured_report == null)
      return;

    export_results(configured_report);
    configured_report.set_terminal(
      status, (status == DPU_CFG_STATUS_SUCCEEDED) ? "" : last_error());
  endfunction

  virtual task execute(
      dpu_reg_plan plan,
      output dpu_cfg_status_e status);
    dpu_reg_op ordered[$];
    bit succeeded;
    string why;

    status = DPU_CFG_STATUS_EXECUTION_FAILED;
    if (!execution_authorized || (authorized_plan == null)) begin
      set_last_error("PCIe DPU executor execute called before preflight");
      update_configured_report(status);
      return;
    end
    if (plan != authorized_plan) begin
      set_last_error(
        "PCIe DPU executor execute plan does not match preflight plan");
      execution_authorized = 1'b0;
      authorized_plan = null;
      update_configured_report(status);
      return;
    end

    execution_authorized = 1'b0;
    authorized_plan = null;
    if (!plan.ordered_operations(ordered, why)) begin
      set_last_error(why);
      update_configured_report(status);
      return;
    end

    foreach (ordered[index]) begin
      execute_one(ordered[index], succeeded, why);
      result_operation_ids.push_back(ordered[index].op_id);
      result_values.push_back(succeeded ? DPU_REG_OP_RESULT_SUCCEEDED :
                                         DPU_REG_OP_RESULT_FAILED);
      if (!succeeded) begin
        if (why == "")
          why = $sformatf("operation %s failed", ordered[index].op_id);
        set_last_error(why);
        update_configured_report(status);
        return;
      end
    end

    status = DPU_CFG_STATUS_SUCCEEDED;
    set_last_error("");
    update_configured_report(status);
  endtask

  virtual function void export_results(dpu_execution_report report);
    if (report == null)
      return;

    report.clear_results();
    foreach (result_operation_ids[index])
      report.append_result(result_operation_ids[index], result_values[index]);
  endfunction

  // Protocol-specific classes must reject a missing or invalid RC sequencer
  // during preflight, before any operation has a visible transport side effect.
  pure virtual protected function bit backend_ready(output string why);

  // Single-root adapters accept every resolved device by default.  A backend
  // that selects a physical link may tighten ownership without duplicating
  // the common BDF/BAR lookup.
  protected virtual function bit backend_accepts_device(
      dpu_reg_op operation,
      pcie_device_cfg device,
      output string why);
    why = "";
    return 1'b1;
  endfunction

  pure virtual protected task transport_cfg_write(
      bit [15:0] bdf,
      bit [11:0] byte_offset,
      int unsigned width_bytes,
      bit [63:0] data,
      output bit succeeded,
      output string why);

  pure virtual protected task transport_cfg_read(
      bit [15:0] bdf,
      bit [11:0] byte_offset,
      int unsigned width_bytes,
      output bit [63:0] data,
      output bit succeeded,
      output string why);

  pure virtual protected task transport_mmio_write(
      bit [63:0] bus_address,
      int unsigned width_bytes,
      bit [63:0] data,
      output bit succeeded,
      output string why);

  pure virtual protected task transport_mmio_read(
      bit [63:0] bus_address,
      int unsigned width_bytes,
      output bit [63:0] data,
      output bit succeeded,
      output string why);
endclass : pcie_dpu_reg_executor_base
