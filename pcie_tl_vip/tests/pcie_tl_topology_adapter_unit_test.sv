import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_tl_topology_adapter_unit_test extends uvm_test;
    `uvm_component_utils(pcie_tl_topology_adapter_unit_test)

    function new(string name = "pcie_tl_topology_adapter_unit_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void require(bit condition, string message);
        if (!condition) `uvm_error("TOPO_ADAPT", message)
    endfunction

    function pcie_topology_cfg build_two_usp();
        pcie_topology_builder builder;
        int owners[];

        builder = new("two_usp_builder");
        owners = new[3];
        owners[0] = 0;
        owners[1] = 1;
        owners[2] = 1;
        void'(builder.add_rc("RC0"));
        void'(builder.add_rc("RC1"));
        void'(builder.add_switch("SW0", 2, 3, owners));
        for (int i = 0; i < 3; i++)
            void'(builder.add_ep($sformatf("EP%0d", i)));
        void'(builder.connect("UP0", "RC0", PCIE_TOPO_PORT_RC, 0,
                              "SW0", PCIE_TOPO_PORT_USP, 0, 8, 4));
        void'(builder.connect("UP1", "RC1", PCIE_TOPO_PORT_RC, 0,
                              "SW0", PCIE_TOPO_PORT_USP, 1, 8, 4));
        for (int i = 0; i < 3; i++) begin
            void'(builder.connect($sformatf("DOWN%0d", i),
                                  "SW0", PCIE_TOPO_PORT_DSP, i,
                                  $sformatf("EP%0d", i),
                                  PCIE_TOPO_PORT_EP, 0, 4, 4));
        end
        return builder.finish();
    endfunction

    function void require_switch_array_sizes(pcie_tl_switch_config cfg,
                                             int num_usp, int num_dsp);
        require(cfg.ds_secondary_bus.size() == num_dsp,
                "DSP secondary-bus array size");
        require(cfg.ds_subordinate_bus.size() == num_dsp,
                "DSP subordinate-bus array size");
        require(cfg.ds_mem_base.size() == num_dsp,
                "DSP memory-base array size");
        require(cfg.ds_mem_limit.size() == num_dsp,
                "DSP memory-limit array size");
        require(cfg.usp_sec_bus.size() == num_usp,
                "USP secondary-bus array size");
        require(cfg.usp_sub_bus.size() == num_usp,
                "USP subordinate-bus array size");
        require(cfg.usp_mem_base_a.size() == num_usp,
                "USP memory-base array size");
        require(cfg.usp_mem_limit_a.size() == num_usp,
                "USP memory-limit array size");
    endfunction

    task run_phase(uvm_phase phase);
        pcie_tl_topology_adapter adapter;
        pcie_tl_env_config cfg;
        pcie_topology_cfg source;
        pcie_topology_link_cfg swap;
        string errors[$];

        phase.raise_objection(this);
        adapter = pcie_tl_topology_adapter::type_id::create("adapter");

        cfg = adapter.translate(null, errors);
        require(cfg == null, "null topology translation returns null");
        require(adapter.error_contains(errors, "topology is null"),
                "null topology translation reports an error");
        adapter.audit(null, cfg, errors);
        require(adapter.error_contains(errors, "audit input is null"),
                "null audit inputs report an error");

        source = pcie_topology_builder::build_ep_x16(5);
        source.links[0].link_width = 1;
        cfg = adapter.translate(source, errors);
        require(cfg == null, "invalid whole source is not translated");
        require(adapter.error_contains(errors, "unsupported width"),
                "source validation error is preserved");

        source = pcie_topology_builder::build_ep_x16(5);
        cfg = adapter.translate(source, errors);
        require((errors.size() == 0) && (cfg != null),
                "EP_X16 translation");
        if (cfg != null) begin
            require(!cfg.switch_enable && cfg.rc_agent_enable &&
                    cfg.ep_agent_enable, "EP_X16 direct mode and agents");
            require((cfg.num_rc == 1) && (cfg.num_ep == 1),
                    "EP_X16 native counts");
        end
        require((adapter.direct_link_ids.size() == 1) &&
                (adapter.direct_rc_node_ids.size() == 1) &&
                (adapter.direct_ep_node_ids.size() == 1),
                "EP_X16 direct mappings exist");

        source = pcie_topology_builder::build_ep_2x8(4);
        swap = source.links[0];
        source.links[0] = source.links[1];
        source.links[1] = swap;
        cfg = adapter.translate(source, errors);
        require((errors.size() == 0) && (cfg != null),
                "EP_2X8 translation");
        if (cfg != null) begin
            require(!cfg.switch_enable && cfg.rc_agent_enable &&
                    cfg.ep_agent_enable, "EP_2X8 direct mode and agents");
            require((cfg.num_rc == 2) && (cfg.num_ep == 2),
                    "EP_2X8 native counts");
        end
        require((adapter.direct_link_ids.size() == 2) &&
                (adapter.direct_link_ids[0] == "RC0_EP0") &&
                (adapter.direct_link_ids[1] == "RC1_EP1"),
                "direct link ordering is lexicographic");
        require((adapter.direct_rc_node_ids.size() == 2) &&
                (adapter.direct_rc_node_ids[0] == "RC0") &&
                (adapter.direct_rc_node_ids[1] == "RC1"),
                "direct RC mapping follows link ordering");
        require((adapter.direct_ep_node_ids.size() == 2) &&
                (adapter.direct_ep_node_ids[0] == "EP0") &&
                (adapter.direct_ep_node_ids[1] == "EP1"),
                "direct Endpoint mapping follows link ordering");

        if (cfg != null) begin
            cfg.switch_enable = 1;
            cfg.num_rc++;
            cfg.num_ep++;
            adapter.audit(source, cfg, errors);
            require(adapter.error_contains(errors,
                                            "unexpectedly enabled Switch mode"),
                    "direct audit detects corrupted mode");
            require(adapter.error_contains(errors, "RC count mismatch"),
                    "direct audit detects corrupted RC count");
            require(adapter.error_contains(errors, "Endpoint count mismatch"),
                    "direct audit detects corrupted Endpoint count");
        end

        source = pcie_topology_builder::build_switch_1x16_4x4(5);
        cfg = adapter.translate(source, errors);
        require((errors.size() == 0) && (cfg != null),
                "SWITCH_1X16_4X4 translation");
        if (cfg != null) begin
            require(cfg.switch_enable && cfg.rc_agent_enable &&
                    cfg.ep_agent_enable && (cfg.switch_cfg != null),
                    "Switch mode, agents, and native configuration");
            require((cfg.num_rc == 1) && (cfg.num_ep == 4),
                    "Switch environment counts");
            if (cfg.switch_cfg != null) begin
                require((cfg.switch_cfg.num_usp == 1) &&
                        (cfg.switch_cfg.num_ds_ports == 4),
                        "Switch native counts");
                require(cfg.switch_cfg.dsp_owner.size() == 4,
                        "Switch ownership size");
                foreach (cfg.switch_cfg.dsp_owner[i])
                    require(cfg.switch_cfg.dsp_owner[i] == 0,
                            "Switch ownership value");
                require_switch_array_sizes(cfg.switch_cfg, 1, 4);
            end
        end
        require((adapter.direct_link_ids.size() == 0) &&
                (adapter.direct_rc_node_ids.size() == 0) &&
                (adapter.direct_ep_node_ids.size() == 0),
                "direct mappings reset before Switch translation");
        require(adapter.switch_ep_node_ids.size() == 4,
                "Switch Endpoint mapping size");
        if (adapter.switch_ep_node_ids.size() == 4) begin
            foreach (adapter.switch_ep_node_ids[i])
                require(adapter.switch_ep_node_ids[i] == $sformatf("EP%0d", i),
                        "Switch Endpoint mapping follows DSP index");
        end

        source = pcie_topology_builder::build_ep_x16(4);
        cfg = adapter.translate(source, errors);
        require((cfg != null) && (errors.size() == 0),
                "direct translation after Switch translation");
        require(adapter.switch_ep_node_ids.size() == 0,
                "Switch mappings reset before direct translation");

        cfg = adapter.translate(null, errors);
        require(cfg == null, "second null topology translation returns null");
        require((adapter.direct_link_ids.size() == 0) &&
                (adapter.direct_rc_node_ids.size() == 0) &&
                (adapter.direct_ep_node_ids.size() == 0) &&
                (adapter.switch_ep_node_ids.size() == 0),
                "all mappings reset before failed translation");

        source = build_two_usp();
        cfg = adapter.translate(source, errors);
        require((errors.size() == 0) && (cfg != null),
                "multi-USP translation");
        if (cfg != null) begin
            require(cfg.switch_enable && cfg.rc_agent_enable &&
                    cfg.ep_agent_enable, "multi-USP Switch mode and agents");
            require((cfg.num_rc == 2) && (cfg.num_ep == 3),
                    "multi-USP environment counts");
            require((cfg.switch_cfg.num_usp == 2) &&
                    (cfg.switch_cfg.num_ds_ports == 3),
                    "multi-USP native counts");
            require((cfg.switch_cfg.dsp_owner.size() == 3) &&
                    (cfg.switch_cfg.dsp_owner[0] == 0) &&
                    (cfg.switch_cfg.dsp_owner[1] == 1) &&
                    (cfg.switch_cfg.dsp_owner[2] == 1),
                    "multi-USP native ownership");
            require_switch_array_sizes(cfg.switch_cfg, 2, 3);

            cfg.num_ep++;
            adapter.audit(source, cfg, errors);
            require(adapter.error_contains(errors, "Endpoint count mismatch"),
                    "Switch audit detects corrupted Endpoint count");
            cfg.num_ep--;

            cfg.num_rc++;
            adapter.audit(source, cfg, errors);
            require(adapter.error_contains(errors, "RC count mismatch"),
                    "Switch audit detects corrupted RC count");
            cfg.num_rc--;

            cfg.switch_cfg.dsp_owner[2] = 0;
            adapter.audit(source, cfg, errors);
            require(adapter.error_contains(errors, "ownership mismatch"),
                    "Switch audit detects corrupted ownership");
            cfg.switch_cfg.dsp_owner[2] = 1;

            cfg.switch_cfg.ds_mem_base = new[0];
            adapter.audit(source, cfg, errors);
            require(adapter.error_contains(errors,
                                            "generated window array size mismatch"),
                    "Switch audit detects corrupted generated arrays");
        end

        adapter.audit(source, null, errors);
        require(adapter.error_contains(errors, "audit input is null"),
                "null native audit input reports an error");

        phase.drop_objection(this);
    endtask
endclass
