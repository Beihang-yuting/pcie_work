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

    task run_phase(uvm_phase phase);
        pcie_topology_cfg topology;
        pcie_topology_cfg topology_clone;
        pcie_topology_node_cfg rc0;
        pcie_topology_node_cfg ep0;
        pcie_topology_node_cfg sw0;
        pcie_topology_link_cfg rc0_to_ep0;

        phase.raise_objection(this);

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
        rc0_to_ep0.upstream_port_index = 0;
        rc0_to_ep0.downstream_node_id = "EP0";
        rc0_to_ep0.downstream_role = PCIE_TOPO_PORT_EP;
        rc0_to_ep0.downstream_port_index = 0;
        topology.links.push_back(rc0_to_ep0);

        if (!$cast(topology_clone, topology.clone())) begin
            `uvm_error("TOPO_COPY", "Topology clone returned a wrong-typed object")
        end
        else if (topology_clone == null) begin
            `uvm_error("TOPO_COPY", "Topology clone returned null")
        end
        else begin
            if (topology_clone.nodes.size() != 3)
                `uvm_error("TOPO_COPY", $sformatf("Expected 3 clone nodes, got %0d",
                                                    topology_clone.nodes.size()))
            if (topology_clone.links.size() != 1)
                `uvm_error("TOPO_COPY", $sformatf("Expected 1 clone link, got %0d",
                                                    topology_clone.links.size()))

            topology_clone.nodes[0].node_id = "RC0_CLONE";
            topology_clone.nodes[2].dsp_owner_usp[0] = 99;
            topology_clone.links[0].link_width = 8;

            if (topology.nodes[0].node_id != "RC0")
                `uvm_error("TOPO_COPY", "Source node ID changed after clone mutation")
            if (topology.nodes[2].dsp_owner_usp[0] != 0)
                `uvm_error("TOPO_COPY", "Source switch ownership changed after clone mutation")
            if (topology.links[0].link_width != 4)
                `uvm_error("TOPO_COPY", "Source link width changed after clone mutation")
        end

        phase.drop_objection(this);
    endtask
endclass
