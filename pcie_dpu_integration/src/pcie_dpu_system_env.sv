//------------------------------------------------------------------------------
// DPU-aware extension of the common PCIe environment.
//
// The extension resolves dpu-common authoring data before calling the parent
// build_phase.  Consequently pcie_unified_env can create only after frozen
// snapshots have been projected into one validated pcie_global_cfg.
//------------------------------------------------------------------------------

class pcie_dpu_system_env extends pcie_unified_env;
  `uvm_component_utils(pcie_dpu_system_env)

  pcie_dpu_system_cfg system_cfg;
  dpu_device_snapshot device_snapshot;
  dpu_resource_snapshot resource_snapshot;

  dpu_reg_executor executor;
  dpu_config_orchestrator orchestrator;
  dpu_execution_report bootstrap_report;
  dpu_execution_report vio_report;

  function new(string name = "pcie_dpu_system_env",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  protected function string first_error(
      string prefix,
      string errors[$]);
    if (errors.size() == 0)
      return {prefix, "unspecified error"};
    return {prefix, errors[0]};
  endfunction

  virtual function void build_phase(uvm_phase phase);
    dpu_configuration_resolver resolver;
    dpu_placement_diagnostic diagnostic;
    pcie_dpu_cfg_adapter adapter;
    pcie_global_cfg projected_cfg;
    string errors[$];

    // Do not call pcie_unified_env::build_phase until every DPU-owned value is
    // frozen and projected.  Returning on any failure guarantees that neither
    // the TL nor SVT child can be partially constructed.
    if (!uvm_config_db#(pcie_dpu_system_cfg)::get(
          this, "", "system_cfg", system_cfg) || (system_cfg == null)) begin
      `uvm_fatal("DPU_SYSTEM_CFG", "non-null system_cfg is required")
      return;
    end

    system_cfg.validate(errors);
    if (errors.size() != 0) begin
      `uvm_fatal("DPU_SYSTEM_CFG",
        first_error("invalid system configuration: ", errors))
      return;
    end

    resolver = dpu_configuration_resolver::type_id::create(
      "configuration_resolver");
    if (!resolver.resolve(
          system_cfg.device_cfg, system_cfg.placement_cfg,
          device_snapshot, resource_snapshot, diagnostic)) begin
      `uvm_fatal("DPU_SYSTEM_CFG",
        {"DPU resolution failed: ", diagnostic.message})
      return;
    end

    adapter = pcie_dpu_cfg_adapter::type_id::create("cfg_adapter");
    if (!adapter.project(
          device_snapshot, resource_snapshot,
          system_cfg.pcie_policy.topology, system_cfg.attachments,
          projected_cfg, errors)) begin
      `uvm_fatal("DPU_SYSTEM_CFG",
        first_error("DPU-to-PCIe projection failed: ", errors))
      return;
    end
    if (!system_cfg.apply_pcie_policy(projected_cfg, errors)) begin
      `uvm_fatal("DPU_SYSTEM_CFG",
        first_error("PCIe policy overlay failed: ", errors))
      return;
    end

    // Publish immutable snapshots for service environments and the projected
    // policy for the parent manager before it constructs the selected child.
    global_cfg = projected_cfg;
    uvm_config_db#(dpu_device_snapshot)::set(
      this, "*", "dpu_device_snapshot", device_snapshot);
    uvm_config_db#(dpu_resource_snapshot)::set(
      this, "*", "dpu_resource_snapshot", resource_snapshot);
    uvm_config_db#(pcie_global_cfg)::set(
      this, "", "global_cfg", global_cfg);

    orchestrator = dpu_config_orchestrator::type_id::create(
      "config_orchestrator");
    super.build_phase(phase);
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    if ((global_cfg == null) || (orchestrator == null))
      return;

    executor = system_cfg.executor;
    if (executor == null) begin
      case (global_cfg.backend)
        PCIE_BACKEND_TL_ONLY,
        PCIE_BACKEND_SVT_TL_FORWARD: begin
          pcie_tl_custom_env selected_tl_env;
          pcie_dpu_tl_reg_executor tl_executor;

          if (!$cast(selected_tl_env, tl_env) ||
              (selected_tl_env.v_seqr == null)) begin
            `uvm_fatal("DPU_SYSTEM_EXEC",
              "TL backend did not expose pcie_tl_custom_env.v_seqr")
            return;
          end
          tl_executor = pcie_dpu_tl_reg_executor::type_id::create(
            "tl_reg_executor");
          tl_executor.configure(selected_tl_env.v_seqr, global_cfg, null,
                                system_cfg.rc_index);
          executor = tl_executor;
        end

        PCIE_BACKEND_SVT_REAL_DUT: begin
          pcie_dpu_svt_reg_executor svt_executor;

          if ((svt_env == null) || (svt_env.vseqr == null)) begin
            `uvm_fatal("DPU_SYSTEM_EXEC",
              "SVT backend did not expose pcie_svt_topology_env.vseqr")
            return;
          end
          svt_executor = pcie_dpu_svt_reg_executor::type_id::create(
            "svt_reg_executor");
          svt_executor.configure(
            svt_env.vseqr, global_cfg, system_cfg.root_link_id, null,
            system_cfg.use_switch_routing);
          executor = svt_executor;
        end

        default: begin
          `uvm_fatal("DPU_SYSTEM_EXEC",
            "unsupported backend reached executor configuration")
          return;
        end
      endcase
    end

    orchestrator.set_executor(executor);
  endfunction

  function bit stages_are_ready(output string why);
    why = "";
    if ((device_snapshot == null) || !device_snapshot.is_frozen() ||
        (resource_snapshot == null) || !resource_snapshot.is_frozen()) begin
      why = "DPU snapshots are not frozen";
      return 1'b0;
    end
    if ((global_cfg == null) || (orchestrator == null) ||
        (executor == null)) begin
      why = "PCIe policy, orchestrator, or executor is not ready";
      return 1'b0;
    end
    return 1'b1;
  endfunction

  task apply_bootstrap_plan(output bit succeeded, output string why);
    dpu_device_bootstrap_plan_builder builder;
    dpu_reg_plan plan;

    succeeded = 1'b0;
    why = "";
    builder = dpu_device_bootstrap_plan_builder::type_id::create(
      "bootstrap_plan_builder");
    if (!builder.build(device_snapshot, plan, why))
      return;
    orchestrator.apply_with_report(plan, bootstrap_report);
    succeeded = (bootstrap_report != null) &&
                (bootstrap_report.status() == DPU_CFG_STATUS_SUCCEEDED);
    if (!succeeded)
      why = (bootstrap_report == null) ?
            "bootstrap executor returned a null report" :
            bootstrap_report.reason();
  endtask

  task apply_vio_plan(output bit succeeded, output string why);
    dpu_vio_register_plan_builder builder;
    dpu_reg_plan plan;

    succeeded = 1'b0;
    why = "";
    builder = dpu_vio_register_plan_builder::type_id::create(
      "vio_plan_builder");
    if (system_cfg.vio_policy != null)
      builder.set_policy(system_cfg.vio_policy);
    builder.set_dataplane_extension(system_cfg.vio_dataplane_extension);
    if (!builder.build(device_snapshot, resource_snapshot, plan, why))
      return;
    orchestrator.apply_with_report(plan, vio_report);
    succeeded = (vio_report != null) &&
                (vio_report.status() == DPU_CFG_STATUS_SUCCEEDED);
    if (!succeeded)
      why = (vio_report == null) ?
            "VIO executor returned a null report" : vio_report.reason();
  endtask
endclass : pcie_dpu_system_env
