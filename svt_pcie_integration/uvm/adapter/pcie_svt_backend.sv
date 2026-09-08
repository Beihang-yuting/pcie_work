//------------------------------------------------------------------------------
// 自动创建正式 SVT Device Agent 的 backend。
//
// 这个类是 pcie_tl_env 的可选 transport provider：
//   1. 从 global_cfg.links[] 选择 enabled && use_svt 的物理链路；
//   2. 为每条链路创建一组 SVT configuration/status/device agent；
//   3. 创建 pcie_svt_if_adapter，并把 adapter 交回 TL 环境；
//   4. 将公共链路策略转换成 SVT R-2020.12 的公开配置 API。
//
// Host 数量、BAR 分配和 TL sequence 不在这里创建。这样 SVT backend 只
// 承担 Serial/PIPE transport，pcie_tl_env 仍然是唯一控制面。
//------------------------------------------------------------------------------

class pcie_svt_backend extends pcie_tl_backend_provider;
  `uvm_object_utils(pcie_svt_backend)

  // SVT 专用策略；用户可在 test 中通过 config_db 注入同一个对象。
  pcie_svt_backend_cfg backend_cfg;

  // 每个实际 SVT link 的正式 SVT 对象句柄，key 使用 global link_id。
  svt_pcie_device_configuration svt_cfg_by_link[string];
  svt_pcie_device_status svt_status_by_link[string];
  svt_pcie_device_agent svt_agent_by_link[string];
  pcie_svt_if_adapter svt_adapter_by_link[string];

  // TL 环境按 RC/EP agent ordinal 取 adapter，而不是按 Host 数量取。
  pcie_tl_if_adapter rc_adapters[$];
  pcie_tl_if_adapter ep_adapters[$];

  // 只读统计信息，便于 test 在 build 后检查实际创建数量。
  int unsigned created_rc_count;
  int unsigned created_ep_count;

  // 创建结果的可追踪视图。两个队列始终按 global_cfg 提供的 canonical
  // 物理顺序成对保存：created_roles[i] 对应 created_link_ids[i]。它们
  // 只用于诊断和回归断言，真正的 adapter 查找仍以
  // pcie_tl_backend_provider 的 link_id associative map 为准。
  pcie_device_role_e created_roles[$];
  string created_link_ids[$];

  // 构造函数：仅透传名字，全部映射表/队列保持为空。
  function new(string name = "pcie_svt_backend");
    super.new(name);
  endfunction

  // 用户最后一级覆盖入口。默认实现不改动 backend 的公开配置；项目集成
  // 可 subclass 该 provider，在 agent 创建前调整 SVT 公开字段。
  virtual function void customize_svt_agent_cfg(
      int link_index,
      pcie_link_cfg link_policy,
      svt_pcie_device_configuration svt_cfg);
  endfunction

  // 将项目级 EQ 策略转换成 R-2020.12 的公开枚举。集中在纯函数中，
  // 便于配置契约测试覆盖 Gen4/Gen5 以及关闭 EQ 的边界，而无需创建
  // SVT agent 或依赖 HDL Unified VIF。
  protected function svt_pcie_pl_configuration::link_eq_mode_enum
      resolve_equalization_mode(int unsigned max_gen,
                                bit enable_equalization,
                                int unsigned requested_mode);
    if (!enable_equalization)
      return svt_pcie_pl_configuration::LINK_EQ_MODE_NO_EQUALIZATION_NEEDED;

    case (requested_mode)
      1: return svt_pcie_pl_configuration::LINK_EQ_MODE_FULL_EQUALIZATION_REQUIRED;
      2: return svt_pcie_pl_configuration::LINK_EQ_MODE_EQ_BYPASS_TO_HIGHEST_RATE;
      3: return svt_pcie_pl_configuration::LINK_EQ_MODE_NO_EQUALIZATION_NEEDED;
      default:
        return (max_gen == 5) ?
          svt_pcie_pl_configuration::LINK_EQ_MODE_EQ_BYPASS_TO_HIGHEST_RATE :
          svt_pcie_pl_configuration::LINK_EQ_MODE_FULL_EQUALIZATION_REQUIRED;
    endcase
  endfunction

  // 契约测试只读入口；生产代码仍通过上面的 protected 函数调用。
  function svt_pcie_pl_configuration::link_eq_mode_enum
      get_effective_equalization_mode(int unsigned max_gen,
                                      bit enable_equalization,
                                      int unsigned requested_mode);
    return resolve_equalization_mode(max_gen, enable_equalization,
                                     requested_mode);
  endfunction

  // 返回当前 link 的正式 SVT status，供公共 link sequence/scoreboard 等
  // 在不依赖 SVT agent 层次路径的情况下读取链路状态。
  function svt_pcie_device_status get_status(string link_id);
    if (svt_status_by_link.exists(link_id))
      return svt_status_by_link[link_id];
    return null;
  endfunction

  // 官方 update_if_variables() 通常把 Unified VIF 发布在
  // ``uvm_test_top`` scope，而 backend 的 parent 是 ``tl_env``。UVM
  // config_db::get() 不会自动向父层级回溯，因此仅以 parent/"" 查询会
  // 在真实集成中错误地报告“VIF 不存在”。这里沿 UVM 树从当前环境向上
  // 查找，既兼容用户把 VIF 直接发布到 tl_env，也兼容官方示例发布到
  // test scope；不会改变 field_name 或 VIF 类型的严格匹配语义。
  protected function bit lookup_unified_vif(
      uvm_component start_context,
      string vif_key,
      output svt_pcie_vif vif);
    // context_name 避免与 SystemVerilog 保留关键字 context 混淆；部分
    // VCS 版本会因此发出 KUAI 警告，影响用户把 warning 当 error 的回归。
    uvm_component context_name;

    vif = null;
    context_name = start_context;
    while (context_name != null) begin
      if (uvm_config_db#(svt_pcie_vif)::get(
            context_name, "", vif_key, vif) && (vif != null))
        return 1'b1;
      context_name = context_name.get_parent();
    end

    return 1'b0;
  endfunction

  // 按紧凑序号返回 RC adapter；越界或负索引返回 null。
  virtual function pcie_tl_if_adapter get_rc_adapter(int index);
    if ((index < 0) || (index >= rc_adapters.size()))
      return null;
    return rc_adapters[index];
  endfunction

  // 按紧凑序号返回 EP adapter；越界或负索引返回 null。
  virtual function pcie_tl_if_adapter get_ep_adapter(int index);
    if ((index < 0) || (index >= ep_adapters.size()))
      return null;
    return ep_adapters[index];
  endfunction

  // 仅为诊断/实例命名解析物理槽位序号。adapter 所有权始终以 link_id
  // 为 key。特别注意：不能在按声明顺序遍历时只数 use_svt 链路，否则
  // 稀疏策略会把（例如）物理 DSP2 挪到 EP0。
  protected function int canonical_role_slot(
      pcie_device_role_e role,
      string link_id);
    string role_ids[$];

    canonical_role_slot = -1;
    if (global_cfg == null)
      return canonical_role_slot;
    global_cfg.get_role_link_ids(role, role_ids, 1'b0);
    foreach (role_ids[i]) begin
      if (role_ids[i] == link_id) begin
        canonical_role_slot = i;
        return canonical_role_slot;
      end
    end
  endfunction

  // provider 主入口：校验配置后，为每条 enabled && use_svt 链路创建
  // svt_pcie_device_configuration/status/agent 与 pcie_svt_if_adapter，
  // 发布 link→adapter 身份映射并重建紧凑兼容数组。任何链路缺静态
  // slot/VIF、角色非法或 SVT 配置失败都会累加中文诊断并返回 0；成功
  // 返回 1。副作用：覆盖上一次 build 的全部内部表。
  virtual function bit build_backend(
      uvm_component parent,
      pcie_global_cfg global_cfg_arg,
      pcie_tl_env_config tl_cfg_arg,
      output string errors[$]);
    string cfg_errors[$];
    errors.delete();
    rc_adapters.delete();
    ep_adapters.delete();
    svt_cfg_by_link.delete();
    svt_status_by_link.delete();
    svt_agent_by_link.delete();
    svt_adapter_by_link.delete();
    created_rc_count = 0;
    created_ep_count = 0;
    created_roles.delete();
    created_link_ids.delete();
    rc_adapter_count = 0;
    ep_adapter_count = 0;
    bridge_required = 1'b0;

    if (parent == null) begin
      errors.push_back("SVT backend parent component 不能为空");
      return 1'b0;
    end
    if ((global_cfg_arg == null) || (tl_cfg_arg == null)) begin
      errors.push_back("SVT backend requires non-null global_cfg and tl_cfg");
      return 1'b0;
    end

    configure(global_cfg_arg, tl_cfg_arg);

    // backend_cfg 由用户 test 在创建 TL env 前发布；没有注入时只创建
    // 一个默认对象，保持可读且不依赖 plusarg 才能运行。
    if (!uvm_config_db#(pcie_svt_backend_cfg)::get(
          parent, "", "pcie_svt_backend_cfg", backend_cfg) ||
        (backend_cfg == null)) begin
      backend_cfg = pcie_svt_backend_cfg::type_id::create(
        "default_pcie_svt_backend_cfg");
      if (backend_cfg == null) begin
        errors.push_back("SVT backend cfg factory returned null");
        return 1'b0;
      end
      backend_cfg.init_defaults();
    end

    backend_cfg.validate(cfg_errors);
    foreach (cfg_errors[i])
      errors.push_back(cfg_errors[i]);
    if (errors.size() != 0)
      return 1'b0;

    if (!backend_cfg.enable) begin
      errors.push_back("SVT backend_cfg.enable=0，但 global backend 仍选择了 SVT");
      return 1'b0;
    end

    if (global_cfg.links.size() == 0) begin
      errors.push_back("SVT backend 没有可消费的 global_cfg.links[]");
      return 1'b0;
    end

    foreach (global_cfg.links[i]) begin
      pcie_link_cfg link;
      pcie_tl_if_adapter adapter;
      svt_pcie_device_configuration svt_cfg;
      svt_pcie_device_status svt_status;
      svt_pcie_device_agent svt_agent;
      pcie_svt_if_adapter svt_adapter;
      svt_pcie_vif link_vif;
      string vif_key;
      string role_name;
      string agent_name;
      int role_index;

      link = global_cfg.links[i];
      if ((link == null) || !link.enabled || !link.use_svt)
        continue;

      if (!link.has_hdl_slot) begin
        errors.push_back($sformatf(
          "SVT link '%s' 未绑定静态 HDL slot", link.link_id));
        continue;
      end
      if (link.svt_node_id == "" || !link.svt_role_valid) begin
        errors.push_back($sformatf(
          "SVT link '%s' 必须声明 svt_node_id/svt_role", link.link_id));
        continue;
      end
      if ((link.svt_node_id != link.upstream_node_id) &&
          (link.svt_node_id != link.downstream_node_id)) begin
        errors.push_back($sformatf(
          "SVT node '%s' is not an endpoint of link '%s'",
          link.svt_node_id, link.link_id));
        continue;
      end
      if (!((link.svt_role == PCIE_DEVICE_RC) ||
            (link.svt_role == PCIE_DEVICE_EP))) begin
        errors.push_back($sformatf(
          "SVT link '%s' 只能创建 RC 或 EP agent", link.link_id));
        continue;
      end

      // SVT 的 RC/EP 角色还必须与链路方向一致。仅检查 node kind
      // 不足以阻止把上游 RC 配成 EP（或把下游 EP 配成 RC）；这类
      // 错配会在 agent 已创建后才表现为 LTSSM/配置空间异常，因此
      // 在 build 阶段直接拒绝。
      if ((link.svt_role == PCIE_DEVICE_RC) &&
          ((link.svt_node_id != link.upstream_node_id) ||
           (link.upstream_role != PCIE_TOPO_PORT_RC))) begin
        errors.push_back($sformatf(
          "SVT link '%s' RC node '%s' must be the upstream RC endpoint",
          link.link_id, link.svt_node_id));
        continue;
      end
      if ((link.svt_role == PCIE_DEVICE_EP) &&
          ((link.svt_node_id != link.downstream_node_id) ||
           (link.downstream_role != PCIE_TOPO_PORT_EP))) begin
        errors.push_back($sformatf(
          "SVT link '%s' EP node '%s' must be the downstream EP endpoint",
          link.link_id, link.svt_node_id));
        continue;
      end

      role_index = canonical_role_slot(link.svt_role, link.link_id);
      if (role_index < 0) begin
        errors.push_back($sformatf(
          "SVT link '%s' cannot be assigned a canonical %s physical slot",
          link.link_id,
          (link.svt_role == PCIE_DEVICE_RC) ? "RC" : "EP"));
        continue;
      end
      role_name = (link.svt_role == PCIE_DEVICE_RC) ? "RC" : "EP";
      vif_key = link.vif_key;
      if (vif_key == "") begin
        errors.push_back($sformatf(
          "SVT link '%s' 未提供 vif_key（静态 HDL slot=%0d）",
          link.link_id, link.hdl_slot));
        continue;
      end

      link_vif = null;
      if (!lookup_unified_vif(parent, vif_key, link_vif)) begin
        errors.push_back($sformatf(
          "SVT link '%s' 无法从 config_db 获取 Unified VIF '%s'",
          link.link_id, vif_key));
        continue;
      end

      if (svt_cfg_by_link.exists(link.link_id)) begin
        errors.push_back($sformatf(
          "SVT link '%s' 被重复创建", link.link_id));
        continue;
      end

      svt_cfg = svt_pcie_device_configuration::type_id::create(
        $sformatf("svt_cfg_%s", link.link_id));
      svt_status = svt_pcie_device_status::type_id::create(
        $sformatf("svt_status_%s", link.link_id));

      apply_link_configuration(i, link, link_vif, svt_cfg, errors);
      if (errors.size() != 0)
        continue;

      // 公开 hook 必须在 agent 创建前运行，保证用户修改的 cfg 能被
      // svt_pcie_device_agent.build_phase 读取。
      customize_svt_agent_cfg(i, link, svt_cfg);

      // 官方 Device Agent 采用 cfg/shared_status 这两个公开 config-db 键。
      // 配置发布必须早于 agent 创建，避免 agent build 时退回默认配置。
      // 路径使用即将创建的实例名，兼容官方 pcie-device-base-test 的写法。
      agent_name = $sformatf("svt_agent_%s_%0d", role_name, role_index);
      uvm_config_db#(svt_pcie_device_configuration)::set(
        parent, agent_name, "cfg", svt_cfg);
      uvm_config_db#(svt_pcie_device_status)::set(
        parent, agent_name, "shared_status", svt_status);

      svt_agent = svt_pcie_device_agent::type_id::create(agent_name, parent);
      if (svt_agent == null) begin
        errors.push_back($sformatf(
          "SVT link '%s' agent 创建失败", link.link_id));
        continue;
      end

      // svt_verbosity 是 UVM report verbosity，而不是 SVT 私有日志等级。
      // Device Agent 继承 uvm_component，set_report_verbosity_level_hier()
      // 是 R-2020.12/UVM 的公开 API；在 agent 创建后立即设置，确保其
      // build/connect 子组件也继承同一个等级。
      svt_agent.set_report_verbosity_level_hier(
        int'(backend_cfg.svt_verbosity));

      // adapter 与正式 agent 同属于 TL env，连接阶段会自动读取 svt_agent
      // 并绑定 tlp sequencer/monitor；测试无需再手工传 agent path。
      svt_adapter = pcie_svt_if_adapter::type_id::create(
        $sformatf("svt_adapter_%s_%0d", role_name, role_index), parent);
      if (svt_adapter == null) begin
        errors.push_back($sformatf(
          "SVT link '%s' adapter 创建失败", link.link_id));
        continue;
      end
      adapter = svt_adapter;
      uvm_config_db#(svt_pcie_device_agent)::set(
        parent, adapter.get_name(), "svt_agent", svt_agent);
      uvm_config_db#(string)::set(
        parent, adapter.get_name(), "svt_backend_mode",
        (backend_cfg.backend_mode == PCIE_SVT_BACKEND_FULL_VIP) ?
          "FULL_VIP" : "MAPPER_APP");
      uvm_config_db#(bit)::set(
        parent, adapter.get_name(), "svt_device_is_root",
        (link.svt_role == PCIE_DEVICE_RC));
      uvm_config_db#(svt_pcie_tl_configuration)::set(
        parent, adapter.get_name(), "svt_tl_cfg", svt_cfg.pcie_cfg.tl_cfg);

      svt_cfg_by_link[link.link_id] = svt_cfg;
      svt_status_by_link[link.link_id] = svt_status;
      svt_agent_by_link[link.link_id] = svt_agent;
      svt_adapter_by_link[link.link_id] = svt_adapter;
      // 在构建紧凑兼容视图之前先发布。中性映射表是权威数据，即使链路
      // 声明顺序被打乱或所有权稀疏也保持正确。
      publish_adapter_for_link(link.link_id, link.svt_role, adapter);
      if (link.svt_role == PCIE_DEVICE_RC)
        created_rc_count++;
      else
        created_ep_count++;
    end

    if (errors.size() != 0)
      return 1'b0;
    if ((created_rc_count == 0) && (created_ep_count == 0)) begin
      errors.push_back("SVT backend 没有 enabled/use_svt 的物理链路");
      return 1'b0;
    end

    // 紧凑数组是给旧 TL 调用者的兼容视图。按 provider 拥有的规范 ID
    // 重建，声明顺序就永远无法调换两个原本有效的 adapter。上面发布的
    // 关联映射表仍是权威物理连接表。
    begin
      string canonical_ids[$];

      global_cfg.get_role_link_ids(PCIE_DEVICE_RC, canonical_ids, 1'b1);
      foreach (canonical_ids[j]) begin
        if (!svt_adapter_by_link.exists(canonical_ids[j])) begin
          errors.push_back($sformatf(
            "SVT backend missing RC adapter for canonical link '%s'",
            canonical_ids[j]));
        end
        else
          rc_adapters.push_back(svt_adapter_by_link[canonical_ids[j]]);
      end

      canonical_ids.delete();
      global_cfg.get_role_link_ids(PCIE_DEVICE_EP, canonical_ids, 1'b1);
      foreach (canonical_ids[j]) begin
        if (!svt_adapter_by_link.exists(canonical_ids[j])) begin
          errors.push_back($sformatf(
            "SVT backend missing EP adapter for canonical link '%s'",
            canonical_ids[j]));
        end
        else
          ep_adapters.push_back(svt_adapter_by_link[canonical_ids[j]]);
      end

      // 诊断信息使用同一规范顺序。使用方不得从策略记录的声明顺序推断
      // 物理身份。
      created_roles.delete();
      created_link_ids.delete();
      canonical_ids.delete();
      global_cfg.get_role_link_ids(PCIE_DEVICE_RC, canonical_ids, 1'b1);
      foreach (canonical_ids[j]) begin
        created_roles.push_back(PCIE_DEVICE_RC);
        created_link_ids.push_back(canonical_ids[j]);
      end
      canonical_ids.delete();
      global_cfg.get_role_link_ids(PCIE_DEVICE_EP, canonical_ids, 1'b1);
      foreach (canonical_ids[j]) begin
        created_roles.push_back(PCIE_DEVICE_EP);
        created_link_ids.push_back(canonical_ids[j]);
      end
    end

    if (errors.size() != 0)
      return 1'b0;

    // 外部 SVT transport 需要 TL env 切换到 SV_IF_MODE，并使用 bridge FIFO
    // 处理反向请求/Completion，不能让 TL 内部 loopback 与 SVT 同时消费。
    bridge_required = 1'b1;
    rc_adapter_count = rc_adapters.size();
    ep_adapter_count = ep_adapters.size();
    return 1'b1;
  endfunction

  // 将一条 backend-neutral link policy 映射为 SVT configuration。这里使用
  // R-2020.12 已验证的 set_link_width_values/set_link_speed_values API，
  // 不访问 SVT 私有字段。
  protected function void apply_link_configuration(
      int link_index,
      pcie_link_cfg link,
      svt_pcie_vif link_vif,
      svt_pcie_device_configuration svt_cfg,
      output string errors[$]);
    int unsigned max_gen;
    bit fast_training;
    bit direct_speedup;
    bit selected_equalization;
    pcie_svt_transport_e selected_transport;
    int unsigned selected_eq_mode;
    bit [31:0] supported_widths;
    bit [31:0] supported_speeds;
    bit [31:0] selected_speed;
    time selected_timeout;
    int unsigned selected_timeout_ns;
    svt_pcie_pl_configuration::link_eq_mode_enum effective_eq_mode;

    if ((link == null) || (link_vif == null) || (svt_cfg == null)) begin
      errors.push_back("SVT link configuration received a null argument");
      return;
    end

    void'(backend_cfg.get_link_max_gen(link, max_gen));
    void'(backend_cfg.get_link_fast_training(link, fast_training));
    void'(backend_cfg.get_link_direct_speedup(link, direct_speedup));
    void'(backend_cfg.get_link_transport(link, selected_transport));
    void'(backend_cfg.get_link_equalization(link, selected_equalization));
    void'(backend_cfg.get_link_eq_mode(link, selected_eq_mode));
    void'(backend_cfg.get_link_timeout(link, selected_timeout));
    // VCS R-2020.12 对带有 nettype 的类型转换语法较严格；先转成
    // 普通 int，再赋给 unsigned 字段，保持 timeout 的纳秒单位。
    selected_timeout_ns = int'(selected_timeout / 1ns);

    if (!((max_gen == 4) || (max_gen == 5))) begin
      errors.push_back($sformatf(
        "SVT link '%s' effective Gen%0d 必须为 4 或 5", link.link_id, max_gen));
      return;
    end
    if (selected_transport != PCIE_SVT_TRANSPORT_SERIAL) begin
      errors.push_back($sformatf(
        "SVT link '%s' 请求了未实现的 PIPE transport", link.link_id));
      return;
    end
    if (selected_eq_mode > 3) begin
      errors.push_back($sformatf(
        "SVT link '%s' EQ mode=%0d 超出 0~3 范围",
        link.link_id, selected_eq_mode));
      return;
    end
    if (!((link.link_width == 4) || (link.link_width == 8) ||
          (link.link_width == 16))) begin
      errors.push_back($sformatf(
        "SVT link '%s' width x%0d 不受支持", link.link_id, link.link_width));
      return;
    end
    if (link_vif.num_physical_lanes < link.link_width) begin
      errors.push_back($sformatf(
        "SVT link '%s' 请求 x%0d，但 Unified VIF 只有 x%0d lanes",
        link.link_id, link.link_width, link_vif.num_physical_lanes));
      return;
    end

    svt_cfg.set_initial_values_via_unified_vif(1'b1, link_vif);
    if (svt_cfg.pcie_cfg == null) begin
      errors.push_back($sformatf(
        "SVT link '%s' did not initialize pcie_cfg from Unified VIF",
        link.link_id));
      return;
    end
    if (svt_cfg.pcie_cfg.pl_cfg == null) begin
      errors.push_back($sformatf(
        "SVT link '%s' has null pcie_cfg.pl_cfg", link.link_id));
      return;
    end
    if ((backend_cfg.backend_mode == PCIE_SVT_BACKEND_FULL_VIP) &&
        (svt_cfg.pcie_cfg.tl_cfg == null)) begin
      errors.push_back($sformatf(
        "SVT link '%s' FULL_VIP configuration has null pcie_cfg.tl_cfg",
        link.link_id));
      return;
    end
    // Unified VIF 默认 PCIe 3.0，不足以支撑下面的 Gen4/Gen5 速率广告。
    // 在应用 PL 速率策略前，先让 device 级 spec 版本与所选最大 Gen
    // 保持一致。
    svt_cfg.pcie_spec_ver = (max_gen == 5) ?
      svt_pcie_device_configuration::PCIE_SPEC_VER_5_0 :
      svt_pcie_device_configuration::PCIE_SPEC_VER_4_0;
    // FULL_VIP 的 Device Agent 自身就是被模拟设备，不应再声明 RTL
    // dut_model；只有 Mapper/Application 模式才由 SVT 创建 tlp_mapper。
    svt_cfg.dut_model = (backend_cfg.backend_mode == PCIE_SVT_BACKEND_MAPPER_APP) ?
      svt_pcie_device_configuration::RTL :
      svt_pcie_device_configuration::NOT_APPLICABLE;
    if (svt_cfg.device_is_root != (link.svt_role == PCIE_DEVICE_RC)) begin
      errors.push_back($sformatf(
        "SVT link '%s' 的 role 与 Unified VIF device_is_root 不一致",
        link.link_id));
      return;
    end

    case (link.link_width)
      4: supported_widths = 32'h0000_0007;
      8: supported_widths = 32'h0000_000f;
      16: supported_widths = 32'h0000_003f;
      default: supported_widths = 32'h0;
    endcase
    svt_cfg.pcie_cfg.pl_cfg.set_link_width_values(
      link.link_width, supported_widths, link.link_width);

    supported_speeds = `SVT_PCIE_SPEED_2_5G |
                       `SVT_PCIE_SPEED_5_0G |
                       `SVT_PCIE_SPEED_8_0G |
                       `SVT_PCIE_SPEED_16_0G;
    selected_speed = `SVT_PCIE_SPEED_16_0G;
    if (max_gen == 5) begin
      supported_speeds |= `SVT_PCIE_SPEED_32_0G;
      selected_speed = `SVT_PCIE_SPEED_32_0G;
    end
    svt_cfg.pcie_cfg.pl_cfg.set_link_speed_values(
      supported_speeds, selected_speed, selected_speed);

    effective_eq_mode = resolve_equalization_mode(
      max_gen, selected_equalization, selected_eq_mode);

    if (selected_equalization) begin
      // eq_mode=0 保持项目原有的“按 Gen/快速建链策略自动选择”；
      // 1/2/3 分别显式选择 Full、Bypass、No-Equalization。
      // Gen5 没有 R-2020.12 的 2.5→16 GT/s 直达捷径。仍要发布其显式
      // bypass 模式（含默认 eq_mode=0），确保 32 GT/s 路径不会从 VIF
      // 继承 Gen4/full-EQ 默认值。
      svt_cfg.pcie_cfg.pl_cfg.set_link_eq_attribute_values(
        effective_eq_mode,
        // SVT API 的第二个参数是“从 2.5 GT/s 直接加速到 16 GT/s”。
        direct_speedup, 3);
    end
    else begin
      // 关闭 EQ 时必须使用 NO_EQUALIZATION_NEEDED，并明确清零
      // direct-speed-up；不能把“关闭 EQ”误编码成 Gen4 Full-EQ shortcut。
      svt_cfg.pcie_cfg.pl_cfg.set_link_eq_attribute_values(
        effective_eq_mode, 1'b0, 0);
    end

    // TL env 是唯一配置空间控制者时默认关闭 SVT shadow lookup，避免
    // 动态 BDF 没有 shadow entry 的 warning；需要 SVT 自己管理配置空间的
    // 专用测试可以在 backend_cfg 中重新打开。
    if (svt_cfg.pcie_cfg.tl_cfg != null)
      svt_cfg.pcie_cfg.tl_cfg.enable_shadow_cfg_lookup =
        backend_cfg.enable_shadow_cfg_lookup;

    // timeout 的单位转换在这里集中完成，避免把 SystemVerilog time 直接
    // 赋给 SVT 的 int unsigned *_timeout_ns 字段造成精度/编译器差异。
    if (svt_cfg.pcie_cfg.tl_cfg != null) begin
      svt_cfg.pcie_cfg.tl_cfg.completion_timeout_ns = selected_timeout_ns;
      svt_cfg.pcie_cfg.tl_cfg.credit_starvation_timeout_ns = selected_timeout_ns;
    end

    // R-2020.12 的 active Driver App 使用 driver_cfg[0].completion_timeout_ns
    // 作为真正的 Completion Timeout；tl_cfg.completion_timeout_ns 只用于
    // TL monitor/RX-path 检查。此前仅设置 tl_cfg 会让 active driver 仍然
    // 使用默认 500 us，和项目的 link_timeout 意图不一致。
    if ((svt_cfg.driver_cfg.num() == 0) ||
        (svt_cfg.driver_cfg[0] == null)) begin
      errors.push_back($sformatf(
        "SVT link '%s' 缺少 driver_cfg[0]，无法设置 active driver CTO",
        link.link_id));
      return;
    end
    svt_cfg.driver_cfg[0].completion_timeout_ns = selected_timeout_ns;

    // SVT 日志字段属于 Device configuration 的公开 API；只在用户提供
    // 非空文件名时覆盖默认名字，保持旧的层次化日志命名行为。
    svt_cfg.pcie_cfg.enable_transaction_logging =
      backend_cfg.enable_transaction_log;
    svt_cfg.pcie_cfg.enable_symbol_logging = backend_cfg.enable_symbol_log;
    svt_cfg.pcie_cfg.enable_pl_history_logging =
      backend_cfg.enable_pl_history_log;
    svt_cfg.pcie_cfg.enable_ctrl_skp_logging = backend_cfg.enable_ctrl_skp_log;
    svt_cfg.pcie_cfg.enable_mbi_logging = backend_cfg.enable_mbi_log;
    svt_cfg.pcie_cfg.enable_flit_transaction_logging =
      backend_cfg.enable_flit_transaction_log;
    if (backend_cfg.transaction_log_filename != "")
      svt_cfg.pcie_cfg.transaction_log_filename =
        backend_cfg.transaction_log_filename;
    if (backend_cfg.symbol_log_filename != "")
      svt_cfg.pcie_cfg.symbol_log_filename = backend_cfg.symbol_log_filename;
    if (backend_cfg.pl_history_log_filename != "")
      svt_cfg.pcie_cfg.pl_history_log_filename =
        backend_cfg.pl_history_log_filename;
    if (backend_cfg.flit_transaction_log_filename != "")
      svt_cfg.pcie_cfg.flit_transaction_log_filename =
        backend_cfg.flit_transaction_log_filename;

    // active Device Agent 与 passive monitor 互斥。FULL_VIP/MAPPER backend
    // 都需要 active driver，因此这里不偷偷改 is_active；用户若要纯
    // passive monitor，应在 test 中创建独立 passive SVT agent。
    if (backend_cfg.enable_svt_monitor)
      `uvm_warning("SVT_BACKEND", {
        "enable_svt_monitor=1 requested, but active backend keeps ",
        "Device Agent active; use a separate passive monitor agent"})

    if (link.svt_role == PCIE_DEVICE_EP) begin
      svt_cfg.pcie_cfg.enable_multi_endpoint_mode =
        backend_cfg.enable_multi_endpoint_mode;
      if (backend_cfg.enable_multi_endpoint_mode &&
          svt_cfg.target_cfg.exists(0) && (svt_cfg.target_cfg[0] != null))
        svt_cfg.target_cfg[0].default_bar_ro_map = 32'h0000_ffff;
    end
    else begin
      svt_cfg.pcie_cfg.enable_multi_endpoint_mode = 1'b0;
    end

    // 当前 SVT API 没有统一的公开“timeout”字段；selected_timeout 仍保留
    // 在配置阶段用于 diagnostics，并通过 log 明确它不会伪造 SVT 私有设置。
    `uvm_info("SVT_BACKEND", $sformatf(
      "link=%s role=%s x%0d Gen%0d timeout=%0t monitor=%0b log=%0b",
      link.link_id,
      (link.svt_role == PCIE_DEVICE_RC) ? "RC" : "EP",
      link.link_width, max_gen, selected_timeout,
      backend_cfg.enable_svt_monitor, backend_cfg.enable_transaction_log),
      backend_cfg.svt_verbosity)
  endfunction
endclass

//------------------------------------------------------------------------------
// SVT provider factory。用户只需把该 factory 放入 config_db，TL env 就能
// 根据 global_cfg.backend 自动取得本 provider，不需要在 test 中逐个创建
// SVT agent/config/status。
//------------------------------------------------------------------------------

class pcie_svt_backend_factory extends pcie_tl_backend_factory;
  `uvm_object_utils(pcie_svt_backend_factory)

  // 构造函数：仅透传名字。
  function new(string name = "pcie_svt_backend_factory");
    super.new(name);
  endfunction

  // 创建一个 pcie_svt_backend provider 实例并返回其中性基类句柄。
  virtual function pcie_tl_backend_provider create_backend(string name);
    return pcie_svt_backend::type_id::create(name);
  endfunction
endclass
