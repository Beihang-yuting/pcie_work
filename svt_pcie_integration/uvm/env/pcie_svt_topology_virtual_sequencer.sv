class pcie_svt_topology_virtual_sequencer extends
    uvm_sequencer #(uvm_sequence_item);
  `uvm_component_utils(pcie_svt_topology_virtual_sequencer)

  pcie_svt_port_descriptor descriptor_by_link[string];
  svt_pcie_device_configuration cfg_by_link[string];
  svt_pcie_device_status status_by_link[string];
  svt_pcie_device_agent agent_by_link[string];
  svt_pcie_device_virtual_sequencer seqr_by_link[string];
  pcie_svt_stage_state_e cfg_state[string];
  pcie_svt_stage_state_e link_state[string];
  pcie_svt_stage_state_e enum_state[string];
  pcie_svt_stage_state_e traffic_state[string];
  bit host_memory_window_valid[string];
  bit [63:0] host_memory_base[string];
  bit [63:0] host_memory_limit[string];
  virtual pcie_svt_reset_if reset_vif;
  string last_registry_error;

  function new(string name = "pcie_svt_topology_virtual_sequencer",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void register_port(
      pcie_svt_port_descriptor descriptor,
      svt_pcie_device_configuration cfg,
      svt_pcie_device_status status,
      svt_pcie_device_agent agent);
    if (descriptor == null) begin
      `uvm_fatal("SVT_VSEQR_REGISTER", "cannot register a null descriptor")
      return;
    end
    if (descriptor.link_id.len() == 0) begin
      `uvm_fatal("SVT_VSEQR_REGISTER", "cannot register an empty link ID")
      return;
    end
    if ((cfg == null) || (status == null) || (agent == null)) begin
      `uvm_fatal("SVT_VSEQR_REGISTER", $sformatf(
        "%s: cfg, status, and agent must all be non-null",
        descriptor.link_id))
      return;
    end
    if (descriptor_by_link.exists(descriptor.link_id)) begin
      `uvm_fatal("SVT_VSEQR_REGISTER", $sformatf(
        "duplicate link registration '%s'", descriptor.link_id))
      return;
    end

    descriptor_by_link[descriptor.link_id] = descriptor;
    cfg_by_link[descriptor.link_id] = cfg;
    status_by_link[descriptor.link_id] = status;
    agent_by_link[descriptor.link_id] = agent;
    cfg_state[descriptor.link_id] = PCIE_SVT_STAGE_NOT_RUN;
    link_state[descriptor.link_id] = PCIE_SVT_STAGE_NOT_RUN;
    enum_state[descriptor.link_id] = PCIE_SVT_STAGE_NOT_RUN;
    traffic_state[descriptor.link_id] = PCIE_SVT_STAGE_NOT_RUN;
    host_memory_window_valid[descriptor.link_id] = 1'b0;
    host_memory_base[descriptor.link_id] = 64'h0;
    host_memory_limit[descriptor.link_id] = 64'h0;
  endfunction

  function void connect_port(
      string link_id,
      svt_pcie_device_virtual_sequencer seqr);
    if (!descriptor_by_link.exists(link_id) ||
        !agent_by_link.exists(link_id)) begin
      `uvm_fatal("SVT_VSEQR_CONNECT", $sformatf(
        "cannot connect unregistered link '%s'", link_id))
      return;
    end
    if (seqr == null) begin
      `uvm_fatal("SVT_VSEQR_CONNECT", $sformatf(
        "%s: device virtual sequencer is null", link_id))
      return;
    end
    if (seqr_by_link.exists(link_id)) begin
      `uvm_fatal("SVT_VSEQR_CONNECT", $sformatf(
        "duplicate sequencer connection '%s'", link_id))
      return;
    end
    seqr_by_link[link_id] = seqr;
  endfunction

  function pcie_svt_port_descriptor get_port_descriptor(string link_id);
    if (!descriptor_by_link.exists(link_id))
      return null;
    return descriptor_by_link[link_id];
  endfunction

  function svt_pcie_device_virtual_sequencer get_port_seqr(string link_id);
    if (!seqr_by_link.exists(link_id))
      return null;
    return seqr_by_link[link_id];
  endfunction

  function svt_pcie_device_virtual_sequencer require_port_seqr(
      string link_id,
      string operation_context = "topology sequence");
    svt_pcie_device_virtual_sequencer seqr;
    seqr = get_port_seqr(link_id);
    if (seqr == null) begin
      `uvm_fatal("SVT_VSEQR_LOOKUP", $sformatf(
        "%s requires registered link sequencer '%s'",
        operation_context, link_id))
      return null;
    end
    return seqr;
  endfunction

  function void get_links_by_role(
      pcie_svt_role_e role,
      output string link_ids[$]);
    link_ids.delete();
    foreach (descriptor_by_link[link_id]) begin
      if (descriptor_by_link[link_id].role == role)
        link_ids.push_back(link_id);
    end
    for (int i = 0; i < link_ids.size(); i++) begin
      for (int j = i + 1; j < link_ids.size(); j++) begin
        if (link_ids[j] < link_ids[i]) begin
          string temporary;
          temporary = link_ids[i];
          link_ids[i] = link_ids[j];
          link_ids[j] = temporary;
        end
      end
    end
  endfunction

  function bit reserve_host_memory_window(
      string link_id,
      bit [63:0] base_address,
      bit [63:0] limit_address);
    pcie_svt_port_descriptor descriptor;

    last_registry_error = "";
    descriptor = get_port_descriptor(link_id);
    if (descriptor == null) begin
      last_registry_error = $sformatf("link '%s' is not registered", link_id);
      return 1'b0;
    end
    if (descriptor.role != PCIE_SVT_ROLE_RC) begin
      last_registry_error = $sformatf("link '%s' is not an RC", link_id);
      return 1'b0;
    end
    if (base_address > limit_address) begin
      last_registry_error = $sformatf(
        "link '%s' host-memory base exceeds limit", link_id);
      return 1'b0;
    end
    if (host_memory_window_valid.exists(link_id) &&
        host_memory_window_valid[link_id]) begin
      last_registry_error = $sformatf(
        "link '%s' already has a host-memory window", link_id);
      return 1'b0;
    end
    foreach (descriptor_by_link[other_link_id]) begin
      if ((other_link_id != link_id) &&
          host_memory_window_valid.exists(other_link_id) &&
          host_memory_window_valid[other_link_id] &&
          (descriptor_by_link[other_link_id].root_hierarchy ==
             descriptor.root_hierarchy) &&
          !((limit_address < host_memory_base[other_link_id]) ||
            (base_address > host_memory_limit[other_link_id]))) begin
        last_registry_error = $sformatf(
          "link '%s' host-memory window overlaps link '%s' in hierarchy %0d",
          link_id, other_link_id, descriptor.root_hierarchy);
        return 1'b0;
      end
    end

    host_memory_window_valid[link_id] = 1'b1;
    host_memory_base[link_id] = base_address;
    host_memory_limit[link_id] = limit_address;
    return 1'b1;
  endfunction

  function bit get_host_memory_window(
      string link_id,
      output bit [63:0] base_address,
      output bit [63:0] limit_address);
    base_address = 64'h0;
    limit_address = 64'h0;
    if (!host_memory_window_valid.exists(link_id) ||
        !host_memory_window_valid[link_id])
      return 1'b0;
    base_address = host_memory_base[link_id];
    limit_address = host_memory_limit[link_id];
    return 1'b1;
  endfunction

  protected function string stage_name(pcie_svt_stage_state_e state);
    case (state)
      PCIE_SVT_STAGE_PASS: return "PASS";
      PCIE_SVT_STAGE_FAIL: return "FAIL";
      default: return "NOT_RUN";
    endcase
  endfunction

  function void report_stage_table();
    string link_ids[$];
    foreach (descriptor_by_link[link_id])
      link_ids.push_back(link_id);
    for (int i = 0; i < link_ids.size(); i++) begin
      for (int j = i + 1; j < link_ids.size(); j++) begin
        if (link_ids[j] < link_ids[i]) begin
          string temporary;
          temporary = link_ids[i];
          link_ids[i] = link_ids[j];
          link_ids[j] = temporary;
        end
      end
    end
    foreach (link_ids[i]) begin
      string link_id;
      link_id = link_ids[i];
      `uvm_info("PCIE_SVT_STAGE", $sformatf(
        "link=%s CFG=%s LINK=%s ENUM=%s TRAFFIC=%s",
        link_id, stage_name(cfg_state[link_id]),
        stage_name(link_state[link_id]), stage_name(enum_state[link_id]),
        stage_name(traffic_state[link_id])), UVM_NONE)
    end
  endfunction
endclass
