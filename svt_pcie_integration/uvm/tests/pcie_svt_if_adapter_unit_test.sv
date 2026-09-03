// 适配器最小单元测试：使用 bridge 的接收队列模拟 Mapper 的 RX put，
// 并检查一次发送与一次接收均经过编解码和 application_id 路由。
// SVT 交易类型只在 VCS + R-2020.12 环境提供，因此本测试在无 SVT 时安全跳过。

`ifdef PCIE_SVT_AVAILABLE
package pcie_svt_if_adapter_unit_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import pcie_tl_pkg::*;
  import pcie_svt_topology_pkg::*;

  class pcie_svt_if_adapter_unit_test extends uvm_test;
    `uvm_component_utils(pcie_svt_if_adapter_unit_test)

    pcie_svt_if_adapter adapter;

    function new(string name = "pcie_svt_if_adapter_unit_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      adapter = pcie_svt_if_adapter::type_id::create("adapter", this);
      adapter.route.application_id = 7;
      adapter.route.requester_id = 16'h1234;
      adapter.mapper_endpoint = new("mock_mapper_bridge", adapter);
    endfunction

    task run_phase(uvm_phase phase);
      pcie_tl_mem_tlp tx;
      pcie_tl_tlp rx;
      svt_pcie_tlp wire;

      phase.raise_objection(this);

      tx = new("tx");
      tx.kind = TLP_MEM_WR;
      tx.type_f = TLP_TYPE_MEM_WR;
      tx.fmt = FMT_3DW_WITH_DATA;
      tx.requester_id = 16'h1234;
      tx.addr = 64'h1000;
      tx.length = 1;
      tx.first_be = 4'hf;
      tx.payload = new[4];
      tx.payload = '{8'hde, 8'had, 8'hbe, 8'hef};

      if (!pcie_svt_tlp_codec::encode(tx, wire, adapter.route))
        `uvm_fatal("SVT_ADAPTER_TEST", "mock outbound 编码失败")

      adapter.mapper_endpoint.push_rx(adapter.route.application_id, wire);
      adapter.receive(rx);
      if ((rx == null) || (rx.requester_id != tx.requester_id) ||
          (rx.payload.size() != tx.payload.size()))
        `uvm_fatal("SVT_ADAPTER_TEST", "mock inbound 路由或字段不匹配")

      phase.drop_objection(this);
    endtask
  endclass
endpackage
`endif

