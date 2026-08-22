//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Switch Port (USP/DSP)
//-----------------------------------------------------------------------------

class pcie_tl_switch_port extends uvm_component;
    `uvm_component_utils(pcie_tl_switch_port)

    switch_port_role_e  role;
    int                 port_id;
    int owner_usp = 0;   // DSP 专用: 归属的 USP 索引
    int root_id   = 0;   // USP 专用: 自身根索引

    bit [15:0] bdf;
    bit [15:0] vendor_id = 16'h20f9;
    bit [15:0] device_id;
    bit [15:0] command;
    bit [15:0] status = 16'h0010;
    bit [7:0]  revision_id = 8'h01;
    bit [23:0] class_code = 24'h060400;
    bit [7:0]  header_type = 8'h01;
    bit [15:0] pref_base_reg = 16'h0001;
    bit [15:0] pref_limit_reg = 16'h0001;
    bit [63:0] pref_base;
    bit [63:0] pref_limit;
    bit [31:0] pref_base_upper;
    bit [31:0] pref_limit_upper;
    bit        pref_window_programmed;

    uvm_tlm_fifo #(pcie_tl_tlp) rx_fifo;
    uvm_tlm_fifo #(pcie_tl_tlp) tx_fifo;

    switch_route_entry_t route_entry;

    pcie_tl_fc_manager fc_mgr;

    pcie_tl_link_delay_model ingress_delay;
    pcie_tl_link_delay_model egress_delay;

    int forwarded_count = 0;
    int dropped_count   = 0;

    function new(string name = "pcie_tl_switch_port", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function automatic bit [31:0] merge_be(bit [31:0] old_value,
                                            bit [31:0] new_value,
                                            bit [3:0] be);
        bit [31:0] result = old_value;
        foreach (be[i])
            if (be[i]) result[i*8 +: 8] = new_value[i*8 +: 8];
        return result;
    endfunction

    function void init_type1_image(switch_port_role_e image_role,
                                   int unsigned index,
                                   bit [15:0] image_bdf);
        role = image_role;
        bdf = image_bdf;
        device_id = (role == SWITCH_USP) ? 16'h5010 : 16'(16'h5020 + index);
        command = 16'h0000;
        status = 16'h0010;
        pref_base_reg = 16'h0001;
        pref_limit_reg = 16'h0001;
        pref_base_upper = 32'h0000_0000;
        pref_limit_upper = 32'h0000_0000;
        pref_base = 64'h0;
        pref_limit = 64'h0000_0000_000f_ffff;
        pref_window_programmed = 1'b0;
    endfunction

    function void update_pref_window();
        pref_base = {pref_base_upper, pref_base_reg[15:4], 20'h00000};
        pref_limit = {pref_limit_upper, pref_limit_reg[15:4], 20'hfffff};
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        rx_fifo       = new("rx_fifo", this, 256);
        tx_fifo       = new("tx_fifo", this, 256);
        fc_mgr        = pcie_tl_fc_manager::type_id::create($sformatf("fc_mgr_p%0d", port_id));
        ingress_delay = pcie_tl_link_delay_model::type_id::create(
                            $sformatf("ingress_delay_p%0d", port_id), this);
        egress_delay  = pcie_tl_link_delay_model::type_id::create(
                            $sformatf("egress_delay_p%0d", port_id), this);
    endfunction

    function void apply_config(pcie_tl_switch_config sw_cfg, int idx);
        if (role == SWITCH_USP) begin
            // idx = root index; use per-root domain (usp_*[idx]).
            // num_usp==1: usp_sec_bus[0]==usp_secondary_bus etc (init_defaults), so byte-equivalent.
            route_entry.primary_bus     = sw_cfg.usp_primary_bus;
            route_entry.secondary_bus   = sw_cfg.usp_sec_bus[idx];
            route_entry.subordinate_bus = sw_cfg.usp_sub_bus[idx];
            route_entry.mem_base  = 0;
            route_entry.mem_limit = 0;
        end else begin
            // idx = DSP index; primary bus = owning root's secondary bus.
            route_entry.primary_bus     = sw_cfg.usp_sec_bus[owner_usp];
            route_entry.secondary_bus   = sw_cfg.ds_secondary_bus[idx];
            route_entry.subordinate_bus = sw_cfg.ds_subordinate_bus[idx];
            route_entry.mem_base        = sw_cfg.ds_mem_base[idx];
            route_entry.mem_limit       = sw_cfg.ds_mem_limit[idx];
        end

        fc_mgr.fc_enable       = 1;
        fc_mgr.infinite_credit = 0;
        fc_mgr.init_credits(sw_cfg.port_ph_credit, sw_cfg.port_pd_credit,
                            sw_cfg.port_nph_credit, sw_cfg.port_npd_credit,
                            sw_cfg.port_cplh_credit, sw_cfg.port_cpld_credit);

        ingress_delay.enable         = sw_cfg.port_link_delay_enable;
        ingress_delay.latency_min_ns = sw_cfg.port_latency_min_ns;
        ingress_delay.latency_max_ns = sw_cfg.port_latency_max_ns;
        egress_delay.enable          = sw_cfg.port_link_delay_enable;
        egress_delay.latency_min_ns  = sw_cfg.port_latency_min_ns;
        egress_delay.latency_max_ns  = sw_cfg.port_latency_max_ns;
    endfunction

    function bit [31:0] cfg_read(bit [11:0] addr);
        case (addr)
            12'h000: return {device_id, vendor_id};
            12'h004: return {status, command};
            12'h008: return {class_code, revision_id};
            12'h00c: return {8'h00, header_type, 16'h0000};
            12'h018: return {8'h00, route_entry.subordinate_bus,
                             route_entry.secondary_bus,
                             route_entry.primary_bus};
            12'h020: return {route_entry.mem_limit[31:20], 4'h0,
                             route_entry.mem_base[31:20], 4'h0};
            12'h024: return {pref_limit_reg, pref_base_reg};
            12'h028: return pref_base_upper;
            12'h02c: return pref_limit_upper;
            12'h034: return 32'h0000_0040;
            12'h040: return {8'h00,
                             (role == SWITCH_USP) ? 4'h5 : 4'h6,
                             4'h2, 8'h00, 8'h10};
            default: return 32'h0;
        endcase
    endfunction

    function void cfg_write(bit [11:0] addr, bit [31:0] data, bit [3:0] be);
        bit [31:0] merged;
        case (addr)
            12'h004: begin
                merged = merge_be(cfg_read(addr), data, be);
                command = merged[15:0];
            end
            12'h018: begin
                merged = merge_be(cfg_read(addr), data, be);
                route_entry.primary_bus     = merged[7:0];
                route_entry.secondary_bus   = merged[15:8];
                route_entry.subordinate_bus = merged[23:16];
            end
            12'h020: begin
                merged = merge_be(cfg_read(addr), data, be);
                route_entry.mem_base[31:20]  = merged[15:4];
                route_entry.mem_limit[31:20] = merged[31:20];
            end
            12'h024: begin
                merged = merge_be(cfg_read(addr), data, be);
                pref_base_reg  = {merged[15:4], 4'h1};
                pref_limit_reg = {merged[31:20], 4'h1};
                update_pref_window();
                pref_window_programmed = 1'b1;
            end
            12'h028: begin
                pref_base_upper = merge_be(cfg_read(addr), data, be);
                update_pref_window();
                pref_window_programmed = 1'b1;
            end
            12'h02c: begin
                pref_limit_upper = merge_be(cfg_read(addr), data, be);
                update_pref_window();
                pref_window_programmed = 1'b1;
            end
        endcase
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info(get_name(), $sformatf(
            "\n===== Switch Port %0d (%s) =====\n  Bus: pri=%0d sec=%0d sub=%0d\n  Mem: [0x%08h - 0x%08h]\n  Forwarded: %0d  Dropped: %0d\n================================",
            port_id, role.name(),
            route_entry.primary_bus, route_entry.secondary_bus, route_entry.subordinate_bus,
            route_entry.mem_base, route_entry.mem_limit,
            forwarded_count, dropped_count), UVM_LOW)
    endfunction

endclass
