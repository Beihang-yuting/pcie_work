class pcie_svt_profile_set extends uvm_object;
  pcie_svt_port_profile port[PCIE_SVT_MAX_PORTS];

  `uvm_object_utils(pcie_svt_profile_set)

  function new(string name = "pcie_svt_profile_set");
    super.new(name);
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_svt_profile_set rhs_set;
    super.do_copy(rhs);
    if (!$cast(rhs_set, rhs)) begin
      `uvm_error("PROFILE_COPY", "pcie_svt_profile_set copy source has the wrong type")
      return;
    end
    foreach (port[i]) begin
      if (rhs_set.port[i] == null) begin
        port[i] = null;
      end else begin
        port[i] = pcie_svt_port_profile::type_id::create(
          $sformatf("port%0d", i));
        port[i].copy(rhs_set.port[i]);
      end
    end
  endfunction

  function int unsigned active_count();
    int unsigned count;
    foreach (port[i])
      if (port[i] != null)
        count++;
    return count;
  endfunction

  function void clear();
    foreach (port[i])
      port[i] = null;
  endfunction

  function void set_fixed_defaults(pcie_svt_function_profile fn);
    fn.revision_id = 8'h00;
    fn.command_reset = 16'h0000;
    fn.max_payload_supported = 3'd0;
    fn.max_payload_size = 3'd0;
    fn.max_read_request_size = 3'd2;
    fn.completion_timeout_ranges = 4'b0001;
  endfunction

  function void set_64b_prefetch_bar(pcie_svt_function_profile fn,
                                     int unsigned bar_number,
                                     longint unsigned aperture);
    fn.bars[bar_number].implemented = 1;
    fn.bars[bar_number].is_64bit = 1;
    fn.bars[bar_number].prefetchable = 1;
    fn.bars[bar_number].aperture = aperture;
    fn.bars[bar_number].initial_base = 0;
  endfunction

  function pcie_svt_port_profile make_ep(string port_id,
                                         int unsigned width,
                                         int unsigned hierarchy,
                                         int unsigned max_gen,
                                         bit [15:0] vendor_id,
                                         bit [15:0] device_id);
    pcie_svt_port_profile result;
    pcie_svt_function_profile fn;
    result = pcie_svt_port_profile::type_id::create(port_id);
    result.port_id = port_id;
    result.role = PCIE_SVT_EP;
    result.link_width = width;
    result.max_gen = max_gen;
    result.root_hierarchy = hierarchy;
    fn = pcie_svt_function_profile::type_id::create({port_id, "_pf0"});
    set_fixed_defaults(fn);
    fn.vendor_id = vendor_id;
    fn.device_id = device_id;
    fn.class_code = 24'h020000;
    fn.header_type = 8'h00;
    fn.subsystem_vendor_id = vendor_id;
    fn.subsystem_device_id = device_id;
    fn.interrupt_pin = 8'h01;
    set_64b_prefetch_bar(fn, 0, 64'd33554432);
    set_64b_prefetch_bar(fn, 2, 64'd65536);
    set_64b_prefetch_bar(fn, 4, 64'd65536);
    result.functions.push_back(fn);
    return result;
  endfunction

  function pcie_svt_port_profile make_rc(string port_id,
                                         int unsigned width,
                                         int unsigned hierarchy,
                                         int unsigned max_gen);
    pcie_svt_port_profile result;
    pcie_svt_function_profile fn;
    result = pcie_svt_port_profile::type_id::create(port_id);
    result.port_id = port_id;
    result.role = PCIE_SVT_RC;
    result.link_width = width;
    result.max_gen = max_gen;
    result.root_hierarchy = hierarchy;
    fn = pcie_svt_function_profile::type_id::create({port_id, "_pf0"});
    set_fixed_defaults(fn);
    // Stable legal IDs for all supplied RC PF0 templates.
    fn.vendor_id = 16'h1d0f;
    fn.device_id = 16'hf000;
    fn.class_code = 24'h060400;
    fn.header_type = 8'h01;
    fn.subsystem_vendor_id = fn.vendor_id;
    fn.subsystem_device_id = fn.device_id;
    fn.interrupt_pin = 8'h00;
    result.functions.push_back(fn);
    return result;
  endfunction

  function void add_port(int unsigned index, pcie_svt_port_profile profile);
    if ((index >= PCIE_SVT_MAX_PORTS) || (profile == null))
      `uvm_fatal("PROFILE", "attempted to add an invalid port profile")
    port[index] = profile;
  endfunction

  function void validate_generated(string kind);
    foreach (port[i])
      if ((port[i] != null) && !port[i].validate())
        `uvm_fatal("PROFILE", $sformatf("invalid generated %s profile at index %0d",
                                        kind, i))
  endfunction

  function void check_build_args(pcie_svt_topology_e topology,
                                 int unsigned max_gen);
    if (!((max_gen == 4) || (max_gen == 5)))
      `uvm_fatal("PROFILE", "profile max_gen must be Gen4 or Gen5")
    if (!((topology == PCIE_SVT_TOPO_EP_X16) ||
          (topology == PCIE_SVT_TOPO_EP_2X8) ||
          (topology == PCIE_SVT_TOPO_SWITCH)))
      `uvm_fatal("PROFILE", "unsupported PCIe SVT topology")
  endfunction

  function void build_for_topology(pcie_svt_topology_e topology,
                                   int unsigned max_gen);
    clear();
    check_build_args(topology, max_gen);
    case (topology)
      PCIE_SVT_TOPO_EP_X16:
        add_port(PCIE_SVT_PRIMARY_RC0, make_rc("rc0", 16, 0, max_gen));
      PCIE_SVT_TOPO_EP_2X8: begin
        add_port(PCIE_SVT_PRIMARY_RC0, make_rc("rc0", 8, 0, max_gen));
        add_port(PCIE_SVT_PRIMARY_RC1, make_rc("rc1", 8, 1, max_gen));
      end
      PCIE_SVT_TOPO_SWITCH: begin
        add_port(PCIE_SVT_PRIMARY_RC0, make_rc("rc0", 16, 0, max_gen));
        for (int i = 0; i < 4; i++)
          add_port(PCIE_SVT_PRIMARY_EP0+i,
                   make_ep($sformatf("ep%0d", i), 4, 0, max_gen,
                           16'h20f9, 16'h5011+i));
      end
      default: `uvm_fatal("PROFILE", "unsupported PCIe SVT topology")
    endcase
    validate_generated("primary");
  endfunction

  function void build_peer_for_topology(pcie_svt_topology_e topology,
                                        int unsigned max_gen);
    clear();
    check_build_args(topology, max_gen);
    case (topology)
      PCIE_SVT_TOPO_EP_X16:
        add_port(PCIE_SVT_PEER_PORT0,
                 make_ep("peer_ep0", 16, 0, max_gen, 16'h1af4, 16'h1000));
      PCIE_SVT_TOPO_EP_2X8: begin
        add_port(PCIE_SVT_PEER_PORT0,
                 make_ep("peer_ep0", 8, 0, max_gen, 16'h1af4, 16'h1000));
        add_port(PCIE_SVT_PEER_PORT1,
                 make_ep("peer_ep1", 8, 1, max_gen, 16'h1af4, 16'h1001));
      end
      PCIE_SVT_TOPO_SWITCH: begin
        add_port(PCIE_SVT_PEER_PORT0,
                 make_ep("peer_ep_usp", 16, 0, max_gen,
                         16'h1af4, 16'h1100));
        for (int i = 0; i < 4; i++)
          add_port(PCIE_SVT_PEER_PORT1+i,
                   make_rc($sformatf("peer_rc_dsp%0d", i), 4, i+1,
                           max_gen));
      end
      default: `uvm_fatal("PROFILE", "unsupported PCIe SVT topology")
    endcase
    validate_generated("peer");
  endfunction
endclass
