import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_topology_validation_unit_test extends uvm_test;
    `uvm_component_utils(pcie_topology_validation_unit_test)

    function new(string name = "pcie_topology_validation_unit_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function bit contains_fragment(input string errors[$], string fragment);
        foreach (errors[i]) begin
            if (fragment.len() == 0) return 1'b1;
            if (errors[i].len() >= fragment.len()) begin
                for (int offset = 0;
                     offset <= errors[i].len() - fragment.len(); offset++) begin
                    if (errors[i].substr(offset, offset + fragment.len() - 1) ==
                        fragment) return 1'b1;
                end
            end
        end
        return 1'b0;
    endfunction

    function void require(bit condition, string message);
        if (!condition) `uvm_error("TOPO_VALIDATE", message)
    endfunction

    function void expect_valid(pcie_topology_cfg topology, string label);
        string errors[$];

        topology.validate(errors);
        if (errors.size() != 0) begin
            foreach (errors[i]) begin
                `uvm_error("TOPO_VALIDATE", $sformatf(
                    "%s unexpectedly returned validation error %0d: %s",
                    label, i, errors[i]))
            end
        end
    endfunction

    function void expect_invalid(pcie_topology_cfg topology, string fragment,
                                 string label);
        string errors[$];

        topology.validate(errors);
        if (!contains_fragment(errors, fragment)) begin
            `uvm_error("TOPO_VALIDATE", $sformatf(
                "%s did not return expected validation fragment '%s'",
                label, fragment))
        end
    endfunction

    function pcie_topology_cfg build_valid_switch_2x3(int unsigned max_gen = 5);
        pcie_topology_builder builder;
        int owners[];

        builder = pcie_topology_builder::type_id::create("switch_2x3_builder");
        owners = new[3];
        owners[0] = 0;
        owners[1] = 1;
        owners[2] = 1;
        builder.add_rc("RC0");
        builder.add_rc("RC1");
        builder.add_switch("SW0", 2, 3, owners);
        builder.add_ep("EP0");
        builder.add_ep("EP1");
        builder.add_ep("EP2");
        builder.connect("RC0_SW0_USP0", "RC0", PCIE_TOPO_PORT_RC, 0,
                        "SW0", PCIE_TOPO_PORT_USP, 0, 8, max_gen);
        builder.connect("RC1_SW0_USP1", "RC1", PCIE_TOPO_PORT_RC, 0,
                        "SW0", PCIE_TOPO_PORT_USP, 1, 8, max_gen);
        builder.connect("SW0_DSP0_EP0", "SW0", PCIE_TOPO_PORT_DSP, 0,
                        "EP0", PCIE_TOPO_PORT_EP, 0, 4, max_gen);
        builder.connect("SW0_DSP1_EP1", "SW0", PCIE_TOPO_PORT_DSP, 1,
                        "EP1", PCIE_TOPO_PORT_EP, 0, 4, max_gen);
        builder.connect("SW0_DSP2_EP2", "SW0", PCIE_TOPO_PORT_DSP, 2,
                        "EP2", PCIE_TOPO_PORT_EP, 0, 4, max_gen);
        return builder.finish();
    endfunction

    function pcie_topology_cfg build_empty();
        return pcie_topology_cfg::type_id::create("empty_topology");
    endfunction

    task run_phase(uvm_phase phase);
        pcie_topology_cfg topology;
        pcie_topology_node_cfg node;
        pcie_topology_link_cfg link;
        string first_errors[$];
        string second_errors[$];
        int owners[];

        phase.raise_objection(this);

        expect_valid(pcie_topology_builder::build_ep_x16(4), "EP_X16 Gen4");
        expect_valid(pcie_topology_builder::build_ep_x16(5), "EP_X16 Gen5");
        expect_valid(pcie_topology_builder::build_ep_2x8(4), "EP_2X8 Gen4");
        expect_valid(pcie_topology_builder::build_ep_2x8(5), "EP_2X8 Gen5");
        expect_valid(pcie_topology_builder::build_switch_1x16_4x4(4),
                     "SWITCH_1X16_4X4 Gen4");
        expect_valid(pcie_topology_builder::build_switch_1x16_4x4(5),
                     "SWITCH_1X16_4X4 Gen5");
        expect_valid(build_valid_switch_2x3(), "programmatic 2-USP/3-DSP Switch");

        topology = build_empty();
        expect_invalid(topology, "at least two nodes", "minimum node count");
        expect_invalid(topology, "at least one enabled link", "minimum link count");

        topology = pcie_topology_builder::build_ep_x16(5);
        topology.nodes[0] = null;
        expect_invalid(topology, "node 0 is null", "null node");

        topology = pcie_topology_builder::build_ep_x16(5);
        topology.nodes[0].node_id = "";
        expect_invalid(topology, "node 0 has an empty ID", "empty node ID");

        topology = pcie_topology_builder::build_ep_x16(5);
        topology.nodes[1].node_id = "RC0";
        expect_invalid(topology, "duplicate node ID", "duplicate node ID");

        topology = pcie_topology_builder::build_ep_x16(5);
        topology.links[0] = null;
        expect_invalid(topology, "link 0 is null", "null link");

        topology = pcie_topology_builder::build_ep_x16(5);
        topology.links[0].link_id = "";
        expect_invalid(topology, "link 0 has an empty ID", "empty link ID");

        topology = pcie_topology_builder::build_ep_x16(5);
        link = pcie_topology_link_cfg::type_id::create("duplicate_link");
        link.copy(topology.links[0]);
        link.link_id = topology.links[0].link_id;
        link.enabled = 1'b0;
        topology.links.push_back(link);
        expect_invalid(topology, "duplicate link ID", "duplicate link ID");

        topology = pcie_topology_builder::build_ep_x16(5);
        topology.links[0].upstream_node_id = "MISSING_RC";
        expect_invalid(topology, "unknown upstream node", "missing endpoint node");

        topology = pcie_topology_builder::build_ep_x16(5);
        topology.links[0].upstream_role = PCIE_TOPO_PORT_DSP;
        expect_invalid(topology, "role does not match", "node/role mismatch");

        topology = pcie_topology_builder::build_ep_x16(5);
        topology.links[0].upstream_port_index = 1;
        expect_invalid(topology, "port index", "RC port index range");

        topology = pcie_topology_builder::build_ep_x16(5);
        topology.links[0].downstream_port_index = 1;
        expect_invalid(topology, "port index", "EP port index range");

        topology = build_valid_switch_2x3();
        topology.links[0].downstream_port_index = 2;
        expect_invalid(topology, "port index", "Switch USP index range");

        topology = build_valid_switch_2x3();
        topology.links[2].upstream_port_index = 3;
        expect_invalid(topology, "port index", "Switch DSP index range");

        topology = pcie_topology_builder::build_ep_x16(5);
        topology.links[0].link_width = 2;
        expect_invalid(topology, "unsupported width", "enabled invalid width");

        topology = pcie_topology_builder::build_ep_x16(5);
        topology.links[0].max_gen = 6;
        expect_invalid(topology, "unsupported max_gen", "enabled invalid generation");

        topology = pcie_topology_builder::build_ep_x16(5);
        topology.links[0].upstream_node_id = "EP0";
        topology.links[0].upstream_role = PCIE_TOPO_PORT_EP;
        topology.links[0].downstream_node_id = "RC0";
        topology.links[0].downstream_role = PCIE_TOPO_PORT_RC;
        expect_invalid(topology, "unsupported phase-one form", "unsupported orientation");

        topology = pcie_topology_builder::build_ep_2x8(5);
        topology.links[1].upstream_node_id = "RC0";
        expect_invalid(topology, "reuses physical port", "enabled physical port reuse");

        topology = pcie_topology_builder::build_ep_x16(5);
        node = pcie_topology_node_cfg::type_id::create("disabled_only_ep");
        node.node_id = "EP_DISABLED";
        node.kind = PCIE_TOPO_NODE_EP;
        topology.nodes.push_back(node);
        link = pcie_topology_link_cfg::type_id::create("disabled_extra");
        link.link_id = "RC0_EP_DISABLED";
        link.upstream_node_id = "RC0";
        link.upstream_role = PCIE_TOPO_PORT_RC;
        link.downstream_node_id = "EP_DISABLED";
        link.downstream_role = PCIE_TOPO_PORT_EP;
        link.link_width = 16;
        link.max_gen = 5;
        link.enabled = 1'b0;
        topology.links.push_back(link);
        expect_invalid(topology, "isolated", "disabled-only node isolation");
        expect_invalid(topology, "exactly one enabled parent",
                       "Endpoint with no enabled parent");
        topology = pcie_topology_builder::build_ep_x16(5);
        link = pcie_topology_link_cfg::type_id::create("second_parent");
        link.copy(topology.links[0]);
        link.link_id = "RC0_EP0_SECOND";
        topology.links.push_back(link);
        expect_invalid(topology, "exactly one enabled parent",
                       "Endpoint with duplicate enabled parents");

        topology = pcie_topology_builder::build_ep_x16(5);
        topology.nodes[0].num_usp = 1;
        expect_invalid(topology, "Switch-only state", "RC Switch-only metadata");

        topology = pcie_topology_builder::build_ep_2x8(5);
        topology.links[1].enabled = 1'b0;
        expect_invalid(topology, "direct topology", "lossy direct graph");

        topology = pcie_topology_builder::build_switch_1x16_4x4(5);
        node = pcie_topology_node_cfg::type_id::create("RC_DIRECT");
        node.node_id = "RC_DIRECT";
        node.kind = PCIE_TOPO_NODE_RC;
        topology.nodes.push_back(node);
        node = pcie_topology_node_cfg::type_id::create("EP_DIRECT");
        node.node_id = "EP_DIRECT";
        node.kind = PCIE_TOPO_NODE_EP;
        topology.nodes.push_back(node);
        link = pcie_topology_link_cfg::type_id::create("direct_mixed_link");
        link.link_id = "RC_DIRECT_EP_DIRECT";
        link.upstream_node_id = "RC_DIRECT";
        link.upstream_role = PCIE_TOPO_PORT_RC;
        link.downstream_node_id = "EP_DIRECT";
        link.downstream_role = PCIE_TOPO_PORT_EP;
        link.link_width = 4;
        link.max_gen = 5;
        topology.links.push_back(link);
        expect_invalid(topology, "mixes direct and Switch", "mixed topology forms");

        topology = pcie_topology_builder::build_switch_1x16_4x4(5);
        owners = new[1];
        owners[0] = 0;
        node = pcie_topology_node_cfg::type_id::create("SW1");
        node.node_id = "SW1";
        node.kind = PCIE_TOPO_NODE_SWITCH;
        node.num_usp = 1;
        node.num_dsp = 1;
        node.dsp_owner_usp = new[1](owners);
        topology.nodes.push_back(node);
        expect_invalid(topology, "multiple Switch nodes", "multiple Switch topology");

        topology = build_valid_switch_2x3();
        node = pcie_topology_node_cfg::type_id::create("SW1");
        node.node_id = "SW1";
        node.kind = PCIE_TOPO_NODE_SWITCH;
        node.num_usp = 1;
        node.num_dsp = 1;
        node.dsp_owner_usp = new[1];
        node.dsp_owner_usp[0] = 0;
        topology.nodes.push_back(node);
        link = pcie_topology_link_cfg::type_id::create("cascade_link");
        link.link_id = "SW0_DSP0_SW1_USP0";
        link.upstream_node_id = "SW0";
        link.upstream_role = PCIE_TOPO_PORT_DSP;
        link.upstream_port_index = 0;
        link.downstream_node_id = "SW1";
        link.downstream_role = PCIE_TOPO_PORT_USP;
        link.downstream_port_index = 0;
        link.link_width = 4;
        link.max_gen = 5;
        topology.links.push_back(link);
        expect_invalid(topology, "Switch cascading", "Switch cascade");

        topology = build_valid_switch_2x3();
        topology.nodes[2].num_usp = 0;
        expect_invalid(topology, "nonzero USP", "zero USP declaration");

        topology = build_valid_switch_2x3();
        topology.nodes[2].num_dsp = 0;
        expect_invalid(topology, "nonzero DSP", "zero DSP declaration");

        topology = build_valid_switch_2x3();
        topology.links[1].enabled = 1'b0;
        expect_invalid(topology, "USP 1", "missing enabled USP link");

        topology = build_valid_switch_2x3();
        topology.links[4].enabled = 1'b0;
        expect_invalid(topology, "DSP 2", "missing enabled DSP link");

        topology = build_valid_switch_2x3();
        topology.nodes[2].dsp_owner_usp = new[2];
        topology.nodes[2].dsp_owner_usp[0] = 0;
        topology.nodes[2].dsp_owner_usp[1] = 1;
        expect_invalid(topology, "owner count", "owner array size");

        topology = build_valid_switch_2x3();
        topology.nodes[2].dsp_owner_usp[2] = 2;
        expect_invalid(topology, "owner index", "owner index range");

        topology = build_valid_switch_2x3();
        topology.nodes[2].dsp_owner_usp[0] = 1;
        expect_invalid(topology, "owns no DSP", "USP without an owned DSP");

        topology = pcie_topology_builder::build_ep_x16(5);
        link = pcie_topology_link_cfg::type_id::create("malformed_disabled");
        link.link_id = "MALFORMED_DISABLED";
        link.upstream_node_id = "MISSING_UP";
        link.upstream_role = PCIE_TOPO_PORT_RC;
        link.downstream_node_id = "MISSING_DOWN";
        link.downstream_role = PCIE_TOPO_PORT_EP;
        link.link_width = 32;
        link.max_gen = 3;
        link.enabled = 1'b0;
        topology.links.push_back(link);
        expect_invalid(topology, "unsupported width", "disabled structural width");
        expect_invalid(topology, "unsupported max_gen", "disabled structural generation");
        expect_invalid(topology, "unknown upstream node", "disabled structural endpoint");

        topology = pcie_topology_builder::build_ep_x16(5);
        node = pcie_topology_node_cfg::type_id::create("disabled_valid_ep");
        node.node_id = "EP_DISABLED";
        node.kind = PCIE_TOPO_NODE_EP;
        topology.nodes.push_back(node);
        link = pcie_topology_link_cfg::type_id::create("valid_disabled");
        link.link_id = "RC0_EP_DISABLED";
        link.upstream_node_id = "RC0";
        link.upstream_role = PCIE_TOPO_PORT_RC;
        link.downstream_node_id = "EP_DISABLED";
        link.downstream_role = PCIE_TOPO_PORT_EP;
        link.link_width = 16;
        link.max_gen = 5;
        link.enabled = 1'b0;
        topology.links.push_back(link);
        topology.validate(first_errors);
        require(contains_fragment(first_errors, "isolated"),
                "valid disabled link did not leave its extra node isolated");
        require(!contains_fragment(first_errors, "reuses physical port"),
                "valid disabled link incorrectly triggered active port reuse");

        topology = pcie_topology_builder::build_ep_x16(5);
        topology.nodes[0].node_id = "";
        topology.links[0].link_width = 1;
        topology.links[0].max_gen = 9;
        topology.validate(first_errors);
        require(contains_fragment(first_errors, "empty ID") &&
                contains_fragment(first_errors, "unsupported width") &&
                contains_fragment(first_errors, "unsupported max_gen"),
                "multiple independent corruptions were not all collected");
        topology.validate(second_errors);
        require(first_errors.size() == second_errors.size(),
                "repeat validation returned a different error count");
        if (first_errors.size() == second_errors.size()) begin
            foreach (first_errors[i]) begin
                require(first_errors[i] == second_errors[i], $sformatf(
                    "repeat validation changed error %0d: '%s' versus '%s'",
                    i, first_errors[i], second_errors[i]));
            end
        end

        phase.drop_objection(this);
    endtask
endclass
