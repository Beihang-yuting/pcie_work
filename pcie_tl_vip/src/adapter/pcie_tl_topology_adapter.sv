class pcie_tl_topology_adapter extends uvm_object;
    `uvm_object_utils(pcie_tl_topology_adapter)

    localparam int unsigned TL_MAX_SWITCH_USP = 8;
    localparam int unsigned TL_MAX_SWITCH_DSP_PER_USP = 8;

    string direct_link_ids[$];
    string direct_rc_node_ids[$];
    string direct_ep_node_ids[$];
    string switch_ep_node_ids[];

    function new(string name = "pcie_tl_topology_adapter");
        super.new(name);
    endfunction

    function bit error_contains(input string errors[$], string fragment);
        foreach (errors[i]) begin
            if (uvm_is_match({"*", fragment, "*"}, errors[i])) return 1;
        end
        return 0;
    endfunction

    function pcie_tl_env_config translate(pcie_topology_cfg topology,
                                          output string errors[$]);
        pcie_tl_env_config result;
        pcie_topology_link_cfg direct_links[$];
        pcie_topology_link_cfg swap;
        pcie_topology_node_cfg switch_node;
        pcie_tl_switch_config switch_cfg;
        string validation_errors[$];
        int dsp_count_by_usp[];

        errors.delete();
        direct_link_ids.delete();
        direct_rc_node_ids.delete();
        direct_ep_node_ids.delete();
        switch_ep_node_ids = new[0];

        if (topology == null) begin
            errors.push_back("topology is null");
            return null;
        end

        topology.validate(validation_errors);
        foreach (validation_errors[i])
            errors.push_back(validation_errors[i]);
        if (errors.size() != 0) return null;

        result = pcie_tl_env_config::type_id::create("translated_tl_cfg");
        foreach (topology.nodes[i]) begin
            if (topology.nodes[i].kind == PCIE_TOPO_NODE_SWITCH)
                switch_node = topology.nodes[i];
        end

        if (switch_node != null) begin
            if (switch_node.num_usp > TL_MAX_SWITCH_USP) begin
                errors.push_back($sformatf(
                    "TL backend supports at most %0d Switch USPs; source declares %0d",
                    TL_MAX_SWITCH_USP, switch_node.num_usp));
            end
            dsp_count_by_usp = new[switch_node.num_usp];
            foreach (switch_node.dsp_owner_usp[i])
                dsp_count_by_usp[switch_node.dsp_owner_usp[i]]++;
            foreach (dsp_count_by_usp[i]) begin
                if (dsp_count_by_usp[i] > TL_MAX_SWITCH_DSP_PER_USP) begin
                    errors.push_back($sformatf(
                        "Switch USP%0d owns %0d DSPs; maximum is %0d for TL backend",
                        i, dsp_count_by_usp[i], TL_MAX_SWITCH_DSP_PER_USP));
                end
            end
            if (errors.size() != 0) return null;
        end

        if (switch_node == null) begin
            foreach (topology.links[i]) begin
                if (topology.links[i].enabled)
                    direct_links.push_back(topology.links[i]);
            end
            for (int i = 0; i < direct_links.size(); i++) begin
                for (int j = i + 1; j < direct_links.size(); j++) begin
                    if (direct_links[j].link_id < direct_links[i].link_id) begin
                        swap = direct_links[i];
                        direct_links[i] = direct_links[j];
                        direct_links[j] = swap;
                    end
                end
            end

            result.switch_enable = 0;
            result.rc_agent_enable = 1;
            result.ep_agent_enable = 1;
            result.num_rc = direct_links.size();
            result.num_ep = direct_links.size();
            foreach (direct_links[i]) begin
                direct_link_ids.push_back(direct_links[i].link_id);
                direct_rc_node_ids.push_back(direct_links[i].upstream_node_id);
                direct_ep_node_ids.push_back(direct_links[i].downstream_node_id);
            end
        end
        else begin
            result.switch_enable = 1;
            result.rc_agent_enable = 1;
            result.ep_agent_enable = 1;
            result.num_rc = switch_node.num_usp;
            result.num_ep = switch_node.num_dsp;

            switch_cfg = pcie_tl_switch_config::type_id::create(
                "translated_switch_cfg");
            switch_cfg.num_usp = switch_node.num_usp;
            switch_cfg.num_ds_ports = switch_node.num_dsp;
            switch_cfg.dsp_owner = new[switch_node.dsp_owner_usp.size()];
            foreach (switch_cfg.dsp_owner[i])
                switch_cfg.dsp_owner[i] = switch_node.dsp_owner_usp[i];
            switch_cfg.init_defaults();
            result.switch_cfg = switch_cfg;

            switch_ep_node_ids = new[switch_node.num_dsp];
            foreach (topology.links[i]) begin
                if (topology.links[i].enabled &&
                    (topology.links[i].upstream_node_id == switch_node.node_id) &&
                    (topology.links[i].upstream_role == PCIE_TOPO_PORT_DSP)) begin
                    switch_ep_node_ids[topology.links[i].upstream_port_index] =
                        topology.links[i].downstream_node_id;
                end
            end
        end

        audit(topology, result, errors);
        if (errors.size() != 0) return null;

        `uvm_info("TOPO_TL", $sformatf(
            {"retained physical intent for %0d links; ",
             "TL backend does not simulate lanes, training, or data rate"},
            topology.links.size()), UVM_LOW)
        return result;
    endfunction

    function void audit(pcie_topology_cfg topology,
                        pcie_tl_env_config native_cfg,
                        output string errors[$]);
        pcie_topology_node_cfg switch_node;
        int enabled_links;

        errors.delete();
        if ((topology == null) || (native_cfg == null)) begin
            errors.push_back("audit input is null");
            return;
        end

        foreach (topology.nodes[i]) begin
            if ((topology.nodes[i] != null) &&
                (topology.nodes[i].kind == PCIE_TOPO_NODE_SWITCH)) begin
                switch_node = topology.nodes[i];
            end
        end
        enabled_links = 0;
        foreach (topology.links[i]) begin
            if ((topology.links[i] != null) && topology.links[i].enabled)
                enabled_links++;
        end

        if (!native_cfg.rc_agent_enable)
            errors.push_back("RC agent is disabled");
        if (!native_cfg.ep_agent_enable)
            errors.push_back("Endpoint agent is disabled");

        if (switch_node == null) begin
            if (native_cfg.switch_enable)
                errors.push_back(
                    "direct topology unexpectedly enabled Switch mode");
            if (native_cfg.num_rc != enabled_links) begin
                errors.push_back($sformatf("RC count mismatch: %0d versus %0d",
                                           native_cfg.num_rc, enabled_links));
            end
            if (native_cfg.num_ep != enabled_links) begin
                errors.push_back($sformatf(
                    "Endpoint count mismatch: %0d versus %0d",
                    native_cfg.num_ep, enabled_links));
            end
            return;
        end

        if (!native_cfg.switch_enable || (native_cfg.switch_cfg == null)) begin
            errors.push_back(
                "Switch topology lost native Switch configuration");
            return;
        end
        if (native_cfg.num_rc != switch_node.num_usp) begin
            errors.push_back($sformatf("RC count mismatch: %0d versus %0d",
                                       native_cfg.num_rc,
                                       switch_node.num_usp));
        end
        if (native_cfg.num_ep != switch_node.num_dsp) begin
            errors.push_back($sformatf(
                "Endpoint count mismatch: %0d versus %0d",
                native_cfg.num_ep, switch_node.num_dsp));
        end
        if (native_cfg.switch_cfg.num_usp != switch_node.num_usp)
            errors.push_back("Switch USP count mismatch");
        if (native_cfg.switch_cfg.num_ds_ports != switch_node.num_dsp)
            errors.push_back("Switch DSP count mismatch");

        if (native_cfg.switch_cfg.dsp_owner.size() !=
            switch_node.dsp_owner_usp.size()) begin
            errors.push_back("Switch ownership size mismatch");
        end
        else begin
            foreach (native_cfg.switch_cfg.dsp_owner[i]) begin
                if (native_cfg.switch_cfg.dsp_owner[i] !=
                    switch_node.dsp_owner_usp[i]) begin
                    errors.push_back($sformatf(
                        "Switch DSP%0d ownership mismatch", i));
                end
            end
        end

        if ((native_cfg.switch_cfg.ds_secondary_bus.size() !=
             switch_node.num_dsp) ||
            (native_cfg.switch_cfg.ds_subordinate_bus.size() !=
             switch_node.num_dsp) ||
            (native_cfg.switch_cfg.ds_mem_base.size() != switch_node.num_dsp) ||
            (native_cfg.switch_cfg.ds_mem_limit.size() != switch_node.num_dsp) ||
            (native_cfg.switch_cfg.usp_sec_bus.size() != switch_node.num_usp) ||
            (native_cfg.switch_cfg.usp_sub_bus.size() != switch_node.num_usp) ||
            (native_cfg.switch_cfg.usp_mem_base_a.size() !=
             switch_node.num_usp) ||
            (native_cfg.switch_cfg.usp_mem_limit_a.size() !=
             switch_node.num_usp)) begin
            errors.push_back("Switch generated window array size mismatch");
        end
    endfunction
endclass
