import uvm_pkg::*;
import dpu_resource_pkg::*;
import pcie_topology_pkg::*;
import pcie_dpu_integration_pkg::*;
import pcie_svt_topology_pkg::*;
import pcie_dpu_system_pkg::*;
`include "uvm_macros.svh"

// Single-function x16 integration example.  The profile owns all authoring
// values; changing +PCIE_BACKEND selects transport without rebuilding DPU
// identity, BDF, BAR, or placement inputs.
class pcie_dpu_ep_x16_test extends pcie_dpu_device_base_test;
  `uvm_component_utils(pcie_dpu_ep_x16_test)

  function new(string name = "pcie_dpu_ep_x16_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_system_cfg();
    string why;

    if (!pcie_dpu_ep_x16_profile::populate(system_cfg, why))
      `uvm_fatal("DPU_EP_X16", {"profile construction failed: ", why})
  endfunction

  virtual function void end_of_elaboration_phase(uvm_phase phase);
    dpu_spy_reg_executor controlled_executor;

    super.end_of_elaboration_phase(phase);
    if ((system_env == null) || (system_env.global_cfg == null) ||
        (system_env.device_snapshot == null) ||
        !system_env.device_snapshot.is_frozen()) begin
      `uvm_fatal("DPU_EP_X16",
        "system environment did not publish projected frozen state")
      return;
    end
    if ((system_env.global_cfg.topology.links.size() != 1) ||
        (system_env.global_cfg.topology.links[0].link_width != 16) ||
        (system_env.global_cfg.devices[1].bdf != 16'h0100) ||
        (system_env.global_cfg.devices[1].bars[0].initial_base !=
          64'h0000_0001_0000_0000))
      `uvm_fatal("DPU_EP_X16",
        "projected EP x16 topology/BDF/BAR contract is incorrect")
    if ($test$plusargs("PCIE_DPU_CONTROLLED_EXECUTOR") &&
        !$cast(controlled_executor, system_env.executor))
      `uvm_fatal("DPU_EP_X16",
        "controlled smoke did not install dpu_spy_reg_executor")
  endfunction

  virtual task run_phase(uvm_phase phase);
    dpu_spy_reg_executor controlled_executor;
    dpu_reg_op operation;
    dpu_reg_op_result_e result;
    string why;
    bit saw_vio_operation;

    super.run_phase(phase);
    if ($test$plusargs("PCIE_DPU_COMPILE_ONLY"))
      return;
    if ((system_env.bootstrap_report == null) ||
        (system_env.bootstrap_report.status() != DPU_CFG_STATUS_SUCCEEDED) ||
        (system_env.vio_report == null) ||
        (system_env.vio_report.status() != DPU_CFG_STATUS_SUCCEEDED))
      `uvm_fatal("DPU_EP_X16",
        "EP x16 smoke did not complete bootstrap and VIO plans")

    if ($cast(controlled_executor, system_env.executor)) begin
      saw_vio_operation = 1'b0;
      for (int unsigned index = 0;
           index < controlled_executor.record_count(); index++) begin
        if (!controlled_executor.record_at(
              index, operation, result, why))
          `uvm_fatal("DPU_EP_X16", {"cannot read executor history: ", why})
        if ((operation != null) &&
            (operation.phase != DPU_REG_PHASE_BOOTSTRAP))
          saw_vio_operation = 1'b1;
      end
      if ((controlled_executor.record_count() == 0) || !saw_vio_operation)
        `uvm_fatal("DPU_EP_X16",
          "controlled executor did not observe bootstrap plus VIO ordering")
    end
  endtask
endclass
