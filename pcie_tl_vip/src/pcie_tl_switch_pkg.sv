//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Host-Memory-Free Switch Package
//-----------------------------------------------------------------------------
// Compilation contract: use this lightweight package instead of pcie_tl_pkg.
// Do not compile both packages into the same simulation image because they
// register the same UVM class names.

package pcie_tl_switch_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    `include "types/pcie_tl_types.sv"
    `include "types/pcie_tl_prefix.sv"
    `include "types/pcie_tl_tlp.sv"
    `include "switch/pcie_tl_switch_route_event.sv"

    `include "shared/pcie_tl_fc_manager.sv"
    `include "shared/pcie_tl_link_delay_model.sv"

    `include "switch/pcie_tl_switch_config.sv"
    `include "switch/pcie_tl_switch_port.sv"
    `include "switch/pcie_tl_switch_fabric.sv"
    `include "switch/pcie_tl_switch.sv"

endpackage : pcie_tl_switch_pkg
