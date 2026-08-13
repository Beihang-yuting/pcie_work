class pcie_svt_cfg_space_builder extends uvm_object;
  `uvm_object_utils(pcie_svt_cfg_space_builder)

  function new(string name = "pcie_svt_cfg_space_builder");
    super.new(name);
  endfunction

  function automatic bit [31:0] bar_sizing_dw(longint unsigned aperture,
                                               bit upper);
    bit [63:0] mask;
    mask = ~(aperture - 1);
    return upper ? mask[63:32] : (mask[31:0] | 32'h0000_000c);
  endfunction

  function automatic bit [31:0] bar_ro_map(longint unsigned aperture,
                                            bit upper);
    bit [63:0] ro_map;
    ro_map = aperture - 1;
    return upper ? ro_map[63:32] : ro_map[31:0];
  endfunction

  function void put_dw(ref bit [31:0] image[1024],
                       input int unsigned byte_offset,
                       input bit [31:0] value);
    if ((byte_offset & 3) != 0) begin
      `uvm_error("CFG_BUILD", $sformatf(
        "configuration DWORD offset 0x%0h is not DWORD aligned", byte_offset))
      return;
    end
    if (byte_offset > 12'hffc) begin
      `uvm_error("CFG_BUILD", $sformatf(
        "configuration DWORD offset 0x%0h exceeds 4 KiB", byte_offset))
      return;
    end
    image[byte_offset/4] = value;
  endfunction

  function automatic bit is_ext_cap_header(int unsigned byte_offset);
    case (byte_offset)
      12'h100, 12'h180, 12'h240, 12'h260, 12'h280,
      12'h2a0, 12'h2c0, 12'h300: return 1;
      default: return 0;
    endcase
  endfunction

  function automatic bit is_std_cap_header(int unsigned byte_offset);
    case (byte_offset)
      12'h040, 12'h080, 12'h0a0: return 1;
      default: return 0;
    endcase
  endfunction

  function automatic bit [31:0] ext_cap_header(bit [15:0] cap_id,
                                                bit [3:0] version,
                                                int unsigned next_offset);
    return {next_offset[11:0], version, cap_id};
  endfunction

  function automatic int unsigned next_ext_cap(
      pcie_svt_function_profile fn, int unsigned offset);
    case (offset)
      12'h100: begin
        if (fn.enable_sriov) return 12'h180;
        if (fn.enable_ats)   return 12'h240;
        if (fn.enable_pri)   return 12'h260;
        if (fn.enable_pasid) return 12'h280;
        if (fn.enable_ari)   return 12'h2a0;
        if (fn.enable_acs)   return 12'h2c0;
        if (fn.enable_rebar) return 12'h300;
      end
      12'h180: begin
        if (fn.enable_ats)   return 12'h240;
        if (fn.enable_pri)   return 12'h260;
        if (fn.enable_pasid) return 12'h280;
        if (fn.enable_ari)   return 12'h2a0;
        if (fn.enable_acs)   return 12'h2c0;
        if (fn.enable_rebar) return 12'h300;
      end
      12'h240: begin
        if (fn.enable_pri)   return 12'h260;
        if (fn.enable_pasid) return 12'h280;
        if (fn.enable_ari)   return 12'h2a0;
        if (fn.enable_acs)   return 12'h2c0;
        if (fn.enable_rebar) return 12'h300;
      end
      12'h260: begin
        if (fn.enable_pasid) return 12'h280;
        if (fn.enable_ari)   return 12'h2a0;
        if (fn.enable_acs)   return 12'h2c0;
        if (fn.enable_rebar) return 12'h300;
      end
      12'h280: begin
        if (fn.enable_ari)   return 12'h2a0;
        if (fn.enable_acs)   return 12'h2c0;
        if (fn.enable_rebar) return 12'h300;
      end
      12'h2a0: begin
        if (fn.enable_acs)   return 12'h2c0;
        if (fn.enable_rebar) return 12'h300;
      end
      12'h2c0: if (fn.enable_rebar) return 12'h300;
      default: return 0;
    endcase
    return 0;
  endfunction

  function automatic bit current_rebar_size_matches(
      pcie_svt_function_profile fn, int unsigned bar_number);
    longint unsigned expected_aperture;
    if (fn.rebar_current_size[bar_number] >= 44)
      return 0;
    expected_aperture = 64'd1 << (20 + fn.rebar_current_size[bar_number]);
    return fn.bars[bar_number].aperture == expected_aperture;
  endfunction

  function bit validate_bar_layout(pcie_svt_function_profile fn);
    int unsigned max_bars;
    longint unsigned first_end;
    longint unsigned second_end;
    max_bars = (fn.header_type[6:0] == 7'h00) ? 6 : 2;
    for (int unsigned i = max_bars; i < 6; i++) begin
      if (fn.bars[i].implemented) begin
        `uvm_error("CFG_BUILD", $sformatf(
          "%s.BAR%0d: header type exposes only %0d BAR DWORDs",
          fn.get_name(), i, max_bars))
        return 0;
      end
    end
    for (int unsigned i = 0; i < max_bars; i++) begin
      if (fn.bars[i].implemented) begin
        if (!fn.bars[i].is_64bit && (fn.bars[i].initial_base[63:32] != 0)) begin
          `uvm_error("CFG_BUILD", $sformatf(
            "%s.BAR%0d: 32-bit BAR base exceeds 32 bits", fn.get_name(), i))
          return 0;
        end
        first_end = fn.bars[i].initial_base + fn.bars[i].aperture - 1;
        if (first_end < fn.bars[i].initial_base) begin
          `uvm_error("CFG_BUILD", $sformatf(
            "%s.BAR%0d: BAR address range overflows", fn.get_name(), i))
          return 0;
        end
        if (fn.bars[i].initial_base != 0) begin
          for (int unsigned j = i + 1; j < max_bars; j++) begin
            if (fn.bars[j].implemented && (fn.bars[j].initial_base != 0)) begin
              second_end = fn.bars[j].initial_base + fn.bars[j].aperture - 1;
              if ((first_end >= fn.bars[j].initial_base) &&
                  (second_end >= fn.bars[i].initial_base)) begin
                `uvm_error("CFG_BUILD", $sformatf(
                  "%s.BAR%0d and BAR%0d address ranges overlap",
                  fn.get_name(), i, j))
                return 0;
              end
            end
          end
        end
      end
    end
    return 1;
  endfunction

  function bit validate_raw_overrides(pcie_svt_function_profile fn,
                                      ref bit [31:0] image[1024]);
    int unsigned byte_offset;
    int unsigned bar_number;
    bit [31:0] value;
    foreach (fn.raw_dw_override[index]) begin
      if (index > 1023) begin
        `uvm_error("CFG_BUILD", $sformatf(
          "raw DWORD override index 0x%0h exceeds the 4-KiB image", index))
        return 0;
      end
      byte_offset = index * 4;
      value = fn.raw_dw_override[index];
      if (byte_offset == 12'h034) begin
        `uvm_error("CFG_BUILD", "raw override of Capability Pointer is forbidden")
        return 0;
      end
      if ((byte_offset >= 12'h010) &&
          (byte_offset <= ((fn.header_type[6:0] == 7'h00) ? 12'h024 :
                                                              12'h014))) begin
        bar_number = (byte_offset - 12'h010) / 4;
        if (((bar_number == 0) || !fn.bars[bar_number-1].implemented ||
             !fn.bars[bar_number-1].is_64bit) &&
            (value[3:0] != image[index][3:0])) begin
          `uvm_error("CFG_BUILD", $sformatf(
            "raw override of BAR type bits at 0x%03h is forbidden", byte_offset))
          return 0;
        end
      end
      if (is_std_cap_header(byte_offset) &&
          (value[15:8] != image[index][15:8])) begin
        `uvm_error("CFG_BUILD", $sformatf(
          "raw override of standard capability next pointer at 0x%03h is forbidden",
          byte_offset))
        return 0;
      end
      if (is_ext_cap_header(byte_offset) &&
          (value[31:20] != image[index][31:20])) begin
        `uvm_error("CFG_BUILD", $sformatf(
          "raw override of extended capability next pointer at 0x%03h is forbidden",
          byte_offset))
        return 0;
      end
    end
    return 1;
  endfunction

  function void emit_bar(pcie_svt_function_profile fn,
                         int unsigned bar_number,
                         ref bit [31:0] image[1024]);
    bit [31:0] low_value;
    low_value = 0;
    if (fn.bars[bar_number].implemented) begin
      low_value = fn.bars[bar_number].initial_base[31:0] & 32'hffff_fff0;
      if (fn.bars[bar_number].is_64bit)
        low_value |= 32'h0000_0004;
      if (fn.bars[bar_number].prefetchable)
        low_value |= 32'h0000_0008;
    end
    put_dw(image, 12'h010 + (bar_number * 4), low_value);
    if (fn.bars[bar_number].implemented && fn.bars[bar_number].is_64bit)
      put_dw(image, 12'h010 + ((bar_number + 1) * 4),
             fn.bars[bar_number].initial_base[63:32]);
  endfunction

  function void emit_pcie_capability(pcie_svt_function_profile fn,
                                     int unsigned link_width,
                                     int unsigned max_gen,
                                     bit [7:0] next_standard,
                                     ref bit [31:0] image[1024]);
    bit [6:0] speed_vector;
    speed_vector = (7'b1 << max_gen) - 1;
    put_dw(image, 12'h040,
           {(fn.header_type[6:0] == 7'h01) ? 16'h0042 : 16'h0002,
            next_standard, 8'h10});
    put_dw(image, 12'h044, {29'h0, fn.max_payload_supported});
    put_dw(image, 12'h048,
           {17'h0, fn.max_read_request_size, 4'h0,
            fn.max_payload_size, 5'h0});
    put_dw(image, 12'h04c, {22'h0, link_width[5:0], max_gen[3:0]});
    put_dw(image, 12'h064, {28'h0, fn.completion_timeout_ranges});
    put_dw(image, 12'h068, 32'h0000_0000);
    put_dw(image, 12'h06c, {24'h0, speed_vector, 1'b0});
  endfunction

  function void emit_extended_capabilities(pcie_svt_function_profile fn,
                                            ref bit [31:0] image[1024]);
    int unsigned entries;
    int unsigned offset;
    if (fn.enable_aer)
      put_dw(image, 12'h100,
             ext_cap_header(16'h0001, 4'h2, next_ext_cap(fn, 12'h100)));
    if (fn.enable_sriov)
      put_dw(image, 12'h180,
             ext_cap_header(16'h0010, 4'h1, next_ext_cap(fn, 12'h180)));
    if (fn.enable_ats)
      put_dw(image, 12'h240,
             ext_cap_header(16'h000f, 4'h1, next_ext_cap(fn, 12'h240)));
    if (fn.enable_pri)
      put_dw(image, 12'h260,
             ext_cap_header(16'h0013, 4'h1, next_ext_cap(fn, 12'h260)));
    if (fn.enable_pasid)
      put_dw(image, 12'h280,
             ext_cap_header(16'h001b, 4'h1, next_ext_cap(fn, 12'h280)));
    if (fn.enable_ari)
      put_dw(image, 12'h2a0,
             ext_cap_header(16'h000e, 4'h1, next_ext_cap(fn, 12'h2a0)));
    if (fn.enable_acs)
      put_dw(image, 12'h2c0,
             ext_cap_header(16'h000d, 4'h1, next_ext_cap(fn, 12'h2c0)));
    if (fn.enable_rebar) begin
      put_dw(image, 12'h300,
             ext_cap_header(16'h0015, 4'h1, next_ext_cap(fn, 12'h300)));
      entries = 0;
      foreach (fn.rebar_supported_sizes[i])
        if (fn.rebar_supported_sizes[i] != 0)
          entries++;
      offset = 12'h304;
      foreach (fn.rebar_supported_sizes[i]) begin
        if (fn.rebar_supported_sizes[i] != 0) begin
          put_dw(image, offset,
                 {fn.rebar_supported_sizes[i][27:0], 1'b0, i[2:0]});
          put_dw(image, offset + 4,
                 {18'h0, fn.rebar_current_size[i],
                  entries[2:0], 2'b00, i[2:0]});
          offset += 8;
        end
      end
    end
  endfunction

  function bit build_function(pcie_svt_function_profile fn,
                              int unsigned link_width,
                              int unsigned max_gen,
                              ref bit [31:0] image[1024]);
    bit [7:0] next_standard;
    bit [31:0] rom_value;
    foreach (image[i])
      image[i] = 0;
    if (fn == null) begin
      `uvm_error("CFG_BUILD", "cannot build a null function profile")
      return 0;
    end
    if (!((link_width == 4) || (link_width == 8) || (link_width == 16))) begin
      `uvm_error("CFG_BUILD", "link_width must be x4, x8, or x16")
      return 0;
    end
    if (!((max_gen == 4) || (max_gen == 5))) begin
      `uvm_error("CFG_BUILD", "max_gen must be Gen4 or Gen5")
      return 0;
    end
    if (!fn.validate(fn.get_name()))
      return 0;
    if (!((fn.header_type[6:0] == 7'h00) ||
          (fn.header_type[6:0] == 7'h01))) begin
      `uvm_error("CFG_BUILD", $sformatf(
        "unsupported PCI header type 0x%02h", fn.header_type[6:0]))
      return 0;
    end
    if (!validate_bar_layout(fn))
      return 0;
    if (fn.enable_rebar) begin
      foreach (fn.rebar_supported_sizes[i]) begin
        if ((fn.rebar_supported_sizes[i] != 0) &&
            !current_rebar_size_matches(fn, i)) begin
          `uvm_error("CFG_BUILD", $sformatf(
            "%s.BAR%0d: REBAR current size does not match BAR aperture",
            fn.get_name(), i))
          return 0;
        end
      end
    end

    put_dw(image, 12'h000, {fn.device_id, fn.vendor_id});
    put_dw(image, 12'h004, {16'h0010, fn.command_reset});
    put_dw(image, 12'h008, {fn.class_code, fn.revision_id});
    put_dw(image, 12'h00c, {8'h00, fn.header_type, 16'h0000});

    if (fn.header_type[6:0] == 7'h00) begin
      for (int unsigned i = 0; i < 6; i++)
        if ((i == 0) || !fn.bars[i-1].implemented ||
            !fn.bars[i-1].is_64bit)
          emit_bar(fn, i, image);
      put_dw(image, 12'h02c, {fn.subsystem_device_id,
                              fn.subsystem_vendor_id});
      rom_value = 0;
      if (fn.expansion_rom.implemented)
        rom_value = fn.expansion_rom.initial_base[31:0] & 32'hffff_f800;
      put_dw(image, 12'h030, rom_value);
    end else begin
      emit_bar(fn, 0, image);
      if (!fn.bars[0].implemented || !fn.bars[0].is_64bit)
        emit_bar(fn, 1, image);
      put_dw(image, 12'h018, 32'h0000_0000);
      put_dw(image, 12'h01c, 32'h0000_0000);
      put_dw(image, 12'h020, 32'h0000_0000);
      put_dw(image, 12'h024, 32'h0000_0000);
      put_dw(image, 12'h028, 32'h0000_0000);
      put_dw(image, 12'h02c, 32'h0000_0000);
      put_dw(image, 12'h030, 32'h0000_0000);
      put_dw(image, 12'h038, 32'h0000_0000);
    end
    put_dw(image, 12'h034, 32'h0000_0040);
    put_dw(image, 12'h03c, {16'h0000, fn.interrupt_pin, 8'h00});

    if (fn.enable_msi)
      next_standard = 8'h80;
    else if (fn.enable_msix)
      next_standard = 8'ha0;
    else
      next_standard = 0;
    emit_pcie_capability(fn, link_width, max_gen, next_standard, image);
    if (fn.enable_msi)
      put_dw(image, 12'h080,
             {16'h0000, fn.enable_msix ? 8'ha0 : 8'h00, 8'h05});
    if (fn.enable_msix) begin
      put_dw(image, 12'h0a0, 32'h0000_0011);
      put_dw(image, 12'h0a4,
             {fn.msix_table_offset[28:3], 3'b000} | fn.msix_table_bar);
      put_dw(image, 12'h0a8,
             {fn.msix_pba_offset[28:3], 3'b000} | fn.msix_pba_bar);
    end
    emit_extended_capabilities(fn, image);

    if (!validate_raw_overrides(fn, image))
      return 0;
    foreach (fn.raw_dw_override[index])
      image[index] = fn.raw_dw_override[index];
    return 1;
  endfunction
endclass
