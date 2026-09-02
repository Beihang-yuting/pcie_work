import uvm_pkg::*;
import dpu_resource_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
import pcie_dpu_integration_pkg::*;
import pcie_dpu_tl_backend_pkg::*;
`include "uvm_macros.svh"

// A clockless responder exercises the real TL Configuration sequences without
// requiring a complete link agent.  It behaves like a single Function's
// Configuration Space and folds Completions onto the original request object.
class pcie_dpu_tl_config_responder extends uvm_driver #(pcie_tl_tlp);
  `uvm_component_utils(pcie_dpu_tl_config_responder)

  bit [31:0] config_dwords[bit [9:0]];

  function new(string name = "pcie_dpu_tl_config_responder",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      pcie_tl_tlp request;
      pcie_tl_cfg_tlp cfg_request;
      bit [31:0] value;

      seq_item_port.get_next_item(request);
      if (!$cast(cfg_request, request)) begin
        `uvm_error("DPU_TL_RESPONDER", "received a non-Configuration TLP")
        seq_item_port.item_done();
        continue;
      end

      value = config_dwords.exists(cfg_request.reg_num) ?
              config_dwords[cfg_request.reg_num] : '0;
      if (cfg_request.kind inside {TLP_CFG_WR0, TLP_CFG_WR1}) begin
        for (int unsigned byte_index = 0; byte_index < 4; byte_index++) begin
          if (cfg_request.first_be[byte_index] &&
              (byte_index < cfg_request.payload.size()))
            value[byte_index * 8 +: 8] = cfg_request.payload[byte_index];
        end
        config_dwords[cfg_request.reg_num] = value;
      end else begin
        request.rb_data.delete();
        for (int unsigned byte_index = 0; byte_index < 4; byte_index++)
          request.rb_data.push_back(value[byte_index * 8 +: 8]);
      end

      request.rb_status = CPL_STATUS_SC;
      request.rb_done = 1'b1;
      seq_item_port.item_done();
    end
  endtask
endclass

// The probe replaces only the external TL transport.  Plan validation,
// address resolution, dependency ordering, masking, and result reporting all
// execute in the production executor base class.
class pcie_dpu_tl_reg_executor_probe extends pcie_dpu_tl_reg_executor;
  `uvm_object_utils(pcie_dpu_tl_reg_executor_probe)

  string observed_kind[$];
  bit [15:0] observed_bdf[$];
  bit [63:0] observed_address[$];
  bit [63:0] observed_data[$];
  int unsigned observed_width[$];
  bit [63:0] queued_read_data[$];

  function new(string name = "pcie_dpu_tl_reg_executor_probe");
    super.new(name);
  endfunction

  function void clear_observations();
    observed_kind.delete();
    observed_bdf.delete();
    observed_address.delete();
    observed_data.delete();
    observed_width.delete();
    queued_read_data.delete();
  endfunction

  function void queue_read(bit [63:0] data);
    queued_read_data.push_back(data);
  endfunction

  protected function void record(
      string kind,
      bit [15:0] bdf,
      bit [63:0] address,
      int unsigned width_bytes,
      bit [63:0] data = '0);
    observed_kind.push_back(kind);
    observed_bdf.push_back(bdf);
    observed_address.push_back(address);
    observed_width.push_back(width_bytes);
    observed_data.push_back(data);
  endfunction

  protected virtual task transport_cfg_write(
      bit [15:0] bdf,
      bit [11:0] byte_offset,
      int unsigned width_bytes,
      bit [63:0] data,
      output bit succeeded,
      output string why);
    record("cfg_write", bdf, byte_offset, width_bytes, data);
    succeeded = 1'b1;
    why = "";
  endtask

  protected virtual task transport_cfg_read(
      bit [15:0] bdf,
      bit [11:0] byte_offset,
      int unsigned width_bytes,
      output bit [63:0] data,
      output bit succeeded,
      output string why);
    record("cfg_read", bdf, byte_offset, width_bytes);
    if (queued_read_data.size() == 0) begin
      data = '0;
      succeeded = 1'b0;
      why = "probe has no queued Configuration Read result";
      return;
    end
    data = queued_read_data.pop_front();
    succeeded = 1'b1;
    why = "";
  endtask

  protected virtual task transport_mmio_write(
      bit [63:0] bus_address,
      int unsigned width_bytes,
      bit [63:0] data,
      output bit succeeded,
      output string why);
    record("mmio_write", '0, bus_address, width_bytes, data);
    succeeded = 1'b1;
    why = "";
  endtask

  protected virtual task transport_mmio_read(
      bit [63:0] bus_address,
      int unsigned width_bytes,
      output bit [63:0] data,
      output bit succeeded,
      output string why);
    record("mmio_read", '0, bus_address, width_bytes);
    if (queued_read_data.size() == 0) begin
      data = '0;
      succeeded = 1'b0;
      why = "probe has no queued Memory Read result";
      return;
    end
    data = queued_read_data.pop_front();
    succeeded = 1'b1;
    why = "";
  endtask
endclass

class pcie_dpu_tl_reg_executor_unit_test extends uvm_test;
  `uvm_component_utils(pcie_dpu_tl_reg_executor_unit_test)

  pcie_tl_virtual_sequencer vseqr;
  uvm_sequencer #(pcie_tl_tlp) rc_seqr;
  pcie_dpu_tl_config_responder responder;

  function new(string name = "pcie_dpu_tl_reg_executor_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // A concrete RC sequencer satisfies backend readiness.  The probe keeps
    // this focused contract test independent of a clocked TL driver.
    vseqr = new("vseqr", this);
    rc_seqr = new("rc_seqr", this);
    responder = pcie_dpu_tl_config_responder::type_id::create(
      "responder", this);
    vseqr.rc_seqr = rc_seqr;
    vseqr.rc_seqr_arr.push_back(rc_seqr);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    responder.seq_item_port.connect(rc_seqr.seq_item_export);
  endfunction

  function void require(bit condition, string message);
    if (!condition)
      `uvm_error("DPU_TL_EXECUTOR", message)
  endfunction

  function dpu_reg_op make_op(
      string op_id,
      dpu_reg_op_kind_e kind,
      dpu_reg_target_space_e target_space,
      bit [63:0] address,
      int unsigned width_bytes);
    dpu_reg_op op;

    op = dpu_reg_op::type_id::create(op_id);
    op.op_id = op_id;
    op.owner = "unit_test";
    op.kind = kind;
    op.target_space = target_space;
    op.target_scope = DPU_REG_SCOPE_SINGLE;
    op.phase = DPU_REG_PHASE_BOOTSTRAP;
    op.host_id = 2;
    op.segment_id = 3;
    op.bdf_valid = 1'b1;
    op.bdf = 16'h2340;
    op.bar_id = 0;
    op.target_block = "pf0";
    op.address = address;
    op.width_bytes = width_bytes;
    return op;
  endfunction

  function pcie_global_cfg make_global_cfg(bit implement_bar = 1'b1);
    pcie_global_cfg cfg;
    pcie_device_cfg device;

    cfg = pcie_global_cfg::type_id::create("global_cfg");
    device = pcie_device_cfg::type_id::create("pf0");
    device.device_id = "EP0.PF0";
    device.domain_host_id = 2;
    device.domain_segment_id = 3;
    device.bdf = 16'h2340;
    device.bars[0].implemented = implement_bar;
    device.bars[0].is_64bit = 1'b1;
    device.bars[0].prefetchable = 1'b1;
    device.bars[0].aperture = 64'h0200_0000;
    device.bars[0].initial_base = 64'h0000_0001_0000_0000;
    cfg.devices.push_back(device);
    return cfg;
  endfunction

  function dpu_reg_plan make_ordered_plan();
    dpu_reg_plan plan;
    dpu_reg_op op;
    string why;

    plan = dpu_reg_plan::type_id::create("ordered_plan");

    op = make_op("01.cfg", DPU_REG_OP_PCI_CFG_WRITE,
                 DPU_REG_TARGET_PCI_CONFIG, 64'h0000_0004, 4);
    op.payload = 64'h0000_0000_0000_0006;
    op.write_mask = 64'h0000_0000_ffff_ffff;
    require(plan.add_operation(op, why), {"add cfg op: ", why});

    op = make_op("02.mmio", DPU_REG_OP_MMIO_WRITE,
                 DPU_REG_TARGET_AF_BAR0, 64'h0000_1010, 4);
    op.payload = 64'h0000_0000_a5a5_5a5a;
    op.write_mask = 64'h0000_0000_ffff_ffff;
    op.add_dependency("01.cfg");
    require(plan.add_operation(op, why), {"add MMIO op: ", why});

    op = make_op("03.verify", DPU_REG_OP_READ_VERIFY,
                 DPU_REG_TARGET_AF_BAR0, 64'h0000_1014, 4);
    op.expected_value = 64'h0000_0000_1122_3344;
    op.read_mask = 64'h0000_0000_ffff_ffff;
    op.add_dependency("02.mmio");
    require(plan.add_operation(op, why), {"add read op: ", why});

    require(plan.freeze(why), {"freeze ordered plan: ", why});
    return plan;
  endfunction

  function dpu_reg_plan make_read_plan(bit [63:0] expected_value);
    dpu_reg_plan plan;
    dpu_reg_op op;
    string why;

    plan = dpu_reg_plan::type_id::create("read_plan");
    op = make_op("verify", DPU_REG_OP_READ_VERIFY,
                 DPU_REG_TARGET_AF_BAR0, 64'h0000_0040, 4);
    op.expected_value = expected_value;
    op.read_mask = 64'h0000_0000_ffff_ffff;
    require(plan.add_operation(op, why), {"add read op: ", why});
    require(plan.freeze(why), {"freeze read plan: ", why});
    return plan;
  endfunction

  function dpu_reg_plan make_partial_write_plan();
    dpu_reg_plan plan;
    dpu_reg_op op;
    string why;

    plan = dpu_reg_plan::type_id::create("partial_write_plan");
    op = make_op("rmw", DPU_REG_OP_MMIO_WRITE,
                 DPU_REG_TARGET_AF_BAR0, 64'h0000_0080, 4);
    op.payload = 64'h0000_0000_0000_aa00;
    op.write_mask = 64'h0000_0000_0000_ff00;
    require(plan.add_operation(op, why), {"add RMW op: ", why});
    require(plan.freeze(why), {"freeze RMW plan: ", why});
    return plan;
  endfunction

  function dpu_reg_plan make_config_roundtrip_plan();
    dpu_reg_plan plan;
    dpu_reg_op op;
    string why;

    plan = dpu_reg_plan::type_id::create("config_roundtrip_plan");
    op = make_op("cfg.write", DPU_REG_OP_PCI_CFG_WRITE,
                 DPU_REG_TARGET_PCI_CONFIG, 64'h0000_0044, 4);
    op.payload = 64'h0000_0000_cafe_babe;
    op.write_mask = 64'h0000_0000_ffff_ffff;
    require(plan.add_operation(op, why), {"add config write: ", why});

    op = make_op("cfg.verify", DPU_REG_OP_READ_VERIFY,
                 DPU_REG_TARGET_PCI_CONFIG, 64'h0000_0044, 4);
    op.expected_value = 64'h0000_0000_cafe_babe;
    op.read_mask = 64'h0000_0000_ffff_ffff;
    op.add_dependency("cfg.write");
    require(plan.add_operation(op, why), {"add config verify: ", why});
    require(plan.freeze(why), {"freeze config roundtrip plan: ", why});
    return plan;
  endfunction

  task check_preflight_rejections();
    pcie_dpu_tl_reg_executor executor;
    dpu_reg_plan plan;
    string why;

    executor = pcie_dpu_tl_reg_executor::type_id::create("reject_executor");
    executor.configure(null, make_global_cfg(), null, 0);
    require(!executor.preflight(null, why), "null plan was accepted");

    plan = dpu_reg_plan::type_id::create("unfrozen_plan");
    require(!executor.preflight(plan, why), "unfrozen plan was accepted");

    plan = make_ordered_plan();
    require(!executor.preflight(plan, why),
            "executor without an RC sequencer was accepted");

    executor.configure(vseqr, make_global_cfg(1'b0), null, 0);
    require(!executor.preflight(plan, why),
            "operation targeting an unimplemented BAR was accepted");
  endtask

  task check_order_and_address_resolution();
    pcie_dpu_tl_reg_executor_probe executor;
    dpu_execution_report report;
    dpu_reg_op_result_e result;
    dpu_cfg_status_e status;
    dpu_reg_plan plan;
    string op_id;
    string why;

    executor = pcie_dpu_tl_reg_executor_probe::type_id::create("ordered_exec");
    report = dpu_execution_report::type_id::create("ordered_report");
    executor.configure(vseqr, make_global_cfg(), report, 0);
    plan = make_ordered_plan();
    executor.queue_read(64'h0000_0000_1122_3344);

    require(executor.preflight(plan, why), {"preflight failed: ", why});
    executor.execute(plan, status);
    executor.export_results(report);

    require(status == DPU_CFG_STATUS_SUCCEEDED,
            {"ordered execution failed: ", executor.last_error()});
    require(executor.observed_kind.size() == 3,
            "ordered plan did not issue exactly three transports");
    require(executor.observed_kind[0] == "cfg_write" &&
            executor.observed_kind[1] == "mmio_write" &&
            executor.observed_kind[2] == "mmio_read",
            "executor did not preserve dependency order");
    require(executor.observed_bdf[0] == 16'h2340 &&
            executor.observed_address[0] == 64'h0000_0004,
            "Configuration Write target was translated incorrectly");
    require(executor.observed_address[1] == 64'h0000_0001_0000_1010 &&
            executor.observed_address[2] == 64'h0000_0001_0000_1014,
            "MMIO offsets were not resolved against the DPU-owned BAR base");
    require(report.result_count() == 3,
            "successful report does not contain every operation");
    for (int unsigned i = 0; i < 3; i++) begin
      require(report.result_at(i, op_id, result, why),
              {"read report result: ", why});
      require(result == DPU_REG_OP_RESULT_SUCCEEDED,
              $sformatf("report result %0d was not successful", i));
    end
  endtask

  task check_masked_write_and_mismatch();
    pcie_dpu_tl_reg_executor_probe executor;
    dpu_execution_report report;
    dpu_reg_op_result_e result;
    dpu_cfg_status_e status;
    dpu_reg_plan plan;
    string op_id;
    string why;

    executor = pcie_dpu_tl_reg_executor_probe::type_id::create("masked_exec");
    executor.configure(vseqr, make_global_cfg(), null, 0);
    plan = make_partial_write_plan();
    executor.queue_read(64'h0000_0000_1234_5678);
    require(executor.preflight(plan, why), {"RMW preflight failed: ", why});
    executor.execute(plan, status);
    require(status == DPU_CFG_STATUS_SUCCEEDED,
            {"RMW execution failed: ", executor.last_error()});
    require(executor.observed_kind.size() == 2 &&
            executor.observed_kind[0] == "mmio_read" &&
            executor.observed_kind[1] == "mmio_write",
            "partial write did not use read-modify-write");
    require(executor.observed_data[1] == 64'h0000_0000_1234_aa78,
            "partial write merged payload with the wrong bit mask");

    executor.clear_observations();
    report = dpu_execution_report::type_id::create("mismatch_report");
    executor.configure(vseqr, make_global_cfg(), report, 0);
    plan = make_read_plan(64'h0000_0000_dead_beef);
    executor.queue_read(64'h0000_0000_dead_beee);
    require(executor.preflight(plan, why),
            {"mismatch preflight failed: ", why});
    executor.execute(plan, status);
    executor.export_results(report);
    require(status == DPU_CFG_STATUS_EXECUTION_FAILED,
            "readback mismatch was reported as success");
    require(report.result_count() == 1 &&
            report.result_at(0, op_id, result, why) &&
            result == DPU_REG_OP_RESULT_FAILED,
            "readback mismatch was not recorded as a failed operation");
  endtask

  task check_real_tl_config_transport();
    pcie_dpu_tl_reg_executor executor;
    dpu_cfg_status_e status;
    dpu_reg_plan plan;
    string why;

    executor = pcie_dpu_tl_reg_executor::type_id::create("real_tl_exec");
    executor.configure(vseqr, make_global_cfg(), null, 0);
    plan = make_config_roundtrip_plan();
    require(executor.preflight(plan, why),
            {"real TL preflight failed: ", why});
    executor.execute(plan, status);
    require(status == DPU_CFG_STATUS_SUCCEEDED,
            {"real TL Configuration roundtrip failed: ",
             executor.last_error()});
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_preflight_rejections();
    check_order_and_address_resolution();
    check_masked_write_and_mismatch();
    check_real_tl_config_transport();
    phase.drop_objection(this);
  endtask
endclass
