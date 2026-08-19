//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Switch Top-Level
//-----------------------------------------------------------------------------

// The full pcie_tl_pkg includes this class directly, while the lightweight
// switch package includes the route-event type earlier in its package body.
`include "switch/pcie_tl_switch_route_event.sv"

class pcie_tl_switch extends uvm_component;
    `uvm_component_utils(pcie_tl_switch)

    //--- Configuration ---
    pcie_tl_switch_config  sw_cfg;

    //--- Ports ---
    pcie_tl_switch_port    usps[];   // [num_usp]
    pcie_tl_switch_port    usp;       // alias = usps[0]; back-compat for env/tests (single-root)
    pcie_tl_switch_port    dsp[];

    //--- All ports flat array for fabric ---
    pcie_tl_switch_port    all_ports[];

    //--- Routing Fabric ---
    pcie_tl_switch_fabric  fabric;

    //--- Dynamic routing state ---
    int local_bdf_to_port[bit [15:0]];
    int outstanding_ingress[switch_np_key_t];
    bit enum_cfg_write_completed[];

    //--- Route observation ---
    uvm_analysis_port #(pcie_tl_switch_route_event) route_observed_port;
    longint unsigned next_route_event_id;

    //--- Statistics ---
    int total_routed   = 0;
    int total_dropped  = 0;
    int total_p2p      = 0;
    int total_bcast    = 0;

    function new(string name = "pcie_tl_switch", uvm_component parent = null);
        super.new(name, parent);
        route_observed_port = new("route_observed_port", this);
        next_route_event_id = 0;
    endfunction

    protected function void publish_route_event(
        pcie_tl_switch_route_action_e action,
        int ingress_port, int egress_port, int route_code,
        pcie_tl_tlp ingress_tlp, pcie_tl_tlp egress_tlp);
        pcie_tl_switch_route_event route_event;

        route_event = pcie_tl_switch_route_event::type_id::create(
            $sformatf("route_event_%0d", next_route_event_id));
        if (route_event == null)
            `uvm_fatal("SWITCH_ROUTE_EVENT_CREATE", "event creation failed")
        route_event.event_id = next_route_event_id++;
        route_event.action = action;
        route_event.ingress_port = ingress_port;
        route_event.egress_port = egress_port;
        route_event.route_code = route_code;
        route_event.set_snapshots(ingress_tlp, egress_tlp);
        route_observed_port.write(route_event);
    endfunction

    function int unsigned outstanding_count();
        return outstanding_ingress.num();
    endfunction

    function void refresh_local_bdf_map();
        local_bdf_to_port.delete();
        foreach (all_ports[i]) begin
            bit [15:0] local_bdf = all_ports[i].bdf;
            if (local_bdf_to_port.exists(local_bdf))
                `uvm_fatal("SWITCH_DUP_BDF", $sformatf(
                    "bdf=%04h ports=%0d,%0d", local_bdf,
                    local_bdf_to_port[local_bdf], i))
            local_bdf_to_port[local_bdf] = i;
        end
    endfunction

    function int local_port_for_bdf(bit [15:0] bdf);
        if (local_bdf_to_port.exists(bdf))
            return local_bdf_to_port[bdf];
        return SWITCH_ROUTE_DROP;
    endfunction

    function void build_phase(uvm_phase phase);
        int nu, nd;
        super.build_phase(phase);

        if (sw_cfg == null)
            `uvm_fatal("SWITCH", "sw_cfg is null")

        // dsp_owner[] is filled by init_defaults(); the env/test calls it before switch build.
        if (sw_cfg.dsp_owner.size() != sw_cfg.num_ds_ports)
            sw_cfg.init_defaults();

        nu = sw_cfg.num_usp;
        nd = sw_cfg.num_ds_ports;

        // Port layout: [USP_0..USP_{nu-1}, DSP_0..DSP_{nd-1}]
        usps = new[nu];
        for (int r = 0; r < nu; r++) begin
            usps[r] = pcie_tl_switch_port::type_id::create($sformatf("usp_%0d", r), this);
            usps[r].role    = SWITCH_USP;
            usps[r].port_id = r;
            usps[r].root_id = r;
            // Root 0 preserves the public single-root identity contract.
            // Additional roots use their root-qualified secondary-bus BDF.
            usps[r].init_type1_image(SWITCH_USP, r,
                                     (r == 0) ? sw_cfg.switch_bdf :
                                     {sw_cfg.usp_sec_bus[r], 8'h00});
        end
        usp = usps[0];   // alias for back-compat (single-root)

        dsp = new[nd];
        for (int i = 0; i < nd; i++) begin
            bit [15:0] dsp_bdf;
            int owner_local_dev = 0;
            dsp[i] = pcie_tl_switch_port::type_id::create($sformatf("dsp_%0d", i), this);
            dsp[i].role      = SWITCH_DSP;
            dsp[i].port_id   = nu + i;
            dsp[i].owner_usp = sw_cfg.dsp_owner[i];
            for (int j = 0; j < i; j++)
                if (sw_cfg.dsp_owner[j] == sw_cfg.dsp_owner[i])
                    owner_local_dev++;
            dsp_bdf = {8'(sw_cfg.usp_sec_bus[dsp[i].owner_usp] + 1),
                       5'(owner_local_dev), 3'b000};
            dsp[i].init_type1_image(SWITCH_DSP, i, dsp_bdf);
        end

        all_ports = new[nu + nd];
        for (int r = 0; r < nu; r++) all_ports[r]      = usps[r];
        for (int i = 0; i < nd; i++) all_ports[nu + i] = dsp[i];
        enum_cfg_write_completed = new[nu + nd];

        fabric = pcie_tl_switch_fabric::type_id::create("fabric");
        fabric.ports      = all_ports;
        fabric.num_ports  = nu + nd;
        fabric.num_usp    = nu;
        fabric.p2p_enable = sw_cfg.p2p_enable;

        refresh_local_bdf_map();
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (!sw_cfg.enum_mode) begin
            for (int r = 0; r < sw_cfg.num_usp; r++)
                usps[r].apply_config(sw_cfg, r);   // r = root index → per-root usp_*[r] domain
            for (int i = 0; i < sw_cfg.num_ds_ports; i++) begin
                dsp[i].apply_config(sw_cfg, i);
                dsp[i].command[1] = 1'b1;
            end
        end
    endfunction

    task run_phase(uvm_phase phase);
        fork
            begin
                for (int r = 0; r < sw_cfg.num_usp; r++) begin
                    automatic int rr = r;
                    fork usp_forward_loop(rr); join_none
                end
                for (int i = 0; i < sw_cfg.num_ds_ports; i++) begin
                    automatic int ii = i;
                    fork dsp_forward_loop(ii); join_none
                end
            end
        join_none
    endtask

    protected task usp_forward_loop(int root_idx);
        pcie_tl_tlp tlp;
        forever begin
            usps[root_idx].rx_fifo.get(tlp);
            route_and_forward(tlp, root_idx);   // ingress port_id = root index
        end
    endtask

    protected task dsp_forward_loop(int port_idx);
        pcie_tl_tlp tlp;
        forever begin
            dsp[port_idx].rx_fifo.get(tlp);
            route_and_forward(tlp, sw_cfg.num_usp + port_idx);
        end
    endtask

    protected task route_and_forward(pcie_tl_tlp tlp, int ingress_port_id);
        int dst;
        bit is_completion;
        switch_np_key_t key;
        pcie_tl_tlp forwarded_tlp;
        pcie_tl_cpl_tlp completion_tlp;
        int local_target_port;
        int unsigned completion_byte_count;
        int unsigned completion_data_capacity;
        bit final_completion;

        if (tlp == null)
            return;

        local_target_port = SWITCH_ROUTE_DROP;
        is_completion = (tlp.get_category() == TLP_CAT_COMPLETION);
        if (is_completion) begin
            key = switch_np_key(tlp.requester_id, tlp.tag);
            if (!outstanding_ingress.exists(key))
                `uvm_fatal("SWITCH_UNKNOWN_CPL", $sformatf(
                    "requester=%04h tag=%03h", tlp.requester_id, tlp.tag))
            dst = outstanding_ingress[key];
            final_completion = 1'b1;
            if ($cast(completion_tlp, tlp) &&
                completion_tlp.kind inside {TLP_CPLD, TLP_CPLD_LK} &&
                completion_tlp.cpl_status == CPL_STATUS_SC) begin
                completion_byte_count = (completion_tlp.byte_count == 0) ?
                                        4096 : completion_tlp.byte_count;
                completion_data_capacity =
                    ((completion_tlp.length == 0) ?
                     4096 : completion_tlp.length * 4) -
                    completion_tlp.lower_addr[1:0];
                final_completion =
                    (completion_data_capacity >= completion_byte_count);
            end
            if (final_completion)
                outstanding_ingress.delete(key);
        end else if (tlp.kind inside {TLP_CFG_RD0, TLP_CFG_WR0,
                                      TLP_CFG_RD1, TLP_CFG_WR1}) begin
            pcie_tl_cfg_tlp cfg_tlp;
            if (!$cast(cfg_tlp, tlp))
                `uvm_fatal("SWITCH_CFG_CAST",
                           "Configuration kind has non-Configuration object")
            local_target_port = local_port_for_bdf(cfg_tlp.completer_id);
            if (local_target_port != SWITCH_ROUTE_DROP) begin
                if (fabric.root_of(local_target_port) !=
                    fabric.root_of(ingress_port_id))
                    dst = SWITCH_ROUTE_CROSS_ROOT;
                else
                    dst = SWITCH_ROUTE_LOCAL;
            end else begin
                dst = fabric.route(tlp, ingress_port_id);
            end
        end else begin
            dst = fabric.route(tlp, ingress_port_id);
        end

        // If routed back to ingress, redirect: DSP self-route → owning USP, USP self-route → drop
        if (!is_completion && dst == ingress_port_id) begin
            if (ingress_port_id >= sw_cfg.num_usp)
                dst = fabric.usp_port_id(all_ports[ingress_port_id].owner_usp); // DSP→self: upstream
            else
                dst = SWITCH_ROUTE_DROP; // USP→self: nowhere to go
        end

        case (dst)
            SWITCH_ROUTE_LOCAL: begin
                handle_local_config(tlp, ingress_port_id, local_target_port);
            end
            SWITCH_ROUTE_DROP: begin
                total_dropped++;
                all_ports[ingress_port_id].dropped_count++;
                publish_route_event(PCIE_TL_ROUTE_DROP,
                                    ingress_port_id, SWITCH_ROUTE_DROP, dst,
                                    tlp, null);
                `uvm_info("SWITCH", $sformatf("DROPPED from port %0d: %s",
                    ingress_port_id, tlp.convert2string()), UVM_MEDIUM)
            end
            SWITCH_ROUTE_CROSS_ROOT: begin
                total_dropped++;
                fabric.cross_root_violations++;
                publish_route_event(PCIE_TL_ROUTE_DROP,
                                    ingress_port_id, SWITCH_ROUTE_DROP, dst,
                                    tlp, null);
                if (sw_cfg.cross_root_check_enable)
                    `uvm_error("CROSS_ROOT", $sformatf("跨根丢弃 from port %0d: %s",
                        ingress_port_id, tlp.convert2string()))
                else
                    `uvm_info("SWITCH", $sformatf("cross-root dropped from port %0d",
                        ingress_port_id), UVM_MEDIUM)
            end
            SWITCH_ROUTE_BCAST: begin
                int ir = fabric.root_of(ingress_port_id);
                total_bcast++;
                publish_route_event(PCIE_TL_ROUTE_UNSUPPORTED_BROADCAST,
                                    ingress_port_id, SWITCH_ROUTE_BCAST,
                                    SWITCH_ROUTE_BCAST, tlp, tlp);
                for (int i = sw_cfg.num_usp; i < all_ports.size(); i++) begin
                    if (i != ingress_port_id && all_ports[i].owner_usp == ir) begin
                        all_ports[i].tx_fifo.put(tlp);
                        all_ports[i].forwarded_count++;
                    end
                end
            end
            default: begin
                if (dst >= 0 && dst < all_ports.size()) begin
                    forwarded_tlp = tlp;
                    if (tlp.kind inside {TLP_CFG_RD0, TLP_CFG_WR0,
                                         TLP_CFG_RD1, TLP_CFG_WR1}) begin
                        pcie_tl_cfg_tlp source_cfg;
                        pcie_tl_cfg_tlp cloned_cfg;

                        if (!$cast(source_cfg, tlp))
                            `uvm_fatal("SWITCH_CFG_CAST",
                                       "Configuration kind has non-Configuration object")
                        if (!$cast(cloned_cfg, source_cfg.clone()))
                            `uvm_fatal("SWITCH_CFG_CLONE",
                                       "Unable to clone Configuration Request")

                        // pcie_tl_cfg_tlp has no subclass do_copy(), so preserve
                        // its fields explicitly. The base clone handles the
                        // remaining common fields except Address Type.
                        cloned_cfg.at           = source_cfg.at;
                        cloned_cfg.completer_id = source_cfg.completer_id;
                        cloned_cfg.reg_num      = source_cfg.reg_num;
                        cloned_cfg.first_be     = source_cfg.first_be;

                        if ((tlp.kind inside {TLP_CFG_RD1, TLP_CFG_WR1}) &&
                            (source_cfg.completer_id[15:8] ==
                             all_ports[dst].route_entry.secondary_bus)) begin
                            if (tlp.kind == TLP_CFG_RD1)
                                cloned_cfg.kind = TLP_CFG_RD0;
                            else
                                cloned_cfg.kind = TLP_CFG_WR0;
                            cloned_cfg.type_f = TLP_TYPE_CFG_RD0;
                        end
                        forwarded_tlp = cloned_cfg;
                    end

                    if (tlp.get_category() == TLP_CAT_NON_POSTED) begin
                        key = switch_np_key(tlp.requester_id, tlp.tag);
                        if (outstanding_ingress.exists(key))
                            `uvm_fatal("SWITCH_DUP_NP", $sformatf(
                                "requester=%04h tag=%03h",
                                tlp.requester_id, tlp.tag))
                        outstanding_ingress[key] = ingress_port_id;
                    end

                    publish_route_event(PCIE_TL_ROUTE_FORWARD,
                                        ingress_port_id, dst, dst,
                                        tlp, forwarded_tlp);
                    all_ports[dst].tx_fifo.put(forwarded_tlp);
                    all_ports[dst].forwarded_count++;
                    total_routed++;
                    if (ingress_port_id >= sw_cfg.num_usp && dst >= sw_cfg.num_usp)
                        total_p2p++;  // DSP→DSP (num_usp==1: ingress>0 && dst>0)
                end else begin
                    total_dropped++;
                    publish_route_event(PCIE_TL_ROUTE_DROP,
                                        ingress_port_id, SWITCH_ROUTE_DROP,
                                        dst, tlp, null);
                    `uvm_warning("SWITCH", $sformatf("Bad route dst=%0d from port %0d",
                        dst, ingress_port_id))
                end
            end
        endcase
    endtask

    protected task handle_local_config(pcie_tl_tlp tlp, int ingress_port_id,
                                       int target_port);
        pcie_tl_cfg_tlp cfg_tlp;
        pcie_tl_cpl_tlp cpl;

        if (!$cast(cfg_tlp, tlp)) return;

        if (target_port < 0 || target_port >= all_ports.size())
            `uvm_fatal("SWITCH_LOCAL_CFG", $sformatf(
                "invalid target port %0d for BDF %04h",
                target_port, cfg_tlp.completer_id))
        begin
            if (tlp.kind inside {TLP_CFG_RD0, TLP_CFG_RD1}) begin
                bit [31:0] data = all_ports[target_port].cfg_read({cfg_tlp.reg_num, 2'b00});
                cpl = pcie_tl_cpl_tlp::type_id::create("sw_cfg_cpl");
                cpl.kind         = TLP_CPLD;
                cpl.fmt          = FMT_3DW_WITH_DATA;
                cpl.type_f       = TLP_TYPE_CPL;
                cpl.tc           = tlp.tc;
                cpl.attr         = tlp.attr;
                cpl.length       = 1;
                cpl.requester_id = tlp.requester_id;
                cpl.tag          = tlp.tag;
                cpl.completer_id =
                    (sw_cfg.enum_mode &&
                     !enum_cfg_write_completed[target_port]) ?
                    16'h0000 : all_ports[target_port].bdf;
                cpl.cpl_status   = CPL_STATUS_SC;
                cpl.byte_count   = 4;
                cpl.lower_addr   = 0;
                cpl.payload      = new[4];
                cpl.payload[0]   = data[7:0];
                cpl.payload[1]   = data[15:8];
                cpl.payload[2]   = data[23:16];
                cpl.payload[3]   = data[31:24];
                publish_route_event(PCIE_TL_ROUTE_LOCAL_RESPONSE,
                                    ingress_port_id, ingress_port_id,
                                    SWITCH_ROUTE_LOCAL, tlp, cpl);
                all_ports[ingress_port_id].tx_fifo.put(cpl);
            end else begin
                bit [31:0] data = 0;
                if (tlp.payload.size() >= 4)
                    data = {tlp.payload[3], tlp.payload[2], tlp.payload[1], tlp.payload[0]};
                all_ports[target_port].cfg_write({cfg_tlp.reg_num, 2'b00}, data, cfg_tlp.first_be);
                if (sw_cfg.enum_mode &&
                    (tlp.kind inside {TLP_CFG_WR0, TLP_CFG_WR1}))
                    enum_cfg_write_completed[target_port] = 1'b1;
                cpl = pcie_tl_cpl_tlp::type_id::create("sw_cfg_cpl");
                cpl.kind         = TLP_CPL;
                cpl.fmt          = FMT_3DW_NO_DATA;
                cpl.type_f       = TLP_TYPE_CPL;
                cpl.tc           = tlp.tc;
                cpl.attr         = tlp.attr;
                cpl.length       = 0;
                cpl.requester_id = tlp.requester_id;
                cpl.tag          = tlp.tag;
                cpl.completer_id =
                    (sw_cfg.enum_mode &&
                     !enum_cfg_write_completed[target_port]) ?
                    16'h0000 : all_ports[target_port].bdf;
                cpl.cpl_status   = CPL_STATUS_SC;
                cpl.byte_count   = sw_cfg.enum_mode ? 4 : 0;
                cpl.lower_addr   = 0;
                publish_route_event(PCIE_TL_ROUTE_LOCAL_RESPONSE,
                                    ingress_port_id, ingress_port_id,
                                    SWITCH_ROUTE_LOCAL, tlp, cpl);
                all_ports[ingress_port_id].tx_fifo.put(cpl);
            end
        end
    endtask

    function void report_phase(uvm_phase phase);
        `uvm_info("SWITCH", $sformatf(
            "\n============ Switch Report ============\n  Ports: %0d USP + %0d DSP\n  Total routed:  %0d\n  Total P2P:     %0d\n  Total bcast:   %0d\n  Total dropped: %0d\n  Cross-root violations: %0d\n=======================================",
            sw_cfg.num_usp, sw_cfg.num_ds_ports, total_routed, total_p2p, total_bcast,
            total_dropped, fabric.cross_root_violations), UVM_LOW)
    endfunction

endclass
