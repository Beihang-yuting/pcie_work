// pcie_tl_vip/tests：原生 SV_IF 生命周期回归，依赖专用双单向接口 top。
// 依赖生产 pcie_tl_pkg/pcie_tl_if 与 UVM；不修改、继承覆盖或直接调用 SCB 检查函数。
// 本测试显式提供两条单向接口：RC adapter 发送 RC→EP，EP monitor 观察该 adapter；
// EP adapter 发送 EP→RC，RC monitor 观察该 adapter。基础 adapter 的 vif 本身只有
// 一条单向通道，故这项测试接线不可宣称现有默认单接口 top 已实现双向连接。
// UVM 拥有 env/analysis FIFO，top 拥有 interface，请求与 peer Completion 句柄归测试。
// 最小 peer 只根据真实 monitor 解码出的 MRd，经对向生产 adapter 返回线上的 CplD；
// 禁止补 pending 登记、driver Completion 回调、Tag 释放或关闭严格检查来掩盖缺口。
`timescale 1ns/1ps
import uvm_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

// 每方向先做单笔 4B，再做 40 笔两片 64B 请求，越过 32-Tag 池容量证明正常复用。
// +NATIVE_SINGLE 只运行首笔；完整模式验证首片不释放和终片无重复折叠。
// 传输完成、SCB 匹配、Tag/driver 生命周期分别记录；任一合同失败仍报 UVM_ERROR。
class pcie_tl_native_sv_if_test extends uvm_test;
	`uvm_component_utils(pcie_tl_native_sv_if_test)
	pcie_tl_env		env;
	pcie_tl_ep_agent		ep_endpoint;
	bit			expect_bridge;
	pcie_tl_env_config	cfg;
	uvm_tlm_analysis_fifo #(pcie_tl_tlp)	rc_observed;
	uvm_tlm_analysis_fifo #(pcie_tl_tlp)	ep_observed;
	virtual pcie_tl_if	rc_to_ep;
	virtual pcie_tl_if	ep_to_rc;
	string			direction;
	int unsigned		peer_requests;
	int unsigned		peer_responses;
	int unsigned		checks;
	int unsigned		failures;
	int unsigned		requests_done;
	int unsigned		partials_checked;
	int unsigned		reused_tags;
	bit			seen_tags[bit [9:0]];
	realtime		first_timer_due;
	bit [9:0]		first_tag;
	bit			timer_isolation_checked;

	// 构造不访问 VIF；在 build 取得 top 发布的接口，connect 再连接真实组件。
	function new(string	name = "pcie_tl_native_sv_if_test", uvm_component	parent = null);
		super.new(name, parent);
	endfunction

	// 使用原有程序化配置；保留默认协议检查、strict SCB 与真实 Tag 分配。
	virtual function void build_phase(uvm_phase	phase);
		super.build_phase(phase);
		direction = "RC";
		void'($value$plusargs("NATIVE_DIRECTION=%s", direction));
		if (!(direction inside {"RC", "EP"}))
			`uvm_fatal("NATIVE_SV_IF", "NATIVE_DIRECTION must be RC or EP")
		if (!uvm_config_db#(virtual pcie_tl_if)::get(this, "", "rc_to_ep", rc_to_ep) ||
			!uvm_config_db#(virtual pcie_tl_if)::get(this, "", "ep_to_rc", ep_to_rc))
			`uvm_fatal("NATIVE_SV_IF", "two physical interface handles are required")
		cfg = pcie_tl_env_config::type_id::create("cfg");
		cfg.if_mode             = SV_IF_MODE;
		cfg.infinite_credit     = 1;
		cfg.extended_tag_enable = 0;
		cfg.max_outstanding     = 32;
		cfg.cpl_timeout_ns      = 2000;
		cfg.ep_auto_response    = 0;
		cfg.scb_enable          = 1;
		cfg.scb_strict_check    = 1;
		uvm_config_db#(pcie_tl_env_config)::set(this, "env", "cfg", cfg);
		env = pcie_tl_env::type_id::create("env", this);
		rc_observed = new("rc_observed", this);
		ep_observed = new("ep_observed", this);
	endfunction

	// UVM connect 自底向上：在 env 完成原生注入之后，只完成单向物理接线。
	// SCB 与 monitor 仍使用 env 原有 analysis 连接；不补 native 环境缺失的生命周期回调。
	virtual function void connect_phase(uvm_phase	phase);
		super.connect_phase(phase);
		ep_endpoint = env.ep_agent;
		if (ep_endpoint == null && env.ep_agents.size() != 0) ep_endpoint = env.ep_agents[0];
		if (ep_endpoint == null) `uvm_fatal("NATIVE_SV_IF", "test requires one actual EP endpoint")
		// 原生直连使用标量alias；provider switch契约用真实DSP0对象，不修改env别名。
		env.rc_adapter.vif = rc_to_ep;
		ep_endpoint.adapter.vif = ep_to_rc;
		env.rc_agent.monitor.adapter = ep_endpoint.adapter;
		ep_endpoint.monitor.adapter = env.rc_adapter;
		env.rc_agent.monitor.tlp_ap.connect(rc_observed.analysis_export);
		ep_endpoint.monitor.tlp_ap.connect(ep_observed.analysis_export);
	endfunction

	// 统一四态判定并累计失败，最终 PASS 标记仅在所有真实检查成功时发布。
	function void require(logic	condition, string	detail);
		checks++;
		if (condition !== 1'b1) begin
			failures++;
			`uvm_error("NATIVE_SV_IF", detail)
		end
	endfunction

	// 数据按事务序号与字节偏移生成，防止分片重复折叠或错误引用前一笔仍碰巧匹配。
	function bit [7:0] expected_byte(int	serial, int	offset);
		return 8'(8'ha0 + serial * 7 + offset);
	endfunction

	// 构造 4B 或 64B MRd；64B 请求从 RCB64 的后半段开始，两片各32B符合边界。
	// 每笔换地址但不跨 4KiB；Tag 与 registry 生命周期全部由真实 driver 负责。
	function pcie_tl_mem_tlp make_request(int	serial);
		pcie_tl_mem_tlp	request;

		request = pcie_tl_mem_tlp::type_id::create($sformatf("request_%0d", serial));
		request.kind         = TLP_MEM_RD;
		request.fmt          = FMT_3DW_NO_DATA;
		request.type_f       = TLP_TYPE_MEM_RD;
		request.is_64bit     = 0;
		request.addr         = 64'h1000 + serial * 128 + ((serial == 0) ? 0 : 32);
		request.length       = (serial == 0) ? 1 : 16;
		request.first_be     = 4'hf;
		request.last_be      = (serial == 0) ? 4'h0 : 4'hf;
		request.requester_id = (direction == "RC") ? 16'h0000 : 16'h0010;
		return request;
	endfunction

	// 首片已经过接口和 monitor 后核对生产状态；检查不产生任何生命周期副作用。
	function void check_partial(pcie_tl_mem_tlp	request, int	serial);
		bit [25:0]	key;

		key = pcie_rb_registry::mk_key(request.requester_id, request.tag);
		require(!request.rb_done && request.rb_data.size() == 32,
			$sformatf("request %0d first fragment ended early or double-folded", serial));
		require(env.tag_mgr.get_outstanding_count() == 1 && env.tag_mgr.tag_pool[0].size() == 31,
			"first fragment must retain its requester Tag");
		require(pcie_rb_registry::reqs.exists(key) && env.scb.pending_requests.num() == 1 &&
			env.scb.cpl_trackers.num() == 1, "first fragment must retain registry and SCB trackers");
		if (direction == "RC")
			require(env.rc_agent.rc_driver.get_pending_count() == 1 &&
				env.rc_agent.rc_driver.cpl_byte_trackers.num() == 1,
				"RC first fragment must retain pending and byte tracker");
		foreach (request.rb_data[index])
			require(request.rb_data[index] === expected_byte(serial, index), "first-fragment payload mismatch");
	endfunction

	// 最小 peer 只能从对端 monitor 收到解码后的请求，再由生产 adapter 发线上的响应。
	// requester monitor 的 FIFO 证明每个 CplD 已完整解码；首片检查后才发下一片。
	task peer_response(pcie_tl_mem_tlp	original, int	serial);
		pcie_tl_tlp	observed;
		pcie_tl_tlp	wire_completion;
		pcie_tl_mem_tlp	request;
		pcie_tl_cpl_tlp	completion;
		int	total_bytes;
		int	fragment_bytes;
		bit [63:0]	fragment_addr;

		if (direction == "RC") ep_observed.get(observed);
		else rc_observed.get(observed);
		if (!$cast(request, observed) || observed.kind != TLP_MEM_RD)
			`uvm_fatal("NATIVE_SV_IF", "peer did not receive an interface-decoded MRd")
		require(request.addr == original.addr && request.length == original.length &&
			request.first_be == original.first_be && request.last_be == original.last_be &&
			request.requester_id == original.requester_id && request.tag == original.tag,
			"decoded wire MRd differs from the submitted request");
		peer_requests++;
		total_bytes    = request.length * 4;
		fragment_bytes = (serial == 0) ? 4 : 32;
		for (int	offset = 0; offset < total_bytes; offset += fragment_bytes) begin
			completion = pcie_tl_cpl_tlp::type_id::create("peer_completion");
			completion.kind         = TLP_CPLD;
			completion.fmt          = FMT_3DW_WITH_DATA;
			completion.type_f       = TLP_TYPE_CPL;
			completion.length       = fragment_bytes / 4;
			completion.requester_id = request.requester_id;
			completion.tag          = request.tag;
			completion.completer_id = (direction == "RC") ? 16'h0010 : 16'h0000;
			completion.cpl_status   = CPL_STATUS_SC;
			completion.byte_count   = total_bytes - offset;
			fragment_addr           = request.addr + offset;
			completion.lower_addr   = fragment_addr[6:0];
			completion.payload      = new[fragment_bytes];
			foreach (completion.payload[index])
				completion.payload[index] = expected_byte(serial, offset + index);
			if (direction == "RC") ep_endpoint.adapter.send(completion);
			else env.rc_adapter.send(completion);
			if (direction == "RC") rc_observed.get(wire_completion);
			else ep_observed.get(wire_completion);
			#1step;
			peer_responses++;
			require(wire_completion.get_category() == TLP_CAT_COMPLETION &&
				wire_completion.requester_id == original.requester_id && wire_completion.tag == original.tag &&
				wire_completion.payload.size() == fragment_bytes, "interface Completion metadata mismatch");
			foreach (wire_completion.payload[index])
				require(wire_completion.payload[index] === expected_byte(serial, offset + index),
					"interface Completion bytes mismatch");
			if (offset + fragment_bytes < total_bytes) begin
				partials_checked++;
				check_partial(original, serial);
				// 第33笔重用首笔Tag；首片后跨过首笔旧timer到期点，但仍早于本笔timer。
				// 延后的是外部peer终片，不能直接改driver pending或触发其Completion回调。
				if (direction == "RC" && serial == 32) begin
					require(original.tag == first_tag && $realtime < first_timer_due,
						"old timer isolation window was not reached before the previous generation deadline");
					if ($realtime < first_timer_due) #(first_timer_due - $realtime + 4ns);
					#1step;
					check_partial(original, serial);
					timer_isolation_checked = 1;
				end
			end
		end
	endtask

	// 终片后所有生产跟踪表必须为空，不能依赖 timeout 回收，也不能只看 rb_done。
	function void check_retired(pcie_tl_mem_tlp	request, int	serial);
		require(request.rb_done && request.rb_status == CPL_STATUS_SC &&
			request.rb_data.size() == request.length * 4, "terminal read-back incomplete or double-folded");
		foreach (request.rb_data[index])
			require(request.rb_data[index] === expected_byte(serial, index), "terminal read-back bytes mismatch");
		require(env.scb.total_requests == requests_done && env.scb.total_completions == peer_responses &&
			env.scb.matched == requests_done && env.scb.unexpected == 0 && env.scb.mismatched == 0 &&
			env.scb.pending_requests.num() == 0 && env.scb.cpl_trackers.num() == 0 &&
			env.scb.cpl_processed.num() == 0, "SCB did not retire exactly one request without dedup residue");
		require(env.rc_agent.rc_driver.get_pending_count() == 0 &&
			env.rc_agent.rc_driver.cpl_byte_trackers.num() == 0 && env.tag_mgr.get_outstanding_count() == 0 &&
			env.tag_mgr.tag_pool[0].size() == 32, "requester pending/Tag state was not retired");
		require(pcie_rb_registry::reqs.num() == 0 && pcie_rb_registry::recv.num() == 0 &&
			pcie_rb_registry::total.num() == 0 && pcie_rb_registry::wire_bytes.num() == 0,
			"read-back registry state was not retired");
		require(rc_observed.used() == 0 && ep_observed.used() == 0, "extra interface observation remained");
		if (expect_bridge) begin
			foreach (env.bridge_ep_rx_fifos[index])
				require(env.bridge_ep_rx_fifos[index].used() == 0,
					"bridge EP business FIFO retained an unconsumed observation");
		end
	endfunction

	// 保持原始 native 模式与严格检查；完整模式越过Tag池并在旧timer期间继续请求。
	// 末尾等待超过timeout以抓迟到旧timer，不通过该等待延后任何单笔收尾断言。
	task execute_test();
		pcie_tl_mem_tlp	request;
		pcie_tl_mem_tlp	first_request;
		int	request_count;

		wait (rc_to_ep.rst_n === 1'b1 && ep_to_rc.rst_n === 1'b1);
		require(env.bridge_required == expect_bridge && env.rc_adapter.mode == SV_IF_MODE &&
			ep_endpoint.adapter.mode == SV_IF_MODE, "test interface/provider mode differs from its declared contract");
		`uvm_info("NATIVE_SV_IF_MODE", $sformatf("bridge=%0b auto_response=%0b direction=%s",
			env.bridge_required, cfg.ep_auto_response, direction), UVM_LOW)
		require(env.scb.ep_rx_pending_enable && env.scb.rc_rx_pending_enable && env.scb.strict_check &&
			env.scb.completion_check_enable, "native receive registration and strict SCB must be enabled");
		request_count = $test$plusargs("NATIVE_SINGLE") ? 1 : 41;
		for (int	serial = 0; serial < request_count; serial++) begin
			request = make_request(serial);
			if (serial == 0) first_request = request;
			// 合法复用同一sequence item句柄，使旧timer的句柄比较也相同，必须靠分配代次隔离。
			if (serial == 32) begin
				first_request.copy(request);
				request = first_request;
			end
			fork
				begin
					if (direction == "RC") env.rc_agent.rc_driver.send_tlp(request);
					else ep_endpoint.ep_driver.send_tlp(request);
					if (serial == 0) begin
						first_tag       = request.tag;
						first_timer_due = $realtime + cfg.cpl_timeout_ns * 1ns;
					end
				end
				peer_response(request, serial);
			join
			requests_done++;
			if (seen_tags.exists(request.tag)) reused_tags++;
			seen_tags[request.tag] = 1;
			check_retired(request, serial);
		end
		if (request_count > 32)
			require(reused_tags > 0 && partials_checked == 40, "Tag reuse/split response coverage was not reached");
		if (request_count > 32 && direction == "RC")
			require(timer_isolation_checked, "old timer did not overlap the live reused Tag");
		#2100ns;
		check_retired(request, request_count - 1);
		if (failures == 0)
			`uvm_info("NATIVE_SV_IF_PASS", $sformatf(
				"direction=%s requests=%0d completions=%0d partials=%0d reused_tags=%0d timer_isolation=%0b checks=%0d pending=0 trackers=0 dedup=0 registry=0 tags=0",
				direction, requests_done, peer_responses, partials_checked, reused_tags, timer_isolation_checked, checks), UVM_LOW)
	endtask

	// 20us 上限覆盖正常41笔和迟到timer观察；接口卡死或Tag耗尽必须明确失败。
	virtual task run_phase(uvm_phase	phase);
		phase.raise_objection(this);
		fork
			execute_test();
			begin
				#20us;
				`uvm_fatal("NATIVE_SV_IF_TIMEOUT", "native interface regression exceeded 20us")
			end
		join_any
		disable fork;
		phase.drop_objection(this);
	endtask
endclass
