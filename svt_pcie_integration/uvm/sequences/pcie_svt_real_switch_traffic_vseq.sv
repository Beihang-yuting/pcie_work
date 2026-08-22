class pcie_svt_real_switch_traffic_vseq extends
    uvm_sequence #(uvm_sequence_item);
  localparam int unsigned PCIE_SVT_REAL_SWITCH_PORT_COUNT = 5;
  localparam int unsigned PCIE_SVT_REAL_SWITCH_FLOW_COUNT = 8;
  localparam int unsigned PCIE_SVT_REAL_SWITCH_EP_COUNT = 4;
  localparam time PCIE_SVT_REAL_SWITCH_TRAFFIC_TIMEOUT = 1ms;
  localparam time PCIE_SVT_REAL_SWITCH_IDLE_TIMEOUT = 100us;

  pcie_svt_mem_write_read_seq flow_sequence[PCIE_SVT_REAL_SWITCH_FLOW_COUNT];
  int unsigned flow_source_port[PCIE_SVT_REAL_SWITCH_FLOW_COUNT];
  bit flow_finished[PCIE_SVT_REAL_SWITCH_FLOW_COUNT];
  svt_pcie_driver_app_service_wait_until_idle_sequence
    driver_idle_sequence[PCIE_SVT_REAL_SWITCH_PORT_COUNT];
  svt_pcie_target_app_service_wait_until_idle_sequence
    target_idle_sequence[PCIE_SVT_REAL_SWITCH_EP_COUNT];
  bit driver_idle_finished[PCIE_SVT_REAL_SWITCH_PORT_COUNT];
  bit target_idle_finished[PCIE_SVT_REAL_SWITCH_EP_COUNT];

  `uvm_object_utils(pcie_svt_real_switch_traffic_vseq)
  `uvm_declare_p_sequencer(pcie_svt_virtual_sequencer)

  function new(string name = "pcie_svt_real_switch_traffic_vseq");
    super.new(name);
  endfunction

  protected function automatic int unsigned primary_index(
      int unsigned slot);
    case (slot)
      0: return PCIE_SVT_PRIMARY_RC0;
      1: return PCIE_SVT_PRIMARY_EP0;
      2: return PCIE_SVT_PRIMARY_EP1;
      3: return PCIE_SVT_PRIMARY_EP2;
      4: return PCIE_SVT_PRIMARY_EP3;
      default: begin
        `uvm_fatal("REAL_SWITCH_TRAFFIC_SETUP", $sformatf(
          "invalid real-Switch primary slot=%0d", slot))
        return PCIE_SVT_PRIMARY_RC0;
      end
    endcase
  endfunction

  protected function void validate_traffic_sequencers();
    for (int unsigned slot = 0;
         slot < PCIE_SVT_REAL_SWITCH_PORT_COUNT; slot++) begin
      int unsigned index;
      index = primary_index(slot);
      if (!p_sequencer.active_port[index] ||
          (p_sequencer.port_seqr[index] == null))
        `uvm_fatal("REAL_SWITCH_TRAFFIC_SEQUENCER", $sformatf(
          "primary port index=%0d is inactive or has no virtual sequencer",
          index))
      if (!p_sequencer.port_seqr[index].driver_transaction_seqr.exists(0) ||
          (p_sequencer.port_seqr[index].driver_transaction_seqr[0] == null))
        `uvm_fatal("REAL_SWITCH_TRAFFIC_SEQUENCER", $sformatf(
          {"primary port index=%0d has no Driver App transaction ",
           "sequencer[0]"}, index))
    end
  endfunction

  protected function void validate_idle_sequencers();
    for (int unsigned slot = 0;
         slot < PCIE_SVT_REAL_SWITCH_PORT_COUNT; slot++) begin
      int unsigned index;
      index = primary_index(slot);
      if (!p_sequencer.port_seqr[index].driver_seqr.exists(0) ||
          (p_sequencer.port_seqr[index].driver_seqr[0] == null))
        `uvm_fatal("REAL_SWITCH_TRAFFIC_IDLE_SEQUENCER", $sformatf(
          {"primary port index=%0d has no Driver App service ",
           "sequencer[0]"}, index))
    end
    for (int unsigned ep = 0;
         ep < PCIE_SVT_REAL_SWITCH_EP_COUNT; ep++) begin
      int unsigned index;
      index = PCIE_SVT_PRIMARY_EP0 + ep;
      if (!p_sequencer.port_seqr[index].target_seqr.exists(0) ||
          (p_sequencer.port_seqr[index].target_seqr[0] == null))
        `uvm_fatal("REAL_SWITCH_TRAFFIC_IDLE_SEQUENCER", $sformatf(
          {"Endpoint=%0d primary_index=%0d has no Target App service ",
           "sequencer[0]"}, ep, index))
    end
  endfunction

  protected task automatic run_flow(int unsigned index);
    int unsigned source_port;
    source_port = flow_source_port[index];
    flow_sequence[index].start(
      p_sequencer.port_seqr[source_port].driver_transaction_seqr[0]);
    if (!flow_sequence[index].completed)
      `uvm_fatal("REAL_SWITCH_TRAFFIC_COMPLETION", $sformatf(
        "flow=%0d returned without completed=1", index))
    flow_finished[index] = 1'b1;
  endtask

  protected task run_traffic_with_watchdog();
    bit traffic_group_done;
    realtime start_time;
    realtime deadline;
    realtime completion_time;

    traffic_group_done = 1'b0;
    start_time = $realtime;
    deadline = start_time + PCIE_SVT_REAL_SWITCH_TRAFFIC_TIMEOUT;
    completion_time = 0;
    fork : traffic_watchdog
      begin : traffic_group
        for (int unsigned i = 0;
             i < PCIE_SVT_REAL_SWITCH_FLOW_COUNT; i++) begin
          fork
            automatic int unsigned index = i;
            run_flow(index);
          join_none
        end
        wait fork;
        completion_time = $realtime;
        traffic_group_done = 1'b1;
      end
      begin : traffic_timeout
        #(PCIE_SVT_REAL_SWITCH_TRAFFIC_TIMEOUT);
        if (!traffic_group_done)
          #1step;
      end
    join_any
    disable traffic_watchdog;

    if (!traffic_group_done || (completion_time > deadline)) begin
      string unfinished;
      unfinished = "";
      for (int unsigned i = 0;
           i < PCIE_SVT_REAL_SWITCH_FLOW_COUNT; i++) begin
        if (!flow_finished[i])
          unfinished = {unfinished, $sformatf(
            {" flow=%0d direction=%s Endpoint=%0d address=0x%016h ",
             "last_status=%0d;"}, i, flow_sequence[i].direction.name(),
            flow_sequence[i].endpoint_index, flow_sequence[i].address,
            flow_sequence[i].last_status)};
      end
      `uvm_fatal("REAL_SWITCH_TRAFFIC_TIMEOUT", $sformatf(
        {"eight-flow group exceeded watchdog=%0t start=%0.6f ",
         "deadline=%0.6f completion=%0.6f unfinished:%s"},
        PCIE_SVT_REAL_SWITCH_TRAFFIC_TIMEOUT, start_time, deadline,
        completion_time, unfinished))
    end
  endtask

  protected task automatic run_driver_idle(int unsigned slot);
    int unsigned index;
    index = primary_index(slot);
    driver_idle_sequence[slot].start(
      p_sequencer.port_seqr[index].driver_seqr[0]);
    driver_idle_finished[slot] = 1'b1;
  endtask

  protected task automatic run_target_idle(int unsigned ep);
    int unsigned index;
    index = PCIE_SVT_PRIMARY_EP0 + ep;
    target_idle_sequence[ep].start(
      p_sequencer.port_seqr[index].target_seqr[0]);
    target_idle_finished[ep] = 1'b1;
  endtask

  protected task run_idle_with_watchdog();
    bit idle_group_done;
    realtime start_time;
    realtime deadline;
    realtime completion_time;

    idle_group_done = 1'b0;
    start_time = $realtime;
    deadline = start_time + PCIE_SVT_REAL_SWITCH_IDLE_TIMEOUT;
    completion_time = 0;
    fork : idle_watchdog
      begin : idle_group
        for (int unsigned slot = 0;
             slot < PCIE_SVT_REAL_SWITCH_PORT_COUNT; slot++) begin
          fork
            automatic int unsigned index = slot;
            run_driver_idle(index);
          join_none
        end
        for (int unsigned ep = 0;
             ep < PCIE_SVT_REAL_SWITCH_EP_COUNT; ep++) begin
          fork
            automatic int unsigned index = ep;
            run_target_idle(index);
          join_none
        end
        wait fork;
        completion_time = $realtime;
        idle_group_done = 1'b1;
      end
      begin : idle_timeout
        #(PCIE_SVT_REAL_SWITCH_IDLE_TIMEOUT);
        if (!idle_group_done)
          #1step;
      end
    join_any
    disable idle_watchdog;

    if (!idle_group_done || (completion_time > deadline)) begin
      string unfinished;
      unfinished = "";
      for (int unsigned slot = 0;
           slot < PCIE_SVT_REAL_SWITCH_PORT_COUNT; slot++) begin
        if (!driver_idle_finished[slot])
          unfinished = {unfinished, $sformatf(
            " driver_port=%0d;", primary_index(slot))};
      end
      for (int unsigned ep = 0;
           ep < PCIE_SVT_REAL_SWITCH_EP_COUNT; ep++) begin
        if (!target_idle_finished[ep])
          unfinished = {unfinished, $sformatf(" target_Endpoint=%0d;", ep)};
      end
      `uvm_fatal("REAL_SWITCH_TRAFFIC_IDLE_TIMEOUT", $sformatf(
        {"nine-sequence idle group exceeded watchdog=%0t start=%0.6f ",
         "deadline=%0.6f completion=%0.6f unfinished:%s"},
        PCIE_SVT_REAL_SWITCH_IDLE_TIMEOUT, start_time, deadline,
        completion_time, unfinished))
    end
  endtask

  virtual task body();
    pcie_svt_switch_enum_registry registry;
    pcie_svt_real_switch_traffic_plan plan;
    string plan_error;

    if (p_sequencer == null)
      `uvm_fatal("REAL_SWITCH_TRAFFIC_SETUP",
        "null PCIe SVT virtual sequencer")
    registry = p_sequencer.switch_enum_registry;
    if ((registry == null) || !registry.validated)
      `uvm_fatal("REAL_SWITCH_TRAFFIC_SETUP",
        "switch enumeration registry is null or not validated")
    if ((p_sequencer.rc_host_memory_initialized !== 1'b1) ||
        (p_sequencer.rc_host_memory_base !==
          64'h0000_0002_0000_0000) ||
        (p_sequencer.rc_host_memory_limit !==
          64'h0000_0002_0000_ffff))
      `uvm_fatal("REAL_SWITCH_TRAFFIC_HOST_MEMORY", $sformatf(
        {"host memory must be initialized=1 base=0x0000000200000000 ",
         "limit=0x000000020000ffff; actual initialized=%0b ",
         "base=0x%016h limit=0x%016h"},
        p_sequencer.rc_host_memory_initialized,
        p_sequencer.rc_host_memory_base,
        p_sequencer.rc_host_memory_limit))

    validate_traffic_sequencers();
    plan = pcie_svt_real_switch_traffic_plan::type_id::create("traffic_plan");
    if (plan == null)
      `uvm_fatal("REAL_SWITCH_TRAFFIC_PLAN", "traffic-plan creation failed")
    if (!plan.build(registry, plan_error))
      `uvm_fatal("REAL_SWITCH_TRAFFIC_PLAN", $sformatf(
        "traffic-plan build failed: %s", plan_error))
    if (plan.flows.size() != PCIE_SVT_REAL_SWITCH_FLOW_COUNT)
      `uvm_fatal("REAL_SWITCH_TRAFFIC_PLAN", $sformatf(
        "traffic-plan requires exactly 8 flows, got %0d", plan.flows.size()))

    for (int unsigned i = 0;
         i < PCIE_SVT_REAL_SWITCH_FLOW_COUNT; i++) begin
      if ((plan.flows[i] == null) ||
          (plan.flows[i].source_port >= PCIE_SVT_REAL_SWITCH_PORT_COUNT))
        `uvm_fatal("REAL_SWITCH_TRAFFIC_PLAN", $sformatf(
          "flow=%0d has null record or invalid source_port", i))
      flow_sequence[i] = pcie_svt_mem_write_read_seq::type_id::create(
        $sformatf("flow_sequence_%0d", i));
      if (flow_sequence[i] == null)
        `uvm_fatal("REAL_SWITCH_TRAFFIC_PLAN", $sformatf(
          "flow=%0d child sequence creation failed", i))
      flow_sequence[i].flow_index = i;
      flow_sequence[i].endpoint_index = plan.flows[i].endpoint_index;
      flow_sequence[i].direction = plan.flows[i].direction;
      flow_sequence[i].address = plan.flows[i].address;
      flow_sequence[i].requester_id = plan.flows[i].requester_id;
      flow_source_port[i] = plan.flows[i].source_port;
      for (int unsigned dw = 0; dw < 4; dw++)
        flow_sequence[i].expected_payload[dw] = plan.flows[i].payload[dw];
      flow_finished[i] = 1'b0;
    end

    run_traffic_with_watchdog();
    validate_idle_sequencers();
    for (int unsigned slot = 0;
         slot < PCIE_SVT_REAL_SWITCH_PORT_COUNT; slot++) begin
      driver_idle_sequence[slot] =
        svt_pcie_driver_app_service_wait_until_idle_sequence::type_id::create(
          $sformatf("driver_idle_sequence_%0d", slot));
      if (driver_idle_sequence[slot] == null)
        `uvm_fatal("REAL_SWITCH_TRAFFIC_IDLE", $sformatf(
          "Driver App idle sequence creation failed for primary slot=%0d",
          slot))
      driver_idle_finished[slot] = 1'b0;
    end
    for (int unsigned ep = 0;
         ep < PCIE_SVT_REAL_SWITCH_EP_COUNT; ep++) begin
      target_idle_sequence[ep] =
        svt_pcie_target_app_service_wait_until_idle_sequence::type_id::create(
          $sformatf("target_idle_sequence_%0d", ep));
      if (target_idle_sequence[ep] == null)
        `uvm_fatal("REAL_SWITCH_TRAFFIC_IDLE", $sformatf(
          "Target App idle sequence creation failed for Endpoint=%0d", ep))
      target_idle_finished[ep] = 1'b0;
    end
    run_idle_with_watchdog();

    `uvm_info("REAL_SWITCH_TRAFFIC_PASS",
      "downstream=4 upstream=4 dwords_per_read=4", UVM_NONE)
  endtask
endclass
