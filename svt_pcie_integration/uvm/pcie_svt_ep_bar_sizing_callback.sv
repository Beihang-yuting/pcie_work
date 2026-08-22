class pcie_svt_ep_bar_sizing_callback extends svt_pcie_target_app_callback;
  `uvm_object_utils(pcie_svt_ep_bar_sizing_callback)

  typedef bit [25:0] request_key_t;

  protected bit          bar_dword_valid[6];
  protected bit          bar_dword_is_lower[6];
  protected bit [3:0]    bar_fixed_attributes[6];
  protected bit          sizing_probe_armed[6];
  protected bit [31:0]   raw_sizing_mask[6];
  protected int unsigned pending_bar_by_key[request_key_t];
  protected string       port_label;

  int unsigned sizing_write_count;
  int unsigned sizing_read_count;
  int unsigned sizing_completion_count;

  function new(string name = "pcie_svt_ep_bar_sizing_callback");
    super.new(name);
  endfunction

  protected function automatic bit [31:0] to_pcie_byte_order(
      bit [31:0] value);
    return {value[7:0], value[15:8], value[23:16], value[31:24]};
  endfunction

  protected function automatic request_key_t request_key(
      svt_pcie_tlp transaction);
    return {transaction.requester_id, transaction.tag};
  endfunction

  function void configure(pcie_svt_function_profile function_profile,
                          string endpoint_label);
    bit [63:0] aperture_mask;
    bit [31:0] attributes;

    if (function_profile == null)
      `uvm_fatal("EP_BAR_SIZING_CFG",
        {endpoint_label, ": null PF0 profile"})

    port_label = endpoint_label;
    sizing_write_count = 0;
    sizing_read_count = 0;
    sizing_completion_count = 0;
    pending_bar_by_key.delete();
    foreach (bar_dword_valid[i]) begin
      bar_dword_valid[i] = 1'b0;
      bar_dword_is_lower[i] = 1'b0;
      bar_fixed_attributes[i] = '0;
      sizing_probe_armed[i] = 1'b0;
      raw_sizing_mask[i] = '0;
    end

    foreach (function_profile.bars[i]) begin
      if ((function_profile.bars[i] == null) ||
          !function_profile.bars[i].implemented)
        continue;
      if ((function_profile.bars[i].aperture < 16) ||
          ((function_profile.bars[i].aperture &
            (function_profile.bars[i].aperture - 1)) != 0))
        `uvm_fatal("EP_BAR_SIZING_CFG", $sformatf(
          "%s BAR%0d aperture 0x%0h is invalid", port_label, i,
          function_profile.bars[i].aperture))

      aperture_mask = ~(function_profile.bars[i].aperture - 1);
      attributes = function_profile.bars[i].prefetchable ? 32'h8 : 32'h0;
      if (function_profile.bars[i].is_64bit)
        attributes |= 32'h4;
      bar_dword_valid[i] = 1'b1;
      bar_dword_is_lower[i] = 1'b1;
      bar_fixed_attributes[i] = attributes[3:0];
      raw_sizing_mask[i] = to_pcie_byte_order(
        (aperture_mask[31:0] & 32'hffff_fff0) | attributes);

      if (function_profile.bars[i].is_64bit) begin
        if ((i == 5) || (function_profile.bars[i+1] == null) ||
            function_profile.bars[i+1].implemented)
          `uvm_fatal("EP_BAR_SIZING_CFG", $sformatf(
            "%s BAR%0d has no unimplemented upper DWORD", port_label, i))
        bar_dword_valid[i+1] = 1'b1;
        raw_sizing_mask[i+1] = to_pcie_byte_order(aperture_mask[63:32]);
      end
    end
  endfunction

  protected function bit get_bar_number(
      svt_pcie_tlp transaction,
      output int unsigned bar_number);
    bar_number = 0;
    if ((transaction == null) ||
        (transaction.tlp_type != svt_pcie_tlp::TYPE_0_CFG_REQ) ||
        (transaction.function_number != 0) ||
        (transaction.length != 1) ||
        (transaction.first_dw_be != 4'hf) ||
        (transaction.last_dw_be != 4'h0) ||
        (transaction.register_number < 10'h004) ||
        (transaction.register_number > 10'h009))
      return 1'b0;
    bar_number = transaction.register_number - 10'h004;
    return bar_dword_valid[bar_number];
  endfunction

  virtual function void post_rx_tlp_get(
      svt_pcie_target_app target_app,
      svt_pcie_tlp transaction,
      ref bit drop);
    int unsigned bar_number;
    request_key_t key;

    if (!get_bar_number(transaction, bar_number))
      return;

    if (transaction.fmt == svt_pcie_tlp::WITH_DATA_3_DWORD) begin
      if ((transaction.payload.size() == 1) &&
          (transaction.payload[0] == 32'hffff_ffff)) begin
        sizing_probe_armed[bar_number] = 1'b1;
        sizing_write_count++;
      end else begin
        bit [31:0] host_order_payload;
        sizing_probe_armed[bar_number] = 1'b0;
        if ((transaction.payload.size() == 1) &&
            bar_dword_is_lower[bar_number]) begin
          host_order_payload = to_pcie_byte_order(transaction.payload[0]);
          host_order_payload[3:0] = bar_fixed_attributes[bar_number];
          transaction.payload[0] = to_pcie_byte_order(host_order_payload);
        end
      end
      return;
    end

    if ((transaction.fmt != svt_pcie_tlp::NO_DATA_3_DWORD) ||
        !sizing_probe_armed[bar_number])
      return;

    key = request_key(transaction);
    if (pending_bar_by_key.exists(key))
      `uvm_fatal("EP_BAR_SIZING_DUP", $sformatf(
        "%s duplicate sizing read requester=%04h tag=%03h",
        port_label, transaction.requester_id, transaction.tag))
    sizing_probe_armed[bar_number] = 1'b0;
    pending_bar_by_key[key] = bar_number;
    sizing_read_count++;
  endfunction

  virtual function void pre_tx_tlp_put(
      svt_pcie_target_app target_app,
      svt_pcie_tlp transaction,
      ref bit drop);
    request_key_t key;
    int unsigned bar_number;

    if ((transaction == null) ||
        (transaction.tlp_type != svt_pcie_tlp::CPL))
      return;
    key = request_key(transaction);
    if (!pending_bar_by_key.exists(key))
      return;

    bar_number = pending_bar_by_key[key];
    pending_bar_by_key.delete(key);
    if ((transaction.fmt != svt_pcie_tlp::WITH_DATA_3_DWORD) ||
        (transaction.completion_status != svt_pcie_tlp::SUCCESSFUL) ||
        (transaction.length != 1) || (transaction.payload.size() != 1))
      return;

    transaction.payload[0] = raw_sizing_mask[bar_number];
    sizing_completion_count++;
  endfunction

  function bit is_idle();
    foreach (sizing_probe_armed[i])
      if (sizing_probe_armed[i])
        return 1'b0;
    return (pending_bar_by_key.num() == 0);
  endfunction
endclass
