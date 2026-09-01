//------------------------------------------------------------------------------
// Translation from backend-neutral device policy to a TL function context.
//
// The adapter owns no routing policy.  It only creates an independent config
// manager/BAR state for one device so multiple endpoints cannot accidentally
// share a configuration image through an owner USP manager.
//------------------------------------------------------------------------------

class pcie_tl_device_cfg_adapter extends uvm_object;
  `uvm_object_utils(pcie_tl_device_cfg_adapter)

  function new(string name = "pcie_tl_device_cfg_adapter");
    super.new(name);
  endfunction

  function bit apply_device_cfg(
      pcie_device_cfg src,
      pcie_tl_func_context dst,
      output string errors[$]);
    bit [15:0] vendor;
    bit [15:0] device;

    errors.delete();
    if (src == null) begin
      errors.push_back("device policy is null");
      return 1'b0;
    end
    if (dst == null) begin
      errors.push_back("destination TL function context is null");
      return 1'b0;
    end

    vendor = (src.vendor_id == 0) ? 16'hABCD : src.vendor_id;
    device = (src.pci_device_id == 0) ? 16'h1234 : src.pci_device_id;
    dst.bdf     = src.bdf;
    dst.enabled = 1'b1;
    dst.is_bridge = (src.role == PCIE_DEVICE_SWITCH);
    dst.memory_space_en = src.cfg_space_enable;
    dst.bus_master_en   = src.bus_master_enable;
    dst.init_cfg_space(vendor, device, .header_type(src.header_type));

    // Copy each BAR descriptor into the context.  A high DWORD of a 64-bit
    // pair points back to its low owner, matching the decoder's convention.
    foreach (src.bars[bar]) begin
      pcie_unified_bar_cfg bar_cfg;
      bar_cfg = src.bars[bar];
      dst.bar_owner[bar] = bar;
      dst.bar_base[bar]  = 0;
      dst.bar_size[bar]  = 0;
      dst.bar_enable[bar] = 0;
      dst.bar_flags[bar] = 0;
      if (bar_cfg == null)
        continue;
      if (bar_cfg.implemented) begin
        dst.bar_base[bar]   = bar_cfg.initial_base;
        dst.bar_size[bar]   = bar_cfg.aperture;
        dst.bar_enable[bar] = src.cfg_space_enable;
        dst.bar_flags[bar]  = (bar_cfg.is_64bit ? 32'h4 : 32'h0) |
                              (bar_cfg.prefetchable ? 32'h8 : 32'h0);
        if (bar_cfg.is_64bit) begin
          if (bar == 5) begin
            errors.push_back($sformatf(
              "device '%s' BAR5 cannot be a 64-bit BAR owner",
              src.device_id));
          end
          else begin
            dst.bar_owner[bar + 1] = bar;
            dst.bar_flags[bar + 1] = dst.bar_flags[bar];
          end
        end
      end
    end

    if (errors.size() != 0)
      return 1'b0;
    return 1'b1;
  endfunction
endclass
