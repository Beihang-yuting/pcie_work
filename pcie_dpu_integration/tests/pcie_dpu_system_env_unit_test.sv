import uvm_pkg::*;
import dpu_resource_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
import pcie_dpu_integration_pkg::*;
import pcie_svt_topology_pkg::*;
import pcie_dpu_system_pkg::*;
`include "uvm_macros.svh"

// The expected-fatal catcher keeps the negative build case local to this
// unit test.  A failed DPU projection must stop before a protocol child is
// constructed, while unrelated fatals retain their normal behavior.
class pcie_dpu_system_expected_fatal_catcher extends uvm_report_catcher;
  int unsigned caught_count;

  function new(string name = "pcie_dpu_system_expected_fatal_catcher");
    super.new(name);
    caught_count = 0;
  endfunction

  virtual function action_e catch();
    if ((get_severity() == UVM_FATAL) &&
        (get_id() == "DPU_SYSTEM_CFG")) begin
      caught_count++;
      return CAUGHT;
    end
    return THROW;
  endfunction
endclass

// Protocol activity is external to this lifecycle unit test.  These hooks
// preserve the real sequence's branching and record the point at which each
// backend operation would be dispatched; DPU plan execution remains real and
// goes through dpu_config_orchestrator plus dpu_spy_reg_executor.
class pcie_dpu_system_stage_spy extends pcie_dpu_global_stage_vseq;
  `uvm_object_utils(pcie_dpu_system_stage_spy)

  function new(string name = "pcie_dpu_system_stage_spy");
    super.new(name);
  endfunction

  protected virtual task initialize_backend_devices();
    record_stage((system_env.global_cfg.backend == PCIE_BACKEND_TL_ONLY) ?
                 "tl.config" : "svt.cfg_init");
  endtask

  protected virtual task start_backend_links();
    record_stage("svt.link");
  endtask

  protected virtual task enumerate_backend_devices();
    record_stage("svt.enum");
  endtask

  protected virtual task start_backend_traffic();
    record_stage("traffic");
  endtask
endclass

class pcie_dpu_system_env_unit_test extends uvm_test;
  `uvm_component_utils(pcie_dpu_system_env_unit_test)

  pcie_dpu_system_env valid_env;
  pcie_dpu_system_env invalid_env;
  dpu_spy_reg_executor executor_spy;
  pcie_dpu_system_expected_fatal_catcher expected_fatal_catcher;

  function new(string name = "pcie_dpu_system_env_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void require(bit condition, string message);
    if (!condition)
      `uvm_error("DPU_SYSTEM_TEST", message)
  endfunction

  function dpu_function_key_t pf0_key();
    return '{host_id: 0, pf_id: 0, kind: DPU_FUNCTION_PF, vf_id: 0};
  endfunction

  function dpu_bar_request make_bar(
      dpu_bar_role_e role,
      int unsigned even_bar_id,
      bit [63:0] size,
      bit [63:0] base);
    dpu_bar_request bar;

    bar = dpu_bar_request::type_id::create(
      $sformatf("system_bar%0d", even_bar_id));
    bar.role = role;
    bar.even_bar_id = even_bar_id;
    bar.size = size;
    bar.alignment = size;
    bar.placement = DPU_ALLOC_PINNED;
    bar.pinned_base = base;
    return bar;
  endfunction

  function dpu_device_cfg make_device_cfg();
    dpu_device_cfg cfg;
    dpu_host_cfg host;
    dpu_pcie_domain_cfg domain;
    dpu_mmio_window_cfg window;
    dpu_bdf_range_t bdf_range;
    dpu_function_cfg function_cfg;

    cfg = dpu_device_cfg::type_id::create("system_device_cfg");
    host = dpu_host_cfg::type_id::create("system_host");
    host.host_id = 0;

    domain = dpu_pcie_domain_cfg::type_id::create("system_domain");
    domain.key.host_id = 0;
    domain.key.segment_id = 0;
    bdf_range.first_bdf = 16'h0200;
    bdf_range.last_bdf = 16'h0207;
    domain.bdf_ranges.push_back(bdf_range);

    window = dpu_mmio_window_cfg::type_id::create("system_window");
    window.base = 64'h0000_0001_0000_0000;
    window.limit = 64'h0000_0001_1000_0000;
    window.allowed_roles = '{DPU_BAR_DEVICE_MEMORY,
                             DPU_BAR_MAILBOX,
                             DPU_BAR_MSIX};
    domain.mmio_windows.push_back(window);
    host.pcie_domains.push_back(domain);
    cfg.hosts.push_back(host);

    function_cfg = dpu_function_cfg::type_id::create("system_pf0");
    function_cfg.key = pf0_key();
    function_cfg.domain_key = domain.key;
    function_cfg.bdf_mode = DPU_ALLOC_PINNED;
    function_cfg.pinned_bdf = 16'h0200;
    function_cfg.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);
    function_cfg.bars.push_back(make_bar(
      DPU_BAR_DEVICE_MEMORY, 0, 64'h0200_0000,
      64'h0000_0001_0000_0000));
    function_cfg.bars.push_back(make_bar(
      DPU_BAR_MAILBOX, 2, 64'h0001_0000,
      64'h0000_0001_0200_0000));
    function_cfg.bars.push_back(make_bar(
      DPU_BAR_MSIX, 4, 64'h0001_0000,
      64'h0000_0001_0201_0000));
    cfg.functions.push_back(function_cfg);
    cfg.af_request.mode = DPU_AF_SELECTED;
    cfg.af_request.requester = function_cfg.key;
    return cfg;
  endfunction

  function dpu_resource_placement_cfg make_placement_cfg();
    dpu_resource_placement_cfg placement;
    dpu_resource_pool_config_t profile;
    dpu_vio_placement_request request;
    dpu_vio_qpair_override qpair_override;

    placement = dpu_resource_placement_cfg::type_id::create(
      "system_placement_cfg");
    profile.name = "virtio.qpair";
    profile.class_id = 0;
    profile.kind = DPU_RESOURCE_KIND_QUEUE;
    profile.capacity = 32;
    profile.max_per_function = 32;
    placement.profiles.push_back(profile);

    request = dpu_vio_placement_request::type_id::create("system_vio_req");
    request.request_id = 1;
    request.total_qpairs = 1;
    request.candidate_kind = DPU_VIO_CANDIDATE_PF_ONLY;
    request.device_policy = DPU_VIO_DEVICE_FIXED;
    request.fixed_devices.push_back(pf0_key());

    qpair_override = dpu_vio_qpair_override::type_id::create(
      "system_qpair_override");
    qpair_override.request_pair_index = 0;
    qpair_override.owner_mode = DPU_ASSIGN_PINNED;
    qpair_override.requested_owner = pf0_key();
    qpair_override.local_mode = DPU_ASSIGN_PINNED;
    qpair_override.requested_local_pair_id = 0;
    qpair_override.global_mode = DPU_ASSIGN_PINNED;
    qpair_override.requested_global_qpair_id = 0;
    request.qpair_overrides.push_back(qpair_override);
    placement.vio_requests.push_back(request);
    return placement;
  endfunction

  function pcie_dpu_system_cfg make_system_cfg(
      string name,
      bit include_attachment,
      dpu_reg_executor executor);
    pcie_dpu_system_cfg cfg;
    string why;

    cfg = pcie_dpu_system_cfg::type_id::create(name);
    cfg.device_cfg = make_device_cfg();
    cfg.placement_cfg = make_placement_cfg();
    cfg.pcie_policy = pcie_global_cfg::type_id::create({name, "_pcie"});
    cfg.pcie_policy.build_default_for_topology(
      pcie_topology_builder::build_ep_x16(4));
    cfg.pcie_policy.backend = PCIE_BACKEND_TL_ONLY;
    cfg.attachments = pcie_dpu_attachment_cfg::type_id::create(
      {name, "_attachments"});
    if (include_attachment)
      require(cfg.attachments.add(
        pf0_key(), "EP0", "RC0_EP0", 1'b1, 0, why),
        {"attachment setup failed: ", why});
    cfg.executor = executor;
    cfg.root_link_id = "RC0_EP0";
    return cfg;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    pcie_dpu_system_cfg cfg;

    super.build_phase(phase);
    expected_fatal_catcher = new("expected_fatal_catcher");
    uvm_report_cb::add(null, expected_fatal_catcher);
    executor_spy = dpu_spy_reg_executor::type_id::create("executor_spy");

    cfg = make_system_cfg("valid_cfg", 1'b1, executor_spy);
    uvm_config_db#(pcie_dpu_system_cfg)::set(
      this, "valid_env", "system_cfg", cfg);
    valid_env = pcie_dpu_system_env::type_id::create("valid_env", this);

    cfg = make_system_cfg("invalid_cfg", 1'b0, executor_spy);
    uvm_config_db#(pcie_dpu_system_cfg)::set(
      this, "invalid_env", "system_cfg", cfg);
    invalid_env = pcie_dpu_system_env::type_id::create("invalid_env", this);
  endfunction

  function void check_stage_history(
      pcie_dpu_system_stage_spy sequence_item,
      string expected[$],
      string context);
    string observed;

    require(sequence_item.stage_count() == expected.size(),
            $sformatf("%s stage count expected=%0d actual=%0d",
                      context, expected.size(), sequence_item.stage_count()));
    foreach (expected[index]) begin
      observed = sequence_item.stage_at(index);
      require(observed == expected[index], $sformatf(
        "%s stage %0d expected='%s' actual='%s'",
        context, index, expected[index], observed));
    end
  endfunction

  task run_phase(uvm_phase phase);
    pcie_dpu_system_stage_spy sequence_item;
    string expected[$];
    int unsigned tl_record_count;

    phase.raise_objection(this);
    require(expected_fatal_catcher.caught_count == 1,
            "invalid projection did not emit exactly one DPU_SYSTEM_CFG fatal");
    require((invalid_env.global_cfg == null) &&
            (invalid_env.tl_env == null) && (invalid_env.svt_env == null),
            "invalid DPU projection constructed a protocol child");

    require((valid_env.device_snapshot != null) &&
            valid_env.device_snapshot.is_frozen() &&
            (valid_env.resource_snapshot != null) &&
            valid_env.resource_snapshot.is_frozen(),
            "valid system environment did not publish frozen snapshots");
    require((valid_env.global_cfg != null) &&
            (valid_env.tl_env != null) && (valid_env.svt_env == null),
            "valid TL system environment did not construct exactly one TL child");
    require(valid_env.global_cfg.devices[1].bdf == 16'h0200 &&
            valid_env.global_cfg.devices[1].bars[0].initial_base ==
              64'h0000_0001_0000_0000,
            "system environment did not preserve DPU-owned BDF/BAR values");

    sequence_item = pcie_dpu_system_stage_spy::type_id::create("tl_stages");
    sequence_item.system_env = valid_env;
    sequence_item.start(null);
    expected = '{"tl.config", "dpu.bootstrap", "dpu.vio", "traffic"};
    check_stage_history(sequence_item, expected, "TL");
    require((valid_env.bootstrap_report != null) &&
            (valid_env.bootstrap_report.status() == DPU_CFG_STATUS_SUCCEEDED) &&
            (valid_env.vio_report != null) &&
            (valid_env.vio_report.status() == DPU_CFG_STATUS_SUCCEEDED),
            "TL lifecycle did not execute both DPU plans");
    tl_record_count = executor_spy.record_count();
    require(tl_record_count != 0,
            "TL lifecycle did not send operations through the executor");

    // The protocol hooks are spies, so switching the already-projected policy
    // exercises the SVT lifecycle order without requiring a second HDL/VIF
    // instance.  DPU plan generation and execution remain the real path.
    valid_env.global_cfg.backend = PCIE_BACKEND_SVT_REAL_DUT;
    sequence_item = pcie_dpu_system_stage_spy::type_id::create("svt_stages");
    sequence_item.system_env = valid_env;
    sequence_item.start(null);
    expected = '{"svt.cfg_init", "svt.link", "svt.enum",
                 "dpu.bootstrap", "dpu.vio", "traffic"};
    check_stage_history(sequence_item, expected, "SVT");
    require(executor_spy.record_count() > tl_record_count,
            "SVT lifecycle did not reuse the same DPU executor contract");

    uvm_report_cb::delete(null, expected_fatal_catcher);
    phase.drop_objection(this);
  endtask
endclass
