//------------------------------------------------------------------------------
// TL-root SVT adapter 链路门禁。
//
// 该测试首先验证工厂覆盖确实生成 pcie_svt_if_adapter，并检查 endpoint
// 已创建。未绑定正式 SVT Mapper 时允许完成 compile/elaboration-only 流程；
// 真实 DUT 回归请增加 +PCIE_SVT_REQUIRE_MAPPER，使 adapter 在 connect_phase
// 对缺失 Mapper 直接报出清晰 fatal。
//------------------------------------------------------------------------------

`include "uvm_macros.svh"

import uvm_pkg::*;
import pcie_tl_pkg::*;
import pcie_svt_adapter_pkg::*;

class pcie_tl_svt_adapter_link_test extends pcie_tl_svt_adapter_base_test;
  `uvm_component_utils(pcie_tl_svt_adapter_link_test)

  function new(string name = "pcie_tl_svt_adapter_link_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_adapter_test(uvm_phase phase);
    pcie_svt_if_adapter rc_svt_adapter;
    pcie_svt_if_adapter ep_svt_adapter;

    phase.raise_objection(this);

    if (!$cast(rc_svt_adapter, env.rc_adapter) ||
        (rc_svt_adapter == null))
      `uvm_fatal("SVT_LINK", "RC adapter 工厂覆盖未生成 pcie_svt_if_adapter")

    if (!$cast(ep_svt_adapter, env.ep_adapter) ||
        (ep_svt_adapter == null))
      `uvm_fatal("SVT_LINK", "EP adapter 工厂覆盖未生成 pcie_svt_if_adapter")

    if (rc_svt_adapter.mapper_endpoint == null ||
        ep_svt_adapter.mapper_endpoint == null)
      `uvm_fatal("SVT_LINK", "SVT adapter Mapper endpoint 未创建")

    `uvm_info("SVT_LINK",
      "TL-root adapter link 门禁通过（当前未注入正式 SVT agent，未发送实际 TLP）",
      UVM_LOW)

    #100ns;
    phase.drop_objection(this);
  endtask
endclass

