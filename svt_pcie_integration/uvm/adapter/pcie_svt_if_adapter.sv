// PCIe TL-VIP 到 SVT TLP Mapper 的事务适配器。
// 适配器继承 TL 侧接口，确保既有序列无需感知 SVT 具体实现。

// 将一个 SVT TLP 通过完整 PCIe agent 的 TL sequencer 送入 SVT。
//
// 这个 sequence 是一个非常薄的 transport shim：它不生成任何新事务，
// 只把已经由 pcie_tl_env 编码好的 TLP 交给 SVT TL driver。这样 TL env
// 仍然是唯一的事务控制面，SVT 只负责真实链路上的 DL/PL/PHY 传输。
class pcie_svt_tlp_push_sequence extends uvm_sequence #(svt_pcie_tlp);
  `uvm_object_utils(pcie_svt_tlp_push_sequence)

  svt_pcie_tlp item;

  function new(string name = "pcie_svt_tlp_push_sequence");
    super.new(name);
  endfunction

  virtual task body();
    if (item == null) begin
      `uvm_fatal("SVT_ADAPTER", "FULL_VIP push sequence 收到空 TLP")
      return;
    end

    start_item(item);
    finish_item(item);
  endtask
endclass

//------------------------------------------------------------------------------
// FULL_VIP 接收旁路回调。
//
// svt_pcie_tl::rx_tlp_peek_port 只适用于 TL 已经是协议栈顶层的场景。完整
// PCIe agent 下面还连接着 DL/PL/Serial 时，不能用这个接口取包，否则会
// 绕过 agent 内部的 application 路由。另一方面，rx_tlp_out_port 的数据
// 会被 Target/Requester App 消费，直接再连一个实现也会受 UVM 端口连接
// 规则影响。该 callback 类型作为 SVT 版本兼容备用；FULL_VIP 的实际接收
// 数据源采用 TL monitor 的 rx_tlp_observed_port。
//------------------------------------------------------------------------------
class pcie_svt_tl_rx_callback extends svt_pcie_tl_callback;
  mailbox #(svt_pcie_tlp) rx_mailbox;

  // Endpoint FULL_VIP 同时需要 Target App 观察下行请求和 TL callback
  // 观察上行 Completion。置位后只把 Completion 放入 mailbox，避免同一
  // 个下行请求被两个公开回调重复入队。
  bit completion_only;

  function new(string name = "pcie_svt_tl_rx_callback");
    super.new(name);
  endfunction

  virtual function void pre_tlp_out_put(
    svt_pcie_tl tl,
    svt_pcie_tlp tlp,
    ref bit drop
  );
    svt_pcie_tlp captured_tlp;

    if ((tlp == null) || (rx_mailbox == null))
      return;

    if (completion_only &&
        !(tlp.get_tlp_type_value() inside {
          svt_pcie_tlp::CPL, svt_pcie_tlp::CPL_LK}))
      return;

    // callback 参数由 SVT 内部继续使用；复制一份交给 TL env，避免
    // adapter 解码或队列延迟期间与 SVT application 共享可变对象。
    $cast(captured_tlp, tlp.clone());
    if (captured_tlp == null)
      captured_tlp = tlp;

    // 回调不能阻塞 SVT TL 的接收线程。mailbox 足够大时 try_put 永远
    // 不会因 adapter 暂时未调用 receive() 而卡住链路。
    void'(rx_mailbox.try_put(captured_tlp));
    `uvm_info("SVT_ADAPTER_TL_RX", $sformatf(
      "TL callback 捕获 TLP: %s", captured_tlp.convert2string()), UVM_NONE)
  endfunction
endclass

//------------------------------------------------------------------------------
// FULL_VIP Target App 接收旁路。
//
// active 的 FULL_VIP 不一定创建 TL monitor（pcie_agent.tl_mon 可能为 null），
// 但 Target App 仍然会在收到下行请求后调用官方 post_rx_tlp_get() callback。
// FULL_VIP 桥接的 Completion 统一由 pcie_tl_env driver 产生，因此这里必须
// 显式 drop SVT Target App 的默认响应；capture_transaction 再决定是否把该
// 请求复制到 adapter mailbox。这样可以分别覆盖“monitor 观察”和“callback
// fallback”两种接收路径，而不会重复入队。
//------------------------------------------------------------------------------
class pcie_svt_target_rx_callback extends svt_pcie_target_app_callback;
  mailbox #(svt_pcie_tlp) rx_mailbox;

  // When the adapter is the RC side of a FULL_VIP bridge, the target app is
  // only an observation point.  Setting drop prevents SVT's built-in target
  // memory model from generating a competing Completion; the decoded request
  // is then handled by pcie_tl_env/pcie_tl_rc_driver (and its host_mem).
  bit drop_transaction;

  // Root 开启 TL monitor 时，monitor 会统一观察所有 TLP；Target App callback
  // 仍需注册来抑制内建响应，但不能再次把请求放入 mailbox。Root fallback
  // 和 Endpoint 没有 monitor 时则保留复制功能。
  bit capture_transaction = 1'b1;

  function new(string name = "pcie_svt_target_rx_callback");
    super.new(name);
  endfunction

  virtual function void post_rx_tlp_get(
    svt_pcie_target_app target_app,
    svt_pcie_tlp transaction,
    ref bit drop
  );
    svt_pcie_tlp captured_tlp;

    // drop 必须独立于 capture 开关执行。即使 monitor 已经负责观察，
    // 也不能让 SVT target_appl0 再生成一份 Completion。
    if (drop_transaction)
      drop = 1'b1;

    if (!capture_transaction || (transaction == null) || (rx_mailbox == null))
      return;

    $cast(captured_tlp, transaction.clone());
    if (captured_tlp == null)
      captured_tlp = transaction;

    // callback 在 SVT 接收线程内执行，不能等待 pcie_tl_env 的 task。
    void'(rx_mailbox.try_put(captured_tlp));
    `uvm_info("SVT_ADAPTER_TARGET_RX", $sformatf(
      "Target App callback 捕获 TLP: %s", captured_tlp.convert2string()),
      UVM_NONE)

  endfunction
endclass

//------------------------------------------------------------------------------
// FULL_VIP Mapper 接收旁路（仅 Application/Mapper 模式使用）。
//
// 完整 agent 的 svt_pcie_tl callback 在部分配置下不会被激活，而 Mapper
// callback 是 SVT 官方为“下行 TLP 已接收、即将交给应用”定义的稳定边界。
// 这里不修改 Mapper 的默认路由，只复制一份 TLP 到 adapter mailbox，因而
// Target/Requester App 仍可按 SVT 原有流程工作。
//------------------------------------------------------------------------------
class pcie_svt_mapper_rx_callback extends svt_pcie_tlp_mapper_callback;
  mailbox #(svt_pcie_tlp) rx_mailbox;

  function new(string name = "pcie_svt_mapper_rx_callback");
    super.new(name);
  endfunction

  virtual function void pre_rx_tlp_put(
    svt_pcie_tlp_mapper tlp_mapper,
    svt_pcie_tlp tlp
  );
    svt_pcie_tlp captured_tlp;

    if ((tlp == null) || (rx_mailbox == null))
      return;

    $cast(captured_tlp, tlp.clone());
    if (captured_tlp == null)
      captured_tlp = tlp;

    // Mapper callback 在 SVT 接收线程中执行，必须使用非阻塞入队。
    void'(rx_mailbox.try_put(captured_tlp));
    `uvm_info("SVT_ADAPTER_MAPPER_RX", $sformatf(
      "Mapper callback 捕获 TLP: %s", captured_tlp.convert2string()), UVM_NONE)
  endfunction
endclass

class pcie_svt_if_adapter extends pcie_tl_if_adapter;
  `uvm_component_utils(pcie_svt_if_adapter)

  pcie_svt_route_info route;

  // 父类已占用名称 codec（pcie_tl_codec 类型），因此这里使用明确的
  // codec_adapter 句柄，避免同名遮蔽。转换函数本身是 Task 1 定义的静态 API。
  pcie_svt_tlp_codec codec_adapter;

  svt_pcie_tlp_mapper mapper;

  // 正式 SVT Device Agent。Mapper 必须由该 agent 创建，适配器只保存
  // 公共句柄，避免再次创建一个没有 service sequencer 的孤立 Mapper。
  svt_pcie_device_agent svt_agent;

  // 完整 SVT agent 模式下，事务直接进入内部 PCIe agent 的 TL sequencer。
  svt_pcie_agent full_vip_agent;
  svt_pcie_tlp_sequencer full_vip_tlp_seqr;
  // FULL_VIP 的 TLP 对象必须带有与该 TL driver 相同的配置对象。
  // SVT 在 pack/get_transaction_id 时会通过该句柄读取 tag、header 等
  // 约束；仅填写 TLP 字段而不调用 setup_cfg 会在首个 TLP 处触发 fatal。
  svt_pcie_tl_configuration full_vip_tl_cfg;
  mailbox #(svt_pcie_tlp) full_vip_rx_mailbox;
  pcie_svt_tl_rx_callback full_vip_rx_callback;
  pcie_svt_tl_rx_callback full_vip_cpl_callback;
  pcie_svt_target_rx_callback full_vip_target_rx_callback;
  pcie_svt_mapper_rx_callback full_vip_mapper_rx_callback;

  // FULL_VIP 的 active TL callback 在不同 SVT 配置下并不一定会经过
  // rx_tlp_out_port。官方 TL monitor 的 rx_tlp_observed_port 是完整链路
  // 解码后的统一观察点，因此使用 analysis imp 接收请求和 Completion。
  uvm_analysis_imp #(svt_pcie_tlp, pcie_svt_if_adapter)
    full_vip_rx_analysis_imp;

  // 默认自动判断；生产集成可以通过 config_db 明确指定 FULL_VIP 或
  // MAPPER_APP，避免因 SVT 版本/配置变化而误选后端。
  pcie_svt_backend_mode_e backend_mode = PCIE_SVT_BACKEND_MAPPER_APP;
  string backend_mode_name;

  // 在 adapter 创建时，正式 SVT agent 可能尚未完成 build。集成层可提供
  // 一个稳定的 UVM 全路径，adapter 在 connect_phase 再解析并绑定其正式
  // tlp_mapper，避免在测试中创建孤立 mapper。
  string svt_agent_path;

  // FULL_VIP active agent 不一定创建 tl_mon，因此需要知道当前 adapter
  // 对应 Root 还是 Endpoint，选择官方 TL callback 或 Target App callback。
  // 测试可通过 config_db 显式设置；未设置时在 connect_phase 尝试从
  // svt_pcie_device_agent::get_cfg() 推导。
  bit svt_device_is_root;
  bit svt_device_role_configured;

  pcie_svt_tlp_mapper_bridge mapper_endpoint;

  function new(string name = "pcie_svt_if_adapter", uvm_component parent = null);
    super.new(name, parent);
    route = pcie_svt_route_info_default();
  endfunction

  // 由集成测试在创建 TL env 之前绑定正式 SVT agent。该方法既可直接调用，
  // 也可通过 config_db 的 `svt_agent` 键在 build_phase 自动完成绑定。
  function void bind_agent(svt_pcie_device_agent agent);
    if (agent == null)
      `uvm_fatal("SVT_ADAPTER", "bind_agent 收到空的 SVT device agent")
    svt_agent = agent;
    mapper = agent.tlp_mapper;

    // 未显式指定时，根据 Device Agent 是否创建 Mapper 自动选择后端。
    if (backend_mode_name == "") begin
      backend_mode = (mapper == null) ?
        PCIE_SVT_BACKEND_FULL_VIP : PCIE_SVT_BACKEND_MAPPER_APP;
    end
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // Serial/PIPE 物理接口由顶层通过 config_db 提供。生产集成可使用
    // `vif` 键注入真实适配后的 TL 接口；未提供时保留 compile-only 路径。
    void'(uvm_config_db#(virtual pcie_tl_if)::get(this, "", "vif", vif));

    void'(uvm_config_db#(string)::get(this, "", "svt_agent_path",
                                      svt_agent_path));
    void'(uvm_config_db#(string)::get(this, "", "svt_backend_mode",
                                      backend_mode_name));
    svt_device_role_configured = uvm_config_db#(bit)::get(
      this, "", "svt_device_is_root", svt_device_is_root);
    void'(uvm_config_db#(svt_pcie_tl_configuration)::get(
      this, "", "svt_tl_cfg", full_vip_tl_cfg));

    if (backend_mode_name == "FULL_VIP")
      backend_mode = PCIE_SVT_BACKEND_FULL_VIP;
    else if (backend_mode_name == "MAPPER_APP")
      backend_mode = PCIE_SVT_BACKEND_MAPPER_APP;
    else if ((backend_mode_name != "") && (backend_mode_name != "AUTO"))
      `uvm_fatal("SVT_ADAPTER", $sformatf(
        "不支持的 svt_backend_mode='%s'，可选 AUTO/FULL_VIP/MAPPER_APP",
        backend_mode_name))

    // mailbox 不是 UVM component，可以在 build 阶段创建；它只用于把
    // SVT callback 的函数上下文安全地交给 receive() task。
    full_vip_rx_mailbox = new();
    full_vip_rx_analysis_imp = new("full_vip_rx_analysis_imp", this);

    // 工厂覆盖生成 adapter 时，无法从构造函数传入 SVT agent；使用稳定
    // 的 config_db 句柄完成绑定。直接提供 mapper 仍作为兼容/单元测试入口。
    if (svt_agent == null)
      void'(uvm_config_db#(svt_pcie_device_agent)::get(
        this, "", "svt_agent", svt_agent));
    if ((svt_agent != null) && (mapper == null))
      bind_agent(svt_agent);

    if (mapper == null)
      void'(uvm_config_db#(svt_pcie_tlp_mapper)::get(
        this, "", "pcie_svt_mapper", mapper));

    codec_adapter = new();
    if (codec_adapter == null)
      `uvm_fatal("SVT_ADAPTER", "SVT codec 实例化失败")

    // 在 build 阶段创建层次组件，避免 connect 阶段动态改变 UVM 树。
    // Mapper 尚未注入时仍创建一个 queue-only endpoint，便于 compile/elaboration
    // 门禁；真实 DUT 运行可通过 +PCIE_SVT_REQUIRE_MAPPER 强制检查句柄。
    if (mapper_endpoint == null) begin
      mapper_endpoint = pcie_svt_tlp_mapper_bridge::type_id::create(
        "mapper_bridge", this);
      if (mapper != null)
        mapper_endpoint.bind_mapper(mapper);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    // SVT agent 在同一 UVM test 的 build 阶段创建后，此时已经可以通过
    // 全路径找到。路径方式也兼容官方 pcie_device_unified_vip_env，且不
    // 改变 TL-only 路径。
    if ((svt_agent == null) && (svt_agent_path != "")) begin
      uvm_component found;
      found = uvm_root::get().find(svt_agent_path);
      if ((found != null) && !$cast(svt_agent, found))
        `uvm_fatal("SVT_ADAPTER", $sformatf(
          "svt_agent_path='%s' 不是 svt_pcie_device_agent", svt_agent_path))
      if (svt_agent != null)
        bind_agent(svt_agent);
    end

    if ((mapper == null) && (svt_agent != null))
      bind_agent(svt_agent);

    // config_db 是最稳定的角色来源；对于未显式提供角色的用户环境，
    // 尝试读取正式 Device Agent 的配置副本。get_cfg() 失败时保留默认
    // Endpoint 角色，并在下面只使用 Endpoint Target callback，避免把
    // 一个事务同时捕获两次。
    if (!svt_device_role_configured && (svt_agent != null)) begin
      svt_configuration generic_cfg;
      svt_pcie_device_configuration device_cfg;
      generic_cfg = null;
      svt_agent.get_cfg(generic_cfg);
      if ($cast(device_cfg, generic_cfg)) begin
        svt_device_is_root = device_cfg.device_is_root;
        svt_device_role_configured = 1'b1;
      end
    end

    // 完整 SVT agent 后端：这是唯一会经过 Serial/PIPE HDL interconnect
    // 的 transport 路径。pcie_agent.tlp_seqr 是 SVT TL 层公开的输入；
    // 入站 TLP 通过官方 TL callback 捕获，保持内部 application 路由不变。
    if (backend_mode == PCIE_SVT_BACKEND_FULL_VIP) begin
      if ((svt_agent == null) || (svt_agent.pcie_agent == null))
        `uvm_fatal("SVT_ADAPTER", "FULL_VIP 后端没有可用的 svt_pcie_agent")

      full_vip_agent   = svt_agent.pcie_agent;
      full_vip_tlp_seqr = full_vip_agent.tlp_seqr;
      if (full_vip_tlp_seqr == null)
        `uvm_fatal("SVT_ADAPTER", "FULL_VIP svt_pcie_agent.tlp_seqr 为空")
      if (full_vip_tl_cfg == null)
        `uvm_fatal("SVT_ADAPTER", {
          "FULL_VIP 缺少 svt_pcie_tl_configuration；请通过 config_db ",
          "设置 svt_tl_cfg，且必须使用对应 SVT agent 的 pcie_cfg.tl_cfg"})
      if (full_vip_agent.tl == null)
        `uvm_fatal("SVT_ADAPTER",
          "FULL_VIP svt_pcie_agent.tl 为空，无法接收 Serial TLP")

      if (full_vip_rx_mailbox == null)
        `uvm_fatal("SVT_ADAPTER", "FULL_VIP RX mailbox 未创建")

      // Root active agent 在有 monitor 时优先使用公开 analysis port；若
      // monitor 未创建，则退回 Target App + svt_pcie_tl callback。两种
      // 路径都必须抑制 Target App 默认响应；无 monitor 时 callback 只捕获
      // Completion，EP→RC 请求仍由 Target App callback 唯一入队。
      if (svt_device_is_root && (full_vip_agent.tl_mon != null)) begin
        if (svt_agent.target[0] == null)
          `uvm_fatal("FULL_VIP", "Root target[0] 为空，无法抑制内建 Target App")

        // Monitor 已经是 Root 的唯一观察源；Target App callback 只设置
        // drop，不复制事务，避免同一 EP→RC 请求进入 mailbox 两次。
        full_vip_target_rx_callback = new("full_vip_target_rx_callback");
        full_vip_target_rx_callback.rx_mailbox = full_vip_rx_mailbox;
        full_vip_target_rx_callback.drop_transaction = 1'b1;
        full_vip_target_rx_callback.capture_transaction = 1'b0;
        uvm_callbacks#(svt_pcie_target_app,
                       svt_pcie_target_app_callback)::add(
          svt_agent.target[0], full_vip_target_rx_callback);

        full_vip_agent.tl_mon.rx_tlp_observed_port.connect(
          full_vip_rx_analysis_imp);
        `uvm_info("SVT_ADAPTER",
          "FULL_VIP Root RX 使用 svt_pcie_tl_monitor", UVM_LOW)
      end
      else if (svt_device_is_root) begin
        // RC 侧的 Target App 默认也带有一个内部 memory model。FULL_VIP
        // bridge 的 RC 请求响应应统一由 pcie_tl_env 的 host_mem 产生，
        // 因此在 Target App 接收边界复制请求并置 drop，避免 SVT 内部
        // target_appl0 同时返回一份未初始化数据的 Completion。
        if (svt_agent.target[0] == null)
          `uvm_fatal("FULL_VIP", "Root target[0] 为空，无法旁路上行请求")
        full_vip_target_rx_callback = new("full_vip_target_rx_callback");
        full_vip_target_rx_callback.rx_mailbox = full_vip_rx_mailbox;
        full_vip_target_rx_callback.drop_transaction = 1'b1;
        uvm_callbacks#(svt_pcie_target_app,
                       svt_pcie_target_app_callback)::add(
          svt_agent.target[0], full_vip_target_rx_callback);

        full_vip_rx_callback = new("full_vip_rx_callback");
        full_vip_rx_callback.rx_mailbox = full_vip_rx_mailbox;
        // Target App callback 已经唯一捕获 EP→RC 请求；TL callback 只取
        // 返回到 Root requester 的 Completion，避免 request 重复入队。
        full_vip_rx_callback.completion_only = 1'b1;
        uvm_callbacks#(svt_pcie_tl, svt_pcie_tl_callback)::add(
          full_vip_agent.tl, full_vip_rx_callback);
        `uvm_info("SVT_ADAPTER",
          "FULL_VIP Root RX 使用 svt_pcie_tl::pre_tlp_out_put callback",
          UVM_LOW)
      end
      else begin
        // Endpoint active agent 通常没有 tl_mon，但 Target App 必然是
        // 完整 agent 的公开组件；post_rx_tlp_get 是官方定义的下行请求
        // 边界，不会把 Target App 生成的 Completion 再捕获成请求。
        if (svt_agent.target[0] == null)
          `uvm_fatal("SVT_ADAPTER",
            "FULL_VIP Endpoint target[0] 为空，无法注册 Target App callback")
        full_vip_target_rx_callback = new("full_vip_target_rx_callback");
        full_vip_target_rx_callback.rx_mailbox = full_vip_rx_mailbox;
        // Endpoint 的业务响应统一由 pcie_tl_env EP driver 处理，禁止
        // FULL_VIP 内建 Target App 与它并行产生 Completion。
        full_vip_target_rx_callback.drop_transaction = 1'b1;
        full_vip_target_rx_callback.capture_transaction = 1'b1;
        uvm_callbacks#(svt_pcie_target_app,
                       svt_pcie_target_app_callback)::add(
          svt_agent.target[0], full_vip_target_rx_callback);

        // Target App callback 不覆盖 EP requester 收到的 Completion。补充
        // 一个只观察 Completion 的 TL callback，仍共享同一个 mailbox，
        // 这样 pcie_tl_env 的 EP driver 可以完成反向读事务的 read-back。
        full_vip_cpl_callback = new("full_vip_cpl_callback");
        full_vip_cpl_callback.rx_mailbox = full_vip_rx_mailbox;
        full_vip_cpl_callback.completion_only = 1'b1;
        uvm_callbacks#(svt_pcie_tl, svt_pcie_tl_callback)::add(
          full_vip_agent.tl, full_vip_cpl_callback);
        `uvm_info("SVT_ADAPTER",
          "FULL_VIP Endpoint RX 使用 Target App::post_rx_tlp_get + TL Completion callback",
          UVM_LOW)
      end
      return;
    end

    // mapper_endpoint 在 build 阶段已经创建；agent 句柄晚到时需要在这里
    // 补绑定，再建立 application-id 端口连接。
    if ((mapper != null) && (mapper_endpoint != null))
      mapper_endpoint.bind_mapper(mapper);
    if (mapper_endpoint == null)
      `uvm_fatal("SVT_ADAPTER", "build 阶段未配置 Mapper endpoint")

    // mock endpoint 可能没有真实 Mapper；仍需同步 application_id，确保
    // push_rx/get_rx 使用同一路由键并能覆盖错误 ID 诊断。
    if (mapper == null) begin
      mapper_endpoint.application_id = route.application_id;
      if ($test$plusargs("PCIE_SVT_REQUIRE_MAPPER"))
        `uvm_fatal("SVT_ADAPTER",
          "未绑定正式 svt_pcie_device_agent.tlp_mapper；请在真实 SVT 集成中通过 config_db 注入")
      else
        `uvm_warning("SVT_ADAPTER",
          "当前为 compile/elaboration-only 适配器路径，未绑定正式 SVT Mapper")
    end

    // 外部 mock endpoint 可能没有真实 Mapper；真实 Mapper 才需要建立 RX 连接。
    if (mapper != null) begin
      // 用户 application 端口由 bridge 按官方公开关联数组接口注册；
      // 内建端口已存在时复用，缺失时创建唯一的 100+ 端口。
      mapper_endpoint.bind_application(route.application_id);
    end
  endfunction

  // 官方 TL monitor 通过 analysis port 调用此方法。回调上下文中只能做
  // 非阻塞复制，真正的 receive() 任务再从 mailbox 中等待，避免拖住 SVT
  // monitor 或链路接收线程。
  virtual function void write(svt_pcie_tlp tlp);
    svt_pcie_tlp captured_tlp;

    if ((tlp == null) || (full_vip_rx_mailbox == null))
      return;

    $cast(captured_tlp, tlp.clone());
    if (captured_tlp == null)
      captured_tlp = tlp;

    void'(full_vip_rx_mailbox.try_put(captured_tlp));
    `uvm_info("SVT_ADAPTER_MON_RX", $sformatf(
      "FULL_VIP TL monitor 捕获 TLP: %s", captured_tlp.convert2string()),
      UVM_NONE)
  endfunction

  virtual task send(pcie_tl_tlp tlp);
    svt_pcie_tlp svt_tlp;
    if (tlp == null) begin
      `uvm_error("SVT_ADAPTER", "send 收到空 TL TLP")
      return;
    end
    if (mapper_endpoint == null) begin
      `uvm_fatal("SVT_ADAPTER", "send 时 Mapper endpoint 为空")
      return;
    end
    if (!pcie_svt_tlp_codec::encode(tlp, svt_tlp, route)) begin
      `uvm_error("SVT_ADAPTER", "TL 到 SVT 编码失败")
      return;
    end

    if (backend_mode == PCIE_SVT_BACKEND_FULL_VIP) begin
      pcie_svt_tlp_push_sequence push_seq;

      // 这里走的是 PCIe TL 的公共输入，而不是 SVT Driver App 的
      // requester/application bookkeeping。若把 application_id 设为
      // DRIVER(1)，SVT RC driver 会把外部 TL 请求产生的 Completion
      // 当成“未由它发起”的 spurious completion。使用官方 TL 应用号
      // (9) 可保留完整 Serial/DL/PL 路径，同时把收发交给本项目的
      // pcie_tl_env/adapter 侧管理。
      svt_tlp.application_id = `SVT_PCIE_DEFAULT_APPLICATION_NUMBER_TL;
      // setup_cfg 是 SVT TLP 的官方配置绑定入口，必须在 sequence item
      // 交给 tlp_seqr 前调用；不能直接访问其 protected cfg 字段。
      svt_tlp.setup_cfg(full_vip_tl_cfg);
      `uvm_info("SVT_ADAPTER_TX", $sformatf(
        "FULL_VIP TX 送入 %s: %s", full_vip_tlp_seqr.get_full_name(),
        svt_tlp.convert2string()), UVM_NONE)
      push_seq = pcie_svt_tlp_push_sequence::type_id::create(
        "full_vip_push_seq");
      push_seq.item = svt_tlp;
      push_seq.start(full_vip_tlp_seqr);
      return;
    end

    mapper_endpoint.put_tx(route.application_id, svt_tlp);
  endtask

  virtual task receive(output pcie_tl_tlp tlp);
    svt_pcie_tlp svt_tlp;
    tlp = null;
    if (mapper_endpoint == null) begin
      `uvm_fatal("SVT_ADAPTER", "receive 时 Mapper endpoint 为空")
      return;
    end

    if (backend_mode == PCIE_SVT_BACKEND_FULL_VIP) begin
      if (full_vip_rx_mailbox == null)
        `uvm_fatal("SVT_ADAPTER", "FULL_VIP RX mailbox 为空")
      // monitor analysis imp 只负责快速复制并入队；真正的阻塞等待在
      // TL env 的 receive() task 中完成，因此不会阻塞 SVT 链路线程。
      full_vip_rx_mailbox.get(svt_tlp);
      `uvm_info("SVT_ADAPTER_RX", $sformatf(
        "FULL_VIP RX 从 mailbox 取出: %s", svt_tlp.convert2string()), UVM_NONE)
      if (!pcie_svt_tlp_codec::decode(svt_tlp, tlp, route)) begin
        `uvm_error("SVT_ADAPTER", "FULL_VIP SVT 到 TL 解码失败")
        tlp = null;
      end
      return;
    end

    // 没有正式 Mapper 时，表示仅进行编译/elaboration 门禁。即使顶层提供
    // 了占位 vif，也不应从 queue-only bridge 阻塞等待 RX 数据。
    if (mapper == null) begin
      #1ns;
      return;
    end
    mapper_endpoint.get_rx(route.application_id, svt_tlp);
    if (!pcie_svt_tlp_codec::decode(svt_tlp, tlp, route)) begin
      `uvm_error("SVT_ADAPTER", "SVT 到 TL 解码或路由校验失败")
      tlp = null;
    end
  endtask

endclass
