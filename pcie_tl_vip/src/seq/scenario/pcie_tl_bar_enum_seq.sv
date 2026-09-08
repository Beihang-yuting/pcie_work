//------------------------------------------------------------------------------
// BAR 枚举 sequence（支持随机 BAR 基址分配）。
//
// 该文件属于 pcie_tl_vip/src/seq/scenario，由 pcie_tl_pkg 收录，只依赖
// 基础 cfg 读写 sequence。它对目标 BDF 的每个 BAR 执行标准枚举三步：
// 写全 1 探测 size、读回 size mask、写入分配的基址；最后打开 Memory
// Space + Bus Master。
//
// 基址分配有两种模式（use_random_bar_base 选择）：
//   1（默认）：在 [bar_region_base, +bar_region_size) 随机窗口内按各 BAR
//      真实 size 对齐随机放置，且互不重叠；结果记录在
//      assigned_bar_base[]，供上层 sequence/scoreboard 直接使用。
//   0：沿用历史固定公式 32'h1000_0000 + i*32'h0100_0000，保证旧用例
//      可复现。
//
// 本对象生命周期为单次 start()；重复 start 会先清空上次的分配记录。
//------------------------------------------------------------------------------
class pcie_tl_bar_enum_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_bar_enum_seq)

    rand bit [15:0] target_bdf;
    rand int num_bars;

    // 随机分配窗口。声明初值保证"直接 start() 不 randomize()"的旧用法
    // 也能拿到有效窗口（soft 约束只在 randomize() 时生效）；显式赋值或
    // inline 约束均可覆盖。窗口必须容得下全部 BAR。
    rand bit [31:0] bar_region_base = 32'h1000_0000;
    rand bit [31:0] bar_region_size = 32'h1000_0000;

    // 1 = 随机基址（默认）；0 = 历史固定公式。
    bit use_random_bar_base = 1'b1;

    // 枚举结果：BAR index -> 实际写入的基址 / 探测到的 size（字节）。
    // size 为 0 表示该 BAR 未实现（size mask 读回全 0），未写基址。
    bit [31:0] assigned_bar_base[int];
    bit [31:0] probed_bar_size[int];

    constraint c_default { num_bars inside {[1:6]}; }

    // soft 约束：窗口默认 [0x1000_0000, +0x1000_0000)。显式赋值或外部
    // inline 约束都能覆盖。
    constraint c_region {
        soft bar_region_base == 32'h1000_0000;
        soft bar_region_size == 32'h1000_0000;
    }

    // 构造函数：仅透传名字。
    function new(string name = "pcie_tl_bar_enum_seq"); super.new(name); endfunction

    // 由写全 1 后的读回值计算 BAR size：屏蔽低 4 位类型/属性位后取
    // 补码。读回全 0 视为 BAR 未实现，返回 0。
    protected function bit [31:0] size_from_mask(bit [31:0] rd_val);
        bit [31:0] mask = rd_val & 32'hFFFF_FFF0;
        if (mask == 32'h0)
            return 32'h0;
        return (~mask) + 32'h1;
    endfunction

    // 在窗口内为一个 size 字节的 BAR 挑选按 size 对齐、且与已有分配不
    // 重叠的随机基址。成功置 base 并返回 1；重试耗尽返回 0（调用方回退
    // 顺序放置）。
    protected function bit pick_random_base(
        bit [31:0] size,
        output bit [31:0] base);
        bit [31:0] slot_count;
        bit [31:0] slot;
        bit [31:0] candidate;
        bit overlaps;

        // 窗口按 size 切成对齐槽位；BAR 基址天然 size 对齐。
        if ((size == 0) || (size > bar_region_size))
            return 1'b0;
        slot_count = bar_region_size / size;
        if (slot_count == 0)
            return 1'b0;

        repeat (32) begin
            slot = $urandom_range(slot_count - 1);
            candidate = bar_region_base + slot * size;
            overlaps = 1'b0;
            foreach (assigned_bar_base[j]) begin
                if ((candidate < (assigned_bar_base[j] + probed_bar_size[j])) &&
                    (assigned_bar_base[j] < (candidate + size)))
                    overlaps = 1'b1;
            end
            if (!overlaps) begin
                base = candidate;
                return 1'b1;
            end
        end
        return 1'b0;
    endfunction

    // 随机重试失败时的兜底：从窗口起点顺序扫描第一个不重叠的对齐槽位。
    // 窗口整体放不下时返回 0，由 body 报 UVM_ERROR。
    protected function bit pick_sequential_base(
        bit [31:0] size,
        output bit [31:0] base);
        bit [31:0] candidate;
        bit overlaps;

        if ((size == 0) || (size > bar_region_size))
            return 1'b0;
        candidate = bar_region_base;
        while ((candidate + size) <= (bar_region_base + bar_region_size)) begin
            overlaps = 1'b0;
            foreach (assigned_bar_base[j]) begin
                if ((candidate < (assigned_bar_base[j] + probed_bar_size[j])) &&
                    (assigned_bar_base[j] < (candidate + size)))
                    overlaps = 1'b1;
            end
            if (!overlaps) begin
                base = candidate;
                return 1'b1;
            end
            candidate += size;
        end
        return 1'b0;
    endfunction

    // 标准 BAR 枚举：逐 BAR 探测 size 并写入基址（随机或固定公式），
    // 最后使能 Memory Space + Bus Master。分配结果留在
    // assigned_bar_base/probed_bar_size 供上层读取。
    task body();
        assigned_bar_base.delete();
        probed_bar_size.delete();

        for (int i = 0; i < num_bars; i++) begin
            bit [9:0] bar_reg = (10'h4 + i);
            bit [31:0] bar_size;
            bit [31:0] bar_base;
            pcie_tl_cfg_wr_seq wr1, wr2;
            pcie_tl_cfg_rd_seq rd;

            // 第一步：写全 1 探测可写位。
            wr1 = pcie_tl_cfg_wr_seq::type_id::create($sformatf("wr1_%0d",i));
            wr1.target_bdf = target_bdf; wr1.reg_num = bar_reg;
            wr1.first_be = 4'hF; wr1.wr_data = 32'hFFFFFFFF;
            wr1.start(m_sequencer);

            // 第二步：读回 size mask。
            rd = pcie_tl_cfg_rd_seq::type_id::create($sformatf("rd_%0d",i));
            rd.target_bdf = target_bdf; rd.reg_num = bar_reg; rd.first_be = 4'hF;
            rd.start(m_sequencer);

            // 第三步：选择基址。随机模式用探测 size 做对齐/防重叠；
            // BAR 未实现（mask 全 0）时跳过写基址，保持记录 size=0。
            if (use_random_bar_base) begin
                bar_size = size_from_mask(rd.rd_data);
                probed_bar_size[i] = bar_size;
                if (bar_size == 0) begin
                    `uvm_info("BAR_ENUM", $sformatf(
                        "BDF 0x%04h BAR%0d 未实现，跳过基址分配",
                        target_bdf, i), UVM_HIGH)
                    continue;
                end
                if (!pick_random_base(bar_size, bar_base) &&
                    !pick_sequential_base(bar_size, bar_base)) begin
                    `uvm_error("BAR_ENUM", $sformatf(
                        "BDF 0x%04h BAR%0d size=0x%0h 在窗口 [0x%08h,+0x%08h) 内放不下",
                        target_bdf, i, bar_size,
                        bar_region_base, bar_region_size))
                    continue;
                end
            end
            else begin
                // 历史固定公式路径：不看 size，保证旧用例逐位可复现。
                bar_base = 32'h1000_0000 + (i * 32'h0100_0000);
                probed_bar_size[i] = size_from_mask(rd.rd_data);
            end
            assigned_bar_base[i] = bar_base;

            wr2 = pcie_tl_cfg_wr_seq::type_id::create($sformatf("wr2_%0d",i));
            wr2.target_bdf = target_bdf; wr2.reg_num = bar_reg;
            wr2.first_be = 4'hF; wr2.wr_data = bar_base;
            wr2.start(m_sequencer);

            `uvm_info("BAR_ENUM", $sformatf(
                "BDF 0x%04h BAR%0d base=0x%08h size=0x%0h (%s)",
                target_bdf, i, bar_base, probed_bar_size[i],
                use_random_bar_base ? "random" : "fixed"), UVM_MEDIUM)
        end

        // 使能 Memory Space + Bus Master。
        begin
            pcie_tl_cfg_wr_seq cmd_wr;
            cmd_wr = pcie_tl_cfg_wr_seq::type_id::create("cmd_wr");
            cmd_wr.target_bdf = target_bdf; cmd_wr.reg_num = 1; // Command at 04h
            cmd_wr.first_be = 4'hF; cmd_wr.wr_data = 32'h0000_0006; // MemSpace + BusMaster
            cmd_wr.start(m_sequencer);
        end
    endtask
endclass
