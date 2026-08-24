import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_topology_builder_unit_test extends uvm_test;
    `uvm_component_utils(pcie_topology_builder_unit_test)

    function new(string name = "pcie_topology_builder_unit_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void require(bit condition, string message);
        if (!condition) `uvm_error("TOPO_BUILDER", message)
    endfunction

    function void check_node(pcie_topology_cfg topology, int index,
                             string expected_id,
                             pcie_topology_node_kind_e expected_kind,
                             int unsigned expected_num_usp,
                             int unsigned expected_num_dsp,
                             input int expected_owners[]);
        pcie_topology_node_cfg node;

        if (topology == null) begin
            `uvm_error("TOPO_BUILDER", "Topology is null while checking node")
            return;
        end
        if ((index < 0) || (index >= topology.nodes.size())) begin
            `uvm_error("TOPO_BUILDER", $sformatf("Node index %0d is out of range", index))
            return;
        end
        if (topology.nodes[index] == null) begin
            `uvm_error("TOPO_BUILDER", $sformatf("Node %0d is null", index))
            return;
        end
        node = topology.nodes[index];
        require(node.node_id == expected_id,
                $sformatf("Node %0d ID expected %s, got %s", index, expected_id,
                          node.node_id));
        require(node.kind == expected_kind,
                $sformatf("Node %s kind expected %0d, got %0d", expected_id,
                          expected_kind, node.kind));
        require(node.num_usp == expected_num_usp,
                $sformatf("Node %s USP count expected %0d, got %0d", expected_id,
                          expected_num_usp, node.num_usp));
        require(node.num_dsp == expected_num_dsp,
                $sformatf("Node %s DSP count expected %0d, got %0d", expected_id,
                          expected_num_dsp, node.num_dsp));
        require(node.dsp_owner_usp.size() == expected_owners.size(),
                $sformatf("Node %s ownership count expected %0d, got %0d",
                          expected_id, expected_owners.size(),
                          node.dsp_owner_usp.size()));
        if (node.dsp_owner_usp.size() == expected_owners.size()) begin
            foreach (expected_owners[i]) begin
                require(node.dsp_owner_usp[i] == expected_owners[i],
                        $sformatf("Node %s owner %0d expected %0d, got %0d",
                                  expected_id, i, expected_owners[i],
                                  node.dsp_owner_usp[i]));
            end
        end
    endfunction

    function void check_link(
        pcie_topology_cfg topology, int index, string expected_id,
        string expected_upstream_node_id,
        pcie_topology_port_role_e expected_upstream_role,
        int unsigned expected_upstream_port_index,
        string expected_downstream_node_id,
        pcie_topology_port_role_e expected_downstream_role,
        int unsigned expected_downstream_port_index,
        int unsigned expected_link_width, int unsigned expected_max_gen,
        bit expected_enabled);
        pcie_topology_link_cfg link;

        if (topology == null) begin
            `uvm_error("TOPO_BUILDER", "Topology is null while checking link")
            return;
        end
        if ((index < 0) || (index >= topology.links.size())) begin
            `uvm_error("TOPO_BUILDER", $sformatf("Link index %0d is out of range", index))
            return;
        end
        link = topology.links[index];
        if (link == null) begin
            `uvm_error("TOPO_BUILDER", $sformatf("Link %0d is null", index))
            return;
        end
        require(link.link_id == expected_id,
                $sformatf("Link %0d ID expected %s, got %s", index, expected_id,
                          link.link_id));
        require(link.upstream_node_id == expected_upstream_node_id,
                $sformatf("Link %s upstream node expected %s, got %s",
                          expected_id, expected_upstream_node_id,
                          link.upstream_node_id));
        require(link.upstream_role == expected_upstream_role,
                $sformatf("Link %s upstream role expected %0d, got %0d",
                          expected_id, expected_upstream_role,
                          link.upstream_role));
        require(link.upstream_port_index == expected_upstream_port_index,
                $sformatf("Link %s upstream port expected %0d, got %0d",
                          expected_id, expected_upstream_port_index,
                          link.upstream_port_index));
        require(link.downstream_node_id == expected_downstream_node_id,
                $sformatf("Link %s downstream node expected %s, got %s",
                          expected_id, expected_downstream_node_id,
                          link.downstream_node_id));
        require(link.downstream_role == expected_downstream_role,
                $sformatf("Link %s downstream role expected %0d, got %0d",
                          expected_id, expected_downstream_role,
                          link.downstream_role));
        require(link.downstream_port_index == expected_downstream_port_index,
                $sformatf("Link %s downstream port expected %0d, got %0d",
                          expected_id, expected_downstream_port_index,
                          link.downstream_port_index));
        require(link.link_width == expected_link_width,
                $sformatf("Link %s width expected %0d, got %0d", expected_id,
                          expected_link_width, link.link_width));
        require(link.max_gen == expected_max_gen,
                $sformatf("Link %s max generation expected %0d, got %0d",
                          expected_id, expected_max_gen, link.max_gen));
        require(link.enabled == expected_enabled,
                $sformatf("Link %s enabled expected %0b, got %0b", expected_id,
                          expected_enabled, link.enabled));
    endfunction

    task run_phase(uvm_phase phase);
        pcie_topology_builder builder;
        pcie_topology_cfg topology;
        pcie_topology_node_cfg switch_node;
        pcie_topology_node_cfg explicit_node;
        pcie_topology_link_cfg disabled_link;
        int owners[];
        int no_owners[];
        int switch_owners[];
        int programmatic_switch_owners[];

        phase.raise_objection(this);
        no_owners = new[0];
        switch_owners = new[4];
        foreach (switch_owners[i]) switch_owners[i] = 0;
        programmatic_switch_owners = new[2];
        programmatic_switch_owners[0] = 0;
        programmatic_switch_owners[1] = 1;

        topology = pcie_topology_builder::build_ep_x16(5);
        if (topology != null) begin
            require(topology.get_name() == "ep_x16_builder_cfg",
                    $sformatf("EP_X16 topology name expected ep_x16_builder_cfg, got %s",
                              topology.get_name()));
            require(topology.nodes.size() == 2,
                    $sformatf("EP_X16 expected 2 nodes, got %0d", topology.nodes.size()));
            require(topology.links.size() == 1,
                    $sformatf("EP_X16 expected 1 link, got %0d", topology.links.size()));
        end
        check_node(topology, 0, "RC0", PCIE_TOPO_NODE_RC, 0, 0, no_owners);
        check_node(topology, 1, "EP0", PCIE_TOPO_NODE_EP, 0, 0, no_owners);
        check_link(topology, 0, "RC0_EP0", "RC0", PCIE_TOPO_PORT_RC, 0,
                   "EP0", PCIE_TOPO_PORT_EP, 0, 16, 5, 1'b1);

        topology = pcie_topology_builder::build_ep_2x8(4);
        if (topology != null) begin
            require(topology.get_name() == "ep_2x8_builder_cfg",
                    $sformatf("EP_2X8 topology name expected ep_2x8_builder_cfg, got %s",
                              topology.get_name()));
            require(topology.nodes.size() == 4,
                    $sformatf("EP_2X8 expected 4 nodes, got %0d", topology.nodes.size()));
            require(topology.links.size() == 2,
                    $sformatf("EP_2X8 expected 2 links, got %0d", topology.links.size()));
        end
        check_node(topology, 0, "RC0", PCIE_TOPO_NODE_RC, 0, 0, no_owners);
        check_node(topology, 1, "EP0", PCIE_TOPO_NODE_EP, 0, 0, no_owners);
        check_node(topology, 2, "RC1", PCIE_TOPO_NODE_RC, 0, 0, no_owners);
        check_node(topology, 3, "EP1", PCIE_TOPO_NODE_EP, 0, 0, no_owners);
        check_link(topology, 0, "RC0_EP0", "RC0", PCIE_TOPO_PORT_RC, 0,
                   "EP0", PCIE_TOPO_PORT_EP, 0, 8, 4, 1'b1);
        check_link(topology, 1, "RC1_EP1", "RC1", PCIE_TOPO_PORT_RC, 0,
                   "EP1", PCIE_TOPO_PORT_EP, 0, 8, 4, 1'b1);

        topology = pcie_topology_builder::build_switch_1x16_4x4(5);
        if (topology != null) begin
            require(topology.get_name() == "switch_1x16_4x4_builder_cfg",
                    $sformatf("Switch topology name expected switch_1x16_4x4_builder_cfg, got %s",
                              topology.get_name()));
            require(topology.nodes.size() == 6,
                    $sformatf("Switch profile expected 6 nodes, got %0d",
                              topology.nodes.size()));
            require(topology.links.size() == 5,
                    $sformatf("Switch profile expected 5 links, got %0d",
                              topology.links.size()));
        end
        check_node(topology, 0, "RC0", PCIE_TOPO_NODE_RC, 0, 0, no_owners);
        check_node(topology, 1, "SW0", PCIE_TOPO_NODE_SWITCH, 1, 4,
                   switch_owners);
        check_node(topology, 2, "EP0", PCIE_TOPO_NODE_EP, 0, 0, no_owners);
        check_node(topology, 3, "EP1", PCIE_TOPO_NODE_EP, 0, 0, no_owners);
        check_node(topology, 4, "EP2", PCIE_TOPO_NODE_EP, 0, 0, no_owners);
        check_node(topology, 5, "EP3", PCIE_TOPO_NODE_EP, 0, 0, no_owners);
        check_link(topology, 0, "RC0_SW0_USP0", "RC0", PCIE_TOPO_PORT_RC, 0,
                   "SW0", PCIE_TOPO_PORT_USP, 0, 16, 5, 1'b1);
        check_link(topology, 1, "SW0_DSP0_EP0", "SW0", PCIE_TOPO_PORT_DSP, 0,
                   "EP0", PCIE_TOPO_PORT_EP, 0, 4, 5, 1'b1);
        check_link(topology, 2, "SW0_DSP1_EP1", "SW0", PCIE_TOPO_PORT_DSP, 1,
                   "EP1", PCIE_TOPO_PORT_EP, 0, 4, 5, 1'b1);
        check_link(topology, 3, "SW0_DSP2_EP2", "SW0", PCIE_TOPO_PORT_DSP, 2,
                   "EP2", PCIE_TOPO_PORT_EP, 0, 4, 5, 1'b1);
        check_link(topology, 4, "SW0_DSP3_EP3", "SW0", PCIE_TOPO_PORT_DSP, 3,
                   "EP3", PCIE_TOPO_PORT_EP, 0, 4, 5, 1'b1);

        builder = pcie_topology_builder::type_id::create("programmatic_builder");
        require(builder != null, "Factory did not create the builder");
        if (builder != null) begin
            require(builder.topology.get_name() == "programmatic_builder_cfg",
                    $sformatf("Programmatic topology name expected programmatic_builder_cfg, got %s",
                              builder.topology.get_name()));
            explicit_node = builder.add_node("EXPLICIT_EP", PCIE_TOPO_NODE_EP);
            require(explicit_node != null, "add_node returned null");
            require(builder.add_rc("RC_API") != null, "add_rc returned null");
            require(builder.add_ep("EP_API") != null, "add_ep returned null");

            owners = new[2];
            owners[0] = 0;
            owners[1] = 1;
            switch_node = builder.add_switch("SW_API", 2, 2, owners);
            require(switch_node != null, "add_switch returned null");
            owners[0] = 9;
            if (switch_node != null) begin
                require(switch_node.num_usp == 2,
                        $sformatf("SW_API USP count expected 2, got %0d",
                                  switch_node.num_usp));
                require(switch_node.num_dsp == 2,
                        $sformatf("SW_API DSP count expected 2, got %0d",
                                  switch_node.num_dsp));
                require(switch_node.dsp_owner_usp.size() == 2,
                        $sformatf("SW_API ownership count expected 2, got %0d",
                                  switch_node.dsp_owner_usp.size()));
                if (switch_node.dsp_owner_usp.size() == 2) begin
                    require(switch_node.dsp_owner_usp[0] == 0,
                            $sformatf("SW_API owner 0 expected 0 after caller mutation, got %0d",
                                      switch_node.dsp_owner_usp[0]));
                    require(switch_node.dsp_owner_usp[1] == 1,
                            $sformatf("SW_API owner 1 expected 1, got %0d",
                                      switch_node.dsp_owner_usp[1]));
                end
            end

            disabled_link = builder.connect("RC_API_SW_API", "RC_API",
                                            PCIE_TOPO_PORT_RC, 0, "SW_API",
                                            PCIE_TOPO_PORT_USP, 1, 8, 4, 1'b0);
            require(disabled_link != null, "connect returned null");
            topology = builder.finish();
            require(topology == builder.topology,
                    "finish did not return the builder topology");
            if (topology != null) begin
                require(topology.nodes.size() == 4,
                        $sformatf("Programmatic API expected 4 nodes, got %0d",
                                  topology.nodes.size()));
                require(topology.links.size() == 1,
                        $sformatf("Programmatic API expected 1 link, got %0d",
                                  topology.links.size()));
            end
            check_node(topology, 0, "EXPLICIT_EP", PCIE_TOPO_NODE_EP,
                       0, 0, no_owners);
            check_node(topology, 1, "RC_API", PCIE_TOPO_NODE_RC,
                       0, 0, no_owners);
            check_node(topology, 2, "EP_API", PCIE_TOPO_NODE_EP,
                       0, 0, no_owners);
            check_node(topology, 3, "SW_API", PCIE_TOPO_NODE_SWITCH,
                       2, 2, programmatic_switch_owners);
            check_link(topology, 0, "RC_API_SW_API", "RC_API",
                       PCIE_TOPO_PORT_RC, 0, "SW_API", PCIE_TOPO_PORT_USP, 1,
                       8, 4, 1'b0);
        end

        phase.drop_objection(this);
    endtask
endclass
