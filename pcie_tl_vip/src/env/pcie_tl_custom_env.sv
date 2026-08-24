class pcie_tl_custom_env extends pcie_tl_env;
    `uvm_component_utils(pcie_tl_custom_env)

    pcie_topology_cfg topology_cfg;
    pcie_tl_topology_adapter topology_adapter;

    function new(string name = "pcie_tl_custom_env",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        pcie_tl_env_config translated_cfg;
        pcie_tl_env_config policy_cfg;
        string errors[$];
        string message;

        if (!uvm_config_db#(pcie_topology_cfg)::get(
                this, "", "topology_cfg", topology_cfg) ||
            (topology_cfg == null)) begin
            `uvm_fatal("TOPO_ENV", "non-null topology_cfg is required")
            return;
        end

        topology_cfg.validate(errors);
        if (errors.size() != 0) begin
            message = "";
            foreach (errors[i]) begin
                message = {message, (i == 0) ? "" : "; ", errors[i]};
            end
            `uvm_fatal("TOPO_ENV",
                       {"topology validation failed: ", message})
            return;
        end

        topology_adapter = pcie_tl_topology_adapter::type_id::create(
            "topology_adapter");
        translated_cfg = topology_adapter.translate(topology_cfg, errors);
        if ((translated_cfg == null) || (errors.size() != 0)) begin
            message = "";
            foreach (errors[i]) begin
                message = {message, (i == 0) ? "" : "; ", errors[i]};
            end
            `uvm_fatal("TOPO_ENV",
                       {"topology translation failed: ", message})
            return;
        end

        if (!uvm_config_db#(pcie_tl_env_config)::get(
                this, "", "tl_policy_cfg", policy_cfg) ||
            (policy_cfg == null)) begin
            policy_cfg = pcie_tl_env_config::type_id::create(
                "default_tl_policy_cfg");
        end

        // Policy owns all non-topology settings. Overwrite only the six fields
        // that determine the native environment topology.
        policy_cfg.rc_agent_enable = translated_cfg.rc_agent_enable;
        policy_cfg.ep_agent_enable = translated_cfg.ep_agent_enable;
        policy_cfg.num_rc = translated_cfg.num_rc;
        policy_cfg.num_ep = translated_cfg.num_ep;
        policy_cfg.switch_enable = translated_cfg.switch_enable;
        policy_cfg.switch_cfg = translated_cfg.switch_cfg;

        uvm_config_db#(pcie_tl_env_config)::set(
            null, get_full_name(), "cfg", policy_cfg);
        super.build_phase(phase);
        `uvm_info("TOPO_ENV", "PCIE_TL_CUSTOM_ENV_READY", UVM_LOW)
    endfunction
endclass
