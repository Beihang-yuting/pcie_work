package pcie_svt_switch_adapter_unit_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import svt_uvm_pkg::*;
  import svt_pcie_uvm_pkg::*;
  import pcie_tl_switch_pkg::*;
  import pcie_svt_integration_pkg::*;

  bit callback_drop_probe;

  class pcie_svt_null_clone_tlp extends svt_pcie_tlp;
    function new(string name = "pcie_svt_null_clone_tlp");
      super.new(name);
    endfunction

    virtual function uvm_object clone();
      return null;
    endfunction
  endclass

  class pcie_svt_collecting_driver extends uvm_driver #(svt_pcie_tlp);
    `uvm_component_utils(pcie_svt_collecting_driver)

    svt_pcie_tlp received[$];
    svt_pcie_tlp collected[$];

    function new(string name = "pcie_svt_collecting_driver",
                 uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
      svt_pcie_tlp cloned;
      forever begin
        seq_item_port.get_next_item(req);
        received.push_back(req);
        if ((req == null) || !$cast(cloned, req.clone()))
          `uvm_fatal("ADAPTER_TEST_DRIVER_CLONE", "driver clone failed")
        collected.push_back(cloned);
        seq_item_port.item_done();
      end
    endtask
  endclass

  class pcie_svt_switch_adapter_unit_test extends uvm_test;
    `uvm_component_utils(pcie_svt_switch_adapter_unit_test)

    pcie_tl_switch_port                  switch_port;
    svt_pcie_tl_configuration           sequencer_cfg;
    svt_pcie_tlp_sequencer              proxy_tlp_seqr;
    pcie_svt_collecting_driver          collecting_driver;
    pcie_svt_switch_scoreboard          scoreboard;
    pcie_svt_switch_port_adapter        adapter;
    pcie_svt_switch_target_callback     target_callback;
    pcie_svt_switch_sidecar_subscriber  rx_subscriber;
    pcie_svt_switch_sidecar_subscriber  tx_subscriber;
    pcie_svt_switch_sidecar_subscriber  peer_rx_subscriber;
    pcie_svt_switch_sidecar_subscriber  peer_tx_subscriber;

    function new(string name = "pcie_svt_switch_adapter_unit_test",
                 uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function automatic void require(bit condition, string message);
      if (!condition)
        `uvm_fatal("SWITCH_ADAPTER_TEST", message)
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      switch_port = pcie_tl_switch_port::type_id::create(
        "switch_port", this);
      sequencer_cfg = new("sequencer_cfg");
      uvm_config_db#(svt_pcie_tl_configuration)::set(
        this, "proxy_tlp_seqr", "cfg", sequencer_cfg);
      proxy_tlp_seqr = new("proxy_tlp_seqr", this);
      collecting_driver = pcie_svt_collecting_driver::type_id::create(
        "collecting_driver", this);
      scoreboard = pcie_svt_switch_scoreboard::type_id::create(
        "scoreboard", this);
      adapter = pcie_svt_switch_port_adapter::type_id::create(
        "adapter", this);
      rx_subscriber = pcie_svt_switch_sidecar_subscriber::type_id::create(
        "rx_subscriber", this);
      tx_subscriber = pcie_svt_switch_sidecar_subscriber::type_id::create(
        "tx_subscriber", this);
      peer_rx_subscriber =
        pcie_svt_switch_sidecar_subscriber::type_id::create(
          "peer_rx_subscriber", this);
      peer_tx_subscriber =
        pcie_svt_switch_sidecar_subscriber::type_id::create(
          "peer_tx_subscriber", this);
      target_callback = pcie_svt_switch_target_callback::type_id::create(
        "target_callback");

      adapter.port_index = 2;
      adapter.switch_port = switch_port;
      adapter.proxy_tlp_seqr = proxy_tlp_seqr;
      target_callback.adapter = adapter;

      rx_subscriber.port_index = 2;
      rx_subscriber.role = PCIE_SVT_SIDECAR_RX;
      rx_subscriber.adapter = adapter;
      rx_subscriber.scoreboard = scoreboard;
      tx_subscriber.port_index = 2;
      tx_subscriber.role = PCIE_SVT_SIDECAR_TX;
      tx_subscriber.adapter = adapter;
      tx_subscriber.scoreboard = scoreboard;
      peer_rx_subscriber.port_index = 3;
      peer_rx_subscriber.role = PCIE_SVT_SIDECAR_RX;
      peer_rx_subscriber.adapter = adapter;
      peer_rx_subscriber.scoreboard = scoreboard;
      peer_tx_subscriber.port_index = 3;
      peer_tx_subscriber.role = PCIE_SVT_SIDECAR_TX;
      peer_tx_subscriber.adapter = adapter;
      peer_tx_subscriber.scoreboard = scoreboard;
    endfunction

    virtual function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      collecting_driver.seq_item_port.connect(proxy_tlp_seqr.seq_item_export);
    endfunction

    function automatic svt_pcie_tlp make_request(
        string name = "request");
      svt_pcie_tlp tlp;
      tlp = new(name);
      tlp.tlp_type = svt_pcie_tlp::MEM_REQ;
      tlp.fmt = svt_pcie_tlp::WITH_DATA_3_DWORD;
      tlp.address = 64'h0000_0000_1234_5040;
      tlp.length = 10'd2;
      tlp.requester_id = 16'h4100;
      tlp.tag = 10'h2a5;
      tlp.first_dw_be = 4'hf;
      tlp.last_dw_be = 4'hf;
      tlp.payload = new[2];
      tlp.payload[0] = 32'h4433_2211;
      tlp.payload[1] = 32'h8877_6655;
      return tlp;
    endfunction

    function automatic svt_pcie_tlp make_completion(
        string name = "completion");
      svt_pcie_tlp tlp;
      tlp = new(name);
      tlp.tlp_type = svt_pcie_tlp::CPL;
      tlp.fmt = svt_pcie_tlp::WITH_DATA_3_DWORD;
      tlp.length = 10'd2;
      tlp.requester_id = 16'h4100;
      tlp.completer_id = 16'h5200;
      tlp.tag = 10'h2a5;
      tlp.completion_status = svt_pcie_tlp::SUCCESSFUL;
      tlp.byte_count_modified = 1'b0;
      tlp.byte_count = 12'd8;
      tlp.lower_address = 7'h40;
      tlp.payload = new[2];
      tlp.payload[0] = 32'hccbbaa99;
      tlp.payload[1] = 32'h00ffeedd;
      return tlp;
    endfunction

    function automatic svt_pcie_tlp make_cfg_request(
        string name,
        svt_pcie_tlp::tlp_type_enum tlp_type,
        bit with_data);
      svt_pcie_tlp tlp;
      tlp = new(name);
      tlp.tlp_type = tlp_type;
      tlp.fmt = with_data ? svt_pcie_tlp::WITH_DATA_3_DWORD :
                            svt_pcie_tlp::NO_DATA_3_DWORD;
      tlp.length = 10'd1;
      tlp.requester_id = 16'h4100;
      tlp.tag = 10'h2a5;
      tlp.bus_number = 8'h52;
      tlp.device_number = 5'h04;
      tlp.function_number = 3'h1;
      tlp.register_number = 10'h084;
      tlp.first_dw_be = 4'hf;
      tlp.last_dw_be = 4'h0;
      if (with_data) begin
        tlp.payload = new[1];
        tlp.payload[0] = 32'h1234_abcd;
      end else begin
        tlp.payload = new[0];
      end
      return tlp;
    endfunction

    function automatic svt_pcie_tlp make_local_completion(
        string name,
        svt_pcie_tlp request,
        bit with_data);
      svt_pcie_tlp tlp;
      tlp = new(name);
      tlp.tlp_type = svt_pcie_tlp::CPL;
      tlp.fmt = with_data ? svt_pcie_tlp::WITH_DATA_3_DWORD :
                            svt_pcie_tlp::NO_DATA_3_DWORD;
      tlp.length = with_data ? 10'd1 : 10'd0;
      tlp.requester_id = request.requester_id;
      tlp.completer_id = 16'h5200;
      tlp.tag = request.tag;
      tlp.completion_status = svt_pcie_tlp::SUCCESSFUL;
      tlp.byte_count_modified = 1'b0;
      tlp.byte_count = with_data ? 12'd4 : 12'd0;
      tlp.lower_address = 7'h00;
      if (with_data) begin
        tlp.payload = new[1];
        tlp.payload[0] = 32'hfeed_cafe;
      end else begin
        tlp.payload = new[0];
      end
      return tlp;
    endfunction

    function automatic bit [31:0] reference_payload_fnv1a(
        svt_pcie_tlp transaction);
      bit [31:0] digest;
      bit [7:0] payload_byte;
      digest = 32'h811c_9dc5;
      foreach (transaction.payload[dword_index]) begin
        for (int unsigned byte_index = 0; byte_index < 4; byte_index++) begin
          payload_byte = transaction.payload[dword_index]
                         [8 * byte_index +: 8];
          digest = (digest ^ payload_byte) * 32'h0100_0193;
        end
      end
      return digest;
    endfunction

    function automatic bit wire_equal(svt_pcie_tlp lhs,
                                      svt_pcie_tlp rhs);
      if ((lhs == null) || (rhs == null))
        return 1'b0;
      if ((lhs.fmt != rhs.fmt) ||
          (lhs.tlp_type != rhs.tlp_type) ||
          (lhs.traffic_class != rhs.traffic_class) ||
          (lhs.th != rhs.th) || (lhs.td != rhs.td) ||
          (lhs.ep != rhs.ep) ||
          (lhs.attr_relaxed_ordering != rhs.attr_relaxed_ordering) ||
          (lhs.attr_id_order != rhs.attr_id_order) ||
          (lhs.attr_no_snoop != rhs.attr_no_snoop) ||
          (lhs.at != rhs.at) || (lhs.length != rhs.length) ||
          (lhs.requester_id != rhs.requester_id) ||
          (lhs.tag != rhs.tag) || (lhs.address != rhs.address) ||
          (lhs.first_dw_be != rhs.first_dw_be) ||
          (lhs.last_dw_be != rhs.last_dw_be) ||
          (lhs.bus_number != rhs.bus_number) ||
          (lhs.device_number != rhs.device_number) ||
          (lhs.function_number != rhs.function_number) ||
          (lhs.register_number != rhs.register_number) ||
          (lhs.completer_id != rhs.completer_id) ||
          (lhs.completion_status != rhs.completion_status) ||
          (lhs.byte_count_modified != rhs.byte_count_modified) ||
          (lhs.byte_count != rhs.byte_count) ||
          (lhs.lower_address != rhs.lower_address) ||
          (lhs.ln != rhs.ln) || (lhs.ph != rhs.ph) ||
          (lhs.st != rhs.st) ||
          (lhs.num_local_tlp_prefixes != rhs.num_local_tlp_prefixes) ||
          (lhs.num_end_to_end_tlp_prefixes !=
           rhs.num_end_to_end_tlp_prefixes) ||
          (lhs.payload.size() != rhs.payload.size()) ||
          (lhs.tlp_prefixes.size() != rhs.tlp_prefixes.size()))
        return 1'b0;
      foreach (lhs.payload[index])
        if (lhs.payload[index] !== rhs.payload[index])
          return 1'b0;
      foreach (lhs.tlp_prefixes[index])
        if (lhs.tlp_prefixes[index] !== rhs.tlp_prefixes[index])
          return 1'b0;
      return 1'b1;
    endfunction

    task automatic get_normalized(
        output pcie_tl_tlp tlp, input string description);
      fork
        begin
          switch_port.rx_fifo.get(tlp);
        end
        begin
          #2us;
          `uvm_fatal("SWITCH_ADAPTER_TIMEOUT",
                     {"timed out waiting for ", description})
        end
      join_any
      disable fork;
    endtask

    task automatic wait_for_driver_count(int unsigned expected);
      fork
        begin
          wait ((collecting_driver.collected.size() == expected) &&
                (adapter.egress_forward_count == expected));
        end
        begin
          #2us;
          `uvm_fatal("SWITCH_ADAPTER_TIMEOUT",
                     "timed out waiting for collecting driver")
        end
      join_any
      disable fork;
    endtask

    function automatic void verify_raw_item(
        svt_pcie_tlp source_a,
        svt_pcie_tlp source_b,
        svt_pcie_tlp converted_source);
      require(collecting_driver.received.size() == 1,
              "collecting driver raw-item count mismatch");
      require(collecting_driver.collected.size() == 1,
              "collecting driver snapshot count mismatch");
      require(collecting_driver.received[0].is_fmt_type_valid(),
              "submitted raw item is not valid through the public TLP API");
      require((collecting_driver.received[0] != source_a) &&
              ((source_b == null) ||
               (collecting_driver.received[0] != source_b)) &&
              (collecting_driver.received[0] != converted_source),
              "submitted raw item reused an existing SVT object");
    endfunction

    task automatic check_cross_route_identical_tlps();
      svt_pcie_tlp request;
      request = make_request("cross_route_request");
      scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                1, 2, request);
      scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                2, 3, request);
      scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 1, request);
      scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 2, request);
      scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 2, request);
      scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 3, request);
      scoreboard.check_empty();
    endtask

    task automatic run_scoreboard_cross_route_regression();
      check_cross_route_identical_tlps();
      $display("SWITCH_SCOREBOARD_CROSS_ROUTE_PASS");
    endtask

    task automatic run_scoreboard_cfg_rewrite_regression();
      svt_pcie_tlp ingress_cfg1;
      svt_pcie_tlp egress_cfg0;
      ingress_cfg1 = make_cfg_request(
        "cfg1_ingress", svt_pcie_tlp::TYPE_1_CFG_REQ, 1'b0);
      require($cast(egress_cfg0, ingress_cfg1.clone()),
              "Cfg1-to-Cfg0 egress clone failed");
      egress_cfg0.tlp_type = svt_pcie_tlp::TYPE_0_CFG_REQ;
      scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                1, 2, ingress_cfg1, egress_cfg0);
      scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 1, ingress_cfg1);
      scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 2, egress_cfg0);
      scoreboard.check_empty();
      $display("SWITCH_SCOREBOARD_CFG_REWRITE_PASS");
    endtask

    task automatic run_scoreboard_local_cfg_read_regression();
      svt_pcie_tlp request;
      svt_pcie_tlp response;
      request = make_cfg_request(
        "local_cfg_read", svt_pcie_tlp::TYPE_0_CFG_REQ, 1'b0);
      response = make_local_completion(
        "local_cfg_read_completion", request, 1'b1);
      scoreboard.expect_local_response(2, request, response);
      scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 2, request);
      scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 2, response);
      scoreboard.check_empty();
      $display("SWITCH_SCOREBOARD_LOCAL_CFG_READ_PASS");
    endtask

    task automatic run_scoreboard_local_cfg_write_regression();
      svt_pcie_tlp request;
      svt_pcie_tlp response;
      request = make_cfg_request(
        "local_cfg_write", svt_pcie_tlp::TYPE_0_CFG_REQ, 1'b1);
      response = make_local_completion(
        "local_cfg_write_completion", request, 1'b0);
      scoreboard.expect_local_response(2, request, response);
      scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 2, request);
      scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 2, response);
      scoreboard.check_empty();
      $display("SWITCH_SCOREBOARD_LOCAL_CFG_WRITE_PASS");
    endtask

    task automatic run_scoreboard_cpl_nonwire_regression();
      svt_pcie_tlp ingress;
      svt_pcie_tlp egress;
      ingress = make_completion("completion_nonwire_ingress");
      require($cast(egress, ingress.clone()),
              "Completion non-wire sentinel clone failed");
      ingress.address = 64'h1111_2222_3333_4444;
      ingress.first_dw_be = 4'h1;
      ingress.last_dw_be = 4'h2;
      egress.address = 64'haaaa_bbbb_cccc_dddd;
      egress.first_dw_be = 4'h4;
      egress.last_dw_be = 4'h8;
      scoreboard.expect_forward(PCIE_SVT_FORWARD_COMPLETION,
                                3, 2, ingress);
      scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 3, ingress);
      scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 2, egress);
      scoreboard.check_empty();
      $display("SWITCH_SCOREBOARD_CPL_NONWIRE_PASS");
    endtask

    task automatic run_scoreboard_request_nonwire_regression();
      svt_pcie_tlp ingress;
      svt_pcie_tlp egress;
      ingress = make_request("request_nonwire_ingress");
      require($cast(egress, ingress.clone()),
              "Request non-wire sentinel clone failed");
      ingress.completer_id = 16'h1111;
      ingress.completion_status = svt_pcie_tlp::COMPLETER_ABORT;
      ingress.byte_count_modified = 1'b1;
      ingress.byte_count = 12'h111;
      ingress.lower_address = 7'h11;
      egress.completer_id = 16'heeee;
      egress.completion_status = svt_pcie_tlp::UNSUPPORTED_REQ;
      egress.byte_count_modified = 1'b0;
      egress.byte_count = 12'heee;
      egress.lower_address = 7'h6e;
      scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                1, 2, ingress);
      scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 1, ingress);
      scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 2, egress);
      scoreboard.check_empty();
      $display("SWITCH_SCOREBOARD_REQUEST_NONWIRE_PASS");
    endtask

    task automatic run_setup_cfg_regression();
      svt_pcie_tlp request;
      svt_pcie_tlp expected_egress;
      pcie_tl_tlp normalized;
      string reason;

      request = make_request("setup_cfg_request");
      require(pcie_svt_tlp_converter::from_svt(
                request, normalized, reason),
              {"setup regression ingress conversion failed: ", reason});
      require(pcie_svt_tlp_converter::to_svt(
                normalized, expected_egress, reason),
              {"setup regression egress conversion failed: ", reason});
      switch_port.tx_fifo.put(normalized);
      wait_for_driver_count(1);
      verify_raw_item(request, null, expected_egress);
      require(wire_equal(collecting_driver.collected[0], expected_egress),
              "setup regression raw egress fields changed");
      $display("SWITCH_SETUP_CFG_PASS");
    endtask

    task automatic run_positive();
      svt_pcie_tlp request;
      svt_pcie_tlp completion;
      svt_pcie_tlp request_snapshot;
      svt_pcie_tlp completion_snapshot;
      svt_pcie_tlp expected_egress;
      pcie_tl_tlp first_normalized;
      pcie_tl_tlp second_normalized;
      pcie_tl_tlp request_normalized;
      pcie_tl_tlp completion_normalized;
      bit drop;
      string reason;

      request = make_request();
      completion = make_completion();
      require($cast(request_snapshot, request.clone()),
              "request snapshot clone failed");
      require($cast(completion_snapshot, completion.clone()),
              "completion snapshot clone failed");

      scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                2, 3, request);
      scoreboard.expect_forward(PCIE_SVT_FORWARD_COMPLETION,
                                3, 2, completion);

      drop = 1'b0;
      target_callback.post_rx_tlp_get(null, request, drop);
      require(drop == 1'b1, "supported request was not suppressed");
      require(adapter.request_capture_count == 1,
              "supported request was not captured exactly once");

      rx_subscriber.write(request);
      require(adapter.request_capture_count == 1,
              "RX Request re-entered adapter capture");
      peer_tx_subscriber.write(request);
      require(adapter.request_capture_count == 1,
              "TX Request entered adapter capture");
      require(adapter.completion_capture_count == 0,
              "Request changed Completion capture count");

      peer_rx_subscriber.write(completion);
      require(adapter.completion_capture_count == 1,
              "RX Completion was not captured exactly once");
      tx_subscriber.write(completion);
      require(adapter.completion_capture_count == 1,
              "TX Completion entered adapter capture");

      require(wire_equal(request, request_snapshot),
              "request source object was modified");
      require(wire_equal(completion, completion_snapshot),
              "Completion source object was modified");

      get_normalized(first_normalized, "first normalized ingress TLP");
      get_normalized(second_normalized, "second normalized ingress TLP");
      if (first_normalized.kind inside {TLP_CPL, TLP_CPLD}) begin
        completion_normalized = first_normalized;
        request_normalized = second_normalized;
      end else begin
        request_normalized = first_normalized;
        completion_normalized = second_normalized;
      end
      require(request_normalized.kind == TLP_MEM_WR,
              "normalized Request kind mismatch");
      require(completion_normalized.kind == TLP_CPLD,
              "normalized Completion kind mismatch");
      require((request_normalized != completion_normalized) &&
              (request_normalized != null) &&
              (completion_normalized != null),
              "normalized ingress objects are not independent");
      require(adapter.request_ingress_count == 1,
              "Request was not forwarded to switch ingress exactly once");
      require(adapter.completion_ingress_count == 1,
              "Completion was not forwarded to switch ingress exactly once");
      require(switch_port.rx_fifo.used() == 0,
              "switch-port RX FIFO did not drain");

      require(pcie_svt_tlp_converter::to_svt(
                request_normalized, expected_egress, reason),
              {"expected egress conversion failed: ", reason});
      switch_port.tx_fifo.put(request_normalized);
      wait_for_driver_count(1);
      verify_raw_item(request, completion, expected_egress);
      require(wire_equal(collecting_driver.collected[0], expected_egress),
              "raw egress fields changed");
      require(wire_equal(request, request_snapshot),
              "egress conversion modified source Request");
      require(request_normalized.kind == TLP_MEM_WR,
              "egress conversion modified normalized source");

      scoreboard.check_empty();
      require(adapter.request_mbox.num() == 0,
              "request mailbox did not drain");
      require(adapter.completion_mbox.num() == 0,
              "Completion mailbox did not drain");
      require(adapter.egress_forward_count == 1,
              "raw egress sequence count mismatch");
      require(adapter.drop_count == 0, "adapter drop count is nonzero");
      require(adapter.unexpected_target_tx_count == 0,
              "unexpected Proxy Target TX count is nonzero");

      // Identical legal TLPs are distinct expectations, not duplicates.
      scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                3, 4, request);
      scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                3, 4, request);
      scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 3, request);
      scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 3, request);
      scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 4, request);
      scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 4, request);
      scoreboard.check_empty();

      check_cross_route_identical_tlps();

      $display("SWITCH_ADAPTER_PASS");
    endtask

    task automatic run_negative(string mode);
      svt_pcie_tlp request;
      svt_pcie_tlp completion;
      svt_pcie_tlp unsupported;
      svt_pcie_tlp illegal_tuple;
      svt_pcie_tlp illegal_completion;
      svt_pcie_tlp observed;
      svt_pcie_tlp cfg_ingress;
      svt_pcie_tlp cfg_egress;
      pcie_svt_null_clone_tlp bad_clone;
      pcie_svt_raw_tlp_sequence raw_sequence;
      bit drop;

      request = make_request();
      completion = make_completion();
      unsupported = new("unsupported_message");
      unsupported.tlp_type = svt_pcie_tlp::MSG_REQ_TO_ROOT;
      unsupported.fmt = svt_pcie_tlp::NO_DATA_4_DWORD;
      illegal_tuple = new("illegal_tuple");
      illegal_tuple.tlp_type = svt_pcie_tlp::DMEM_REQ;
      illegal_tuple.fmt = svt_pcie_tlp::NO_DATA_3_DWORD;
      illegal_completion = make_completion("illegal_completion");
      illegal_completion.fmt = svt_pcie_tlp::NO_DATA_4_DWORD;
      bad_clone = new("bad_clone");
      bad_clone.tlp_type = svt_pcie_tlp::MEM_REQ;
      bad_clone.fmt = svt_pcie_tlp::NO_DATA_3_DWORD;

      case (mode)
        "callback_completion": begin
          callback_drop_probe = 1'b0;
          target_callback.post_rx_tlp_get(
            null, completion, callback_drop_probe);
        end
        "callback_unsupported": begin
          callback_drop_probe = 1'b0;
          target_callback.post_rx_tlp_get(
            null, unsupported, callback_drop_probe);
        end
        "callback_null": begin
          callback_drop_probe = 1'b0;
          target_callback.post_rx_tlp_get(
            null, null, callback_drop_probe);
        end
        "callback_adapter_null": begin
          callback_drop_probe = 1'b0;
          target_callback.adapter = null;
          target_callback.post_rx_tlp_get(
            null, request, callback_drop_probe);
        end
        "callback_illegal_tuple": begin
          callback_drop_probe = 1'b0;
          target_callback.post_rx_tlp_get(
            null, illegal_tuple, callback_drop_probe);
        end
        "callback_clone": begin
          drop = 1'b0;
          target_callback.post_rx_tlp_get(null, bad_clone, drop);
        end
        "target_tx": begin
          drop = 1'b0;
          target_callback.pre_tx_tlp_put(null, request, drop);
        end
        "subscriber_null": rx_subscriber.write(null);
        "subscriber_clone": rx_subscriber.write(bad_clone);
        "sidecar_rx_message": rx_subscriber.write(unsupported);
        "sidecar_tx_illegal_tuple":
          tx_subscriber.write(illegal_completion);
        "capture_null": adapter.capture_request(null);
        "capture_clone": adapter.capture_request(bad_clone);
        "raw_null": begin
          raw_sequence = pcie_svt_raw_tlp_sequence::type_id::create(
            "raw_null_sequence");
          raw_sequence.start(proxy_tlp_seqr);
        end
        "scoreboard_wrong_egress": begin
          scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                    1, 2, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 1, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 3, request);
        end
        "scoreboard_duplicate": begin
          scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                    1, 2, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 1, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 2, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 2, request);
        end
        "scoreboard_unmatched_completion": begin
          scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 1, completion);
        end
        "scoreboard_payload_mismatch": begin
          scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                    1, 2, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 1, request);
          request.payload[0] = 32'hdead_beef;
          scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 2, request);
        end
        "scoreboard_fnv_collision": begin
          request.payload[0] = 32'h3e9e_72dd;
          request.payload[1] = 32'h3c90_d748;
          require($cast(observed, request.clone()),
                  "FNV collision observed clone failed");
          observed.payload[0] = 32'h884c_33c5;
          observed.payload[1] = 32'hd536_7d80;
          require(reference_payload_fnv1a(request) == 32'hf1c5_0def,
                  "FNV collision expected digest is not literal f1c50def");
          require(reference_payload_fnv1a(observed) == 32'hf1c5_0def,
                  "FNV collision observed digest is not literal f1c50def");
          scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                    1, 2, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 1, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 2, observed);
          $display("FNV_COLLISION_UNDETECTED");
        end
        "scoreboard_tc_mismatch": begin
          require($cast(observed, request.clone()),
                  "TC mismatch observed clone failed");
          observed.traffic_class = request.traffic_class ^ 3'b001;
          scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                    1, 2, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 1, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 2, observed);
        end
        "scoreboard_attr_mismatch": begin
          require($cast(observed, request.clone()),
                  "Attr mismatch observed clone failed");
          observed.attr_no_snoop = !request.attr_no_snoop;
          scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                    1, 2, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 1, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 2, observed);
        end
        "scoreboard_prefix_mismatch": begin
          request.tlp_prefixes.delete();
          request.tlp_prefixes.push_back(32'h0100_1234);
          request.num_local_tlp_prefixes = 1;
          request.num_end_to_end_tlp_prefixes = 0;
          require($cast(observed, request.clone()),
                  "prefix mismatch observed clone failed");
          observed.tlp_prefixes[0] = 32'h0100_5678;
          scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                    1, 2, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 1, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 2, observed);
        end
        "scoreboard_at_mismatch": begin
          request.at = svt_pcie_tlp::UNTRANSLATED;
          require($cast(observed, request.clone()),
                  "AT mismatch observed clone failed");
          observed.at = svt_pcie_tlp::TRANSLATED;
          scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                    1, 2, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 1, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 2, observed);
        end
        "scoreboard_tph_mismatch": begin
          request.th = 1'b1;
          request.ln = 1'b1;
          request.ph = svt_pcie_tlp::REQUESTER;
          request.st = 16'h1234;
          require($cast(observed, request.clone()),
                  "TPH mismatch observed clone failed");
          observed.st = 16'h5678;
          scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                    1, 2, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 1, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 2, observed);
        end
        "scoreboard_loop": begin
          scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                    1, 2, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 1, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 1, request);
        end
        "scoreboard_missing": begin
          scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                    1, 2, request);
          scoreboard.check_empty();
        end
        "scoreboard_self_route_expect": begin
          scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                    1, 1, request);
        end
        "scoreboard_direction_mismatch": begin
          scoreboard.expect_forward(PCIE_SVT_FORWARD_COMPLETION,
                                    1, 2, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 1, request);
          scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 2, request);
          scoreboard.check_empty();
        end
        "scoreboard_cfg_rewrite_loop": begin
          cfg_ingress = make_cfg_request(
            "cfg_loop_ingress", svt_pcie_tlp::TYPE_1_CFG_REQ, 1'b0);
          require($cast(cfg_egress, cfg_ingress.clone()),
                  "Cfg rewrite loop egress clone failed");
          cfg_egress.tlp_type = svt_pcie_tlp::TYPE_0_CFG_REQ;
          scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                    1, 2, cfg_ingress, cfg_egress);
          scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 1, cfg_ingress);
          scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 1, cfg_egress);
        end
        "scoreboard_port_expect": begin
          scoreboard.expect_forward(PCIE_SVT_FORWARD_REQUEST,
                                    5, 2, request);
        end
        "scoreboard_port_observe": begin
          scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 5, request);
        end
        default:
          `uvm_fatal("SWITCH_ADAPTER_BAD_MODE",
                     {"unknown negative mode: ", mode})
      endcase
      `uvm_fatal("SWITCH_ADAPTER_NEGATIVE_MISSED",
                 {"negative mode did not fatal: ", mode})
    endtask

    virtual task run_phase(uvm_phase phase);
      string negative_mode;
      string positive_mode;
      phase.raise_objection(this);
      if ($value$plusargs("ADAPTER_NEGATIVE=%s", negative_mode))
        run_negative(negative_mode);
      else if ($value$plusargs("ADAPTER_POSITIVE=%s", positive_mode)) begin
        case (positive_mode)
          "scoreboard_cross_route":
            run_scoreboard_cross_route_regression();
          "setup_cfg": run_setup_cfg_regression();
          "scoreboard_cfg_rewrite":
            run_scoreboard_cfg_rewrite_regression();
          "scoreboard_local_cfg_read":
            run_scoreboard_local_cfg_read_regression();
          "scoreboard_local_cfg_write":
            run_scoreboard_local_cfg_write_regression();
          "scoreboard_cpl_nonwire":
            run_scoreboard_cpl_nonwire_regression();
          "scoreboard_request_nonwire":
            run_scoreboard_request_nonwire_regression();
          default:
            `uvm_fatal("SWITCH_ADAPTER_BAD_MODE",
                       {"unknown positive mode: ", positive_mode})
        endcase
      end
      else
        run_positive();
      #1ns;
      phase.drop_objection(this);
    endtask
  endclass
endpackage

module pcie_svt_switch_adapter_unit_top;
  import uvm_pkg::*;
  import pcie_svt_switch_adapter_unit_test_pkg::*;

  initial run_test("pcie_svt_switch_adapter_unit_test");

  final begin
    string negative_mode;
    if ($value$plusargs("ADAPTER_NEGATIVE=%s", negative_mode)) begin
      case (negative_mode)
        "callback_completion",
        "callback_unsupported",
        "callback_null",
        "callback_adapter_null",
        "callback_illegal_tuple": begin
          if (callback_drop_probe)
            $display("CALLBACK_DROP_PASS mode=%s", negative_mode);
          else
            $display("CALLBACK_DROP_FAIL mode=%s", negative_mode);
        end
      endcase
    end
  end
endmodule
