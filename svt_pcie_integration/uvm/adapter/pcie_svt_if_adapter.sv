// PCIe TL-VIP 到 SVT TLP Mapper 的事务适配器。
// 适配器继承 TL 侧接口，确保既有序列无需感知 SVT 具体实现。

class pcie_svt_if_adapter extends pcie_tl_if_adapter;
  `uvm_component_utils(pcie_svt_if_adapter)

  pcie_svt_route_info route;

  svt_pcie_tlp_mapper mapper;

  pcie_svt_tlp_mapper_bridge mapper_endpoint;

  function new(string name = "pcie_svt_if_adapter", uvm_component parent = null);
    super.new(name, parent);
    route = pcie_svt_route_info_default();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // 在 build 阶段创建层次组件，避免 connect 阶段动态改变 UVM 树。
    if ((mapper_endpoint == null) && (mapper != null)) begin
      mapper_endpoint = pcie_svt_tlp_mapper_bridge::type_id::create(
        "mapper_bridge", this);
      mapper_endpoint.bind_mapper(mapper);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if ((mapper_endpoint == null) && (mapper == null))
      `uvm_fatal("SVT_ADAPTER", "未配置 Mapper endpoint")
    if (mapper_endpoint == null) begin
      mapper_endpoint = pcie_svt_tlp_mapper_bridge::type_id::create(
        "mapper_bridge", this);
      mapper_endpoint.bind_mapper(mapper);
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
    mapper_endpoint.get_rx(route.application_id, svt_tlp);
    if (!pcie_svt_tlp_codec::decode(svt_tlp, tlp, route)) begin
      `uvm_error("SVT_ADAPTER", "SVT 到 TL 解码或路由校验失败")
      tlp = null;
    end
  endtask
endclass
