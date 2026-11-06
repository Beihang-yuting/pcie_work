// pcie_tl_vip/tests：不依赖 AIP 的 reg_seq 契约和失败路径验证。
// 最小 driver 拥有字节存储并独立按 TLP BE 执行访问；test 拥有 sequencer/catcher。
// Completion 注入仅用于验证 timeout/UR/短数据处理，真实链路由 Intel bind 回归覆盖。
`include "uvm_macros.svh"
import uvm_pkg::*;
import pcie_tl_pkg::*;

// 独立字节模型检查屏蔽是否真的不写；不引用 reg_seq 的 mask 或数据转换函数。
class pcie_reg_test_driver extends uvm_driver #(pcie_tl_tlp);
    `uvm_component_utils(pcie_reg_test_driver)
    byte unsigned	mem[bit [63:0]];
    int	count;
    int	failure_mode;

    // driver 和其存储由单个测试拥有，无外部 agent 共享。
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    // mode 0 正常，1 UR，2 不回 Completion，3 回 SC 但少一个字节。
    task run_phase(uvm_phase phase);
        pcie_tl_tlp	item;
        pcie_tl_mem_tlp	req;
        bit [63:0]	a;
        bit	enabled;
        forever begin
            seq_item_port.get_next_item(item);
            if (!$cast(req,item)) `uvm_fatal("REG_DRIVER", "non-memory request")
            count++;
            a = {req.addr[63:2],2'b0};
            for (int i = 0; i < req.length*4; i++) begin
                if (i < 4) enabled = req.first_be[i%4];
                else if (i >= (req.length-1)*4) enabled = req.last_be[i%4];
                else enabled = 1;
                if (!enabled) continue;
                if (req.kind == TLP_MEM_WR) mem[a+i] = req.payload[i];
                else req.rb_data.push_back(mem.exists(a+i) ? mem[a+i] : 8'hc3);
            end
            if (req.kind == TLP_MEM_RD) begin
                req.rb_status = (failure_mode == 1) ? CPL_STATUS_UR : CPL_STATUS_SC;
                if (failure_mode == 3 && req.rb_data.size() != 0) void'(req.rb_data.pop_back());
                req.rb_done = (failure_mode != 2);
            end
            seq_item_port.item_done();
        end
    endtask
endclass

// 只吞掉已明确武装的超时负测报告，其他 UVM_ERROR/FATAL 仍导致回归失败。
class pcie_reg_expected_timeout extends uvm_report_catcher;
    bit	armed;
    int	seen;
    // catcher 由测试安装/卸载，不改变全局 report 配置。
    function new(string name = "expected_timeout"); super.new(name); endfunction
    // 期望 RW_SEQ 超时必须恰好出现一次；未武装时照常传播。
    virtual function action_e catch();
        if (armed && get_id() == "RW_SEQ" && get_severity() == UVM_ERROR) begin
            seen++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

// 同一 reg_seq 反复 start，以旧输入和错误状态不能泄漏到下次访问为契约。
class pcie_tl_reg_seq_test extends uvm_test;
    `uvm_component_utils(pcie_tl_reg_seq_test)
    uvm_sequencer #(pcie_tl_tlp)	sqr;
    pcie_reg_test_driver	driver;
    int	checks;
    // 标准工厂构造，所有资源由 UVM test 生命周期管理。
    function new(string name, uvm_component parent); super.new(name,parent); endfunction
    // 创建最小连接，不启动 PCIe env 或 AIP 命令注册。
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        sqr = uvm_sequencer#(pcie_tl_tlp)::type_id::create("sqr",this);
        driver = pcie_reg_test_driver::type_id::create("driver",this);
    endfunction
    // 只连接标准 UVM sequencer/driver TLM 端口。
    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        driver.seq_item_port.connect(sqr.seq_item_export);
    endfunction
    // 失败立即终止，计数证明每个预定条件实际执行。
    function void check_condition(bit condition, string message);
        if (!condition) `uvm_fatal("REG_SEQ_CHECK",message)
        checks++;
    endfunction
    // 验证每种长度的单包、单字节屏蔽、全屏蔽、64位地址转换及错误恢复。
    task run_phase(uvm_phase phase);
        pcie_tl_reg_seq	r;
        pcie_reg_expected_timeout	catcher;
        bit [127:0]	original;
        bit [127:0]	expected;
        int	before_count;
        phase.raise_objection(this);
        r = pcie_tl_reg_seq::type_id::create("reused");
        check_condition(r.mask == 0, "constructor mask is not zero");
        for (int n = 4; n <= 16; n += 4) begin
            for (int byte_index = 0; byte_index < n; byte_index++) begin
                r.addr = ((byte_index % 2) ? 64'h12345678_00001000 : 64'h00001000) + n*32;
                r.len = n;
                original = '0;
                for (int b = 0; b < n; b++) original[b*8 +: 8] = 8'(b+1);
                r.is_write = 1;
                r.wdata = original;
                r.mask = 0;
                r.start(sqr);
                check_condition(r.status == PCIE_RW_OK && r.issued_tlps.size() == 1,"full write must be one TLP");
                check_condition(r.issued_tlps[0].is_64bit == (r.addr[63:32] != 0),"stale address format");
                r.wdata = 0;
                r.mask = 1 << byte_index;
                r.start(sqr);
                expected = 0;
                expected[byte_index*8 +: 8] = original[byte_index*8 +: 8];
                r.is_write = 0;
                r.mask = 0;
                r.start(sqr);
                check_condition(r.status == PCIE_RW_OK && r.rdata == expected,"masked byte changed or endian mismatch");
            end
        end
        before_count = driver.count;
        r.mask = '1;
        r.start(sqr);
        check_condition(r.status == PCIE_RW_OK && r.rdata == 0 && r.issued_tlps.size() == 0 && driver.count == before_count,"all masked read issued traffic");
        r.is_write = 1;
        r.start(sqr);
        check_condition(driver.count == before_count,"all masked write issued traffic");

        r.mask = 0;
        r.len = 3;
        r.start(sqr);
        check_condition(r.status == PCIE_RW_ERR && r.error_msg != "" && driver.count == before_count,"bad len not rejected");
        r.len = 4;
        r.addr = 1;
        r.start(sqr);
        check_condition(r.status == PCIE_RW_ERR && driver.count == before_count,"unaligned addr not rejected");
        r.addr = 64'h1000;
        r.is_write = 0;
        for (int failure = 1; failure <= 3; failure++) begin
            driver.failure_mode = failure;
            r.rb_timeout_ns = 20;
            catcher = new();
            catcher.armed = (failure == 2);
            uvm_report_cb::add(null,catcher);
            r.start(sqr);
            uvm_report_cb::delete(null,catcher);
            check_condition(r.status == ((failure == 2) ? PCIE_RW_TIMEOUT : PCIE_RW_ERR) && r.error_msg != "","read failure became success");
            if (failure == 2) check_condition(catcher.seen == 1,"timeout path not exercised");
        end
        driver.failure_mode = 0;
        r.start(sqr);
        check_condition(r.status == PCIE_RW_OK && r.error_msg == "" && r.issued_tlps.size() == 1,"stale error after recovery");
        `uvm_info("PCIE_REG_SEQ_PASS",$sformatf("checks=%0d requests=%0d",checks,driver.count),UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass

// 独立顶层可在不编译 AIP 的情况下验证新公共 sequence。
module tb_pcie_tl_reg_seq;
    initial run_test("pcie_tl_reg_seq_test");
    initial begin #100us; $fatal(1,"register sequence test watchdog"); end
endmodule
