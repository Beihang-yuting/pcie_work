typedef enum int {PCIE_SVT_RC, PCIE_SVT_EP} pcie_svt_role_e;
typedef enum int {PCIE_SVT_TOPO_EP_X16, PCIE_SVT_TOPO_EP_2X8,
                  PCIE_SVT_TOPO_SWITCH} pcie_svt_topology_e;

localparam int unsigned PCIE_SVT_MAX_PORTS = 10;
localparam int unsigned PCIE_SVT_PRIMARY_PORT0 = 0;
localparam int unsigned PCIE_SVT_PRIMARY_PORT1 = 1;
localparam int unsigned PCIE_SVT_PRIMARY_PORT2 = 2;
localparam int unsigned PCIE_SVT_PRIMARY_PORT3 = 3;
localparam int unsigned PCIE_SVT_PRIMARY_PORT4 = 4;
localparam int unsigned PCIE_SVT_PRIMARY_RC0 = 0;
localparam int unsigned PCIE_SVT_PRIMARY_RC1 = 1;
localparam int unsigned PCIE_SVT_PRIMARY_EP0 = 1;
localparam int unsigned PCIE_SVT_PRIMARY_EP1 = 2;
localparam int unsigned PCIE_SVT_PRIMARY_EP2 = 3;
localparam int unsigned PCIE_SVT_PRIMARY_EP3 = 4;
localparam int unsigned PCIE_SVT_PEER_PORT0 = 5;
localparam int unsigned PCIE_SVT_PEER_PORT1 = 6;
localparam int unsigned PCIE_SVT_PEER_PORT2 = 7;
localparam int unsigned PCIE_SVT_PEER_PORT3 = 8;
localparam int unsigned PCIE_SVT_PEER_PORT4 = 9;

class pcie_svt_bar_profile extends uvm_object;
  bit implemented;
  bit is_64bit;
  bit prefetchable;
  longint unsigned aperture;
  longint unsigned initial_base;

  `uvm_object_utils(pcie_svt_bar_profile)

  function new(string name = "pcie_svt_bar_profile");
    super.new(name);
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_svt_bar_profile rhs_profile;
    super.do_copy(rhs);
    if (!$cast(rhs_profile, rhs)) begin
      `uvm_error("PROFILE_COPY", "pcie_svt_bar_profile copy source has the wrong type")
      return;
    end
    implemented = rhs_profile.implemented;
    is_64bit = rhs_profile.is_64bit;
    prefetchable = rhs_profile.prefetchable;
    aperture = rhs_profile.aperture;
    initial_base = rhs_profile.initial_base;
  endfunction

  function bit validate(string path);
    if (!implemented)
      return 1;
    if ((aperture < 16) || ((aperture & (aperture - 1)) != 0)) begin
      `uvm_error("PROFILE", {path, ": BAR aperture must be a power of two and at least 16 bytes"})
      return 0;
    end
    if ((initial_base & (aperture - 1)) != 0) begin
      `uvm_error("PROFILE", {path, ": BAR base is not aperture aligned"})
      return 0;
    end
    return 1;
  endfunction
endclass

class pcie_svt_function_profile extends uvm_object;
  bit [15:0] vendor_id;
  bit [15:0] device_id;
  bit [23:0] class_code;
  bit [7:0] revision_id;
  bit [7:0] header_type;
  bit [15:0] subsystem_vendor_id;
  bit [15:0] subsystem_device_id;
  bit [15:0] command_reset;
  bit [7:0] interrupt_pin;
  pcie_svt_bar_profile bars[6];
  pcie_svt_bar_profile expansion_rom;
  bit enable_msi;
  bit enable_msix;
  bit enable_aer;
  bit enable_sriov;
  bit enable_ats;
  bit enable_pri;
  bit enable_pasid;
  bit enable_ari;
  bit enable_acs;
  bit enable_rebar;
  bit [2:0] max_payload_supported;
  bit [2:0] max_payload_size;
  bit [2:0] max_read_request_size;
  bit [3:0] completion_timeout_ranges;
  bit [2:0] msix_table_bar;
  bit [2:0] msix_pba_bar;
  bit [28:0] msix_table_offset;
  bit [28:0] msix_pba_offset;
  bit [31:0] rebar_supported_sizes[6];
  bit [5:0] rebar_current_size[6];
  bit [31:0] raw_dw_override[int unsigned];

  `uvm_object_utils(pcie_svt_function_profile)

  function new(string name = "pcie_svt_function_profile");
    super.new(name);
    foreach (bars[i])
      bars[i] = pcie_svt_bar_profile::type_id::create(
        $sformatf("bar%0d", i));
    expansion_rom = pcie_svt_bar_profile::type_id::create("expansion_rom");
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_svt_function_profile rhs_profile;
    super.do_copy(rhs);
    if (!$cast(rhs_profile, rhs)) begin
      `uvm_error("PROFILE_COPY", "pcie_svt_function_profile copy source has the wrong type")
      return;
    end
    vendor_id = rhs_profile.vendor_id;
    device_id = rhs_profile.device_id;
    class_code = rhs_profile.class_code;
    revision_id = rhs_profile.revision_id;
    header_type = rhs_profile.header_type;
    subsystem_vendor_id = rhs_profile.subsystem_vendor_id;
    subsystem_device_id = rhs_profile.subsystem_device_id;
    command_reset = rhs_profile.command_reset;
    interrupt_pin = rhs_profile.interrupt_pin;
    foreach (bars[i]) begin
      if (rhs_profile.bars[i] == null) begin
        bars[i] = null;
      end else begin
        bars[i] = pcie_svt_bar_profile::type_id::create(
          $sformatf("bar%0d", i));
        bars[i].copy(rhs_profile.bars[i]);
      end
    end
    if (rhs_profile.expansion_rom == null) begin
      expansion_rom = null;
    end else begin
      expansion_rom = pcie_svt_bar_profile::type_id::create("expansion_rom");
      expansion_rom.copy(rhs_profile.expansion_rom);
    end
    enable_msi = rhs_profile.enable_msi;
    enable_msix = rhs_profile.enable_msix;
    enable_aer = rhs_profile.enable_aer;
    enable_sriov = rhs_profile.enable_sriov;
    enable_ats = rhs_profile.enable_ats;
    enable_pri = rhs_profile.enable_pri;
    enable_pasid = rhs_profile.enable_pasid;
    enable_ari = rhs_profile.enable_ari;
    enable_acs = rhs_profile.enable_acs;
    enable_rebar = rhs_profile.enable_rebar;
    max_payload_supported = rhs_profile.max_payload_supported;
    max_payload_size = rhs_profile.max_payload_size;
    max_read_request_size = rhs_profile.max_read_request_size;
    completion_timeout_ranges = rhs_profile.completion_timeout_ranges;
    msix_table_bar = rhs_profile.msix_table_bar;
    msix_pba_bar = rhs_profile.msix_pba_bar;
    msix_table_offset = rhs_profile.msix_table_offset;
    msix_pba_offset = rhs_profile.msix_pba_offset;
    foreach (rebar_supported_sizes[i]) begin
      rebar_supported_sizes[i] = rhs_profile.rebar_supported_sizes[i];
      rebar_current_size[i] = rhs_profile.rebar_current_size[i];
    end
    raw_dw_override.delete();
    foreach (rhs_profile.raw_dw_override[index])
      raw_dw_override[index] = rhs_profile.raw_dw_override[index];
  endfunction

  function bit msix_bir_is_valid(bit [2:0] bir, string path);
    if (bir >= 6) begin
      `uvm_error("PROFILE", {path, ": MSI-X BIR must select BAR0 through BAR5"})
      return 0;
    end
    if ((bir > 0) && (bars[bir-1] != null) &&
        bars[bir-1].implemented && bars[bir-1].is_64bit) begin
      `uvm_error("PROFILE", {path, ": MSI-X BIR selects the upper half of a 64-bit BAR"})
      return 0;
    end
    if (bars[bir] == null) begin
      `uvm_error("PROFILE", {path, ": MSI-X BIR selects a null BAR handle"})
      return 0;
    end
    if (!bars[bir].implemented) begin
      `uvm_error("PROFILE", {path, ": MSI-X BIR selects an unimplemented BAR"})
      return 0;
    end
    return 1;
  endfunction

  function bit validate(string path);
    bit ok;
    bit rebar_entry_found;
    ok = 1;
    if (enable_pri && !enable_ats) begin
      `uvm_error("PROFILE", {path, ": PRI requires ATS"})
      ok = 0;
    end
    if (enable_pasid && !enable_ats) begin
      `uvm_error("PROFILE", {path, ": PASID requires ATS"})
      ok = 0;
    end
    foreach (bars[i]) begin
      if (bars[i] == null) begin
        `uvm_error("PROFILE", $sformatf("%s.BAR%0d: null BAR handle", path, i))
        ok = 0;
      end else if (!bars[i].validate($sformatf("%s.BAR%0d", path, i)))
        ok = 0;
    end
    foreach (bars[i]) begin
      if ((bars[i] != null) && bars[i].implemented && bars[i].is_64bit) begin
        if (i == 5) begin
          `uvm_error("PROFILE", $sformatf(
            "%s.BAR5: 64-bit BAR requires an upper DWORD", path))
          ok = 0;
        end else if ((bars[i+1] != null) && bars[i+1].implemented) begin
          `uvm_error("PROFILE", $sformatf(
            "%s.BAR%0d: upper DWORD of BAR%0d must be unimplemented",
            path, i+1, i))
          ok = 0;
        end
      end
    end
    if (expansion_rom == null) begin
      `uvm_error("PROFILE", {path, ".expansion_rom: null BAR handle"})
      ok = 0;
    end else if (!expansion_rom.validate({path, ".expansion_rom"}))
      ok = 0;

    if (enable_msix) begin
      if (!msix_bir_is_valid(msix_table_bar, {path, ".msix_table"}))
        ok = 0;
      if (!msix_bir_is_valid(msix_pba_bar, {path, ".msix_pba"}))
        ok = 0;
      if ((msix_table_offset & 29'h7) != 0) begin
        `uvm_error("PROFILE", {path, ": MSI-X table offset must be 8-byte aligned"})
        ok = 0;
      end
      if ((msix_pba_offset & 29'h7) != 0) begin
        `uvm_error("PROFILE", {path, ": MSI-X PBA offset must be 8-byte aligned"})
        ok = 0;
      end
    end

    if (enable_rebar) begin
      rebar_entry_found = 0;
      foreach (rebar_supported_sizes[i]) begin
        if (rebar_supported_sizes[i] != 0) begin
          rebar_entry_found = 1;
          if ((bars[i] == null) || !bars[i].implemented) begin
            `uvm_error("PROFILE", $sformatf(
              "%s.BAR%0d: REBAR entry requires an implemented BAR", path, i))
            ok = 0;
          end
          if (rebar_current_size[i] >= 32) begin
            `uvm_error("PROFILE", $sformatf(
              "%s.BAR%0d: REBAR current-size encoding is out of range", path, i))
            ok = 0;
          end else if (!rebar_supported_sizes[i][rebar_current_size[i]]) begin
            `uvm_error("PROFILE", $sformatf(
              "%s.BAR%0d: REBAR current size is not supported", path, i))
            ok = 0;
          end
        end
      end
      if (!rebar_entry_found) begin
        `uvm_error("PROFILE", {path, ": REBAR requires at least one configured entry"})
        ok = 0;
      end
    end
    return ok;
  endfunction
endclass

class pcie_svt_port_profile extends uvm_object;
  string port_id;
  pcie_svt_role_e role;
  int unsigned link_width;
  int unsigned max_gen;
  int unsigned root_hierarchy;
  pcie_svt_function_profile functions[$];

  `uvm_object_utils(pcie_svt_port_profile)

  function new(string name = "pcie_svt_port_profile");
    super.new(name);
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_svt_port_profile rhs_profile;
    pcie_svt_function_profile copied_function;
    super.do_copy(rhs);
    if (!$cast(rhs_profile, rhs)) begin
      `uvm_error("PROFILE_COPY", "pcie_svt_port_profile copy source has the wrong type")
      return;
    end
    port_id = rhs_profile.port_id;
    role = rhs_profile.role;
    link_width = rhs_profile.link_width;
    max_gen = rhs_profile.max_gen;
    root_hierarchy = rhs_profile.root_hierarchy;
    functions.delete();
    foreach (rhs_profile.functions[i]) begin
      if (rhs_profile.functions[i] == null) begin
        functions.push_back(null);
      end else begin
        copied_function = pcie_svt_function_profile::type_id::create(
          $sformatf("function%0d", i));
        copied_function.copy(rhs_profile.functions[i]);
        functions.push_back(copied_function);
      end
    end
  endfunction

  function bit validate();
    bit ok;
    ok = 1;
    if (port_id.len() == 0) begin
      `uvm_error("PROFILE", "port_id must not be empty")
      ok = 0;
    end
    if (!((link_width == 4) || (link_width == 8) || (link_width == 16))) begin
      `uvm_error("PROFILE", {port_id, ": link width must be x4, x8, or x16"})
      ok = 0;
    end
    if (!((max_gen == 4) || (max_gen == 5))) begin
      `uvm_error("PROFILE", {port_id, ": max_gen must be Gen4 or Gen5"})
      ok = 0;
    end
    if ((functions.size() == 0) || (functions[0] == null)) begin
      `uvm_error("PROFILE", {port_id, ": PF0 must be present"})
      ok = 0;
    end
    foreach (functions[i]) begin
      if (functions[i] == null) begin
        `uvm_error("PROFILE", $sformatf("%s.PF%0d: null function handle", port_id, i))
        ok = 0;
      end else if (!functions[i].validate(
                     $sformatf("%s.PF%0d", port_id, i)))
        ok = 0;
    end
    return ok;
  endfunction
endclass
