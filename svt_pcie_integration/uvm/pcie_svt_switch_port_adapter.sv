class pcie_svt_switch_port_adapter extends uvm_component;
  `uvm_component_utils(pcie_svt_switch_port_adapter)

  int port_index = -1;
  pcie_tl_switch_port switch_port;
  svt_pcie_tlp_sequencer proxy_tlp_seqr;

  mailbox #(svt_pcie_tlp) request_mbox;
  mailbox #(svt_pcie_tlp) completion_mbox;

  int unsigned request_capture_count;
  int unsigned completion_capture_count;
  int unsigned request_ingress_count;
  int unsigned completion_ingress_count;
  int unsigned egress_forward_count;
  int unsigned drop_count;
  int unsigned unexpected_target_tx_count;

  function new(string name = "pcie_svt_switch_port_adapter",
               uvm_component parent = null);
    super.new(name, parent);
    request_mbox = new();
    completion_mbox = new();
  endfunction

  function void capture_request(svt_pcie_tlp observed);
    svt_pcie_tlp captured;
    if (observed == null) begin
      drop_count++;
      `uvm_fatal("ADAPTER_CAPTURE_NULL", "Request capture received null")
      return;
    end
    if (!$cast(captured, observed.clone()) || (captured == null)) begin
      drop_count++;
      `uvm_fatal("ADAPTER_CAPTURE_CLONE", "Request capture clone failed")
      return;
    end
    if (!request_mbox.try_put(captured)) begin
      drop_count++;
      `uvm_fatal("ADAPTER_REQUEST_ENQUEUE",
                 "unbounded Request mailbox rejected try_put")
      return;
    end
    request_capture_count++;
  endfunction

  function void capture_completion(svt_pcie_tlp observed);
    svt_pcie_tlp captured;
    if (observed == null) begin
      drop_count++;
      `uvm_fatal("ADAPTER_COMPLETION_NULL",
                 "Completion capture received null")
      return;
    end
    if (!$cast(captured, observed.clone()) || (captured == null)) begin
      drop_count++;
      `uvm_fatal("ADAPTER_COMPLETION_CLONE",
                 "Completion capture clone failed")
      return;
    end
    if (!completion_mbox.try_put(captured)) begin
      drop_count++;
      `uvm_fatal("ADAPTER_COMPLETION_ENQUEUE",
                 "unbounded Completion mailbox rejected try_put")
      return;
    end
    completion_capture_count++;
  endfunction

  function void note_unexpected_target_tx(svt_pcie_tlp transaction);
    unexpected_target_tx_count++;
    if (transaction == null) begin
      `uvm_fatal("TARGET_TX_SAFETY_WALL",
                 "Proxy Target attempted to transmit a null TLP")
      return;
    end
    `uvm_fatal("TARGET_TX_SAFETY_WALL",
               "Proxy Target attempted to generate a local response")
  endfunction

  protected task forward_ingress(bit is_request);
    svt_pcie_tlp captured;
    pcie_tl_tlp normalized;
    string reason;

    if (is_request)
      request_mbox.get(captured);
    else
      completion_mbox.get(captured);

    if (!pcie_svt_tlp_converter::from_svt(captured, normalized, reason) ||
        (normalized == null)) begin
      drop_count++;
      `uvm_fatal("ADAPTER_INGRESS_CONVERSION",
        $sformatf("port=%0d %s conversion failed: %s", port_index,
                  is_request ? "Request" : "Completion", reason))
      return;
    end
    if ((switch_port == null) || (switch_port.rx_fifo == null)) begin
      drop_count++;
      `uvm_fatal("ADAPTER_RX_FIFO_NULL", "switch-port RX FIFO is null")
      return;
    end
    switch_port.rx_fifo.put(normalized);
    if (is_request)
      request_ingress_count++;
    else
      completion_ingress_count++;
  endtask

  protected task forward_egress();
    pcie_tl_tlp normalized;
    svt_pcie_tlp converted;
    svt_pcie_tlp injected;
    svt_configuration generic_sequencer_cfg;
    svt_pcie_tl_configuration sequencer_cfg;
    pcie_svt_raw_tlp_sequence raw_sequence;
    string reason;

    if ((switch_port == null) || (switch_port.tx_fifo == null)) begin
      drop_count++;
      `uvm_fatal("ADAPTER_TX_FIFO_NULL", "switch-port TX FIFO is null")
      return;
    end
    switch_port.tx_fifo.get(normalized);
    if (!pcie_svt_tlp_converter::to_svt(normalized, converted, reason) ||
        (converted == null)) begin
      drop_count++;
      `uvm_fatal("ADAPTER_EGRESS_CONVERSION",
        $sformatf("port=%0d egress conversion failed: %s",
                  port_index, reason))
      return;
    end
    if (!$cast(injected, converted.clone()) || (injected == null)) begin
      drop_count++;
      `uvm_fatal("ADAPTER_EGRESS_CLONE", "raw egress clone failed")
      return;
    end
    if (proxy_tlp_seqr == null) begin
      drop_count++;
      `uvm_fatal("ADAPTER_SEQUENCER_NULL",
                 "Proxy TLP sequencer is null")
      return;
    end
    proxy_tlp_seqr.get_cfg(generic_sequencer_cfg);
    if ((generic_sequencer_cfg == null) ||
        !$cast(sequencer_cfg, generic_sequencer_cfg)) begin
      drop_count++;
      `uvm_fatal("ADAPTER_SEQUENCER_CFG_NULL",
                 "Proxy TLP sequencer configuration is null or invalid")
      return;
    end
    injected.setup_cfg(sequencer_cfg);
    raw_sequence = pcie_svt_raw_tlp_sequence::type_id::create(
      $sformatf("raw_sequence_%0d", egress_forward_count));
    if (raw_sequence == null) begin
      drop_count++;
      `uvm_fatal("ADAPTER_SEQUENCE_NULL",
                 "raw TLP sequence creation failed")
      return;
    end
    raw_sequence.request = injected;
    raw_sequence.start(proxy_tlp_seqr);
    egress_forward_count++;
  endtask

  virtual task run_phase(uvm_phase phase);
    if (switch_port == null) begin
      `uvm_fatal("ADAPTER_SWITCH_PORT_NULL", "switch-port handle is null")
      return;
    end
    if (proxy_tlp_seqr == null) begin
      `uvm_fatal("ADAPTER_SEQUENCER_NULL", "Proxy TLP sequencer is null")
      return;
    end
    fork
      forever forward_ingress(1'b1);
      forever forward_ingress(1'b0);
      forever forward_egress();
    join
  endtask

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    $display("SWITCH_ADAPTER_REPORT port=%0d request_q=%0d completion_q=%0d drops=%0d unexpected_target_tx=%0d",
             port_index, request_mbox.num(), completion_mbox.num(),
             drop_count, unexpected_target_tx_count);
  endfunction
endclass
