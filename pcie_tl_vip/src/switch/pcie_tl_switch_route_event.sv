//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Switch Route Observation Event
//-----------------------------------------------------------------------------

`ifndef PCIE_TL_SWITCH_ROUTE_EVENT_SV
`define PCIE_TL_SWITCH_ROUTE_EVENT_SV

typedef enum int unsigned {
    PCIE_TL_ROUTE_FORWARD,
    PCIE_TL_ROUTE_LOCAL_RESPONSE,
    PCIE_TL_ROUTE_DROP,
    PCIE_TL_ROUTE_UNSUPPORTED_BROADCAST
} pcie_tl_switch_route_action_e;

class pcie_tl_switch_route_event extends uvm_object;
    `uvm_object_utils(pcie_tl_switch_route_event)

    longint unsigned event_id;
    pcie_tl_switch_route_action_e action;
    int ingress_port;
    int egress_port;
    int route_code;
    pcie_tl_tlp ingress_tlp;
    pcie_tl_tlp egress_tlp;

    function new(string name = "pcie_tl_switch_route_event");
        super.new(name);
        event_id = '1;
        ingress_port = -1;
        egress_port = SWITCH_ROUTE_DROP;
        route_code = SWITCH_ROUTE_DROP;
    endfunction

    function void set_snapshots(pcie_tl_tlp ingress,
                                pcie_tl_tlp egress);
        ingress_tlp = snapshot(ingress, "ingress");
        if (action == PCIE_TL_ROUTE_DROP) begin
            if (egress != null)
                `uvm_fatal("SWITCH_ROUTE_EVENT_CONTRACT",
                           "drop event has a non-null egress TLP")
            egress_tlp = null;
        end else begin
            if (egress == null)
                `uvm_fatal("SWITCH_ROUTE_EVENT_CONTRACT",
                           "non-drop event has a null egress TLP")
            egress_tlp = snapshot(egress, "egress");
        end
    endfunction

    static function pcie_tl_tlp snapshot(pcie_tl_tlp source,
                                         string label);
        pcie_tl_tlp result;
        pcie_tl_cfg_tlp source_cfg;
        pcie_tl_cfg_tlp result_cfg;
        pcie_tl_io_tlp source_io;
        pcie_tl_io_tlp result_io;
        pcie_tl_msg_tlp source_msg;
        pcie_tl_msg_tlp result_msg;
        pcie_tl_vendor_tlp source_vendor;
        pcie_tl_vendor_tlp result_vendor;
        pcie_tl_ltr_tlp source_ltr;
        pcie_tl_ltr_tlp result_ltr;
        pcie_tl_prefix prefix;

        if ((source == null) || !$cast(result, source.clone()) ||
            (result == null)) begin
            `uvm_fatal("SWITCH_ROUTE_EVENT_CLONE",
                       {label, ": normalized TLP clone failed"})
            return null;
        end
        result.at = source.at;
        result.prefixes.delete();
        foreach (source.prefixes[i]) begin
            if (source.prefixes[i] == null) begin
                `uvm_fatal("SWITCH_ROUTE_EVENT_CLONE",
                           {label, ": null prefix"})
                return null;
            end
            prefix = new($sformatf("prefix_%0d", i));
            prefix.prefix_type = source.prefixes[i].prefix_type;
            prefix.raw_dw = source.prefixes[i].raw_dw;
            result.prefixes.push_back(prefix);
        end
        if ($cast(source_cfg, source)) begin
            if (!$cast(result_cfg, result)) begin
                `uvm_fatal("SWITCH_ROUTE_EVENT_CLONE",
                           {label, ": Configuration clone type changed"})
                return null;
            end
            result_cfg.completer_id = source_cfg.completer_id;
            result_cfg.reg_num = source_cfg.reg_num;
            result_cfg.first_be = source_cfg.first_be;
        end
        if ($cast(source_io, source)) begin
            if (!$cast(result_io, result)) begin
                `uvm_fatal("SWITCH_ROUTE_EVENT_CLONE",
                           {label, ": IO clone type changed"})
                return null;
            end
            result_io.addr = source_io.addr;
            result_io.first_be = source_io.first_be;
        end
        if ($cast(source_msg, source)) begin
            if (!$cast(result_msg, result)) begin
                `uvm_fatal("SWITCH_ROUTE_EVENT_CLONE",
                           {label, ": Message clone type changed"})
                return null;
            end
            result_msg.msg_code = source_msg.msg_code;
            result_msg.msg_addr = source_msg.msg_addr;
            result_msg.target_id = source_msg.target_id;
        end
        if ($cast(source_vendor, source)) begin
            if (!$cast(result_vendor, result)) begin
                `uvm_fatal("SWITCH_ROUTE_EVENT_CLONE",
                           {label, ": Vendor clone type changed"})
                return null;
            end
            result_vendor.vendor_id = source_vendor.vendor_id;
            result_vendor.vendor_data =
                new[source_vendor.vendor_data.size()](source_vendor.vendor_data);
        end
        if ($cast(source_ltr, source)) begin
            if (!$cast(result_ltr, result)) begin
                `uvm_fatal("SWITCH_ROUTE_EVENT_CLONE",
                           {label, ": LTR clone type changed"})
                return null;
            end
            result_ltr.snoop_latency_value =
                source_ltr.snoop_latency_value;
            result_ltr.snoop_latency_scale =
                source_ltr.snoop_latency_scale;
            result_ltr.snoop_requirement = source_ltr.snoop_requirement;
            result_ltr.no_snoop_latency_value =
                source_ltr.no_snoop_latency_value;
            result_ltr.no_snoop_latency_scale =
                source_ltr.no_snoop_latency_scale;
            result_ltr.no_snoop_requirement =
                source_ltr.no_snoop_requirement;
        end
        return result;
    endfunction
endclass

`endif
