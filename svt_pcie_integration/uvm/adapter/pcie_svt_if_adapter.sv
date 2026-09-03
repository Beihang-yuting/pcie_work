// PCIe TL-VIP 到 SVT TLP Mapper 的事务适配器。
// 适配器继承 TL 侧接口，确保既有序列无需感知 SVT 具体实现。

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
    if (agent.tlp_mapper == null)
      `uvm_fatal("SVT_ADAPTER",
        {"SVT device agent '", agent.get_full_name(),
         "' 尚未创建正式 tlp_mapper"})
    svt_agent = agent;
    mapper = agent.tlp_mapper;
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // Serial/PIPE 物理接口由顶层通过 config_db 提供。生产集成可使用
    // `vif` 键注入真实适配后的 TL 接口；未提供时保留 compile-only 路径。
    void'(uvm_config_db#(virtual pcie_tl_if)::get(this, "", "vif", vif));

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
      if (!mapper.tx_tlp_in_export.exists(route.application_id) ||
          !mapper.rx_tlp_out_port.exists(route.application_id))
        `uvm_fatal("SVT_ADAPTER", $sformatf(
          "application_id=%0d 未在 Mapper TX/RX 端口注册",
          route.application_id))
      mapper_endpoint.bind_application(route.application_id);
    end
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
    mapper_endpoint.put_tx(route.application_id, svt_tlp);
  endtask

  virtual task receive(output pcie_tl_tlp tlp);
    svt_pcie_tlp svt_tlp;
    tlp = null;
    if (mapper_endpoint == null) begin
      `uvm_fatal("SVT_ADAPTER", "receive 时 Mapper endpoint 为空")
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
