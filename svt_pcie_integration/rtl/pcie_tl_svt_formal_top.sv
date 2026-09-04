//------------------------------------------------------------------------------
// TL-root + 正式 SVT agent Serial 验证顶层。
//------------------------------------------------------------------------------

`timescale 1ns/1fs
module pcie_tl_svt_formal_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "import_pcie_svt_uvm_pkgs.svi"
  `include `SVC_SOURCE_MAP_SUITE_UTIL_V(pcie_svc,PCIE,latest,svc_util_parms)
  `include `SVC_SOURCE_MAP_SUITE_MODEL_MODULE(pcie_svc,Include,latest,pciesvc_parms)
  `include "pcie_device_unified_vip_env.sv"
  `include "pcie_tl_svt_formal_test.sv"

  bit reset = 1'b1;
  int unsigned global_random_seed = 0;
  `include "hdl_interconnect_macros.sv"
  `include "pcie_tl_svt_formal_topology.sv"

  pciesvc_global_shadow #(.DISPLAY_NAME("global_shadow0.")) global_shadow0();

  initial begin
    #200ns;
    reset = 1'b0;
  end

  initial begin
    repeat (100) #0;
    run_test("pcie_tl_svt_formal_link_test");
  end
endmodule
