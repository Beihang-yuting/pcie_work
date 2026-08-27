import uvm_pkg::*;
`include "uvm_macros.svh"

class pcie_svt_topology_bar_expected_fatal_catcher extends
    uvm_report_catcher;
  string expected_id;
  int unsigned catch_count;

  function new(string name = "expected_fatal_catcher");
    super.new(name);
  endfunction

  function void arm(string report_id);
    expected_id = report_id;
  endfunction

  virtual function action_e catch();
    if ((get_severity() == UVM_FATAL) && (get_id() == expected_id)) begin
      catch_count++;
      set_severity(UVM_INFO);
      set_action(UVM_DISPLAY);
      return THROW;
    end
    return THROW;
  endfunction
endclass

module pcie_svt_topology_ep_bar_sizing_callback_unit_test;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import svt_pcie_uvm_pkg::*;
  import pcie_svt_topology_pkg::*;

  function automatic void require(bit condition, string message);
    if (!condition)
      `uvm_fatal("TOPO_BAR_CB_TEST", message)
  endfunction

  function automatic svt_pcie_tlp make_cfg(
      string name, int unsigned bar_number, bit is_write,
      bit [31:0] raw_payload, bit [9:0] tag);
    svt_pcie_tlp request = new(name);
    request.tlp_type = svt_pcie_tlp::TYPE_0_CFG_REQ;
    request.fmt = is_write ? svt_pcie_tlp::WITH_DATA_3_DWORD :
                             svt_pcie_tlp::NO_DATA_3_DWORD;
    request.length = 1;
    request.requester_id = 16'h0000;
    request.tag = tag;
    request.function_number = 0;
    request.register_number = 10'h004 + bar_number;
    request.first_dw_be = 4'hf;
    request.last_dw_be = 4'h0;
    request.payload = new[is_write ? 1 : 0];
    if (is_write)
      request.payload[0] = raw_payload;
    return request;
  endfunction

  function automatic svt_pcie_tlp make_completion(
      string name, svt_pcie_tlp request, bit [31:0] raw_payload);
    svt_pcie_tlp completion = new(name);
    completion.tlp_type = svt_pcie_tlp::CPL;
    completion.fmt = svt_pcie_tlp::WITH_DATA_3_DWORD;
    completion.length = 1;
    completion.requester_id = request.requester_id;
    completion.tag = request.tag;
    completion.completion_status = svt_pcie_tlp::SUCCESSFUL;
    completion.payload = new[1];
    completion.payload[0] = raw_payload;
    return completion;
  endfunction

  function automatic pcie_svt_port_descriptor make_descriptor();
    pcie_svt_port_descriptor descriptor =
      pcie_svt_port_descriptor::type_id::create("descriptor");
    descriptor.link_id = "PEER_LINK_0";
    descriptor.role = PCIE_SVT_ROLE_EP;
    descriptor.endpoint_model = PCIE_SVT_EP_SINGLE;
    foreach (descriptor.ep_bars[i]) begin
      descriptor.ep_bars[i].implemented = 1'b0;
      descriptor.ep_bars[i].initial_base = 0;
    end
    foreach (descriptor.ep_bars[i]) begin
      if (i inside {0, 2, 4}) begin
        descriptor.ep_bars[i].implemented = 1'b1;
        descriptor.ep_bars[i].is_64bit = 1'b1;
        descriptor.ep_bars[i].prefetchable = 1'b1;
        descriptor.ep_bars[i].aperture =
          (i == 0) ? 64'd33554432 : 64'd65536;
      end
    end
    return descriptor;
  endfunction

  initial begin
    const bit [31:0] expected_raw_mask[6] = '{
      32'h0c00_00fe, 32'hffff_ffff,
      32'h0c00_ffff, 32'hffff_ffff,
      32'h0c00_ffff, 32'hffff_ffff};
    pcie_svt_topology_ep_bar_sizing_callback callback;
    pcie_svt_topology_bar_expected_fatal_catcher catcher;
    pcie_svt_port_descriptor descriptor;
    svt_pcie_tlp sizing_read[6];
    svt_pcie_tlp transaction;
    bit drop = 1'b0;

    callback = pcie_svt_topology_ep_bar_sizing_callback::type_id::create(
      "callback");
    catcher = new("catcher");
    uvm_report_cb::add(null, catcher);
    descriptor = make_descriptor();
    callback.configure(descriptor);

    transaction = make_cfg("ordinary_read", 0, 0, 0, 10'h010);
    callback.post_rx_tlp_get(null, transaction, drop);
    transaction = make_completion(
      "ordinary_completion", transaction, 32'h0c00_0010);
    callback.pre_tx_tlp_put(null, transaction, drop);
    require(!drop && transaction.payload[0] == 32'h0c00_0010,
            "ordinary BAR read was modified or dropped");

    transaction = make_cfg("non_bar_cfg", 0, 1, 32'h4433_2211, 10'h011);
    transaction.register_number = 10'h001;
    callback.post_rx_tlp_get(null, transaction, drop);
    require(!drop && transaction.payload[0] == 32'h4433_2211,
            "non-BAR Configuration write was modified or dropped");

    transaction = make_cfg("other_function", 0, 1, 32'h8877_6655, 10'h012);
    transaction.function_number = 1;
    callback.post_rx_tlp_get(null, transaction, drop);
    require(!drop && transaction.payload[0] == 32'h8877_6655,
            "another Function's Configuration write was modified or dropped");

    for (int unsigned bar = 0; bar < 6; bar++) begin
      transaction = make_cfg(
        $sformatf("size_write_%0d", bar), bar, 1,
        32'hffff_ffff, 10'h020 + bar);
      callback.post_rx_tlp_get(null, transaction, drop);
      sizing_read[bar] = make_cfg(
        $sformatf("size_read_%0d", bar), bar, 0, 0, 10'h100 + bar);
      callback.post_rx_tlp_get(null, sizing_read[bar], drop);
    end
    for (int bar = 5; bar >= 0; bar--) begin
      transaction = make_completion(
        $sformatf("size_cpl_%0d", bar), sizing_read[bar], 0);
      callback.pre_tx_tlp_put(null, transaction, drop);
      require(transaction.payload[0] === expected_raw_mask[bar],
        $sformatf("BAR%0d sizing payload expected=%08h actual=%08h",
          bar, expected_raw_mask[bar], transaction.payload[0]));
    end

    transaction = make_cfg("assigned", 0, 1, 32'h0000_0010, 10'h180);
    callback.post_rx_tlp_get(null, transaction, drop);
    require(transaction.payload[0] == 32'h0c00_0010,
            "assigned BAR write lost 64-bit Prefetchable attributes");
    transaction = make_cfg("assigned_upper", 1, 1,
                           32'h1000_0000, 10'h181);
    callback.post_rx_tlp_get(null, transaction, drop);
    require(transaction.payload[0] == 32'h1000_0000,
            "upper BAR DWORD received low-DWORD attributes");

    transaction = new("memory_request");
    transaction.tlp_type = svt_pcie_tlp::MEM_REQ;
    transaction.fmt = svt_pcie_tlp::NO_DATA_4_DWORD;
    callback.post_rx_tlp_get(null, transaction, drop);
    require(!drop && transaction.tlp_type == svt_pcie_tlp::MEM_REQ,
            "Memory request was modified or dropped");

    require(callback.is_idle(), "callback retained probe state");
    require(callback.sizing_write_count == 6 &&
            callback.sizing_read_count == 6 &&
            callback.sizing_completion_count == 6,
            "callback counters are unbalanced");

    callback.configure(make_descriptor());
    transaction = make_cfg("invalid_cfg_write_bar0", 0, 1,
                           32'hffff_ffff, 10'h190);
    callback.post_rx_tlp_get(null, transaction, drop);
    sizing_read[0] = make_cfg("invalid_cfg_read_bar0", 0, 0, 0, 10'h191);
    callback.post_rx_tlp_get(null, sizing_read[0], drop);
    transaction = make_cfg("invalid_cfg_write_bar2", 2, 1,
                           32'hffff_ffff, 10'h192);
    callback.post_rx_tlp_get(null, transaction, drop);
    require(!callback.is_idle(),
            "invalid-configure test did not create transient probe state");
    descriptor.endpoint_model = PCIE_SVT_EP_MULTI_BDF;
    catcher.arm("TOPO_BAR_CB_CFG");
    callback.configure(descriptor);
    require(catcher.catch_count == 1 && callback.is_idle() &&
            callback.sizing_write_count == 0 &&
            callback.sizing_read_count == 0 &&
            callback.sizing_completion_count == 0,
            "rejected descriptor did not immediately abort probe state");

    callback.configure(make_descriptor());
    transaction = make_cfg("dup_write_bar0", 0, 1,
                           32'hffff_ffff, 10'h1a0);
    callback.post_rx_tlp_get(null, transaction, drop);
    sizing_read[0] = make_cfg("dup_read_bar0", 0, 0, 0, 10'h1a1);
    callback.post_rx_tlp_get(null, sizing_read[0], drop);
    transaction = make_cfg("dup_write_bar2", 2, 1,
                           32'hffff_ffff, 10'h1a2);
    callback.post_rx_tlp_get(null, transaction, drop);
    transaction = make_cfg("dup_read_bar2", 2, 0, 0, 10'h1a1);
    catcher.arm("TOPO_BAR_CB_DUP");
    callback.post_rx_tlp_get(null, transaction, drop);
    require(catcher.catch_count == 2 && callback.is_idle() &&
            callback.sizing_write_count == 0 &&
            callback.sizing_read_count == 0 &&
            callback.sizing_completion_count == 0,
            "duplicate requester/tag did not immediately abort probe state");

    callback.configure(make_descriptor());
    transaction = make_cfg("bad_size_write", 0, 1, 32'hffff_ffff, 10'h1a0);
    callback.post_rx_tlp_get(null, transaction, drop);
    sizing_read[0] = make_cfg("bad_size_read", 0, 0, 0, 10'h1a1);
    callback.post_rx_tlp_get(null, sizing_read[0], drop);
    transaction = make_completion("bad_size_cpl", sizing_read[0], 0);
    transaction.completion_status = svt_pcie_tlp::UNSUPPORTED_REQ;
    catcher.arm("TOPO_BAR_CB_CPL");
    callback.pre_tx_tlp_put(null, transaction, drop);
    require(catcher.catch_count == 3 && callback.is_idle() &&
            callback.sizing_write_count == 0 &&
            callback.sizing_read_count == 0 &&
            callback.sizing_completion_count == 0,
            "malformed Completion did not immediately abort probe state");
    uvm_report_cb::delete(null, catcher);
    $display("TOPOLOGY_EP_BAR_SIZING_CALLBACK_PASS bars=6 ordinary=5 memory=1");
    $finish;
  end
endmodule
