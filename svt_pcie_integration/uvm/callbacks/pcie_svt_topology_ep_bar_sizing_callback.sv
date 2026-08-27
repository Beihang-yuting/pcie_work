class pcie_svt_topology_ep_bar_sizing_callback extends
    svt_pcie_target_app_callback;
  `uvm_object_utils(pcie_svt_topology_ep_bar_sizing_callback)

  typedef bit [25:0] request_key_t;
  protected bit valid[6];
  protected bit is_lower[6];
  protected bit [3:0] fixed_attributes[6];
  protected bit armed[6];
  protected bit [31:0] raw_mask[6];
  protected int unsigned pending_bar[request_key_t];
  protected string link_id;
  int unsigned sizing_write_count;
  int unsigned sizing_read_count;
  int unsigned sizing_completion_count;

  function new(string name =
      "pcie_svt_topology_ep_bar_sizing_callback");
    super.new(name);
  endfunction

  protected function automatic bit [31:0] byte_swap(bit [31:0] value);
    return {value[7:0], value[15:8], value[23:16], value[31:24]};
  endfunction

  protected function automatic request_key_t key(svt_pcie_tlp tlp);
    return {tlp.requester_id, tlp.tag};
  endfunction

  function void configure(pcie_svt_port_descriptor descriptor);
    pcie_svt_cfg_space_builder builder;

    if ((descriptor == null) ||
        (descriptor.role != PCIE_SVT_ROLE_EP) ||
        (descriptor.endpoint_model != PCIE_SVT_EP_SINGLE)) begin
      `uvm_fatal("TOPO_BAR_CB_CFG",
        "callback requires a non-null Single-Endpoint descriptor")
      return;
    end
    builder = pcie_svt_cfg_space_builder::type_id::create(
      {get_name(), "_builder"});
    if ((builder == null) || !builder.validate_ep_descriptor(descriptor))
      return;
    link_id = descriptor.link_id;
    sizing_write_count = 0;
    sizing_read_count = 0;
    sizing_completion_count = 0;
    pending_bar.delete();
    foreach (valid[i]) begin
      valid[i] = 0;
      is_lower[i] = 0;
      fixed_attributes[i] = 0;
      armed[i] = 0;
      raw_mask[i] = 0;
    end
    foreach (descriptor.ep_bars[i]) begin
      if (!descriptor.ep_bars[i].implemented)
        continue;
      valid[i] = 1;
      is_lower[i] = 1;
      fixed_attributes[i] =
        {descriptor.ep_bars[i].prefetchable,
         descriptor.ep_bars[i].is_64bit, 1'b0, 1'b0};
      raw_mask[i] = byte_swap(
        builder.bar_sizing_value(descriptor.ep_bars[i], 0));
      if (descriptor.ep_bars[i].is_64bit) begin
        valid[i+1] = 1;
        raw_mask[i+1] = byte_swap(
          builder.bar_sizing_value(descriptor.ep_bars[i], 1));
      end
    end
  endfunction

  protected function bit decode_bar(
      svt_pcie_tlp tlp, output int unsigned bar);
    bar = 0;
    if ((tlp == null) ||
        (tlp.tlp_type != svt_pcie_tlp::TYPE_0_CFG_REQ) ||
        (tlp.function_number != 0) || (tlp.length != 1) ||
        (tlp.first_dw_be != 4'hf) || (tlp.last_dw_be != 4'h0) ||
        (tlp.register_number < 10'h004) ||
        (tlp.register_number > 10'h009))
      return 0;
    bar = tlp.register_number - 10'h004;
    return valid[bar];
  endfunction

  virtual function void post_rx_tlp_get(
      svt_pcie_target_app target_app, svt_pcie_tlp transaction,
      ref bit drop);
    int unsigned bar;
    request_key_t request_key;
    bit [31:0] host_payload;

    if (!decode_bar(transaction, bar))
      return;
    if (transaction.fmt == svt_pcie_tlp::WITH_DATA_3_DWORD) begin
      if ((transaction.payload.size() == 1) &&
          (transaction.payload[0] == 32'hffff_ffff)) begin
        armed[bar] = 1;
        sizing_write_count++;
      end else begin
        armed[bar] = 0;
        if ((transaction.payload.size() == 1) && is_lower[bar]) begin
          host_payload = byte_swap(transaction.payload[0]);
          host_payload[3:0] = fixed_attributes[bar];
          transaction.payload[0] = byte_swap(host_payload);
        end
      end
      return;
    end
    if ((transaction.fmt != svt_pcie_tlp::NO_DATA_3_DWORD) || !armed[bar])
      return;
    request_key = key(transaction);
    if (pending_bar.exists(request_key)) begin
      armed[bar] = 0;
      `uvm_fatal("TOPO_BAR_CB_DUP", $sformatf(
        "%s duplicate requester=%04h tag=%03h",
        link_id, transaction.requester_id, transaction.tag))
      return;
    end
    armed[bar] = 0;
    pending_bar[request_key] = bar;
    sizing_read_count++;
  endfunction

  virtual function void pre_tx_tlp_put(
      svt_pcie_target_app target_app, svt_pcie_tlp transaction,
      ref bit drop);
    request_key_t request_key;
    int unsigned bar;

    if ((transaction == null) ||
        (transaction.tlp_type != svt_pcie_tlp::CPL))
      return;
    request_key = key(transaction);
    if (!pending_bar.exists(request_key))
      return;
    bar = pending_bar[request_key];
    pending_bar.delete(request_key);
    if ((transaction.fmt != svt_pcie_tlp::WITH_DATA_3_DWORD) ||
        (transaction.completion_status != svt_pcie_tlp::SUCCESSFUL) ||
        (transaction.length != 1) || (transaction.payload.size() != 1)) begin
      `uvm_fatal("TOPO_BAR_CB_CPL", $sformatf(
        "%s malformed sizing Completion requester=%04h tag=%03h",
        link_id, transaction.requester_id, transaction.tag))
      return;
    end
    transaction.payload[0] = raw_mask[bar];
    sizing_completion_count++;
  endfunction

  function bit is_idle();
    foreach (armed[i])
      if (armed[i])
        return 0;
    return pending_bar.num() == 0;
  endfunction
endclass
