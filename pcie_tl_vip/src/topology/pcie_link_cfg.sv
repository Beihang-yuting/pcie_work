//------------------------------------------------------------------------------
// Backend-neutral PCIe link policy.
//
// A link is dynamic in UVM but is backed by a statically elaborated HDL slot.
// has_hdl_slot distinguishes an explicitly bound slot from an unbound TL-only
// link, which has no SVT VIF requirement.
//------------------------------------------------------------------------------

class pcie_link_cfg extends uvm_object;
  // Link identity and graph endpoints.  Connectivity remains owned by the
  // corresponding pcie_topology_link_cfg record.
  string link_id;
  string upstream_node_id;
  string downstream_node_id;

  pcie_topology_port_role_e upstream_role;
  pcie_topology_port_role_e downstream_role;
  int unsigned upstream_port_index;
  int unsigned downstream_port_index;

  // Runtime selection: disabled links do not create UVM backend children.
  bit enabled;
  bit use_svt;

  // Physical policy copied from the topology graph.  Width is still a static
  // HDL property for SVT and is validated before backend construction.
  int unsigned link_width;
  int unsigned max_gen;

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
    link_id               = source.link_id;
    upstream_node_id      = source.upstream_node_id;
    downstream_node_id    = source.downstream_node_id;
    upstream_role         = source.upstream_role;
    downstream_role       = source.downstream_role;
    upstream_port_index   = source.upstream_port_index;
    downstream_port_index = source.downstream_port_index;
    enabled               = source.enabled;
    use_svt               = source.use_svt;
    link_width            = source.link_width;
    max_gen               = source.max_gen;
    vif_key               = source.vif_key;
    has_hdl_slot          = source.has_hdl_slot;
    hdl_slot              = source.hdl_slot;
  endfunction
endclass
