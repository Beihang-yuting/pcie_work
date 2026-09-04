//------------------------------------------------------------------------------
// 官方 SVT RC/EP peer traffic 验证。
//
// pcie_device_base_test 已由官方示例提供配置和默认 virtual sequence：先并行
// 使能 RC/EP 链路，等待双方进入 L0，然后从 RC driver 发起 Memory Write 和
// 对同一地址的 Memory Read。这里仅注册一个独立测试名，不修改生产环境。
//------------------------------------------------------------------------------

`ifndef PCIE_SVT_PEER_TRAFFIC_TEST_SV
  `define PCIE_SVT_PEER_TRAFFIC_TEST_SV

  class pcie_svt_peer_traffic_test extends pcie_device_base_test;

    `uvm_component_utils(pcie_svt_peer_traffic_test)

    function new(string name = "pcie_svt_peer_traffic_test",
                 uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // 官方 base test 的默认 sequence 已覆盖 link-up 与 Memory W/R；
    // 保留空实现，避免在 agent 创建完成后修改速率配置。Gen4/Gen5
    // 需要在正式 test 重写配置创建时机后再启用。

  endclass

`endif
