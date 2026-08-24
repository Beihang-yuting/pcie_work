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

    protected function int node_id_match_count(string node_id);
        int count;

        count = 0;
        foreach (nodes[i]) begin
            if ((nodes[i] != null) && (nodes[i].node_id == node_id)) count++;
        end
        return count;
    endfunction

    protected function int resolve_unique_node_index(string node_id);
        int index;

        index = -1;
        foreach (nodes[i]) begin
            if ((nodes[i] != null) && (nodes[i].node_id == node_id)) begin
                if (index >= 0) return -1;
                index = i;
            end
        end
        return index;
    endfunction

    protected function bit same_endpoint(
        pcie_topology_link_cfg lhs, bit lhs_downstream,
        pcie_topology_link_cfg rhs, bit rhs_downstream);
        string lhs_node_id;
        string rhs_node_id;
        pcie_topology_port_role_e lhs_role;
        pcie_topology_port_role_e rhs_role;
        int unsigned lhs_port_index;
        int unsigned rhs_port_index;

        if ((lhs == null) || (rhs == null)) return 1'b0;
        if (lhs_downstream) begin
            lhs_node_id = lhs.downstream_node_id;
            lhs_role = lhs.downstream_role;
            lhs_port_index = lhs.downstream_port_index;
        end
        else begin
            lhs_node_id = lhs.upstream_node_id;
            lhs_role = lhs.upstream_role;
            lhs_port_index = lhs.upstream_port_index;
        end
        if (rhs_downstream) begin
            rhs_node_id = rhs.downstream_node_id;
            rhs_role = rhs.downstream_role;
            rhs_port_index = rhs.downstream_port_index;
        end
        else begin
            rhs_node_id = rhs.upstream_node_id;
            rhs_role = rhs.upstream_role;
            rhs_port_index = rhs.upstream_port_index;
        end
        return (lhs_node_id == rhs_node_id) && (lhs_role == rhs_role) &&
               (lhs_port_index == rhs_port_index);
    endfunction

    virtual function void do_copy(uvm_object rhs);
        pcie_topology_cfg rhs_;
        pcie_topology_node_cfg node_copy;
        pcie_topology_link_cfg link_copy;

        super.do_copy(rhs);
        if (!$cast(rhs_, rhs)) begin
            `uvm_fatal("TOPO_COPY", "topology copy source has wrong type")
            return;
        end

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
        int enabled_link_count;
        int switch_count;
        int rc_count;
        int ep_count;
        int direct_link_count;
        int rc_switch_link_count;
        int switch_ep_link_count;
        int enabled_degree[];
        int ep_parent_count[];
        int upstream_index;
        int downstream_index;
        int upstream_match_count;
        int downstream_match_count;
        int port_link_count;
        int owner_count;
        int switch_index;
        bit upstream_valid;
        bit downstream_valid;
        bit supported_form;

        errors.delete();
        enabled_link_count = 0;
        switch_count = 0;
        rc_count = 0;
        ep_count = 0;
        direct_link_count = 0;
        rc_switch_link_count = 0;
        switch_ep_link_count = 0;
        switch_index = -1;
        enabled_degree = new[nodes.size()];
        ep_parent_count = new[nodes.size()];

        if (nodes.size() < 2) begin
            errors.push_back($sformatf(
                "topology requires at least two nodes; found %0d", nodes.size()));
        end

        foreach (nodes[i]) begin
            if (nodes[i] == null) begin
                errors.push_back($sformatf("node %0d is null", i));
                continue;
            end

            if (nodes[i].node_id == "") begin
                errors.push_back($sformatf("node %0d has an empty ID", i));
            end
            else begin
                for (int j = 0; j < i; j++) begin
                    if ((nodes[j] != null) &&
                        (nodes[j].node_id == nodes[i].node_id)) begin
                        errors.push_back($sformatf(
                            "duplicate node ID '%s' at nodes %0d and %0d",
                            nodes[i].node_id, j, i));
                        break;
                    end
                end
            end

            case (nodes[i].kind)
                PCIE_TOPO_NODE_RC: begin
                    rc_count++;
                    if ((nodes[i].num_usp != 0) || (nodes[i].num_dsp != 0) ||
                        (nodes[i].dsp_owner_usp.size() != 0)) begin
                        errors.push_back($sformatf(
                            "node '%s' is an RC but carries Switch-only state",
                            nodes[i].node_id));
                    end
                end
                PCIE_TOPO_NODE_EP: begin
                    ep_count++;
                    if ((nodes[i].num_usp != 0) || (nodes[i].num_dsp != 0) ||
                        (nodes[i].dsp_owner_usp.size() != 0)) begin
                        errors.push_back($sformatf(
                            "node '%s' is an Endpoint but carries Switch-only state",
                            nodes[i].node_id));
                    end
                end
                PCIE_TOPO_NODE_SWITCH: begin
                    switch_count++;
                    if (switch_index < 0) switch_index = i;
                    if (nodes[i].num_usp == 0) begin
                        errors.push_back($sformatf(
                            "Switch '%s' must declare a nonzero USP count",
                            nodes[i].node_id));
                    end
                    if (nodes[i].num_dsp == 0) begin
                        errors.push_back($sformatf(
                            "Switch '%s' must declare a nonzero DSP count",
                            nodes[i].node_id));
                    end
                    if (nodes[i].dsp_owner_usp.size() != nodes[i].num_dsp) begin
                        errors.push_back($sformatf(
                            "Switch '%s' owner count %0d does not match DSP count %0d",
                            nodes[i].node_id, nodes[i].dsp_owner_usp.size(),
                            nodes[i].num_dsp));
                    end
                    foreach (nodes[i].dsp_owner_usp[dsp]) begin
                        if ((nodes[i].dsp_owner_usp[dsp] < 0) ||
                            (nodes[i].dsp_owner_usp[dsp] >= nodes[i].num_usp)) begin
                            errors.push_back($sformatf(
                                "Switch '%s' DSP %0d owner index %0d is outside [0,%0d)",
                                nodes[i].node_id, dsp,
                                nodes[i].dsp_owner_usp[dsp], nodes[i].num_usp));
                        end
                    end
                    for (longint unsigned usp = 0;
                         usp < nodes[i].num_usp; usp++) begin
                        owner_count = 0;
                        foreach (nodes[i].dsp_owner_usp[dsp]) begin
                            if (nodes[i].dsp_owner_usp[dsp] == usp) owner_count++;
                        end
                        if (owner_count == 0) begin
                            errors.push_back($sformatf(
                                "Switch '%s' USP %0d owns no DSP", nodes[i].node_id,
                                usp));
                        end
                    end
                end
                default: begin
                    errors.push_back($sformatf(
                        "node '%s' has an unsupported node kind", nodes[i].node_id));
                end
            endcase
        end

        if (switch_count > 1) begin
            errors.push_back($sformatf(
                "topology contains multiple Switch nodes (%0d); exactly one is supported",
                switch_count));
        end

        foreach (links[i]) begin
            if (links[i] == null) begin
                errors.push_back($sformatf("link %0d is null", i));
                continue;
            end

            if (links[i].link_id == "") begin
                errors.push_back($sformatf("link %0d has an empty ID", i));
            end
            else begin
                for (int j = 0; j < i; j++) begin
                    if ((links[j] != null) &&
                        (links[j].link_id == links[i].link_id)) begin
                        errors.push_back($sformatf(
                            "duplicate link ID '%s' at links %0d and %0d",
                            links[i].link_id, j, i));
                        break;
                    end
                end
            end

            if (!((links[i].link_width == 4) || (links[i].link_width == 8) ||
                  (links[i].link_width == 16))) begin
                errors.push_back($sformatf(
                    "link '%s' has unsupported width x%0d",
                    links[i].link_id, links[i].link_width));
            end
            if (!((links[i].max_gen == 4) || (links[i].max_gen == 5))) begin
                errors.push_back($sformatf(
                    "link '%s' has unsupported max_gen %0d",
                    links[i].link_id, links[i].max_gen));
            end

            upstream_match_count = node_id_match_count(links[i].upstream_node_id);
            downstream_match_count = node_id_match_count(links[i].downstream_node_id);
            upstream_index = resolve_unique_node_index(links[i].upstream_node_id);
            downstream_index = resolve_unique_node_index(links[i].downstream_node_id);
            upstream_valid = (upstream_match_count == 1) && (upstream_index >= 0);
            downstream_valid = (downstream_match_count == 1) &&
                               (downstream_index >= 0);

            if (upstream_match_count == 0) begin
                errors.push_back($sformatf(
                    "link '%s' names unknown upstream node '%s'",
                    links[i].link_id, links[i].upstream_node_id));
            end
            else if (upstream_match_count > 1) begin
                errors.push_back($sformatf(
                    "link '%s' has ambiguous upstream node ID '%s'",
                    links[i].link_id, links[i].upstream_node_id));
            end
            if (downstream_match_count == 0) begin
                errors.push_back($sformatf(
                    "link '%s' names unknown downstream node '%s'",
                    links[i].link_id, links[i].downstream_node_id));
            end
            else if (downstream_match_count > 1) begin
                errors.push_back($sformatf(
                    "link '%s' has ambiguous downstream node ID '%s'",
                    links[i].link_id, links[i].downstream_node_id));
            end

            if (upstream_valid) begin
                case (nodes[upstream_index].kind)
                    PCIE_TOPO_NODE_RC: begin
                        if (links[i].upstream_role != PCIE_TOPO_PORT_RC) begin
                            errors.push_back($sformatf(
                                "link '%s' upstream role does not match RC node '%s'",
                                links[i].link_id, nodes[upstream_index].node_id));
                        end
                        else if (links[i].upstream_port_index != 0) begin
                            errors.push_back($sformatf(
                                "link '%s' upstream RC port index %0d must be 0",
                                links[i].link_id, links[i].upstream_port_index));
                        end
                    end
                    PCIE_TOPO_NODE_EP: begin
                        if (links[i].upstream_role != PCIE_TOPO_PORT_EP) begin
                            errors.push_back($sformatf(
                                "link '%s' upstream role does not match Endpoint node '%s'",
                                links[i].link_id, nodes[upstream_index].node_id));
                        end
                        else if (links[i].upstream_port_index != 0) begin
                            errors.push_back($sformatf(
                                "link '%s' upstream Endpoint port index %0d must be 0",
                                links[i].link_id, links[i].upstream_port_index));
                        end
                    end
                    PCIE_TOPO_NODE_SWITCH: begin
                        if (!((links[i].upstream_role == PCIE_TOPO_PORT_USP) ||
                              (links[i].upstream_role == PCIE_TOPO_PORT_DSP))) begin
                            errors.push_back($sformatf(
                                "link '%s' upstream role does not match Switch node '%s'",
                                links[i].link_id, nodes[upstream_index].node_id));
                        end
                        else if ((links[i].upstream_role == PCIE_TOPO_PORT_USP) &&
                                 (links[i].upstream_port_index >=
                                  nodes[upstream_index].num_usp)) begin
                            errors.push_back($sformatf(
                                "link '%s' upstream Switch USP port index %0d is out of range",
                                links[i].link_id, links[i].upstream_port_index));
                        end
                        else if ((links[i].upstream_role == PCIE_TOPO_PORT_DSP) &&
                                 (links[i].upstream_port_index >=
                                  nodes[upstream_index].num_dsp)) begin
                            errors.push_back($sformatf(
                                "link '%s' upstream Switch DSP port index %0d is out of range",
                                links[i].link_id, links[i].upstream_port_index));
                        end
                    end
                    default: ;
                endcase
            end

            if (downstream_valid) begin
                case (nodes[downstream_index].kind)
                    PCIE_TOPO_NODE_RC: begin
                        if (links[i].downstream_role != PCIE_TOPO_PORT_RC) begin
                            errors.push_back($sformatf(
                                "link '%s' downstream role does not match RC node '%s'",
                                links[i].link_id, nodes[downstream_index].node_id));
                        end
                        else if (links[i].downstream_port_index != 0) begin
                            errors.push_back($sformatf(
                                "link '%s' downstream RC port index %0d must be 0",
                                links[i].link_id, links[i].downstream_port_index));
                        end
                    end
                    PCIE_TOPO_NODE_EP: begin
                        if (links[i].downstream_role != PCIE_TOPO_PORT_EP) begin
                            errors.push_back($sformatf(
                                "link '%s' downstream role does not match Endpoint node '%s'",
                                links[i].link_id, nodes[downstream_index].node_id));
                        end
                        else if (links[i].downstream_port_index != 0) begin
                            errors.push_back($sformatf(
                                "link '%s' downstream Endpoint port index %0d must be 0",
                                links[i].link_id, links[i].downstream_port_index));
                        end
                    end
                    PCIE_TOPO_NODE_SWITCH: begin
                        if (!((links[i].downstream_role == PCIE_TOPO_PORT_USP) ||
                              (links[i].downstream_role == PCIE_TOPO_PORT_DSP))) begin
                            errors.push_back($sformatf(
                                "link '%s' downstream role does not match Switch node '%s'",
                                links[i].link_id, nodes[downstream_index].node_id));
                        end
                        else if ((links[i].downstream_role == PCIE_TOPO_PORT_USP) &&
                                 (links[i].downstream_port_index >=
                                  nodes[downstream_index].num_usp)) begin
                            errors.push_back($sformatf(
                                "link '%s' downstream Switch USP port index %0d is out of range",
                                links[i].link_id, links[i].downstream_port_index));
                        end
                        else if ((links[i].downstream_role == PCIE_TOPO_PORT_DSP) &&
                                 (links[i].downstream_port_index >=
                                  nodes[downstream_index].num_dsp)) begin
                            errors.push_back($sformatf(
                                "link '%s' downstream Switch DSP port index %0d is out of range",
                                links[i].link_id, links[i].downstream_port_index));
                        end
                    end
                    default: ;
                endcase
            end

            if (!links[i].enabled) continue;
            enabled_link_count++;
            if (upstream_valid) enabled_degree[upstream_index]++;
            if (downstream_valid) begin
                enabled_degree[downstream_index]++;
                if (nodes[downstream_index].kind == PCIE_TOPO_NODE_EP)
                    ep_parent_count[downstream_index]++;
            end

            for (int j = 0; j < i; j++) begin
                if ((links[j] == null) || !links[j].enabled) continue;
                if (same_endpoint(links[i], 1'b0, links[j], 1'b0) ||
                    same_endpoint(links[i], 1'b0, links[j], 1'b1)) begin
                    errors.push_back($sformatf(
                        "enabled link '%s' reuses physical port at its upstream endpoint",
                        links[i].link_id));
                end
                if (same_endpoint(links[i], 1'b1, links[j], 1'b0) ||
                    same_endpoint(links[i], 1'b1, links[j], 1'b1)) begin
                    errors.push_back($sformatf(
                        "enabled link '%s' reuses physical port at its downstream endpoint",
                        links[i].link_id));
                end
            end
            if (same_endpoint(links[i], 1'b0, links[i], 1'b1)) begin
                errors.push_back($sformatf(
                    "enabled link '%s' reuses the same physical port at both endpoints",
                    links[i].link_id));
            end

            supported_form = 1'b0;
            if (upstream_valid && downstream_valid) begin
                if ((nodes[upstream_index].kind == PCIE_TOPO_NODE_SWITCH) &&
                    (nodes[downstream_index].kind == PCIE_TOPO_NODE_SWITCH)) begin
                    errors.push_back($sformatf(
                        "link '%s' creates unsupported Switch cascading",
                        links[i].link_id));
                end
                else if ((nodes[upstream_index].kind == PCIE_TOPO_NODE_RC) &&
                         (links[i].upstream_role == PCIE_TOPO_PORT_RC) &&
                         (nodes[downstream_index].kind == PCIE_TOPO_NODE_EP) &&
                         (links[i].downstream_role == PCIE_TOPO_PORT_EP)) begin
                    supported_form = 1'b1;
                    direct_link_count++;
                end
                else if ((nodes[upstream_index].kind == PCIE_TOPO_NODE_RC) &&
                         (links[i].upstream_role == PCIE_TOPO_PORT_RC) &&
                         (nodes[downstream_index].kind == PCIE_TOPO_NODE_SWITCH) &&
                         (links[i].downstream_role == PCIE_TOPO_PORT_USP)) begin
                    supported_form = 1'b1;
                    rc_switch_link_count++;
                end
                else if ((nodes[upstream_index].kind == PCIE_TOPO_NODE_SWITCH) &&
                         (links[i].upstream_role == PCIE_TOPO_PORT_DSP) &&
                         (nodes[downstream_index].kind == PCIE_TOPO_NODE_EP) &&
                         (links[i].downstream_role == PCIE_TOPO_PORT_EP)) begin
                    supported_form = 1'b1;
                    switch_ep_link_count++;
                end
                if (!supported_form) begin
                    errors.push_back($sformatf(
                        "enabled link '%s' has an unsupported phase-one form",
                        links[i].link_id));
                end
            end
        end

        if (enabled_link_count == 0) begin
            errors.push_back("topology requires at least one enabled link");
        end

        foreach (nodes[i]) begin
            if (nodes[i] == null) continue;
            if (enabled_degree[i] == 0) begin
                errors.push_back($sformatf(
                    "node '%s' is isolated from all enabled links", nodes[i].node_id));
            end
            if ((nodes[i].kind == PCIE_TOPO_NODE_EP) &&
                (ep_parent_count[i] != 1)) begin
                errors.push_back($sformatf(
                    "Endpoint '%s' must have exactly one enabled parent link; found %0d",
                    nodes[i].node_id, ep_parent_count[i]));
            end
        end

        foreach (nodes[i]) begin
            if ((nodes[i] == null) ||
                (nodes[i].kind != PCIE_TOPO_NODE_SWITCH)) continue;

            for (longint unsigned usp = 0;
                 usp < nodes[i].num_usp; usp++) begin
                port_link_count = 0;
                foreach (links[j]) begin
                    if ((links[j] == null) || !links[j].enabled) continue;
                    upstream_index = resolve_unique_node_index(
                        links[j].upstream_node_id);
                    downstream_index = resolve_unique_node_index(
                        links[j].downstream_node_id);
                    if ((upstream_index >= 0) && (downstream_index == i) &&
                        (nodes[upstream_index].kind == PCIE_TOPO_NODE_RC) &&
                        (links[j].upstream_role == PCIE_TOPO_PORT_RC) &&
                        (links[j].downstream_role == PCIE_TOPO_PORT_USP) &&
                        (links[j].downstream_port_index == usp)) begin
                        port_link_count++;
                    end
                end
                if (port_link_count != 1) begin
                    errors.push_back($sformatf(
                        "Switch '%s' USP %0d must have exactly one enabled RC link; found %0d",
                        nodes[i].node_id, usp, port_link_count));
                end
            end

            for (longint unsigned dsp = 0;
                 dsp < nodes[i].num_dsp; dsp++) begin
                port_link_count = 0;
                foreach (links[j]) begin
                    if ((links[j] == null) || !links[j].enabled) continue;
                    upstream_index = resolve_unique_node_index(
                        links[j].upstream_node_id);
                    downstream_index = resolve_unique_node_index(
                        links[j].downstream_node_id);
                    if ((upstream_index == i) && (downstream_index >= 0) &&
                        (nodes[downstream_index].kind == PCIE_TOPO_NODE_EP) &&
                        (links[j].upstream_role == PCIE_TOPO_PORT_DSP) &&
                        (links[j].upstream_port_index == dsp) &&
                        (links[j].downstream_role == PCIE_TOPO_PORT_EP)) begin
                        port_link_count++;
                    end
                end
                if (port_link_count != 1) begin
                    errors.push_back($sformatf(
                        "Switch '%s' DSP %0d must have exactly one enabled Endpoint link; found %0d",
                        nodes[i].node_id, dsp, port_link_count));
                end
            end
        end

        if ((direct_link_count > 0) &&
            ((rc_switch_link_count > 0) || (switch_ep_link_count > 0) ||
             (switch_count > 0))) begin
            errors.push_back("topology mixes direct and Switch links");
        end
        else if ((switch_count == 0) &&
                 ((direct_link_count > 0) || (enabled_link_count > 0))) begin
            if ((direct_link_count != enabled_link_count) ||
                (direct_link_count != rc_count) ||
                (direct_link_count != ep_count) ||
                (nodes.size() != (rc_count + ep_count))) begin
                errors.push_back($sformatf(
                    "direct topology must reduce to independent one-RC/one-EP pairs; RC=%0d EP=%0d direct_links=%0d enabled_links=%0d",
                    rc_count, ep_count, direct_link_count, enabled_link_count));
            end
            else begin
                foreach (nodes[i]) begin
                    if ((nodes[i] != null) && (enabled_degree[i] != 1)) begin
                        errors.push_back($sformatf(
                            "direct topology node '%s' does not belong to exactly one pair",
                            nodes[i].node_id));
                    end
                end
            end
        end
        else if ((switch_count > 0) && (direct_link_count == 0)) begin
            if ((switch_count != 1) || (switch_index < 0)) begin
                errors.push_back(
                    "Switch topology must contain exactly one single-level Switch");
            end
            else if ((rc_count != nodes[switch_index].num_usp) ||
                     (ep_count != nodes[switch_index].num_dsp) ||
                     (rc_switch_link_count != nodes[switch_index].num_usp) ||
                     (switch_ep_link_count != nodes[switch_index].num_dsp) ||
                     (enabled_link_count !=
                      (rc_switch_link_count + switch_ep_link_count)) ||
                     (nodes.size() != (rc_count + ep_count + 1))) begin
                errors.push_back($sformatf(
                    "phase-one Switch topology connectivity/counts are incomplete or contain silent extras: RC=%0d EP=%0d RC-SW=%0d SW-EP=%0d",
                    rc_count, ep_count, rc_switch_link_count,
                    switch_ep_link_count));
            end
        end
    endfunction
endclass
