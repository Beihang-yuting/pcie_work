//------------------------------------------------------------------------------
// Optional DPU-to-PCIe integration package.
//
// This package is compiled only by DPU-aware integrations.  The generic TL
// and SVT packages do not import dpu_resource_pkg, so either backend remains
// usable without the virtio_work repository.
//------------------------------------------------------------------------------

package pcie_dpu_integration_pkg;
  import uvm_pkg::*;
  import dpu_resource_pkg::*;
  import pcie_topology_pkg::*;
  `include "uvm_macros.svh"
  `include "pcie_dpu_attachment_cfg.sv"
  `include "pcie_dpu_cfg_adapter.sv"
  `include "pcie_dpu_reg_executor_base.sv"
endpackage : pcie_dpu_integration_pkg
