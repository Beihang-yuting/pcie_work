//------------------------------------------------------------------------------
// PCIe TL-root SVT adapter package.
//
// 生产 TL-root filelist 只需要本 package；它不包含 topology env、global
// sequence 或 peer self-check。这样 SVT 作为物理适配层接入时，不会引入第二
// 套配置/枚举管理面，同时 TL-only filelist 完全不依赖 SVT。
//------------------------------------------------------------------------------

package pcie_svt_adapter_pkg;
  import uvm_pkg::*;
  import pcie_topology_pkg::*;
  import pcie_tl_pkg::*;
  `include "import_pcie_svt_uvm_pkgs.svi"
  `include "uvm_macros.svh"

  `include "adapter/pcie_svt_adapter_types.sv"
  `include "adapter/pcie_svt_tlp_codec.sv"
  `include "adapter/pcie_svt_tlp_mapper_bridge.sv"
  `include "adapter/pcie_svt_if_adapter.sv"
endpackage : pcie_svt_adapter_pkg
