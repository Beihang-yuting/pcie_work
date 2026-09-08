//------------------------------------------------------------------------------
// Backend-neutral PCIe link policy.
//
// A link is dynamic in UVM but is backed by a statically elaborated HDL slot.
// has_hdl_slot distinguishes an explicitly bound slot from an unbound TL-only
// link, which has no SVT VIF requirement.
//------------------------------------------------------------------------------

class pcie_link_cfg extends uvm_object;
  // --------------------------------------------------------------------------
  // Graph identity and endpoint ownership.
  // --------------------------------------------------------------------------
  // Link identity and graph endpoints.  Connectivity remains owned by the
  // corresponding pcie_topology_link_cfg record.
  string link_id;
  string upstream_node_id;
  string downstream_node_id;

  pcie_topology_port_role_e upstream_role;
  pcie_topology_port_role_e downstream_role;
  int unsigned upstream_port_index;
  int unsigned downstream_port_index;

  // --------------------------------------------------------------------------
  // Runtime protocol policy.
  // --------------------------------------------------------------------------
  // Runtime selection: disabled links do not create UVM backend children.
  bit enabled;
  bit use_svt;

  // 当链路由 SVT backend 承担时，必须明确指出哪一个物理节点由 SVT
  // 模拟。这样同一条 RC↔EP 链既可以表达“SVT RC + DUT EP”，也可以
  // 表达“DUT RC + SVT EP”，不会根据链路方向误判角色。
  bit svt_role_valid;
  string svt_node_id;
  pcie_device_role_e svt_role;

  // Physical policy copied from the topology graph.  Width is still a static
  // HDL property for SVT and is validated before backend construction.
  int unsigned link_width;
  int unsigned max_gen;

  // --------------------------------------------------------------------------
  // Optional static SVT binding.
  // --------------------------------------------------------------------------
  // SVT-only binding information.  TL_ONLY links may leave these unbound.
  string vif_key;
  bit has_hdl_slot;
  int unsigned hdl_slot;

  `uvm_object_utils(pcie_link_cfg)

  function new(string name = "pcie_link_cfg");
    super.new(name);
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_link_cfg source;

    super.do_copy(rhs);

    if (!$cast(source, rhs)) begin
      `uvm_fatal("GLOBAL_CFG_COPY", "link source has the wrong type")
      return;
    end

    // Graph identity and endpoint ownership.
    link_id               = source.link_id;
    upstream_node_id      = source.upstream_node_id;
    downstream_node_id    = source.downstream_node_id;
    upstream_role         = source.upstream_role;
    downstream_role       = source.downstream_role;
    upstream_port_index   = source.upstream_port_index;
    downstream_port_index = source.downstream_port_index;

    // Runtime protocol and negotiated capability policy.
    enabled               = source.enabled;
    use_svt               = source.use_svt;
    svt_role_valid        = source.svt_role_valid;
    svt_node_id           = source.svt_node_id;
    svt_role              = source.svt_role;
    link_width            = source.link_width;
    max_gen               = source.max_gen;

    // Static SVT binding metadata; TL-only links may leave it empty.
    vif_key               = source.vif_key;
    has_hdl_slot          = source.has_hdl_slot;
    hdl_slot              = source.hdl_slot;
  endfunction
endclass
