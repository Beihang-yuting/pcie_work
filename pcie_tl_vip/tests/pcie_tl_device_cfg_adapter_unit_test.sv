//------------------------------------------------------------------------------
// Unit test for the backend-neutral device -> TL context adapter.
//------------------------------------------------------------------------------
import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_tl_device_cfg_adapter_unit_test extends uvm_test;
  `uvm_component_utils(pcie_tl_device_cfg_adapter_unit_test)

  function new(string name = "pcie_tl_device_cfg_adapter_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    pcie_device_cfg policy_a;
    pcie_device_cfg policy_b;
    pcie_tl_func_context context_a;
    pcie_tl_func_context context_b;
    pcie_tl_device_cfg_adapter adapter;
    string errors[$];

    phase.raise_objection(this);
    adapter = pcie_tl_device_cfg_adapter::type_id::create("adapter");

    policy_a = pcie_device_cfg::type_id::create("policy_a");
    policy_a.device_id = "EP_A";
    policy_a.bdf = 16'h0200;
    policy_a.header_type = 8'h00;
    policy_a.cfg_space_enable = 1'b1;
    policy_a.init_default_bars();
    policy_a.bars[0].initial_base = 64'h0000_0001_0000_0000;
    context_a = pcie_tl_func_context::type_id::create("context_a");
    if (!adapter.apply_device_cfg(policy_a, context_a, errors))
      `uvm_fatal("TL_DEVICE_CFG", "policy_a translation failed")
    if (context_a.bdf != 16'h0200 || context_a.bar_size[0] != 32 * 1024 * 1024 ||
        context_a.bar_base[0] != 64'h0000_0001_0000_0000 ||
        context_a.bar_owner[1] != 0)
      `uvm_error("TL_DEVICE_CFG", "policy_a identity/BAR mapping mismatch")

    policy_b = pcie_device_cfg::type_id::create("policy_b");
    policy_b.device_id = "EP_B";
    policy_b.bdf = 16'h0210;
    policy_b.header_type = 8'h00;
    policy_b.cfg_space_enable = 1'b1;
    policy_b.init_default_bars();
    policy_b.bars[0].aperture = 64 * 1024;
    context_b = pcie_tl_func_context::type_id::create("context_b");
    errors.delete();
    if (!adapter.apply_device_cfg(policy_b, context_b, errors))
      `uvm_fatal("TL_DEVICE_CFG", "policy_b translation failed")
    if (context_b.bdf != 16'h0210 || context_b.bar_size[0] != 64 * 1024)
      `uvm_error("TL_DEVICE_CFG", "policy_b identity/BAR mapping mismatch")
    if (context_a.cfg_mgr.read(12'h010) == context_b.cfg_mgr.read(12'h010) &&
        context_a.bdf == context_b.bdf)
      `uvm_error("TL_DEVICE_CFG", "device contexts unexpectedly alias")

    phase.drop_objection(this);
  endtask
endclass
