class pcie_tl_custom_env extends pcie_tl_env;
    `uvm_component_utils(pcie_tl_custom_env)

    pcie_topology_cfg topology_cfg;
    pcie_tl_topology_adapter topology_adapter;

    function new(string name = "pcie_tl_custom_env",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // 将后端无关 device policy 中的 Root 元数据转换为 TL agent 顺序。
    // direct 模式按 topology adapter 排序后的链路顺序建立 EP[i]；switch
    // 模式按 DSP port 顺序建立 EP[i]。没有 Root 元数据的旧测试不写入
    // 映射表，继续使用 pcie_tl_env 的历史回退规则。
    protected function void derive_ep_root_bindings(
        pcie_tl_env_config policy_cfg,
        output string errors[$]);
        int endpoint_count;
        int root_count;

        errors.delete();
        if (policy_cfg == null)
            return;

        endpoint_count = policy_cfg.switch_enable &&
                         (policy_cfg.switch_cfg != null) ?
                         policy_cfg.switch_cfg.num_ds_ports :
                         policy_cfg.num_ep;
        root_count = policy_cfg.switch_enable &&
                     (policy_cfg.switch_cfg != null) ?
                     policy_cfg.switch_cfg.num_usp : policy_cfg.num_rc;

        for (int ep_index = 0; ep_index < endpoint_count; ep_index++) begin
            string node_id;
            bit found_root;
            int mapped_root;
            int expected_root;

            node_id = policy_cfg.switch_enable ?
                      ((ep_index < topology_adapter.switch_ep_node_ids.size()) ?
                       topology_adapter.switch_ep_node_ids[ep_index] : "") :
                      ((ep_index < topology_adapter.direct_ep_node_ids.size()) ?
                       topology_adapter.direct_ep_node_ids[ep_index] : "");
            found_root = 1'b0;
            mapped_root = 0;

            // 一个物理 EP 可能对应多个 PF/VF policy；它们必须属于同一
            // Root，否则同一个 agent 会出现不可判定的资源归属。
            foreach (policy_cfg.device_cfgs[device_index]) begin
                pcie_device_cfg device;

                device = policy_cfg.device_cfgs[device_index];
                if ((device == null) || (device.role != PCIE_DEVICE_EP))
                    continue;
                if (!((device.device_id == node_id) ||
                      (device.physical_node_id != "" &&
                       device.physical_node_id == node_id)))
                    continue;
                if (!device.root_index_valid)
                    continue;

                if (!found_root) begin
                    found_root = 1'b1;
                    mapped_root = int'(device.root_index);
                end
                else if (mapped_root != int'(device.root_index)) begin
                    errors.push_back($sformatf(
                        "EP%0d physical node '%s' has conflicting Root metadata",
                        ep_index, node_id));
                end
            end

            if (!found_root)
                continue;
            if ((mapped_root < 0) || (mapped_root >= root_count)) begin
                errors.push_back($sformatf(
                    "EP%0d maps to invalid Root%0d (Root count=%0d)",
                    ep_index, mapped_root, root_count));
                continue;
            end

            if (policy_cfg.switch_enable &&
                (policy_cfg.switch_cfg != null)) begin
                expected_root = policy_cfg.switch_cfg.dsp_owner[ep_index];
                if (mapped_root != expected_root)
                    errors.push_back($sformatf(
                        "Switch DSP%0d maps to Root%0d but dsp_owner requires Root%0d",
                        ep_index, mapped_root, expected_root));
            end

            begin
                string why;
                if (!policy_cfg.bind_ep_root(ep_index, mapped_root, why))
                    errors.push_back({"EP Root mapping failed: ", why});
            end
        end
    endfunction

    virtual function void build_phase(uvm_phase phase);
        pcie_tl_env_config translated_cfg;
        pcie_tl_env_config policy_cfg;
        pcie_global_cfg global_cfg;
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

        // The unified manager publishes backend-neutral device images.  Copy
        // their handles into the native TL policy; pcie_tl_env translates each
        // image into an independent function/configuration-space context.
        if (uvm_config_db#(pcie_global_cfg)::get(
                this, "", "global_cfg", global_cfg) &&
            (global_cfg != null)) begin
            policy_cfg.device_cfgs.delete();
            foreach (global_cfg.devices[i])
                policy_cfg.device_cfgs.push_back(global_cfg.devices[i]);
        end

        // Policy owns all non-topology settings. Overwrite only the six fields
        // that determine the native environment topology.
        policy_cfg.rc_agent_enable = translated_cfg.rc_agent_enable;
        policy_cfg.ep_agent_enable = translated_cfg.ep_agent_enable;
        policy_cfg.num_rc = translated_cfg.num_rc;
        policy_cfg.num_ep = translated_cfg.num_ep;
        policy_cfg.switch_enable = translated_cfg.switch_enable;
        policy_cfg.switch_cfg = translated_cfg.switch_cfg;

        // Root-aware DPU policy is converted after the topology counts are
        // copied.  Any mismatch is therefore reported before the base
        // environment creates agents or issues a TL transaction.
        derive_ep_root_bindings(policy_cfg, errors);
        if (errors.size() != 0) begin
            message = "";
            foreach (errors[i])
                message = {message, (i == 0) ? "" : "; ", errors[i]};
            `uvm_fatal("ROOT_MAP", {"EP Root mapping failed: ", message})
            return;
        end

        uvm_config_db#(pcie_tl_env_config)::set(
            null, get_full_name(), "cfg", policy_cfg);
        super.build_phase(phase);
        `uvm_info("TOPO_ENV", "PCIE_TL_CUSTOM_ENV_READY", UVM_LOW)
    endfunction
endclass
