//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Switch Configuration
//-----------------------------------------------------------------------------

class pcie_tl_switch_config extends uvm_object;
    `uvm_object_utils(pcie_tl_switch_config)

    //--- Topology ---
    int num_ds_ports = 4;

    //--- Multi-root (multi-USP) ---
    int  num_usp = 1;                  // 上行口/根 数量（默认 1）
    int  dsp_owner[];                  // 可选: dsp_owner[i]=DSP i 的 USP 索引; 空=均匀连续
    bit  cross_root_check_enable = 1;  // 跨根尝试报 uvm_error
    bit [7:0]  usp_sec_bus[];          // [num_usp] per-root bus 带起
    bit [7:0]  usp_sub_bus[];          // [num_usp] per-root bus 带止
    bit [31:0] usp_mem_base_a[];       // [num_usp] per-root 内存区起
    bit [31:0] usp_mem_limit_a[];      // [num_usp] per-root 内存区止

    //--- Switch identity ---
    bit [15:0] switch_bdf = 16'h0100;

    //--- Mode ---
    bit enum_mode  = 0;
    bit p2p_enable = 1;

    //--- USP config (static mode) ---
    bit [7:0] usp_primary_bus     = 8'h00;
    bit [7:0] usp_secondary_bus   = 8'h01;
    bit [7:0] usp_subordinate_bus = 8'h0F;

    //--- DSP config arrays ---
    bit [7:0]  ds_secondary_bus[];
    bit [7:0]  ds_subordinate_bus[];
    bit [31:0] ds_mem_base[];
    bit [31:0] ds_mem_limit[];

    //--- Per-port FC credits ---
    int port_ph_credit   = 32;
    int port_pd_credit   = 256;
    int port_nph_credit  = 32;
    int port_npd_credit  = 256;
    int port_cplh_credit = 32;
    int port_cpld_credit = 256;

    //--- Per-port link delay ---
    bit port_link_delay_enable = 0;
    int port_latency_min_ns    = 0;
    int port_latency_max_ns    = 0;

    function new(string name = "pcie_tl_switch_config");
        super.new(name);
    endfunction

    function void init_defaults();
        int per;
        ds_secondary_bus   = new[num_ds_ports];
        ds_subordinate_bus = new[num_ds_ports];
        ds_mem_base        = new[num_ds_ports];
        ds_mem_limit       = new[num_ds_ports];
        usp_sec_bus      = new[num_usp];
        usp_sub_bus      = new[num_usp];
        usp_mem_base_a   = new[num_usp];
        usp_mem_limit_a  = new[num_usp];

        // num_usp==1: 保持旧单根布局逐位不变 (switch_unified_mem_test 绿色基线)
        if (num_usp == 1) begin
            for (int i = 0; i < num_ds_ports; i++) begin
                ds_secondary_bus[i]   = usp_secondary_bus + 1 + i;
                ds_subordinate_bus[i] = ds_secondary_bus[i];
                ds_mem_base[i]  = 32'h8000_0000 + (i * 32'h1000_0000);
                ds_mem_limit[i] = ds_mem_base[i] + 32'h0FFF_FFFF;
            end
            usp_subordinate_bus = ds_subordinate_bus[num_ds_ports - 1];
            usp_sec_bus[0]     = usp_secondary_bus;
            usp_sub_bus[0]     = usp_subordinate_bus;
            usp_mem_base_a[0]  = 32'h8000_0000;
            usp_mem_limit_a[0] = ds_mem_limit[num_ds_ports - 1];
            return;
        end

        // 归属: 空 dsp_owner → 均匀连续
        if (dsp_owner.size() != num_ds_ports) begin
            dsp_owner = new[num_ds_ports];
            per = (num_ds_ports + num_usp - 1) / num_usp;  // ceil
            foreach (dsp_owner[i]) dsp_owner[i] = ((i / per) < num_usp) ? (i / per) : (num_usp - 1);
        end

        // per-root 域 + 根内 DSP 细分
        for (int r = 0; r < num_usp; r++) begin
            bit [7:0]  rbus  = 8'(r * (256 / num_usp)) + 1;   // 根 r 起始 bus
            bit [31:0] rbase = 32'h8000_0000 + r * 32'h2000_0000;  // 512MB/根
            int k = 0;
            usp_sec_bus[r]    = rbus;
            usp_mem_base_a[r] = rbase;
            foreach (dsp_owner[i]) if (dsp_owner[i] == r) begin
                ds_secondary_bus[i]   = rbus + 1 + 8'(k);
                ds_subordinate_bus[i] = ds_secondary_bus[i];
                ds_mem_base[i]  = rbase + (k * 32'h0400_0000);   // 64MB/DSP
                ds_mem_limit[i] = ds_mem_base[i] + 32'h03FF_FFFF;
                k++;
            end
            usp_sub_bus[r]     = rbus + 8'(k);
            usp_mem_limit_a[r] = rbase + 32'h1FFF_FFFF;
        end
        usp_subordinate_bus = usp_sub_bus[0];  // 兼容旧单值字段

        // 不交叠自检
        for (int a = 0; a < num_usp; a++) for (int b = a+1; b < num_usp; b++) begin
            if (!(usp_sub_bus[a] < usp_sec_bus[b] || usp_sub_bus[b] < usp_sec_bus[a]))
                `uvm_fatal("SWCFG", $sformatf("root %0d/%0d bus 带重叠", a, b))
            if (!(usp_mem_limit_a[a] < usp_mem_base_a[b] || usp_mem_limit_a[b] < usp_mem_base_a[a]))
                `uvm_fatal("SWCFG", $sformatf("root %0d/%0d 内存区重叠", a, b))
        end
    endfunction

endclass
