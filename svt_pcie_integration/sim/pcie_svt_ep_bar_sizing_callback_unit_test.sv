module pcie_svt_ep_bar_sizing_callback_unit_test;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import svt_pcie_uvm_pkg::*;
  import pcie_svt_integration_pkg::*;

  function automatic void require(bit condition, string message);
    if (!condition)
      `uvm_fatal("EP_BAR_SIZING_TEST", message)
  endfunction

  function automatic svt_pcie_tlp make_cfg_request(
      string name,
      int unsigned bar_number,
      bit is_write,
      bit [31:0] raw_payload,
      bit [9:0] tag);
    svt_pcie_tlp request;
    request = new(name);
    request.tlp_type = svt_pcie_tlp::TYPE_0_CFG_REQ;
    request.fmt = is_write ? svt_pcie_tlp::WITH_DATA_3_DWORD :
                             svt_pcie_tlp::NO_DATA_3_DWORD;
    request.length = 10'd1;
    request.requester_id = 16'h0000;
    request.tag = tag;
    request.bus_number = 8'h03;
    request.device_number = 5'h00;
    request.function_number = 3'h0;
    request.register_number = 10'h004 + bar_number;
    request.first_dw_be = 4'hf;
    request.last_dw_be = 4'h0;
    if (is_write) begin
      request.payload = new[1];
      request.payload[0] = raw_payload;
    end else begin
      request.payload = new[0];
    end
    return request;
  endfunction

  function automatic svt_pcie_tlp make_completion(
      string name,
      svt_pcie_tlp request,
      bit [31:0] raw_payload);
    svt_pcie_tlp completion;
    completion = new(name);
    completion.tlp_type = svt_pcie_tlp::CPL;
    completion.fmt = svt_pcie_tlp::WITH_DATA_3_DWORD;
    completion.length = 10'd1;
    completion.requester_id = request.requester_id;
    completion.completer_id = 16'h0300;
    completion.tag = request.tag;
    completion.completion_status = svt_pcie_tlp::SUCCESSFUL;
    completion.byte_count = 12'd4;
    completion.lower_address = 7'h00;
    completion.payload = new[1];
    completion.payload[0] = raw_payload;
    return completion;
  endfunction

  initial begin
    const bit [31:0] expected_raw_mask[6] = '{
      32'h0c00_00fe, 32'hffff_ffff,
      32'h0c00_ffff, 32'hffff_ffff,
      32'h0c00_ffff, 32'hffff_ffff};
    pcie_svt_profile_set profile_set;
    pcie_svt_port_profile endpoint_profile;
    pcie_svt_ep_bar_sizing_callback callback;
    svt_pcie_tlp sizing_read[6];
    svt_pcie_tlp transaction;
    bit drop;

    profile_set = pcie_svt_profile_set::type_id::create("profile_set");
    endpoint_profile = profile_set.make_ep(
      "unit_ep", 4, 0, 4, 16'h20f9, 16'h5011);
    callback = pcie_svt_ep_bar_sizing_callback::type_id::create(
      "bar_sizing_callback");
    require((endpoint_profile != null) &&
            (endpoint_profile.functions.size() == 1) &&
            (endpoint_profile.functions[0] != null) &&
            (callback != null),
            "profile or callback creation failed");
    callback.configure(endpoint_profile.functions[0], "unit_ep");

    transaction = make_cfg_request(
      "ordinary_read", 0, 1'b0, '0, 10'h010);
    drop = 1'b0;
    callback.post_rx_tlp_get(null, transaction, drop);
    require(!drop, "ordinary BAR read was dropped");
    transaction = make_completion(
      "ordinary_completion", transaction, 32'h0c00_0010);
    callback.pre_tx_tlp_put(null, transaction, drop);
    require(!drop && (transaction.payload[0] == 32'h0c00_0010),
            "ordinary BAR read Completion was modified");

    for (int unsigned bar_number = 0; bar_number < 6; bar_number++) begin
      transaction = make_cfg_request(
        $sformatf("sizing_write_bar%0d", bar_number),
        bar_number, 1'b1, 32'hffff_ffff, 10'h020 + bar_number);
      drop = 1'b0;
      callback.post_rx_tlp_get(null, transaction, drop);
      require(!drop, $sformatf("BAR%0d sizing write was dropped", bar_number));
      sizing_read[bar_number] = make_cfg_request(
        $sformatf("sizing_read_bar%0d", bar_number),
        bar_number, 1'b0, '0, 10'h100 + bar_number);
      callback.post_rx_tlp_get(null, sizing_read[bar_number], drop);
      require(!drop, $sformatf("BAR%0d sizing read was dropped", bar_number));
    end

    // Complete in reverse order to prove requester/tag correlation rather
    // than relying on Target App callback ordering.
    for (int bar_number = 5; bar_number >= 0; bar_number--) begin
      transaction = make_completion(
        $sformatf("sizing_completion_bar%0d", bar_number),
        sizing_read[bar_number], 32'hffff_ffff);
      drop = 1'b0;
      callback.pre_tx_tlp_put(null, transaction, drop);
      require(!drop, $sformatf(
        "BAR%0d sizing Completion was dropped", bar_number));
      require(transaction.payload[0] === expected_raw_mask[bar_number],
        $sformatf("BAR%0d raw sizing mask expected=%08h got=%08h",
          bar_number, expected_raw_mask[bar_number],
          transaction.payload[0]));
    end

    // A final assigned write cancels a new sizing probe. The subsequent
    // readback must remain the Target App's assigned BAR value.
    transaction = make_cfg_request(
      "cancelled_probe", 0, 1'b1, 32'hffff_ffff, 10'h180);
    callback.post_rx_tlp_get(null, transaction, drop);
    transaction = make_cfg_request(
      "assigned_write", 0, 1'b1, 32'h0000_0010, 10'h181);
    callback.post_rx_tlp_get(null, transaction, drop);
    require(transaction.payload[0] == 32'h0c00_0010,
            "assigned BAR write did not retain fixed attributes");
    transaction = make_cfg_request(
      "assigned_read", 0, 1'b0, '0, 10'h182);
    callback.post_rx_tlp_get(null, transaction, drop);
    transaction = make_completion(
      "assigned_completion", transaction, 32'h0c00_0010);
    callback.pre_tx_tlp_put(null, transaction, drop);
    require(transaction.payload[0] == 32'h0c00_0010,
            "assigned BAR read Completion was modified");

    require(callback.is_idle(), "BAR sizing callback retained pending state");
    require((callback.sizing_write_count == 7) &&
            (callback.sizing_read_count == 6) &&
            (callback.sizing_completion_count == 6),
            $sformatf(
              "callback counts writes=%0d reads=%0d completions=%0d",
              callback.sizing_write_count, callback.sizing_read_count,
              callback.sizing_completion_count));
    $display({"EP_BAR_SIZING_CALLBACK_PASS bars=6 sizing_writes=7 ",
      "sizing_reads=6 rewrites=6 ordinary=2"});
    $finish;
  end
endmodule
