class pcie_svt_bar_range extends uvm_object;
  int unsigned low_bar;
  int unsigned high_bar;
  bit is_64bit;
  bit prefetchable;
  bit [63:0] base_address;
  bit [63:0] limit_address;
  bit [63:0] aperture;

  `uvm_object_utils(pcie_svt_bar_range)

  function new(string name = "pcie_svt_bar_range");
    super.new(name);
  endfunction
endclass

class pcie_svt_endpoint_record extends uvm_object;
  string link_id;
  int unsigned root_hierarchy;
  bit [15:0] bdf;
  pcie_svt_bar_range bars[3];
  svt_pcie_ep_enumeration_seq_status source_status;

  `uvm_object_utils(pcie_svt_endpoint_record)

  function new(string name = "pcie_svt_endpoint_record");
    super.new(name);
    foreach (bars[pair])
      bars[pair] = pcie_svt_bar_range::type_id::create(
        $sformatf("bar_pair_%0d", pair));
  endfunction

  function bit [63:0] bar_base(int unsigned pair);
    if ((pair >= 3) || (bars[pair] == null))
      return '0;
    return bars[pair].base_address;
  endfunction
endclass

class pcie_svt_bridge_record extends uvm_object;
  bit is_usp;
  int unsigned index;
  bit [15:0] bdf;
  bit [7:0] primary_bus;
  bit [7:0] secondary_bus;
  bit [7:0] subordinate_bus;
  bit [63:0] prefetch_base;
  bit [63:0] prefetch_limit;

  `uvm_object_utils(pcie_svt_bridge_record)

  function new(string name = "pcie_svt_bridge_record");
    super.new(name);
  endfunction
endclass

class pcie_svt_enumeration_registry extends uvm_object;
  pcie_svt_endpoint_record endpoints[$];
  pcie_svt_bridge_record bridges[$];
  string last_error;

  protected string pending_errors[$];
  protected bit finalized;

  `uvm_object_utils(pcie_svt_enumeration_registry)

  function new(string name = "pcie_svt_enumeration_registry");
    super.new(name);
  endfunction

  protected function void add_pending_error(string message);
    pending_errors.push_back(message);
  endfunction

  protected function bit [63:0] range_aperture(
      string link_id,
      int unsigned low_bar,
      int unsigned high_bar,
      bit [63:0] base_address,
      bit [63:0] limit_address);
    if ((base_address == 0) && (limit_address == 0)) begin
      add_pending_error($sformatf(
        "%s BAR%0d/%0d has zero aperture",
        link_id, low_bar, high_bar));
      return '0;
    end
    if (limit_address < base_address) begin
      add_pending_error($sformatf(
        "%s BAR%0d/%0d has reversed range [0x%016h:0x%016h]",
        link_id, low_bar, high_bar, base_address, limit_address));
      return '0;
    end
    if ((base_address == 0) && (limit_address == '1)) begin
      add_pending_error($sformatf(
        "%s BAR%0d/%0d aperture overflows 64 bits",
        link_id, low_bar, high_bar));
      return '0;
    end
    return limit_address - base_address + 1;
  endfunction

  function void record_direct_endpoint(
      string link_id,
      int unsigned root_hierarchy,
      bit [15:0] bdf,
      svt_pcie_ep_enumeration_seq_status status);
    pcie_svt_endpoint_record endpoint;

    last_error = "";
    if (finalized) begin
      add_pending_error("cannot record a direct Endpoint after finalize");
      finalized = 1'b0;
    end
    endpoint = pcie_svt_endpoint_record::type_id::create(
      $sformatf("direct_endpoint_%0d", endpoints.size()));
    endpoint.link_id = link_id;
    endpoint.root_hierarchy = root_hierarchy;
    endpoint.bdf = bdf;
    endpoint.source_status = status;
    endpoints.push_back(endpoint);

    if (link_id.len() == 0)
      add_pending_error("direct Endpoint link ID must be non-empty");
    if (status == null) begin
      add_pending_error($sformatf(
        "%s has null official Endpoint enumeration status", link_id));
      return;
    end
    if (!status.address_space_calculated)
      add_pending_error($sformatf(
        "%s official Endpoint address space was not calculated", link_id));
    if (status.max_num_functions_supported != 1)
      add_pending_error($sformatf(
        "%s must enumerate exactly one physical function; got %0d",
        link_id, status.max_num_functions_supported));
    if (bdf !== {status.captured_bus_number,
                 status.captured_device_number, 3'h0})
      add_pending_error($sformatf(
        "%s BDF %04x disagrees with official status %02x:%02x.0",
        link_id, bdf, status.captured_bus_number,
        status.captured_device_number));

    for (int unsigned pair = 0; pair < 3; pair++) begin
      int unsigned low_bar;
      int unsigned high_bar;
      bit [1:0] low_type;
      bit [1:0] high_type;
      pcie_svt_bar_range bar;

      low_bar = pair * 2;
      high_bar = low_bar + 1;
      low_type = status.non_virtual_bar_present[0][low_bar];
      high_type = status.non_virtual_bar_present[0][high_bar];
      bar = endpoint.bars[pair];
      bar.low_bar = low_bar;
      bar.high_bar = high_bar;
      bar.is_64bit = (low_type == 2'b10);
      // This registry describes the topology profile's required BAR contract.
      // The enumeration sequence independently proves bit 3 over the link.
      bar.prefetchable = 1'b1;
      bar.base_address =
        status.min_per_bar_address_range[0][low_bar];
      bar.limit_address =
        status.max_per_bar_address_range[0][low_bar];
      bar.aperture = range_aperture(
        link_id, low_bar, high_bar, bar.base_address, bar.limit_address);

      if ((low_type != 2'b10) && (high_type != 2'b00))
        add_pending_error($sformatf(
          "%s BAR%0d is present without a 64-bit low BAR%0d",
          link_id, high_bar, low_bar));
      if (low_type != 2'b10)
        add_pending_error($sformatf(
          "%s BAR%0d/%0d low BAR%0d must be a 64-bit Memory BAR; type=%02b",
          link_id, low_bar, high_bar, low_bar, low_type));
      if ((low_type == 2'b10) && (high_type != 2'b00))
        add_pending_error($sformatf(
          "%s BAR%0d must be only the upper half of 64-bit BAR%0d; type=%02b",
          link_id, high_bar, low_bar, high_type));
    end
  endfunction

  protected function void check_unique_endpoint_keys(ref string errors[$]);
    foreach (endpoints[i]) begin
      for (int unsigned j = i + 1; j < endpoints.size(); j++) begin
        if (endpoints[i].link_id == endpoints[j].link_id)
          errors.push_back($sformatf(
            "duplicate link ID '%s'", endpoints[i].link_id));
        if ((endpoints[i].root_hierarchy ==
               endpoints[j].root_hierarchy) &&
            (endpoints[i].bdf == endpoints[j].bdf))
          errors.push_back($sformatf(
            "duplicate BDF %04x in root hierarchy %0d",
            endpoints[i].bdf, endpoints[i].root_hierarchy));
      end
    end
  endfunction

  protected function void check_bar_ranges(ref string errors[$]);
    foreach (endpoints[i]) begin
      foreach (endpoints[i].bars[pair]) begin
        pcie_svt_bar_range current;
        current = endpoints[i].bars[pair];
        if (current == null) begin
          errors.push_back($sformatf(
            "%s BAR pair %0d is null", endpoints[i].link_id, pair));
          continue;
        end
        if (current.aperture == 0)
          continue;
        for (int unsigned other_i = i;
             other_i < endpoints.size(); other_i++) begin
          int unsigned first_pair;
          if (endpoints[other_i].root_hierarchy !=
              endpoints[i].root_hierarchy)
            continue;
          first_pair = (other_i == i) ? pair + 1 : 0;
          for (int unsigned other_pair = first_pair;
               other_pair < 3; other_pair++) begin
            pcie_svt_bar_range other;
            other = endpoints[other_i].bars[other_pair];
            if ((other == null) || (other.aperture == 0))
              continue;
            if ((current.base_address <= other.limit_address) &&
                (other.base_address <= current.limit_address))
              errors.push_back($sformatf(
                {"%s BAR%0d/%0d [0x%016h:0x%016h] overlaps ",
                 "%s BAR%0d/%0d [0x%016h:0x%016h] in root hierarchy %0d"},
                endpoints[i].link_id, current.low_bar, current.high_bar,
                current.base_address, current.limit_address,
                endpoints[other_i].link_id, other.low_bar, other.high_bar,
                other.base_address, other.limit_address,
                endpoints[i].root_hierarchy));
          end
        end
      end
    end
  endfunction

  function void finalize(ref string errors[$]);
    errors.delete();
    last_error = "";
    finalized = 1'b0;
    foreach (pending_errors[i])
      errors.push_back(pending_errors[i]);
    if (endpoints.size() == 0)
      errors.push_back("enumeration registry contains no Endpoint records");
    check_unique_endpoint_keys(errors);
    check_bar_ranges(errors);
    finalized = (errors.size() == 0);
  endfunction

  function bit is_finalized();
    return finalized;
  endfunction

  protected function bit queries_ready(string query_name);
    last_error = "";
    if (!finalized) begin
      last_error = {query_name, " rejected before finalize"};
      return 1'b0;
    end
    return 1'b1;
  endfunction

  function int unsigned endpoint_count();
    if (!queries_ready("endpoint_count"))
      return 0;
    return endpoints.size();
  endfunction

  function int unsigned bar_count();
    if (!queries_ready("bar_count"))
      return 0;
    return endpoints.size() * 3;
  endfunction

  function pcie_svt_endpoint_record find_endpoint(string link_id);
    if (!queries_ready("find_endpoint"))
      return null;
    foreach (endpoints[i]) begin
      if (endpoints[i].link_id == link_id)
        return endpoints[i];
    end
    last_error = $sformatf(
      "find_endpoint could not resolve link ID '%s'", link_id);
    return null;
  endfunction
endclass
