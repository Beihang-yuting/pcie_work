typedef enum int unsigned {
  PCIE_SVT_WIRE_RX,
  PCIE_SVT_WIRE_TX
} pcie_svt_wire_direction_e;

typedef enum int unsigned {
  PCIE_SVT_FORWARD_REQUEST,
  PCIE_SVT_FORWARD_COMPLETION
} pcie_svt_forward_direction_e;

class pcie_svt_switch_signature;
  pcie_svt_forward_direction_e direction;
  int ingress;
  int egress;
  int unsigned fmt;
  int unsigned tlp_type;
  bit [15:0] requester_id;
  bit [15:0] completer_id;
  bit [9:0] tag;
  bit [63:0] address;
  bit [9:0] length;
  bit [3:0] first_be;
  bit [3:0] last_be;
  int unsigned completion_status;
  bit bcm;
  bit [11:0] byte_count;
  bit [6:0] lower_address;
  bit [31:0] payload_digest;
  bit rx_seen;
  bit tx_seen;
endclass

class pcie_svt_switch_scoreboard extends uvm_component;
  `uvm_component_utils(pcie_svt_switch_scoreboard)

  protected pcie_svt_switch_signature expected[$];
  protected pcie_svt_switch_signature completed[$];

  function new(string name = "pcie_svt_switch_scoreboard",
               uvm_component parent = null);
    super.new(name, parent);
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

  protected function pcie_svt_switch_signature make_signature(
      pcie_svt_forward_direction_e direction,
      int ingress,
      int egress,
      svt_pcie_tlp transaction);
    pcie_svt_switch_signature signature;
    signature = new();
    signature.direction = direction;
    signature.ingress = ingress;
    signature.egress = egress;
    signature.fmt = transaction.fmt;
    signature.tlp_type = transaction.tlp_type;
    signature.requester_id = transaction.requester_id;
    signature.completer_id = transaction.completer_id;
    signature.tag = transaction.tag;
    case (transaction.tlp_type)
      svt_pcie_tlp::MEM_REQ,
      svt_pcie_tlp::DMEM_REQ:
        signature.address = transaction.address;
      svt_pcie_tlp::TYPE_0_CFG_REQ,
      svt_pcie_tlp::TYPE_1_CFG_REQ: begin
        signature.completer_id = {transaction.bus_number,
                                  transaction.device_number,
                                  transaction.function_number};
        signature.address = {36'b0,
                             transaction.bus_number,
                             transaction.device_number,
                             transaction.function_number,
                             transaction.register_number,
                             2'b00};
      end
      default:
        signature.address = transaction.address;
    endcase
    signature.length = transaction.length;
    signature.first_be = transaction.first_dw_be;
    signature.last_be = transaction.last_dw_be;
    signature.completion_status = transaction.completion_status;
    signature.bcm = transaction.byte_count_modified;
    signature.byte_count = transaction.byte_count;
    signature.lower_address = transaction.lower_address;
    signature.payload_digest = payload_fnv1a(transaction);
    return signature;
  endfunction

  protected function bit same_header(pcie_svt_switch_signature lhs,
                                     pcie_svt_switch_signature rhs);
    return (lhs.direction == rhs.direction) &&
           (lhs.fmt == rhs.fmt) &&
           (lhs.tlp_type == rhs.tlp_type) &&
           (lhs.requester_id == rhs.requester_id) &&
           (lhs.completer_id == rhs.completer_id) &&
           (lhs.tag == rhs.tag) &&
           (lhs.address == rhs.address) &&
           (lhs.length == rhs.length) &&
           (lhs.first_be == rhs.first_be) &&
           (lhs.last_be == rhs.last_be) &&
           (lhs.completion_status == rhs.completion_status) &&
           (lhs.bcm == rhs.bcm) &&
           (lhs.byte_count == rhs.byte_count) &&
           (lhs.lower_address == rhs.lower_address);
  endfunction

  protected function bit same_tlp(pcie_svt_switch_signature lhs,
                                  pcie_svt_switch_signature rhs);
    return same_header(lhs, rhs) &&
           (lhs.payload_digest == rhs.payload_digest);
  endfunction

  function void expect_forward(
      pcie_svt_forward_direction_e direction,
      int ingress,
      int egress,
      svt_pcie_tlp transaction);
    pcie_svt_switch_signature signature;
    if (transaction == null) begin
      `uvm_fatal("SCOREBOARD_NULL", "null forwarding expectation")
      return;
    end
    if ((ingress < 0) || (egress < 0)) begin
      `uvm_fatal("SCOREBOARD_PORT", "negative expectation port")
      return;
    end
    signature = make_signature(direction, ingress, egress, transaction);
    expected.push_back(signature);
  endfunction

  protected function void observe_rx(int port,
                                     pcie_svt_switch_signature observed);
    int selected;
    selected = -1;
    foreach (expected[index]) begin
      if ((expected[index].ingress == port) &&
          !expected[index].rx_seen && same_tlp(expected[index], observed)) begin
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
          same_header(expected[index], observed) &&
          (expected[index].payload_digest != observed.payload_digest)) begin
        `uvm_fatal("SCOREBOARD_PAYLOAD_MISMATCH",
                   "RX payload digest does not match expectation")
        return;
      end
    end
    foreach (expected[index]) begin
      if (same_tlp(expected[index], observed) &&
          (expected[index].ingress != port)) begin
        `uvm_fatal("SCOREBOARD_WRONG_INGRESS",
                   "TLP arrived on the wrong ingress port")
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

  protected function void observe_tx(int port,
                                     pcie_svt_switch_signature observed);
    int selected;
    selected = -1;

    foreach (expected[index]) begin
      if ((expected[index].ingress == port) &&
          same_tlp(expected[index], observed)) begin
        `uvm_fatal("SCOREBOARD_FORWARDING_LOOP",
                   "TLP returned to its ingress port")
        return;
      end
    end
    foreach (expected[index]) begin
      if ((expected[index].egress == port) && expected[index].rx_seen &&
          !expected[index].tx_seen && same_tlp(expected[index], observed)) begin
        selected = index;
        break;
      end
    end
    if (selected >= 0) begin
      expected[selected].tx_seen = 1'b1;
      completed.push_back(expected[selected]);
      expected.delete(selected);
      return;
    end

    foreach (expected[index]) begin
      if ((expected[index].egress == port) &&
          same_header(expected[index], observed) &&
          (expected[index].payload_digest != observed.payload_digest)) begin
        `uvm_fatal("SCOREBOARD_PAYLOAD_MISMATCH",
                   "TX payload digest does not match expectation")
        return;
      end
    end
    foreach (expected[index]) begin
      if (same_tlp(expected[index], observed) &&
          (expected[index].egress != port)) begin
        `uvm_fatal("SCOREBOARD_WRONG_EGRESS",
                   "TLP appeared on the wrong egress port")
        return;
      end
    end
    foreach (expected[index]) begin
      if ((expected[index].egress == port) &&
          same_tlp(expected[index], observed) &&
          !expected[index].rx_seen) begin
        `uvm_fatal("SCOREBOARD_MISSING_INGRESS",
                   "TX observation preceded its RX observation")
        return;
      end
    end
    foreach (completed[index]) begin
      if ((completed[index].egress == port) &&
          same_tlp(completed[index], observed)) begin
        `uvm_fatal("SCOREBOARD_DUPLICATE",
                   "duplicate TX forwarding observation")
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
    pcie_svt_switch_signature observed;
    if (transaction == null) begin
      `uvm_fatal("SCOREBOARD_NULL", "null wire observation")
      return;
    end
    observed = make_signature(infer_direction(transaction),
                              (wire_direction == PCIE_SVT_WIRE_RX) ? port : -1,
                              (wire_direction == PCIE_SVT_WIRE_TX) ? port : -1,
                              transaction);
    case (wire_direction)
      PCIE_SVT_WIRE_RX: observe_rx(port, observed);
      PCIE_SVT_WIRE_TX: observe_tx(port, observed);
      default:
        `uvm_fatal("SCOREBOARD_DIRECTION",
                   "invalid wire observation direction")
    endcase
  endfunction

  function void check_empty();
    if (expected.size() != 0) begin
      `uvm_fatal("SCOREBOARD_MISSING",
        $sformatf("%0d forwarding expectation(s) remain", expected.size()))
      return;
    end
    $display("SWITCH_SCOREBOARD_EMPTY completed=%0d", completed.size());
  endfunction
endclass
