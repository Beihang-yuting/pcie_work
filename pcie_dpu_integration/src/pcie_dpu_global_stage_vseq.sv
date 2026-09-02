//------------------------------------------------------------------------------
// Ordered PCIe/DPU lifecycle sequence.
//
// Backend hooks are virtual so switch enumeration or project traffic can be
// replaced without changing DPU resolution or register-plan execution.  The
// default SVT path uses the project cfg-init and direct-Endpoint enumeration
// sequences; a real switch test overrides enumerate_backend_devices() until a
// switch-specific enumeration sequence is selected.
//------------------------------------------------------------------------------

class pcie_dpu_global_stage_vseq extends pcie_global_stage_vseq;
  `uvm_object_utils(pcie_dpu_global_stage_vseq)

  pcie_dpu_system_env system_env;
  protected string completed_stages[$];

  function new(string name = "pcie_dpu_global_stage_vseq");
    super.new(name);
  endfunction

  protected function void record_stage(string stage_name);
    completed_stages.push_back(stage_name);
    `uvm_info("DPU_SYSTEM_STAGE", {"completed ", stage_name}, UVM_LOW)
  endfunction

  function int unsigned stage_count();
    return completed_stages.size();
  endfunction

  function string stage_at(int unsigned index);
    if (index >= completed_stages.size())
      return "";
    return completed_stages[index];
  endfunction

  protected virtual task initialize_backend_devices();
    if ((system_env.global_cfg.backend == PCIE_BACKEND_TL_ONLY) ||
        (system_env.global_cfg.backend == PCIE_BACKEND_SVT_TL_FORWARD)) begin
      pcie_tl_custom_env selected_tl_env;

      // TL configuration images are materialized during environment build;
      // the DPU bootstrap stage later emits the authoritative BAR writes.
      if (!$cast(selected_tl_env, system_env.tl_env) ||
          (selected_tl_env.v_seqr == null)) begin
        `uvm_fatal("DPU_SYSTEM_STAGE",
          "TL configuration stage requires pcie_tl_custom_env.v_seqr")
        return;
      end
      record_stage("tl.config");
    end else begin
      pcie_svt_cfg_init_vseq cfg_init;

      if ((system_env.svt_env == null) ||
          (system_env.svt_env.vseqr == null)) begin
        `uvm_fatal("DPU_SYSTEM_STAGE",
          "SVT cfg-init stage requires pcie_svt_topology_env.vseqr")
        return;
      end
      cfg_init = pcie_svt_cfg_init_vseq::type_id::create("system_cfg_init");
      cfg_init.program_target_bars = 1'b1;
      cfg_init.start(system_env.svt_env.vseqr);
      record_stage("svt.cfg_init");
    end
  endtask

  protected function svt_pcie_pl_status::link_speed_enum expected_speed(
      int unsigned max_gen);
    return (max_gen == 5) ? svt_pcie_pl_status::SPEED_32_0G :
                            svt_pcie_pl_status::SPEED_16_0G;
  endfunction

  protected task start_one_svt_link(string link_id);
    pcie_svt_topology_virtual_sequencer topology_vseqr;
    pcie_svt_port_descriptor descriptor;
    svt_pcie_device_status status;
    pcie_svt_link_enable_port_sequence enable_sequence;
    svt_pcie_pl_status::link_speed_enum speed;
    bit reached;

    topology_vseqr = system_env.svt_env.vseqr;
    descriptor = topology_vseqr.get_port_descriptor(link_id);
    status = topology_vseqr.status_by_link.exists(link_id) ?
             topology_vseqr.status_by_link[link_id] : null;
    if ((descriptor == null) || (status == null) ||
        (status.pcie_status == null) ||
        (status.pcie_status.pl_status == null) ||
        (status.pcie_status.dl_status == null) ||
        (topology_vseqr.get_port_seqr(link_id) == null)) begin
      `uvm_fatal("DPU_SYSTEM_STAGE", {link_id,
        ": incomplete SVT descriptor/status/sequencer handles"})
      return;
    end
    if (!topology_vseqr.cfg_state.exists(link_id) ||
        (topology_vseqr.cfg_state[link_id] != PCIE_SVT_STAGE_PASS)) begin
      `uvm_fatal("DPU_SYSTEM_STAGE", {link_id,
        ": link stage requires CFG stage PASS"})
      return;
    end

    speed = expected_speed(descriptor.max_gen);
    reached = 1'b0;
    enable_sequence = pcie_svt_link_enable_port_sequence::type_id::create(
      {link_id, "_real_dut_enable"});
    enable_sequence.link_id = link_id;
    enable_sequence.port_seqr = topology_vseqr.get_port_seqr(link_id);
    fork
      begin
        enable_sequence.start(null);
        // Keep status fields directly in the wait expression so VCS updates
        // sensitivity when the vendor status object changes.
        wait ((status.pcie_status.pl_status.link_up === 1'b1) &&
              (status.pcie_status.dl_status.dl_link_up === 1'b1) &&
              (status.pcie_status.pl_status.ltssm_state ==
                svt_pcie_types::L0) &&
              (status.pcie_status.pl_status.current_speed == speed) &&
              (status.pcie_status.pl_status.negotiated_link_width ==
                descriptor.link_width));
        reached = 1'b1;
      end
      begin
        #(descriptor.link_timeout);
      end
    join_any
    disable fork;

    if (!reached) begin
      topology_vseqr.link_state[link_id] = PCIE_SVT_STAGE_FAIL;
      `uvm_fatal("DPU_SYSTEM_STAGE", $sformatf(
        "%s did not reach L0 x%0d Gen%0d within %0t",
        link_id, descriptor.link_width, descriptor.max_gen,
        descriptor.link_timeout))
      return;
    end
    topology_vseqr.link_state[link_id] = PCIE_SVT_STAGE_PASS;
  endtask

  protected virtual task start_backend_links();
    string link_ids[$];

    if ((system_env.svt_env == null) ||
        (system_env.svt_env.vseqr == null)) begin
      `uvm_fatal("DPU_SYSTEM_STAGE",
        "SVT link stage requires pcie_svt_topology_env.vseqr")
      return;
    end
    foreach (system_env.svt_env.vseqr.descriptor_by_link[link_id])
      link_ids.push_back(link_id);
    if (link_ids.size() == 0) begin
      `uvm_fatal("DPU_SYSTEM_STAGE", "SVT link stage found no active links")
      return;
    end
    foreach (link_ids[index])
      start_one_svt_link(link_ids[index]);
    record_stage("svt.link");
  endtask

  protected virtual task enumerate_backend_devices();
    pcie_svt_enumeration_registry registry;
    pcie_svt_enumeration_vseq enumeration;

    foreach (system_env.svt_env.vseqr.descriptor_by_link[link_id]) begin
      pcie_svt_port_descriptor descriptor;

      descriptor = system_env.svt_env.vseqr.descriptor_by_link[link_id];
      if ((descriptor == null) ||
          (descriptor.role != PCIE_SVT_ROLE_RC)) begin
        `uvm_fatal("DPU_SYSTEM_STAGE", $sformatf(
          {"default DPU enumeration supports direct RC-to-Endpoint links; ",
           "link '%s' requires a switch-specific stage override"}, link_id))
        return;
      end
    end

    registry = pcie_svt_enumeration_registry::type_id::create(
      "system_enumeration_registry");
    enumeration = pcie_svt_enumeration_vseq::type_id::create(
      "system_enumeration");
    enumeration.registry = registry;
    foreach (system_env.svt_env.vseqr.descriptor_by_link[link_id])
      enumeration.peer_endpoint_model_by_link[link_id] = PCIE_SVT_EP_SINGLE;
    enumeration.start(system_env.svt_env.vseqr);
    record_stage("svt.enum");
  endtask

  protected virtual task start_backend_traffic();
    // Service tests override this hook.  Keeping the default side-effect free
    // prevents the common management layer from inventing traffic ownership.
    record_stage("traffic");
  endtask

  virtual task body();
    bit succeeded;
    string why;

    completed_stages.delete();
    if (system_env == null) begin
      `uvm_fatal("DPU_SYSTEM_STAGE", "system_env is required")
      return;
    end
    if (!system_env.stages_are_ready(why)) begin
      `uvm_fatal("DPU_SYSTEM_STAGE", {"environment is not ready: ", why})
      return;
    end

    // R-2020.12 target/config refresh must occur while reset is asserted and
    // links are down.  Physical link-up and enumeration are SVT-only stages.
    initialize_backend_devices();
    if (system_env.global_cfg.backend == PCIE_BACKEND_SVT_REAL_DUT) begin
      start_backend_links();
      enumerate_backend_devices();
    end

    if (system_env.system_cfg.enable_bootstrap_plan) begin
      system_env.apply_bootstrap_plan(succeeded, why);
      if (!succeeded) begin
        `uvm_fatal("DPU_SYSTEM_STAGE", {"bootstrap plan failed: ", why})
        return;
      end
      record_stage("dpu.bootstrap");
    end

    if (system_env.system_cfg.enable_vio_plan) begin
      system_env.apply_vio_plan(succeeded, why);
      if (!succeeded) begin
        `uvm_fatal("DPU_SYSTEM_STAGE", {"VIO plan failed: ", why})
        return;
      end
      record_stage("dpu.vio");
    end
    start_backend_traffic();
  endtask
endclass : pcie_dpu_global_stage_vseq
