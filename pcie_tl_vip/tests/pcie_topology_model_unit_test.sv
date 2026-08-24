import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_topology_model_unit_test extends uvm_test;
    `uvm_component_utils(pcie_topology_model_unit_test)

    function new(string name = "pcie_topology_model_unit_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void require(bit condition, string message);
        if (!condition) `uvm_error("TOPO_COPY", message)
    endfunction

    task run_phase(uvm_phase phase);
        pcie_topology_cfg topology;
        pcie_topology_cfg topology_clone;
        pcie_topology_node_cfg rc0;
        pcie_topology_node_cfg ep0;
        pcie_topology_node_cfg sw0;
        pcie_topology_link_cfg default_link;
        pcie_topology_link_cfg rc0_to_ep0;
        bit clone_shape_valid;

        phase.raise_objection(this);

        default_link = pcie_topology_link_cfg::type_id::create("default_link");
        require(default_link.upstream_port_index == 0,
                "Default upstream port index is not zero");
        require(default_link.downstream_port_index == 0,
                "Default downstream port index is not zero");
        require(default_link.link_width == 4, "Default link width is not 4");
        require(default_link.max_gen == 4, "Default max generation is not 4");
        require(default_link.enabled == 1'b1, "Default link is not enabled");

        topology = pcie_topology_cfg::type_id::create("topology");

        rc0 = pcie_topology_node_cfg::type_id::create("rc0");
        rc0.node_id = "RC0";
        rc0.kind = PCIE_TOPO_NODE_RC;
        topology.nodes.push_back(rc0);

        ep0 = pcie_topology_node_cfg::type_id::create("ep0");
        ep0.node_id = "EP0";
        ep0.kind = PCIE_TOPO_NODE_EP;
        topology.nodes.push_back(ep0);

        sw0 = pcie_topology_node_cfg::type_id::create("sw0");
        sw0.node_id = "SW0";
        sw0.kind = PCIE_TOPO_NODE_SWITCH;
        sw0.num_usp = 1;
        sw0.num_dsp = 1;
        sw0.dsp_owner_usp = new[1];
        sw0.dsp_owner_usp[0] = 0;
        topology.nodes.push_back(sw0);

        rc0_to_ep0 = pcie_topology_link_cfg::type_id::create("rc0_to_ep0");
        rc0_to_ep0.link_id = "RC0_EP0";
        rc0_to_ep0.upstream_node_id = "RC0";
        rc0_to_ep0.upstream_role = PCIE_TOPO_PORT_RC;
        rc0_to_ep0.upstream_port_index = 3;
        rc0_to_ep0.downstream_node_id = "EP0";
        rc0_to_ep0.downstream_role = PCIE_TOPO_PORT_EP;
        rc0_to_ep0.downstream_port_index = 7;
        rc0_to_ep0.link_width = 16;
        rc0_to_ep0.max_gen = 5;
        rc0_to_ep0.enabled = 1'b0;
        topology.links.push_back(rc0_to_ep0);

        require(topology.find_node_index("SW0") == 2,
                "find_node_index did not find SW0");
        require(topology.find_node_index("MISSING") == -1,
                "find_node_index found a missing node");
        require(topology.find_node("EP0") == ep0, "find_node did not return EP0");
        require(topology.find_node("MISSING") == null,
                "find_node returned a missing node");

        default_link.upstream_role = PCIE_TOPO_PORT_EP;
        default_link.copy(rc0_to_ep0);
        require(default_link.upstream_role == PCIE_TOPO_PORT_RC,
                "Link copy did not preserve the upstream role");

        if (!$cast(topology_clone, topology.clone())) begin
            `uvm_error("TOPO_COPY", "Topology clone returned a wrong-typed object")
        end
        else if (topology_clone == null) begin
            `uvm_error("TOPO_COPY", "Topology clone returned null")
        end
        else begin
            clone_shape_valid = 1'b1;
            if (topology_clone.nodes.size() != 3) begin
                `uvm_error("TOPO_COPY", $sformatf("Expected 3 clone nodes, got %0d",
                                                    topology_clone.nodes.size()))
                clone_shape_valid = 1'b0;
            end
            if (topology_clone.links.size() != 1) begin
                `uvm_error("TOPO_COPY", $sformatf("Expected 1 clone link, got %0d",
                                                    topology_clone.links.size()))
                clone_shape_valid = 1'b0;
            end

            if (clone_shape_valid) begin
                foreach (topology_clone.nodes[i]) begin
                    if (topology_clone.nodes[i] == null) begin
                        `uvm_error("TOPO_COPY", $sformatf("Clone node %0d is null", i))
                        clone_shape_valid = 1'b0;
                    end
                end
                if (topology_clone.links[0] == null) begin
                    `uvm_error("TOPO_COPY", "Clone link 0 is null")
                    clone_shape_valid = 1'b0;
                end
            end

            if (clone_shape_valid) begin
                if (topology_clone.nodes[2].dsp_owner_usp.size() != 1) begin
                    `uvm_error("TOPO_COPY", $sformatf(
                        "Expected 1 ownership entry, got %0d",
                        topology_clone.nodes[2].dsp_owner_usp.size()))
                    clone_shape_valid = 1'b0;
                end
            end

            if (clone_shape_valid) begin
                foreach (topology.nodes[i]) begin
                    require(topology_clone.nodes[i] != topology.nodes[i],
                            $sformatf("Clone node %0d aliases its source", i));
                end
                require(topology_clone.links[0] != topology.links[0],
                        "Clone link aliases its source");

                require(topology_clone.nodes[0].node_id == rc0.node_id &&
                        topology_clone.nodes[0].kind == rc0.kind &&
                        topology_clone.nodes[0].num_usp == rc0.num_usp &&
                        topology_clone.nodes[0].num_dsp == rc0.num_dsp &&
                        topology_clone.nodes[0].dsp_owner_usp.size() == 0,
                        "RC0 clone fields differ from source");
                require(topology_clone.nodes[1].node_id == ep0.node_id &&
                        topology_clone.nodes[1].kind == ep0.kind &&
                        topology_clone.nodes[1].num_usp == ep0.num_usp &&
                        topology_clone.nodes[1].num_dsp == ep0.num_dsp &&
                        topology_clone.nodes[1].dsp_owner_usp.size() == 0,
                        "EP0 clone fields differ from source");
                require(topology_clone.nodes[2].node_id == sw0.node_id &&
                        topology_clone.nodes[2].kind == sw0.kind &&
                        topology_clone.nodes[2].num_usp == sw0.num_usp &&
                        topology_clone.nodes[2].num_dsp == sw0.num_dsp &&
                        topology_clone.nodes[2].dsp_owner_usp[0] ==
                            sw0.dsp_owner_usp[0],
                        "SW0 clone fields differ from source");
                require(topology_clone.links[0].link_id == rc0_to_ep0.link_id &&
                        topology_clone.links[0].upstream_node_id ==
                            rc0_to_ep0.upstream_node_id &&
                        topology_clone.links[0].upstream_role == rc0_to_ep0.upstream_role &&
                        topology_clone.links[0].upstream_port_index ==
                            rc0_to_ep0.upstream_port_index &&
                        topology_clone.links[0].downstream_node_id ==
                            rc0_to_ep0.downstream_node_id &&
                        topology_clone.links[0].downstream_role ==
                            rc0_to_ep0.downstream_role &&
                        topology_clone.links[0].downstream_port_index ==
                            rc0_to_ep0.downstream_port_index &&
                        topology_clone.links[0].link_width == rc0_to_ep0.link_width &&
                        topology_clone.links[0].max_gen == rc0_to_ep0.max_gen &&
                        topology_clone.links[0].enabled == rc0_to_ep0.enabled,
                        "Link clone fields differ from source");

                topology_clone.nodes[0].node_id = "RC0_CLONE";
                topology_clone.nodes[2].dsp_owner_usp[0] = 99;
                topology_clone.links[0].link_width = 4;

                require(topology.nodes[0].node_id == "RC0",
                        "Source node ID changed after clone mutation");
                require(topology.nodes[2].dsp_owner_usp[0] == 0,
                        "Source switch ownership changed after clone mutation");
                require(topology.links[0].link_width == 16,
                        "Source link width changed after clone mutation");
            end
        end

        phase.drop_objection(this);
    endtask
endclass
