// tests：公共 TLP 的默认无注入与显式单项覆盖契约，依赖 pcie_tl_pkg 和 UVM。
// 测试拥有临时事务、sequencer 与 capture driver；driver 保存生产错误序列的独立快照，
// 不接真实 adapter，不发送协议响应。所有字段/模式均逐次强断言，不以概率或日志计数判定。
`include "uvm_macros.svh"
import uvm_pkg::*;
import pcie_tl_pkg::*;

// 捕获生产 poisoned/malformed sequence 实际交出的对象，避免复制约束而漏掉兼容性变化。
class pcie_tl_injection_capture_driver extends uvm_driver #(pcie_tl_tlp);
    `uvm_component_utils(pcie_tl_injection_capture_driver)

    pcie_tl_tlp	captured[$];

    // 标准构造；快照由本 driver 持有直至测试结束。
    function new(string name = "pcie_tl_injection_capture_driver",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // 接受 sequence 发出的 posted 请求并立即完成握手；clone 失败是测试基础设施错误。
    task run_phase(uvm_phase phase);
        pcie_tl_tlp	item;
        pcie_tl_tlp	snapshot;

        forever begin
            seq_item_port.get_next_item(item);
            if (!$cast(snapshot, item.clone()))
                `uvm_fatal("INJECT_CAPTURE", "cannot clone sequence request")
            captured.push_back(snapshot);
            seq_item_port.item_done();
        end
    endtask
endclass

// 用同一检查器覆盖基类、Memory 和 Completion，并实际执行两个生产错误序列。
// 单项覆盖后立即重新随机化，验证先前非零值不会泄漏到下一笔普通业务。
class pcie_tl_injection_defaults_unit_test extends uvm_test;
    `uvm_component_utils(pcie_tl_injection_defaults_unit_test)

    uvm_sequencer #(pcie_tl_tlp)	sequencer;
    pcie_tl_injection_capture_driver	driver;
    int	checks = 0;

    // 标准构造；所有 probe 组件交给 UVM 管理。
    function new(string name = "pcie_tl_injection_defaults_unit_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // 只创建生产 sequence 所需的最小握手链，不引入 env 流量及错误包协议检查。
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        sequencer = uvm_sequencer #(pcie_tl_tlp)::type_id::create("sequencer", this);
        driver = pcie_tl_injection_capture_driver::type_id::create("driver", this);
    endfunction

    // 连接标准 sequence-item 握手；capture driver 不修改被测注入字段。
    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction

    // shape=0 使用普通基类 new；派生对象固定包型及短长度以限定测试成本，
    // 仍使用其真实继承约束，六个注入字段与 mode 始终保持 rand 状态。
    function pcie_tl_tlp make_sample(int shape);
        pcie_tl_tlp	base;
        pcie_tl_mem_tlp	mem;
        pcie_tl_cpl_tlp	cpl;

        case (shape)
            0: base = new("base_default");
            1: begin
                mem = new("mem_default");
                mem.kind   = TLP_MEM_RD;
                mem.length = 4;
                mem.kind.rand_mode(0);
                mem.length.rand_mode(0);
                base = mem;
            end
            2: begin
                cpl = new("cpl_default");
                cpl.kind   = TLP_CPLD;
                cpl.length = 4;
                cpl.kind.rand_mode(0);
                cpl.length.rand_mode(0);
                base = cpl;
            end
            default: `uvm_fatal("INJECT_SHAPE", "unknown sample shape")
        endcase
        return base;
    endfunction

    // 将五个单比特与 32-bit mask 打包比较，确保未选中的每一项都必须为零。
    // [36:32]={EP,ordering,poison,LCRC,ECRC}，[31:0]=field_bitmask；模式也精确匹配。
    function void check_fields(pcie_tl_tlp tlp,
                               tlp_constraint_mode_e expected_mode,
                               bit [36:0] expected_fields,
                               string label_text);
        bit [36:0]	actual_fields;

        actual_fields = {tlp.ep_bit, tlp.violate_ordering, tlp.inject_poisoned,
                         tlp.inject_lcrc_err, tlp.inject_ecrc_err, tlp.field_bitmask};
        checks++;
        if ((actual_fields !== expected_fields) ||
            (tlp.constraint_mode_sel != expected_mode))
            `uvm_error("INJECT_DEFAULTS", $sformatf(
                "%s fields=%010h expected=%010h mode=%s expected_mode=%s",
                label_text, actual_fields, expected_fields,
                tlp.constraint_mode_sel.name(), expected_mode.name()))
    endfunction

    // selected=-1 不施加任何注入约束；0..5 只强制一个字段，其他五项完全交给 soft。
    // force_mode=0 且 selected=-1 直接调用普通 randomize()，其余路径只添加选择条件。
    // 因默认 soft mode 仍须 LEGAL，强制错误位不能靠偷偷换 ILLEGAL 模式满足随机化。
    function void randomize_sample(pcie_tl_tlp tlp,
                                   bit force_mode,
                                   tlp_constraint_mode_e selected_mode,
                                   int selected,
                                   string label_text);
        bit	ok;
        bit [36:0]	expected_fields;
        tlp_constraint_mode_e	expected_mode;

        expected_fields = '0;
        expected_mode = force_mode ? selected_mode : CONSTRAINT_LEGAL;
        case (selected)
            0: expected_fields[32]   = 1'b1;
            1: expected_fields[33]   = 1'b1;
            2: expected_fields[34]   = 1'b1;
            3: expected_fields[35]   = 1'b1;
            4: expected_fields[31:0] = 32'ha5a5_0001;
            5: expected_fields[36]   = 1'b1;
            default: begin end
        endcase
        if (!force_mode && (selected == -1))
            ok = tlp.randomize();
        else
            ok = tlp.randomize() with {
                if (local::force_mode)
                    constraint_mode_sel == local::selected_mode;
                if (local::selected == 0) inject_ecrc_err == 1'b1;
                if (local::selected == 1) inject_lcrc_err == 1'b1;
                if (local::selected == 2) inject_poisoned == 1'b1;
                if (local::selected == 3) violate_ordering == 1'b1;
                if (local::selected == 4) field_bitmask == 32'ha5a5_0001;
                if (local::selected == 5) ep_bit == 1'b1;
            };
        if (!ok) begin
            `uvm_error("INJECT_RANDOMIZE", {label_text, ": randomize failed"})
            return;
        end
        check_fields(tlp, expected_mode, expected_fields, label_text);
    endfunction

    // 遍历三种动态类型及默认/显式 LEGAL/ILLEGAL/CORNER_CASE；每种重复普通随机化，
    // 再逐项注入并恢复默认，防止合并 soft 表达式导致旁项跟随随机化。
    function void check_default_and_single_overrides();
        pcie_tl_tlp	tlp;
        tlp_constraint_mode_e	mode;

        for (int shape = 0; shape < 3; shape++) begin
            tlp = make_sample(shape);
            for (int mode_index = 0; mode_index < 4; mode_index++) begin
                case (mode_index)
                    2: mode = CONSTRAINT_ILLEGAL;
                    3: mode = CONSTRAINT_CORNER_CASE;
                    default: mode = CONSTRAINT_LEGAL;
                endcase
                for (int iteration = 0; iteration < 16; iteration++)
                    randomize_sample(tlp, mode_index != 0, mode, -1,
                        $sformatf("shape=%0d mode=%0d default=%0d", shape, mode_index, iteration));
                for (int field_index = 0; field_index < 6; field_index++) begin
                    randomize_sample(tlp, mode_index != 0, mode, field_index,
                        $sformatf("shape=%0d mode=%0d field=%0d", shape, mode_index, field_index));
                    randomize_sample(tlp, mode_index != 0, mode, -1,
                        $sformatf("shape=%0d mode=%0d restore=%0d", shape, mode_index, field_index));
                end
            end
        end
    endfunction

    // 实际启动旧错误序列并检查线上物化之前的单一注入意图；它们仍显式选择 ILLEGAL。
    task check_production_sequences();
        pcie_tl_err_poisoned_seq	poisoned;
        pcie_tl_err_malformed_seq	malformed;
        bit [36:0]	expected_fields;

        poisoned = pcie_tl_err_poisoned_seq::type_id::create("poisoned");
        malformed = pcie_tl_err_malformed_seq::type_id::create("malformed");
        poisoned.start(sequencer);
        malformed.start(sequencer);
        if (driver.captured.size() != 2)
            `uvm_fatal("INJECT_SEQUENCE", "expected exactly two production sequence requests")
        expected_fields = '0;
        expected_fields[34] = 1'b1;
        check_fields(driver.captured[0], CONSTRAINT_ILLEGAL, expected_fields, "production poisoned");
        expected_fields = '0;
        expected_fields[31:0] = 32'h1;
        check_fields(driver.captured[1], CONSTRAINT_ILLEGAL, expected_fields, "production malformed");
    endtask

    // 完成 3×4×(16+6×2)+2=338 次精确检查；失败保留为 UVM_ERROR，不屏蔽随机化错误。
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        check_default_and_single_overrides();
        check_production_sequences();
        if (checks != 338)
            `uvm_error("INJECT_CHECK_COUNT", $sformatf("checks=%0d expected=338", checks))
        `uvm_info("INJECT_DEFAULTS_DONE", $sformatf("completed %0d exact field/mode checks", checks), UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
