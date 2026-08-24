typedef enum {
    PCIE_TOPO_NODE_RC,
    PCIE_TOPO_NODE_SWITCH,
    PCIE_TOPO_NODE_EP
} pcie_topology_node_kind_e;

typedef enum {
    PCIE_TOPO_PORT_RC,
    PCIE_TOPO_PORT_USP,
    PCIE_TOPO_PORT_DSP,
    PCIE_TOPO_PORT_EP
} pcie_topology_port_role_e;

class pcie_topology_node_cfg extends uvm_object;
    `uvm_object_utils(pcie_topology_node_cfg)

    string                    node_id;
    pcie_topology_node_kind_e kind;
    int unsigned              num_usp = 0;
    int unsigned              num_dsp = 0;
    int                       dsp_owner_usp[];

    function new(string name = "pcie_topology_node_cfg");
        super.new(name);
    endfunction

    virtual function void do_copy(uvm_object rhs);
        pcie_topology_node_cfg rhs_;

        super.do_copy(rhs);
        if (!$cast(rhs_, rhs)) begin
            `uvm_fatal("TOPO_COPY", "node copy source has wrong type")
            return;
        end

        node_id       = rhs_.node_id;
        kind          = rhs_.kind;
        num_usp       = rhs_.num_usp;
        num_dsp       = rhs_.num_dsp;
        dsp_owner_usp = new[rhs_.dsp_owner_usp.size()](rhs_.dsp_owner_usp);
    endfunction : do_copy
endclass

class pcie_topology_link_cfg extends uvm_object;
    `uvm_object_utils(pcie_topology_link_cfg)

    string                    link_id;
    string                    upstream_node_id;
    pcie_topology_port_role_e upstream_role;
    int unsigned              upstream_port_index = 0;
    string                    downstream_node_id;
    pcie_topology_port_role_e downstream_role;
    int unsigned              downstream_port_index = 0;
    int unsigned              link_width = 4;
    int unsigned              max_gen = 4;
    bit                       enabled = 1'b1;

    function new(string name = "pcie_topology_link_cfg");
        super.new(name);
    endfunction

    virtual function void do_copy(uvm_object rhs);
        pcie_topology_link_cfg rhs_;

        super.do_copy(rhs);
        if (!$cast(rhs_, rhs)) begin
            `uvm_fatal("TOPO_COPY", "link copy source has wrong type")
            return;
        end

        link_id               = rhs_.link_id;
        upstream_node_id      = rhs_.upstream_node_id;
        upstream_role         = rhs_.upstream_role;
        upstream_port_index   = rhs_.upstream_port_index;
        downstream_node_id    = rhs_.downstream_node_id;
        downstream_role       = rhs_.downstream_role;
        downstream_port_index = rhs_.downstream_port_index;
        link_width            = rhs_.link_width;
        max_gen               = rhs_.max_gen;
        enabled               = rhs_.enabled;
    endfunction : do_copy
endclass
