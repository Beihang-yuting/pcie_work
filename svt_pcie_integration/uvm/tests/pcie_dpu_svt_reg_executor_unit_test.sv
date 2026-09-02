import uvm_pkg::*;
import dpu_resource_pkg::*;
import pcie_topology_pkg::*;
import pcie_dpu_integration_pkg::*;
import pcie_svt_topology_pkg::*;
import pcie_dpu_svt_backend_pkg::*;
`include "uvm_macros.svh"

// This probe removes only the proprietary wire transaction.  Common plan
// ordering, BDF/BAR lookup, masking, and reporting remain production code.
class pcie_dpu_svt_reg_executor_probe extends pcie_dpu_svt_reg_executor;
  `uvm_object_utils(pcie_dpu_svt_reg_executor_probe)

  string observed_kind[$];
  bit [15:0] observed_bdf[$];
  bit [63:0] observed_address[$];
  bit [63:0] observed_data[$];
  bit [63:0] queued_read_data[$];

  function new(string name = "pcie_dpu_svt_reg_executor_probe");
    super.new(name);
  endfunction

  function void queue_read(bit [63:0] data);
    queued_read_data.push_back(data);
  endfunction

  // Expose the production completion policy without starting a proprietary
  // driver.  A posted Memory Write has no Completion TLP, so SVT legitimately
  // leaves completion_status at AWAITED after the request is transmitted.
  function bit completion_is_acceptable(
      bit is_write,
      svt_pcie_driver_app_transaction::completion_status_enum status);
    return memory_completion_is_acceptable(is_write, status);
  endfunction

  protected function void record(
      string kind,
      bit [15:0] bdf,
      bit [63:0] address,
      bit [63:0] data = '0);
    observed_kind.push_back(kind);
    observed_bdf.push_back(bdf);
    observed_address.push_back(address);
    observed_data.push_back(data);
  endfunction

  protected task next_read(
      output bit [63:0] data,
      output bit succeeded,
      output string why);
    if (queued_read_data.size() == 0) begin
      data = '0;
      succeeded = 1'b0;
      why = "SVT probe has no queued read result";
      return;
    end
    data = queued_read_data.pop_front();
    succeeded = 1'b1;
    why = "";
  endtask

  protected virtual task transport_cfg_write(
      bit [15:0] bdf,
      bit [11:0] byte_offset,
      int unsigned width_bytes,
      bit [63:0] data,
      output bit succeeded,
      output string why);
    record("cfg_write", bdf, byte_offset, data);
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
    record("cfg_read", bdf, byte_offset);
    next_read(data, succeeded, why);
  endtask

  protected virtual task transport_mmio_write(
      bit [63:0] bus_address,
      int unsigned width_bytes,
      bit [63:0] data,
      output bit succeeded,
      output string why);
    record("mmio_write", '0, bus_address, data);
    succeeded = 1'b1;
    why = "";
  endtask

  protected virtual task transport_mmio_read(
      bit [63:0] bus_address,
      int unsigned width_bytes,
      output bit [63:0] data,
      output bit succeeded,
      output string why);
    record("mmio_read", '0, bus_address);
    next_read(data, succeeded, why);
  endtask
endclass

class pcie_dpu_svt_reg_executor_unit_test extends uvm_test;
  `uvm_component_utils(pcie_dpu_svt_reg_executor_unit_test)

  pcie_svt_topology_virtual_sequencer topology_vseqr;
  svt_pcie_device_virtual_sequencer rc_seqr;
  svt_pcie_driver_app_transaction_sequencer driver_transaction_seqr;

  function new(string name = "pcie_dpu_svt_reg_executor_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    pcie_svt_port_descriptor descriptor;
    pcie_svt_port_descriptor downstream_descriptor;
    pcie_svt_port_descriptor other_root_descriptor;
    svt_pcie_device_configuration rc_cfg;

    super.build_phase(phase);
    topology_vseqr = new("topology_vseqr", this);
    rc_seqr = new("rc_seqr", this);
    driver_transaction_seqr = new("driver_transaction_seqr", this);

    // A production SVT agent normally supplies this configuration.  This
    // focused unit test constructs the transaction sequencer directly, so it
    // must honor the same sequencer configuration contract before build ends.
    rc_cfg = svt_pcie_device_configuration::type_id::create("rc_cfg");
    driver_transaction_seqr.reconfigure(rc_cfg);
    rc_seqr.driver_transaction_seqr[0] = driver_transaction_seqr;
    descriptor = pcie_svt_port_descriptor::type_id::create("descriptor");
    descriptor.link_id = "RC0_EP0";
    descriptor.role = PCIE_SVT_ROLE_RC;
    descriptor.root_hierarchy = 0;
    topology_vseqr.descriptor_by_link[descriptor.link_id] = descriptor;
    topology_vseqr.seqr_by_link[descriptor.link_id] = rc_seqr;

    // Switch-routed device policy names the downstream physical link, while
    // transactions originate from the RC VIP on the upstream link.  Root
    // hierarchy is the stable association between those two ports.
    downstream_descriptor = pcie_svt_port_descriptor::type_id::create(
      "downstream_descriptor");
    downstream_descriptor.link_id = "SW0_DSP0_EP0";
    downstream_descriptor.role = PCIE_SVT_ROLE_EP;
    downstream_descriptor.root_hierarchy = 0;
    topology_vseqr.descriptor_by_link[downstream_descriptor.link_id] =
      downstream_descriptor;

    other_root_descriptor = pcie_svt_port_descriptor::type_id::create(
      "other_root_descriptor");
    other_root_descriptor.link_id = "SW1_DSP0_EP1";
    other_root_descriptor.role = PCIE_SVT_ROLE_EP;
    other_root_descriptor.root_hierarchy = 1;
    topology_vseqr.descriptor_by_link[other_root_descriptor.link_id] =
      other_root_descriptor;
  endfunction

  function void require(bit condition, string message);
    if (!condition)
      `uvm_error("DPU_SVT_EXECUTOR", message)
  endfunction

  function pcie_global_cfg make_global_cfg(
      string device_link_id = "RC0_EP0");
    pcie_global_cfg cfg;
    pcie_device_cfg device;

    cfg = pcie_global_cfg::type_id::create("global_cfg");
    device = pcie_device_cfg::type_id::create("pf0");
    device.device_id = "EP0.PF0";
    device.link_id = device_link_id;
    device.domain_host_id = 2;
    device.domain_segment_id = 3;
    device.bdf = 16'h2340;
    device.bars[0].implemented = 1'b1;
    device.bars[0].is_64bit = 1'b1;
    device.bars[0].prefetchable = 1'b1;
    device.bars[0].aperture = 64'h0200_0000;
    device.bars[0].initial_base = 64'h0000_0001_0000_0000;
    cfg.devices.push_back(device);
    return cfg;
  endfunction

  function dpu_reg_op make_op(
      string op_id,
      dpu_reg_op_kind_e kind,
      dpu_reg_target_space_e target_space,
      bit [63:0] address);
    dpu_reg_op op;

    op = dpu_reg_op::type_id::create(op_id);
    op.op_id = op_id;
    op.owner = "svt_unit_test";
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
    op.width_bytes = 4;
    return op;
  endfunction

  function dpu_reg_plan make_plan();
    dpu_reg_plan plan;
    dpu_reg_op op;
    string why;

    plan = dpu_reg_plan::type_id::create("svt_plan");
    op = make_op("01.cfg", DPU_REG_OP_PCI_CFG_WRITE,
                 DPU_REG_TARGET_PCI_CONFIG, 64'h0000_0004);
    op.payload = 64'h0000_0000_0000_0006;
    op.write_mask = 64'h0000_0000_ffff_ffff;
    require(plan.add_operation(op, why), {"add cfg op: ", why});

    op = make_op("02.mmio", DPU_REG_OP_MMIO_WRITE,
                 DPU_REG_TARGET_AF_BAR0, 64'h0000_1010);
    op.payload = 64'h0000_0000_a5a5_5a5a;
    op.write_mask = 64'h0000_0000_ffff_ffff;
    op.add_dependency("01.cfg");
    require(plan.add_operation(op, why), {"add MMIO op: ", why});

    op = make_op("03.verify", DPU_REG_OP_READ_VERIFY,
                 DPU_REG_TARGET_AF_BAR0, 64'h0000_1014);
    op.expected_value = 64'h0000_0000_1122_3344;
    op.read_mask = 64'h0000_0000_ffff_ffff;
    op.add_dependency("02.mmio");
    require(plan.add_operation(op, why), {"add verify op: ", why});
    require(plan.freeze(why), {"freeze SVT plan: ", why});
    return plan;
  endfunction

  task check_rejections();
    pcie_dpu_svt_reg_executor executor;
    dpu_reg_plan plan;
    string why;

    plan = make_plan();
    executor = pcie_dpu_svt_reg_executor::type_id::create("reject_exec");
    executor.configure(null, make_global_cfg(), "RC0_EP0");
    require(!executor.preflight(plan, why),
            "SVT executor accepted a null topology sequencer");

    executor.configure(topology_vseqr, make_global_cfg(), "missing_link");
    require(!executor.preflight(plan, why),
            "SVT executor accepted a missing link sequencer");

    executor.configure(topology_vseqr, make_global_cfg("OTHER_LINK"),
                       "RC0_EP0");
    require(!executor.preflight(plan, why),
            "SVT executor accepted a device owned by another physical link");
  endtask

  task check_order_and_resolution();
    pcie_dpu_svt_reg_executor_probe executor;
    dpu_execution_report report;
    dpu_cfg_status_e status;
    dpu_reg_plan plan;
    string why;

    executor = pcie_dpu_svt_reg_executor_probe::type_id::create("svt_exec");
    report = dpu_execution_report::type_id::create("svt_report");
    executor.configure(topology_vseqr, make_global_cfg(),
                       "RC0_EP0", report);
    executor.queue_read(64'h0000_0000_1122_3344);
    plan = make_plan();
    require(executor.preflight(plan, why), {"SVT preflight failed: ", why});
    executor.execute(plan, status);
    executor.export_results(report);

    require(status == DPU_CFG_STATUS_SUCCEEDED,
            {"SVT execution failed: ", executor.last_error()});
    require(executor.observed_kind.size() == 3 &&
            executor.observed_kind[0] == "cfg_write" &&
            executor.observed_kind[1] == "mmio_write" &&
            executor.observed_kind[2] == "mmio_read",
            "SVT executor did not preserve DPU plan ordering");
    require(executor.observed_bdf[0] == 16'h2340 &&
            executor.observed_address[0] == 64'h0000_0004,
            "SVT Configuration target was translated incorrectly");
    require(executor.observed_address[1] == 64'h0000_0001_0000_1010 &&
            executor.observed_address[2] == 64'h0000_0001_0000_1014,
            "SVT MMIO offsets did not use the projected BAR base");
    require(report.result_count() == 3,
            "SVT execution report omitted successful operations");
  endtask

  task check_switch_root_routing();
    pcie_dpu_svt_reg_executor_probe executor;
    dpu_reg_plan plan;
    string why;

    plan = make_plan();
    executor = pcie_dpu_svt_reg_executor_probe::type_id::create(
      "switch_root_exec");
    executor.configure(topology_vseqr, make_global_cfg("SW0_DSP0_EP0"),
                       "RC0_EP0", null, 1'b1);
    require(executor.preflight(plan, why),
            {"switch executor rejected a downstream link in its root: ", why});

    executor.configure(topology_vseqr, make_global_cfg("SW1_DSP0_EP1"),
                       "RC0_EP0", null, 1'b1);
    require(!executor.preflight(plan, why),
            "switch executor accepted a downstream link in another root");
  endtask

  task check_posted_write_completion_policy();
    pcie_dpu_svt_reg_executor_probe executor;

    executor = pcie_dpu_svt_reg_executor_probe::type_id::create(
      "completion_policy_exec");
    require(executor.completion_is_acceptable(
              1'b1, svt_pcie_driver_app_transaction::AWAITED),
            "SVT executor rejected a transmitted posted Memory Write");
    require(!executor.completion_is_acceptable(
              1'b0, svt_pcie_driver_app_transaction::AWAITED),
            "SVT executor accepted a Memory Read without Completion");
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_rejections();
    check_order_and_resolution();
    check_switch_root_routing();
    check_posted_write_completion_policy();
    phase.drop_objection(this);
  endtask
endclass
