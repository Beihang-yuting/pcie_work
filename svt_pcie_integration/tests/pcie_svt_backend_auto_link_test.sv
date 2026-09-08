//------------------------------------------------------------------------------
// SVT backend 自动创建门禁。
//
// 本测试与 pcie_tl_svt_formal_link_test 使用同一个静态 Serial 顶层，但刻意
// 不在 test 中创建 SVT RC。RC 必须由下面这条生产路径自动产生：
//
//   global_cfg -> pcie_tl_env -> pcie_tl_backend_factory
//              -> pcie_svt_backend -> svt_pcie_device_agent
//
// Endpoint 作为“真实 DUT/外部对端”只保留一个手工创建的 SVT agent，方便
// 检查自动 backend 的角色边界。这里不启动链路和业务流量；完整双向 Serial
// 数据面仍由 pcie_tl_svt_formal_link_test 负责验证。
//------------------------------------------------------------------------------

`include "uvm_macros.svh"

import uvm_pkg::*;
import pcie_tl_pkg::*;
// pcie_global_cfg 和 topology builder 定义在 topology package 中。
// pcie_tl_pkg 只导入该 package，并不会把其名字重新导出到本 compilation
// unit，因此这里必须显式导入，避免不同 VCS 版本下出现“类型未声明”。
import pcie_topology_pkg::*;
import pcie_svt_adapter_pkg::*;

class pcie_svt_backend_auto_link_test extends uvm_test;
  `uvm_component_utils(pcie_svt_backend_auto_link_test)

  // --------------------------------------------------------------------------
  // 自动 backend 的输入配置。
  // --------------------------------------------------------------------------
  pcie_global_cfg global_cfg;
  pcie_tl_env_config tl_cfg;
  pcie_svt_backend_cfg svt_backend_cfg;
  pcie_svt_backend_factory backend_factory;

  // TL 环境是唯一控制面；backend provider 和它创建的 SVT agent 都挂在
  // 这个环境之下。
  pcie_tl_env tl_env;
  pcie_svt_backend backend;

  // 仅作为外部 DUT/对端占位的 Endpoint agent。它不是 backend 创建的对象，
  // 用来证明“一个 SVT RC + 一个外部 EP”时不会多创建一个 SVT EP。
  svt_pcie_device_agent external_endpoint;
  svt_pcie_device_configuration external_endpoint_cfg;
  svt_pcie_device_status external_endpoint_status;
  svt_pcie_vif endpoint_vif;

  function new(string name = "pcie_svt_backend_auto_link_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // --------------------------------------------------------------------------
  // 构造一个只含一条 x16 RC↔EP 链的 backend-neutral policy。
  // --------------------------------------------------------------------------
  function void build_global_policy();
    pcie_topology_cfg topology;
    pcie_link_cfg link;

    topology = pcie_topology_builder::build_ep_x16(4);

    global_cfg = pcie_global_cfg::type_id::create("auto_global_cfg");
    global_cfg.build_default_for_topology(topology);
    global_cfg.backend = PCIE_BACKEND_SVT_REAL_DUT;
    global_cfg.svt_bridge_enable = 1'b1;

    if (global_cfg.links.size() != 1)
      `uvm_fatal("SVT_AUTO", "x16 自动 backend policy 应只有一条 link")

    link = global_cfg.links[0];
    link.enabled = 1'b1;
    link.use_svt = 1'b1;
    link.svt_role_valid = 1'b1;
    link.svt_role = PCIE_DEVICE_RC;
    link.svt_node_id = topology.links[0].upstream_node_id;
    link.has_hdl_slot = 1'b1;
    link.hdl_slot = 0;
    // 官方 hdl_interconnect_macros.sv 的 CREATE_LINK(0,...) 会发布该 key。
    link.vif_key = "link_0_vif_0";

    global_cfg.runtime_num_links = 1;
  endfunction

  // --------------------------------------------------------------------------
  // 外部 Endpoint 只作为对端占位，不经过本项目 backend factory。
  // --------------------------------------------------------------------------
  function void build_external_endpoint();
    void'(uvm_config_db#(svt_pcie_vif)::get(
      this, "", "link_0_vif_1", endpoint_vif));
    if (endpoint_vif == null)
      `uvm_fatal("SVT_AUTO", "自动 backend 测试找不到 Endpoint Unified VIF")

    external_endpoint_cfg = svt_pcie_device_configuration::type_id::create(
      "external_endpoint_cfg", this);
    external_endpoint_cfg.set_initial_values_via_unified_vif(
      1'b1, endpoint_vif);
    external_endpoint_cfg.dut_model =
      svt_pcie_device_configuration::NOT_APPLICABLE;
    external_endpoint_cfg.pcie_cfg.tl_cfg.enable_shadow_cfg_lookup = 1'b0;

    external_endpoint_status = svt_pcie_device_status::type_id::create(
      "external_endpoint_status", this);

    uvm_config_db#(svt_pcie_device_configuration)::set(
      this, "external_endpoint", "cfg", external_endpoint_cfg);
    uvm_config_db#(svt_pcie_device_status)::set(
      this, "external_endpoint", "shared_status", external_endpoint_status);
    external_endpoint = svt_pcie_device_agent::type_id::create(
      "external_endpoint", this);
  endfunction

  // --------------------------------------------------------------------------
  // 创建 TL 环境。这里不调用 pcie_svt_backend::build_backend()，而是只
  // 发布 neutral factory，验证真正的自动发现路径。
  // --------------------------------------------------------------------------
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    build_global_policy();
    build_external_endpoint();

    svt_backend_cfg = pcie_svt_backend_cfg::type_id::create(
      "auto_svt_backend_cfg");
    svt_backend_cfg.init_defaults();
    svt_backend_cfg.backend_mode = PCIE_SVT_BACKEND_FULL_VIP;
    svt_backend_cfg.enable_shadow_cfg_lookup = 1'b0;

    backend_factory = pcie_svt_backend_factory::type_id::create(
      "auto_backend_factory");

    tl_cfg = pcie_tl_env_config::type_id::create("auto_tl_cfg");
    tl_cfg.if_mode = SV_IF_MODE;
    // 这些值会由 provider 的 adapter count 覆盖；故意先给出不同值，
    // 以确保环境确实消费了 factory 返回的方向计数。
    tl_cfg.rc_agent_enable = 1'b0;
    tl_cfg.ep_agent_enable = 1'b1;
    tl_cfg.num_rc = 1;
    tl_cfg.num_ep = 1;
    tl_cfg.fc_enable = 1'b0;
    tl_cfg.scb_enable = 1'b0;
    tl_cfg.cov_enable = 1'b0;
    tl_cfg.ep_auto_response = 1'b0;

    uvm_config_db#(pcie_global_cfg)::set(
      this, "tl_env", "global_cfg", global_cfg);
    uvm_config_db#(pcie_svt_backend_cfg)::set(
      this, "tl_env", "pcie_svt_backend_cfg", svt_backend_cfg);
    uvm_config_db#(pcie_tl_backend_factory)::set(
      this, "tl_env", "pcie_tl_backend_factory", backend_factory);
    uvm_config_db#(pcie_tl_env_config)::set(
      this, "tl_env", "cfg", tl_cfg);

    tl_env = pcie_tl_env::type_id::create("tl_env", this);
  endfunction

  // --------------------------------------------------------------------------
  // 在所有 child build/connect 完成后检查自动创建结果。
  // --------------------------------------------------------------------------
  function void end_of_elaboration_phase(uvm_phase phase);
    pcie_tl_if_adapter expected_adapter;
    svt_pcie_device_configuration expected_cfg;
    string expected_link_id;
    int unsigned expected_timeout_ns;

    super.end_of_elaboration_phase(phase);

    if (tl_env == null)
      `uvm_fatal("SVT_AUTO", "TL env 没有创建")
    if (!tl_env.backend_provider_active)
      `uvm_fatal("SVT_AUTO", "TL env 没有激活 backend provider")
    if (!$cast(backend, tl_env.backend_provider) || (backend == null))
      `uvm_fatal("SVT_AUTO", "factory 没有返回 pcie_svt_backend")

    if (backend.created_rc_count != 1)
      `uvm_fatal("SVT_AUTO", $sformatf(
        "自动创建 RC 数量错误：got=%0d expected=1",
        backend.created_rc_count))
    if (backend.created_ep_count != 0)
      `uvm_fatal("SVT_AUTO", $sformatf(
        "SVT RC + DUT EP 不应自动创建 EP：got=%0d",
        backend.created_ep_count))
    if (backend.rc_adapters.size() != 1 ||
        (backend.ep_adapters.size() != 0))
      `uvm_fatal("SVT_AUTO", "backend RC/EP adapter 数量不符合角色策略")

    // builder.connect() 生成的稳定链路 ID 是 RC0_EP0，而不是节点名 EP0。
    // 测试必须使用 policy 中的真实 link_id，避免把节点 ID 与链路 ID
    // 混淆后误报 backend 没有创建 agent。
    if ((global_cfg == null) || (global_cfg.links.size() != 1) ||
        (global_cfg.links[0] == null))
      `uvm_fatal("SVT_AUTO", "自动 backend policy 缺少唯一有效 link")
    expected_link_id = global_cfg.links[0].link_id;

    // 诊断队列必须与物理 link_id 保持同一 canonical 顺序。这个断言
    // 既检查 backend 确实记录了创建结果，也防止后续把 declaration
    // order 错当成物理 link ordinal。
    if ((backend.created_roles.size() != 1) ||
        (backend.created_link_ids.size() != 1) ||
        (backend.created_roles[0] != PCIE_DEVICE_RC) ||
        (backend.created_link_ids[0] != expected_link_id))
      `uvm_fatal("SVT_AUTO", $sformatf(
        "backend 创建诊断不匹配：role_count=%0d id_count=%0d first_id=%s expected=%s",
        backend.created_roles.size(), backend.created_link_ids.size(),
        (backend.created_link_ids.size() != 0) ?
          backend.created_link_ids[0] : "<none>", expected_link_id))

    if (!backend.svt_agent_by_link.exists(expected_link_id) ||
        (backend.svt_agent_by_link[expected_link_id] == null))
      `uvm_fatal("SVT_AUTO", $sformatf(
        "自动 backend 没有保存 link %s 的 SVT agent", expected_link_id))
    if (!backend.svt_adapter_by_link.exists(expected_link_id) ||
        (backend.svt_adapter_by_link[expected_link_id] == null))
      `uvm_fatal("SVT_AUTO", $sformatf(
        "自动 backend 没有保存 link %s 的 adapter", expected_link_id))

    expected_cfg = backend.svt_cfg_by_link[expected_link_id];
    if ((expected_cfg == null) ||
        (expected_cfg.pcie_spec_ver !=
         svt_pcie_device_configuration::PCIE_SPEC_VER_4_0))
      `uvm_fatal("SVT_AUTO",
        "Gen4 backend link must advertise PCIE_SPEC_VER_4_0")

    // R-2020.12 exposes two different timeout controls: tl_cfg is used by
    // monitor/RX-path checks, while driver_cfg[0] controls the active Driver
    // App's Completion Timeout.  Both must receive the backend link policy;
    // checking the latter here prevents a silent fallback to SVT's 500-us
    // default.
    expected_timeout_ns = int'(
      svt_backend_cfg.link_timeout / 1ns);
    if ((expected_cfg.driver_cfg.num() == 0) ||
        (expected_cfg.driver_cfg[0] == null))
      `uvm_fatal("SVT_AUTO",
        "backend Device Configuration 缺少 driver_cfg[0]")
    if (expected_cfg.driver_cfg[0].completion_timeout_ns !=
        expected_timeout_ns)
      `uvm_fatal("SVT_AUTO", $sformatf(
        "active driver CTO=%0d ns, expected=%0d ns",
        expected_cfg.driver_cfg[0].completion_timeout_ns,
        expected_timeout_ns))
    if (backend.svt_agent_by_link[expected_link_id].get_report_verbosity_level() !=
        int'(svt_backend_cfg.svt_verbosity))
      `uvm_fatal("SVT_AUTO",
        "svt_verbosity 未应用到自动创建的 SVT Device Agent")

    expected_adapter = backend.svt_adapter_by_link[expected_link_id];
    if (tl_env.rc_adapters.size() != 1 ||
        (tl_env.rc_adapters[0] != expected_adapter) ||
        (tl_env.rc_adapter != expected_adapter))
      `uvm_fatal("SVT_AUTO", "TL env 没有注入 backend 创建的 RC adapter")
    if (tl_env.ep_agents.size() != 0 || tl_env.ep_agent != null)
      `uvm_fatal("SVT_AUTO", "DUT EP 场景错误创建了 TL EP agent")

    if (backend.svt_agent_by_link[expected_link_id].get_parent() != tl_env)
      `uvm_fatal("SVT_AUTO", "自动 SVT agent 未挂在 TL env 下")

    `uvm_info("SVT_AUTO", {
      "SVT_AUTO_BACKEND_BUILD_PASS: factory -> backend -> one RC agent; ",
      "external EP remains outside backend"}, UVM_NONE)
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    // 本测试的目标是 build/elaboration contract；不启动 linkup，避免把
    // “自动 agent 创建”与双 SVT data-plane 门禁混为一个失败原因。
    #1ns;
    phase.drop_objection(this);
  endtask
endclass
