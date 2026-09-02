//------------------------------------------------------------------------------
// Combined DPU-aware PCIe system package.
//
// This is intentionally separate from pcie_dpu_integration_pkg: only the
// final system integration imports both protocol stacks.  Native TL, native
// SVT, and backend-neutral DPU packages remain independently compilable.
//------------------------------------------------------------------------------

package pcie_dpu_system_pkg;
  import uvm_pkg::*;
  import dpu_resource_pkg::*;
  import pcie_topology_pkg::*;
  import pcie_tl_pkg::*;
  import pcie_dpu_integration_pkg::*;
  import pcie_svt_topology_pkg::*;
  import pcie_dpu_tl_backend_pkg::*;
  import pcie_dpu_svt_backend_pkg::*;
  `include "import_pcie_svt_uvm_pkgs.svi"
  `include "uvm_macros.svh"

  `include "pcie_dpu_system_env.sv"
  `include "pcie_dpu_global_stage_vseq.sv"
  `include "pcie_dpu_device_base_test.sv"
endpackage : pcie_dpu_system_pkg
