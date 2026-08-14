package pcie_svt_watchdog_directed_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import pcie_svt_integration_pkg::*;

  class pcie_svt_watchdog_timeout_catcher extends uvm_report_catcher;
    int unsigned matched_count;
    string last_message;

    `uvm_object_utils(pcie_svt_watchdog_timeout_catcher)

    function new(string name = "pcie_svt_watchdog_timeout_catcher");
      super.new(name);
    endfunction

    function bit message_contains(string message, string substring);
      if ((substring.len() == 0) || (message.len() < substring.len()))
        return 0;
      for (int i = 0; i <= message.len() - substring.len(); i++)
        if (message.substr(i, i + substring.len() - 1) == substring)
          return 1;
      return 0;
    endfunction

    virtual function action_e catch();
      if (get_id() == "CFG_INIT_TIMEOUT") begin
        matched_count++;
        last_message = get_message();
        return CAUGHT;
      end
      return THROW;
    endfunction
  endclass

  class pcie_svt_watchdog_delayed_cfg_seq extends
      pcie_svt_cfg_space_init_seq;
    static int unsigned post_deadline_steps;

    `uvm_object_utils(pcie_svt_watchdog_delayed_cfg_seq)

    function new(string name = "pcie_svt_watchdog_delayed_cfg_seq");
      super.new(name);
    endfunction

    // Bypass uvm_sequence_base::start()'s post-body #0 delays so this test
    // controls the exact time slot in which run_one_port() sees completion.
    // The production arbitration, factory creation, and child.start() call
    // remain unchanged; only this deterministic test double's wrapper differs.
    virtual task start(uvm_sequencer_base sequencer,
                       uvm_sequence_base parent_sequence = null,
                       int this_priority = -1,
                       bit call_pre_post = 1);
      body();
    endtask

    virtual task body();
      case (post_deadline_steps)
        0: #1ms;
        1: #(1ms + 1fs);
        2: #(1ms + 2fs);
        default: `uvm_fatal("WATCHDOG_TEST", "unsupported child delay")
      endcase
    endtask
  endclass

  class pcie_svt_watchdog_one_port_vseq extends
      pcie_svt_all_cfg_spaces_init_vseq;
    `uvm_object_utils(pcie_svt_watchdog_one_port_vseq)

    function new(string name = "pcie_svt_watchdog_one_port_vseq");
      super.new(name);
    endfunction

    virtual task body();
      if (p_sequencer == null)
        `uvm_fatal("WATCHDOG_TEST", "null directed virtual sequencer")
      run_one_port(0);
    endtask
  endclass

  class pcie_svt_watchdog_directed_test extends uvm_test;
    pcie_svt_virtual_sequencer vseqr;

    `uvm_component_utils(pcie_svt_watchdog_directed_test)

    function new(string name = "pcie_svt_watchdog_directed_test",
                 uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      pcie_svt_cfg_space_init_seq::type_id::set_type_override(
        pcie_svt_watchdog_delayed_cfg_seq::get_type());
      super.build_phase(phase);
      vseqr = pcie_svt_virtual_sequencer::type_id::create("vseqr", this);
    endfunction

    virtual task run_phase(uvm_phase phase);
      pcie_svt_watchdog_timeout_catcher catcher;
      pcie_svt_watchdog_one_port_vseq vseq;
      string mode_values[$];
      string mode;
      string expected_diagnostic;
      int unsigned expected_timeouts;
      bit passed;

      phase.raise_objection(this);
      void'(uvm_cmdline_processor::get_inst().get_arg_values(
        "+WATCHDOG_MODE=", mode_values));
      if (mode_values.size() != 1)
        `uvm_fatal("WATCHDOG_TEST",
          "provide exactly one +WATCHDOG_MODE=exact|plus1fs|plus2fs")
      mode = mode_values[0];
      case (mode)
        "exact": begin
          pcie_svt_watchdog_delayed_cfg_seq::post_deadline_steps = 0;
          expected_timeouts = 0;
          expected_diagnostic = "";
        end
        "plus1fs": begin
          pcie_svt_watchdog_delayed_cfg_seq::post_deadline_steps = 1;
          expected_timeouts = 1;
          expected_diagnostic = "completion=";
        end
        "plus2fs": begin
          pcie_svt_watchdog_delayed_cfg_seq::post_deadline_steps = 2;
          expected_timeouts = 1;
          expected_diagnostic = "current=";
        end
        default:
          `uvm_fatal("WATCHDOG_TEST", $sformatf(
            "unsupported WATCHDOG_MODE '%s'", mode))
      endcase

      catcher = pcie_svt_watchdog_timeout_catcher::type_id::create(
        "timeout_catcher");
      vseq = pcie_svt_watchdog_one_port_vseq::type_id::create("watchdog_vseq");
      if ((catcher == null) || (vseq == null) || (vseqr == null))
        `uvm_fatal("WATCHDOG_TEST", "directed test object creation failed")

      `uvm_info("WATCHDOG_DIRECTED_START", $sformatf(
        "mode=%s post_deadline_steps=%0d", mode,
        pcie_svt_watchdog_delayed_cfg_seq::post_deadline_steps), UVM_NONE)
      uvm_report_cb::add(null, catcher);
      vseq.start(vseqr);
      uvm_report_cb::delete(null, catcher);

      passed = catcher.matched_count == expected_timeouts;
      if ((expected_diagnostic.len() != 0) &&
          !catcher.message_contains(catcher.last_message,
                                    expected_diagnostic))
        passed = 0;
      if (!passed) begin
        `uvm_info("WATCHDOG_DIRECTED_FAIL", $sformatf(
          "mode=%s expected_timeouts=%0d observed_timeouts=%0d expected_diagnostic=%s message='%s'",
          mode, expected_timeouts, catcher.matched_count,
          expected_diagnostic, catcher.last_message), UVM_NONE)
        `uvm_fatal("WATCHDOG_TEST", "watchdog directed expectation failed")
      end

      `uvm_info("WATCHDOG_DIRECTED_PASS", $sformatf(
        "mode=%s timeout_count=%0d diagnostic=%s message='%s'",
        mode, catcher.matched_count,
        (expected_diagnostic.len() == 0) ? "none" : expected_diagnostic,
        catcher.last_message), UVM_NONE)
      phase.drop_objection(this);
    endtask
  endclass
endpackage

module pcie_svt_watchdog_directed_top;
  import uvm_pkg::*;
  import pcie_svt_watchdog_directed_test_pkg::*;

  pcie_svt_reset_if reset_vif();

  initial begin
    uvm_config_db#(virtual pcie_svt_reset_if)::set(
      null, "uvm_test_top", "reset_vif", reset_vif);
    run_test();
  end
endmodule
