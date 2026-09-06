import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_tl_custom_profile_test extends pcie_tl_custom_base_test;
    `uvm_component_utils(pcie_tl_custom_profile_test)

    bit traffic_failed;

    function new(string name = "pcie_tl_custom_profile_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void configure_tl_policy();
        super.configure_tl_policy();
        tl_policy_cfg.use_unified_mem = 0;
        tl_policy_cfg.fc_enable = 1;
        tl_policy_cfg.infinite_credit = 1;
        tl_policy_cfg.ep_auto_response = 1;
        tl_policy_cfg.scb_enable = 1;
        tl_policy_cfg.cpl_timeout_ns = 200000;
    endfunction

    protected function void traffic_error(string message);
        traffic_failed = 1;
        `uvm_error("TOPO_TRAFFIC", message)
    endfunction

    function pcie_tl_ep_agent endpoint_at(int index);
        if ((env != null) && (index >= 0) &&
            (index < env.ep_agents.size()) &&
            (env.ep_agents[index] != null)) begin
            return env.ep_agents[index];
        end
        if ((env != null) && (index == 0)) return env.ep_agent;
        return null;
    endfunction

    task downstream_roundtrip(int pair, bit [63:0] address);
        pcie_tl_rw_seq write_seq;
        pcie_tl_rw_seq read_seq;
        bit [7:0] pattern[];
        int byte_count;

        byte_count = 32;
        if ((env == null) || (pair < 0) ||
            (pair >= env.rc_agents.size()) ||
            (env.rc_agents[pair] == null) ||
            (env.rc_agents[pair].sequencer == null)) begin
            traffic_error($sformatf(
                "downstream pair %0d has no RC sequencer", pair));
            return;
        end

        pattern = new[byte_count];
        foreach (pattern[i])
            pattern[i] = byte'(8'h40 + pair * 8'h20 + i);

        write_seq = pcie_tl_rw_seq::type_id::create(
            $sformatf("profile_write_pair_%0d", pair));
        write_seq.op = PCIE_RW_WRITE;
        write_seq.addr = address;
        write_seq.byte_len = byte_count;
        write_seq.wdata = new[byte_count];
        foreach (write_seq.wdata[i]) write_seq.wdata[i] = pattern[i];
        write_seq.start(env.rc_agents[pair].sequencer);

        #1us;

        read_seq = pcie_tl_rw_seq::type_id::create(
            $sformatf("profile_read_pair_%0d", pair));
        read_seq.op = PCIE_RW_READ;
        read_seq.addr = address;
        read_seq.byte_len = byte_count;
        read_seq.start(env.rc_agents[pair].sequencer);

        if (read_seq.status != PCIE_RW_OK) begin
            traffic_error($sformatf(
                "pair %0d read status=%s address=0x%016h",
                pair, read_seq.status.name(), address));
            return;
        end
        if (read_seq.rdata.size() != byte_count) begin
            traffic_error($sformatf(
                "pair %0d read size=%0d expected=%0d address=0x%016h",
                pair, read_seq.rdata.size(), byte_count, address));
            return;
        end
        foreach (pattern[i]) begin
            if (read_seq.rdata[i] !== pattern[i]) begin
                traffic_error($sformatf(
                    {"pair %0d byte %0d mismatch expected=0x%02h ",
                     "actual=0x%02h address=0x%016h"},
                    pair, i, pattern[i], read_seq.rdata[i], address));
                return;
            end
        end
    endtask

    task upstream_read(int ep_index);
        pcie_tl_ep_agent ep;
        pcie_tl_rw_seq read_seq;
        bit [63:0] address;
        int byte_count;

        byte_count = 16;
        address = 64'h0000_1000 + ep_index * 64'h0000_0100;
        ep = endpoint_at(ep_index);
        if ((ep == null) || (ep.sequencer == null)) begin
            traffic_error($sformatf(
                "endpoint %0d has no sequencer", ep_index));
            return;
        end

        read_seq = pcie_tl_rw_seq::type_id::create(
            $sformatf("profile_upstream_read_ep_%0d", ep_index));
        read_seq.op = PCIE_RW_READ;
        read_seq.addr = address;
        read_seq.byte_len = byte_count;
        read_seq.start(ep.sequencer);

        if (read_seq.status != PCIE_RW_OK) begin
            traffic_error($sformatf(
                "endpoint %0d upstream read status=%s address=0x%016h",
                ep_index, read_seq.status.name(), address));
            return;
        end
        if (read_seq.rdata.size() != byte_count) begin
            traffic_error($sformatf(
                {"endpoint %0d upstream read size=%0d expected=%0d ",
                 "address=0x%016h"},
                ep_index, read_seq.rdata.size(), byte_count, address));
        end
    endtask

    task run_phase(uvm_phase phase);
        int endpoint_count;
        bit structure_ok;

        phase.raise_objection(this);
        traffic_failed = 0;
        structure_ok = 1;
        endpoint_count = 0;

        if ((env == null) || (env.cfg == null)) begin
            traffic_error("pcie_tl_env or native config is null");
            structure_ok = 0;
        end
        else if (env.cfg.switch_enable) begin
            if (env.cfg.switch_cfg == null) begin
                traffic_error("switch config is null");
                structure_ok = 0;
            end
            else begin
                endpoint_count = env.cfg.switch_cfg.num_ds_ports;
                if (env.sw == null) begin
                    traffic_error("switch component is null");
                    structure_ok = 0;
                end
                else begin
                    if (env.sw.usp == null) begin
                        traffic_error("switch USP is null");
                        structure_ok = 0;
                    end
                    if (env.sw.usps.size() != env.cfg.switch_cfg.num_usp) begin
                        traffic_error($sformatf(
                            "switch USP count=%0d expected=%0d",
                            env.sw.usps.size(), env.cfg.switch_cfg.num_usp));
                        structure_ok = 0;
                    end
                    if (env.sw.dsp.size() != endpoint_count) begin
                        traffic_error($sformatf(
                            "switch DSP count=%0d expected=%0d",
                            env.sw.dsp.size(), endpoint_count));
                        structure_ok = 0;
                    end
                end
                if (env.ep_agents.size() != endpoint_count) begin
                    traffic_error($sformatf(
                        "endpoint agent count=%0d expected=%0d",
                        env.ep_agents.size(), endpoint_count));
                    structure_ok = 0;
                end
            end

            if (structure_ok) begin
                for (int i = 0; i < endpoint_count; i++) begin
                    bit [31:0] bus_register;
                    bit [63:0] memory_base;

                    bus_register = env.sw.dsp[i].cfg_read(12'h018);
                    if (bus_register[15:8] !==
                        env.cfg.switch_cfg.ds_secondary_bus[i]) begin
                        traffic_error($sformatf(
                            {"DSP %0d secondary bus=0x%02h expected=0x%02h ",
                             "cfg018=0x%08h"},
                            i, bus_register[15:8],
                            env.cfg.switch_cfg.ds_secondary_bus[i],
                            bus_register));
                    end
                    memory_base = {
                        32'h0000_0000, env.cfg.switch_cfg.ds_mem_base[i]};
                    downstream_roundtrip(0, memory_base);
                    upstream_read(i);
                end
            end
        end
        else begin
            endpoint_count = env.cfg.num_ep;
            for (int pair_index = 0;
                 pair_index < endpoint_count; pair_index++) begin
                automatic int pair = pair_index;
                fork
                    downstream_roundtrip(pair, 64'h0000_0000_0001_0000);
                join_none
            end
            wait fork;
            for (int i = 0; i < endpoint_count; i++) upstream_read(i);
        end

        if (!traffic_failed)
            `uvm_info("TOPO_TRAFFIC", $sformatf(
                "PROFILE_TRAFFIC_PASS endpoints=%0d", endpoint_count), UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass

class pcie_tl_programmatic_1dsp_1ep_test extends pcie_tl_custom_profile_test;
    `uvm_component_utils(pcie_tl_programmatic_1dsp_1ep_test)

    function new(string name = "pcie_tl_programmatic_1dsp_1ep_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function bit configure_topology(output pcie_topology_cfg result);
        pcie_topology_builder builder;
        int owners[];

        builder = pcie_topology_builder::type_id::create(
            "programmatic_1dsp_1ep_builder");
        owners = new[1];
        owners[0] = 0;

        builder.add_rc("RC0");
        builder.add_switch("SW0", 1, 1, owners);
        builder.add_ep("EP0");
        builder.connect("RC0_SW0_USP0",
                        "RC0", PCIE_TOPO_PORT_RC, 0,
                        "SW0", PCIE_TOPO_PORT_USP, 0, 16, 5);
        builder.connect("SW0_DSP0_EP0",
                        "SW0", PCIE_TOPO_PORT_DSP, 0,
                        "EP0", PCIE_TOPO_PORT_EP, 0, 4, 5);
        result = builder.finish();
        return 1;
    endfunction
endclass
