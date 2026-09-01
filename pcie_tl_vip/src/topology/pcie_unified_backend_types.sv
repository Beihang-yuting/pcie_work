//------------------------------------------------------------------------------
// Backend-neutral PCIe environment types.
//
// These declarations intentionally live beside pcie_topology_pkg rather than
// inside the SVT package.  The TL-only build must be able to consume the same
// global configuration without depending on Synopsys SVT libraries.
//------------------------------------------------------------------------------

// Selects which protocol implementation is created by pcie_unified_env.
// The value is policy only; it does not change the static HDL elaboration.
typedef enum {
  PCIE_BACKEND_TL_ONLY,
  PCIE_BACKEND_SVT_REAL_DUT,
  PCIE_BACKEND_SVT_TL_FORWARD
} pcie_backend_e;

// Generic device role used by both TL and SVT adapters.  It is deliberately
// independent of SVT-specific role enums so package dependencies stay acyclic.
typedef enum {
  PCIE_DEVICE_RC,
  PCIE_DEVICE_SWITCH,
  PCIE_DEVICE_EP
} pcie_device_role_e;

// A BAR descriptor contains policy, not a live decoder.  Each backend translates
// it into its own BAR/configuration implementation during build/connect.
class pcie_unified_bar_cfg extends uvm_object;
  bit implemented;
  bit is_64bit;
  bit prefetchable;
  longint unsigned aperture;
  longint unsigned initial_base;

  `uvm_object_utils(pcie_unified_bar_cfg)

  function new(string name = "pcie_unified_bar_cfg");
    super.new(name);
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_unified_bar_cfg source;

    super.do_copy(rhs);
    if (!$cast(source, rhs)) begin
      `uvm_fatal("GLOBAL_CFG_COPY", "BAR source has the wrong type")
      return;
    end
    implemented  = source.implemented;
    is_64bit     = source.is_64bit;
    prefetchable = source.prefetchable;
    aperture     = source.aperture;
    initial_base = source.initial_base;
  endfunction
endclass
