typedef enum bit {
  PCIE_SVT_FLOW_DOWNSTREAM,
  PCIE_SVT_FLOW_UPSTREAM
} pcie_svt_real_switch_flow_direction_e;

class pcie_svt_real_switch_flow_record;
  pcie_svt_real_switch_flow_direction_e direction;
  int unsigned endpoint_index;
  int unsigned source_port;
  bit [15:0] requester_id;
  bit [63:0] address;
  bit [31:0] payload[4];
endclass

class pcie_svt_real_switch_traffic_plan extends uvm_object;
  localparam bit [63:0] HOST_BASE  = 64'h0000_0002_0000_0000;
  localparam bit [63:0] HOST_LIMIT = 64'h0000_0002_0000_ffff;

  pcie_svt_real_switch_flow_record flows[$];

  `uvm_object_utils(pcie_svt_real_switch_traffic_plan)

  function new(string name = "pcie_svt_real_switch_traffic_plan");
    super.new(name);
  endfunction

  function bit build(
      pcie_svt_switch_enum_registry registry,
      output string error);
    pcie_svt_switch_enum_endpoint_record endpoint_by_dsp[4];
    pcie_svt_switch_enum_bar_record bar0_by_dsp[4];
    pcie_svt_real_switch_flow_record candidate_flows[$];

    flows.delete();
    error = "";
    if ((registry == null) || !registry.validated) begin
      error = "enumeration registry is not validated";
      return 1'b0;
    end

    foreach (registry.endpoints[i]) begin
      int unsigned dsp;
      dsp = registry.endpoints[i].dsp_index;
      if ((dsp >= 4) || (endpoint_by_dsp[dsp] != null)) begin
        error = "Endpoint-to-DSP mapping is not one-to-one";
        return 1'b0;
      end
      endpoint_by_dsp[dsp] = registry.endpoints[i];
    end

    foreach (registry.bar_apertures[i]) begin
      int unsigned dsp;
      dsp = registry.bar_apertures[i].dsp_index;
      if ((dsp < 4) && (registry.bar_apertures[i].pair_index == 0)) begin
        if (bar0_by_dsp[dsp] != null) begin
          error = "DSP has duplicate BAR0/1 records";
          return 1'b0;
        end
        bar0_by_dsp[dsp] = registry.bar_apertures[i];
      end
    end

    for (int unsigned ep = 0; ep < 4; ep++) begin
      if ((endpoint_by_dsp[ep] == null) || (bar0_by_dsp[ep] == null)) begin
        error = $sformatf("DSP%0d has no Endpoint BAR0/1 mapping", ep);
        return 1'b0;
      end
    end

    for (int unsigned ep = 0; ep < 4; ep++) begin
      pcie_svt_real_switch_flow_record down;
      down = new();
      down.direction = PCIE_SVT_FLOW_DOWNSTREAM;
      down.endpoint_index = ep;
      down.source_port = PCIE_SVT_PRIMARY_RC0;
      down.requester_id = 16'h0000;
      down.address = bar0_by_dsp[ep].base_address + 64'h100 + ep * 64'h40;
      if ((down.address + 15) > bar0_by_dsp[ep].limit_address) begin
        error = $sformatf(
          "DSP%0d BAR0/1 cannot contain traffic payload", ep);
        return 1'b0;
      end
      for (int unsigned dw = 0; dw < 4; dw++)
        down.payload[dw] = 32'hd000_0000 | (ep << 12) | dw;
      candidate_flows.push_back(down);
    end

    for (int unsigned ep = 0; ep < 4; ep++) begin
      pcie_svt_real_switch_flow_record up;
      up = new();
      up.direction = PCIE_SVT_FLOW_UPSTREAM;
      up.endpoint_index = ep;
      up.source_port = PCIE_SVT_PRIMARY_EP0 + ep;
      up.requester_id = endpoint_by_dsp[ep].bdf;
      up.address = HOST_BASE + ep * 64'h1000 + 64'h100;
      if ((up.address + 15) > HOST_LIMIT) begin
        error = $sformatf("EP%0d host payload exceeds range", ep);
        return 1'b0;
      end
      for (int unsigned dw = 0; dw < 4; dw++)
        up.payload[dw] = 32'he000_0000 | (ep << 12) | dw;
      candidate_flows.push_back(up);
    end

    flows = candidate_flows;
    return 1'b1;
  endfunction
endclass
