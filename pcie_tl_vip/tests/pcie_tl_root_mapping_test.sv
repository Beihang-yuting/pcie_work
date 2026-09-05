import uvm_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

//------------------------------------------------------------------------------
// 非恒等 Root 映射回归。
//
// 该测试故意让 EP0 属于 Root1、EP1 属于 Root0。检查对象不是 policy
// 字段本身，而是 connect_phase 后 EP agent 实际拿到的 manager 句柄，
// 用来防止适配层只写元数据、底层仍按数组序号路由的回归。
//------------------------------------------------------------------------------
class pcie_tl_root_mapping_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_root_mapping_test)

    function new(string name = "pcie_tl_root_mapping_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void require(bit condition, string message);
        if (!condition)
            `uvm_error("ROOT_MAP", message)
    endfunction

    virtual function void configure_test();
        pcie_device_cfg ep0_cfg;
        pcie_device_cfg ep1_cfg;
        string why;

        super.configure_test();

        // 两条独立直连链路各自有一个 RC，EP 的 Root 归属与声明顺序相反。
        cfg.rc_agent_enable = 1'b1;
        cfg.ep_agent_enable = 1'b1;
        cfg.num_rc = 2;
        cfg.num_ep = 2;
        cfg.scb_enable = 1'b0;
        // 通过配置 API 显式声明非恒等映射，模拟 DPU 适配层产生的结果。
        require(cfg.bind_ep_root(0, 1, why),
                {"bind EP0 -> Root1 failed: ", why});
        require(cfg.bind_ep_root(1, 0, why),
                {"bind EP1 -> Root0 failed: ", why});

        ep0_cfg = pcie_device_cfg::type_id::create("ep0_cfg");
        ep0_cfg.device_id = "EP0";
        ep0_cfg.role = PCIE_DEVICE_EP;
        ep0_cfg.bdf = 16'h0200;

        ep1_cfg = pcie_device_cfg::type_id::create("ep1_cfg");
        ep1_cfg.device_id = "EP1";
        ep1_cfg.role = PCIE_DEVICE_EP;
        ep1_cfg.bdf = 16'h0208;

        cfg.device_cfgs.push_back(ep0_cfg);
        cfg.device_cfgs.push_back(ep1_cfg);
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        if ((env == null) || (env.ep_agents.size() != 2)) begin
            `uvm_error("ROOT_MAP", "expected two Endpoint agents")
            return;
        end

        // 断言实际连接到的 manager，而不是只检查配置表中的 Root 字段。
        if (env.ep_agents[0].fc_mgr != env.fc_mgrs[1])
            `uvm_error("ROOT_MAP",
                       "EP0 did not use the manager of mapped Root1")
        if (env.ep_agents[1].fc_mgr != env.fc_mgrs[0])
            `uvm_error("ROOT_MAP",
                       "EP1 did not use the manager of mapped Root0")
    endfunction
endclass
