import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_svt_topology_pkg::*;
`include "uvm_macros.svh"

class pcie_svt_topology_model_unit_test extends uvm_test;
  `uvm_component_utils(pcie_svt_topology_model_unit_test)

  function new(string name = "pcie_svt_topology_model_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void require(bit condition, string message);
    if (!condition)
      `uvm_error("SVT_MODEL", message)
  endfunction

  function bit error_contains(input string errors[$], string fragment);
    foreach (errors[i])
      if (uvm_is_match({"*", fragment, "*"}, errors[i]))
        return 1'b1;
    return 1'b0;
  endfunction

  task run_phase(uvm_phase phase);
    pcie_svt_topology_policy_cfg policy;
    pcie_svt_topology_policy_cfg copy;
    pcie_svt_topology_policy_cfg invalid_policy;
    pcie_svt_link_override_cfg override_cfg;
    pcie_svt_port_descriptor descriptor;
    pcie_svt_port_descriptor descriptor_copy;
    pcie_svt_stage_state_e stage_state;
    bit expected_bar_implemented[6];
    longint unsigned expected_bar_aperture[6];
    string errors[$];

    phase.raise_objection(this);
    foreach (expected_bar_implemented[i]) begin
      expected_bar_implemented[i] = 1'b0;
      expected_bar_aperture[i] = 0;
    end
    expected_bar_implemented[0] = 1'b1;
    expected_bar_implemented[2] = 1'b1;
    expected_bar_implemented[4] = 1'b1;
    expected_bar_aperture[0] = 64'd33554432;
    expected_bar_aperture[2] = 64'd65536;
    expected_bar_aperture[4] = 64'd65536;

    policy = pcie_svt_topology_policy_cfg::type_id::create("policy");
    policy.init_defaults();
    policy.dut_node_ids.push_back("SW0");
    policy.hdl_slot_by_link["RC0_SW0_USP0"] = 0;
    override_cfg = pcie_svt_link_override_cfg::type_id::create("override");
    override_cfg.link_id = "SW0_DSP0_EP0";
    override_cfg.has_gen = 1;
    override_cfg.max_gen = 5;
    policy.link_overrides.push_back(override_cfg);
    policy.validate(errors);

    require(errors.size() == 0, "valid default policy was rejected");
    foreach (policy.ep_bars[i]) begin
      require(policy.ep_bars[i] != null,
              $sformatf("BAR%0d handle is null", i));
      if (policy.ep_bars[i] != null) begin
        require(policy.ep_bars[i].implemented == expected_bar_implemented[i],
                $sformatf("BAR%0d implemented default is wrong", i));
        require(policy.ep_bars[i].is_64bit == expected_bar_implemented[i],
                $sformatf("BAR%0d 64-bit default is wrong", i));
        require(policy.ep_bars[i].prefetchable == expected_bar_implemented[i],
                $sformatf("BAR%0d Prefetchable default is wrong", i));
        require(policy.ep_bars[i].aperture == expected_bar_aperture[i],
                $sformatf("BAR%0d aperture default is wrong", i));
        require(policy.ep_bars[i].initial_base == 0,
                $sformatf("BAR%0d initial_base default is not zero", i));
      end
    end
    require(policy.transport == PCIE_SVT_TRANSPORT_SERIAL,
            "Serial is not the default transport");
    require(policy.vif_prefix == "primary_vif_",
            "primary VIF prefix default is wrong");
    require(policy.reset_vif_key == "primary_reset_vif",
            "reset VIF key default is wrong");
    require(policy.cfg_timeout == 1ms && policy.link_timeout == 3ms &&
            policy.enum_timeout == 3ms && policy.traffic_timeout == 1ms,
            "policy timeout defaults are wrong");
    require(policy.enum_cfg != null,
            "enumeration configuration handle is null");
    if (policy.enum_cfg != null) begin
      require(policy.enum_cfg.pref_mem_base_addr ==
                64'h0000_0001_0000_0000,
              "enumeration Prefetchable base default is wrong");
      require(policy.enum_cfg.pref_mem_limit_addr ==
                64'h0000_0001_0fff_ffff,
              "enumeration Prefetchable limit default is wrong");
      require(policy.enum_cfg.pref_mem_window_stride ==
                64'h0000_0000_1000_0000,
              "enumeration Prefetchable stride default is wrong");
      require(policy.enum_cfg.bus_number == 8'h01 &&
              policy.enum_cfg.device_number == 0,
              "enumeration BDF defaults are wrong");
    end

    $cast(copy, policy.clone());
    copy.dut_node_ids[0] = "CHANGED";
    copy.ep_bars[0].aperture = 64'd4096;
    copy.link_overrides[0].max_gen = 4;
    copy.hdl_slot_by_link["RC0_SW0_USP0"] = 4;
    copy.enum_cfg.pref_mem_base_addr = 64'h0000_0002_0000_0000;
    require(policy.dut_node_ids[0] == "SW0",
            "DUT-node list clone aliases the source");
    require(policy.ep_bars[0].aperture == 64'd33554432,
            "BAR clone aliases the source");
    require(policy.link_overrides[0].max_gen == 5,
            "override clone aliases the source");
    require(policy.hdl_slot_by_link["RC0_SW0_USP0"] == 0,
            "HDL-slot map clone aliases the source");
    require(policy.enum_cfg.pref_mem_base_addr ==
              64'h0000_0001_0000_0000,
            "enumeration configuration clone aliases the source");

    descriptor = pcie_svt_port_descriptor::type_id::create("descriptor");
    descriptor.ep_bars[0].aperture = 64'd8192;
    $cast(descriptor_copy, descriptor.clone());
    descriptor_copy.ep_bars[0].aperture = 64'd4096;
    require(descriptor.ep_bars[0].aperture == 64'd8192,
            "descriptor BAR clone aliases the source");

    $cast(invalid_policy, policy.clone());
    invalid_policy.hdl_slot_by_link[""] = 0;
    invalid_policy.validate(errors);
    require(error_contains(errors, "HDL-slot-map keys must be non-empty"),
            "empty HDL-slot-map key was accepted");
    require(error_contains(errors, "is assigned to both"),
            "empty HDL-slot-map key suppressed duplicate-slot validation");

    $cast(invalid_policy, policy.clone());
    invalid_policy.dut_node_ids.push_back("");
    invalid_policy.dut_node_ids.push_back("");
    invalid_policy.validate(errors);
    require(error_contains(errors, "duplicate DUT node ID ''"),
            "empty DUT node ID suppressed duplicate-ID validation");

    $cast(invalid_policy, policy.clone());
    override_cfg = pcie_svt_link_override_cfg::type_id::create(
      "empty_override0");
    invalid_policy.link_overrides.push_back(override_cfg);
    override_cfg = pcie_svt_link_override_cfg::type_id::create(
      "empty_override1");
    invalid_policy.link_overrides.push_back(override_cfg);
    invalid_policy.validate(errors);
    require(error_contains(errors, "duplicate link override ''"),
            "empty override link_id suppressed duplicate-ID validation");

    $cast(invalid_policy, policy.clone());
    invalid_policy.cfg_timeout = 'x;
    invalid_policy.validate(errors);
    require(error_contains(errors, "cfg_timeout must be positive"),
              "unknown cfg_timeout was accepted");

    $cast(invalid_policy, policy.clone());
    invalid_policy.enum_cfg.pref_mem_limit_addr =
      invalid_policy.enum_cfg.pref_mem_base_addr - 1;
    invalid_policy.validate(errors);
    require(error_contains(errors,
              "Prefetchable memory limit precedes base"),
            "reversed enumeration memory window was accepted");

    $cast(invalid_policy, policy.clone());
    invalid_policy.enum_cfg.pref_mem_window_stride = 64'd4096;
    invalid_policy.validate(errors);
    require(error_contains(errors,
              "window stride is smaller than its window"),
            "overlapping enumeration windows were accepted");

    $cast(invalid_policy, policy.clone());
    invalid_policy.link_timeout = 'x;
    invalid_policy.validate(errors);
    require(error_contains(errors, "link_timeout must be positive"),
            "unknown link_timeout was accepted");

    $cast(invalid_policy, policy.clone());
    invalid_policy.enum_timeout = 'x;
    invalid_policy.validate(errors);
    require(error_contains(errors, "enum_timeout must be positive"),
            "unknown enum_timeout was accepted");

    $cast(invalid_policy, policy.clone());
    invalid_policy.traffic_timeout = 'x;
    invalid_policy.validate(errors);
    require(error_contains(errors, "traffic_timeout must be positive"),
            "unknown traffic_timeout was accepted");

    $cast(invalid_policy, policy.clone());
    invalid_policy.transport = PCIE_SVT_TRANSPORT_PIPE;
    invalid_policy.validate(errors);
    require(error_contains(errors, "PIPE transport is not implemented"),
            "known PIPE transport lost its stable diagnostic");

    $cast(invalid_policy, policy.clone());
    invalid_policy.ep_bars[0].aperture = 'x;
    invalid_policy.validate(errors);
    require(error_contains(errors,
              "BAR0 aperture must be a power of two and at least 16 bytes"),
            "coerced-zero implemented BAR0 aperture was accepted");

    $cast(invalid_policy, policy.clone());
    override_cfg = pcie_svt_link_override_cfg::type_id::create(
      "unknown_gen_override");
    override_cfg.link_id = "SW0_DSP1_EP1";
    override_cfg.has_gen = 1'b1;
    override_cfg.max_gen = 'x;
    invalid_policy.link_overrides.push_back(override_cfg);
    invalid_policy.validate(errors);
    require(error_contains(errors,
              "link override 'SW0_DSP1_EP1' Gen must be 4 or 5"),
            "unknown active override max_gen was accepted");

    $cast(invalid_policy, policy.clone());
    override_cfg = pcie_svt_link_override_cfg::type_id::create(
      "unknown_width_override");
    override_cfg.link_id = "SW0_DSP2_EP2";
    override_cfg.has_width = 1'b1;
    override_cfg.link_width = 'x;
    invalid_policy.link_overrides.push_back(override_cfg);
    invalid_policy.validate(errors);
    require(error_contains(errors,
              "link override 'SW0_DSP2_EP2' width must be 4, 8, or 16"),
            "unknown active override link_width was accepted");

    $cast(invalid_policy, policy.clone());
    override_cfg = pcie_svt_link_override_cfg::type_id::create(
      "unknown_timeout_override");
    override_cfg.link_id = "SW0_DSP1_EP1";
    override_cfg.has_link_timeout = 1'b1;
    override_cfg.link_timeout = 'x;
    invalid_policy.link_overrides.push_back(override_cfg);
    invalid_policy.validate(errors);
    require(error_contains(errors,
              "link override 'SW0_DSP1_EP1' link_timeout must be positive"),
            "unknown override link_timeout was accepted");

    stage_state = PCIE_SVT_STAGE_NOT_RUN;
    require(stage_state.name() == "PCIE_SVT_STAGE_NOT_RUN",
            "stage enum is unavailable");
    phase.drop_objection(this);
  endtask
endclass
