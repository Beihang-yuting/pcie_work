module pcie_svt_real_switch_contract_unit_test;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import pcie_svt_integration_pkg::*;

  function automatic void require(bit condition, string message);
    if (!condition)
      `uvm_fatal("REAL_SWITCH_CONTRACT_TEST", message)
  endfunction

  function automatic pcie_svt_switch_enum_registry make_registry();
    pcie_svt_switch_enum_registry registry;
    pcie_svt_switch_enum_endpoint_record endpoint;
    pcie_svt_switch_enum_bar_record bar;
    bit [63:0] bar0_base;
    bit [63:0] aperture;

    registry = pcie_svt_switch_enum_registry::type_id::create(
      "contract_registry");
    registry.validated = 1'b1;
    for (int unsigned ep = 0; ep < 4; ep++) begin
      endpoint = new();
      endpoint.index = ep;
      endpoint.dsp_index = ep;
      endpoint.bdf = {(8'h03 + ep), 5'h00, 3'h0};
      endpoint.parent_dsp_bdf = {8'h02, ep[4:0], 3'h0};
      registry.endpoints.push_back(endpoint);

      bar0_base = 64'h0000_0001_0000_0000 +
                  ep * 64'h0000_0000_0800_0000;
      for (int unsigned pair = 0; pair < 3; pair++) begin
        case (pair)
          0: begin
            aperture = 64'h0000_0000_0200_0000;
            bar = new();
            bar.base_address = bar0_base;
          end
          1: begin
            aperture = 64'h0000_0000_0001_0000;
            bar = new();
            bar.base_address = bar0_base + 64'h0000_0000_0200_0000;
          end
          default: begin
            aperture = 64'h0000_0000_0001_0000;
            bar = new();
            bar.base_address = bar0_base + 64'h0000_0000_0201_0000;
          end
        endcase
        bar.index = registry.bar_apertures.size();
        bar.ep_index = ep;
        bar.dsp_index = ep;
        bar.pair_index = pair;
        bar.low_bar = pair * 2;
        bar.high_bar = bar.low_bar + 1;
        bar.ep_bdf = endpoint.bdf;
        bar.parent_dsp_bdf = endpoint.parent_dsp_bdf;
        bar.limit_address = bar.base_address + aperture - 1;
        bar.aperture = aperture;
        registry.bar_apertures.push_back(bar);
      end
    end
    return registry;
  endfunction

  initial begin
    string error;
    pcie_svt_switch_enum_registry registry;
    pcie_svt_real_switch_traffic_plan plan;

    registry = make_registry();
    plan = pcie_svt_real_switch_traffic_plan::type_id::create("plan");

    require(pcie_svt_real_switch_link_gate::ready(
      4, 16, 1'b1, 1'b1, 1'b1, 4, 16), "Gen4 x16 ready rejected");
    require(!pcie_svt_real_switch_link_gate::ready(
      4, 16, 1'b0, 1'b1, 1'b1, 4, 16), "PL-down accepted");
    require(!pcie_svt_real_switch_link_gate::ready(
      5, 4, 1'b1, 1'b0, 1'b1, 5, 4), "DL-down accepted");
    require(!pcie_svt_real_switch_link_gate::ready(
      5, 4, 1'b1, 1'b1, 1'b0, 5, 4), "non-L0 accepted");
    require(!pcie_svt_real_switch_link_gate::ready(
      5, 4, 1'b1, 1'b1, 1'b1, 4, 4), "wrong speed accepted");
    require(!pcie_svt_real_switch_link_gate::ready(
      5, 4, 1'b1, 1'b1, 1'b1, 5, 8), "wrong width accepted");

    require(plan.build(registry, error), {"valid plan rejected: ", error});
    require(plan.flows.size() == 8, "plan must contain eight flows");
    for (int unsigned ep = 0; ep < 4; ep++) begin
      require(plan.flows[ep].direction == PCIE_SVT_FLOW_DOWNSTREAM,
              "first four flows must be downstream");
      require(plan.flows[ep].source_port == PCIE_SVT_PRIMARY_RC0,
              "downstream source must be RC0");
      require(plan.flows[ep].address ==
              registry.bar_apertures[ep * 3].base_address +
              64'h100 + ep * 64'h40, "downstream address mismatch");
      require(plan.flows[4 + ep].direction == PCIE_SVT_FLOW_UPSTREAM,
              "last four flows must be upstream");
      require(plan.flows[4 + ep].source_port == PCIE_SVT_PRIMARY_EP0 + ep,
              "upstream source mismatch");
      require(plan.flows[4 + ep].requester_id == registry.endpoints[ep].bdf,
              "upstream requester mismatch");
      for (int unsigned dw = 0; dw < 4; dw++) begin
        require(plan.flows[ep].payload[dw] ==
                (32'hd000_0000 | (ep << 12) | dw),
                "downstream payload mismatch");
        require(plan.flows[4 + ep].payload[dw] ==
                (32'he000_0000 | (ep << 12) | dw),
                "upstream payload mismatch");
      end
    end

    registry = make_registry();
    registry.bar_apertures[6].limit_address =
      registry.bar_apertures[6].base_address + 64'h100 + 2 * 64'h40 + 14;
    require(!plan.build(registry, error),
            "undersized DSP2 BAR0/1 accepted");
    require(error == "DSP2 BAR0/1 cannot contain traffic payload",
            {"unexpected error: ", error});
    require(plan.flows.size() == 0,
            "failed plan retained partial traffic flows");

    registry.validated = 1'b0;
    require(!plan.build(registry, error), "unvalidated registry accepted");
    require(error == "enumeration registry is not validated",
            {"unexpected error: ", error});
    $display("REAL_SWITCH_CONTRACT_UNIT_PASS flows=8 link_negatives=5");
  end
endmodule
