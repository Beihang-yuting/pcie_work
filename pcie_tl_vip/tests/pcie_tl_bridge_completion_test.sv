// pcie_tl_vip/tests：后端provider中性Completion合同回归，复用真实native接口传输测试。
// 依赖已有pcie_tl_fake_backend_provider与native test；global_cfg/graph和provider由测试持有。
// provider真实执行build/映射验证，env按原流程创建bridge FIFO并连接SCB TX预登记。
// 两条pcie_tl_if代表外部transport，不代表Synopsys Serial/PIPE或RTL switch已验证。
// peer仍只经monitor观察与adapter回复；不补Completion回调、不改生产bridge_required。
import pcie_topology_pkg::*;

class pcie_tl_bridge_completion_test extends pcie_tl_native_sv_if_test;
	`uvm_component_utils(pcie_tl_bridge_completion_test)
	pcie_tl_fake_backend_provider	provider;
	pcie_global_cfg			global_policy;

	// 构造继承真实接口与字节/Tag/SCB检查，不创建另一份镜像检查器。
	function new(string	name = "pcie_tl_bridge_completion_test", uvm_component	parent = null);
		super.new(name, parent);
	endfunction

	// 父build只create env，UVM尚未遍历其build；在此提供正式provider合同输入。
	// 一USP一DSP图给RC/EP各一个独立link身份，已有fake provider按原契约发布两个adapter。
	// use_unified_mem=0使RC业务请求路径无内存responder，唯一响应来自明确的测试peer。
	// auto_response=1只用于EP请求方向，EP接收的是Completion，因此可检验dispatcher不双消费。
	virtual function void build_phase(uvm_phase	phase);
		pcie_topology_builder	builder;
		pcie_topology_cfg	graph;
		pcie_tl_if_adapter	adapter;
		int	owners[];
		string	errors[$];

		super.build_phase(phase);
		expect_bridge = 1;
		cfg.ep_auto_response = $test$plusargs("BRIDGE_AUTO_RESPONSE");
		cfg.use_unified_mem = 0;
		if (cfg.ep_auto_response && direction != "EP")
			`uvm_fatal("BRIDGE_COMPLETION", "auto-response variant requires EP requester to avoid two peers")
		builder = new("bridge_contract_builder");
		owners = new[1];
		owners[0] = 0;
		void'(builder.add_rc("RC0"));
		void'(builder.add_switch("SW0", 1, 1, owners));
		void'(builder.add_ep("EP0"));
		void'(builder.connect("RC_LINK", "RC0", PCIE_TOPO_PORT_RC, 0, "SW0", PCIE_TOPO_PORT_USP, 0, 8, 4));
		void'(builder.connect("EP_LINK", "SW0", PCIE_TOPO_PORT_DSP, 0, "EP0", PCIE_TOPO_PORT_EP, 0, 8, 4));
		graph = builder.finish();
		global_policy = new("bridge_contract_policy");
		global_policy.build_default_for_topology(graph);
		global_policy.backend = PCIE_BACKEND_SVT_REAL_DUT;
		global_policy.svt_bridge_enable = 1;
		global_policy.runtime_num_links = 2;
		foreach (global_policy.links[index]) begin
			global_policy.links[index].use_svt       = 1;
			global_policy.links[index].svt_role_valid = 1;
			global_policy.links[index].svt_role      =
				(global_policy.links[index].link_id == "RC_LINK") ? PCIE_DEVICE_RC : PCIE_DEVICE_EP;
			global_policy.links[index].svt_node_id   =
				(global_policy.links[index].link_id == "RC_LINK") ? "RC0" : "EP0";
			global_policy.links[index].has_hdl_slot  = 1;
			global_policy.links[index].hdl_slot      = index;
			global_policy.links[index].vif_key       = $sformatf("contract_if_%0d", index);
		end
		global_policy.validate(errors);
		if (errors.size() != 0) `uvm_fatal("BRIDGE_COMPLETION", errors[0])
		provider = new("bridge_contract_provider");
		for (int	index = 0; index < 2; index++) begin
			adapter = new($sformatf("contract_adapter_%0d", index), this);
			adapter.vif = rc_to_ep;
			provider.adapter_pool.push_back(adapter);
		end
		provider.bridge_required_value = 1;
		uvm_config_db#(pcie_global_cfg)::set(this, "env", "global_cfg", global_policy);
		uvm_config_db#(pcie_tl_env_config)::set(this, "env", "tl_policy_cfg", cfg);
		uvm_config_db#(pcie_tl_backend_provider)::set(this, "env", "pcie_tl_backend_provider", provider);
	endfunction

	// 确认是生产provider发现路径激活的bridge，不接受手工翻位或只存在测试peer的假覆盖。
	virtual function void end_of_elaboration_phase(uvm_phase	phase);
		super.end_of_elaboration_phase(phase);
		require(provider.build_called && env.backend_provider_active && env.bridge_required &&
			provider.created_transport_count == 2 && env.bridge_ep_rx_fifos.size() == 1,
			"provider bridge contract was not constructed by the real environment");
	endfunction
endclass
