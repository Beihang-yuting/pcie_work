class pcie_svt_switch_enum_bridge_record;
  bit is_usp;
  int unsigned index;
  int unsigned port_info_index;
  bit [15:0] bdf;
  bit [7:0] primary_bus;
  bit [7:0] secondary_bus;
  bit [7:0] subordinate_bus;
  bit [63:0] prefetch_base;
  bit [63:0] prefetch_limit;

  bit readback_valid;
  bit [31:0] bus_numbers_readback;
  bit [31:0] prefetch_base_limit_readback;
  bit [31:0] prefetch_base_upper_readback;
  bit [31:0] prefetch_limit_upper_readback;
endclass

class pcie_svt_switch_enum_endpoint_record;
  int unsigned index;
  int unsigned dsp_index;
  bit [15:0] bdf;
  bit [15:0] parent_dsp_bdf;
endclass

class pcie_svt_switch_enum_bar_record;
  int unsigned index;
  int unsigned ep_index;
  int unsigned dsp_index;
  int unsigned pair_index;
  int unsigned low_bar;
  int unsigned high_bar;
  bit [15:0] ep_bdf;
  bit [15:0] parent_dsp_bdf;
  bit [63:0] base_address;
  bit [63:0] limit_address;
  bit [63:0] aperture;

  bit readback_valid;
  bit [31:0] low_dword_readback;
  bit [31:0] high_dword_readback;
endclass

class pcie_svt_switch_enum_registry extends uvm_object;
  `uvm_object_utils(pcie_svt_switch_enum_registry)

  svt_pcie_switch_enumeration_seq_status source_status;
  pcie_svt_switch_enum_bridge_record usp;
  pcie_svt_switch_enum_bridge_record dsps[$];
  pcie_svt_switch_enum_endpoint_record endpoints[$];
  pcie_svt_switch_enum_bar_record bar_apertures[$];
  bit status_loaded;
  bit validated;

  function new(string name = "pcie_svt_switch_enum_registry");
    super.new(name);
  endfunction

  protected function void clear_records();
    source_status = null;
    usp = null;
    dsps.delete();
    endpoints.delete();
    bar_apertures.delete();
    status_loaded = 1'b0;
    validated = 1'b0;
  endfunction

  protected function automatic bit [15:0] make_bdf(
      int bus_number, int device_number);
    return {bus_number[7:0], device_number[4:0], 3'h0};
  endfunction

  protected function automatic bit valid_bridge_numbers(
      svt_pcie_switch_port_info info);
    if ((info.pri_bus_num < 0) || (info.pri_bus_num > 255) ||
        (info.sec_bus_num < 0) || (info.sec_bus_num > 255) ||
        (info.sub_bus_num < 0) || (info.sub_bus_num > 255) ||
        (info.dev_num < 0) || (info.dev_num > 31)) begin
      `uvm_fatal("SWITCH_ENUM_BRIDGE_NUMBER", $sformatf(
        "switch port has invalid bus/device numbers pri=%0d sec=%0d sub=%0d dev=%0d",
        info.pri_bus_num, info.sec_bus_num, info.sub_bus_num,
        info.dev_num))
      return 1'b0;
    end
    if ((info.pref_mem_start_addr < 0) ||
        (info.pref_mem_end_addr < info.pref_mem_start_addr)) begin
      `uvm_fatal("SWITCH_ENUM_BRIDGE_WINDOW", $sformatf(
        "switch port %02x:%02x.0 has invalid prefetch window [0x%016h:0x%016h]",
        info.pri_bus_num, info.dev_num, info.pref_mem_start_addr,
        info.pref_mem_end_addr))
      return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function pcie_svt_switch_enum_bridge_record make_bridge(
      svt_pcie_switch_port_info info,
      int unsigned port_info_index,
      bit is_usp,
      int unsigned index);
    pcie_svt_switch_enum_bridge_record record;
    if (!valid_bridge_numbers(info))
      return null;
    record = new();
    record.is_usp = is_usp;
    record.index = index;
    record.port_info_index = port_info_index;
    record.bdf = make_bdf(info.pri_bus_num, info.dev_num);
    record.primary_bus = info.pri_bus_num[7:0];
    record.secondary_bus = info.sec_bus_num[7:0];
    record.subordinate_bus = info.sub_bus_num[7:0];
    record.prefetch_base = info.pref_mem_start_addr;
    record.prefetch_limit = info.pref_mem_end_addr;
    return record;
  endfunction

  protected function automatic bit [63:0] expected_aperture(
      int unsigned pair_index);
    case (pair_index)
      0: return 64'd33554432;
      1, 2: return 64'd65536;
      default: return 0;
    endcase
  endfunction

  protected function void add_endpoint(
      svt_pcie_switch_port_info dsp_info,
      pcie_svt_switch_enum_bridge_record parent);
    svt_pcie_ep_enumeration_seq_status ep_status;
    pcie_svt_switch_enum_endpoint_record endpoint;
    pcie_svt_switch_enum_bar_record bar_record;
    bit [63:0] expected_size;
    bit [63:0] actual_size;

    ep_status = dsp_info.ep_enumeration_status;
    if (ep_status == null) begin
      `uvm_fatal("SWITCH_ENUM_EP_PARENT", $sformatf(
        "DSP %02x:%02x.0 has no Endpoint enumeration status",
        parent.primary_bus, parent.bdf[7:3]))
      return;
    end
    if (!ep_status.is_ep_device_beneath_switch_dsp) begin
      `uvm_fatal("SWITCH_ENUM_EP_PARENT", $sformatf(
        "Endpoint %02x:%02x.0 is not reported beneath parent DSP %04x",
        ep_status.captured_bus_number, ep_status.captured_device_number,
        parent.bdf))
      return;
    end
    if (ep_status.captured_bus_number != parent.secondary_bus) begin
      `uvm_fatal("SWITCH_ENUM_EP_PARENT", $sformatf(
        "Endpoint %02x:%02x.0 bus does not match parent DSP %04x secondary bus %02x",
        ep_status.captured_bus_number, ep_status.captured_device_number,
        parent.bdf, parent.secondary_bus))
      return;
    end

    endpoint = new();
    endpoint.index = endpoints.size();
    endpoint.dsp_index = parent.index;
    endpoint.bdf = {ep_status.captured_bus_number,
                    ep_status.captured_device_number, 3'h0};
    endpoint.parent_dsp_bdf = parent.bdf;
    endpoints.push_back(endpoint);

    for (int unsigned pair = 0; pair < 3; pair++) begin
      int unsigned low_bar;
      low_bar = pair * 2;
      if (ep_status.non_virtual_bar_present[0][low_bar] != 2'b10) begin
        `uvm_fatal("SWITCH_ENUM_BAR_TYPE", $sformatf(
          "Endpoint %04x BAR%0d/%0d must be a 64-bit Memory BAR; type=%02b",
          endpoint.bdf, low_bar, low_bar+1,
          ep_status.non_virtual_bar_present[0][low_bar]))
        return;
      end
      expected_size = expected_aperture(pair);
      if (ep_status.max_per_bar_address_range[0][low_bar] <
          ep_status.min_per_bar_address_range[0][low_bar]) begin
        `uvm_fatal("SWITCH_ENUM_BAR_SIZE", $sformatf(
          "Endpoint %04x BAR%0d/%0d has reversed range [0x%016h:0x%016h]",
          endpoint.bdf, low_bar, low_bar+1,
          ep_status.min_per_bar_address_range[0][low_bar],
          ep_status.max_per_bar_address_range[0][low_bar]))
        return;
      end
      actual_size = ep_status.max_per_bar_address_range[0][low_bar] -
                    ep_status.min_per_bar_address_range[0][low_bar] + 1;
      if (actual_size != expected_size) begin
        `uvm_fatal("SWITCH_ENUM_BAR_SIZE", $sformatf(
          "Endpoint %04x BAR%0d/%0d aperture must be 0x%0h; got 0x%0h",
          endpoint.bdf, low_bar, low_bar+1, expected_size,
          actual_size))
        return;
      end
      bar_record = new();
      bar_record.index = bar_apertures.size();
      bar_record.ep_index = endpoint.index;
      bar_record.dsp_index = endpoint.dsp_index;
      bar_record.pair_index = pair;
      bar_record.low_bar = low_bar;
      bar_record.high_bar = low_bar + 1;
      bar_record.ep_bdf = endpoint.bdf;
      bar_record.parent_dsp_bdf = endpoint.parent_dsp_bdf;
      bar_record.base_address =
        ep_status.min_per_bar_address_range[0][low_bar];
      bar_record.limit_address =
        ep_status.max_per_bar_address_range[0][low_bar];
      bar_record.aperture = actual_size;
      bar_apertures.push_back(bar_record);
    end
  endfunction

  protected function void check_counts();
    if ((usp_count() != 1) || (dsp_count() != 4)) begin
      `uvm_fatal("SWITCH_ENUM_PORT_COUNTS", $sformatf(
        "official enumeration must contain exactly one USP and four DSPs; got usp=%0d dsp=%0d",
        usp_count(), dsp_count()))
      return;
    end
    if (ep_count() != 4) begin
      `uvm_fatal("SWITCH_ENUM_EP_COUNT", $sformatf(
        "official enumeration must contain exactly four Endpoints; got ep=%0d",
        ep_count()))
      return;
    end
    if (bar_count() != 12) begin
      `uvm_fatal("SWITCH_ENUM_BAR_COUNT", $sformatf(
        "official enumeration must contain exactly 12 BAR-pair apertures; got bars=%0d",
        bar_count()))
      return;
    end
  endfunction

  protected function void check_topology();
    if (!((usp.primary_bus < usp.secondary_bus) &&
          (usp.secondary_bus <= usp.subordinate_bus))) begin
      `uvm_fatal("SWITCH_ENUM_BUS_ORDER", $sformatf(
        "USP %04x buses=%02x/%02x/%02x violate primary < secondary <= subordinate",
        usp.bdf, usp.primary_bus, usp.secondary_bus, usp.subordinate_bus))
      return;
    end
    foreach (dsps[i]) begin
      if (!((dsps[i].primary_bus < dsps[i].secondary_bus) &&
            (dsps[i].secondary_bus <= dsps[i].subordinate_bus))) begin
        `uvm_fatal("SWITCH_ENUM_BUS_ORDER", $sformatf(
          "DSP %04x buses=%02x/%02x/%02x violate primary < secondary <= subordinate",
          dsps[i].bdf, dsps[i].primary_bus, dsps[i].secondary_bus,
          dsps[i].subordinate_bus))
        return;
      end
      if ((dsps[i].primary_bus != usp.secondary_bus) ||
          (dsps[i].secondary_bus <= usp.secondary_bus) ||
          (dsps[i].subordinate_bus > usp.subordinate_bus)) begin
        `uvm_fatal("SWITCH_ENUM_BUS_PARENT", $sformatf(
          "DSP %04x buses=%02x/%02x/%02x are outside parent USP %04x buses=%02x/%02x/%02x",
          dsps[i].bdf, dsps[i].primary_bus, dsps[i].secondary_bus,
          dsps[i].subordinate_bus, usp.bdf, usp.primary_bus,
          usp.secondary_bus, usp.subordinate_bus))
        return;
      end
    end
    foreach (dsps[i]) begin
      for (int unsigned j = i + 1; j < dsps.size(); j++) begin
        if ((dsps[i].secondary_bus <= dsps[j].subordinate_bus) &&
            (dsps[j].secondary_bus <= dsps[i].subordinate_bus)) begin
          `uvm_fatal("SWITCH_ENUM_BUS_OVERLAP", $sformatf(
            "DSP %04x bus range [%02x:%02x] overlaps DSP %04x bus range [%02x:%02x]",
            dsps[i].bdf, dsps[i].secondary_bus, dsps[i].subordinate_bus,
            dsps[j].bdf, dsps[j].secondary_bus,
            dsps[j].subordinate_bus))
          return;
        end
      end
    end
    foreach (dsps[i]) begin
      if ((dsps[i].prefetch_base < usp.prefetch_base) ||
          (dsps[i].prefetch_limit > usp.prefetch_limit)) begin
        `uvm_fatal("SWITCH_ENUM_WINDOW_PARENT", $sformatf(
          "DSP %04x prefetch window [0x%016h:0x%016h] is outside USP %04x window [0x%016h:0x%016h]",
          dsps[i].bdf, dsps[i].prefetch_base, dsps[i].prefetch_limit,
          usp.bdf, usp.prefetch_base, usp.prefetch_limit))
        return;
      end
    end
    foreach (dsps[i]) begin
      for (int unsigned j = i + 1; j < dsps.size(); j++) begin
        if ((dsps[i].prefetch_base <= dsps[j].prefetch_limit) &&
            (dsps[j].prefetch_base <= dsps[i].prefetch_limit)) begin
          `uvm_fatal("SWITCH_ENUM_WINDOW_OVERLAP", $sformatf(
            "DSP %04x prefetch window [0x%016h:0x%016h] overlaps DSP %04x window [0x%016h:0x%016h]",
            dsps[i].bdf, dsps[i].prefetch_base,
            dsps[i].prefetch_limit, dsps[j].bdf,
            dsps[j].prefetch_base, dsps[j].prefetch_limit))
          return;
        end
      end
    end
  endfunction

  protected function void check_unique_bdfs();
    bit [15:0] bdfs[$];
    bdfs.push_back(usp.bdf);
    foreach (dsps[i])
      bdfs.push_back(dsps[i].bdf);
    foreach (endpoints[i])
      bdfs.push_back(endpoints[i].bdf);
    foreach (bdfs[i]) begin
      for (int unsigned j = i + 1; j < bdfs.size(); j++) begin
        if (bdfs[i] == bdfs[j]) begin
          `uvm_fatal("SWITCH_ENUM_BDF_DUPLICATE", $sformatf(
            "enumerated BDF %04x appears more than once", bdfs[i]))
          return;
        end
      end
    end
  endfunction

  protected function void check_bar_layout();
    foreach (bar_apertures[i]) begin
      for (int unsigned j = i + 1; j < bar_apertures.size(); j++) begin
        if ((bar_apertures[i].base_address <=
             bar_apertures[j].limit_address) &&
            (bar_apertures[j].base_address <=
             bar_apertures[i].limit_address)) begin
          `uvm_fatal("SWITCH_ENUM_BAR_OVERLAP", $sformatf(
            "Endpoint %04x BAR%0d/%0d [0x%016h:0x%016h] overlaps Endpoint %04x BAR%0d/%0d [0x%016h:0x%016h]",
            bar_apertures[i].ep_bdf, bar_apertures[i].low_bar,
            bar_apertures[i].high_bar, bar_apertures[i].base_address,
            bar_apertures[i].limit_address, bar_apertures[j].ep_bdf,
            bar_apertures[j].low_bar, bar_apertures[j].high_bar,
            bar_apertures[j].base_address,
            bar_apertures[j].limit_address))
          return;
        end
      end
    end
    foreach (bar_apertures[i]) begin
      pcie_svt_switch_enum_bridge_record parent;
      parent = dsps[bar_apertures[i].dsp_index];
      if ((bar_apertures[i].base_address < parent.prefetch_base) ||
          (bar_apertures[i].limit_address > parent.prefetch_limit)) begin
        `uvm_fatal("SWITCH_ENUM_BAR_WINDOW", $sformatf(
          "Endpoint %04x BAR%0d/%0d [0x%016h:0x%016h] is outside parent DSP %04x prefetch window [0x%016h:0x%016h]",
          bar_apertures[i].ep_bdf, bar_apertures[i].low_bar,
          bar_apertures[i].high_bar, bar_apertures[i].base_address,
          bar_apertures[i].limit_address, parent.bdf,
          parent.prefetch_base, parent.prefetch_limit))
        return;
      end
    end
  endfunction

  function void load_from_status(
      svt_pcie_switch_enumeration_seq_status status);
    pcie_svt_switch_enum_bridge_record bridge;
    svt_pcie_switch_port_info info;
    clear_records();
    if (status == null) begin
      `uvm_fatal("SWITCH_ENUM_STATUS_NULL",
        "official switch enumeration status is null")
      return;
    end
    source_status = status;
    foreach (status.port_info[i]) begin
      info = status.port_info[i];
      if (info == null) begin
        `uvm_fatal("SWITCH_ENUM_PORT_NULL", $sformatf(
          "official enumeration port_info[%0d] is null", i))
        return;
      end
      case (info.port_type)
        svt_pcie_types::SW_USP: begin
          bridge = make_bridge(info, i, 1'b1, 0);
          if (bridge == null)
            return;
          if (usp != null) begin
            `uvm_fatal("SWITCH_ENUM_PORT_COUNTS",
              "official enumeration contains more than one USP")
            return;
          end
          usp = bridge;
        end
        svt_pcie_types::SW_DSP: begin
          bridge = make_bridge(info, i, 1'b0, dsps.size());
          if (bridge == null)
            return;
          dsps.push_back(bridge);
          add_endpoint(info, bridge);
        end
        default: begin
          `uvm_fatal("SWITCH_ENUM_PORT_TYPE", $sformatf(
            "official enumeration port_info[%0d] has invalid port_type=%0d",
            i, info.port_type))
          return;
        end
      endcase
    end
    status_loaded = 1'b1;
    check_counts();
    check_topology();
    check_unique_bdfs();
    check_bar_layout();
  endfunction

  function void record_bridge_readback(
      bit is_usp,
      int unsigned index,
      bit [31:0] bus_numbers,
      bit [31:0] pref_base_limit,
      bit [31:0] pref_base_upper,
      bit [31:0] pref_limit_upper);
    pcie_svt_switch_enum_bridge_record record;
    if (!status_loaded) begin
      `uvm_fatal("SWITCH_ENUM_READBACK_ORDER",
        "bridge readback was recorded before official status was loaded")
      return;
    end
    if (is_usp) begin
      if ((index != 0) || (usp == null)) begin
        `uvm_fatal("SWITCH_ENUM_READBACK_INDEX",
          "USP readback index must be zero for a loaded USP")
        return;
      end
      record = usp;
    end else begin
      if (index >= dsps.size()) begin
        `uvm_fatal("SWITCH_ENUM_READBACK_INDEX", $sformatf(
          "DSP readback index %0d is outside [0:%0d]", index,
          dsps.size()-1))
        return;
      end
      record = dsps[index];
    end
    if (record.readback_valid) begin
      `uvm_fatal("SWITCH_ENUM_READBACK_DUPLICATE", $sformatf(
        "bridge %04x readback was recorded more than once", record.bdf))
      return;
    end
    record.bus_numbers_readback = bus_numbers;
    record.prefetch_base_limit_readback = pref_base_limit;
    record.prefetch_base_upper_readback = pref_base_upper;
    record.prefetch_limit_upper_readback = pref_limit_upper;
    record.readback_valid = 1'b1;
  endfunction

  function void record_bar_readback(
      int unsigned ep_index,
      int unsigned pair_index,
      bit [31:0] low_dword,
      bit [31:0] high_dword);
    int selected;
    selected = -1;
    if (!status_loaded) begin
      `uvm_fatal("SWITCH_ENUM_READBACK_ORDER",
        "BAR readback was recorded before official status was loaded")
      return;
    end
    foreach (bar_apertures[i]) begin
      if ((bar_apertures[i].ep_index == ep_index) &&
          (bar_apertures[i].pair_index == pair_index)) begin
        selected = i;
        break;
      end
    end
    if (selected < 0) begin
      `uvm_fatal("SWITCH_ENUM_READBACK_INDEX", $sformatf(
        "Endpoint/BAR-pair readback index %0d/%0d is not enumerated",
        ep_index, pair_index))
      return;
    end
    if (bar_apertures[selected].readback_valid) begin
      `uvm_fatal("SWITCH_ENUM_READBACK_DUPLICATE", $sformatf(
        "Endpoint %04x BAR%0d/%0d readback was recorded more than once",
        bar_apertures[selected].ep_bdf,
        bar_apertures[selected].low_bar,
        bar_apertures[selected].high_bar))
      return;
    end
    bar_apertures[selected].low_dword_readback = low_dword;
    bar_apertures[selected].high_dword_readback = high_dword;
    bar_apertures[selected].readback_valid = 1'b1;
  endfunction

  protected function void validate_bridge_readback(
      pcie_svt_switch_enum_bridge_record record);
    bit [63:0] observed_base;
    bit [63:0] observed_limit;
    if (!record.readback_valid) begin
      `uvm_fatal("SWITCH_ENUM_READBACK_MISSING", $sformatf(
        "bridge %04x has no normal Configuration Read readback",
        record.bdf))
      return;
    end
    if (record.bus_numbers_readback[23:0] !==
        {record.subordinate_bus, record.secondary_bus,
         record.primary_bus}) begin
      `uvm_fatal("SWITCH_ENUM_TYPE1_READBACK", $sformatf(
        "bridge %04x bus-number readback=%06x expected=%02x%02x%02x",
        record.bdf, record.bus_numbers_readback[23:0],
        record.subordinate_bus, record.secondary_bus,
        record.primary_bus))
      return;
    end
    if ((record.prefetch_base_limit_readback[3:0] !== 4'h1) ||
        (record.prefetch_base_limit_readback[19:16] !== 4'h1)) begin
      `uvm_fatal("SWITCH_ENUM_TYPE1_READBACK", $sformatf(
        "bridge %04x must report a 64-bit prefetch window; base_type=%x limit_type=%x",
        record.bdf, record.prefetch_base_limit_readback[3:0],
        record.prefetch_base_limit_readback[19:16]))
      return;
    end
    observed_base = {record.prefetch_base_upper_readback,
                     record.prefetch_base_limit_readback[15:4], 20'h00000};
    observed_limit = {record.prefetch_limit_upper_readback,
                      record.prefetch_base_limit_readback[31:20],
                      20'hfffff};
    if ((observed_base != record.prefetch_base) ||
        (observed_limit != record.prefetch_limit)) begin
      `uvm_fatal("SWITCH_ENUM_TYPE1_READBACK", $sformatf(
        "bridge %04x prefetch readback [0x%016h:0x%016h] disagrees with official status [0x%016h:0x%016h]",
        record.bdf, observed_base, observed_limit,
        record.prefetch_base, record.prefetch_limit))
      return;
    end
  endfunction

  protected function void validate_bar_readback(
      pcie_svt_switch_enum_bar_record record);
    bit [63:0] observed_base;
    if (!record.readback_valid) begin
      `uvm_fatal("SWITCH_ENUM_READBACK_MISSING", $sformatf(
        "Endpoint %04x BAR%0d/%0d has no normal Configuration Read readback",
        record.ep_bdf, record.low_bar, record.high_bar))
      return;
    end
    if ((record.low_dword_readback[0] !== 1'b0) ||
        (record.low_dword_readback[2:1] !== 2'b10)) begin
      `uvm_fatal("SWITCH_ENUM_BAR_TYPE", $sformatf(
        "Endpoint %04x BAR%0d/%0d readback is not a 64-bit Memory BAR; low=0x%08x",
        record.ep_bdf, record.low_bar, record.high_bar,
        record.low_dword_readback))
      return;
    end
    if (record.low_dword_readback[3] !== 1'b1) begin
      `uvm_fatal("SWITCH_ENUM_BAR_PREFETCH", $sformatf(
        "Endpoint %04x BAR%0d/%0d is not Prefetchable; low=0x%08x",
        record.ep_bdf, record.low_bar, record.high_bar,
        record.low_dword_readback))
      return;
    end
    observed_base = {record.high_dword_readback,
                     record.low_dword_readback[31:4], 4'h0};
    if (observed_base != record.base_address) begin
      `uvm_fatal("SWITCH_ENUM_BAR_READBACK", $sformatf(
        "Endpoint %04x BAR%0d/%0d readback base=0x%016h expected=0x%016h",
        record.ep_bdf, record.low_bar, record.high_bar,
        observed_base, record.base_address))
      return;
    end
  endfunction

  function void finalize_and_validate();
    if (!status_loaded) begin
      `uvm_fatal("SWITCH_ENUM_STATUS_NULL",
        "cannot finalize an unloaded switch enumeration registry")
      return;
    end
    validate_bridge_readback(usp);
    foreach (dsps[i])
      validate_bridge_readback(dsps[i]);
    foreach (bar_apertures[i])
      validate_bar_readback(bar_apertures[i]);
    validated = 1'b1;
  endfunction

  protected function bit queries_ready(string query_name);
    if (!validated) begin
      `uvm_fatal("SWITCH_ENUM_QUERY_ORDER", $sformatf(
        "%s requires a finalized switch enumeration registry", query_name))
      return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function pcie_svt_switch_enum_bar_record find_bar(
      int unsigned ep_index,
      int unsigned pair_index,
      string query_name);
    if (!queries_ready(query_name))
      return null;
    foreach (bar_apertures[i])
      if ((bar_apertures[i].ep_index == ep_index) &&
          (bar_apertures[i].pair_index == pair_index))
        return bar_apertures[i];
    `uvm_fatal("SWITCH_ENUM_QUERY_INDEX", $sformatf(
      "%s Endpoint/BAR-pair index %0d/%0d is not enumerated",
      query_name, ep_index, pair_index))
    return null;
  endfunction

  function int unsigned usp_count();
    return (usp == null) ? 0 : 1;
  endfunction

  function int unsigned dsp_count();
    return dsps.size();
  endfunction

  function int unsigned ep_count();
    return endpoints.size();
  endfunction

  function int unsigned bar_count();
    return bar_apertures.size();
  endfunction

  function bit [15:0] get_dsp_bdf(int unsigned dsp_index);
    if (!queries_ready("get_dsp_bdf"))
      return '0;
    if (dsp_index >= dsps.size()) begin
      `uvm_fatal("SWITCH_ENUM_QUERY_INDEX", $sformatf(
        "get_dsp_bdf index %0d is outside [0:%0d]", dsp_index,
        dsps.size()-1))
      return '0;
    end
    return dsps[dsp_index].bdf;
  endfunction

  function int unsigned get_dsp_port_info_index(int unsigned dsp_index);
    if (!queries_ready("get_dsp_port_info_index"))
      return 0;
    if (dsp_index >= dsps.size()) begin
      `uvm_fatal("SWITCH_ENUM_QUERY_INDEX", $sformatf(
        "get_dsp_port_info_index index %0d is outside [0:%0d]",
        dsp_index, dsps.size()-1))
      return 0;
    end
    return dsps[dsp_index].port_info_index;
  endfunction

  function bit [15:0] get_ep_bdf(int unsigned ep_index);
    if (!queries_ready("get_ep_bdf"))
      return '0;
    if (ep_index >= endpoints.size()) begin
      `uvm_fatal("SWITCH_ENUM_QUERY_INDEX", $sformatf(
        "get_ep_bdf index %0d is outside [0:%0d]", ep_index,
        endpoints.size()-1))
      return '0;
    end
    return endpoints[ep_index].bdf;
  endfunction

  function int unsigned get_ep_parent_dsp_index(int unsigned ep_index);
    if (!queries_ready("get_ep_parent_dsp_index"))
      return 0;
    if (ep_index >= endpoints.size()) begin
      `uvm_fatal("SWITCH_ENUM_QUERY_INDEX", $sformatf(
        "get_ep_parent_dsp_index index %0d is outside [0:%0d]",
        ep_index, endpoints.size()-1))
      return 0;
    end
    return endpoints[ep_index].dsp_index;
  endfunction

  function bit [15:0] get_ep_parent_dsp_bdf(int unsigned ep_index);
    if (!queries_ready("get_ep_parent_dsp_bdf"))
      return '0;
    if (ep_index >= endpoints.size()) begin
      `uvm_fatal("SWITCH_ENUM_QUERY_INDEX", $sformatf(
        "get_ep_parent_dsp_bdf index %0d is outside [0:%0d]",
        ep_index, endpoints.size()-1))
      return '0;
    end
    return endpoints[ep_index].parent_dsp_bdf;
  endfunction

  function bit [63:0] get_dsp_prefetch_base(int unsigned dsp_index);
    if (!queries_ready("get_dsp_prefetch_base"))
      return '0;
    if (dsp_index >= dsps.size()) begin
      `uvm_fatal("SWITCH_ENUM_QUERY_INDEX", $sformatf(
        "get_dsp_prefetch_base index %0d is outside [0:%0d]",
        dsp_index, dsps.size()-1))
      return '0;
    end
    return dsps[dsp_index].prefetch_base;
  endfunction

  function bit [63:0] get_dsp_prefetch_limit(int unsigned dsp_index);
    if (!queries_ready("get_dsp_prefetch_limit"))
      return '0;
    if (dsp_index >= dsps.size()) begin
      `uvm_fatal("SWITCH_ENUM_QUERY_INDEX", $sformatf(
        "get_dsp_prefetch_limit index %0d is outside [0:%0d]",
        dsp_index, dsps.size()-1))
      return '0;
    end
    return dsps[dsp_index].prefetch_limit;
  endfunction

  function bit [63:0] get_bar_base(
      int unsigned ep_index, int unsigned pair_index);
    pcie_svt_switch_enum_bar_record record;
    record = find_bar(ep_index, pair_index, "get_bar_base");
    return (record == null) ? '0 : record.base_address;
  endfunction

  function bit [63:0] get_bar_limit(
      int unsigned ep_index, int unsigned pair_index);
    pcie_svt_switch_enum_bar_record record;
    record = find_bar(ep_index, pair_index, "get_bar_limit");
    return (record == null) ? '0 : record.limit_address;
  endfunction

  function void report_discovery();
    if (!queries_ready("report_discovery"))
      return;
    `uvm_info("SWITCH_ENUM_DISCOVERY", $sformatf(
      "USP bdf=%04x buses=%02x/%02x/%02x window=[0x%016h:0x%016h]",
      usp.bdf, usp.primary_bus, usp.secondary_bus, usp.subordinate_bus,
      usp.prefetch_base, usp.prefetch_limit), UVM_NONE)
    foreach (endpoints[i]) begin
      `uvm_info("SWITCH_ENUM_DISCOVERY", $sformatf(
        "DSP[%0d] bdf=%04x EP[%0d] bdf=%04x parent=%04x window=[0x%016h:0x%016h] BAR0=[0x%016h:0x%016h] BAR2=[0x%016h:0x%016h] BAR4=[0x%016h:0x%016h]",
        endpoints[i].dsp_index, dsps[endpoints[i].dsp_index].bdf, i,
        endpoints[i].bdf, endpoints[i].parent_dsp_bdf,
        dsps[endpoints[i].dsp_index].prefetch_base,
        dsps[endpoints[i].dsp_index].prefetch_limit,
        get_bar_base(i, 0), get_bar_limit(i, 0),
        get_bar_base(i, 1), get_bar_limit(i, 1),
        get_bar_base(i, 2), get_bar_limit(i, 2)), UVM_NONE)
    end
  endfunction
endclass
