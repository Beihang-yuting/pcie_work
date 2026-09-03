//------------------------------------------------------------------------------
// TL-root + SVT adapter 的生产测试基类。
//
// 本测试有意只创建 pcie_tl_env。TL VIP 仍是唯一配置、枚举和事务控制面，
// SVT 适配器通过 pcie_tl_if_adapter 工厂覆盖注入。真实 SVT device agent
// 应由产品顶层创建，并以 "svt_agent" 或 "pcie_svt_mapper" 键发布给 adapter。
//------------------------------------------------------------------------------

`include "uvm_macros.svh"

import uvm_pkg::*;
import pcie_tl_pkg::*;
import pcie_svt_adapter_pkg::*;

class pcie_tl_svt_adapter_base_test extends uvm_test;
  `uvm_component_utils(pcie_tl_svt_adapter_base_test)

  // 唯一生产根环境；不依赖 unified/topology env。
  pcie_tl_env        env;
  pcie_tl_env_config cfg;

  function new(string name = "pcie_tl_svt_adapter_base_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // 覆盖必须在 env 创建前安装，确保 RC/EP 的所有 adapter 都使用 SVT 子类。
    pcie_tl_if_adapter::type_id::set_type_override(
      pcie_svt_if_adapter::get_type());

    cfg = pcie_tl_env_config::type_id::create("cfg");
    cfg.if_mode          = SV_IF_MODE;
    cfg.rc_agent_enable  = 1'b1;
    cfg.ep_agent_enable  = 1'b1;
    cfg.num_rc           = 1;
    cfg.num_ep           = 1;
    cfg.ep_auto_response = 1'b1;
    cfg.infinite_credit  = 1'b1;

    // compile/elaboration 门禁不需要 scoreboard；真实流量测试可在派生类打开。
    cfg.scb_enable       = 1'b0;

    uvm_config_db#(pcie_tl_env_config)::set(this, "env", "cfg", cfg);
    env = pcie_tl_env::type_id::create("env", this);
  endfunction

  // 派生测试可重载此钩子，在 env 创建后执行自定义 sequence。
  virtual task run_adapter_test(uvm_phase phase);
    phase.raise_objection(this);
    #100ns;
    phase.drop_objection(this);
  endtask

  task run_phase(uvm_phase phase);
    run_adapter_test(phase);
  endtask
endclass

