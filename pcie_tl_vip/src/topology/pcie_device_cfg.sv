//------------------------------------------------------------------------------
// Backend-neutral PCIe device configuration.
//
// This object describes one enumerated device.  It is separate from
// pcie_topology_node_cfg because a graph node describes connectivity, while
// this object describes the device's configuration-space image and BAR policy.
//------------------------------------------------------------------------------

class pcie_device_cfg extends uvm_object;
  // --------------------------------------------------------------------------
  // Enumerated identity and role.
  // --------------------------------------------------------------------------
  // Stable project identifier used to match a graph node or Switch port.
  string device_id;

  // Numeric PCI identity is kept separate from the string project identifier.
  // Zero means "use backend default" when a caller does not care about IDs.
  bit [15:0] vendor_id;
  bit [15:0] pci_device_id;

  // Generic role is translated into Type-0/Type-1 behavior by each backend.
  pcie_device_role_e role;

  // Runtime BDF and header format used for enumeration and routing checks.
  bit [15:0] bdf;

  // Domain-qualified identity is supplied by dpu-common.  The legacy
  // topology-only path leaves these at zero; multi-domain backends can use
  // them to disambiguate identical BDF values.
  int unsigned domain_host_id;
  int unsigned domain_segment_id;

  // Optional DPU ownership labels.  Strings keep this package independent of
  // dpu_resource_pkg while still allowing an adapter to carry the mapping.
  string physical_node_id;
  string link_id;
  string function_key_name;
  bit [7:0] header_type;

  // Command-space policy.  The backend may update the live enable state after
  // an enumeration sequence writes the Command register.
  bit cfg_space_enable;
  bit bus_master_enable;

  // --------------------------------------------------------------------------
  // Type-0 configuration-space BAR image.
  // --------------------------------------------------------------------------
  // Six fixed BAR descriptors are used because PCIe Type-0 has six BAR slots.
  pcie_unified_bar_cfg bars[6];

  `uvm_object_utils(pcie_device_cfg)

  function new(string name = "pcie_device_cfg");
    super.new(name);

    // Create all six descriptors up front so scenario code may update BAR
    // policy without repeating null checks for each optional override.
    foreach (bars[i])
      bars[i] = pcie_unified_bar_cfg::type_id::create(
        $sformatf("bar%0d", i));
  endfunction

  // Creates the project-wide default BAR image: three 64-bit prefetchable
  // pairs (BAR0/1=32MB, BAR2/3=64KB, BAR4/5=64KB).  Upper DWORD entries remain
  // present as descriptors but are marked unimplemented by the low owner.
  function void init_default_bars();
    longint unsigned apertures[3] = '{32 * 1024 * 1024,
                                      64 * 1024,
                                      64 * 1024};

    // Clear stale scenario overrides before applying the project defaults.
    foreach (bars[i]) begin
      if (bars[i] == null)
        bars[i] = pcie_unified_bar_cfg::type_id::create(
          $sformatf("bar%0d", i));

      bars[i].implemented  = 1'b0;
      bars[i].is_64bit     = 1'b0;
      bars[i].prefetchable = 1'b0;
      bars[i].aperture     = 0;
      bars[i].initial_base = 0;
    end

    // Only the low DWORD owns each 64-bit BAR.  Its adjacent descriptor stays
    // unimplemented and is claimed by the backend when the pair is created.
    for (int pair = 0; pair < 3; pair++) begin
      int low;

      low = pair * 2;

      bars[low].implemented  = 1'b1;
      bars[low].is_64bit     = 1'b1;
      bars[low].prefetchable = 1'b1;
      bars[low].aperture     = apertures[pair];
    end
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_device_cfg source;

    super.do_copy(rhs);

    if (!$cast(source, rhs)) begin
      `uvm_fatal("GLOBAL_CFG_COPY", "device source has the wrong type")
      return;
    end

    // Scalar configuration-space identity and enable policy.
    device_id          = source.device_id;
    vendor_id          = source.vendor_id;
    pci_device_id      = source.pci_device_id;
    role               = source.role;
    bdf                = source.bdf;
    domain_host_id     = source.domain_host_id;
    domain_segment_id  = source.domain_segment_id;
    physical_node_id   = source.physical_node_id;
    link_id            = source.link_id;
    function_key_name  = source.function_key_name;
    header_type        = source.header_type;
    cfg_space_enable   = source.cfg_space_enable;
    bus_master_enable  = source.bus_master_enable;

    // BAR objects require deep copies because tests may customize each device
    // independently after cloning a global configuration.
    foreach (bars[i]) begin
      if (source.bars[i] == null) begin
        bars[i] = null;
      end
      else begin
        if (bars[i] == null)
          bars[i] = pcie_unified_bar_cfg::type_id::create(
            $sformatf("bar%0d", i));

        bars[i].copy(source.bars[i]);
      end
    end
  endfunction
endclass
