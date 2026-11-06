// pcie_tl_vip/tests：明确建立两条单向链路，ready 常高用于隔离 SCB 生命周期；生产 adapter
// 仍自行做 negedge 驱动/posedge 采样和 codec 编解码，不经过 TLM FIFO 传输。
// 依赖UVM、pcie_tl_if和独立test；top拥有两条interface直到仿真结束，test仅借用句柄。
// bridge合同的合成peer按真实接收的单拍MRd归还一个NPH，经interface送回生产FC同步逻辑；
// 这只是有界测试所需的外部transport信用行为，不表示已实现或验证PCIe数据链路层。
`timescale 1ns/1ps
module pcie_tl_native_sv_if_tb_top;
	import uvm_pkg::*;
	logic	clk = 0;
	logic	rst_n = 0;
	string	test_name;
	bit	bridge_credit_peer;
	pcie_tl_if	rc_to_ep(clk, rst_n);
	pcie_tl_if	ep_to_rc(clk, rst_n);

	// 每条单向接口独立观察实际握手，只为无prefix、单拍3DW/4DW MRd归还NPH。
	// codec将首个header字节放在data[7:0]，其中[7:5]为Fmt、[4:0]为Type。
	// 接收posedge后在negedge更新信用，adapter到下个posedge才采样，保证晚于
	// driver在send返回时消耗信用；每个周期重新计算，不会因valid保持而重复归还。
	// 复位及native模式不产生更新；其余信用固定为0，本fixture不模拟其他请求类别。
	task automatic return_mrd_credit(virtual pcie_tl_if	link);
		bit	accepted_mrd;

		forever begin
			@(posedge clk);
			accepted_mrd = bridge_credit_peer && rst_n && link.tlp_valid && link.tlp_ready &&
				link.tlp_sop && link.tlp_eop && link.tlp_data[4:0] == 5'b00000 &&
				(link.tlp_data[7:5] == 3'b000 || link.tlp_data[7:5] == 3'b001);
			@(negedge clk);
			link.nph_credit = accepted_mrd ? 8'd1 : 8'd0;
			link.fc_update  = accepted_mrd;
		end
	endtask

	always #2ns clk = ~clk;
	initial begin
		#20ns;
		rst_n = 1;
	end
	initial begin
		rc_to_ep.tlp_valid      = 0;
		rc_to_ep.tlp_sop        = 0;
		rc_to_ep.tlp_eop        = 0;
		rc_to_ep.tlp_ready      = 1;
		rc_to_ep.fc_update      = 0;
		rc_to_ep.ph_credit      = 0;
		rc_to_ep.pd_credit      = 0;
		rc_to_ep.nph_credit     = 0;
		rc_to_ep.npd_credit     = 0;
		rc_to_ep.cplh_credit    = 0;
		rc_to_ep.cpld_credit    = 0;
		ep_to_rc.tlp_valid      = 0;
		ep_to_rc.tlp_sop        = 0;
		ep_to_rc.tlp_eop        = 0;
		ep_to_rc.tlp_ready      = 1;
		ep_to_rc.fc_update      = 0;
		ep_to_rc.ph_credit      = 0;
		ep_to_rc.pd_credit      = 0;
		ep_to_rc.nph_credit     = 0;
		ep_to_rc.npd_credit     = 0;
		ep_to_rc.cplh_credit    = 0;
		ep_to_rc.cpld_credit    = 0;
		void'($value$plusargs("UVM_TESTNAME=%s", test_name));
		bridge_credit_peer = (test_name == "pcie_tl_bridge_completion_test");
		fork
			return_mrd_credit(rc_to_ep);
			return_mrd_credit(ep_to_rc);
		join_none
		uvm_config_db#(virtual pcie_tl_if)::set(null, "uvm_test_top", "rc_to_ep", rc_to_ep);
		uvm_config_db#(virtual pcie_tl_if)::set(null, "uvm_test_top", "ep_to_rc", ep_to_rc);
		run_test("pcie_tl_native_sv_if_test");
	end
endmodule
