//------------------------------------------------------------------------------
// 后端 provider 中性契约测试。
//
// 该测试只依赖 pcie_tl_pkg，故可在没有 Synopsys SVT 安装的 TL-only 回归
// 中编译。它用一个按 global_cfg.links[] 建立“物理 transport”句柄的 fake
// provider，验证 pcie_tl_env 与 SVT backend 之间的计数/角色契约，而不是
// 任何 SVT API。
//
// 覆盖的物理链路矩阵：
//   * 1 RC
//   * 4 RC
//   * 1 RC + 4 EP
//
// 每个矩阵都用一个 Host 和四个 Host 各运行一次。Host 数量只作为 memory
// domain 的合成输入，绝不能改变 transport agent 的数量或角色顺序。
//------------------------------------------------------------------------------

import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_tl_fake_backend_provider extends pcie_tl_backend_provider;
  `uvm_object_utils(pcie_tl_fake_backend_provider)

  // 合成的 Host 域输入。build_backend 刻意从不读取该值：物理 transport
  // 数量只能来自启用的 SVT 链路。
  int unsigned host_count;
  bit publish_adapters = 1'b1;
  bit bridge_required_value = 1'b1;

  bit build_called;
  int unsigned created_transport_count;
  int unsigned pool_cursor;
  pcie_tl_if_adapter adapter_pool[$];
  // bridge 契约会把 TL adapter 置于 SV_IF_MODE。因此 fake provider 发布
  // 与真实 provider 从 config_db 取得的相同 testbench interface；留空会
  // 让中性环境测试在断言执行前就死在 monitor 里。
  virtual pcie_tl_if provider_vif;
  // 测试专用记录：按声明顺序遍历时分配的句柄。与规范化查询结果对比，
  // 即使所有 adapter 非空且总数恰好一致，也能抓出映射被调换的情况。
  pcie_tl_if_adapter declared_adapter_by_link[string];
  pcie_tl_if_adapter rc_adapters[$];
  pcie_tl_if_adapter ep_adapters[$];
  pcie_device_role_e created_roles[$];
  string created_link_ids[$];

  // 构造函数：仅透传名字。
  function new(string name = "pcie_tl_fake_backend_provider");
    super.new(name);
  endfunction

  // pcie_tl_if_adapter 是 uvm_component。在测试的 build_phase 里预建一个
  // 不挂树的小池子；UVM 禁止 build_phase 之后再构造 component，而
  // provider 发现流程本身要到更晚的阶段才被驱动。
  function void preallocate_adapters(int unsigned count);
    pcie_tl_if_adapter adapter;

    adapter_pool.delete();
    for (int unsigned i = 0; i < count; i++) begin
      adapter = new($sformatf("fake_transport_%0d", i), null);
      adapter_pool.push_back(adapter);
    end
  endfunction

  // 模拟真实 provider 的构建流程：遍历启用的 SVT 链路，从预分配池领取
  // adapter 并按中性契约发布；任何缺 slot/vif_key/角色的链路都会向
  // errors 累加诊断并使返回值为 0。成功时重建规范顺序的 RC/EP 数组并
  // 更新计数。副作用：覆盖上一次 build 的全部记录队列。
  virtual function bit build_backend(
      uvm_component parent,
      pcie_global_cfg global_cfg_arg,
      pcie_tl_env_config tl_cfg_arg,
      output string errors[$]);
    errors.delete();
    build_called = 1'b1;
    rc_adapters.delete();
    ep_adapters.delete();
    created_roles.delete();
    created_link_ids.delete();
    declared_adapter_by_link.delete();
    created_transport_count = 0;
    pool_cursor = 0;

    if ((parent == null) || (global_cfg_arg == null) ||
        (tl_cfg_arg == null)) begin
      errors.push_back("fake provider requires non-null parent/config handles");
      return 1'b0;
    end

    configure(global_cfg_arg, tl_cfg_arg);
    clear_adapter_link_mapping();

    // 真实 SVT provider 在存在外部 transport 时置位该标志。fake 里保留
    // 同样行为，让中性契约也被覆盖到。
    bridge_required = bridge_required_value;

    foreach (global_cfg_arg.links[i]) begin
      pcie_link_cfg link;
      pcie_tl_if_adapter adapter;

      link = global_cfg_arg.links[i];
      if ((link == null) || !link.enabled || !link.use_svt)
        continue;

      if (!link.svt_role_valid ||
          !((link.svt_role == PCIE_DEVICE_RC) ||
            (link.svt_role == PCIE_DEVICE_EP))) begin
        errors.push_back($sformatf(
          "link '%s' has no valid RC/EP SVT role", link.link_id));
        continue;
      end

      // 与真实 SVT backend 相同：每条启用的 SVT 链路必须绑定静态
      // HDL slot，并提供 config_db VIF key；否则在创建 transport 前失败。
      if (!link.has_hdl_slot) begin
        errors.push_back($sformatf(
          "SVT link '%s' 未绑定静态 HDL slot", link.link_id));
        continue;
      end
      if (link.vif_key == "") begin
        errors.push_back($sformatf(
          "SVT link '%s' 未提供 vif_key", link.link_id));
        continue;
      end

      // 这是来自预分配池的测试专用句柄，因此不挂进 UVM 树。生产
      // provider 会在 pcie_tl_env 之下创建具体 adapter；两条路径暴露
      // 同一个中性 pcie_tl_if_adapter 契约。
      adapter = null;
      if (publish_adapters) begin
        if (pool_cursor >= adapter_pool.size()) begin
          errors.push_back("fake provider adapter pool is too small");
          continue;
        end
        adapter = adapter_pool[pool_cursor++];
        // 独立的 provider 调用会复用预分配池。当某次调用刻意不带 VIF
        // 时，不要抹掉已有的有效 interface；活跃的 env 可能还在监视池
        // 中的 adapter。
        if (provider_vif != null)
          adapter.vif = provider_vif;
      end
      created_roles.push_back(link.svt_role);
      created_link_ids.push_back(link.link_id);
      created_transport_count++;

      if (link.svt_role == PCIE_DEVICE_RC)
        rc_adapters.push_back(adapter);
      else
        ep_adapters.push_back(adapter);

      declared_adapter_by_link[link.link_id] = adapter;

      // fake 刻意发布与生产 provider 相同的中性契约。其紧凑数组会在
      // 下面重排，因此本循环按声明顺序遍历不影响身份映射。
      publish_adapter_for_link(link.link_id, link.svt_role, adapter);
    end

    if (errors.size() != 0)
      return 1'b0;

    // 按规范物理顺序重建紧凑角色数组。保持句柄唯一，测试才能发现序号
    // 被意外调换，而不只是检查每个槽位非空。
    rc_adapters.delete();
    ep_adapters.delete();
    created_roles.delete();
    created_link_ids.delete();
    begin
      string role_ids[$];

      global_cfg_arg.get_role_link_ids(PCIE_DEVICE_RC, role_ids, 1'b1);
      foreach (role_ids[j]) begin
        rc_adapters.push_back(get_adapter_for_link(role_ids[j]));
        created_roles.push_back(PCIE_DEVICE_RC);
        created_link_ids.push_back(role_ids[j]);
      end
      role_ids.delete();
      global_cfg_arg.get_role_link_ids(PCIE_DEVICE_EP, role_ids, 1'b1);
      foreach (role_ids[j]) begin
        ep_adapters.push_back(get_adapter_for_link(role_ids[j]));
        created_roles.push_back(PCIE_DEVICE_EP);
        created_link_ids.push_back(role_ids[j]);
      end
    end

    rc_adapter_count = rc_adapters.size();
    ep_adapter_count = ep_adapters.size();
    return 1'b1;
  endfunction

  // 按紧凑序号返回 RC adapter；越界或负索引返回 null，不得串到 EP 数组。
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
endclass

// 仅用于验证 env 的 factory discovery 路径，不依赖任何真实 SVT 类型。
class pcie_tl_fake_backend_factory extends pcie_tl_backend_factory;
  `uvm_object_utils(pcie_tl_fake_backend_factory)

  pcie_tl_fake_backend_provider last_provider;
  pcie_tl_if_adapter adapter_pool[$];
  virtual pcie_tl_if provider_vif;

  // 构造函数：仅透传名字。
  function new(string name = "pcie_tl_fake_backend_factory");
    super.new(name);
  endfunction

  // 创建 fake provider 并注入池/VIF；保存 last_provider 供测试断言
  // factory 路径确实被 env 调用过。
  virtual function pcie_tl_backend_provider create_backend(string name);
    last_provider = pcie_tl_fake_backend_provider::type_id::create(name);
    last_provider.adapter_pool = adapter_pool;
    last_provider.provider_vif = provider_vif;
    last_provider.publish_adapters = 1'b1;
    last_provider.bridge_required_value = 1'b0;
    return last_provider;
  endfunction
endclass

// 测试主体：独立驱动 fake provider 的构建/查询契约，并围绕真实
// pcie_tl_env 建一个环境矩阵，验证 agent 数量只随物理链路变化。
class pcie_tl_backend_provider_unit_test extends uvm_test;
  `uvm_component_utils(pcie_tl_backend_provider_unit_test)

  pcie_tl_if_adapter adapter_pool[$];
  pcie_tl_env env_matrix[$];
  int matrix_expected_rc[$];
  int matrix_expected_ep[$];
  int matrix_host_count[$];
  string matrix_labels[$];
  pcie_tl_fake_backend_factory factory;
  virtual pcie_tl_if matrix_vif;
  pcie_global_cfg one_rc_policy;
  pcie_global_cfg four_rc_policy;
  pcie_global_cfg one_rc_four_ep_policy;

  // 每个子 env 拿到私有的 adapter 池。若多个 env 共享同一个 component
  // 句柄，后来的 provider 调用会在先前的 monitor 已运行时覆盖其
  // mode/VIF 状态。

  // 构造函数：仅透传参数。
  function new(string name = "pcie_tl_backend_provider_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 取 testbench VIF、预建 adapter 池、构造三种拓扑策略并搭好环境
  // 矩阵——全部必须在 build_phase 完成（UVM 禁止 run_phase 加 env）。
  function void build_phase(uvm_phase phase);
    pcie_topology_cfg one_link_topology;
    pcie_topology_cfg four_link_topology;
    pcie_topology_cfg switch_topology;
    pcie_device_role_e one_rc_roles[];
    pcie_device_role_e four_rc_roles[];
    pcie_device_role_e one_rc_four_ep_roles[];
    pcie_tl_if_adapter adapter;

    super.build_phase(phase);

    // testbench 顶层用历史沿用的 `vif` key 发布一个 interface。取一次
    // 并传给每个 fake provider，既让 bridge-enable 断言有意义，又避免
    // 本 TL 包测试依赖任何 SVT 类型或实现。
    if (!uvm_config_db#(virtual pcie_tl_if)::get(
          this, "", "vif", matrix_vif) || (matrix_vif == null)) begin
      `uvm_fatal("BACKEND_PROVIDER",
                 "fake provider test requires the testbench virtual pcie_tl_if")
      return;
    end

    // provider 在 run_phase 里被驱动，但其 adapter 句柄是 UVM
    // component，必须在 build phase 结束前就存在。
    for (int i = 0; i < 64; i++) begin
      adapter = new($sformatf("matrix_adapter_%0d", i), this);
      adapter.vif = matrix_vif;
      adapter_pool.push_back(adapter);
    end

    // 在子环境进入各自的 build_phase 前准备好全部策略；UVM 不允许在
    // run_phase 添加 env。
    one_link_topology = pcie_topology_builder::build_ep_x16(4);
    one_rc_roles = new[one_link_topology.links.size()];
    one_rc_roles[0] = PCIE_DEVICE_RC;
    one_rc_policy = make_svt_policy(one_link_topology, one_rc_roles);
    // 下面的 provider 刻意报告 bridge_required=0。一旦非 TL backend 激
    // 活，全局策略标志仍必须能显式请求外部 bridge；该断言是这条契约的
    // RED 半边，防止字段沦为死配置位。
    one_rc_policy.svt_bridge_enable = 1'b1;

    four_link_topology = build_four_direct_links();
    four_rc_roles = new[four_link_topology.links.size()];
    foreach (four_rc_roles[i]) four_rc_roles[i] = PCIE_DEVICE_RC;
    four_rc_policy = make_svt_policy(four_link_topology, four_rc_roles);

    switch_topology = pcie_topology_builder::build_switch_1x16_4x4(4);
    one_rc_four_ep_roles = new[switch_topology.links.size()];
    one_rc_four_ep_roles[0] = PCIE_DEVICE_RC;
    for (int i = 1; i < one_rc_four_ep_roles.size(); i++)
      one_rc_four_ep_roles[i] = PCIE_DEVICE_EP;
    one_rc_four_ep_policy = make_svt_policy(
      switch_topology, one_rc_four_ep_roles);
    // 在 Switch DSP 上执行与直连 RC 相同的显式 bridge 策略。下面的
    // connect-phase 回归会抓出把这些 adapter 悄悄改回 TLM_MODE 的
    // 过期赋值。
    one_rc_four_ep_policy.svt_bridge_enable = 1'b1;

    build_environment_matrix(one_rc_policy, four_rc_policy,
                             one_rc_four_ep_policy);
    create_factory_environment(one_rc_policy);
  endfunction

  // 通过 config_db 注入 backend factory（而非现成 provider），构建
  // env_factory 环境，验证 env 的 factory 发现路径。
  function void create_factory_environment(pcie_global_cfg policy);
    pcie_tl_env_config tl_policy;
    pcie_tl_env env;
    pcie_tl_if_adapter factory_pool[$];

    tl_policy = pcie_tl_env_config::type_id::create("env_factory_policy");
    tl_policy.if_mode = TLM_MODE;
    tl_policy.rc_is_active = UVM_PASSIVE;
    tl_policy.ep_is_active = UVM_PASSIVE;
    tl_policy.fc_enable = 1'b0;
    tl_policy.scb_enable = 1'b0;
    tl_policy.cov_enable = 1'b0;
    tl_policy.use_unified_mem = 1'b0;

    factory = pcie_tl_fake_backend_factory::type_id::create("matrix_factory");
    allocate_env_adapter_pool("factory", policy.links.size(), factory_pool);
    factory.adapter_pool = factory_pool;
    factory.provider_vif = matrix_vif;
    uvm_config_db#(pcie_global_cfg)::set(
      this, "env_factory", "global_cfg", policy);
    uvm_config_db#(pcie_tl_env_config)::set(
      this, "env_factory", "tl_policy_cfg", tl_policy);
    uvm_config_db#(pcie_tl_backend_factory)::set(
      this, "env_factory", "pcie_tl_backend_factory", factory);
    env = pcie_tl_env::type_id::create("env_factory", this);
    env_matrix.push_back(env);
    matrix_expected_rc.push_back(1);
    matrix_expected_ep.push_back(0);
    matrix_host_count.push_back(1);
    matrix_labels.push_back("env_factory");
  endfunction

  // 围绕中性 fake provider 构建一个真实 pcie_tl_env。测试不依赖 SVT
  // 类型，但仍检查环境实际的 rc_agents[]/ep_agents[] 创建决策。
  function void create_env_case(
      string label,
      pcie_global_cfg policy,
      int expected_rc,
      int expected_ep,
      int unsigned host_value);
    pcie_tl_env_config tl_policy;
    pcie_tl_fake_backend_provider provider;
    pcie_tl_env env;
    pcie_tl_if_adapter env_pool[$];

    tl_policy = pcie_tl_env_config::type_id::create(
      $sformatf("env_policy_%s", label));
    tl_policy.if_mode = TLM_MODE;
    tl_policy.rc_is_active = UVM_PASSIVE;
    tl_policy.ep_is_active = UVM_PASSIVE;
    tl_policy.fc_enable = 1'b0;
    tl_policy.scb_enable = 1'b0;
    tl_policy.cov_enable = 1'b0;
    tl_policy.use_unified_mem = 1'b0;

    provider = pcie_tl_fake_backend_provider::type_id::create(
      $sformatf("env_provider_%s", label));
    provider.host_count = host_value;
    allocate_env_adapter_pool(label, policy.links.size(), env_pool);
    provider.adapter_pool = env_pool;
    provider.provider_vif = matrix_vif;
    provider.publish_adapters = 1'b1;
    provider.bridge_required_value = 1'b0;

    uvm_config_db#(pcie_global_cfg)::set(
      this, label, "global_cfg", policy);
    uvm_config_db#(pcie_tl_env_config)::set(
      this, label, "tl_policy_cfg", tl_policy);
    uvm_config_db#(pcie_tl_backend_provider)::set(
      this, label, "pcie_tl_backend_provider", provider);

    env = pcie_tl_env::type_id::create(label, this);
    env_matrix.push_back(env);
    matrix_expected_rc.push_back(expected_rc);
    matrix_expected_ep.push_back(expected_ep);
    matrix_host_count.push_back(host_value);
    matrix_labels.push_back(label);
  endfunction

  // 在测试 build phase 内、子 env 进入自己的 build/connect 之前分配
  // adapter。对畸形/空策略也刻意至少创建一个句柄，负向测试才不会误踩
  // 空队列索引。
  function void allocate_env_adapter_pool(
      string label,
      int unsigned requested_count,
      output pcie_tl_if_adapter pool[$]);
    int unsigned count;
    pcie_tl_if_adapter adapter;

    pool.delete();
    count = (requested_count == 0) ? 1 : requested_count;
    for (int unsigned i = 0; i < count; i++) begin
      adapter = new($sformatf("%s_adapter_%0d", label, i), this);
      adapter.vif = matrix_vif;
      pool.push_back(adapter);
    end
  endfunction

  // 按三种物理拓扑各建 Host1/Host4 两个变体，共六个 env。
  function void build_environment_matrix(
      pcie_global_cfg one_rc_policy,
      pcie_global_cfg four_rc_policy,
      pcie_global_cfg one_rc_four_ep_policy);
    // 每种物理拓扑两个 Host 域变体，证明选取 transport agent 数组时
    // 不会参考 Host 数量。
    create_env_case("env_one_rc_h1", one_rc_policy, 1, 0, 1);
    create_env_case("env_one_rc_h4", one_rc_policy, 1, 0, 4);
    create_env_case("env_four_rc_h1", four_rc_policy, 4, 0, 1);
    create_env_case("env_four_rc_h4", four_rc_policy, 4, 0, 4);
    create_env_case("env_one_rc_four_ep_h1",
                    one_rc_four_ep_policy, 1, 4, 1);
    create_env_case("env_one_rc_four_ep_h4",
                    one_rc_four_ep_policy, 1, 4, 4);
  endfunction

  // 逐个检查矩阵中真实 env 的 agent 数组/别名/使能标志，并对比
  // Host1/Host4 配对确认 Host 数不影响 transport 侧。
  function void check_environment_matrix();
    int seen_host1_rc[$];
    int seen_host1_ep[$];

    require(env_matrix.size() == 7,
            "environment matrix did not create expected variants");
    foreach (env_matrix[i]) begin
      pcie_tl_env env;

      env = env_matrix[i];
      require(env != null,
              $sformatf("%s: environment handle is null", matrix_labels[i]));
      if (env == null)
        continue;

      require(env.backend_provider_active,
              $sformatf("%s: backend provider was not activated",
                        matrix_labels[i]));
      if (matrix_labels[i] == "env_factory") begin
        require(factory != null && factory.last_provider != null,
                "backend factory did not create a provider");
        require(env.cfg.rc_agent_enable && !env.cfg.ep_agent_enable,
                "factory provider adapter counts did not override RC/EP enable");
        require(env.bridge_required,
                "global svt_bridge_enable was not consumed by active provider");
      end
      require(env.cfg != null,
              $sformatf("%s: environment config is null", matrix_labels[i]));
      require(env.rc_agents.size() == matrix_expected_rc[i],
              $sformatf("%s Host%0d: RC agent array size=%0d expected=%0d",
                        matrix_labels[i], matrix_host_count[i],
                        env.rc_agents.size(), matrix_expected_rc[i]));
      require(env.ep_agents.size() == matrix_expected_ep[i],
              $sformatf("%s Host%0d: EP agent array size=%0d expected=%0d",
                        matrix_labels[i], matrix_host_count[i],
                        env.ep_agents.size(), matrix_expected_ep[i]));
      require(env.cfg.rc_agent_enable == (matrix_expected_rc[i] != 0),
              $sformatf("%s: RC enable does not follow provider count",
                        matrix_labels[i]));
      require(env.cfg.ep_agent_enable == (matrix_expected_ep[i] != 0),
              $sformatf("%s: EP enable does not follow provider count",
                        matrix_labels[i]));

      if (matrix_host_count[i] == 1) begin
        seen_host1_rc.push_back(env.rc_agents.size());
        seen_host1_ep.push_back(env.ep_agents.size());
      end
      else begin
        // build_environment_matrix() 里 Host4 用例紧跟其配对的 Host1
        // 用例。与前一个变体直接比较，让独立性断言显式化。
        require(env.rc_agents.size() == seen_host1_rc[seen_host1_rc.size()-1],
                $sformatf("%s: Host count changed RC agent count",
                          matrix_labels[i]));
        require(env.ep_agents.size() == seen_host1_ep[seen_host1_ep.size()-1],
                $sformatf("%s: Host count changed EP agent count",
                          matrix_labels[i]));
      end

      if (matrix_expected_rc[i] > 0)
        require(env.rc_agent != null,
                $sformatf("%s: RC alias is null", matrix_labels[i]));
      else
        require(env.rc_agent == null,
                $sformatf("%s: RC alias exists with zero RC count",
                          matrix_labels[i]));

      if (matrix_expected_ep[i] > 0)
        require(env.ep_agents[0] != null,
                $sformatf("%s: first EP agent is null", matrix_labels[i]));

      if ((matrix_labels[i] == "env_one_rc_four_ep_h1") ||
          (matrix_labels[i] == "env_one_rc_four_ep_h4")) begin
        // Switch provider adapter 是外部 transport 端点。全局 bridge
        // 策略必须在 apply_config() 和 Switch 专用 connect 接线两个环节
        // 后仍对每个物理 DSP 槽位保持有效。
        foreach (env.ep_adapters[dsp_index]) begin
          if (env.ep_adapters[dsp_index] != null)
            require(env.ep_adapters[dsp_index].mode == SV_IF_MODE,
                    $sformatf(
                      "%s DSP%0d adapter lost SV_IF_MODE in connect_phase",
                      matrix_labels[i], dsp_index));
        end
      end
    end
  endfunction

  // 断言辅助：条件不成立时报 UVM_ERROR。
  function void require(bit condition, string message);
    if (!condition)
      `uvm_error("BACKEND_PROVIDER", message)
  endfunction

  // 构建四条独立 RC-EP 直连链路的拓扑（4 RC 用例的输入）。
  function pcie_topology_cfg build_four_direct_links();
    pcie_topology_builder builder;

    builder = pcie_topology_builder::type_id::create("four_direct_builder");
    for (int i = 0; i < 4; i++) begin
      void'(builder.add_rc($sformatf("RC%0d", i)));
      void'(builder.add_ep($sformatf("EP%0d", i)));
    end
    for (int i = 0; i < 4; i++) begin
      void'(builder.connect(
        $sformatf("RC%0d_EP%0d", i, i),
        $sformatf("RC%0d", i), PCIE_TOPO_PORT_RC, 0,
        $sformatf("EP%0d", i), PCIE_TOPO_PORT_EP, 0, 8, 4));
    end
    return builder.finish();
  endfunction

  // 构建声明顺序与字典序刻意不一致的三条直连链路（Z/M/A），用于验证
  // 规范化 link ID 排序不受声明顺序影响。
  function pcie_topology_cfg build_shuffled_direct_links();
    pcie_topology_builder builder;
    pcie_topology_link_cfg swap;

    builder = pcie_topology_builder::type_id::create(
      "provider_shuffled_direct_builder");
    void'(builder.add_rc("RC_Z"));
    void'(builder.add_ep("EP_Z"));
    void'(builder.add_rc("RC_A"));
    void'(builder.add_ep("EP_A"));
    void'(builder.add_rc("RC_M"));
    void'(builder.add_ep("EP_M"));
    void'(builder.connect("Z_LINK", "RC_Z", PCIE_TOPO_PORT_RC, 0,
                          "EP_Z", PCIE_TOPO_PORT_EP, 0, 8, 4));
    void'(builder.connect("M_LINK", "RC_M", PCIE_TOPO_PORT_RC, 0,
                          "EP_M", PCIE_TOPO_PORT_EP, 0, 8, 4));
    void'(builder.connect("A_LINK", "RC_A", PCIE_TOPO_PORT_RC, 0,
                          "EP_A", PCIE_TOPO_PORT_EP, 0, 8, 4));
    return builder.finish();
  endfunction

  // 构建双 USP + 三 DSP 的 Switch 拓扑，并反转链路声明顺序，验证
  // USP/DSP 规范序号跟随物理端口而非声明顺序。
  function pcie_topology_cfg build_shuffled_switch_links();
    pcie_topology_builder builder;
    pcie_topology_cfg topology;
    pcie_topology_link_cfg swap;
    int owners[];

    builder = pcie_topology_builder::type_id::create(
      "provider_shuffled_switch_builder");
    owners = new[3];
    owners[0] = 0;
    owners[1] = 1;
    owners[2] = 1;
    void'(builder.add_rc("RC0"));
    void'(builder.add_rc("RC1"));
    void'(builder.add_switch("SW0", 2, 3, owners));
    for (int i = 0; i < 3; i++)
      void'(builder.add_ep($sformatf("EP%0d", i)));
    void'(builder.connect("USP_Z", "RC0", PCIE_TOPO_PORT_RC, 0,
                          "SW0", PCIE_TOPO_PORT_USP, 0, 8, 4));
    void'(builder.connect("USP_A", "RC1", PCIE_TOPO_PORT_RC, 0,
                          "SW0", PCIE_TOPO_PORT_USP, 1, 8, 4));
    for (int i = 0; i < 3; i++)
      void'(builder.connect($sformatf("DSP_%0d", i), "SW0",
                            PCIE_TOPO_PORT_DSP, i, $sformatf("EP%0d", i),
                            PCIE_TOPO_PORT_EP, 0, 4, 4));
    topology = builder.finish();
    // 反转声明顺序，同时保留每条边的物理端口。
    for (int i = 0; i < (topology.links.size() / 2); i++) begin
      swap = topology.links[i];
      topology.links[i] = topology.links[topology.links.size() - 1 - i];
      topology.links[topology.links.size() - 1 - i] = swap;
    end
    return topology;
  endfunction

  // 用乱序直连、乱序 Switch、稀疏所有权三个场景验证 link→adapter 身份
  // 映射：规范序号必须落在正确物理链路，外部槽位保持 null。
  function void exercise_shuffled_and_sparse_mappings();
    pcie_topology_cfg topology;
    pcie_global_cfg policy;
    pcie_device_role_e roles[];
    pcie_tl_fake_backend_provider provider;
    pcie_tl_env_config tl_cfg;
    string errors[$];
    string role_ids[$];
    pcie_tl_if_adapter expected;
    bit built;

    topology = build_shuffled_direct_links();
    roles = new[topology.links.size()];
    foreach (roles[i]) roles[i] = PCIE_DEVICE_RC;
    policy = make_svt_policy(topology, roles);
    provider = pcie_tl_fake_backend_provider::type_id::create(
      "provider_shuffled_direct");
    provider.adapter_pool = adapter_pool;
    tl_cfg = pcie_tl_env_config::type_id::create("provider_shuffled_tl_cfg");
    built = provider.build_backend(this, policy, tl_cfg, errors);
    require(built && (errors.size() == 0),
            "shuffled direct provider build failed");
    policy.get_role_link_ids(PCIE_DEVICE_RC, role_ids, 1'b1);
    require((role_ids.size() == 3) && (role_ids[0] == "A_LINK") &&
            (role_ids[1] == "M_LINK") && (role_ids[2] == "Z_LINK"),
            "global policy direct canonical IDs are not lexical");
    foreach (role_ids[i]) begin
      expected = provider.declared_adapter_by_link[role_ids[i]];
      require(provider.get_adapter_for_link(role_ids[i]) == expected,
              $sformatf("shuffled direct map swapped link '%s'", role_ids[i]));
      require(provider.get_rc_adapter(i) == expected,
              $sformatf("shuffled direct packed RC ordinal %0d is wrong", i));
    end

    topology = build_shuffled_switch_links();
    roles = new[topology.links.size()];
    foreach (topology.links[i]) begin
      roles[i] = (topology.links[i].upstream_role == PCIE_TOPO_PORT_DSP) ?
                 PCIE_DEVICE_EP : PCIE_DEVICE_RC;
    end
    policy = make_svt_policy(topology, roles);
    provider = pcie_tl_fake_backend_provider::type_id::create(
      "provider_shuffled_switch");
    provider.adapter_pool = adapter_pool;
    tl_cfg = pcie_tl_env_config::type_id::create("provider_switch_tl_cfg");
    errors.delete();
    built = provider.build_backend(this, policy, tl_cfg, errors);
    require(built && (errors.size() == 0),
            "shuffled Switch provider build failed");
    policy.get_role_link_ids(PCIE_DEVICE_RC, role_ids, 1'b1);
    require((role_ids.size() == 2) && (role_ids[0] == "USP_Z") &&
            (role_ids[1] == "USP_A"),
            "Switch USP canonical IDs do not follow port indexes");
    foreach (role_ids[i])
      require(provider.get_rc_adapter(i) ==
              provider.declared_adapter_by_link[role_ids[i]],
              $sformatf("Switch USP ordinal %0d is mapped to wrong link", i));
    policy.get_role_link_ids(PCIE_DEVICE_EP, role_ids, 1'b1);
    require((role_ids.size() == 3) && (role_ids[0] == "DSP_0") &&
            (role_ids[1] == "DSP_1") && (role_ids[2] == "DSP_2"),
            "Switch DSP canonical IDs do not follow port indexes");
    foreach (role_ids[i])
      require(provider.get_ep_adapter(i) ==
              provider.declared_adapter_by_link[role_ids[i]],
              $sformatf("Switch DSP ordinal %0d is mapped to wrong link", i));

    // 稀疏所有权：只有中间那条物理链路归 provider。正确的映射在紧凑
    // 序号 0 返回其唯一句柄，外部槽位保持未解析而不是被压缩进来。
    topology = build_shuffled_direct_links();
    roles = new[topology.links.size()];
    foreach (roles[i]) roles[i] = PCIE_DEVICE_RC;
    policy = make_svt_policy(topology, roles);
    foreach (policy.links[i]) begin
      policy.links[i].use_svt = (policy.links[i].link_id == "M_LINK");
    end
    provider = pcie_tl_fake_backend_provider::type_id::create(
      "provider_sparse_direct");
    provider.adapter_pool = adapter_pool;
    tl_cfg = pcie_tl_env_config::type_id::create("provider_sparse_tl_cfg");
    errors.delete();
    built = provider.build_backend(this, policy, tl_cfg, errors);
    require(built && (errors.size() == 0),
            "sparse provider build failed");
    require(provider.get_rc_adapter_count() == 1,
            "sparse provider did not compact owned RC count");
    require(provider.get_adapter_for_link("A_LINK") == null,
            "external A_LINK unexpectedly received an adapter");
    require(provider.get_adapter_for_link("Z_LINK") == null,
            "external Z_LINK unexpectedly received an adapter");
    require(provider.get_adapter_for_link("M_LINK") != null,
            "owned middle M_LINK has no adapter");
    require(provider.get_rc_adapter(0) ==
            provider.declared_adapter_by_link["M_LINK"],
            "sparse compact ordinal points at the wrong physical link");
    require(provider.validate_link_adapter_mapping(errors),
            "sparse provider strict map validation failed");
  endfunction

  // 把拓扑图复制进 global_cfg，再逐条链路显式标注 provider 模拟的物理
  // 节点。静态 slot 元数据也一并设置，使策略能代表真实 SVT 配置。
  function pcie_global_cfg make_svt_policy(
      pcie_topology_cfg topology,
      input pcie_device_role_e roles[]);
    pcie_global_cfg policy;
    string errors[$];

    policy = pcie_global_cfg::type_id::create("matrix_global_cfg");
    policy.build_default_for_topology(topology);
    policy.backend = PCIE_BACKEND_SVT_REAL_DUT;
    policy.runtime_num_links = topology.links.size();

    require(roles.size() == policy.links.size(),
            "role vector size does not match global link count");
    foreach (policy.links[i]) begin
      policy.links[i].use_svt = 1'b1;
      policy.links[i].svt_role_valid = 1'b1;
      policy.links[i].svt_role = roles[i];
      policy.links[i].svt_node_id =
        (roles[i] == PCIE_DEVICE_RC) ?
          topology.links[i].upstream_node_id :
          topology.links[i].downstream_node_id;
      policy.links[i].has_hdl_slot = 1'b1;
      policy.links[i].hdl_slot = i;
      policy.links[i].vif_key = $sformatf("matrix_vif_%0d", i);
    end

    policy.validate(errors);
    require(errors.size() == 0,
            "matrix global_cfg policy failed backend-neutral validation");
    return policy;
  endfunction

  // 把 provider 记录的角色/链路序列压成字符串签名，便于跨变体比较。
  function string role_signature(
      pcie_tl_fake_backend_provider provider);
    string signature;

    signature = "";
    foreach (provider.created_roles[i]) begin
      signature = {signature,
                   $sformatf("%0d:%s;", provider.created_roles[i],
                             provider.created_link_ids[i])};
    end
    return signature;
  endfunction

  // 单个拓扑用例：用 Host1/Host4 各跑一次 provider 构建，断言计数、
  // 句柄保持、身份映射、越界防护，并比较两次角色签名完全一致。
  task exercise_case(
      string label,
      pcie_global_cfg policy,
      int expected_rc,
      int expected_ep);
    string baseline_signature;
    int host_values[2];

    host_values[0] = 1;
    host_values[1] = 4;

    for (int variant = 0; variant < 2; variant++) begin
      pcie_tl_fake_backend_provider provider;
      pcie_tl_env_config tl_cfg;
      string errors[$];
      string signature;
      bit built;

      provider = pcie_tl_fake_backend_provider::type_id::create(
        $sformatf("provider_%s_%0d", label, variant));
      provider.host_count = host_values[variant];
      provider.adapter_pool = adapter_pool;
      tl_cfg = pcie_tl_env_config::type_id::create(
        $sformatf("tl_cfg_%s_%0d", label, variant));

      // 刻意填入无关的原生计数。provider 必须从链路报告物理 RC/EP
      // 所有权，而不是从 Host 或 cfg 记账字段推断。
      tl_cfg.num_rc = 99;
      tl_cfg.num_ep = 99;
      built = provider.build_backend(this, policy, tl_cfg, errors);
      require(built, $sformatf("%s: provider build failed", label));
      require(errors.size() == 0,
              $sformatf("%s: provider returned unexpected errors", label));
      require(provider.build_called,
              $sformatf("%s: build_backend was not called", label));
      require(provider.global_cfg == policy,
              $sformatf("%s: global_cfg handle was not retained", label));
      require(provider.tl_cfg == tl_cfg,
              $sformatf("%s: tl_cfg handle was not retained", label));
      require(provider.bridge_required,
              $sformatf("%s: bridge_required was not asserted", label));

      begin
        string mapping_errors[$];
        require(provider.validate_link_adapter_mapping(mapping_errors),
                $sformatf("%s: strict link/adapter mapping failed", label));
        require(mapping_errors.size() == 0,
                $sformatf("%s: mapping validation returned diagnostics", label));
      end

      require(provider.get_rc_adapter_count() == expected_rc,
              $sformatf("%s: expected %0d RC adapters, got %0d (Host%0d)",
                        label, expected_rc,
                        provider.get_rc_adapter_count(), provider.host_count));
      require(provider.get_ep_adapter_count() == expected_ep,
              $sformatf("%s: expected %0d EP adapters, got %0d (Host%0d)",
                        label, expected_ep,
                        provider.get_ep_adapter_count(), provider.host_count));
      require(provider.created_transport_count == expected_rc + expected_ep,
              $sformatf("%s: physical transport count mismatch", label));
      require(provider.created_roles.size() == expected_rc + expected_ep,
              $sformatf("%s: role record count mismatch", label));

      for (int i = 0; i < expected_rc; i++)
        require(provider.get_rc_adapter(i) != null,
                $sformatf("%s: RC adapter %0d is missing", label, i));
      for (int i = 0; i < expected_ep; i++)
        require(provider.get_ep_adapter(i) != null,
                $sformatf("%s: EP adapter %0d is missing", label, i));

      // 物理身份是权威依据：按全局 link_id 查询必须解析到同一角色
      // adapter，未知 ID 绝不能回退到任意序号。
      foreach (policy.links[link_index]) begin
        pcie_link_cfg link;
        link = policy.links[link_index];
        if ((link != null) && link.enabled && link.use_svt)
          require(provider.get_adapter_for_link(link.link_id) != null,
                  $sformatf("%s: adapter missing for link '%s'",
                            label, link.link_id));
      end
      require(provider.get_adapter_for_link("unknown-link") == null,
              $sformatf("%s: unknown link_id unexpectedly resolved", label));

      // 首个非法索引和负索引都不得泄漏另一角色的句柄，也不得越过
      // provider 动态数组的边界读取。
      require(provider.get_rc_adapter(expected_rc) == null,
              $sformatf("%s: out-of-range RC adapter was returned", label));
      require(provider.get_ep_adapter(expected_ep) == null,
              $sformatf("%s: out-of-range EP adapter was returned", label));
      require(provider.get_rc_adapter(-1) == null,
              $sformatf("%s: negative RC adapter index was accepted", label));
      require(provider.get_ep_adapter(-1) == null,
              $sformatf("%s: negative EP adapter index was accepted", label));

      signature = role_signature(provider);
      if (variant == 0)
        baseline_signature = signature;
      else begin
        require(signature == baseline_signature,
                $sformatf(
                  "%s: changing Host count changed physical role/link order",
                  label));
      end

      `uvm_info("BACKEND_PROVIDER",
                $sformatf("%s Host%0d -> RC=%0d EP=%0d roles=%s",
                          label, provider.host_count,
                          provider.get_rc_adapter_count(),
                          provider.get_ep_adapter_count(), signature),
                UVM_LOW)
    end
  endtask

  // 负向路径：缺少静态 slot 或 VIF key 时，provider 必须拒绝构建，且
  // 不应留下任何已创建的 transport 句柄。
  task exercise_error_paths();
    pcie_global_cfg policy;
    pcie_tl_fake_backend_provider provider;
    pcie_tl_env_config tl_cfg;
    string errors[$];
    bit built;

    policy = pcie_global_cfg::type_id::create("missing_slot_policy");
    policy.copy(one_rc_policy);
    policy.links[0].has_hdl_slot = 1'b0;
    provider = pcie_tl_fake_backend_provider::type_id::create(
      "provider_missing_slot");
    tl_cfg = pcie_tl_env_config::type_id::create("tl_cfg_missing_slot");
    built = provider.build_backend(this, policy, tl_cfg, errors);
    require(!built, "missing HDL slot unexpectedly passed backend build");
    require(errors.size() != 0,
            "missing HDL slot did not report a diagnostic");
    require(provider.created_transport_count == 0,
            "missing HDL slot left created transport handles");

    policy = pcie_global_cfg::type_id::create("missing_vif_policy");
    policy.copy(one_rc_policy);
    policy.links[0].vif_key = "";
    provider = pcie_tl_fake_backend_provider::type_id::create(
      "provider_missing_vif");
    tl_cfg = pcie_tl_env_config::type_id::create("tl_cfg_missing_vif");
    errors.delete();
    built = provider.build_backend(this, policy, tl_cfg, errors);
    require(!built, "missing VIF key unexpectedly passed backend build");
    require(errors.size() != 0,
            "missing VIF key did not report a diagnostic");
    require(provider.created_transport_count == 0,
            "missing VIF key left created transport handles");
  endtask

  // 负向路径：同一个非空 adapter 句柄不能代表两条不同物理链路。
  // 先用正常 provider 建立完整的 packed view，再只重发布 link map，
  // 这样计数、角色和静态 slot 都保持有效，失败原因应精确落在
  // adapter identity alias，而不是被其它缺失映射诊断掩盖。
  task exercise_adapter_identity_alias();
    pcie_global_cfg policy;
    pcie_tl_fake_backend_provider provider;
    pcie_tl_env_config tl_cfg;
    pcie_tl_if_adapter alias_adapter;
    string ids[$];
    string errors[$];
    bit valid;
    bit alias_error_found;

    policy = pcie_global_cfg::type_id::create("adapter_alias_policy");
    policy.copy(four_rc_policy);
    provider = pcie_tl_fake_backend_provider::type_id::create(
      "provider_adapter_alias");
    provider.adapter_pool = adapter_pool;
    tl_cfg = pcie_tl_env_config::type_id::create("tl_cfg_adapter_alias");
    valid = provider.build_backend(this, policy, tl_cfg, errors);
    require(valid && (errors.size() == 0),
            "adapter identity alias setup provider build failed");

    policy.get_role_link_ids(PCIE_DEVICE_RC, ids, 1'b1);
    require(ids.size() >= 2,
            "adapter identity alias test needs at least two RC links");
    if (ids.size() < 2)
      return;

    alias_adapter = provider.declared_adapter_by_link[ids[0]];
    provider.clear_adapter_link_mapping();
    foreach (ids[i]) begin
      if (i == 1)
        provider.publish_adapter_for_link(ids[i], PCIE_DEVICE_RC,
                                          alias_adapter);
      else
        provider.publish_adapter_for_link(
          ids[i], PCIE_DEVICE_RC,
          provider.declared_adapter_by_link[ids[i]]);
    end

    errors.delete();
    valid = provider.validate_link_adapter_mapping(errors);
    require(!valid,
            "provider accepted one adapter identity for multiple links");
    alias_error_found = 1'b0;
    foreach (errors[i]) begin
      if ((errors[i].len() >= 22) &&
          (errors[i].substr(0, 21) == "adapter identity alias"))
        alias_error_found = 1'b1;
    end
    require(alias_error_found,
            "adapter identity alias diagnostic was not reported");
  endtask

  // 依次驱动三个拓扑用例、映射/负向/别名检查，最后核对环境矩阵。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    exercise_case("one_rc", one_rc_policy, 1, 0);

    exercise_case("four_rc", four_rc_policy, 4, 0);

    exercise_case("one_rc_four_ep", one_rc_four_ep_policy, 1, 4);

    exercise_shuffled_and_sparse_mappings();

    exercise_error_paths();

    exercise_adapter_identity_alias();

    // 环境矩阵在 run_phase 之前就已构建；这里验证真实 pcie_tl_env 的
    // 数组，而不只是 provider 侧计数器。
    check_environment_matrix();

    phase.drop_objection(this);
  endtask
endclass
