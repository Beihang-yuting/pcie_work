import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_tl_custom_base_test extends uvm_test;
    `uvm_component_utils(pcie_tl_custom_base_test)

    // 拓扑测试现在直接使用正式 pcie_tl_env。
    // 拓扑解析由正式环境自身完成，测试不再依赖第二套环境类型。
    pcie_tl_env env;
    pcie_topology_cfg topology_cfg;
    pcie_tl_env_config tl_policy_cfg;

    function new(string name = "pcie_tl_custom_base_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void configure_tl_policy();
        tl_policy_cfg.if_mode = TLM_MODE;
    endfunction

    // Return 1 and set result to bypass named profiles. Returning 0 selects CLI.
    virtual function bit configure_topology(output pcie_topology_cfg result);
        result = null;
        return 0;
    endfunction

    protected function void get_occurrences(
        string stem, string value_prefix,
        output string raw[$], output string values[$]);
        uvm_cmdline_processor clp;

        clp = uvm_cmdline_processor::get_inst();
        raw.delete();
        values.delete();
        void'(clp.get_arg_matches(stem, raw));
        void'(clp.get_arg_values(value_prefix, values));
    endfunction

    virtual function void build_phase(uvm_phase phase);
        string topology_raw[$];
        string topology_values[$];
        string gen_raw[$];
        string gen_values[$];
        pcie_topology_cfg programmatic_cfg;
        bit programmatic;
        int generation;

        super.build_phase(phase);
        tl_policy_cfg = pcie_tl_env_config::type_id::create("tl_policy_cfg");
        configure_tl_policy();
        get_occurrences("+PCIE_TOPOLOGY", "+PCIE_TOPOLOGY=",
                        topology_raw, topology_values);
        get_occurrences("+PCIE_GEN", "+PCIE_GEN=", gen_raw, gen_values);
        programmatic = configure_topology(programmatic_cfg);

        if (programmatic) begin
            if (programmatic_cfg == null) begin
                `uvm_fatal("TOPO_CLI",
                           "programmatic topology hook returned null")
                return;
            end
            if ((topology_raw.size() != 0) || (gen_raw.size() != 0)) begin
                `uvm_fatal(
                    "TOPO_CLI",
                    {"programmatic topology cannot be mixed with ",
                     "PCIE_TOPOLOGY or PCIE_GEN"})
                return;
            end
            topology_cfg = programmatic_cfg;
        end
        else begin
            if ((topology_raw.size() != 1) ||
                (topology_values.size() != 1) ||
                (topology_values[0].len() == 0)) begin
                `uvm_fatal(
                    "TOPO_CLI",
                    "exactly one non-empty +PCIE_TOPOLOGY=<profile> is required")
                return;
            end
            if ((gen_raw.size() != 1) || (gen_values.size() != 1) ||
                (gen_values[0].len() == 0)) begin
                `uvm_fatal(
                    "TOPO_CLI",
                    "exactly one +PCIE_GEN=4 or +PCIE_GEN=5 is required")
                return;
            end

            if (gen_values[0] == "4") generation = 4;
            else if (gen_values[0] == "5") generation = 5;
            else begin
                `uvm_fatal(
                    "TOPO_CLI",
                    "exactly one +PCIE_GEN=4 or +PCIE_GEN=5 is required")
                return;
            end

            case (topology_values[0])
                "EP_X16": begin
                    topology_cfg =
                        pcie_topology_builder::build_ep_x16(generation);
                end
                "EP_2X8": begin
                    topology_cfg =
                        pcie_topology_builder::build_ep_2x8(generation);
                end
                "SWITCH_1X16_4X4": begin
                    topology_cfg = pcie_topology_builder::
                        build_switch_1x16_4x4(generation);
                end
                default: begin
                    `uvm_fatal("TOPO_CLI", $sformatf(
                        "unknown PCIE_TOPOLOGY value '%s'",
                        topology_values[0]))
                    return;
                end
            endcase
        end

        uvm_config_db#(pcie_topology_cfg)::set(
            this, "env", "topology_cfg", topology_cfg);
        uvm_config_db#(pcie_tl_env_config)::set(
            this, "env", "tl_policy_cfg", tl_policy_cfg);
        env = pcie_tl_env::type_id::create("env", this);
    endfunction
endclass

class pcie_tl_custom_cfg_precedence_test extends pcie_tl_custom_base_test;
    `uvm_component_utils(pcie_tl_custom_cfg_precedence_test)

    pcie_tl_env_config conflicting_cfg;

    function new(string name = "pcie_tl_custom_cfg_precedence_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        conflicting_cfg = pcie_tl_env_config::type_id::create(
            "conflicting_cfg");
        conflicting_cfg.switch_enable = 0;
        conflicting_cfg.num_rc = 1;
        conflicting_cfg.num_ep = 1;
        uvm_config_db#(pcie_tl_env_config)::set(
            this, "env", "cfg", conflicting_cfg);
        super.build_phase(phase);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        if ((env == null) || (env.cfg == null)) begin
            `uvm_error("TOPO_CFG", "pcie_tl_env did not build a native cfg")
        end
        else if ((env.cfg != tl_policy_cfg) || env.cfg.switch_enable ||
                 (env.cfg.num_rc != 2) || (env.cfg.num_ep != 2)) begin
            `uvm_error("TOPO_CFG", $sformatf(
                {"translated EP_2X8 cfg was not authoritative: ",
                 "switch=%0b num_rc=%0d num_ep=%0d"},
                env.cfg.switch_enable, env.cfg.num_rc, env.cfg.num_ep))
        end
    endfunction
endclass

//------------------------------------------------------------------------------
// pcie_tl_env Root 映射回归。
//
// 验证生产编排路径：global_cfg 携带 DPU 风格 Root 元数据，
// pcie_tl_env 按物理链路顺序转换，并将每个 Endpoint 连接到指定 Root。
//------------------------------------------------------------------------------
class pcie_tl_custom_root_mapping_test extends pcie_tl_custom_base_test;
    `uvm_component_utils(pcie_tl_custom_root_mapping_test)

    pcie_global_cfg global_cfg;

    function new(string name = "pcie_tl_custom_root_mapping_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function bit configure_topology(output pcie_topology_cfg result);
        result = pcie_topology_builder::build_ep_2x8(4);
        return 1'b1;
    endfunction

    virtual function void build_phase(uvm_phase phase);
        pcie_topology_cfg source;

        // pcie_tl_env 创建前发布 global_cfg；EP 元数据故意反转两条
        // 物理 Root 链路，用来验证映射而不是数组顺序生效。
        source = pcie_topology_builder::build_ep_2x8(4);
        global_cfg = pcie_global_cfg::type_id::create("global_cfg");
        global_cfg.build_default_for_topology(source);
        global_cfg.devices[1].root_index_valid = 1'b1;
        global_cfg.devices[1].root_index = 1;
        global_cfg.devices[3].root_index_valid = 1'b1;
        global_cfg.devices[3].root_index = 0;
        uvm_config_db#(pcie_global_cfg)::set(
            this, "env", "global_cfg", global_cfg);

        super.build_phase(phase);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        if ((env == null) || (env.ep_agents.size() != 2)) begin
            `uvm_error("ROOT_MAP", "pcie_tl_env did not create two EP agents")
            return;
        end
        if (env.ep_agents[0].fc_mgr != env.fc_mgrs[1])
            `uvm_error("ROOT_MAP",
                       "custom EP0 did not use mapped Root1 manager")
        if (env.ep_agents[1].fc_mgr != env.fc_mgrs[0])
            `uvm_error("ROOT_MAP",
                       "custom EP1 did not use mapped Root0 manager")
    endfunction
endclass

//------------------------------------------------------------------------------
// EP configuration context must follow canonical physical-link order even when
// topology node declarations are shuffled.  The topology adapter orders direct
// links lexically by link_id, while build_default_for_topology() intentionally
// retains node declaration order for device/BDF records.  These two orders are
// independent and must be joined by the physical EP node ID.
//------------------------------------------------------------------------------
class pcie_tl_custom_shuffled_ep_context_test extends pcie_tl_custom_base_test;
    `uvm_component_utils(pcie_tl_custom_shuffled_ep_context_test)

    pcie_global_cfg global_cfg;
    pcie_topology_cfg shuffled_topology;

    function new(string name = "pcie_tl_custom_shuffled_ep_context_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function bit configure_topology(output pcie_topology_cfg result);
        pcie_topology_builder builder;

        // Keep node declarations in Z/A order, but link IDs in the reverse
        // lexical order.  The adapter therefore creates EP agent 0 for A_LINK
        // and EP agent 1 for Z_LINK, unlike the device-policy declaration
        // order (EP_Z then EP_A).
        if (shuffled_topology == null) begin
            builder = pcie_topology_builder::type_id::create(
                "shuffled_ep_context_builder");
            void'(builder.add_rc("RC_Z"));
            void'(builder.add_ep("EP_Z"));
            void'(builder.add_rc("RC_A"));
            void'(builder.add_ep("EP_A"));
            void'(builder.connect("Z_LINK", "RC_Z", PCIE_TOPO_PORT_RC, 0,
                                  "EP_Z", PCIE_TOPO_PORT_EP, 0, 8, 4));
            void'(builder.connect("A_LINK", "RC_A", PCIE_TOPO_PORT_RC, 0,
                                  "EP_A", PCIE_TOPO_PORT_EP, 0, 8, 4));
            shuffled_topology = builder.finish();
        end
        result = shuffled_topology;
        return 1'b1;
    endfunction

    virtual function void build_phase(uvm_phase phase);
        pcie_topology_cfg source;

        void'(configure_topology(source));
        global_cfg = pcie_global_cfg::type_id::create(
            "shuffled_ep_context_global_cfg");
        global_cfg.build_default_for_topology(source);
        uvm_config_db#(pcie_global_cfg)::set(
            this, "env", "global_cfg", global_cfg);

        super.build_phase(phase);
    endfunction

    // device_contexts 的 key 自"BDF 唯一性按逻辑域限定"改造后不再是裸
    // BDF，而是 pcie_device_cfg::context_key() 生成的域限定字符串
    // （h<host>.s<segment>.<bdf>）。测试侧不应自行拼 key 格式，而是在
    // env.cfg.device_cfgs 中按 BDF 找到对应设备策略，复用其 context_key()
    // 查表；找不到设备或上下文时返回 null，由调用方统一报错。
    virtual function pcie_tl_func_context find_context_by_bdf(bit [15:0] bdf);
        foreach (env.cfg.device_cfgs[i]) begin
            if ((env.cfg.device_cfgs[i] != null) &&
                (env.cfg.device_cfgs[i].bdf == bdf) &&
                env.device_contexts.exists(
                    env.cfg.device_cfgs[i].context_key()))
                return env.device_contexts[
                    env.cfg.device_cfgs[i].context_key()];
        end
        return null;
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        pcie_tl_func_context ep_a_context;
        pcie_tl_func_context ep_z_context;

        super.end_of_elaboration_phase(phase);
        if ((env == null) || (env.ep_agents.size() != 2)) begin
            `uvm_error("EP_CONTEXT_ORDER",
                       "shuffled topology did not create two EP agents")
            return;
        end

        ep_a_context = find_context_by_bdf(16'h0208);
        ep_z_context = find_context_by_bdf(16'h0200);
        if ((ep_a_context == null) || (ep_z_context == null)) begin
            `uvm_error("EP_CONTEXT_ORDER",
                       "expected shuffled EP BDF contexts are missing")
            return;
        end
        if ((env.ep_agents[0].cfg_mgr != ep_a_context.cfg_mgr) ||
            (env.ep_agents[1].cfg_mgr != ep_z_context.cfg_mgr)) begin
            `uvm_error("EP_CONTEXT_ORDER",
                       "EP cfg managers did not follow canonical link/node order")
        end
    endfunction
endclass
