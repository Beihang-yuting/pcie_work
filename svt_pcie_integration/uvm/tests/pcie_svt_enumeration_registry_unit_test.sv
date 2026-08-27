import uvm_pkg::*;
import pcie_topology_pkg::*;
import svt_uvm_pkg::*;
import svt_pcie_uvm_pkg::*;
import pcie_svt_topology_pkg::*;
`include "uvm_macros.svh"

class pcie_svt_enumeration_registry_unit_test extends uvm_test;
  `uvm_component_utils(pcie_svt_enumeration_registry_unit_test)

  function new(
      string name = "pcie_svt_enumeration_registry_unit_test",
      uvm_component parent = null);
    super.new(name, parent);
  endfunction

  protected function void require(bit condition, string message);
    if (!condition)
      `uvm_error("SVT_ENUM_REGISTRY_UNIT", message)
  endfunction

  protected function bit error_contains(
      input string errors[$], string fragment);
    foreach (errors[i])
      if (uvm_is_match({"*", fragment, "*"}, errors[i]))
        return 1'b1;
    return 1'b0;
  endfunction

  protected function svt_pcie_ep_enumeration_seq_status make_status(
      string name,
      bit [63:0] allocation_base = 64'h0000_0001_0000_0000);
    svt_pcie_ep_enumeration_seq_status status;
    bit [63:0] base_address;
    bit [63:0] aperture;

    status = svt_pcie_ep_enumeration_seq_status::type_id::create(name);
    status.captured_bus_number = 8'h01;
    status.captured_device_number = 5'h00;
    status.max_num_functions_supported = 1;
    status.address_space_calculated = 1'b1;
    status.is_ep_device_vip = 1'b1;
    for (int unsigned pair = 0; pair < 3; pair++) begin
      int unsigned low_bar;
      low_bar = pair * 2;
      aperture = (pair == 0) ? 64'd33554432 : 64'd65536;
      case (pair)
        0: base_address = allocation_base;
        1: base_address = allocation_base + 64'h0000_0000_0200_0000;
        default:
          base_address = allocation_base + 64'h0000_0000_0201_0000;
      endcase
      status.non_virtual_bar_present[0][low_bar] = 2'b10;
      status.min_per_bar_address_range[0][low_bar] = base_address;
      status.max_per_bar_address_range[0][low_bar] =
        base_address + aperture - 1;
    end
    return status;
  endfunction

  protected function pcie_svt_enumeration_registry make_registry(
      string name,
      string link_id,
      int unsigned root_hierarchy,
      bit [15:0] bdf,
      svt_pcie_ep_enumeration_seq_status status);
    pcie_svt_enumeration_registry registry;
    registry = pcie_svt_enumeration_registry::type_id::create(name);
    registry.record_direct_endpoint(
      link_id, root_hierarchy, bdf, status);
    return registry;
  endfunction

  protected function void require_rejected(
      pcie_svt_enumeration_registry registry,
      string fragment,
      string label);
    string errors[$];
    registry.finalize(errors);
    require(errors.size() != 0, {label, " was accepted"});
    require(error_contains(errors, fragment), $sformatf(
      "%s did not report expected fragment '%s': %p",
      label, fragment, errors));
    require(!registry.is_finalized(),
            {label, " left registry finalized"});
  endfunction

  task run_phase(uvm_phase phase);
    pcie_svt_enumeration_registry registry;
    pcie_svt_enumeration_vseq enumeration;
    pcie_svt_endpoint_record endpoint;
    pcie_svt_bridge_record bridge;
    svt_pcie_ep_enumeration_seq_status status0;
    svt_pcie_ep_enumeration_seq_status status1;
    string diagnostic;
    string errors[$];

    phase.raise_objection(this);

    enumeration = pcie_svt_enumeration_vseq::type_id::create(
      "enumeration");
    require(!enumeration.peer_model_allows_official_enum(
              "RC0_EP0", diagnostic),
            "missing peer mapping bypassed DUT-style probing");

    enumeration.peer_endpoint_model_by_link["RC0_EP0"] =
      PCIE_SVT_EP_SINGLE;
    require(enumeration.peer_model_allows_official_enum(
              "RC0_EP0", diagnostic),
            "Single-Endpoint peer was rejected");

    enumeration.peer_endpoint_model_by_link["RC0_EP0"] =
      PCIE_SVT_EP_MULTI_BDF;
    require(!enumeration.peer_model_allows_official_enum(
              "RC0_EP0", diagnostic) &&
            uvm_is_match("*Multiple-BDF*", diagnostic),
            "Multiple-BDF peer was accepted or poorly diagnosed");

    // The two RCs are independent roots.  Reusing 01:00.0 and the same
    // allocation coordinates across the two hierarchies is intentional.
    registry = pcie_svt_enumeration_registry::type_id::create(
      "independent_registry");
    status0 = make_status("independent_status0");
    status1 = make_status("independent_status1");
    registry.record_direct_endpoint(
      "RC0_EP0", 0, 16'h0100, status0);
    registry.record_direct_endpoint(
      "RC1_EP1", 1, 16'h0100, status1);
    registry.finalize(errors);
    require(errors.size() == 0, $sformatf(
      "two independent hierarchies rejected: %p", errors));
    require(registry.is_finalized(),
            "valid independent registry did not finalize");
    require(registry.endpoint_count() == 2,
            "endpoint count mismatch");
    require(registry.bar_count() == 6,
            "BAR-pair count mismatch");
    endpoint = registry.find_endpoint("RC1_EP1");
    require(endpoint != null,
            "link lookup returned null Endpoint");
    if (endpoint != null) begin
      require(endpoint.root_hierarchy == 1,
              "link lookup returned wrong hierarchy");
      require(endpoint.bdf == 16'h0100,
              "link lookup returned wrong BDF");
      require(endpoint.bar_base(0) == 64'h0000_0001_0000_0000,
              "BAR0 base lookup returned wrong address");
      foreach (endpoint.bars[pair]) begin
        require(endpoint.bars[pair] != null, $sformatf(
          "Endpoint BAR pair %0d is null", pair));
        if (endpoint.bars[pair] != null) begin
          require(endpoint.bars[pair].low_bar == pair * 2,
                  "BAR pair low index mismatch");
          require(endpoint.bars[pair].high_bar == pair * 2 + 1,
                  "BAR pair high index mismatch");
          require(endpoint.bars[pair].is_64bit,
                  "BAR pair lost 64-bit type");
          require(endpoint.bars[pair].prefetchable,
                  "BAR pair lost Prefetchable contract");
        end
      end
      require(endpoint.bars[0].aperture == 64'd33554432,
              "BAR0/1 aperture mismatch");
      require(endpoint.bars[1].aperture == 64'd65536,
              "BAR2/3 aperture mismatch");
      require(endpoint.bars[2].aperture == 64'd65536,
              "BAR4/5 aperture mismatch");
    end

    bridge = pcie_svt_bridge_record::type_id::create("bridge_contract");
    bridge.is_usp = 1'b1;
    bridge.index = 0;
    bridge.bdf = 16'h0100;
    bridge.primary_bus = 8'h01;
    bridge.secondary_bus = 8'h02;
    bridge.subordinate_bus = 8'h06;
    bridge.prefetch_base = 64'h0000_0001_0000_0000;
    bridge.prefetch_limit = 64'h0000_0001_7fff_ffff;
    require(bridge.is_usp && (bridge.secondary_bus == 8'h02),
            "bridge record public-field contract is unavailable");

    registry = pcie_svt_enumeration_registry::type_id::create(
      "query_order_registry");
    registry.record_direct_endpoint(
      "RC0_EP0", 0, 16'h0100, make_status("query_order_status"));
    endpoint = registry.find_endpoint("RC0_EP0");
    require(endpoint == null,
            "Endpoint lookup before finalize was accepted");
    require(uvm_is_match("*before finalize*", registry.last_error),
            "pre-finalize lookup did not return a stable diagnostic");

    registry = pcie_svt_enumeration_registry::type_id::create(
      "duplicate_link_registry");
    registry.record_direct_endpoint(
      "RC0_EP0", 0, 16'h0100, make_status("duplicate_link_status0"));
    registry.record_direct_endpoint(
      "RC0_EP0", 1, 16'h0100, make_status("duplicate_link_status1"));
    require_rejected(registry, "duplicate link ID 'RC0_EP0'",
                     "duplicate link ID");

    registry = pcie_svt_enumeration_registry::type_id::create(
      "duplicate_bdf_registry");
    registry.record_direct_endpoint(
      "RC0_EP0", 0, 16'h0100, make_status("duplicate_bdf_status0"));
    registry.record_direct_endpoint(
      "RC0_EP1", 0, 16'h0100, make_status("duplicate_bdf_status1",
        64'h0000_0001_1000_0000));
    require_rejected(registry, "duplicate BDF 0100 in root hierarchy 0",
                     "same-hierarchy duplicate BDF");

    status0 = make_status("unpaired_upper_status");
    status0.non_virtual_bar_present[0][0] = 2'b00;
    status0.non_virtual_bar_present[0][1] = 2'b10;
    registry = make_registry("unpaired_upper_registry", "RC0_EP0",
      0, 16'h0100, status0);
    require_rejected(registry,
      "BAR1 is present without a 64-bit low BAR0",
      "upper BAR without 64-bit low BAR");

    status0 = make_status("zero_aperture_status");
    status0.min_per_bar_address_range[0][2] = 64'h0;
    status0.max_per_bar_address_range[0][2] = 64'h0;
    registry = make_registry("zero_aperture_registry", "RC0_EP0",
      0, 16'h0100, status0);
    require_rejected(registry, "BAR2/3 has zero aperture",
                     "zero BAR aperture");

    status0 = make_status("overlap_status");
    status0.min_per_bar_address_range[0][2] =
      status0.min_per_bar_address_range[0][0];
    status0.max_per_bar_address_range[0][2] =
      status0.min_per_bar_address_range[0][0] + 64'd65536 - 1;
    registry = make_registry("overlap_registry", "RC0_EP0",
      0, 16'h0100, status0);
    require_rejected(registry, "overlaps", "overlapping BAR apertures");

    `uvm_info("PCIE_SVT_ENUM_REGISTRY_UNIT_PASS",
      "direct Endpoint registry positive and negative contracts passed",
      UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
