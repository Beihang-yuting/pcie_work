class pcie_topology_builder extends uvm_object;
    `uvm_object_utils(pcie_topology_builder)

    pcie_topology_cfg topology;

    function new(string name = "pcie_topology_builder");
        super.new(name);
        topology = pcie_topology_cfg::type_id::create("topology");
    endfunction

    function pcie_topology_node_cfg add_node(
        string node_id, pcie_topology_node_kind_e kind);
        pcie_topology_node_cfg node;

        node = pcie_topology_node_cfg::type_id::create(node_id);
        node.node_id = node_id;
        node.kind = kind;
        topology.nodes.push_back(node);
        return node;
    endfunction

    function pcie_topology_node_cfg add_rc(string node_id);
        return add_node(node_id, PCIE_TOPO_NODE_RC);
    endfunction

    function pcie_topology_node_cfg add_ep(string node_id);
        return add_node(node_id, PCIE_TOPO_NODE_EP);
    endfunction

    function pcie_topology_node_cfg add_switch(
        string node_id, int unsigned num_usp, int unsigned num_dsp,
        input int owners[]);
        pcie_topology_node_cfg node;

        node = add_node(node_id, PCIE_TOPO_NODE_SWITCH);
        node.num_usp = num_usp;
        node.num_dsp = num_dsp;
        node.dsp_owner_usp = new[owners.size()](owners);
        return node;
    endfunction

    function pcie_topology_link_cfg connect(
        string link_id, string upstream_node_id,
        pcie_topology_port_role_e upstream_role,
        int unsigned upstream_port_index, string downstream_node_id,
        pcie_topology_port_role_e downstream_role,
        int unsigned downstream_port_index, int unsigned link_width,
        int unsigned max_gen, bit enabled = 1'b1);
        pcie_topology_link_cfg link;

        link = pcie_topology_link_cfg::type_id::create(link_id);
        link.link_id = link_id;
        link.upstream_node_id = upstream_node_id;
        link.upstream_role = upstream_role;
        link.upstream_port_index = upstream_port_index;
        link.downstream_node_id = downstream_node_id;
        link.downstream_role = downstream_role;
        link.downstream_port_index = downstream_port_index;
        link.link_width = link_width;
        link.max_gen = max_gen;
        link.enabled = enabled;
        topology.links.push_back(link);
        return link;
    endfunction

    function pcie_topology_cfg finish();
        return topology;
    endfunction

    static function pcie_topology_cfg build_ep_x16(int unsigned max_gen);
        pcie_topology_builder builder;

        builder = pcie_topology_builder::type_id::create("ep_x16_builder");
        builder.add_rc("RC0");
        builder.add_ep("EP0");
        builder.connect("RC0_EP0", "RC0", PCIE_TOPO_PORT_RC, 0,
                        "EP0", PCIE_TOPO_PORT_EP, 0, 16, max_gen);
        return builder.finish();
    endfunction

    static function pcie_topology_cfg build_ep_2x8(int unsigned max_gen);
        pcie_topology_builder builder;

        builder = pcie_topology_builder::type_id::create("ep_2x8_builder");
        for (int unsigned i = 0; i < 2; i++) begin
            builder.add_rc($sformatf("RC%0d", i));
            builder.add_ep($sformatf("EP%0d", i));
        end
        for (int unsigned i = 0; i < 2; i++) begin
            builder.connect($sformatf("RC%0d_EP%0d", i, i),
                            $sformatf("RC%0d", i), PCIE_TOPO_PORT_RC, 0,
                            $sformatf("EP%0d", i), PCIE_TOPO_PORT_EP, 0,
                            8, max_gen);
        end
        return builder.finish();
    endfunction

    static function pcie_topology_cfg build_switch_1x16_4x4(
        int unsigned max_gen);
        pcie_topology_builder builder;
        int owners[];

        builder = pcie_topology_builder::type_id::create("switch_1x16_4x4_builder");
        owners = new[4];
        foreach (owners[i]) owners[i] = 0;

        builder.add_rc("RC0");
        builder.add_switch("SW0", 1, 4, owners);
        for (int unsigned i = 0; i < 4; i++) begin
            builder.add_ep($sformatf("EP%0d", i));
        end

        builder.connect("RC0_SW0_USP0", "RC0", PCIE_TOPO_PORT_RC, 0,
                        "SW0", PCIE_TOPO_PORT_USP, 0, 16, max_gen);
        for (int unsigned i = 0; i < 4; i++) begin
            builder.connect($sformatf("SW0_DSP%0d_EP%0d", i, i),
                            "SW0", PCIE_TOPO_PORT_DSP, i,
                            $sformatf("EP%0d", i), PCIE_TOPO_PORT_EP, 0,
                            4, max_gen);
        end
        return builder.finish();
    endfunction
endclass
