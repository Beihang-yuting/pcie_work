class pcie_svt_switch_enumeration_vseq extends
    pcie_svt_switch_enumeration_base_vseq;
  localparam time PCIE_SVT_ENUM_QUIESCENCE_TIMEOUT = 100us;
  localparam time PCIE_SVT_ENUM_QUIESCENCE_POLL = 100ns;

  `uvm_object_utils(pcie_svt_switch_enumeration_vseq)

  int unsigned switch_drop_start;
  int unsigned adapter_drop_start[5];

  function new(string name = "pcie_svt_switch_enumeration_vseq");
    super.new(name);
  endfunction

  protected function void validate_proxy_handles();
    if ((p_sequencer.switch_core == null) ||
        (p_sequencer.switch_scoreboard == null)) begin
      `uvm_fatal("SWITCH_ENUM_QUIESCENCE",
        "virtual sequencer has no switch-core/scoreboard handle")
      return;
    end
    for (int unsigned i = 0; i < 5; i++) begin
      if (p_sequencer.switch_adapter[i] == null) begin
        `uvm_fatal("SWITCH_ENUM_QUIESCENCE", $sformatf(
          "port=%0d virtual sequencer has no switch-adapter handle", i))
        return;
      end
    end
  endfunction

  protected function bit proxy_is_quiescent();
    if ((p_sequencer.switch_core == null) ||
        (p_sequencer.switch_scoreboard == null) ||
        (p_sequencer.switch_core.outstanding_count() != 0) ||
        !p_sequencer.switch_scoreboard.deferred_idle())
      return 1'b0;
    for (int unsigned i = 0; i < 5; i++) begin
      if ((p_sequencer.switch_adapter[i] == null) ||
          (p_sequencer.switch_adapter[i].request_mbox.num() != 0) ||
          (p_sequencer.switch_adapter[i].completion_mbox.num() != 0))
        return 1'b0;
    end
    return 1'b1;
  endfunction

  protected task wait_for_proxy_quiescent();
    time deadline;
    string residuals;

    deadline = $time + PCIE_SVT_ENUM_QUIESCENCE_TIMEOUT;
    forever begin
      if (proxy_is_quiescent())
        return;
      if ($time >= deadline) begin
        residuals = $sformatf(
          "timeout=%0t switch_outstanding=%0d scoreboard_deferred_idle=%0b",
          PCIE_SVT_ENUM_QUIESCENCE_TIMEOUT,
          p_sequencer.switch_core.outstanding_count(),
          p_sequencer.switch_scoreboard.deferred_idle());
        for (int unsigned i = 0; i < 5; i++)
          residuals = {residuals, $sformatf(
            " port=%0d request_q=%0d completion_q=%0d",
            i, p_sequencer.switch_adapter[i].request_mbox.num(),
            p_sequencer.switch_adapter[i].completion_mbox.num())};
        `uvm_fatal("SWITCH_ENUM_QUIESCENCE", residuals)
        return;
      end
      #PCIE_SVT_ENUM_QUIESCENCE_POLL;
    end
  endtask

  protected function void check_final_proxy_state(
      int unsigned switch_drop_start,
      int unsigned adapter_drop_start[5]);
    if (p_sequencer.switch_core.total_dropped != switch_drop_start) begin
      `uvm_fatal("SWITCH_ENUM_DROP", $sformatf(
        "switch drop count changed during official enumeration start=%0d current=%0d",
        switch_drop_start, p_sequencer.switch_core.total_dropped))
      return;
    end
    for (int unsigned i = 0; i < 5; i++) begin
      if (p_sequencer.switch_adapter[i].drop_count !=
          adapter_drop_start[i]) begin
        `uvm_fatal("SWITCH_ENUM_DROP", $sformatf(
          "adapter port=%0d drop count changed during enumeration start=%0d current=%0d",
          i, adapter_drop_start[i],
          p_sequencer.switch_adapter[i].drop_count))
        return;
      end
    end
    if (p_sequencer.switch_core.outstanding_count() != 0) begin
      `uvm_fatal("SWITCH_ENUM_QUIESCENCE", $sformatf(
        "final switch outstanding=%0d expected=0",
        p_sequencer.switch_core.outstanding_count()))
      return;
    end
    for (int unsigned i = 0; i < 5; i++) begin
      if ((p_sequencer.switch_adapter[i].request_mbox.num() != 0) ||
          (p_sequencer.switch_adapter[i].completion_mbox.num() != 0) ||
          (p_sequencer.switch_adapter[i].unexpected_target_tx_count != 0)) begin
        `uvm_fatal("SWITCH_ENUM_QUIESCENCE", $sformatf(
          "final port=%0d request_q=%0d completion_q=%0d unexpected_target_tx=%0d",
          i, p_sequencer.switch_adapter[i].request_mbox.num(),
          p_sequencer.switch_adapter[i].completion_mbox.num(),
          p_sequencer.switch_adapter[i].unexpected_target_tx_count))
        return;
      end
    end
    $display("SWITCH_ENUM_SWITCH_GATE outstanding=0 drop_delta=0");
  endfunction

  protected virtual task before_official_enumeration();
    validate_proxy_handles();
    switch_drop_start = p_sequencer.switch_core.total_dropped;
    for (int unsigned i = 0; i < 5; i++)
      adapter_drop_start[i] = p_sequencer.switch_adapter[i].drop_count;
    p_sequencer.switch_scoreboard.begin_deferred_enumeration();
  endtask

  protected virtual task after_official_enumeration();
    wait_for_proxy_quiescent();
    p_sequencer.switch_scoreboard.end_deferred_enumeration();
    check_final_proxy_state(switch_drop_start, adapter_drop_start);
  endtask

  protected virtual function void report_success();
    $display("SWITCH_ENUM_PASS usp=%0d dsp=%0d ep=%0d bars=%0d",
      p_sequencer.switch_enum_registry.usp_count(),
      p_sequencer.switch_enum_registry.dsp_count(),
      p_sequencer.switch_enum_registry.ep_count(),
      p_sequencer.switch_enum_registry.bar_count());
  endfunction
endclass
