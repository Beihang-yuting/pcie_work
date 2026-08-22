module pcie_svt_real_switch_sequences_unit_test;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import svt_pcie_uvm_pkg::*;
  import pcie_svt_integration_pkg::*;

  class pcie_svt_real_switch_links_probe extends
      pcie_svt_real_switch_links_vseq;
    function new(string name = "pcie_svt_real_switch_links_probe");
      super.new(name);
    endfunction

    task wait_ready(pcie_svt_port_profile profile,
                    svt_pcie_pl_status pl,
                    svt_pcie_dl_status dl);
      wait_until_ready(profile, pl, dl);
    endtask

    function bit ready_now(pcie_svt_port_profile profile,
                           svt_pcie_pl_status pl,
                           svt_pcie_dl_status dl);
      return current_link_ready(profile, pl, dl);
    endfunction
  endclass

  class pcie_svt_switch_enumeration_command_probe extends
      pcie_svt_switch_enumeration_base_vseq;
    int unsigned read_count;
    int unsigned write_count;
    bit [15:0] captured_bdf;
    bit [11:0] captured_offset;
    bit [31:0] captured_data;
    bit [3:0] captured_first_dw_be;

    function new(
        string name = "pcie_svt_switch_enumeration_command_probe");
      super.new(name);
    endfunction

    task exercise_enable(bit [15:0] bdf);
      enable_memory_and_bus_master(bdf);
    endtask

    protected virtual task read_config(
        bit [15:0] bdf,
        bit [11:0] byte_offset,
        output bit [31:0] data);
      if (byte_offset != 12'h004)
        `uvm_fatal("REAL_SWITCH_SEQUENCES_TEST", $sformatf(
          "Command probe read unexpected offset=0x%03x", byte_offset))
      read_count++;
      case (read_count)
        1: data = 32'hf900_0501;
        2: data = 32'hf900_0507;
        default:
          `uvm_fatal("REAL_SWITCH_SEQUENCES_TEST", $sformatf(
            "Command probe unexpected read count=%0d", read_count))
      endcase
    endtask

    protected virtual task write_config(
        bit [15:0] bdf,
        bit [11:0] byte_offset,
        bit [31:0] data,
        bit [3:0] first_dw_be = 4'hf);
      write_count++;
      captured_bdf = bdf;
      captured_offset = byte_offset;
      captured_data = data;
      captured_first_dw_be = first_dw_be;
    endtask
  endclass

  function automatic void require(bit condition, string message);
    if (!condition)
      `uvm_fatal("REAL_SWITCH_SEQUENCES_TEST", message)
  endfunction

  initial begin
    pcie_svt_real_switch_links_probe probe;
    pcie_svt_switch_enumeration_command_probe command_probe;
    pcie_svt_port_profile profile;
    pcie_svt_virtual_sequencer vseqr;
    svt_pcie_pl_status pl;
    svt_pcie_dl_status dl;
    bit waiter_woke;

    probe = new();
    profile = pcie_svt_port_profile::type_id::create("profile");
    pl = svt_pcie_pl_status::type_id::create("pl");
    dl = svt_pcie_dl_status::type_id::create("dl");
    require((profile != null) && (pl != null) && (dl != null),
            "status/profile factory creation failed");

    profile.max_gen = 4;
    profile.link_width = 16;
    pl.link_up = 1'b0;
    pl.ltssm_state = svt_pcie_types::L0;
    pl.current_speed = svt_pcie_pl_status::SPEED_16_0G;
    pl.negotiated_link_width = 16;
    dl.dl_link_up = 1'b1;
    waiter_woke = 1'b0;

    fork
      begin
        probe.wait_ready(profile, pl, dl);
        waiter_woke = 1'b1;
      end
      begin
        #10ns;
        require(!waiter_woke, "waiter returned before PL link-up");
        pl.link_up = 1'b1;
        #1step;
        require(waiter_woke,
                "direct-field waiter did not react to PL status mutation");
      end
    join

    require(probe.ready_now(profile, pl, dl),
            "live readiness rejected a fully ready link");
    dl.dl_link_up = 1'b0;
    require(!probe.ready_now(profile, pl, dl),
            "live readiness stayed true after DL link drop");

    vseqr = new("vseqr", null);
    require(vseqr.try_reserve_rc_host_memory_initialization(),
            "first host-memory reservation failed");
    require(vseqr.rc_host_memory_initialization_in_progress,
            "first reservation did not record in-progress state");
    require(!vseqr.try_reserve_rc_host_memory_initialization(),
            "concurrent host-memory reservation was accepted");
    vseqr.complete_rc_host_memory_initialization(
      64'h0000_0002_0000_0000, 64'h0000_0002_0000_ffff);
    require(vseqr.rc_host_memory_initialized &&
            !vseqr.rc_host_memory_initialization_in_progress &&
            (vseqr.rc_host_memory_base == 64'h0000_0002_0000_0000) &&
            (vseqr.rc_host_memory_limit == 64'h0000_0002_0000_ffff),
            "host-memory completion state mismatch");
    require(!vseqr.try_reserve_rc_host_memory_initialization(),
            "post-completion host-memory reservation was accepted");

    command_probe = new();
    command_probe.exercise_enable(16'h0100);
    require(command_probe.read_count == 2,
            $sformatf("Command probe reads expected=2 got=%0d",
                      command_probe.read_count));
    require(command_probe.write_count == 1,
            $sformatf("Command probe writes expected=1 got=%0d",
                      command_probe.write_count));
    require(command_probe.captured_bdf == 16'h0100,
            $sformatf("Command write BDF expected=0100 got=%04h",
                      command_probe.captured_bdf));
    require(command_probe.captured_offset == 12'h004,
            $sformatf("Command write offset expected=004 got=%03h",
                      command_probe.captured_offset));
    require(command_probe.captured_data == 32'hf900_0507,
            $sformatf("Command write DWORD expected=f9000507 got=%08h",
                      command_probe.captured_data));
    require(command_probe.captured_data[2:1] == 2'b11,
            $sformatf("Command bits expected=11 got=%02b",
                      command_probe.captured_data[2:1]));
    require(command_probe.captured_first_dw_be == 4'b0011,
            $sformatf(
              "Command-register write byte enable expected=0011 got=%04b",
              command_probe.captured_first_dw_be));
    require((command_probe.captured_first_dw_be & 4'b1100) == 4'b0000,
            $sformatf("Status-byte enables expected=00 got=%02b",
                      command_probe.captured_first_dw_be[3:2]));
`ifdef PCIE_TASK9_COMMAND_BE_EXPECT_RED
    $display("REAL_SWITCH_COMMAND_BE_RED_MISSED");
`endif

    $display({"TASK3_SEQUENCE_STATE_UNIT_PASS wait_wakes=1 ",
              "sticky_drop=1 reservation_rejects=2 command_be=0011 ",
              "status_bytes_disabled=1"});
  end
endmodule
