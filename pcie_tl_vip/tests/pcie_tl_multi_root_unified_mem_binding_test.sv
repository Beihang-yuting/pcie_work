import uvm_pkg::*;
import pcie_tl_pkg::*;
import host_mem_pkg::*;
`include "uvm_macros.svh"

//------------------------------------------------------------------------------
// Multi-Root unified Host memory binding regression.
//
// 本测试不依赖 Switch 或具体 Endpoint 数据流，专门检查 PCIe TL 环境管理层
// 的 Root -> Host memory 绑定契约。三个 Root 的映射为：
//
//   Root0 -> Host0
//   Root1 -> Host1
//   Root2 -> Host0
//
// Root0 与 Root2 共享同一个 Host0 manager，用来验证 PREMAP 模式不会因为
// 同一 manager 被两个 Root 引用而重复分配 backing memory。
//------------------------------------------------------------------------------
class pcie_tl_multi_root_unified_mem_binding_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_multi_root_unified_mem_binding_test)

    // 测试自己持有 manager，确保 env 使用的句柄在整个仿真期间有效。
    host_mem_manager host0_manager;
    host_mem_manager host1_manager;

    function new(
        string name = "pcie_tl_multi_root_unified_mem_binding_test",
        uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void require(bit condition, string message);
        if (!condition)
            `uvm_error("MR_UM_BIND", message)
    endfunction

    virtual function void configure_test();
        string why;

        super.configure_test();

        // 三个独立 RC Root，不创建 EP agent；本测试关注 RC Host memory 注入。
        cfg.rc_agent_enable = 1'b1;
        cfg.ep_agent_enable = 1'b0;
        cfg.num_rc         = 3;
        cfg.num_ep         = 0;

        cfg.use_unified_mem = 1'b1;
        cfg.mem_access_mode = PCIE_TL_MEM_PREMAP;
        cfg.mem_alloc_mode  = MODE_LINEAR;
        cfg.mem_granule     = 16;
        cfg.premap_size     = 32'h0100_0000; // 16 MiB，便于检查第二次分配
        cfg.fc_enable       = 1'b1;
        cfg.infinite_credit = 1'b1;
        cfg.scb_enable      = 1'b0;

        host0_manager = new("host0_manager");
        host1_manager = new("host1_manager");
        host0_manager.set_host_id(0);
        host1_manager.set_host_id(1);
        // FIRST_FIT 让 PREMAP 后的下一次 alloc 地址可确定地用于断言。
        host0_manager.set_alloc_policy(HOST_MEM_FIRST_FIT);
        host1_manager.set_alloc_policy(HOST_MEM_FIRST_FIT);

        require(cfg.bind_host_memory(0, 0, host0_manager, why),
                {"bind Root0 -> Host0 failed: ", why});
        require(cfg.bind_host_memory(1, 1, host1_manager, why),
                {"bind Root1 -> Host1 failed: ", why});
        require(cfg.bind_host_memory(2, 0, host0_manager, why),
                {"bind Root2 -> Host0 failed: ", why});
    endfunction

    task run_phase(uvm_phase phase);
        bit [63:0] host0_probe;
        bit [63:0] host1_probe;
        pcie_tl_env_config invalid_cfg;
        host_mem_manager wrong_id_manager;
        string why;
        string errors[$];

        phase.raise_objection(this);
        `uvm_info("MR_UM_BIND", "=== Multi-Root Host binding test START ===", UVM_LOW)

        // 环境已经把每个 RC driver 注入了 Root-specific manager。
        require(env.host_mem_by_root.size() == 3,
                $sformatf("expected 3 Root memory handles, got %0d",
                          env.host_mem_by_root.size()));
        require(env.host_mem_by_root[0] == host0_manager,
                "Root0 did not receive Host0 manager");
        require(env.host_mem_by_root[1] == host1_manager,
                "Root1 did not receive Host1 manager");
        require(env.host_mem_by_root[2] == host0_manager,
                "Root2 did not share Host0 manager");
        require(env.rc_agents[0].rc_driver.mem == host0_manager,
                "RC0 driver memory handle is incorrect");
        require(env.rc_agents[1].rc_driver.mem == host1_manager,
                "RC1 driver memory handle is incorrect");
        require(env.rc_agents[2].rc_driver.mem == host0_manager,
                "RC2 driver memory handle is incorrect");

        require(host0_manager.is_initialized(),
                "Host0 manager was not initialized");
        require(host1_manager.is_initialized(),
                "Host1 manager was not initialized");

        // PREMAP 应该对 Host0 只 alloc 一次。FIRST_FIT 下第一块 16 MiB
        // 占用 [0, 0x00ff_ffff]，下一次 64B 分配应从 0x0100_0000 开始。
        host0_probe = host0_manager.alloc(64, 64);
        host1_probe = host1_manager.alloc(64, 64);
        require(host0_probe == 64'h0100_0000,
                $sformatf("Host0 PREMAP appears repeated or misplaced: probe=0x%0h",
                          host0_probe));
        require(host1_probe == 64'h0100_0000,
                $sformatf("Host1 PREMAP probe address unexpected: probe=0x%0h",
                          host1_probe));
        host0_manager.free(host0_probe);
        host1_manager.free(host1_probe);

        // bind_host_memory() 的本地契约：同一 Root 不能重复绑定。
        require(!cfg.bind_host_memory(0, 0, host0_manager, why),
                "duplicate Root binding was accepted");
        require(why != "", "duplicate Root binding did not report a reason");

        // manager host_id 与声明的 Host 不一致时必须立即拒绝。
        wrong_id_manager = new("wrong_id_manager");
        wrong_id_manager.set_host_id(7);
        require(!cfg.bind_host_memory(3, 1, wrong_id_manager, why),
                "Host manager ID mismatch was accepted");
        require(why != "", "Host manager ID mismatch did not report a reason");

        // 新配置没有显式绑定时，多 Root unified memory 必须失败；不能回退
        // 到单一 config-db host_mem，也不能创建隐式私有 manager。
        invalid_cfg = pcie_tl_env_config::type_id::create("missing_bindings");
        invalid_cfg.use_unified_mem = 1'b1;
        require(!invalid_cfg.validate_host_memory_bindings(3, errors),
                "missing multi-Root bindings were accepted");
        require(errors.size() != 0,
                "missing multi-Root binding did not report an error");

        `uvm_info("MR_UM_BIND", "=== Multi-Root Host binding test END ===", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
