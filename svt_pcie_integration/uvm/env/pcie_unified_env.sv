//------------------------------------------------------------------------------
// 兼容性薄包装（已弃用）。
//
// 新代码应直接实例化 pcie_tl_env；本类只为尚未迁移的 DPU/历史测试保留
// 原始类型名和句柄别名，不再创建 SVT backend、global sequence 或第二套
// PCIe agent。所有实际 PCIe 控制仍由父类 pcie_tl_env 完成。
//------------------------------------------------------------------------------

typedef class pcie_svt_topology_env;

class pcie_unified_env extends pcie_tl_env;
  `uvm_component_utils(pcie_unified_env)

  // 历史代码读取的策略快照；它不是新的控制面。
  pcie_global_cfg global_cfg;

  // 历史 DPU 代码使用的 TL 别名，始终指向 this。
  pcie_tl_env tl_env;

  // 仅保留类型兼容句柄；新 TL-root SVT adapter 不通过此句柄管理 SVT。
  pcie_svt_topology_env svt_env;

  function new(string name = "pcie_unified_env",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    void'(uvm_config_db#(pcie_global_cfg)::get(
      this, "", "global_cfg", global_cfg));
    tl_env = this;
    svt_env = null;
    super.build_phase(phase);
  endfunction
endclass : pcie_unified_env
