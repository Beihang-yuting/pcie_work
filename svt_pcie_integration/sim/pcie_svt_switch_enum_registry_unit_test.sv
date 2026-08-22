module pcie_svt_switch_enum_registry_unit_test;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import svt_pcie_uvm_pkg::*;
  import pcie_svt_integration_pkg::*;

  function automatic bit [31:0] bridge_bus_dw(
      svt_pcie_switch_port_info info);
    return {8'h00, info.sub_bus_num[7:0], info.sec_bus_num[7:0],
            info.pri_bus_num[7:0]};
  endfunction

  function automatic bit [31:0] bridge_pref_dw(
      svt_pcie_switch_port_info info);
    return {info.pref_mem_end_addr[31:20], 4'h1,
            info.pref_mem_start_addr[31:20], 4'h1};
  endfunction

  function automatic svt_pcie_switch_enumeration_seq_status make_status();
    svt_pcie_switch_enumeration_seq_status status;
    svt_pcie_switch_port_info info;
    svt_pcie_ep_enumeration_seq_status ep_status;
    bit [63:0] dsp_base;
    bit [63:0] bar_base;
    bit [63:0] aperture;

    status = svt_pcie_switch_enumeration_seq_status::type_id::create(
      "unit_status");
    status.root_port_sec_bus_num = 8'h01;

    info = new("unit_usp");
    info.port_type = svt_pcie_types::SW_USP;
    info.pri_bus_num = 1;
    info.sec_bus_num = 2;
    info.sub_bus_num = 6;
    info.dev_num = 0;
    info.pref_mem_start_addr = 64'h0000_0001_0000_0000;
    info.pref_mem_end_addr = 64'h0000_0001_7fff_ffff;
    status.port_info.push_back(info);

    for (int unsigned dsp = 0; dsp < 4; dsp++) begin
      dsp_base = 64'h0000_0001_0000_0000 +
                 (64'h0000_0000_0800_0000 * dsp);
      info = new($sformatf("unit_dsp%0d", dsp));
      info.port_type = svt_pcie_types::SW_DSP;
      info.pri_bus_num = 2;
      info.sec_bus_num = 3 + dsp;
      info.sub_bus_num = 3 + dsp;
      info.dev_num = dsp;
      info.pref_mem_start_addr = dsp_base;
      info.pref_mem_end_addr = dsp_base + 64'h0000_0000_07ff_ffff;
      ep_status = svt_pcie_ep_enumeration_seq_status::type_id::create(
        $sformatf("unit_ep_status%0d", dsp));
      ep_status.captured_bus_number = info.sec_bus_num[7:0];
      ep_status.captured_device_number = 5'h00;
      ep_status.is_ep_device_beneath_switch_dsp = 1'b1;
      for (int unsigned pair = 0; pair < 3; pair++) begin
        int unsigned low_bar;
        low_bar = pair * 2;
        aperture = (pair == 0) ? 64'd33554432 : 64'd65536;
        case (pair)
          0: bar_base = dsp_base;
          1: bar_base = dsp_base + 64'h0000_0000_0200_0000;
          default: bar_base = dsp_base + 64'h0000_0000_0201_0000;
        endcase
        ep_status.non_virtual_bar_present[0][low_bar] = 2'b10;
        ep_status.min_per_bar_address_range[0][low_bar] = bar_base;
        ep_status.max_per_bar_address_range[0][low_bar] =
          bar_base + aperture - 1;
      end
      info.ep_enumeration_status = ep_status;
      status.port_info.push_back(info);
    end
    return status;
  endfunction

  task automatic mutate_status(
      string case_name,
      svt_pcie_switch_enumeration_seq_status status);
    if (case_name == "usp_bus_order") begin
      status.port_info[0].sub_bus_num = 1;
    end else if (case_name == "dsp_bus_order") begin
      status.port_info[1].sec_bus_num = 7;
      status.port_info[1].sub_bus_num = 6;
      status.port_info[1].ep_enumeration_status.
        captured_bus_number = 8'h07;
    end else if (case_name == "dsp_primary_mismatch") begin
      status.port_info[4].pri_bus_num = 3;
    end else if (case_name == "dsp_bus_outside_usp") begin
      status.port_info[4].sub_bus_num = 7;
    end else if (case_name == "dsp_bus_overlap") begin
      status.port_info[1].sub_bus_num = 4;
    end else if (case_name == "dsp_window_outside_usp") begin
      status.port_info[4].pref_mem_end_addr =
        64'h0000_0001_87ff_ffff;
    end else if (case_name == "dsp_window_overlap") begin
      status.port_info[1].pref_mem_end_addr =
        status.port_info[2].pref_mem_end_addr;
    end else if (case_name == "duplicate_bdf") begin
      status.port_info[2].dev_num = status.port_info[1].dev_num;
    end else if (case_name == "endpoint_without_parent") begin
      status.port_info[1].ep_enumeration_status.
        is_ep_device_beneath_switch_dsp = 1'b0;
    end else if (case_name == "bar_32bit") begin
      status.port_info[1].ep_enumeration_status.
        non_virtual_bar_present[0][0] = 2'b01;
    end else if (case_name == "bar_overlap") begin
      status.port_info[2].ep_enumeration_status.
        min_per_bar_address_range[0][0] =
          status.port_info[1].ep_enumeration_status.
            min_per_bar_address_range[0][0];
      status.port_info[2].ep_enumeration_status.
        max_per_bar_address_range[0][0] =
          status.port_info[1].ep_enumeration_status.
            max_per_bar_address_range[0][0];
    end else if (case_name == "bar_outside_window") begin
      status.port_info[1].ep_enumeration_status.
        min_per_bar_address_range[0][0] = 64'h0000_0000_f000_0000;
      status.port_info[1].ep_enumeration_status.
        max_per_bar_address_range[0][0] = 64'h0000_0000_f1ff_ffff;
    end
  endtask

  task automatic add_readbacks(
      string case_name,
      pcie_svt_switch_enum_registry registry,
      svt_pcie_switch_enumeration_seq_status status);
    bit [31:0] bar_low;
    svt_pcie_switch_port_info info;

    info = status.port_info[0];
    registry.record_bridge_readback(
      1'b1, 0, bridge_bus_dw(info), bridge_pref_dw(info),
      info.pref_mem_start_addr[63:32], info.pref_mem_end_addr[63:32]);
    for (int unsigned dsp = 0; dsp < 4; dsp++) begin
      info = status.port_info[dsp+1];
      registry.record_bridge_readback(
        1'b0, dsp, bridge_bus_dw(info), bridge_pref_dw(info),
        info.pref_mem_start_addr[63:32], info.pref_mem_end_addr[63:32]);
      for (int unsigned pair = 0; pair < 3; pair++) begin
        int unsigned low_bar;
        bit [63:0] bar_base;
        low_bar = pair * 2;
        bar_base = info.ep_enumeration_status.
          min_per_bar_address_range[0][low_bar];
        bar_low = bar_base[31:0] | 32'h0000_000c;
        if ((case_name == "bar_non_prefetchable") &&
            (dsp == 0) && (pair == 0))
          bar_low[3] = 1'b0;
        registry.record_bar_readback(
          dsp, pair, bar_low, bar_base[63:32]);
      end
    end
  endtask

  initial begin
    string case_name;
    bit expect_failure;
    svt_pcie_switch_enumeration_seq_status status;
    pcie_svt_switch_enum_registry registry;
    pcie_svt_switch_sidecars_ready_vseq sidecar_cfg_seq;
    svt_pcie_configuration sidecar_role_cfg;

    if (!$value$plusargs("REGISTRY_CASE=%s", case_name))
      `uvm_fatal("REGISTRY_UNIT_ARGS", "missing +REGISTRY_CASE=<case>")
    expect_failure = (case_name != "valid");
    sidecar_cfg_seq = pcie_svt_switch_sidecars_ready_vseq::type_id::create(
      "unit_sidecar_cfg_seq");
    if (sidecar_cfg_seq == null)
      `uvm_fatal("SIDECAR_PRIME_POLICY", "sidecar sequence creation failed")
    if (sidecar_cfg_seq.header_type_dword() !== 32'h0001_0000)
      `uvm_fatal("SIDECAR_PRIME_POLICY", $sformatf(
        "Header Type-1 DWORD expected=00010000 got=%08h",
        sidecar_cfg_seq.header_type_dword()))
    if (sidecar_cfg_seq.pcie_capability_dword(0) !== 32'h0052_0010)
      `uvm_fatal("SIDECAR_PRIME_POLICY", $sformatf(
        "USP PCIe capability expected=00520010 got=%08h",
        sidecar_cfg_seq.pcie_capability_dword(0)))
    for (int unsigned port_index = 1; port_index < 5; port_index++) begin
      if (sidecar_cfg_seq.pcie_capability_dword(port_index) !==
          32'h0062_0010)
        `uvm_fatal("SIDECAR_PRIME_POLICY", $sformatf(
          "DSP port=%0d PCIe capability expected=00620010 got=%08h",
          port_index, sidecar_cfg_seq.pcie_capability_dword(port_index)))
    end
    if (sidecar_cfg_seq.initial_10bit_requester_enable() !== 1'b0)
      `uvm_fatal("SIDECAR_PRIME_POLICY",
        "10-bit Tag Requester Enable must remain clear before enumeration")
    $display({"SIDECAR_PRIME_POLICY_PASS header=00010000 ",
      "usp_cap=00520010 dsp_cap=00620010 requester_enable=0"});

    sidecar_role_cfg = svt_pcie_configuration::type_id::create(
      "unit_sidecar_role_cfg");
    if (sidecar_role_cfg == null)
      `uvm_fatal("SIDECAR_ROLE_POLICY",
        "direct sidecar role cfg creation failed")
    for (int unsigned port_index = 0; port_index < 5; port_index++) begin
      sidecar_role_cfg.tl_cfg.is_switch = 1'b0;
      sidecar_role_cfg.tl_cfg.is_tx_downstream = (port_index == 0);
      sidecar_role_cfg.pl_cfg.is_tx_downstream = (port_index == 0);
      sidecar_role_cfg.tl_cfg.cfg_space_mode =
        svt_pcie_tl_configuration::CFG_SPACE_BACKDOOR_UPDATE;
      pcie_svt_switch_sidecar_env::configure_monitor_role(
        sidecar_role_cfg, port_index);
      if ((sidecar_role_cfg.tl_cfg.is_switch !== 1'b1) ||
          (sidecar_role_cfg.tl_cfg.is_tx_downstream !==
            (port_index != 0)) ||
          (sidecar_role_cfg.pl_cfg.is_tx_downstream !==
            (port_index != 0)) ||
          (sidecar_role_cfg.tl_cfg.cfg_space_mode !==
            svt_pcie_tl_configuration::CFG_SPACE_ENUMERATION_UPDATE))
        `uvm_fatal("SIDECAR_ROLE_POLICY", $sformatf(
          "direct sidecar port=%0d role is incomplete", port_index))
    end
    $display("SIDECAR_DIRECT_ROLE_POLICY_PASS usp=1 dsp=4 pre_child=1");

    if (case_name == "invalid_sidecar_port")
      pcie_svt_switch_sidecar_env::configure_monitor_role(
        sidecar_role_cfg, 5);

    registry = pcie_svt_switch_enum_registry::type_id::create(
      "unit_registry");
    if (registry == null)
      `uvm_fatal("REGISTRY_UNIT_CREATE", "registry creation failed")

    if (case_name == "null_status") begin
      registry.load_from_status(null);
    end else begin
      status = make_status();
      mutate_status(case_name, status);
      registry.load_from_status(status);
      add_readbacks(case_name, registry, status);
      registry.finalize_and_validate();
    end

    if (expect_failure)
      `uvm_fatal("REGISTRY_RED", $sformatf(
        "invalid registry case '%s' was accepted", case_name))
    if ((registry.usp_count() != 1) || (registry.dsp_count() != 4) ||
        (registry.ep_count() != 4) || (registry.bar_count() != 12))
      `uvm_fatal("REGISTRY_UNIT_COUNTS", "valid registry counts changed")
    $display("REGISTRY_UNIT_PASS usp=%0d dsp=%0d ep=%0d bars=%0d",
      registry.usp_count(), registry.dsp_count(), registry.ep_count(),
      registry.bar_count());
    $finish;
  end
endmodule
