typedef enum int unsigned {
  PCIE_SVT_WIRE_RX,
  PCIE_SVT_WIRE_TX
} pcie_svt_wire_direction_e;

typedef enum int unsigned {
  PCIE_SVT_FORWARD_REQUEST,
  PCIE_SVT_FORWARD_COMPLETION
} pcie_svt_forward_direction_e;

typedef enum int unsigned {
  PCIE_SVT_SCOREBOARD_STRICT,
  PCIE_SVT_SCOREBOARD_DEFERRED_ENUM
} pcie_svt_scoreboard_mode_e;

class pcie_svt_switch_value_signature;
  pcie_svt_forward_direction_e direction;
  int unsigned fmt;
  int unsigned tlp_type;

  bit [2:0] traffic_class;
  bit th;
  bit td;
  bit ep;
  bit attr_relaxed_ordering;
  bit attr_id_order;
  bit attr_no_snoop;
  bit ln;
  bit [9:0] length;
  bit [15:0] requester_id;
  bit [9:0] tag;
  bit [31:0] tlp_prefixes[$];
  int num_local_tlp_prefixes;
  int num_end_to_end_tlp_prefixes;

  bit has_mem_fields;
  bit [63:0] address;
  bit [3:0] first_be;
  bit [3:0] last_be;
  int unsigned at;
  bit has_tph_fields;
  int unsigned ph;
  bit [15:0] st;

  bit has_cfg_fields;
  bit [7:0] bus_number;
  bit [4:0] device_number;
  bit [2:0] function_number;
  bit [9:0] register_number;

  bit has_completion_fields;
  bit [15:0] completer_id;
  int unsigned completion_status;
  bit bcm;
  bit [11:0] byte_count;
  bit [6:0] lower_address;

  bit [31:0] payload[];
  bit [31:0] payload_digest;
endclass

class pcie_svt_switch_pending_rx;
  int port;
  pcie_svt_switch_value_signature signature;
endclass

class pcie_svt_switch_expectation;
  pcie_svt_forward_direction_e direction;
  int ingress;
  int egress;
  bit local_response;
  pcie_svt_switch_value_signature rx_signature;
  pcie_svt_switch_value_signature tx_signature;
  bit rx_seen;
endclass

class pcie_svt_switch_scoreboard extends uvm_component;
  `uvm_component_utils(pcie_svt_switch_scoreboard)

  int unsigned num_ports = 5;
  uvm_analysis_imp #(pcie_tl_switch_route_event,
                     pcie_svt_switch_scoreboard) route_event_export;
  pcie_svt_scoreboard_mode_e mode = PCIE_SVT_SCOREBOARD_STRICT;

  protected pcie_svt_switch_expectation expected[$];
  protected pcie_svt_switch_expectation completed[$];
  protected pcie_svt_switch_pending_rx pending_rx[$];
  protected bit seen_event_id[longint unsigned];
  protected int unsigned dynamic_event_count;
  protected int unsigned dynamic_complete_count;

  function new(string name = "pcie_svt_switch_scoreboard",
               uvm_component parent = null);
    super.new(name, parent);
    route_event_export = new("route_event_export", this);
  endfunction

  protected function automatic bit [31:0] payload_fnv1a(
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

  protected function pcie_svt_forward_direction_e infer_direction(
      svt_pcie_tlp transaction);
    return (transaction.tlp_type == svt_pcie_tlp::CPL) ?
           PCIE_SVT_FORWARD_COMPLETION : PCIE_SVT_FORWARD_REQUEST;
  endfunction

  protected function bit valid_port(int port, string operation);
    if ((port < 0) || (port >= int'(num_ports))) begin
      `uvm_fatal("SCOREBOARD_PORT",
        $sformatf("%s port %0d is outside [0:%0d]",
                  operation, port, int'(num_ports) - 1))
      return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function pcie_svt_switch_value_signature make_signature(
      svt_pcie_tlp transaction);
    pcie_svt_switch_value_signature signature;
    signature = new();
    signature.direction = infer_direction(transaction);
    signature.fmt = transaction.fmt;
    signature.tlp_type = transaction.tlp_type;
    signature.traffic_class = transaction.traffic_class;
    signature.th = transaction.th;
    signature.td = transaction.td;
    signature.ep = transaction.ep;
    signature.attr_relaxed_ordering = transaction.attr_relaxed_ordering;
    signature.attr_id_order = transaction.attr_id_order;
    signature.attr_no_snoop = transaction.attr_no_snoop;
    signature.ln = transaction.ln;
    signature.length = transaction.length;
    signature.requester_id = transaction.requester_id;
    signature.tag = transaction.tag;
    signature.num_local_tlp_prefixes = transaction.num_local_tlp_prefixes;
    signature.num_end_to_end_tlp_prefixes =
      transaction.num_end_to_end_tlp_prefixes;
    foreach (transaction.tlp_prefixes[prefix_index])
      signature.tlp_prefixes.push_back(
        transaction.tlp_prefixes[prefix_index]);

    case (transaction.tlp_type)
      svt_pcie_tlp::MEM_REQ,
      svt_pcie_tlp::DMEM_REQ: begin
        signature.has_mem_fields = 1'b1;
        signature.address = transaction.address;
        signature.first_be = transaction.first_dw_be;
        signature.last_be = transaction.last_dw_be;
        signature.at = transaction.at;
        signature.has_tph_fields = transaction.th;
        if (signature.has_tph_fields) begin
          signature.ph = transaction.ph;
          signature.st = transaction.st;
        end
      end
      svt_pcie_tlp::TYPE_0_CFG_REQ,
      svt_pcie_tlp::TYPE_1_CFG_REQ: begin
        signature.has_cfg_fields = 1'b1;
        signature.bus_number = transaction.bus_number;
        signature.device_number = transaction.device_number;
        signature.function_number = transaction.function_number;
        signature.register_number = transaction.register_number;
        signature.first_be = transaction.first_dw_be;
        signature.last_be = transaction.last_dw_be;
      end
      svt_pcie_tlp::CPL: begin
        signature.has_completion_fields = 1'b1;
        signature.completer_id = transaction.completer_id;
        signature.completion_status = transaction.completion_status;
        signature.bcm = transaction.byte_count_modified;
        signature.byte_count = transaction.byte_count;
        signature.lower_address = transaction.lower_address;
      end
    endcase

    signature.payload = new[transaction.payload.size()];
    foreach (transaction.payload[dword_index])
      signature.payload[dword_index] = transaction.payload[dword_index];
    signature.payload_digest = payload_fnv1a(transaction);
    return signature;
  endfunction

  protected function pcie_svt_switch_value_signature
      make_signature_from_normalized(pcie_tl_tlp normalized);
    svt_pcie_tlp converted;
    string reason;
    if (!pcie_svt_tlp_converter::to_svt(normalized, converted, reason)) begin
      `uvm_fatal("SCOREBOARD_ROUTE_CONVERSION",
                 {"route snapshot conversion failed: ", reason})
      return null;
    end
    return make_signature(converted);
  endfunction

  protected function bit same_prefixes(
      pcie_svt_switch_value_signature lhs,
      pcie_svt_switch_value_signature rhs);
    if ((lhs.num_local_tlp_prefixes != rhs.num_local_tlp_prefixes) ||
        (lhs.num_end_to_end_tlp_prefixes !=
         rhs.num_end_to_end_tlp_prefixes) ||
        (lhs.tlp_prefixes.size() != rhs.tlp_prefixes.size()))
      return 1'b0;
    foreach (lhs.tlp_prefixes[index])
      if (lhs.tlp_prefixes[index] !== rhs.tlp_prefixes[index])
        return 1'b0;
    return 1'b1;
  endfunction

  protected function bit same_header(
      pcie_svt_switch_value_signature lhs,
      pcie_svt_switch_value_signature rhs);
    if ((lhs.direction != rhs.direction) ||
        (lhs.fmt != rhs.fmt) ||
        (lhs.tlp_type != rhs.tlp_type) ||
        (lhs.traffic_class != rhs.traffic_class) ||
        (lhs.th != rhs.th) ||
        (lhs.td != rhs.td) ||
        (lhs.ep != rhs.ep) ||
        (lhs.attr_relaxed_ordering != rhs.attr_relaxed_ordering) ||
        (lhs.attr_id_order != rhs.attr_id_order) ||
        (lhs.attr_no_snoop != rhs.attr_no_snoop) ||
        (lhs.ln != rhs.ln) ||
        (lhs.length != rhs.length) ||
        (lhs.requester_id != rhs.requester_id) ||
        (lhs.tag != rhs.tag) ||
        !same_prefixes(lhs, rhs) ||
        (lhs.has_mem_fields != rhs.has_mem_fields) ||
        (lhs.has_cfg_fields != rhs.has_cfg_fields) ||
        (lhs.has_completion_fields != rhs.has_completion_fields))
      return 1'b0;

    if (lhs.has_mem_fields &&
        ((lhs.address != rhs.address) ||
         (lhs.first_be != rhs.first_be) ||
         (lhs.last_be != rhs.last_be) ||
         (lhs.at != rhs.at) ||
         (lhs.has_tph_fields != rhs.has_tph_fields)))
      return 1'b0;
    if (lhs.has_mem_fields && lhs.has_tph_fields &&
        ((lhs.ph != rhs.ph) || (lhs.st != rhs.st)))
      return 1'b0;

    if (lhs.has_cfg_fields &&
        ((lhs.bus_number != rhs.bus_number) ||
         (lhs.device_number != rhs.device_number) ||
         (lhs.function_number != rhs.function_number) ||
         (lhs.register_number != rhs.register_number) ||
         (lhs.first_be != rhs.first_be) ||
         (lhs.last_be != rhs.last_be)))
      return 1'b0;

    if (lhs.has_completion_fields &&
        ((lhs.completer_id != rhs.completer_id) ||
         (lhs.completion_status != rhs.completion_status) ||
         (lhs.bcm != rhs.bcm) ||
         (lhs.byte_count != rhs.byte_count) ||
         (lhs.lower_address != rhs.lower_address)))
      return 1'b0;
    return 1'b1;
  endfunction

  protected function bit same_payload(
      pcie_svt_switch_value_signature lhs,
      pcie_svt_switch_value_signature rhs);
    if (lhs.payload.size() != rhs.payload.size())
      return 1'b0;
    foreach (lhs.payload[index])
      if (lhs.payload[index] !== rhs.payload[index])
        return 1'b0;
    return 1'b1;
  endfunction

  protected function bit same_tlp(
      pcie_svt_switch_value_signature lhs,
      pcie_svt_switch_value_signature rhs);
    return same_header(lhs, rhs) &&
           (lhs.payload_digest == rhs.payload_digest) &&
           same_payload(lhs, rhs);
  endfunction

  function void begin_deferred_enumeration();
    if ((mode != PCIE_SVT_SCOREBOARD_STRICT) ||
        (expected.size() != 0) || (pending_rx.size() != 0)) begin
      `uvm_fatal("SCOREBOARD_MODE",
        $sformatf("cannot begin deferred mode: mode=%0d expected=%0d pending=%0d",
                  mode, expected.size(), pending_rx.size()))
      return;
    end
    completed.delete();
    seen_event_id.delete();
    dynamic_event_count = 0;
    dynamic_complete_count = 0;
    mode = PCIE_SVT_SCOREBOARD_DEFERRED_ENUM;
  endfunction

  function void write(pcie_tl_switch_route_event route_event);
    pcie_svt_switch_expectation expectation;
    pcie_svt_switch_value_signature ingress_signature;
    pcie_svt_switch_value_signature egress_signature;
    int selected;
    int match_count;

    if (mode == PCIE_SVT_SCOREBOARD_STRICT)
      return;
    if (route_event == null) begin
      `uvm_fatal("SCOREBOARD_ROUTE_EVENT", "null route event")
      return;
    end
    if (!valid_port(route_event.ingress_port, "route ingress"))
      return;

    case (route_event.action)
      PCIE_TL_ROUTE_FORWARD: begin
        if (!valid_port(route_event.egress_port, "route egress"))
          return;
        if (route_event.ingress_port == route_event.egress_port) begin
          `uvm_fatal("SCOREBOARD_FORWARDING_LOOP",
                     "ordinary route event uses the ingress port")
          return;
        end
        if (route_event.route_code != route_event.egress_port) begin
          `uvm_fatal("SCOREBOARD_ROUTE_EVENT",
                     "forward route code does not match physical egress")
          return;
        end
        if ((route_event.ingress_tlp == null) ||
            (route_event.egress_tlp == null)) begin
          `uvm_fatal("SCOREBOARD_ROUTE_EVENT",
                     "forward route event has a null snapshot")
          return;
        end
      end
      PCIE_TL_ROUTE_LOCAL_RESPONSE: begin
        if (!valid_port(route_event.egress_port, "local route egress"))
          return;
        if ((route_event.ingress_port != route_event.egress_port) ||
            (route_event.route_code != SWITCH_ROUTE_LOCAL)) begin
          `uvm_fatal("SCOREBOARD_ROUTE_EVENT",
                     "local response route/physical ports are inconsistent")
          return;
        end
        if ((route_event.ingress_tlp == null) ||
            (route_event.egress_tlp == null)) begin
          `uvm_fatal("SCOREBOARD_ROUTE_EVENT",
                     "local response event has a null snapshot")
          return;
        end
      end
      PCIE_TL_ROUTE_DROP: begin
        if ((route_event.egress_port != SWITCH_ROUTE_DROP) ||
            (route_event.ingress_tlp == null) ||
            (route_event.egress_tlp != null)) begin
          `uvm_fatal("SCOREBOARD_ROUTE_EVENT",
                     "drop route event violates the snapshot contract")
          return;
        end
      end
      PCIE_TL_ROUTE_UNSUPPORTED_BROADCAST: begin
        if ((route_event.ingress_tlp == null) ||
            (route_event.egress_tlp == null)) begin
          `uvm_fatal("SCOREBOARD_ROUTE_EVENT",
                     "broadcast route event has a null snapshot")
          return;
        end
      end
      default: begin
        `uvm_fatal("SCOREBOARD_ROUTE_EVENT", "invalid route action")
        return;
      end
    endcase

    if (seen_event_id.exists(route_event.event_id)) begin
      `uvm_fatal("SCOREBOARD_ROUTE_DUPLICATE",
        $sformatf("route event_id=%0d was reused", route_event.event_id))
      return;
    end
    seen_event_id[route_event.event_id] = 1'b1;

    if (route_event.action inside {PCIE_TL_ROUTE_DROP,
                                   PCIE_TL_ROUTE_UNSUPPORTED_BROADCAST}) begin
      `uvm_fatal("SCOREBOARD_ROUTE_DROP",
        $sformatf("event=%0d action=%0d route=%0d ingress=%0d egress=%0d",
                  route_event.event_id, route_event.action,
                  route_event.route_code, route_event.ingress_port,
                  route_event.egress_port))
      return;
    end

    ingress_signature =
      make_signature_from_normalized(route_event.ingress_tlp);
    egress_signature =
      make_signature_from_normalized(route_event.egress_tlp);
    if ((route_event.action == PCIE_TL_ROUTE_FORWARD) &&
        (ingress_signature.direction != egress_signature.direction)) begin
      `uvm_fatal("SCOREBOARD_DIRECTION",
                 "forward route snapshots change TLP direction")
      return;
    end
    if ((route_event.action == PCIE_TL_ROUTE_LOCAL_RESPONSE) &&
        ((ingress_signature.direction != PCIE_SVT_FORWARD_REQUEST) ||
         (egress_signature.direction != PCIE_SVT_FORWARD_COMPLETION))) begin
      `uvm_fatal("SCOREBOARD_DIRECTION",
                 "local route must map a Request RX to a Completion TX")
      return;
    end

    selected = -1;
    match_count = 0;
    foreach (pending_rx[index]) begin
      if ((pending_rx[index].port == route_event.ingress_port) &&
          same_tlp(pending_rx[index].signature, ingress_signature)) begin
        selected = index;
        match_count++;
      end
    end
    if (match_count > 1) begin
      `uvm_fatal("SCOREBOARD_AMBIGUOUS",
                 "route event matches multiple pending RX observations")
      return;
    end
    if (match_count == 0) begin
      foreach (pending_rx[index]) begin
        if ((pending_rx[index].port != route_event.ingress_port) &&
            same_tlp(pending_rx[index].signature, ingress_signature)) begin
          `uvm_fatal("SCOREBOARD_WRONG_INGRESS",
                     "route event matched an RX on another ingress")
          return;
        end
      end
      foreach (pending_rx[index]) begin
        if ((pending_rx[index].port == route_event.ingress_port) &&
            same_header(pending_rx[index].signature, ingress_signature) &&
            !same_payload(pending_rx[index].signature, ingress_signature)) begin
          `uvm_fatal("SCOREBOARD_PAYLOAD_MISMATCH",
                     "route-event ingress payload differs from pending RX")
          return;
        end
      end
    end

    expectation = new();
    expectation.direction = egress_signature.direction;
    expectation.ingress = route_event.ingress_port;
    expectation.egress = route_event.egress_port;
    expectation.local_response =
      (route_event.action == PCIE_TL_ROUTE_LOCAL_RESPONSE);
    expectation.rx_signature = ingress_signature;
    expectation.tx_signature = egress_signature;
    expectation.rx_seen = (match_count == 1);
    if (selected >= 0)
      pending_rx.delete(selected);
    expected.push_back(expectation);
    dynamic_event_count++;
  endfunction

  protected function void observe_rx_deferred(
      int port,
      pcie_svt_switch_value_signature observed);
    pcie_svt_switch_pending_rx pending;
    int selected;
    int match_count;

    selected = -1;
    match_count = 0;
    foreach (expected[index]) begin
      if ((expected[index].ingress == port) &&
          !expected[index].rx_seen &&
          same_tlp(expected[index].rx_signature, observed)) begin
        selected = index;
        match_count++;
      end
    end
    if (match_count > 1) begin
      `uvm_fatal("SCOREBOARD_AMBIGUOUS",
                 "RX matches multiple live route expectations")
      return;
    end
    if (match_count == 1) begin
      expected[selected].rx_seen = 1'b1;
      return;
    end

    foreach (expected[index]) begin
      if ((expected[index].ingress != port) &&
          same_tlp(expected[index].rx_signature, observed)) begin
        `uvm_fatal("SCOREBOARD_WRONG_INGRESS",
                   "TLP arrived on the wrong deferred ingress port")
        return;
      end
    end
    foreach (expected[index]) begin
      if ((expected[index].ingress == port) && expected[index].rx_seen &&
          same_tlp(expected[index].rx_signature, observed)) begin
        `uvm_fatal("SCOREBOARD_DUPLICATE",
                   "duplicate deferred RX observation")
        return;
      end
    end
    foreach (pending_rx[index]) begin
      if ((pending_rx[index].port == port) &&
          same_tlp(pending_rx[index].signature, observed)) begin
        `uvm_fatal("SCOREBOARD_DUPLICATE",
                   "duplicate pending deferred RX observation")
        return;
      end
    end
    foreach (pending_rx[index]) begin
      if ((pending_rx[index].port != port) &&
          same_tlp(pending_rx[index].signature, observed)) begin
        `uvm_fatal("SCOREBOARD_WRONG_INGRESS",
                   "pending TLP was repeated on another ingress")
        return;
      end
    end
    foreach (expected[index]) begin
      if ((expected[index].ingress == port) &&
          !expected[index].rx_seen &&
          same_header(expected[index].rx_signature, observed) &&
          !same_payload(expected[index].rx_signature, observed)) begin
        `uvm_fatal("SCOREBOARD_PAYLOAD_MISMATCH",
                   "deferred RX payload differs from route expectation")
        return;
      end
    end
    foreach (pending_rx[index]) begin
      if ((pending_rx[index].port == port) &&
          same_header(pending_rx[index].signature, observed) &&
          !same_payload(pending_rx[index].signature, observed)) begin
        `uvm_fatal("SCOREBOARD_PAYLOAD_MISMATCH",
                   "deferred RX payload conflicts with pending RX")
        return;
      end
    end

    pending = new();
    pending.port = port;
    pending.signature = observed;
    pending_rx.push_back(pending);
  endfunction

  protected function void observe_tx_deferred(
      int port,
      pcie_svt_switch_value_signature observed);
    int selected;
    int match_count;

    selected = -1;
    match_count = 0;
    foreach (expected[index]) begin
      if ((expected[index].egress == port) && expected[index].rx_seen &&
          same_tlp(expected[index].tx_signature, observed)) begin
        selected = index;
        match_count++;
      end
    end
    if (match_count > 1) begin
      `uvm_fatal("SCOREBOARD_AMBIGUOUS",
                 "TX matches multiple live route expectations")
      return;
    end
    if (match_count == 1) begin
      completed.push_back(expected[selected]);
      expected.delete(selected);
      dynamic_complete_count++;
      return;
    end

    foreach (completed[index]) begin
      if ((completed[index].egress == port) &&
          same_tlp(completed[index].tx_signature, observed)) begin
        `uvm_fatal("SCOREBOARD_DUPLICATE",
                   "duplicate deferred TX forwarding observation")
        return;
      end
    end
    foreach (expected[index]) begin
      if ((expected[index].ingress == port) &&
          (same_tlp(expected[index].rx_signature, observed) ||
           (!expected[index].local_response &&
            same_tlp(expected[index].tx_signature, observed)))) begin
        `uvm_fatal("SCOREBOARD_FORWARDING_LOOP",
                   "deferred TLP returned to its ingress port")
        return;
      end
    end
    foreach (expected[index]) begin
      if ((expected[index].egress == port) &&
          same_header(expected[index].tx_signature, observed) &&
          !same_payload(expected[index].tx_signature, observed)) begin
        `uvm_fatal("SCOREBOARD_PAYLOAD_MISMATCH",
          $sformatf("deferred TX payload differs: expected=%08x observed=%08x",
                    expected[index].tx_signature.payload_digest,
                    observed.payload_digest))
        return;
      end
    end
    foreach (expected[index]) begin
      if (same_tlp(expected[index].tx_signature, observed) &&
          (expected[index].egress != port)) begin
        `uvm_fatal("SCOREBOARD_WRONG_EGRESS",
                   "deferred TLP appeared on the wrong egress port")
        return;
      end
    end
    foreach (expected[index]) begin
      if ((expected[index].egress == port) &&
          same_tlp(expected[index].tx_signature, observed) &&
          !expected[index].rx_seen) begin
        `uvm_fatal("SCOREBOARD_MISSING_INGRESS",
                   "deferred TX observation preceded its RX observation")
        return;
      end
    end
    foreach (expected[index]) begin
      if ((expected[index].egress == port) && expected[index].rx_seen &&
          (expected[index].tx_signature.direction == observed.direction)) begin
        `uvm_fatal("SCOREBOARD_HEADER_MISMATCH",
                   "deferred TX header does not match route expectation")
        return;
      end
    end
    if (observed.direction == PCIE_SVT_FORWARD_COMPLETION) begin
      `uvm_fatal("SCOREBOARD_UNMATCHED_COMPLETION",
                 "Completion TX has no matching deferred route event")
      return;
    end
    `uvm_fatal("SCOREBOARD_DUPLICATE",
               "unexpected or duplicate deferred TX Request")
  endfunction

  function bit deferred_idle();
    return (mode == PCIE_SVT_SCOREBOARD_DEFERRED_ENUM) &&
           (pending_rx.size() == 0) && (expected.size() == 0) &&
           (dynamic_event_count == dynamic_complete_count);
  endfunction

  function void end_deferred_enumeration();
    if (mode != PCIE_SVT_SCOREBOARD_DEFERRED_ENUM) begin
      `uvm_fatal("SCOREBOARD_MODE",
                 "cannot end deferred mode while scoreboard is strict")
      return;
    end
    if (pending_rx.size() != 0) begin
      `uvm_fatal("SCOREBOARD_MISSING_ROUTE",
        $sformatf("%0d RX observation(s) have no route event",
                  pending_rx.size()))
      return;
    end
    foreach (expected[index]) begin
      if (!expected[index].rx_seen) begin
        `uvm_fatal("SCOREBOARD_MISSING_INGRESS",
                   "route event has no matching RX observation")
        return;
      end
    end
    if (expected.size() != 0) begin
      `uvm_fatal("SCOREBOARD_MISSING",
        $sformatf("%0d deferred TX expectation(s) remain", expected.size()))
      return;
    end
    if (dynamic_event_count != dynamic_complete_count) begin
      `uvm_fatal("SCOREBOARD_COUNT",
        $sformatf("route events=%0d completed=%0d",
                  dynamic_event_count, dynamic_complete_count))
      return;
    end
    $display("SWITCH_DEFERRED_SCOREBOARD_EMPTY events=%0d completed=%0d pending=0 expected=0",
             dynamic_event_count, dynamic_complete_count);
    mode = PCIE_SVT_SCOREBOARD_STRICT;
  endfunction

  function void expect_forward(
      pcie_svt_forward_direction_e direction,
      int ingress,
      int egress,
      svt_pcie_tlp ingress_tlp,
      svt_pcie_tlp egress_tlp = null);
    pcie_svt_switch_expectation expectation;
    if (ingress_tlp == null) begin
      `uvm_fatal("SCOREBOARD_NULL", "null forwarding expectation")
      return;
    end
    if (!valid_port(ingress, "expect ingress") ||
        !valid_port(egress, "expect egress"))
      return;
    if (ingress == egress) begin
      `uvm_fatal("SCOREBOARD_FORWARDING_LOOP",
                 "ordinary forwarding expectation uses the ingress port")
      return;
    end
    expectation = new();
    expectation.direction = direction;
    expectation.ingress = ingress;
    expectation.egress = egress;
    expectation.rx_signature = make_signature(ingress_tlp);
    expectation.tx_signature = make_signature(
      (egress_tlp == null) ? ingress_tlp : egress_tlp);
    if ((expectation.rx_signature.direction != direction) ||
        (expectation.tx_signature.direction != direction)) begin
      `uvm_fatal("SCOREBOARD_DIRECTION",
                 "forwarding TLP direction does not match expectation")
      return;
    end
    expected.push_back(expectation);
  endfunction

  function void expect_local_response(
      int port,
      svt_pcie_tlp request_tlp,
      svt_pcie_tlp response_tlp);
    pcie_svt_switch_expectation expectation;
    if ((request_tlp == null) || (response_tlp == null)) begin
      `uvm_fatal("SCOREBOARD_NULL", "null local-response expectation")
      return;
    end
    if (!valid_port(port, "local response"))
      return;
    if ((infer_direction(request_tlp) != PCIE_SVT_FORWARD_REQUEST) ||
        (infer_direction(response_tlp) != PCIE_SVT_FORWARD_COMPLETION)) begin
      `uvm_fatal("SCOREBOARD_DIRECTION",
                 "local response must map a Request RX to a Completion TX")
      return;
    end
    expectation = new();
    expectation.direction = PCIE_SVT_FORWARD_COMPLETION;
    expectation.ingress = port;
    expectation.egress = port;
    expectation.local_response = 1'b1;
    expectation.rx_signature = make_signature(request_tlp);
    expectation.tx_signature = make_signature(response_tlp);
    expected.push_back(expectation);
  endfunction

  protected function void observe_rx(
      int port,
      pcie_svt_switch_value_signature observed);
    int selected;
    selected = -1;
    foreach (expected[index]) begin
      if ((expected[index].ingress == port) &&
          !expected[index].rx_seen &&
          same_tlp(expected[index].rx_signature, observed)) begin
        selected = index;
        break;
      end
    end
    if (selected >= 0) begin
      expected[selected].rx_seen = 1'b1;
      return;
    end

    foreach (expected[index]) begin
      if ((expected[index].ingress == port) &&
          !expected[index].rx_seen &&
          same_header(expected[index].rx_signature, observed) &&
          !same_payload(expected[index].rx_signature, observed)) begin
        `uvm_fatal("SCOREBOARD_PAYLOAD_MISMATCH",
          $sformatf("RX payload differs: expected digest=%08x observed=%08x",
                    expected[index].rx_signature.payload_digest,
                    observed.payload_digest))
        return;
      end
    end
    foreach (expected[index]) begin
      if (same_tlp(expected[index].rx_signature, observed) &&
          (expected[index].ingress != port)) begin
        `uvm_fatal("SCOREBOARD_WRONG_INGRESS",
                   "TLP arrived on the wrong ingress port")
        return;
      end
    end
    foreach (expected[index]) begin
      if ((expected[index].ingress == port) &&
          !expected[index].rx_seen &&
          (expected[index].rx_signature.direction == observed.direction)) begin
        `uvm_fatal("SCOREBOARD_HEADER_MISMATCH",
                   "RX header does not match expectation")
        return;
      end
    end
    if (observed.direction == PCIE_SVT_FORWARD_COMPLETION) begin
      `uvm_fatal("SCOREBOARD_UNMATCHED_COMPLETION",
                 "Completion has no matching forwarding expectation")
      return;
    end
    `uvm_fatal("SCOREBOARD_DUPLICATE",
               "unexpected or duplicate RX Request")
  endfunction

  protected function void observe_tx(
      int port,
      pcie_svt_switch_value_signature observed);
    int selected;
    selected = -1;

    foreach (expected[index]) begin
      if ((expected[index].egress == port) && expected[index].rx_seen &&
          same_tlp(expected[index].tx_signature, observed)) begin
        selected = index;
        break;
      end
    end
    if (selected >= 0) begin
      completed.push_back(expected[selected]);
      expected.delete(selected);
      return;
    end

    foreach (completed[index]) begin
      if ((completed[index].egress == port) &&
          same_tlp(completed[index].tx_signature, observed)) begin
        `uvm_fatal("SCOREBOARD_DUPLICATE",
                   "duplicate TX forwarding observation")
        return;
      end
    end
    foreach (expected[index]) begin
      if ((expected[index].ingress == port) &&
          (same_tlp(expected[index].rx_signature, observed) ||
           (!expected[index].local_response &&
            same_tlp(expected[index].tx_signature, observed)))) begin
        `uvm_fatal("SCOREBOARD_FORWARDING_LOOP",
                   "TLP returned to its ingress port")
        return;
      end
    end
    foreach (expected[index]) begin
      if ((expected[index].egress == port) && expected[index].rx_seen &&
          same_header(expected[index].tx_signature, observed) &&
          !same_payload(expected[index].tx_signature, observed)) begin
        `uvm_fatal("SCOREBOARD_PAYLOAD_MISMATCH",
          $sformatf("TX payload differs: expected digest=%08x observed=%08x",
                    expected[index].tx_signature.payload_digest,
                    observed.payload_digest))
        return;
      end
    end
    foreach (expected[index]) begin
      if (same_tlp(expected[index].tx_signature, observed) &&
          (expected[index].egress != port)) begin
        `uvm_fatal("SCOREBOARD_WRONG_EGRESS",
                   "TLP appeared on the wrong egress port")
        return;
      end
    end
    foreach (expected[index]) begin
      if ((expected[index].egress == port) &&
          same_tlp(expected[index].tx_signature, observed) &&
          !expected[index].rx_seen) begin
        `uvm_fatal("SCOREBOARD_MISSING_INGRESS",
                   "TX observation preceded its RX observation")
        return;
      end
    end
    foreach (expected[index]) begin
      if ((expected[index].egress == port) && expected[index].rx_seen &&
          (expected[index].tx_signature.direction == observed.direction)) begin
        `uvm_fatal("SCOREBOARD_HEADER_MISMATCH",
                   "TX header does not match expectation")
        return;
      end
    end
    if (observed.direction == PCIE_SVT_FORWARD_COMPLETION) begin
      `uvm_fatal("SCOREBOARD_UNMATCHED_COMPLETION",
                 "Completion TX has no matching expectation")
      return;
    end
    `uvm_fatal("SCOREBOARD_DUPLICATE",
               "unexpected or duplicate TX Request")
  endfunction

  function void observe_wire(pcie_svt_wire_direction_e wire_direction,
                             int port,
                             svt_pcie_tlp transaction);
    pcie_svt_switch_value_signature observed;
    if (transaction == null) begin
      `uvm_fatal("SCOREBOARD_NULL", "null wire observation")
      return;
    end
    if (!valid_port(port, "wire observation"))
      return;
    observed = make_signature(transaction);
    case (wire_direction)
      PCIE_SVT_WIRE_RX:
        if (mode == PCIE_SVT_SCOREBOARD_DEFERRED_ENUM)
          observe_rx_deferred(port, observed);
        else
          observe_rx(port, observed);
      PCIE_SVT_WIRE_TX:
        if (mode == PCIE_SVT_SCOREBOARD_DEFERRED_ENUM)
          observe_tx_deferred(port, observed);
        else
          observe_tx(port, observed);
      default:
        `uvm_fatal("SCOREBOARD_DIRECTION",
                   "invalid wire observation direction")
    endcase
  endfunction

  function void check_empty();
    if (mode == PCIE_SVT_SCOREBOARD_DEFERRED_ENUM) begin
      `uvm_fatal("SCOREBOARD_MODE",
                 "check_empty called during deferred enumeration")
      return;
    end
    if (expected.size() != 0) begin
      `uvm_fatal("SCOREBOARD_MISSING",
        $sformatf("%0d forwarding expectation(s) remain", expected.size()))
      return;
    end
    $display("SWITCH_SCOREBOARD_EMPTY completed=%0d", completed.size());
  endfunction
endclass
