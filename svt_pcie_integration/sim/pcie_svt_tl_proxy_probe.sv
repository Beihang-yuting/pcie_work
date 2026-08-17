`define EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH \
  pcie_svt_tl_proxy_probe_top.global_shadow0
`define SVC_RANDOM_SEED_SCOPE pcie_svt_tl_proxy_probe_top.global_random_seed
`include "svt_pcie.uvm.pkg"
`include "pcie_svt_serial_port_if.sv"
`include "pcie_svt_serial_adapter.sv"
`include "pcie_svt_peer_harness.sv"
`include "pcie_svt_passive_sidecar_tap.sv"

package pcie_svt_tl_proxy_probe_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import svt_uvm_pkg::*;
  import svt_pcie_uvm_pkg::*;

  function void tl_proxy_fatal_without_control(
      string reason, string fatal_message);
    `uvm_info("TL_PROXY_PASSIVE_SIDECAR_PROBE_BLOCKED", reason, UVM_NONE)
    `uvm_fatal("TL_PROXY_PASSIVE_SIDECAR_PROBE", fatal_message)
  endfunction

  typedef class tl_proxy_bridge;

  class tl_proxy_probe_control extends uvm_component;
    `uvm_component_utils(tl_proxy_probe_control)

    function new(string name = "tl_proxy_probe_control",
                 uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void fail(string message, string fatal_message);
      tl_proxy_fatal_without_control(message, fatal_message);
    endfunction
  endclass

  class tl_proxy_target_callback extends svt_pcie_target_app_callback;
    tl_proxy_probe_control control;
    tl_proxy_bridge bridge;
    bit capture_requests;
    int unsigned request_capture_count;
    int unsigned target_tx_count;

    `uvm_object_utils(tl_proxy_target_callback)

    function new(string name = "tl_proxy_target_callback");
      super.new(name);
    endfunction

    virtual function void post_rx_tlp_get(
        svt_pcie_target_app target_app,
        svt_pcie_tlp transaction,
        ref bit drop);
      if (control == null) begin
        tl_proxy_fatal_without_control(
          "Proxy Target callback control is null",
          "Proxy Target callback control is null");
        return;
      end
      if ((bridge == null) || (target_app == null) ||
          (transaction == null))
        control.fail("Proxy Target callback received a null handle",
          "Proxy Target RX handle missing");
      if (!capture_requests)
        control.fail("Egress Proxy Target received an unexpected request",
          "unexpected request at Egress Proxy Target");
      if (!(((transaction.tlp_type == svt_pcie_tlp::MEM_REQ) &&
             transaction.has_data()) ||
            ((transaction.tlp_type == svt_pcie_tlp::TYPE_0_CFG_REQ) &&
             !transaction.has_data())))
        control.fail("Ingress Proxy Target received an unsupported request",
          "unsupported Proxy request");
      bridge.capture_request(transaction);
      request_capture_count++;
      drop = 1'b1;
    endfunction

    virtual function void pre_tx_tlp_put(
        svt_pcie_target_app target_app, svt_pcie_tlp transaction,
        ref bit drop);
      if (control == null) begin
        tl_proxy_fatal_without_control(
          "Proxy Target TX callback control is null",
          "Proxy Target TX callback control is null");
        return;
      end
      if ((target_app == null) || (transaction == null))
        control.fail("Proxy Target TX callback received a null handle",
          "Proxy Target TX handle missing");
      target_tx_count++;
      drop = 1'b1;
    endfunction
  endclass

  class tl_proxy_raw_tlp_sequence extends uvm_sequence #(svt_pcie_tlp);
    tl_proxy_probe_control control;
    svt_pcie_tlp request;

    `uvm_object_utils(tl_proxy_raw_tlp_sequence)

    function new(string name = "tl_proxy_raw_tlp_sequence");
      super.new(name);
    endfunction

    virtual task body();
      if (control == null) begin
        tl_proxy_fatal_without_control("raw sequence control is null",
          "raw sequence control is null");
        return;
      end
      if (request == null)
        control.fail("raw reinjection request is null",
          "raw reinjection request is null");
      start_item(request);
      finish_item(request);
    endtask
  endclass

  class tl_proxy_bridge extends uvm_component;
    tl_proxy_probe_control control;
    mailbox #(svt_pcie_tlp) request_mailbox;
    mailbox #(svt_pcie_tlp) completion_mailbox;
    svt_pcie_device_agent ingress_proxy;
    svt_pcie_device_agent egress_proxy;
    int unsigned request_capture_count;
    int unsigned completion_capture_count;
    int unsigned request_forward_count;
    int unsigned completion_forward_count;

    `uvm_component_utils(tl_proxy_bridge)

    function new(string name = "tl_proxy_bridge",
                 uvm_component parent = null);
      super.new(name, parent);
      request_mailbox = new();
      completion_mailbox = new();
    endfunction

    function void capture_request(svt_pcie_tlp observed);
      svt_pcie_tlp captured;
      bit accepted;
      if (control == null) begin
        tl_proxy_fatal_without_control("bridge control is null",
          "bridge control is null");
        return;
      end
      if ((observed == null) || !$cast(captured, observed.clone()))
        control.fail("Ingress request clone failed",
          "request bridge clone failed");
      accepted = request_mailbox.try_put(captured);
      if (!accepted)
        control.fail("unbounded request mailbox rejected try_put",
          "request mailbox enqueue failed");
      request_capture_count++;
    endfunction

    function void capture_completion(svt_pcie_tlp observed);
      svt_pcie_tlp captured;
      bit accepted;
      if (control == null) begin
        tl_proxy_fatal_without_control("bridge control is null",
          "bridge control is null");
        return;
      end
      if ((observed == null) || !$cast(captured, observed.clone()))
        control.fail("Egress RX Completion clone failed",
          "Completion bridge clone failed");
      accepted = completion_mailbox.try_put(captured);
      if (!accepted)
        control.fail("unbounded Completion mailbox rejected try_put",
          "Completion mailbox enqueue failed");
      completion_capture_count++;
    endfunction

    task forward_one(bit forward_request);
      svt_pcie_tlp captured;
      svt_pcie_tlp injected;
      tl_proxy_raw_tlp_sequence raw_sequence;
      svt_pcie_tlp_sequencer sequencer;
      if (control == null) begin
        tl_proxy_fatal_without_control("bridge worker control is null",
          "bridge worker control is null");
        return;
      end
      if (forward_request)
        request_mailbox.get(captured);
      else
        completion_mailbox.get(captured);
      if ((captured == null) || !$cast(injected, captured.clone()))
        control.fail("mailbox TLP clone failed",
          "raw reinjection clone failed");
      if (forward_request) begin
        if ((egress_proxy == null) || (egress_proxy.pcie_agent == null))
          control.fail("Egress Proxy Agent is unavailable",
            "request reinjection Agent missing");
        sequencer = egress_proxy.pcie_agent.tlp_seqr;
      end else begin
        if ((ingress_proxy == null) ||
            (ingress_proxy.pcie_agent == null))
          control.fail("Ingress Proxy Agent is unavailable",
            "Completion reinjection Agent missing");
        sequencer = ingress_proxy.pcie_agent.tlp_seqr;
      end
      if (sequencer == null)
        control.fail("raw reinjection sequencer is unavailable",
          "raw tlp_seqr handle missing");
      raw_sequence = tl_proxy_raw_tlp_sequence::type_id::create(
        forward_request ? "request_raw_sequence" :
                          "completion_raw_sequence");
      if (raw_sequence == null)
        control.fail("raw reinjection sequence creation failed",
          "raw sequence handle missing");
      raw_sequence.control = control;
      raw_sequence.request = injected;
      raw_sequence.start(sequencer);
      if (forward_request)
        request_forward_count++;
      else
        completion_forward_count++;
    endtask

    virtual task run_phase(uvm_phase phase);
      fork
        forever forward_one(1'b1);
        forever forward_one(1'b0);
      join
    endtask
  endclass

  class tl_proxy_wire_checker extends uvm_component;
    typedef enum int unsigned {
      INGRESS_RX_REQUEST,
      EGRESS_TX_REQUEST,
      EGRESS_RX_COMPLETION,
      INGRESS_TX_COMPLETION
    } observation_role_e;

    tl_proxy_probe_control control;
    svt_pcie_tlp ingress_requests[$];
    svt_pcie_tlp egress_requests[$];
    svt_pcie_tlp sink_requests[$];
    svt_pcie_tlp egress_completions[$];
    svt_pcie_tlp ingress_completions[$];

    `uvm_component_utils(tl_proxy_wire_checker)

    function new(string name = "tl_proxy_wire_checker",
                 uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function svt_pcie_tlp clone_or_fail(svt_pcie_tlp observed,
                                        string boundary);
      svt_pcie_tlp captured;
      if ((observed == null) || !$cast(captured, observed.clone()))
        control.fail({boundary, ": TLP clone failed"},
          {boundary, ": observation clone failed"});
      return captured;
    endfunction

    function bit is_request(svt_pcie_tlp tlp);
      return (((tlp.tlp_type == svt_pcie_tlp::MEM_REQ) && tlp.has_data()) ||
              ((tlp.tlp_type == svt_pcie_tlp::TYPE_0_CFG_REQ) &&
               !tlp.has_data()));
    endfunction

    function void observe(observation_role_e role, svt_pcie_tlp observed);
      svt_pcie_tlp captured;
      captured = clone_or_fail(observed, "passive sidecar");
      case (role)
        INGRESS_RX_REQUEST: begin
          if (!is_request(captured))
            return;
          ingress_requests.push_back(captured);
        end
        EGRESS_TX_REQUEST: begin
          if (!is_request(captured))
            return;
          egress_requests.push_back(captured);
        end
        EGRESS_RX_COMPLETION: begin
          if (captured.tlp_type != svt_pcie_tlp::CPL)
            return;
          egress_completions.push_back(captured);
        end
        INGRESS_TX_COMPLETION: begin
          if (captured.tlp_type != svt_pcie_tlp::CPL)
            return;
          ingress_completions.push_back(captured);
        end
        default:
          control.fail("invalid passive observation role",
            "sidecar subscriber role invalid");
      endcase
    endfunction

    function void observe_sink(svt_pcie_tlp observed);
      svt_pcie_tlp captured;
      captured = clone_or_fail(observed, "sink Target");
      if (!is_request(captured))
        control.fail("sink Target received an unsupported request",
          "unsupported sink request");
      sink_requests.push_back(captured);
    endfunction

    function bit wire_equal(svt_pcie_tlp lhs, svt_pcie_tlp rhs);
      svt_pcie_types::dword_array_t lhs_dwords;
      svt_pcie_types::dword_array_t rhs_dwords;
      lhs_dwords = lhs.get_dword_array();
      rhs_dwords = rhs.get_dword_array();
      if (lhs_dwords.size() != rhs_dwords.size())
        return 1'b0;
      foreach (lhs_dwords[index])
        if (lhs_dwords[index] !== rhs_dwords[index])
          return 1'b0;
      return 1'b1;
    endfunction

    function void require_wire_equal(svt_pcie_tlp lhs,
                                     svt_pcie_tlp rhs,
                                     string path_name);
      if (!wire_equal(lhs, rhs))
        control.fail({path_name, ": encoded TLP DWORD mismatch"},
          {path_name, ": transparent forwarding failed"});
    endfunction
  endclass

  class tl_proxy_sidecar_subscriber extends uvm_subscriber #(svt_pcie_tlp);
    tl_proxy_probe_control control;
    tl_proxy_wire_checker checker;
    tl_proxy_bridge bridge;
    tl_proxy_wire_checker::observation_role_e role;

    `uvm_component_utils(tl_proxy_sidecar_subscriber)

    function new(string name = "tl_proxy_sidecar_subscriber",
                 uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void write(svt_pcie_tlp t);
      if (control == null) begin
        tl_proxy_fatal_without_control(
          "sidecar subscriber control is null",
          "sidecar subscriber control is null");
        return;
      end
      if ((checker == null) || (t == null))
        control.fail("sidecar subscriber received a null handle",
          "sidecar subscriber handle missing");
      checker.observe(role, t);
      if ((role == tl_proxy_wire_checker::EGRESS_RX_COMPLETION) &&
          (t.tlp_type == svt_pcie_tlp::CPL)) begin
        if (bridge == null)
          control.fail("Egress RX Completion bridge is null",
            "reverse bridge handle missing");
        bridge.capture_completion(t);
      end
    endfunction
  endclass

  class tl_proxy_sink_target_callback extends svt_pcie_target_app_callback;
    tl_proxy_probe_control control;
    tl_proxy_wire_checker checker;
    int unsigned write_count;
    int unsigned cfg_read_count;

    `uvm_object_utils(tl_proxy_sink_target_callback)

    function new(string name = "tl_proxy_sink_target_callback");
      super.new(name);
    endfunction

    virtual function void post_rx_tlp_get(
        svt_pcie_target_app target_app,
        svt_pcie_tlp transaction,
        ref bit drop);
      if (control == null) begin
        tl_proxy_fatal_without_control(
          "sink Target callback control is null",
          "sink Target callback control is null");
        return;
      end
      if ((target_app == null) || (transaction == null) ||
          (checker == null))
        control.fail("sink Target callback received a null handle",
          "sink Target callback handle missing");
      checker.observe_sink(transaction);
      if ((transaction.tlp_type == svt_pcie_tlp::MEM_REQ) &&
          transaction.has_data())
        write_count++;
      else if ((transaction.tlp_type == svt_pcie_tlp::TYPE_0_CFG_REQ) &&
               !transaction.has_data())
        cfg_read_count++;
      else
        control.fail("sink Target received an unsupported TLP",
          "unsupported sink Target TLP");
      drop = 1'b0;
    endfunction
  endclass

  class tl_proxy_source_driver_callback extends svt_pcie_driver_app_callback;
    tl_proxy_probe_control control;
    bit cfg_read_armed;
    int unsigned total_end_count;
    int unsigned cfg_read_end_count;
    int unsigned cfg_read_success_count;

    `uvm_object_utils(tl_proxy_source_driver_callback)

    function new(string name = "tl_proxy_source_driver_callback");
      super.new(name);
    endfunction

    virtual function void transaction_ended(
        svt_pcie_driver_app driver,
        svt_pcie_driver_app_transaction transaction);
      if (control == null) begin
        tl_proxy_fatal_without_control(
          "Source Driver callback control is null",
          "Source Driver callback control is null");
        return;
      end
      if ((driver == null) || (transaction == null))
        control.fail("Source Driver transaction_ended received a null handle",
          "Source Driver callback handle missing");
      total_end_count++;
      if (cfg_read_armed) begin
        cfg_read_end_count++;
        if ((transaction.transaction_type ==
               svt_pcie_driver_app_transaction::CFG_RD) &&
            (transaction.completion_status ==
               svt_pcie_driver_app_transaction::SUCCESSFUL)) begin
          cfg_read_success_count++;
          `uvm_info("TL_PROXY_SOURCE_DRIVER_END_TRACE", $sformatf(
            {"transaction_type=CFG_RD completion_status=SUCCESSFUL ",
             "cfg_read_success_count=%0d"}, cfg_read_success_count),
            UVM_NONE)
        end else
          control.fail($sformatf(
            {"Source armed transaction ended with transaction_type=%0d ",
             "completion_status=%0d"}, transaction.transaction_type,
            transaction.completion_status),
            "Source Configuration Read did not complete successfully");
      end
    endfunction
  endclass

  class pcie_svt_tl_proxy_probe_test extends uvm_test;
    bit sidecars_enabled;
    bit link_only;
    tl_proxy_probe_control control;
    svt_pcie_vif source_rc_vif;
    svt_pcie_vif ingress_proxy_vif;
    svt_pcie_vif egress_proxy_vif;
    svt_pcie_vif sink_ep_vif;
    virtual svt_pcie_serdes_x4_if ingress_sidecar_vif;
    virtual svt_pcie_serdes_x4_if egress_sidecar_vif;
    svt_pcie_device_configuration source_rc_cfg;
    svt_pcie_device_configuration ingress_proxy_cfg;
    svt_pcie_device_configuration egress_proxy_cfg;
    svt_pcie_device_configuration sink_ep_cfg;
    svt_pcie_device_configuration ingress_sidecar_cfg;
    svt_pcie_device_configuration egress_sidecar_cfg;
    svt_pcie_device_status source_rc_status;
    svt_pcie_device_status ingress_proxy_status;
    svt_pcie_device_status egress_proxy_status;
    svt_pcie_device_status sink_ep_status;
    svt_pcie_device_status ingress_sidecar_status;
    svt_pcie_device_status egress_sidecar_status;
    svt_pcie_device_agent source_rc;
    svt_pcie_device_agent ingress_proxy;
    svt_pcie_device_agent egress_proxy;
    svt_pcie_device_agent sink_ep;
    svt_pcie_device_agent ingress_sidecar;
    svt_pcie_device_agent egress_sidecar;
    tl_proxy_bridge bridge;
    tl_proxy_wire_checker checker;
    tl_proxy_target_callback ingress_target_callback;
    tl_proxy_target_callback egress_target_callback;
    tl_proxy_sink_target_callback sink_target_callback;
    tl_proxy_source_driver_callback source_driver_callback;
    tl_proxy_sidecar_subscriber ingress_rx_subscriber;
    tl_proxy_sidecar_subscriber ingress_tx_subscriber;
    tl_proxy_sidecar_subscriber egress_rx_subscriber;
    tl_proxy_sidecar_subscriber egress_tx_subscriber;
    uvm_analysis_port #(svt_pcie_tl_service)
      ingress_sidecar_tl_service_port;
    uvm_analysis_port #(svt_pcie_tl_service)
      egress_sidecar_tl_service_port;

    `uvm_component_utils(pcie_svt_tl_proxy_probe_test)

    function new(string name = "pcie_svt_tl_proxy_probe_test",
                 uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void blocked_fatal(string message, string fatal_message);
      if (control == null) begin
        tl_proxy_fatal_without_control("probe control is null",
          "probe control is null");
        return;
      end
      control.fail(message, fatal_message);
    endfunction

    function void fail_with_full_counter_snapshot(
        string reason, string fatal_message);
      `uvm_info("TL_PROXY_PASSIVE_SIDECAR_TIMEOUT_TRACE", $sformatf(
        {"ingress_rx=%0d egress_tx=%0d sink=%0d egress_rx_cpl=%0d ",
         "ingress_tx_cpl=%0d ingress_target=%0d egress_target=%0d ",
         "request_capture=%0d request_forward=%0d cpl_capture=%0d ",
         "cpl_forward=%0d sink_write=%0d sink_cfg=%0d driver_end=%0d ",
         "cfg_end=%0d source_success=%0d ingress_target_tx=%0d ",
         "egress_target_tx=%0d"},
        checker.ingress_requests.size(), checker.egress_requests.size(),
        checker.sink_requests.size(), checker.egress_completions.size(),
        checker.ingress_completions.size(),
        ingress_target_callback.request_capture_count,
        egress_target_callback.request_capture_count,
        bridge.request_capture_count, bridge.request_forward_count,
        bridge.completion_capture_count, bridge.completion_forward_count,
        sink_target_callback.write_count,
        sink_target_callback.cfg_read_count,
        source_driver_callback.total_end_count,
        source_driver_callback.cfg_read_end_count,
        source_driver_callback.cfg_read_success_count,
        ingress_target_callback.target_tx_count,
        egress_target_callback.target_tx_count), UVM_NONE)
      control.fail(reason, fatal_message);
    endfunction

    function void create_passive_agent(
        string agent_name,
        virtual svt_pcie_serdes_x4_if serdes_vif,
        bit device_is_root,
        output svt_pcie_device_configuration cfg,
        output svt_pcie_device_status status,
        output svt_pcie_device_agent agent);
      cfg = svt_pcie_device_configuration::type_id::create(
        {agent_name, "_cfg"}, this);
      status = svt_pcie_device_status::type_id::create(
        {agent_name, "_status"}, this);
      if ((cfg == null) || (status == null) || (serdes_vif == null))
        blocked_fatal({agent_name,
          ": passive configuration/status/SERDES VIF creation failed"},
          {agent_name, ": passive handle creation failed"});

      // The R-2020.12 manual explicitly excludes passive monitors from
      // set_initial_values_via_unified_vif().
      cfg.is_active = 1'b0;
      cfg.device_is_root = device_is_root;
      configure_common(cfg);
      cfg.pcie_cfg.enable_monitor = 1'b1;
      cfg.pcie_cfg.tl_cfg.cfg_space_mode =
        svt_pcie_tl_configuration::CFG_SPACE_BACKDOOR_UPDATE;
      cfg.pcie_cfg.serdes_x4_if = serdes_vif;

      uvm_config_db#(svt_pcie_device_configuration)::set(
        this, agent_name, "cfg", cfg);
      uvm_config_db#(svt_pcie_device_status)::set(
        this, agent_name, "shared_status", status);
      agent = svt_pcie_device_agent::type_id::create(agent_name, this);
      if (agent == null)
        blocked_fatal({agent_name, ": passive Device Agent creation failed"},
          {agent_name, ": passive Agent handle missing"});
    endfunction

    function void configure_common(svt_pcie_device_configuration cfg);
      bit [31:0] supported_speeds;
      cfg.pcie_spec_ver = svt_pcie_device_configuration::PCIE_SPEC_VER_5_0;
      cfg.pcie_cfg.pl_cfg.disable_ext_bit_clock_mode = 1'b1;
      cfg.pcie_cfg.pl_cfg.set_link_width_values(4, 32'h0000_0007, 4);
      supported_speeds = `SVT_PCIE_SPEED_2_5G |
                         `SVT_PCIE_SPEED_5_0G |
                         `SVT_PCIE_SPEED_8_0G |
                         `SVT_PCIE_SPEED_16_0G;
      cfg.pcie_cfg.pl_cfg.set_link_speed_values(
        supported_speeds, `SVT_PCIE_SPEED_16_0G,
        `SVT_PCIE_SPEED_16_0G);
    endfunction

    function void create_agent(string agent_name,
                               svt_pcie_vif vif,
                               output svt_pcie_device_configuration cfg,
                               output svt_pcie_device_status status,
                               output svt_pcie_device_agent agent);
      cfg = svt_pcie_device_configuration::type_id::create(
        {agent_name, "_cfg"}, this);
      status = svt_pcie_device_status::type_id::create(
        {agent_name, "_status"}, this);
      if ((cfg == null) || (status == null) || (vif == null))
        blocked_fatal({agent_name,
          ": configuration/status/VIF creation failed"},
          {agent_name, ": probe handle creation failed"});
      cfg.set_initial_values_via_unified_vif(1, vif);
      configure_common(cfg);
      uvm_config_db#(svt_pcie_device_configuration)::set(
        this, agent_name, "cfg", cfg);
      uvm_config_db#(svt_pcie_device_status)::set(
        this, agent_name, "shared_status", status);
      agent = svt_pcie_device_agent::type_id::create(agent_name, this);
      if (agent == null)
        blocked_fatal({agent_name, ": full Device Agent creation failed"},
          {agent_name, ": agent handle missing"});
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      control = tl_proxy_probe_control::type_id::create("control", this);
      if (control == null) begin
        tl_proxy_fatal_without_control("probe control creation failed",
          "probe control creation failed");
        return;
      end
      sidecars_enabled = !$test$plusargs("TL_PROXY_DISABLE_SIDECARS");
      link_only = $test$plusargs("TL_PROXY_LINK_ONLY");
      if (!sidecars_enabled && !link_only)
        blocked_fatal(
          "sidecars may be disabled only for the four-active performance baseline",
          "full traffic requires both passive sidecars");
      uvm_root::get().set_timeout(10ms, 1'b1);
      if (sidecars_enabled &&
          (!uvm_config_db#(virtual svt_pcie_serdes_x4_if)::get(
             null, "uvm_test_top", "ingress_sidecar_vif",
             ingress_sidecar_vif) ||
           !uvm_config_db#(virtual svt_pcie_serdes_x4_if)::get(
             null, "uvm_test_top", "egress_sidecar_vif",
             egress_sidecar_vif)))
        blocked_fatal("one or more standalone passive SERDES VIFs are missing",
          "passive sidecar VIF handle missing");
      if (!uvm_config_db#(svt_pcie_vif)::get(
            null, "uvm_test_top", "source_rc_vif", source_rc_vif) ||
          !uvm_config_db#(svt_pcie_vif)::get(
            null, "uvm_test_top", "ingress_proxy_vif", ingress_proxy_vif) ||
          !uvm_config_db#(svt_pcie_vif)::get(
            null, "uvm_test_top", "egress_proxy_vif", egress_proxy_vif) ||
          !uvm_config_db#(svt_pcie_vif)::get(
            null, "uvm_test_top", "sink_ep_vif", sink_ep_vif))
        blocked_fatal("one or more Unified VIFs are missing",
          "probe VIF handle missing");

      create_agent("source_rc", source_rc_vif,
        source_rc_cfg, source_rc_status, source_rc);
      source_rc_cfg.driver_cfg[0].enable_tag_auto_generation = 1'b0;
      source_rc_cfg.driver_cfg[0].max_num_tags = 1024;
      source_rc_cfg.driver_cfg[0].set_req_id_tag_properties(
        16'h0000, 1024, 0);
      source_rc_cfg.driver_cfg[0]
        .enable_tlp_field_user_control_vector[3] = 1'b1;
      create_agent("ingress_proxy", ingress_proxy_vif,
        ingress_proxy_cfg, ingress_proxy_status, ingress_proxy);
      ingress_proxy_cfg.pcie_cfg.tl_cfg.remote_extended_tag_field_enabled =
        1'b1;
      // An Endpoint advertises infinite Completion credits as zero.
      ingress_proxy_cfg.pcie_cfg.tl_cfg.init_cpl_hdr_tx_credits[0] = 0;
      ingress_proxy_cfg.pcie_cfg.tl_cfg.init_cpl_data_tx_credits[0] = 0;
      create_agent("egress_proxy", egress_proxy_vif,
        egress_proxy_cfg, egress_proxy_status, egress_proxy);
      create_agent("sink_ep", sink_ep_vif,
        sink_ep_cfg, sink_ep_status, sink_ep);
      sink_ep_cfg.pcie_cfg.tl_cfg.remote_extended_tag_field_enabled = 1'b1;
      sink_ep_cfg.target_cfg[0].completer_id = 16'h0000;
      if (sidecars_enabled) begin
        create_passive_agent("ingress_sidecar", ingress_sidecar_vif, 1'b0,
          ingress_sidecar_cfg, ingress_sidecar_status, ingress_sidecar);
        create_passive_agent("egress_sidecar", egress_sidecar_vif, 1'b1,
          egress_sidecar_cfg, egress_sidecar_status, egress_sidecar);
      end

      bridge = tl_proxy_bridge::type_id::create("bridge", this);
      checker = tl_proxy_wire_checker::type_id::create("checker", this);
      ingress_target_callback = tl_proxy_target_callback::type_id::create(
        "ingress_target_callback");
      egress_target_callback = tl_proxy_target_callback::type_id::create(
        "egress_target_callback");
      sink_target_callback = tl_proxy_sink_target_callback::type_id::create(
        "sink_target_callback");
      source_driver_callback =
        tl_proxy_source_driver_callback::type_id::create(
          "source_driver_callback");
      if ((bridge == null) || (checker == null) ||
          (ingress_target_callback == null) ||
          (egress_target_callback == null) ||
          (sink_target_callback == null) ||
          (source_driver_callback == null))
        blocked_fatal("one or more probe-owned objects are missing",
          "probe object creation failed");
      bridge.control = control;
      bridge.ingress_proxy = ingress_proxy;
      bridge.egress_proxy = egress_proxy;
      checker.control = control;
      ingress_target_callback.control = control;
      ingress_target_callback.bridge = bridge;
      ingress_target_callback.capture_requests = 1'b1;
      egress_target_callback.control = control;
      egress_target_callback.bridge = bridge;
      egress_target_callback.capture_requests = 1'b0;
      sink_target_callback.control = control;
      sink_target_callback.checker = checker;
      source_driver_callback.control = control;
      if (sidecars_enabled) begin
        ingress_sidecar_tl_service_port = new(
          "ingress_sidecar_tl_service_port", this);
        egress_sidecar_tl_service_port = new(
          "egress_sidecar_tl_service_port", this);
        ingress_rx_subscriber = tl_proxy_sidecar_subscriber::type_id::create(
          "ingress_rx_subscriber", this);
        ingress_tx_subscriber = tl_proxy_sidecar_subscriber::type_id::create(
          "ingress_tx_subscriber", this);
        egress_rx_subscriber = tl_proxy_sidecar_subscriber::type_id::create(
          "egress_rx_subscriber", this);
        egress_tx_subscriber = tl_proxy_sidecar_subscriber::type_id::create(
          "egress_tx_subscriber", this);
        if ((ingress_rx_subscriber == null) ||
            (ingress_tx_subscriber == null) ||
            (egress_rx_subscriber == null) ||
            (egress_tx_subscriber == null) ||
            (ingress_sidecar_tl_service_port == null) ||
            (egress_sidecar_tl_service_port == null))
          control.fail("one or more final sidecar subscribers are missing",
            "sidecar subscriber creation failed");
        ingress_rx_subscriber.control = control;
        ingress_tx_subscriber.control = control;
        egress_rx_subscriber.control = control;
        egress_tx_subscriber.control = control;
        ingress_rx_subscriber.checker = checker;
        ingress_tx_subscriber.checker = checker;
        egress_rx_subscriber.checker = checker;
        egress_tx_subscriber.checker = checker;
        ingress_rx_subscriber.role =
          tl_proxy_wire_checker::INGRESS_RX_REQUEST;
        ingress_tx_subscriber.role =
          tl_proxy_wire_checker::INGRESS_TX_COMPLETION;
        egress_rx_subscriber.role =
          tl_proxy_wire_checker::EGRESS_RX_COMPLETION;
        egress_tx_subscriber.role =
          tl_proxy_wire_checker::EGRESS_TX_REQUEST;
        egress_rx_subscriber.bridge = bridge;
      end
    endfunction

    virtual function void connect_phase(uvm_phase phase);
      bit source_pcie_ok;
      bit source_dl_seqr_ok;
      bit source_pl_seqr_ok;
      bit sink_pcie_ok;
      bit sink_dl_seqr_ok;
      bit sink_pl_seqr_ok;
      bit ingress_pcie_ok;
      bit ingress_tl_ok;
      bit ingress_tlp_seqr_ok;
      bit ingress_dl_seqr_ok;
      bit ingress_pl_seqr_ok;
      bit egress_pcie_ok;
      bit egress_tl_ok;
      bit egress_tlp_seqr_ok;
      bit egress_dl_seqr_ok;
      bit egress_pl_seqr_ok;
      super.connect_phase(phase);
      if ((source_rc_cfg.dut_model == svt_pcie_device_configuration::RTL) ||
          (ingress_proxy_cfg.dut_model ==
             svt_pcie_device_configuration::RTL) ||
          (egress_proxy_cfg.dut_model ==
             svt_pcie_device_configuration::RTL) ||
          (sink_ep_cfg.dut_model == svt_pcie_device_configuration::RTL))
        blocked_fatal("all four agents must be full Device Agents",
          "dut_model=RTL is forbidden in the TL Proxy probe");
      source_pcie_ok = (source_rc.pcie_agent != null);
      sink_pcie_ok = (sink_ep.pcie_agent != null);
      ingress_pcie_ok = (ingress_proxy.pcie_agent != null);
      egress_pcie_ok = (egress_proxy.pcie_agent != null);
      if (source_pcie_ok) begin
        source_dl_seqr_ok = (source_rc.pcie_agent.dl_seqr != null);
        source_pl_seqr_ok = (source_rc.pcie_agent.pl_seqr != null);
      end
      if (sink_pcie_ok) begin
        sink_dl_seqr_ok = (sink_ep.pcie_agent.dl_seqr != null);
        sink_pl_seqr_ok = (sink_ep.pcie_agent.pl_seqr != null);
      end
      if (ingress_pcie_ok) begin
        ingress_tl_ok = (ingress_proxy.pcie_agent.tl != null);
        ingress_tlp_seqr_ok = (ingress_proxy.pcie_agent.tlp_seqr != null);
        ingress_dl_seqr_ok = (ingress_proxy.pcie_agent.dl_seqr != null);
        ingress_pl_seqr_ok = (ingress_proxy.pcie_agent.pl_seqr != null);
      end
      if (egress_pcie_ok) begin
        egress_tl_ok = (egress_proxy.pcie_agent.tl != null);
        egress_tlp_seqr_ok = (egress_proxy.pcie_agent.tlp_seqr != null);
        egress_dl_seqr_ok = (egress_proxy.pcie_agent.dl_seqr != null);
        egress_pl_seqr_ok = (egress_proxy.pcie_agent.pl_seqr != null);
      end
      `uvm_info("TL_PROXY_HANDLE_TRACE", $sformatf(
        {"source=pcie:%0b/dl:%0b/pl:%0b ",
         "sink=pcie:%0b/dl:%0b/pl:%0b ",
         "ingress=pcie:%0b/tl:%0b/tlp:%0b/dl:%0b/pl:%0b ",
         "egress=pcie:%0b/tl:%0b/tlp:%0b/dl:%0b/pl:%0b"},
        source_pcie_ok, source_dl_seqr_ok, source_pl_seqr_ok,
        sink_pcie_ok, sink_dl_seqr_ok, sink_pl_seqr_ok,
        ingress_pcie_ok, ingress_tl_ok, ingress_tlp_seqr_ok,
        ingress_dl_seqr_ok, ingress_pl_seqr_ok,
        egress_pcie_ok, egress_tl_ok, egress_tlp_seqr_ok,
        egress_dl_seqr_ok, egress_pl_seqr_ok), UVM_NONE)
      if ((source_rc.pcie_agent == null) ||
          (source_rc.pcie_agent.dl_seqr == null) ||
          (source_rc.pcie_agent.pl_seqr == null) ||
          (sink_ep.pcie_agent == null) ||
          (sink_ep.pcie_agent.dl_seqr == null) ||
          (sink_ep.pcie_agent.pl_seqr == null) ||
          (ingress_proxy.pcie_agent == null) ||
          (ingress_proxy.pcie_agent.tl == null) ||
          (ingress_proxy.pcie_agent.tlp_seqr == null) ||
          (ingress_proxy.pcie_agent.dl_seqr == null) ||
          (ingress_proxy.pcie_agent.pl_seqr == null) ||
          (egress_proxy.pcie_agent == null) ||
          (egress_proxy.pcie_agent.tl == null) ||
          (egress_proxy.pcie_agent.tlp_seqr == null) ||
          (egress_proxy.pcie_agent.dl_seqr == null) ||
          (egress_proxy.pcie_agent.pl_seqr == null))
        blocked_fatal(
          "a public TL/raw-TLP/DL/PL Proxy handle is unavailable",
          "full Device Agent public handle check failed");
      if (!source_rc.driver_transaction_seqr.exists(0) ||
          (source_rc.driver_transaction_seqr[0] == null))
        blocked_fatal(
          "source public driver transaction sequencer is unavailable",
          "source driver sequencer missing");
      if (!ingress_proxy.target.exists(0) ||
          (ingress_proxy.target[0] == null) ||
          !egress_proxy.target.exists(0) ||
          (egress_proxy.target[0] == null) ||
          !sink_ep.target.exists(0) || (sink_ep.target[0] == null))
        blocked_fatal("one or more public target[0] handles are unavailable",
          "Target App handle check failed");
      if (sidecars_enabled) begin
        if ((ingress_sidecar == null) ||
            (ingress_sidecar.pcie_agent == null) ||
            (ingress_sidecar.pcie_agent.tl_mon == null) ||
            (egress_sidecar == null) ||
            (egress_sidecar.pcie_agent == null) ||
            (egress_sidecar.pcie_agent.tl_mon == null))
          blocked_fatal("a standalone passive TL monitor is unavailable",
            "passive sidecar tl_mon handle missing");

        if (ingress_sidecar_cfg.is_active || egress_sidecar_cfg.is_active ||
            !ingress_sidecar_cfg.pcie_cfg.enable_monitor ||
            !egress_sidecar_cfg.pcie_cfg.enable_monitor ||
            (ingress_sidecar_cfg.pcie_cfg.tl_cfg.cfg_space_mode !=
               svt_pcie_tl_configuration::CFG_SPACE_BACKDOOR_UPDATE) ||
            (egress_sidecar_cfg.pcie_cfg.tl_cfg.cfg_space_mode !=
               svt_pcie_tl_configuration::CFG_SPACE_BACKDOOR_UPDATE) ||
            (ingress_sidecar_cfg.pcie_cfg.serdes_x4_if == null) ||
            (egress_sidecar_cfg.pcie_cfg.serdes_x4_if == null) ||
            (ingress_sidecar_cfg.pcie_cfg.serdes_x4_if ==
               egress_sidecar_cfg.pcie_cfg.serdes_x4_if))
          blocked_fatal("standalone passive configuration contract failed",
            "passive sidecar configuration invalid");

        ingress_sidecar.pcie_agent.tl_mon.rx_tlp_observed_port.connect(
          ingress_rx_subscriber.analysis_export);
        ingress_sidecar.pcie_agent.tl_mon.tx_tlp_observed_port.connect(
          ingress_tx_subscriber.analysis_export);
        egress_sidecar.pcie_agent.tl_mon.rx_tlp_observed_port.connect(
          egress_rx_subscriber.analysis_export);
        egress_sidecar.pcie_agent.tl_mon.tx_tlp_observed_port.connect(
          egress_tx_subscriber.analysis_export);
        ingress_sidecar_tl_service_port.connect(
          ingress_sidecar.pcie_agent.tl_mon.tl_service_in_port);
        egress_sidecar_tl_service_port.connect(
          egress_sidecar.pcie_agent.tl_mon.tl_service_in_port);
      end
    endfunction

    task wait_for_sidecar_tl_service(
        svt_pcie_tl_service tl_service, string operation);
      bit completed;
      if ((tl_service == null) || (tl_service.end_event == null))
        control.fail({operation, ": TL service completion event is missing"},
          "passive sidecar TL service handle missing");
      completed = 1'b0;
      fork
        begin
          tl_service.end_event.wait_on();
          completed = 1'b1;
        end
        #100us;
      join_any
      disable fork;
      if (!completed)
        control.fail({operation, ": TL service timed out after 100 us"},
          "passive sidecar TL service timeout");
    endtask

    task set_sidecar_cfg_field(
        uvm_analysis_port #(svt_pcie_tl_service) service_port,
        int field_id, bit [31:0] value, string field_name);
      svt_pcie_tl_service tl_service;
      if (service_port == null)
        control.fail({field_name, ": TL service port is missing"},
          "passive sidecar TL service port missing");
      tl_service = new();
      if (tl_service == null)
        control.fail({field_name, ": SET_FIELD service creation failed"},
          "passive sidecar SET_FIELD service missing");
      tl_service.service_type =
        svt_pcie_tl_service::MON_CONFIG_SPACE_SET_FIELD;
      tl_service.mon_cfg_space_bdf_num = 16'h0000;
      tl_service.mon_cfg_space_fld_id = field_id;
      tl_service.mon_cfg_space_dword_data = value;
      service_port.write(tl_service);
      wait_for_sidecar_tl_service(tl_service, {field_name, " SET_FIELD"});
    endtask

    task write_sidecar_cfg_address(
        uvm_analysis_port #(svt_pcie_tl_service) service_port,
        bit [27:0] ecam_address, bit [31:0] value, string register_name);
      svt_pcie_tl_service tl_service;
      if (service_port == null)
        control.fail({register_name, ": TL service port is missing"},
          "passive sidecar TL service port missing");
      tl_service = new();
      if (tl_service == null)
        control.fail({register_name, ": WRITE_ADDR service creation failed"},
          "passive sidecar WRITE_ADDR service missing");
      tl_service.service_type =
        svt_pcie_tl_service::MON_CONFIG_SPACE_WRITE_ADDR;
      tl_service.mon_cfg_space_ecam_addr = ecam_address;
      tl_service.mon_cfg_space_bit_mask = 32'hffff_ffff;
      tl_service.mon_cfg_space_dword_data = value;
      service_port.write(tl_service);
      wait_for_sidecar_tl_service(tl_service,
        {register_name, " WRITE_ADDR"});
    endtask

    task initialize_sidecar_pcie_capability(
        uvm_analysis_port #(svt_pcie_tl_service) service_port,
        string sidecar_name);
      // The first SET_FIELD constructs the monitor's capability list.  Map
      // only the conventional Status/Capability Pointer and one PCI Express
      // Capability before that point; Task 1 uses only this minimal checker
      // image and needs no BAR/AER/ATS state.
      write_sidecar_cfg_address(service_port,
        `SVT_PCIE_CONFIG_SPACE_FUNC_0_CAP_STAT_ADDR, 32'h0010_0000,
        {sidecar_name, " Status/Command"});
      write_sidecar_cfg_address(service_port,
        `SVT_PCIE_CONFIG_SPACE_FUNC_0_CAP_PTR_ADDR, 32'h0000_0040,
        {sidecar_name, " Capability Pointer"});
      write_sidecar_cfg_address(service_port,
        `SVT_PCIE_CONFIG_SPACE_FUNC_0_BASE_ADDR + 28'h000_0040,
        32'h0002_0010, {sidecar_name, " PCI Express Capability"});
    endtask

    task get_sidecar_cfg_field(
        uvm_analysis_port #(svt_pcie_tl_service) service_port,
        int field_id, output bit [31:0] value, input string field_name);
      svt_pcie_tl_service tl_service;
      if (service_port == null)
        control.fail({field_name, ": TL service port is missing"},
          "passive sidecar TL service port missing");
      tl_service = new();
      if (tl_service == null)
        control.fail({field_name, ": GET_FIELD service creation failed"},
          "passive sidecar GET_FIELD service missing");
      tl_service.service_type =
        svt_pcie_tl_service::MON_CONFIG_SPACE_GET_FIELD;
      tl_service.mon_cfg_space_bdf_num = 16'h0000;
      tl_service.mon_cfg_space_fld_id = field_id;
      service_port.write(tl_service);
      wait_for_sidecar_tl_service(tl_service, {field_name, " GET_FIELD"});
      value = tl_service.mon_cfg_space_dword_data;
    endtask

    task configure_sidecar_capability_images();
      bit [31:0] egress_extended_tag_enabled;
      bit [31:0] egress_10bit_requester_supported;
      bit [31:0] egress_10bit_requester_enabled;
      bit [31:0] ingress_10bit_completer_supported;

      initialize_sidecar_pcie_capability(egress_sidecar_tl_service_port,
        "egress sidecar");
      initialize_sidecar_pcie_capability(ingress_sidecar_tl_service_port,
        "ingress sidecar");
      set_sidecar_cfg_field(egress_sidecar_tl_service_port,
        `SVT_PCIE_PCIE_DEV_CTST_REG_EXTND_TAG_FIELD_EN_FLD, 1'b1,
        "egress Extended Tag Field Enable");
      set_sidecar_cfg_field(egress_sidecar_tl_service_port,
        `SVT_PCIE_PCIE_DEV_2_REG_10_BIT_TAG_REQUESTER_SUPP_FLD, 1'b1,
        "egress 10-Bit Tag Requester Supported");
      set_sidecar_cfg_field(egress_sidecar_tl_service_port,
        `SVT_PCIE_PCIE_DEV_CTST_2_REG_10_BIT_TAG_REQUESTER_EN_FLD, 1'b1,
        "egress 10-Bit Tag Requester Enable");
      set_sidecar_cfg_field(ingress_sidecar_tl_service_port,
        `SVT_PCIE_PCIE_DEV_2_REG_10_BIT_TAG_COMPLETER_SUPP_FLD, 1'b1,
        "ingress 10-Bit Tag Completer Supported");

      get_sidecar_cfg_field(egress_sidecar_tl_service_port,
        `SVT_PCIE_PCIE_DEV_CTST_REG_EXTND_TAG_FIELD_EN_FLD,
        egress_extended_tag_enabled, "egress Extended Tag Field Enable");
      get_sidecar_cfg_field(egress_sidecar_tl_service_port,
        `SVT_PCIE_PCIE_DEV_2_REG_10_BIT_TAG_REQUESTER_SUPP_FLD,
        egress_10bit_requester_supported,
        "egress 10-Bit Tag Requester Supported");
      get_sidecar_cfg_field(egress_sidecar_tl_service_port,
        `SVT_PCIE_PCIE_DEV_CTST_2_REG_10_BIT_TAG_REQUESTER_EN_FLD,
        egress_10bit_requester_enabled,
        "egress 10-Bit Tag Requester Enable");
      get_sidecar_cfg_field(ingress_sidecar_tl_service_port,
        `SVT_PCIE_PCIE_DEV_2_REG_10_BIT_TAG_COMPLETER_SUPP_FLD,
        ingress_10bit_completer_supported,
        "ingress 10-Bit Tag Completer Supported");

      if ((egress_extended_tag_enabled != 1) ||
          (egress_10bit_requester_supported != 1) ||
          (egress_10bit_requester_enabled != 1) ||
          (ingress_10bit_completer_supported != 1))
        control.fail($sformatf(
          {"passive capability readback failed: egress_ext=%0h ",
           "egress_req_supp=%0h egress_req_en=%0h ingress_cpl_supp=%0h"},
          egress_extended_tag_enabled, egress_10bit_requester_supported,
          egress_10bit_requester_enabled,
          ingress_10bit_completer_supported),
          "passive sidecar capability image mismatch");
      `uvm_info("TL_PROXY_PASSIVE_CFG_TRACE", $sformatf(
        {"egress_ext=%0h egress_req_supp=%0h egress_req_en=%0h ",
         "ingress_cpl_supp=%0h"},
        egress_extended_tag_enabled, egress_10bit_requester_supported,
        egress_10bit_requester_enabled, ingress_10bit_completer_supported),
        UVM_NONE)
    endtask

    function void trace_callback_pool(string label,
                                      svt_pcie_target_app target_app);
      uvm_callback_iter#(svt_pcie_target_app,
                         svt_pcie_target_app_callback) iterator;
      svt_pcie_target_app_callback registered_callback;
      int unsigned callback_count;
      callback_count = 0;
      iterator = new(target_app);
      for (registered_callback = iterator.first();
           registered_callback != null;
           registered_callback = iterator.next()) begin
        callback_count++;
        `uvm_info("TL_PROXY_CALLBACK_POOL_TRACE", $sformatf(
          "label=%s target=%s callback=%s enabled=%0b",
          label, target_app.get_full_name(), registered_callback.get_name(),
          registered_callback.callback_mode()), UVM_NONE)
      end
      `uvm_info("TL_PROXY_CALLBACK_POOL_TRACE", $sformatf(
        "label=%s target=%s callback_count=%0d",
        label, target_app.get_full_name(), callback_count), UVM_NONE)
      uvm_callbacks#(svt_pcie_target_app,
                     svt_pcie_target_app_callback)::display(target_app);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      if ((ingress_proxy == null) || !ingress_proxy.target.exists(0) ||
          (ingress_proxy.target[0] == null) ||
          (egress_proxy == null) || !egress_proxy.target.exists(0) ||
          (egress_proxy.target[0] == null) ||
          (sink_ep == null) || !sink_ep.target.exists(0) ||
          (sink_ep.target[0] == null) ||
          (source_rc == null) || !source_rc.driver.exists(0) ||
          (source_rc.driver[0] == null) ||
          (ingress_target_callback == null) ||
          (egress_target_callback == null) ||
          (sink_target_callback == null) ||
          (source_driver_callback == null))
        blocked_fatal("Target/Source Driver callback registration handle is missing",
          "callback registration failed");
      uvm_callbacks#(svt_pcie_target_app,
                     svt_pcie_target_app_callback)::add(
        ingress_proxy.target[0], ingress_target_callback);
      uvm_callbacks#(svt_pcie_target_app,
                     svt_pcie_target_app_callback)::add(
        egress_proxy.target[0], egress_target_callback);
      uvm_callbacks#(svt_pcie_target_app,
                     svt_pcie_target_app_callback)::add(
        sink_ep.target[0], sink_target_callback);
      uvm_callbacks#(svt_pcie_driver_app,
                     svt_pcie_driver_app_callback)::add(
        source_rc.driver[0], source_driver_callback);
      trace_callback_pool("ingress", ingress_proxy.target[0]);
      trace_callback_pool("egress", egress_proxy.target[0]);
      trace_callback_pool("sink", sink_ep.target[0]);
    endfunction

    task enable_link(svt_pcie_device_agent agent, string port_name);
      svt_pcie_dl_service_set_link_en_sequence link_sequence;
      svt_pcie_pl_service_set_phy_en_sequence phy_sequence;
      if ((agent == null) || (agent.pcie_agent == null) ||
          (agent.pcie_agent.dl_seqr == null) ||
          (agent.pcie_agent.pl_seqr == null))
        blocked_fatal({port_name,
          ": public DL/PL sequencer handle is incomplete"},
          {port_name, ": link-control handle missing"});
      link_sequence =
        svt_pcie_dl_service_set_link_en_sequence::type_id::create(
          {port_name, "_link_enable"});
      phy_sequence =
        svt_pcie_pl_service_set_phy_en_sequence::type_id::create(
          {port_name, "_phy_enable"});
      if ((link_sequence == null) || (phy_sequence == null) ||
          !link_sequence.randomize() with { enable == 1'b1; } ||
          !phy_sequence.randomize() with { phy_enable == 1'b1; })
        blocked_fatal({port_name,
          ": link/PHY enable sequence creation or randomization failed"},
          {port_name, ": link enable failed"});
      fork
        begin
          `uvm_info("TL_PROXY_LINK_TRACE",
            {port_name, ": link sequence start"}, UVM_NONE)
          link_sequence.start(agent.pcie_agent.dl_seqr);
          `uvm_info("TL_PROXY_LINK_TRACE",
            {port_name, ": link sequence done"}, UVM_NONE)
        end
        begin
          `uvm_info("TL_PROXY_LINK_TRACE",
            {port_name, ": PHY sequence start"}, UVM_NONE)
          phy_sequence.start(agent.pcie_agent.pl_seqr);
          `uvm_info("TL_PROXY_LINK_TRACE",
            {port_name, ": PHY sequence done"}, UVM_NONE)
        end
      join
    endtask

    task wait_for_links();
      bit ready;
      ready = 1'b0;
      fork
        begin
          wait (source_rc_status.pcie_status.pl_status.link_up &&
                ingress_proxy_status.pcie_status.pl_status.link_up &&
                egress_proxy_status.pcie_status.pl_status.link_up &&
                sink_ep_status.pcie_status.pl_status.link_up &&
                source_rc_status.pcie_status.pl_status.ltssm_state ==
                  svt_pcie_types::L0 &&
                ingress_proxy_status.pcie_status.pl_status.ltssm_state ==
                  svt_pcie_types::L0 &&
                egress_proxy_status.pcie_status.pl_status.ltssm_state ==
                  svt_pcie_types::L0 &&
                sink_ep_status.pcie_status.pl_status.ltssm_state ==
                  svt_pcie_types::L0 &&
                source_rc_status.pcie_status.pl_status.current_speed ==
                  svt_pcie_pl_status::SPEED_16_0G &&
                ingress_proxy_status.pcie_status.pl_status.current_speed ==
                  svt_pcie_pl_status::SPEED_16_0G &&
                egress_proxy_status.pcie_status.pl_status.current_speed ==
                  svt_pcie_pl_status::SPEED_16_0G &&
                sink_ep_status.pcie_status.pl_status.current_speed ==
                  svt_pcie_pl_status::SPEED_16_0G &&
                source_rc_status.pcie_status.pl_status
                  .negotiated_link_width == 4 &&
                ingress_proxy_status.pcie_status.pl_status
                  .negotiated_link_width == 4 &&
                egress_proxy_status.pcie_status.pl_status
                  .negotiated_link_width == 4 &&
                sink_ep_status.pcie_status.pl_status
                  .negotiated_link_width == 4);
          ready = 1'b1;
        end
        #100us;
      join_any
      disable fork;
      if (!ready)
        fail_with_full_counter_snapshot(
          "the two real Serial links did not reach x4 Gen4 L0 in 100 us",
          "Serial link training timeout");
    endtask

    virtual task run_phase(uvm_phase phase);
      svt_pcie_driver_app_transaction_mem_wr_sequence write_seq;
      svt_pcie_driver_app_transaction_cfg_rd_sequence cfg_read_sequence;
      bit [31:0] observed_payload0;
      phase.raise_objection(this);
      if (sidecars_enabled)
        configure_sidecar_capability_images();
      fork
        enable_link(source_rc, "source_rc");
        enable_link(ingress_proxy, "ingress_proxy");
        enable_link(egress_proxy, "egress_proxy");
        enable_link(sink_ep, "sink_ep");
      join
      wait_for_links();
      if (sidecars_enabled)
        `uvm_info("TL_PROXY_PASSIVE_SIDECAR_STAGE_A_PASS",
          {"four active Agents plus two independent passive Agents; ",
           "two Gen4 x4 links at L0"}, UVM_NONE)
      if (link_only) begin
        #10us;
        if (sidecars_enabled)
          `uvm_info("TL_PROXY_PASSIVE_SIDECAR_LINK_ONLY_PASS",
            "two passive sidecars remained link-neutral for 10 us after L0",
            UVM_NONE)
        else
          `uvm_info("TL_PROXY_FOUR_ACTIVE_BASELINE_PASS",
            "four-active baseline remained stable for 10 us after L0",
            UVM_NONE)
        phase.drop_objection(this);
        return;
      end

      write_seq =
        svt_pcie_driver_app_transaction_mem_wr_sequence::type_id::create(
          "write_seq");
      if (write_seq == null)
        control.fail("directed Memory Write sequence creation failed",
          "Memory Write stimulus handle missing");
      write_seq.cfg = source_rc_cfg;
      if (!write_seq.randomize() with {
            address == 64'h0000_0000_8000_1040;
            address_translation == 2'b00;
            traffic_class == 3'b000;
            first_dw_be == 4'hf;
            last_dw_be == 4'h0;
            length == 10'd1;
            requester_id == 16'h0000;
            payload.size() == 1;
            payload[0] == 32'h4433_2211;
            ep == 1'b0;
            block == 1'b0;
            pkt_delay_ns == 0;
          })
        control.fail("directed Memory Write sequence randomization failed",
          "Memory Write stimulus creation failed");
      write_seq.start(source_rc.driver_transaction_seqr[0]);

      begin
        bit mwr_ready;
        mwr_ready = 1'b0;
        fork
          begin
            wait ((checker.ingress_requests.size() >= 1) &&
                  (checker.egress_requests.size() >= 1) &&
                  (checker.sink_requests.size() >= 1) &&
                  (ingress_target_callback.request_capture_count >= 1) &&
                  (bridge.request_capture_count >= 1) &&
                  (bridge.request_forward_count >= 1) &&
                  (sink_target_callback.write_count >= 1));
            mwr_ready = 1'b1;
          end
          #100us;
        join_any
        disable fork;
        if (!mwr_ready)
          fail_with_full_counter_snapshot(
            "Memory Write path did not complete within 100 us",
            "Memory Write stage exceeded 100 us");
      end

      // Keep callbacks and bridge workers active before the exact recheck.
      #1us;

      if ((checker.ingress_requests.size() != 1) ||
          (checker.egress_requests.size() != 1) ||
          (checker.sink_requests.size() != 1) ||
          (checker.egress_completions.size() != 0) ||
          (checker.ingress_completions.size() != 0) ||
          (ingress_target_callback.request_capture_count != 1) ||
          (egress_target_callback.request_capture_count != 0) ||
          (bridge.request_capture_count != 1) ||
          (bridge.request_forward_count != 1) ||
          (bridge.completion_capture_count != 0) ||
          (bridge.completion_forward_count != 0) ||
          (sink_target_callback.write_count != 1) ||
          (sink_target_callback.cfg_read_count != 0) ||
          (ingress_target_callback.target_tx_count != 0) ||
          (egress_target_callback.target_tx_count != 0))
        control.fail("Memory Write exact-count gate failed",
          "Memory Write was not forwarded exactly once");

      checker.require_wire_equal(checker.ingress_requests[0],
        checker.egress_requests[0], "Ingress RX -> Egress TX Memory Write");
      checker.require_wire_equal(checker.egress_requests[0],
        checker.sink_requests[0], "Egress TX -> sink Target Memory Write");

      observed_payload0 =
        (checker.ingress_requests[0].payload.size() == 0) ? 'x :
          checker.ingress_requests[0].payload[0];
      `uvm_info("TL_PROXY_MWR_FIELDS_TRACE", $sformatf(
        {"address=0x%016h first_be=0x%0h last_be=0x%0h at=%0d ",
         "tag=0x%0h requester=0x%04h tc=%0d length=%0d ",
         "payload_size=%0d payload0=0x%08h ep=%0b"},
        checker.ingress_requests[0].address,
        checker.ingress_requests[0].first_dw_be,
        checker.ingress_requests[0].last_dw_be,
        checker.ingress_requests[0].at,
        checker.ingress_requests[0].tag,
        checker.ingress_requests[0].requester_id,
        checker.ingress_requests[0].traffic_class,
        checker.ingress_requests[0].length,
        checker.ingress_requests[0].payload.size(), observed_payload0,
        checker.ingress_requests[0].ep), UVM_NONE)

      if ((checker.ingress_requests[0].address !=
             64'h0000_0000_8000_1040) ||
          (checker.ingress_requests[0].first_dw_be != 4'hf) ||
          (checker.ingress_requests[0].last_dw_be != 4'h0) ||
          (checker.ingress_requests[0].at !=
             svt_pcie_tlp::UNTRANSLATED) ||
          (checker.ingress_requests[0].tag != 10'h000) ||
          (checker.ingress_requests[0].requester_id != 16'h0000) ||
          (checker.ingress_requests[0].traffic_class != 3'b000) ||
          (checker.ingress_requests[0].length != 10'd1) ||
          (checker.ingress_requests[0].payload.size() != 1) ||
          (checker.ingress_requests[0].payload[0] != 32'h4433_2211) ||
          checker.ingress_requests[0].ep)
        control.fail("directed Memory Write fields do not match the contract",
          "Memory Write stimulus or forwarding changed");

      `uvm_info("TL_PROXY_MWR_GATE_TRACE", $sformatf(
        {"ingress_rx=%0d egress_tx=%0d sink=%0d egress_cpl=%0d ",
         "ingress_cpl=%0d target_capture=%0d/%0d bridge=%0d/%0d/%0d/%0d ",
         "sink_write_cfg=%0d/%0d target_tx=%0d/%0d dword_equal=1/1"},
        checker.ingress_requests.size(), checker.egress_requests.size(),
        checker.sink_requests.size(), checker.egress_completions.size(),
        checker.ingress_completions.size(),
        ingress_target_callback.request_capture_count,
        egress_target_callback.request_capture_count,
        bridge.request_capture_count, bridge.request_forward_count,
        bridge.completion_capture_count, bridge.completion_forward_count,
        sink_target_callback.write_count, sink_target_callback.cfg_read_count,
        ingress_target_callback.target_tx_count,
        egress_target_callback.target_tx_count), UVM_NONE)
      `uvm_info("TL_PROXY_PASSIVE_SIDECAR_MWR_STAGE_PASS",
        "one transparent Memory Write; no Completion; no Proxy Target response",
        UVM_NONE)

      if ($test$plusargs("TL_PROXY_STOP_AFTER_MWR")) begin
        phase.drop_objection(this);
        return;
      end

      begin
        bit source_mwr_ended;
        source_mwr_ended = 1'b0;
        fork
          begin
            wait (source_driver_callback.total_end_count >= 1);
            source_mwr_ended = 1'b1;
          end
          #100us;
        join_any
        disable fork;
        if (!source_mwr_ended)
          fail_with_full_counter_snapshot(
            "Source Memory Write transaction did not end within 100 us",
            "Source Memory Write Driver transaction-end timeout");
        if ((source_driver_callback.total_end_count != 1) ||
            (source_driver_callback.cfg_read_end_count != 0))
          control.fail("Source Memory Write Driver transaction-end gate failed",
            "Source Driver did not end the Memory Write exactly once");
      end

      cfg_read_sequence =
        svt_pcie_driver_app_transaction_cfg_rd_sequence::type_id::create(
          "cfg_read_sequence");
      if (cfg_read_sequence == null)
        control.fail("Type-0 Configuration Read sequence creation failed",
          "Configuration Read stimulus handle missing");
      cfg_read_sequence.cfg = source_rc_cfg;
      if (!cfg_read_sequence.randomize() with {
            bdf == 16'h0000;
            register_number == 10'h000;
            requester_id == 16'h0000;
            first_dw_be == 4'hf;
            block == 1'b0;
            pkt_delay_ns == 0;
          })
        control.fail("Type-0 Configuration Read randomization failed",
          "Configuration Read setup failed");
      source_driver_callback.cfg_read_armed = 1'b1;
      cfg_read_sequence.start(source_rc.driver_transaction_seqr[0]);

      begin
        bit cfg_path_ready;
        cfg_path_ready = 1'b0;
        fork
          begin
            wait ((checker.ingress_requests.size() >= 2) &&
                  (checker.egress_requests.size() >= 2) &&
                  (checker.sink_requests.size() >= 2) &&
                  (checker.egress_completions.size() >= 1) &&
                  (checker.ingress_completions.size() >= 1) &&
                  (bridge.request_forward_count >= 2) &&
                  (bridge.completion_forward_count >= 1) &&
                  (source_driver_callback.cfg_read_end_count >= 1) &&
                  (source_driver_callback.cfg_read_success_count >= 1));
            cfg_path_ready = 1'b1;
          end
          #100us;
        join_any
        disable fork;
        if (!cfg_path_ready)
          fail_with_full_counter_snapshot(
            "Configuration path did not complete within 100 us",
            "Configuration request/Completion timeout");
      end

      // Keep every callback and bridge worker active before the final gate.
      #1us;

      if ((checker.ingress_requests.size() != 2) ||
          (checker.egress_requests.size() != 2) ||
          (checker.sink_requests.size() != 2) ||
          (checker.egress_completions.size() != 1) ||
          (checker.ingress_completions.size() != 1) ||
          (ingress_target_callback.request_capture_count != 2) ||
          (egress_target_callback.request_capture_count != 0) ||
          (bridge.request_capture_count != 2) ||
          (bridge.request_forward_count != 2) ||
          (bridge.completion_capture_count != 1) ||
          (bridge.completion_forward_count != 1) ||
          (sink_target_callback.write_count != 1) ||
          (sink_target_callback.cfg_read_count != 1) ||
          (source_driver_callback.total_end_count != 2) ||
          (source_driver_callback.cfg_read_end_count != 1) ||
          (source_driver_callback.cfg_read_success_count != 1) ||
          (ingress_target_callback.target_tx_count != 0) ||
          (egress_target_callback.target_tx_count != 0))
        control.fail("Configuration path exact-count gate failed",
          "Configuration request/Completion was not forwarded exactly once");

      checker.require_wire_equal(checker.ingress_requests[1],
        checker.egress_requests[1], "Ingress RX -> Egress TX CfgRd0");
      checker.require_wire_equal(checker.egress_requests[1],
        checker.sink_requests[1], "Egress TX -> sink Target CfgRd0");
      checker.require_wire_equal(checker.egress_completions[0],
        checker.ingress_completions[0],
        "Egress RX -> Ingress TX Completion");

      if ((checker.ingress_requests[1].tlp_type !=
             svt_pcie_tlp::TYPE_0_CFG_REQ) ||
          checker.ingress_requests[1].has_data() ||
          (checker.ingress_requests[1].bus_number != 8'h00) ||
          (checker.ingress_requests[1].device_number != 5'h00) ||
          (checker.ingress_requests[1].function_number != 3'h0) ||
          (checker.ingress_requests[1].register_number != 10'h000) ||
          (checker.ingress_requests[1].requester_id != 16'h0000) ||
          (checker.ingress_requests[1].first_dw_be != 4'hf) ||
          (checker.ingress_requests[1].traffic_class != 3'b000) ||
          (checker.ingress_requests[1].tag[9:8] == 2'b00))
        control.fail("Type-0 Configuration Read fields or 10-bit Tag changed",
          "Configuration Read contract failed");

      if ((checker.egress_completions[0].completion_status !=
             svt_pcie_tlp::SUCCESSFUL) ||
          !checker.egress_completions[0].has_data() ||
          (checker.egress_completions[0].payload.size() != 1) ||
          (checker.egress_completions[0].requester_id !=
             checker.ingress_requests[1].requester_id) ||
          (checker.egress_completions[0].tag !=
             checker.ingress_requests[1].tag) ||
          (checker.ingress_completions[0].tag !=
             checker.ingress_requests[1].tag) ||
          (checker.egress_completions[0].completer_id !=
             checker.ingress_completions[0].completer_id) ||
          (checker.egress_completions[0].requester_id !=
             checker.ingress_completions[0].requester_id) ||
          (checker.egress_completions[0].byte_count !=
             checker.ingress_completions[0].byte_count) ||
          (checker.egress_completions[0].lower_address !=
             checker.ingress_completions[0].lower_address) ||
          (checker.egress_completions[0].length !=
             checker.ingress_completions[0].length) ||
          (checker.egress_completions[0].get_attr_value() !=
             checker.ingress_completions[0].get_attr_value()))
        control.fail("Configuration Completion identity or payload changed",
          "Requester ID/full Tag/Completion contract failed");

      `uvm_info("TL_PROXY_CFG_FIELDS_TRACE", $sformatf(
        {"request_tag=0x%03h egress_cpl_tag=0x%03h ",
         "ingress_cpl_tag=0x%03h requester=0x%04h"},
        checker.ingress_requests[1].tag,
        checker.egress_completions[0].tag,
        checker.ingress_completions[0].tag,
        checker.ingress_requests[1].requester_id), UVM_NONE)
      `uvm_info("TL_PROXY_CFG_GATE_TRACE", $sformatf(
        {"requests=%0d/%0d/%0d completions=%0d/%0d target=%0d/%0d ",
         "bridge=%0d/%0d/%0d/%0d sink=%0d/%0d driver=%0d/%0d/%0d ",
         "target_tx=%0d/%0d dword_equal=1/1/1"},
        checker.ingress_requests.size(), checker.egress_requests.size(),
        checker.sink_requests.size(), checker.egress_completions.size(),
        checker.ingress_completions.size(),
        ingress_target_callback.request_capture_count,
        egress_target_callback.request_capture_count,
        bridge.request_capture_count, bridge.request_forward_count,
        bridge.completion_capture_count, bridge.completion_forward_count,
        sink_target_callback.write_count, sink_target_callback.cfg_read_count,
        source_driver_callback.total_end_count,
        source_driver_callback.cfg_read_end_count,
        source_driver_callback.cfg_read_success_count,
        ingress_target_callback.target_tx_count,
        egress_target_callback.target_tx_count), UVM_NONE)
      `uvm_info("TL_PROXY_PASSIVE_SIDECAR_CFG_STAGE_PASS",
        {"one transparent CfgRd0 and one raw Completion; ",
         "Requester ID/full Tag preserved"}, UVM_NONE)
      `uvm_info("TL_PROXY_PASSIVE_SIDECAR_PROBE_PASS", $sformatf(
        {"two Gen4 x4 Serial links; active=4 passive=2; requests=%0d; ",
         "completions=%0d; source_cfg_success=%0d; proxy_target_tx=%0d"},
        bridge.request_forward_count, bridge.completion_forward_count,
        source_driver_callback.cfg_read_success_count,
        ingress_target_callback.target_tx_count +
          egress_target_callback.target_tx_count), UVM_NONE)
      phase.drop_objection(this);
      return;
    endtask
  endclass
endpackage

module pcie_svt_tl_proxy_probe_top;
  import uvm_pkg::*;
  import pcie_svt_tl_proxy_probe_pkg::*;
  `include "uvm_macros.svh"
  `include "import_pcie_svt_uvm_pkgs.svi"
  `include `SVC_SOURCE_MAP_SUITE_UTIL_V(pcie_svc,PCIE,latest,svc_util_parms)
  `include `SVC_SOURCE_MAP_SUITE_MODEL_MODULE(pcie_svc,Include,latest,pciesvc_parms)

  int unsigned global_random_seed = 0;
  pciesvc_global_shadow #(.DISPLAY_NAME("global_shadow0.")) global_shadow0();
  tri1 [1:0] clkreq_n;
  tri1 wake_n;
  logic [3:0] reset;

  svt_pcie_if source_rc_if(clkreq_n[0], wake_n);
  svt_pcie_if ingress_proxy_if(clkreq_n[0], wake_n);
  svt_pcie_if egress_proxy_if(clkreq_n[1], wake_n);
  svt_pcie_if sink_ep_if(clkreq_n[1], wake_n);
  svt_pcie_single_port_device_agent_hdl source_rc_spd(source_rc_if);
  svt_pcie_single_port_device_agent_hdl ingress_proxy_spd(ingress_proxy_if);
  svt_pcie_single_port_device_agent_hdl egress_proxy_spd(egress_proxy_if);
  svt_pcie_single_port_device_agent_hdl sink_ep_spd(sink_ep_if);
  pcie_svt_serial_port_if #(4) source_rc_serial();
  pcie_svt_serial_port_if #(4) ingress_proxy_serial();
  pcie_svt_serial_port_if #(4) egress_proxy_serial();
  pcie_svt_serial_port_if #(4) sink_ep_serial();
  svt_pcie_serdes_x4_if ingress_sidecar_serdes(reset[1]);
  svt_pcie_serdes_x4_if egress_sidecar_serdes(reset[2]);

  `PCIE_SVT_TAP_PASSIVE_SERDES_X4(
    ingress_sidecar_serdes, ingress_proxy_serial)
  `PCIE_SVT_TAP_PASSIVE_SERDES_X4(
    egress_sidecar_serdes, egress_proxy_serial)

  assign ingress_sidecar_serdes.clkreq_n = clkreq_n[0];
  assign ingress_sidecar_serdes.wake_n = wake_n;
  assign egress_sidecar_serdes.clkreq_n = clkreq_n[1];
  assign egress_sidecar_serdes.wake_n = wake_n;

  defparam source_rc_spd.SVT_PCIE_UI_PCIE_SPEC_VER =
    `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
  defparam source_rc_spd.SVT_PCIE_UI_DISPLAY_NAME = "source_rc_spd.";
  defparam source_rc_spd.SVT_PCIE_UI_PHY_INTERFACE_TYPE =
    `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
  defparam source_rc_spd.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE = 1'b1;
  defparam source_rc_spd.SVT_PCIE_UI_ENABLE_CFG_BLOCK = 1'b1;
  defparam source_rc_spd.SVT_PCIE_UI_CONNECT_ACTIVE_VIP = 1'b1;
  defparam source_rc_spd.SVT_PCIE_UI_NUM_PHYSICAL_LANES = 4;
  defparam source_rc_spd.SVT_PCIE_UI_DEVICE_IS_ROOT = 1;
  defparam source_rc_spd.SVT_PCIE_UI_HIERARCHY_NUMBER = 0;

  defparam ingress_proxy_spd.SVT_PCIE_UI_PCIE_SPEC_VER =
    `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
  defparam ingress_proxy_spd.SVT_PCIE_UI_DISPLAY_NAME =
    "ingress_proxy_spd.";
  defparam ingress_proxy_spd.SVT_PCIE_UI_PHY_INTERFACE_TYPE =
    `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
  defparam ingress_proxy_spd.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE = 1'b1;
  defparam ingress_proxy_spd.SVT_PCIE_UI_ENABLE_CFG_BLOCK = 1'b1;
  defparam ingress_proxy_spd.SVT_PCIE_UI_CONNECT_ACTIVE_VIP = 1'b1;
  defparam ingress_proxy_spd.SVT_PCIE_UI_NUM_PHYSICAL_LANES = 4;
  defparam ingress_proxy_spd.SVT_PCIE_UI_DEVICE_IS_ROOT = 0;
  defparam ingress_proxy_spd.SVT_PCIE_UI_HIERARCHY_NUMBER = 0;

  defparam egress_proxy_spd.SVT_PCIE_UI_PCIE_SPEC_VER =
    `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
  defparam egress_proxy_spd.SVT_PCIE_UI_DISPLAY_NAME =
    "egress_proxy_spd.";
  defparam egress_proxy_spd.SVT_PCIE_UI_PHY_INTERFACE_TYPE =
    `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
  defparam egress_proxy_spd.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE = 1'b1;
  defparam egress_proxy_spd.SVT_PCIE_UI_ENABLE_CFG_BLOCK = 1'b1;
  defparam egress_proxy_spd.SVT_PCIE_UI_CONNECT_ACTIVE_VIP = 1'b1;
  defparam egress_proxy_spd.SVT_PCIE_UI_NUM_PHYSICAL_LANES = 4;
  defparam egress_proxy_spd.SVT_PCIE_UI_DEVICE_IS_ROOT = 1;
  defparam egress_proxy_spd.SVT_PCIE_UI_HIERARCHY_NUMBER = 1;

  defparam sink_ep_spd.SVT_PCIE_UI_PCIE_SPEC_VER =
    `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
  defparam sink_ep_spd.SVT_PCIE_UI_DISPLAY_NAME = "sink_ep_spd.";
  defparam sink_ep_spd.SVT_PCIE_UI_PHY_INTERFACE_TYPE =
    `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
  defparam sink_ep_spd.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE = 1'b1;
  defparam sink_ep_spd.SVT_PCIE_UI_ENABLE_CFG_BLOCK = 1'b1;
  defparam sink_ep_spd.SVT_PCIE_UI_CONNECT_ACTIVE_VIP = 1'b1;
  defparam sink_ep_spd.SVT_PCIE_UI_NUM_PHYSICAL_LANES = 4;
  defparam sink_ep_spd.SVT_PCIE_UI_DEVICE_IS_ROOT = 0;
  defparam sink_ep_spd.SVT_PCIE_UI_HIERARCHY_NUMBER = 1;

  `PCIE_SVT_MAP_SERDES_X4(source_rc_spd, source_rc_serial)
  `PCIE_SVT_MAP_SERDES_X4(ingress_proxy_spd, ingress_proxy_serial)
  `PCIE_SVT_MAP_SERDES_X4(egress_proxy_spd, egress_proxy_serial)
  `PCIE_SVT_MAP_SERDES_X4(sink_ep_spd, sink_ep_serial)
  `PCIE_SVT_CONNECT_SERIAL_PEERS(source_rc_serial, ingress_proxy_serial)
  `PCIE_SVT_CONNECT_SERIAL_PEERS(egress_proxy_serial, sink_ep_serial)

  assign source_rc_spd.vip_port_if.ser_if.reset = reset[0];
  assign ingress_proxy_spd.vip_port_if.ser_if.reset = reset[1];
  assign egress_proxy_spd.vip_port_if.ser_if.reset = reset[2];
  assign sink_ep_spd.vip_port_if.ser_if.reset = reset[3];

  initial begin
    reset = '1;
    fork
      begin
        #205ns;
        reset = '0;
      end
    join_none
    source_rc_spd.update_if_variables(4'h0, 0,
      "uvm_test_top", "uvm_test_top");
    ingress_proxy_spd.update_if_variables(4'h1, 1,
      "uvm_test_top", "uvm_test_top");
    egress_proxy_spd.update_if_variables(4'h0, 2,
      "uvm_test_top", "uvm_test_top");
    sink_ep_spd.update_if_variables(4'h1, 3,
      "uvm_test_top", "uvm_test_top");
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "source_rc_vif", source_rc_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "ingress_proxy_vif", ingress_proxy_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "egress_proxy_vif", egress_proxy_if);
    uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
      "sink_ep_vif", sink_ep_if);
    uvm_config_db#(virtual svt_pcie_serdes_x4_if)::set(
      null, "uvm_test_top", "ingress_sidecar_vif",
      ingress_sidecar_serdes);
    uvm_config_db#(virtual svt_pcie_serdes_x4_if)::set(
      null, "uvm_test_top", "egress_sidecar_vif",
      egress_sidecar_serdes);
    repeat (100) #0;
    run_test("pcie_svt_tl_proxy_probe_test");
  end
endmodule
