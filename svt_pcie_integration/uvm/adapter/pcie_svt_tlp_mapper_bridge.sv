// TL 与 SVT TLP Mapper 之间的公共 TLM 边界。
// 仅使用 R-2020.12 文档公开的 blocking_put export/port，不触碰 Mapper 私有成员。

class pcie_svt_tlp_mapper_bridge extends uvm_component;
  `uvm_component_utils(pcie_svt_tlp_mapper_bridge)

  svt_pcie_tlp_mapper mapper;

  // 一个 bridge 实例绑定一个 application_id；上层可为多个应用创建多个实例。
  int unsigned application_id;

  uvm_blocking_put_imp #(svt_pcie_tlp, pcie_svt_tlp_mapper_bridge) rx_imp;

  svt_pcie_tlp rx_queue[$];

  function new(string name = "pcie_svt_tlp_mapper_bridge", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void bind_mapper(svt_pcie_tlp_mapper endpoint);
    mapper = endpoint;
    if (mapper == null)
      `uvm_fatal("SVT_BRIDGE", "Mapper endpoint 句柄为空，无法建立桥接")
  endfunction

  function void bind_application(int unsigned application_id);
    this.application_id = application_id;
    if (mapper == null)
      `uvm_fatal("SVT_BRIDGE", "bind_application 前未绑定 Mapper")

    if (!mapper.rx_tlp_out_port.exists(application_id)) begin
      `uvm_error("SVT_BRIDGE", $sformatf("未知 application_id=%0d", application_id))
      return;
    end

    rx_imp = new($sformatf("rx_imp_%0d", application_id), this);
    mapper.rx_tlp_out_port[application_id].connect(rx_imp);
  endfunction

  task put_tx(int unsigned application_id, svt_pcie_tlp tlp);
    if (tlp == null) begin
      `uvm_error("SVT_BRIDGE", "禁止向 Mapper 发送空 TLP")
      return;
    end
    if (mapper == null) begin
      `uvm_fatal("SVT_BRIDGE", "发送前未绑定 svt_pcie_tlp_mapper")
      return;
    end
    // tx_tlp_in_export 是 SVT 公共的 blocking_put_imp；按 app id 选择端点。
    if (!mapper.tx_tlp_in_export.exists(application_id)) begin
      `uvm_error("SVT_BRIDGE", $sformatf("未知 application_id=%0d", application_id))
      return;
    end
    mapper.tx_tlp_in_export[application_id].put(tlp);
  endtask

  // uvm_blocking_put_imp 的回调；按实现句柄所在 application_id 分流。
  virtual task put(svt_pcie_tlp tlp);
    if (rx_imp == null) begin
      `uvm_error("SVT_BRIDGE", "收到 TLP 但没有绑定 application_id")
      return;
    end
    rx_queue.push_back(tlp);
  endtask

  task push_rx(int unsigned application_id, svt_pcie_tlp tlp);
    if (tlp == null) begin
      `uvm_error("SVT_BRIDGE", "Mapper 接收到了空 TLP")
      return;
    end
    if (application_id != this.application_id) begin
      `uvm_error("SVT_BRIDGE", $sformatf("application_id mismatch: pushed=%0d bound=%0d", application_id, this.application_id))
      return;
    end
    rx_queue.push_back(tlp);
  endtask

  task get_rx(int unsigned requested_application_id, output svt_pcie_tlp tlp);
    tlp = null;
    if (requested_application_id != application_id) begin
      `uvm_error("SVT_BRIDGE", $sformatf("application_id mismatch: requested=%0d bound=%0d", requested_application_id, application_id))
      return;
    end
    wait (rx_queue.size() != 0);
    tlp = rx_queue.pop_front();
  endtask
endclass
