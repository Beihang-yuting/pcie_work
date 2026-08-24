import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_tl_custom_base_test extends uvm_test;
    `uvm_component_utils(pcie_tl_custom_base_test)

    pcie_tl_custom_env env;
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
        env = pcie_tl_custom_env::type_id::create("env", this);
    endfunction
endclass
