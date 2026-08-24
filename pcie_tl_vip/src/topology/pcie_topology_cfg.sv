class pcie_topology_cfg extends uvm_object;
    `uvm_object_utils(pcie_topology_cfg)

    pcie_topology_node_cfg nodes[$];
    pcie_topology_link_cfg links[$];

    function new(string name = "pcie_topology_cfg");
        super.new(name);
    endfunction

    function int find_node_index(string node_id);
        foreach (nodes[i]) begin
            if ((nodes[i] != null) && (nodes[i].node_id == node_id)) return i;
        end
        return -1;
    endfunction

    function pcie_topology_node_cfg find_node(string node_id);
        int index;

        index = find_node_index(node_id);
        if (index < 0) return null;
        return nodes[index];
    endfunction

    virtual function void do_copy(uvm_object rhs);
        pcie_topology_cfg rhs_;
        pcie_topology_node_cfg node_copy;
        pcie_topology_link_cfg link_copy;

        super.do_copy(rhs);
        if (!$cast(rhs_, rhs))
            `uvm_fatal("TOPO_COPY", "topology copy source has wrong type")

        nodes.delete();
        foreach (rhs_.nodes[i]) begin
            if (rhs_.nodes[i] == null) begin
                nodes.push_back(null);
            end
            else begin
                node_copy = pcie_topology_node_cfg::type_id::create(rhs_.nodes[i].get_name());
                node_copy.copy(rhs_.nodes[i]);
                nodes.push_back(node_copy);
            end
        end

        links.delete();
        foreach (rhs_.links[i]) begin
            if (rhs_.links[i] == null) begin
                links.push_back(null);
            end
            else begin
                link_copy = pcie_topology_link_cfg::type_id::create(rhs_.links[i].get_name());
                link_copy.copy(rhs_.links[i]);
                links.push_back(link_copy);
            end
        end
    endfunction : do_copy

    virtual function void validate(output string errors[$]);
        errors.delete();
    endfunction
endclass
