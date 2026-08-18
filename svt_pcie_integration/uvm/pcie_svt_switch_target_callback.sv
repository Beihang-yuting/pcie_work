class pcie_svt_switch_target_callback extends svt_pcie_target_app_callback;
  `uvm_object_utils(pcie_svt_switch_target_callback)

  pcie_svt_switch_port_adapter adapter;

  function new(string name = "pcie_svt_switch_target_callback");
    super.new(name);
  endfunction

  protected function bit is_supported_request(svt_pcie_tlp transaction);
    if (transaction == null)
      return 1'b0;
    case (transaction.tlp_type)
      svt_pcie_tlp::MEM_REQ:
        return transaction.fmt inside {
          svt_pcie_tlp::NO_DATA_3_DWORD,
          svt_pcie_tlp::NO_DATA_4_DWORD,
          svt_pcie_tlp::WITH_DATA_3_DWORD,
          svt_pcie_tlp::WITH_DATA_4_DWORD};
      svt_pcie_tlp::DMEM_REQ:
        return transaction.fmt inside {
          svt_pcie_tlp::WITH_DATA_3_DWORD,
          svt_pcie_tlp::WITH_DATA_4_DWORD};
      svt_pcie_tlp::TYPE_0_CFG_REQ,
      svt_pcie_tlp::TYPE_1_CFG_REQ:
        return transaction.fmt inside {
          svt_pcie_tlp::NO_DATA_3_DWORD,
          svt_pcie_tlp::WITH_DATA_3_DWORD};
      default: return 1'b0;
    endcase
  endfunction

  virtual function void post_rx_tlp_get(
      svt_pcie_target_app target_app,
      svt_pcie_tlp transaction,
      ref bit drop);
    if (adapter == null) begin
      drop = 1'b1;
      `uvm_fatal("TARGET_CALLBACK_ADAPTER_NULL",
                 "Proxy Target callback adapter is null")
      return;
    end
    if (transaction == null) begin
      drop = 1'b1;
      `uvm_fatal("TARGET_CALLBACK_NULL",
                 "Proxy Target callback received a null TLP")
      return;
    end
    if (transaction.tlp_type == svt_pcie_tlp::CPL) begin
      drop = 1'b1;
      `uvm_fatal("TARGET_CALLBACK_COMPLETION",
                 "Proxy Target callback rejects Completion TLPs")
      return;
    end
    if (!is_supported_request(transaction)) begin
      drop = 1'b1;
      `uvm_fatal("TARGET_CALLBACK_UNSUPPORTED",
                 "Proxy Target callback rejects unsupported TLPs")
      return;
    end
    adapter.capture_request(transaction);
    drop = 1'b1;
  endfunction

  virtual function void pre_tx_tlp_put(
      svt_pcie_target_app target_app,
      svt_pcie_tlp transaction,
      ref bit drop);
    drop = 1'b1;
    if (adapter == null) begin
      `uvm_fatal("TARGET_CALLBACK_ADAPTER_NULL",
                 "Proxy Target callback adapter is null")
      return;
    end
    adapter.note_unexpected_target_tx(transaction);
  endfunction
endclass
