import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

// A no-op component shell lets the unit test call the environment's protected
// context-join helper without constructing the full agent hierarchy.  UVM
// components must be created during build, so this shell is allocated by the
// test build_phase and deliberately suppresses inherited build/connect work.
class pcie_tl_context_lookup_env extends pcie_tl_env;
    `uvm_component_utils(pcie_tl_context_lookup_env)

    function new(string name = "pcie_tl_context_lookup_env",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        // Intentionally empty: the test supplies only cfg/topology/context
        // fields needed by configured_ep_context().
    endfunction

    function void connect_phase(uvm_phase phase);
        // Intentionally empty; no agents are built by this shell.
    endfunction

    task run_phase(uvm_phase phase);
        // Intentionally empty; the parent test owns the objection and checks.
    endtask
endclass

class pcie_tl_topology_adapter_unit_test extends uvm_test;
    `uvm_component_utils(pcie_tl_topology_adapter_unit_test)

    pcie_tl_context_lookup_env context_env;

    function new(string name = "pcie_tl_topology_adapter_unit_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        context_env = pcie_tl_context_lookup_env::type_id::create(
            "context_lookup_env", this);
    endfunction

    function void require(bit condition, string message);
        if (!condition) `uvm_error("TOPO_ADAPT", message)
    endfunction

    function bit errors_contain(input string errors[$], string fragment);
        foreach (errors[i]) begin
            if (uvm_is_match({"*", fragment, "*"}, errors[i])) return 1;
        end
        return 0;
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

    // Deliberately non-lexicographic IDs and declaration order.  Canonical
    // direct slots must still be ordered by link_id, matching the production
    // topology adapter/global policy contract rather than queue position.
    function pcie_topology_cfg build_shuffled_direct_links();
        pcie_topology_builder builder;

        builder = new("shuffled_direct_builder");
        void'(builder.add_rc("RC_Z"));
        void'(builder.add_ep("EP_Z"));
        void'(builder.add_rc("RC_A"));
        void'(builder.add_ep("EP_A"));
        void'(builder.add_rc("RC_M"));
        void'(builder.add_ep("EP_M"));
        void'(builder.connect("Z_LINK", "RC_Z", PCIE_TOPO_PORT_RC, 0,
                              "EP_Z", PCIE_TOPO_PORT_EP, 0, 8, 4));
        void'(builder.connect("M_LINK", "RC_M", PCIE_TOPO_PORT_RC, 0,
                              "EP_M", PCIE_TOPO_PORT_EP, 0, 8, 4));
        void'(builder.connect("A_LINK", "RC_A", PCIE_TOPO_PORT_RC, 0,
                              "EP_A", PCIE_TOPO_PORT_EP, 0, 8, 4));
        return builder.finish();
    endfunction

    // The topology adapter orders physical EP slots by link ID, whereas DPU
    // device records may arrive in an unrelated declaration order (and often
    // use physical_node_id rather than the PF-qualified device_id).  Verify
    // that pcie_tl_env joins by the canonical node ID before falling back to
    // the historical declaration-order behavior for cfg-only callers.
    function void check_ep_context_mapping();
        pcie_topology_cfg source;
        pcie_tl_topology_adapter adapter;
        pcie_tl_env_config env_cfg;
        pcie_tl_env_config translated_cfg;
        pcie_device_cfg dev_z;
        pcie_device_cfg dev_a;
        pcie_device_cfg dev_m;
        pcie_tl_func_context ctx_z;
        pcie_tl_func_context ctx_a;
        pcie_tl_func_context ctx_m;
        string errors[$];

        source = build_shuffled_direct_links();
        adapter = pcie_tl_topology_adapter::type_id::create(
            "context_lookup_adapter");
        translated_cfg = adapter.translate(source, errors);
        require((translated_cfg != null) && (errors.size() == 0),
                "context lookup fixture translates successfully");
        if ((translated_cfg == null) || (errors.size() != 0))
            return;

        env_cfg = pcie_tl_env_config::type_id::create("context_lookup_cfg");
        env_cfg.switch_enable = translated_cfg.switch_enable;
        env_cfg.num_ep = translated_cfg.num_ep;

        // Deliberately declare Z, A, M while canonical physical order is
        // A, M, Z.  physical_node_id carries the stable graph node identity;
        // device_id models a PF-qualified DPU record.
        dev_z = pcie_device_cfg::type_id::create("ctx_dev_z");
        dev_z.device_id = "EP_Z.PF0";
        dev_z.physical_node_id = "EP_Z";
        dev_z.role = PCIE_DEVICE_EP;
        dev_z.bdf = 16'h0200;
        dev_a = pcie_device_cfg::type_id::create("ctx_dev_a");
        dev_a.device_id = "EP_A.PF0";
        dev_a.physical_node_id = "EP_A";
        dev_a.role = PCIE_DEVICE_EP;
        dev_a.bdf = 16'h0208;
        dev_m = pcie_device_cfg::type_id::create("ctx_dev_m");
        dev_m.device_id = "EP_M.PF0";
        dev_m.physical_node_id = "EP_M";
        dev_m.role = PCIE_DEVICE_EP;
        dev_m.bdf = 16'h0210;
        env_cfg.device_cfgs.push_back(dev_z);
        env_cfg.device_cfgs.push_back(dev_a);
        env_cfg.device_cfgs.push_back(dev_m);

        ctx_z = pcie_tl_func_context::type_id::create("ctx_z");
        ctx_z.bdf = dev_z.bdf;
        ctx_a = pcie_tl_func_context::type_id::create("ctx_a");
        ctx_a.bdf = dev_a.bdf;
        ctx_m = pcie_tl_func_context::type_id::create("ctx_m");
        ctx_m.bdf = dev_m.bdf;

        context_env.cfg = env_cfg;
        context_env.topology_adapter = adapter;
        context_env.device_contexts[ctx_z.bdf] = ctx_z;
        context_env.device_contexts[ctx_a.bdf] = ctx_a;
        context_env.device_contexts[ctx_m.bdf] = ctx_m;

        require(context_env.configured_ep_context(0) == ctx_a,
                "EP slot 0 resolves canonical EP_A context");
        require(context_env.configured_ep_context(1) == ctx_m,
                "EP slot 1 resolves canonical EP_M context");
        require(context_env.configured_ep_context(2) == ctx_z,
                "EP slot 2 resolves canonical EP_Z context");

        // An active topology must not silently fall back to declaration order
        // when its canonical node is absent; that would bind the neighboring
        // physical slot's configuration image.
        dev_m.physical_node_id = "EP_M_MISSING";
        require(context_env.configured_ep_context(1) == null,
                "unmatched canonical node does not fall back by declaration");
        dev_m.physical_node_id = "EP_M";

        // With no topology adapter, preserve the old declaration-order
        // contract for direct cfg-only users.
        context_env.topology_adapter = null;
        require(context_env.configured_ep_context(0) == ctx_z,
                "cfg-only context lookup retains declaration fallback");
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

        // Physical identity must survive both a shuffled declaration queue
        // and IDs that do not sort in insertion order.
        source = build_shuffled_direct_links();
        cfg = adapter.translate(source, errors);
        require((errors.size() == 0) && (cfg != null),
                "shuffled direct-link translation");
        require((adapter.direct_link_ids.size() == 3) &&
                (adapter.direct_link_ids[0] == "A_LINK") &&
                (adapter.direct_link_ids[1] == "M_LINK") &&
                (adapter.direct_link_ids[2] == "Z_LINK"),
                "shuffled direct IDs use canonical lexical order");
        require((adapter.direct_rc_node_ids.size() == 3) &&
                (adapter.direct_rc_node_ids[0] == "RC_A") &&
                (adapter.direct_rc_node_ids[1] == "RC_M") &&
                (adapter.direct_rc_node_ids[2] == "RC_Z"),
                "shuffled direct RC IDs follow canonical slots");
        require((adapter.direct_ep_node_ids.size() == 3) &&
                (adapter.direct_ep_node_ids[0] == "EP_A") &&
                (adapter.direct_ep_node_ids[1] == "EP_M") &&
                (adapter.direct_ep_node_ids[2] == "EP_Z"),
                "shuffled direct EP IDs follow canonical slots");
        check_ep_context_mapping();
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
            cfg.switch_enable = 0;
            cfg.num_rc--;
            cfg.num_ep--;

            cfg.rc_agent_enable = 0;
            adapter.audit(source, cfg, errors);
            require(errors_contain(errors, "RC agent is disabled"),
                    "direct audit detects disabled RC agent");
            cfg.rc_agent_enable = 1;

            cfg.ep_agent_enable = 0;
            adapter.audit(source, cfg, errors);
            require(errors_contain(errors, "Endpoint agent is disabled"),
                    "direct audit detects disabled Endpoint agent");
            cfg.ep_agent_enable = 1;
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

        // Reorder every Switch edge in the source queue.  USP/DSP arrays must
        // remain indexed by their declared physical port indexes, not by this
        // arbitrary declaration order.
        source = build_two_usp();
        begin
            pcie_topology_link_cfg reordered[$];
            for (int i = source.links.size() - 1; i >= 0; i--)
                reordered.push_back(source.links[i]);
            source.links = reordered;
        end
        cfg = adapter.translate(source, errors);
        require((errors.size() == 0) && (cfg != null),
                "shuffled Switch-link translation");
        require((adapter.switch_usp_link_ids.size() == 2) &&
                (adapter.switch_usp_link_ids[0] == "UP0") &&
                (adapter.switch_usp_link_ids[1] == "UP1"),
                "shuffled Switch USP IDs follow physical ports");
        require((adapter.switch_dsp_link_ids.size() == 3) &&
                (adapter.switch_dsp_link_ids[0] == "DOWN0") &&
                (adapter.switch_dsp_link_ids[1] == "DOWN1") &&
                (adapter.switch_dsp_link_ids[2] == "DOWN2"),
                "shuffled Switch DSP IDs follow physical ports");
        if (cfg != null) begin
            cfg.rc_agent_enable = 0;
            adapter.audit(source, cfg, errors);
            require(errors_contain(errors, "RC agent is disabled"),
                    "Switch audit detects disabled RC agent");
            cfg.rc_agent_enable = 1;

            cfg.ep_agent_enable = 0;
            adapter.audit(source, cfg, errors);
            require(errors_contain(errors, "Endpoint agent is disabled"),
                    "Switch audit detects disabled Endpoint agent");
            cfg.ep_agent_enable = 1;
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

            cfg.switch_cfg.num_usp++;
            adapter.audit(source, cfg, errors);
            require(adapter.error_contains(errors,
                                            "Switch USP count mismatch"),
                    "Switch audit detects corrupted native USP count");
            cfg.switch_cfg.num_usp--;

            cfg.switch_cfg.num_ds_ports++;
            adapter.audit(source, cfg, errors);
            require(adapter.error_contains(errors,
                                            "Switch DSP count mismatch"),
                    "Switch audit detects corrupted native DSP count");
            cfg.switch_cfg.num_ds_ports--;

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

class pcie_tl_topology_adapter_capacity_unit_test extends uvm_test;
    `uvm_component_utils(pcie_tl_topology_adapter_capacity_unit_test)

    function new(string name = "pcie_tl_topology_adapter_capacity_unit_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void require(bit condition, string message);
        if (!condition) `uvm_error("TOPO_CAPACITY", message)
    endfunction

    function bit errors_contain(input string errors[$], string fragment);
        foreach (errors[i]) begin
            if (uvm_is_match({"*", fragment, "*"}, errors[i])) return 1;
        end
        return 0;
    endfunction

    function pcie_topology_cfg build_switch_graph(int num_usp, int num_dsp,
                                                   input int owners[]);
        pcie_topology_builder builder;

        builder = new("capacity_builder");
        for (int i = 0; i < num_usp; i++)
            void'(builder.add_rc($sformatf("RC%0d", i)));
        void'(builder.add_switch("SW0", num_usp, num_dsp, owners));
        for (int i = 0; i < num_dsp; i++)
            void'(builder.add_ep($sformatf("EP%0d", i)));
        for (int i = 0; i < num_usp; i++) begin
            void'(builder.connect($sformatf("UP%0d", i),
                                  $sformatf("RC%0d", i),
                                  PCIE_TOPO_PORT_RC, 0,
                                  "SW0", PCIE_TOPO_PORT_USP, i, 8, 4));
        end
        for (int i = 0; i < num_dsp; i++) begin
            void'(builder.connect($sformatf("DOWN%0d", i),
                                  "SW0", PCIE_TOPO_PORT_DSP, i,
                                  $sformatf("EP%0d", i),
                                  PCIE_TOPO_PORT_EP, 0, 4, 4));
        end
        return builder.finish();
    endfunction

    task run_phase(uvm_phase phase);
        pcie_tl_topology_adapter adapter;
        pcie_tl_env_config cfg;
        pcie_topology_cfg source;
        string capacity_case;
        string errors[$];
        string validation_errors[$];
        int owners[];

        phase.raise_objection(this);
        adapter = pcie_tl_topology_adapter::type_id::create("adapter");
        if (!$value$plusargs("CAPACITY_CASE=%s", capacity_case))
            `uvm_fatal("TOPO_CAPACITY", "CAPACITY_CASE is required")

        case (capacity_case)
            "9USP": begin
                owners = new[9];
                foreach (owners[i]) owners[i] = i;
                source = build_switch_graph(9, 9, owners);
            end
            "17DSP": begin
                owners = new[17];
                foreach (owners[i]) owners[i] = (i < 9) ? 0 : 1;
                source = build_switch_graph(2, 17, owners);
            end
            default:
                `uvm_fatal("TOPO_CAPACITY", $sformatf(
                    "unsupported CAPACITY_CASE '%s'", capacity_case))
        endcase

        source.validate(validation_errors);
        require(validation_errors.size() == 0,
                "capacity fixture must be valid in the common topology model");
        cfg = adapter.translate(source, errors);
        require(cfg == null,
                "unrepresentable Switch topology must return null");
        if (capacity_case == "9USP") begin
            require(errors_contain(errors, "at most 8 Switch USPs"),
                    "9-USP topology reports the native USP capacity");
        end
        else begin
            require(errors_contain(errors,
                                    "USP0 owns 9 DSPs; maximum is 8"),
                    "9-DSP root reports the native per-USP capacity");
        end
        phase.drop_objection(this);
    endtask
endclass
