// pcie_tl_vip/tests：共享 Host memory 的读回检查回归，依赖生产 TL env 和 host_mem。
// CPU 直接写、EP DMA 写和 RC 分片读共用同一 backing；测试不向 SCB 灌入期望数据。
// 测试拥有临时分配和故障开关；RC 派生类仅在采样后改内存或损坏发送数据，验证检查边界。
// HOST_READ_REPRO_ONLY 在旧生产代码上应重现 0x81/0x01 mismatch；默认运行完整正负例。
`timescale 1ns/1ps
import uvm_pkg::*;
import pcie_tl_pkg::*;
import host_mem_pkg::*;
`include "uvm_macros.svh"

// 在生产 responder 读完后、发送前制造变化；不替代读内存、分片或 SCB 登记。
class pcie_tl_host_read_probe_driver extends pcie_tl_rc_driver;
	`uvm_component_utils(pcie_tl_host_read_probe_driver)

	bit			change_memory;
	bit			corrupt_data;
	bit [63:0]	change_address;
	byte		change_bytes[];

	// 构造只保存测试开关，端口和 Host memory 沿用父类所有权。
	extern function new(string	name, uvm_component	parent);
	// 一次性改变 backing 或 payload；随后完整执行生产发送流水线。
	extern virtual task send_tlp(pcie_tl_tlp	tlp);
endclass

function pcie_tl_host_read_probe_driver::new(string	name, uvm_component	parent);
	super.new(name, parent);
endfunction

task pcie_tl_host_read_probe_driver::send_tlp(pcie_tl_tlp	tlp);
	if (tlp.kind inside {TLP_CPLD, TLP_CPLD_LK}) begin
		if (change_memory) begin
			change_memory = 0;
			mem.write_mem(change_address, change_bytes);
			#5ns;
		end
		if (corrupt_data) begin
			corrupt_data = 0;
			tlp.payload[0] ^= 8'h01;
		end
	end
	super.send_tlp(tlp);
endtask

// 仅在故意损坏的单次读窗口捕获 Data mismatch，其他错误照常失败。
class pcie_tl_host_read_expected_error extends uvm_report_catcher;
	int unsigned	count;

	// 捕获器由单次负例拥有，不注册全局常驻规则。
	extern function new();
	// 精确统计 SCB 字节不匹配，Completion/协议错误不能被此规则掩盖。
	extern virtual function action_e catch();
endclass

function pcie_tl_host_read_expected_error::new();
	super.new("host_read_expected_error");
endfunction

function uvm_report_catcher::action_e pcie_tl_host_read_expected_error::catch();
	if (get_severity() == UVM_ERROR && get_id() == "SCB" &&
		uvm_is_match("Data mismatch at addr=*", get_message())) begin
		count++;
		return CAUGHT;
	end
	return THROW;
endfunction

// 通过实际 EP/RC sequencer 测试单/双 Root；重复复用相同地址，不依赖某个随机 Tag。
class pcie_tl_host_read_scb_test extends pcie_tl_base_test;
	`uvm_component_utils(pcie_tl_host_read_scb_test)

	int unsigned	checks;

	// 测试不提前创建组件或分配内存。
	extern function new(string	name, uvm_component	parent);
	// 开启生产数据检查和统一内存，安装仅用于时序/损坏注入的 RC driver。
	extern virtual function void configure_test();
	// 失败立即终止，保证 PASS 不能覆盖先前合同失败。
	extern function void require(bit	condition, string	detail);
	// 从指定 sequencer 发真实读写，读的有效字节与调用方独立黄金数组逐字节核对。
	extern task access_memory(
		uvm_sequencer #(pcie_tl_tlp)	sqr,
		bit							writing,
		bit [63:0]					address,
		byte						data[]
	);
	// 复现旧值、跨 RCB/非对齐读、采样后内存变化和真实损坏；资源在测试结束前释放。
	extern virtual task run_phase(uvm_phase	phase);
endclass

function pcie_tl_host_read_scb_test::new(string	name, uvm_component	parent);
	super.new(name, parent);
endfunction

function void pcie_tl_host_read_scb_test::configure_test();
	super.configure_test();
	cfg.use_unified_mem      = 1;
	cfg.mem_access_mode      = PCIE_TL_MEM_PER_BUFFER;
	cfg.infinite_credit      = 1;
	cfg.scb_enable           = 1;
	cfg.data_integrity_enable = 1;
	cfg.num_rc              = $test$plusargs("HOST_READ_TWO_ROOTS") ? 2 : 1;
	cfg.num_ep              = cfg.num_rc;

	// 多 Root 显式绑定各自 Host manager；句柄由 cfg 保有，env 负责初始化 backing。
	if (cfg.num_rc > 1) begin
		for (int unsigned	root = 0; root < cfg.num_rc; root++) begin
			host_mem_manager	manager;
			string				why;

			manager = new($sformatf("host_%0d", root));
			manager.set_host_id(root);
			require(cfg.bind_host_memory(root, root, manager, why), why);
		end
	end
	pcie_tl_rc_driver::type_id::set_type_override(pcie_tl_host_read_probe_driver::get_type());
endfunction

function void pcie_tl_host_read_scb_test::require(bit	condition, string	detail);
	checks++;
	if (!condition) `uvm_fatal("HOST_READ_SCB", detail)
endfunction

task pcie_tl_host_read_scb_test::access_memory(
	uvm_sequencer #(pcie_tl_tlp)	sqr,
	bit							writing,
	bit [63:0]					address,
	byte						data[]
);
	pcie_tl_rw_seq	rw;

	rw = pcie_tl_rw_seq::type_id::create("host_access");
	rw.op           = writing ? PCIE_RW_WRITE : PCIE_RW_READ;
	rw.addr         = address;
	rw.byte_len     = data.size();
	rw.strict_order = 1;
	rw.wdata        = new[data.size()];
	foreach (data[i]) rw.wdata[i] = data[i];
	rw.start(sqr);
	if (!writing) begin
		require(rw.status == PCIE_RW_OK && rw.rdata.size() == data.size(), "DMA read did not complete");
		foreach (data[i]) require(rw.rdata[i] == data[i], "read bytes differ from independent golden data");
	end
	// posted 写和 monitor 在独立进程消费；下一个 CPU 写等待本次事务真正落入 backing。
	#20ns;
endtask

task pcie_tl_host_read_scb_test::run_phase(uvm_phase	phase);
	phase.raise_objection(this);
	foreach (env.rc_agents[root]) begin
		host_mem_api					memory;
		pcie_tl_host_read_probe_driver	driver;
		uvm_sequencer #(pcie_tl_tlp)	sqr;
		pcie_tl_scoreboard			scb;
		bit [63:0]					address;
		byte						golden[];
		byte						readback[];

		memory = env.host_mem_by_root[root];
		sqr    = env.ep_agents.size() == 0 ? env.ep_agent.sequencer : env.ep_agents[root].sequencer;
		scb    = env.scbs[root];
		require($cast(driver, env.rc_agents[root].rc_driver), "probe driver override missing");
		address = memory.alloc(512, 4096);
		golden = new[192];
		foreach (golden[i]) golden[i] = byte'(i + root * 17);
		golden[14] = 8'h81;
		access_memory(sqr, 1, address, golden);
		memory.read_mem(address, golden.size(), readback);
		require(readback[14] == 8'h81, "initial PCIe write did not reach Host memory");

		// 与截图相同：DMA 写后 CPU 直接翻转 Packed AVAIL，再由设备读取同一 IOVA/GPA。
		golden[14] = 8'h01;
		memory.write_mem(address, golden);
		access_memory(sqr, 0, address, golden);
		require(scb.mismatched == 0, "CPU update left a stale PCIe write expectation (0x81/0x01)");

		if (!$test$plusargs("HOST_READ_REPRO_ONLY")) begin
			// 连续覆盖同一环槽，并跨越多个 RCB，检验每次请求独立取样及旧快照回收。
			for (int unsigned	iteration = 0; iteration < 40; iteration++) begin
				foreach (golden[i]) golden[i] = byte'(iteration * 7 + i + root * 17);
				memory.write_mem(address, golden);
				access_memory(sqr, 0, address, golden);
			end
			// 非 DWORD 对齐首尾和 3 个 RCB 分片，只比较有效 lane。
			golden = new[130];
			foreach (golden[i]) golden[i] = byte'(8'h35 + i + root);
			memory.write_mem(address + 61, golden);
			access_memory(sqr, 0, address + 61, golden);

			// 一片读已经采样，发送前 CPU 又写新值；该 Completion 仍应与旧快照比较。
			golden = new[4];
			foreach (golden[i]) golden[i] = 8'h41 + i;
			memory.write_mem(address, golden);
			driver.change_address = address;
			driver.change_bytes   = '{8'h91, 8'h92, 8'h93, 8'h94};
			driver.change_memory  = 1;
			access_memory(sqr, 0, address, golden);
			access_memory(sqr, 0, address, driver.change_bytes);

			// 明确注入一位损坏，必须检出一次；确认后清除这一次预期统计供正例继续。
			begin
				pcie_tl_host_read_expected_error	catcher;
				pcie_tl_rw_seq					rw;

				catcher = new();
				uvm_report_cb::add(scb, catcher);
				driver.corrupt_data = 1;
				rw = pcie_tl_rw_seq::type_id::create("corrupt_host_read");
				rw.op       = PCIE_RW_READ;
				rw.addr     = address;
				rw.byte_len = 4;
				rw.start(sqr);
				#20ns;
				uvm_report_cb::delete(scb, catcher);
				require(catcher.count == 1 && scb.mismatched == 1,
					"corrupted Completion escaped data checking or caused extra errors");
				scb.mismatched = 0;
			end
		end
		require(scb.mismatched == 0 && scb.unexpected == 0 && scb.pending_requests.num() == 0 &&
			scb.cpl_trackers.num() == 0, "SCB retained an error or an unfinished request");
		memory.free(address);
	end
	`uvm_info("HOST_READ_SCB_PASS", $sformatf("checks=%0d roots=%0d", checks, cfg.num_rc), UVM_LOW)
	phase.drop_objection(this);
endtask
