import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_svt_topology_pkg::*;
import svt_uvm_pkg::*;
import svt_pcie_uvm_pkg::*;
`include "uvm_macros.svh"

// Kept ahead of the adapter override so the TDD RED compile identifies the
// missing production orchestrator, not merely its test seam.
class pcie_svt_cfg_init_production_probe;
  pcie_svt_cfg_init_vseq sequence_item;
endclass

class pcie_svt_cfg_init_recorded_operation extends uvm_object;
  string link_id;
  string operation;
  int bar_num;
  bit [15:0] bdf_num;
  bit [27:0] ecam_addr;
  bit [31:0] data;
  bit [31:0] bit_mask;
  bit io_select;

  `uvm_object_utils(pcie_svt_cfg_init_recorded_operation)

  function new(string name = "pcie_svt_cfg_init_recorded_operation");
    super.new(name);
    bar_num = -1;
  endfunction
endclass

class pcie_svt_cfg_init_recording_adapter extends
    pcie_svt_cfg_init_service_adapter;
  static pcie_svt_cfg_init_recorded_operation operations[$];
  static bit [31:0] cfg_data[string];
  static int unsigned cfg_write_hits[string];
  static int unsigned cfg_read_hits[string];
  static svt_pcie_device_configuration published_cfg_by_link[string];
  static svt_pcie_device_configuration registry_cfg_by_link[string];
  static bit [31:0] bar_data[string];
  static bit [31:0] bar_map[string];
  static virtual pcie_svt_reset_if observed_reset_vif;
  static int unsigned event_ordinal;
  static int unsigned refresh_count;
  static int unsigned wrapper_refresh_count;
  static int unsigned refresh_with_reset_asserted_count;
  static int unsigned last_refresh_ordinal;
  static int unsigned reset_release_count;
  static int unsigned reset_release_ordinal;
  static int unsigned post_refresh_call_count;
  static int unsigned post_refresh_with_reset_released_count;
  static int unsigned first_post_refresh_ordinal;

  `uvm_object_utils(pcie_svt_cfg_init_recording_adapter)

  function new(string name = "pcie_svt_cfg_init_recording_adapter");
    super.new(name);
  endfunction

  static function void clear_records();
    operations.delete();
    cfg_data.delete();
    cfg_write_hits.delete();
    cfg_read_hits.delete();
    published_cfg_by_link.delete();
    registry_cfg_by_link.delete();
    bar_data.delete();
    bar_map.delete();
    event_ordinal = 0;
    refresh_count = 0;
    wrapper_refresh_count = 0;
    refresh_with_reset_asserted_count = 0;
    last_refresh_ordinal = 0;
    reset_release_count = 0;
    reset_release_ordinal = 0;
    post_refresh_call_count = 0;
    post_refresh_with_reset_released_count = 0;
    first_post_refresh_ordinal = 0;
  endfunction

  static function int unsigned next_event_ordinal();
    event_ordinal++;
    return event_ordinal;
  endfunction

  static function void observe_reset_release();
    if ((observed_reset_vif != null) &&
        (observed_reset_vif.asserted === '0)) begin
      reset_release_count++;
      reset_release_ordinal = next_event_ordinal();
    end
  endfunction

  protected function void observe_refresh();
    refresh_count++;
    last_refresh_ordinal = next_event_ordinal();
    if ((observed_reset_vif != null) &&
        (observed_reset_vif.asserted === '1))
      refresh_with_reset_asserted_count++;
  endfunction

  protected function void observe_post_refresh_call();
    int unsigned ordinal;
    ordinal = next_event_ordinal();
    post_refresh_call_count++;
    if (first_post_refresh_ordinal == 0)
      first_post_refresh_ordinal = ordinal;
    if ((observed_reset_vif != null) &&
        (observed_reset_vif.asserted === '0))
      post_refresh_with_reset_released_count++;
  endfunction

  static function string cfg_key(
      string selected_link_id,
      int unsigned function_num,
      int unsigned dword_addr);
    return $sformatf("%s:%0d:%0d", selected_link_id, function_num,
                     dword_addr);
  endfunction

  static function string bar_key(
      string selected_link_id,
      bit [15:0] bdf_num,
      int unsigned bar_num);
    return $sformatf("%s:%04h:%0d", selected_link_id, bdf_num, bar_num);
  endfunction

  static function bit cfg_write_seen(
      string selected_link_id,
      int unsigned dword_addr,
      output bit [31:0] value);
    string key;
    key = cfg_key(selected_link_id, 0, dword_addr);
    value = cfg_data.exists(key) ? cfg_data[key] : 32'h0;
    return cfg_write_hits.exists(key) && (cfg_write_hits[key] != 0);
  endfunction

  static function int unsigned cfg_write_count(
      string selected_link_id,
      int unsigned dword_addr);
    string key;
    key = cfg_key(selected_link_id, 0, dword_addr);
    return cfg_write_hits.exists(key) ? cfg_write_hits[key] : 0;
  endfunction

  static function int unsigned cfg_read_count(
      string selected_link_id,
      int unsigned dword_addr);
    string key;
    key = cfg_key(selected_link_id, 0, dword_addr);
    return cfg_read_hits.exists(key) ? cfg_read_hits[key] : 0;
  endfunction

  static function void get_link_operations(
      string selected_link_id,
      output pcie_svt_cfg_init_recorded_operation selected[$]);
    selected.delete();
    foreach (operations[i])
      if ((operations[i] != null) &&
          (operations[i].link_id == selected_link_id))
        selected.push_back(operations[i]);
  endfunction

  protected function pcie_svt_cfg_init_recorded_operation record(
      string operation);
    pcie_svt_cfg_init_recorded_operation item;
    item = pcie_svt_cfg_init_recorded_operation::type_id::create(
      $sformatf("record_%0d", operations.size()));
    item.link_id = link_id;
    item.operation = operation;
    operations.push_back(item);
    return item;
  endfunction

  protected function void validate_published_refresh_cfg(
      svt_pcie_device_agent agent,
      svt_pcie_device_configuration registry_cfg);
    svt_pcie_device_configuration published_cfg;
    int before_warnings;
    int after_warnings;
    bit valid;

    published_cfg = null;
    if (!uvm_config_db#(svt_pcie_device_configuration)::get(
          agent, "", "cfg", published_cfg) || (published_cfg == null))
      `uvm_fatal("CFG_INIT_DIRECTED", {link_id,
        ": REFRESH_CFG did not publish a configuration at agent scope"})
    before_warnings = uvm_report_server::get_server().
      get_severity_count(UVM_WARNING);
    valid = published_cfg.is_valid(0);
    after_warnings = uvm_report_server::get_server().
      get_severity_count(UVM_WARNING);
    if ((published_cfg == registry_cfg) ||
        (published_cfg.device_is_root != 1'b0) ||
        (published_cfg.pcie_cfg == null) ||
        (published_cfg.pcie_cfg.enable_multi_endpoint_mode != 1'b1) ||
        !published_cfg.target_cfg.exists(0) ||
        (published_cfg.target_cfg[0] == null) ||
        !valid || (after_warnings != before_warnings))
      `uvm_fatal("CFG_INIT_DIRECTED", $sformatf(
        {"%s: REFRESH_CFG requires a valid normalized agent-current clone ",
         "registry_match=%0d outer_root=%0d multi_endpoint=%0d ",
         "target0_present=%0d is_valid=%0d warning_delta=%0d"},
        link_id, published_cfg == registry_cfg,
        published_cfg.device_is_root,
        (published_cfg.pcie_cfg == null) ? 0 :
          published_cfg.pcie_cfg.enable_multi_endpoint_mode,
        published_cfg.target_cfg.exists(0) &&
          (published_cfg.target_cfg[0] != null),
        valid, after_warnings - before_warnings))
    published_cfg_by_link[link_id] = published_cfg;
    registry_cfg_by_link[link_id] = registry_cfg;
  endfunction

  virtual task start_refresh(
      svt_pcie_device_agent_service_sequence sequence_item,
      svt_pcie_device_agent_service_sequencer sequencer,
      svt_pcie_device_agent agent,
      svt_pcie_device_configuration cfg);
    observe_refresh();
    wrapper_refresh_count++;
    if ((sequence_item == null) ||
        (sequence_item.service_type !=
          svt_pcie_device_agent_service::REFRESH_CFG))
      `uvm_fatal("CFG_INIT_DIRECTED", {link_id,
        ": production did not create a REFRESH_CFG service sequence"})
    validate_published_refresh_cfg(agent, cfg);
    void'(record("REFRESH_CFG"));
  endtask

  virtual task execute_cfg_database(
      svt_pcie_cfg_database_service request,
      uvm_sequencer_base sequencer,
      uvm_sequence_base owner_sequence);
    string key;
    observe_post_refresh_call();
    if (!published_cfg_by_link.exists(link_id) ||
        (published_cfg_by_link[link_id] == null) ||
        !registry_cfg_by_link.exists(link_id) ||
        (request.cfg != published_cfg_by_link[link_id]) ||
        (request.cfg == registry_cfg_by_link[link_id]))
      `uvm_fatal("CFG_INIT_DIRECTED", $sformatf(
        {"%s: cfg-database request is not bound to the published runtime ",
         "clone published_match=%0d registry_match=%0d"},
        link_id,
        published_cfg_by_link.exists(link_id) &&
          (request.cfg == published_cfg_by_link[link_id]),
        registry_cfg_by_link.exists(link_id) &&
          (request.cfg == registry_cfg_by_link[link_id])))
    key = cfg_key(link_id, request.function_num, request.dword_addr);
    case (request.service_type)
      svt_pcie_cfg_database_service::WRITE_CFG_DWORD: begin
        cfg_data[key] = request.dword_data;
        cfg_write_hits[key]++;
      end
      svt_pcie_cfg_database_service::READ_CFG_DWORD: begin
        if (!cfg_data.exists(key))
          `uvm_fatal("CFG_INIT_DIRECTED", $sformatf(
            "%s: read before write function=%0d dword=0x%03h",
            link_id, request.function_num, request.dword_addr))
        request.dword_data = cfg_data[key];
        cfg_read_hits[key]++;
      end
      default:
        `uvm_fatal("CFG_INIT_DIRECTED", {link_id,
          ": unexpected cfg database service"})
    endcase
    request.command_status = `SVT_PCIE_CFG_DATABASE_STATUS_SUCCESSFUL;
  endtask

  virtual task start_set_bar_ro_map(
      svt_pcie_target_app_service_set_bar_ro_map_sequence sequence_item,
      svt_pcie_target_app_service_sequencer sequencer);
    pcie_svt_cfg_init_recorded_operation item;
    observe_post_refresh_call();
    item = record("SET_MAP");
    item.bar_num = sequence_item.bar_num;
    item.bdf_num = sequence_item.bdf_num;
    item.data = sequence_item.data;
    bar_map[bar_key(link_id, sequence_item.bdf_num,
                    sequence_item.bar_num)] = sequence_item.data;
  endtask

  virtual task start_write_addr(
      svt_pcie_target_app_service_write_addr_sequence sequence_item,
      svt_pcie_target_app_service_sequencer sequencer);
    pcie_svt_cfg_init_recorded_operation item;
    int unsigned decoded_bar;
    observe_post_refresh_call();
    item = record("WRITE_ADDR");
    item.ecam_addr = sequence_item.ecam_addr;
    item.data = sequence_item.data;
    item.bit_mask = sequence_item.bit_mask;
    decoded_bar = (sequence_item.ecam_addr[11:0] - 12'h010) / 4;
    item.bar_num = decoded_bar;
    bar_data[bar_key(link_id, sequence_item.ecam_addr[27:12],
                     decoded_bar)] = sequence_item.data;
  endtask

  virtual task start_read_addr(
      svt_pcie_target_app_service_read_addr_sequence sequence_item,
      svt_pcie_target_app_service_sequencer sequencer);
    pcie_svt_cfg_init_recorded_operation item;
    int unsigned decoded_bar;
    string key;
    observe_post_refresh_call();
    item = record("READ_ADDR");
    item.ecam_addr = sequence_item.ecam_addr;
    decoded_bar = (sequence_item.ecam_addr[11:0] - 12'h010) / 4;
    item.bar_num = decoded_bar;
    key = bar_key(link_id, sequence_item.ecam_addr[27:12], decoded_bar);
    if (!bar_data.exists(key))
      `uvm_fatal("CFG_INIT_DIRECTED", {link_id,
        ": BAR read was not preceded by BAR write"})
    sequence_item.data = bar_data[key];
    item.data = sequence_item.data;
  endtask

  virtual task start_get_bar_ro_map(
      svt_pcie_target_app_service_get_bar_ro_map_sequence sequence_item,
      svt_pcie_target_app_service_sequencer sequencer);
    pcie_svt_cfg_init_recorded_operation item;
    string key;
    observe_post_refresh_call();
    item = record("GET_MAP");
    item.bar_num = sequence_item.bar_num;
    item.bdf_num = sequence_item.bdf_num;
    key = bar_key(link_id, sequence_item.bdf_num, sequence_item.bar_num);
    if (!bar_map.exists(key))
      `uvm_fatal("CFG_INIT_DIRECTED", {link_id,
        ": BAR map read was not preceded by BAR map write"})
    sequence_item.data = bar_map[key];
    item.data = sequence_item.data;
  endtask

  virtual task start_set_completer_space_enable(
      svt_pcie_target_app_service_set_completer_space_enable_sequence
        sequence_item,
      svt_pcie_target_app_service_sequencer sequencer);
    pcie_svt_cfg_init_recorded_operation item;
    observe_post_refresh_call();
    item = record("SET_COMPLETER_SPACE_ENABLE");
    item.data = sequence_item.data;
    item.io_select = sequence_item.io_select;
  endtask
endclass

class pcie_svt_cfg_init_directed_test extends pcie_svt_topology_base_test;
  `uvm_component_utils(pcie_svt_cfg_init_directed_test)

  function new(string name = "pcie_svt_cfg_init_directed_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    uvm_factory factory;
    super.build_phase(phase);
    factory = uvm_factory::get();
    factory.set_type_override_by_type(
      pcie_svt_cfg_init_service_adapter::get_type(),
      pcie_svt_cfg_init_recording_adapter::get_type());
  endfunction

  protected function bit dword_requires_readback(int unsigned dword_addr);
    return (dword_addr inside {0, 1, 2, 3, [4:9], 11, 15});
  endfunction

  protected function void check_cfg_database(
      string link_id,
      pcie_svt_port_descriptor descriptor);
    pcie_svt_cfg_space_builder builder;
    bit [31:0] expected_image[1024];
    bit [31:0] actual;

    builder = pcie_svt_cfg_space_builder::type_id::create(
      {link_id, "_directed_builder"});
    builder.build_ep_pf0(descriptor, expected_image);
    for (int unsigned dword_addr = 0; dword_addr < 1024; dword_addr++) begin
      topology_check(
        pcie_svt_cfg_init_recording_adapter::cfg_write_seen(
          link_id, dword_addr, actual),
        $sformatf("%s PF0 dword 0x%03h was not preloaded",
                  link_id, dword_addr));
      topology_check(
        pcie_svt_cfg_init_recording_adapter::cfg_write_count(
          link_id, dword_addr) == 1,
        $sformatf("%s PF0 dword 0x%03h write count is not one",
                  link_id, dword_addr));
      topology_check(actual === expected_image[dword_addr], $sformatf(
        "%s PF0 dword 0x%03h expected=%08h actual=%08h",
        link_id, dword_addr, expected_image[dword_addr], actual));
      topology_check(
        pcie_svt_cfg_init_recording_adapter::cfg_read_count(
          link_id, dword_addr) == dword_requires_readback(dword_addr),
        $sformatf("%s PF0 dword 0x%03h readback count is wrong",
                  link_id, dword_addr));
    end
  endfunction

  protected function void check_endpoint_operations(
      string link_id,
      bit expect_target_bars);
    pcie_svt_cfg_init_recorded_operation selected[$];
    bit [31:0] expected_map[6] = '{
      32'h01ff_ffff, 32'h0000_0000,
      32'h0000_ffff, 32'h0000_0000,
      32'h0000_ffff, 32'h0000_0000};
    bit [31:0] expected_value[6] = '{
      32'h0000_000c, 32'h0000_0000,
      32'h0000_000c, 32'h0000_0000,
      32'h0000_000c, 32'h0000_0000};
    int unsigned operation_index;
    int unsigned expected_operation_count;

    pcie_svt_cfg_init_recording_adapter::get_link_operations(
      link_id, selected);
    expected_operation_count = expect_target_bars ? 26 : 1;
    if (selected.size() != expected_operation_count) begin
      topology_check(1'b0,
        $sformatf("%s operation count expected=%0d actual=%0d",
          link_id, expected_operation_count, selected.size()));
      return;
    end
    topology_check(selected[0].operation == "REFRESH_CFG",
                   {link_id, ": first operation is not REFRESH_CFG"});
    if (!expect_target_bars)
      return;

    operation_index = 1;
    for (int unsigned bar = 0; bar < 6; bar++) begin
      bit [27:0] expected_ecam;
      expected_ecam = {16'h0000, 12'(12'h010 + 4 * bar)};
      topology_check(selected[operation_index].operation == "SET_MAP",
        $sformatf("%s BAR%0d operation %0d is not SET_MAP",
                  link_id, bar, operation_index));
      topology_check((selected[operation_index].bar_num == bar) &&
                     (selected[operation_index].bdf_num == 16'h0000) &&
                     (selected[operation_index].data == expected_map[bar]),
        $sformatf("%s BAR%0d SET_MAP fields are wrong", link_id, bar));
      operation_index++;

      topology_check(selected[operation_index].operation == "WRITE_ADDR",
        $sformatf("%s BAR%0d operation %0d is not WRITE_ADDR",
                  link_id, bar, operation_index));
      topology_check((selected[operation_index].ecam_addr == expected_ecam) &&
                     (selected[operation_index].bit_mask == 32'hffff_ffff) &&
                     (selected[operation_index].data == expected_value[bar]),
        $sformatf("%s BAR%0d WRITE_ADDR fields are wrong", link_id, bar));
      operation_index++;

      topology_check(selected[operation_index].operation == "READ_ADDR",
        $sformatf("%s BAR%0d operation %0d is not READ_ADDR",
                  link_id, bar, operation_index));
      topology_check(selected[operation_index].ecam_addr == expected_ecam,
        $sformatf("%s BAR%0d READ_ADDR ECAM is wrong", link_id, bar));
      operation_index++;

      topology_check(selected[operation_index].operation == "GET_MAP",
        $sformatf("%s BAR%0d operation %0d is not GET_MAP",
                  link_id, bar, operation_index));
      topology_check((selected[operation_index].bar_num == bar) &&
                     (selected[operation_index].bdf_num == 16'h0000),
        $sformatf("%s BAR%0d GET_MAP fields are wrong", link_id, bar));
      operation_index++;
    end
    topology_check(
      selected[operation_index].operation ==
        "SET_COMPLETER_SPACE_ENABLE",
      {link_id, ": final operation is not SET_COMPLETER_SPACE_ENABLE"});
    topology_check((selected[operation_index].io_select == 1'b0) &&
                   (selected[operation_index].data == 32'h0000_0001),
      {link_id, ": completer memory-space enable fields are wrong"});
  endfunction

  protected function void check_run(
      pcie_svt_cfg_init_vseq sequence_item,
      bit expect_target_bars);
    string ep_links[$];
    string rc_links[$];

    env.vseqr.get_links_by_role(PCIE_SVT_ROLE_EP, ep_links);
    env.vseqr.get_links_by_role(PCIE_SVT_ROLE_RC, rc_links);
    topology_check(ep_links.size() == 4,
      $sformatf("directed Switch expected four Endpoint links, got %0d",
                ep_links.size()));
    topology_check(rc_links.size() == 1,
      $sformatf("directed Switch expected one RC link, got %0d",
                rc_links.size()));
    topology_check(sequence_item.refresh_count == 4,
      $sformatf("refresh count expected=4 actual=%0d",
                sequence_item.refresh_count));
    topology_check(sequence_item.bar_check_count ==
                     (expect_target_bars ? 24 : 0),
      $sformatf("BAR check count expected=%0d actual=%0d",
        expect_target_bars ? 24 : 0, sequence_item.bar_check_count));
    topology_check(sequence_item.bar_service_operation_count ==
                     (expect_target_bars ? 96 : 0),
      $sformatf("BAR service operation count expected=%0d actual=%0d",
        expect_target_bars ? 96 : 0,
        sequence_item.bar_service_operation_count));
    topology_check(sequence_item.cfg_write_count == 4096,
      $sformatf("cfg write count expected=4096 actual=%0d",
                sequence_item.cfg_write_count));
    topology_check(sequence_item.cfg_read_count == 48,
      $sformatf("cfg read count expected=48 actual=%0d",
                sequence_item.cfg_read_count));
    topology_check(
      pcie_svt_cfg_init_recording_adapter::refresh_count == 4,
      $sformatf("observed refresh count expected=4 actual=%0d",
        pcie_svt_cfg_init_recording_adapter::refresh_count));
    topology_check(
      pcie_svt_cfg_init_recording_adapter::wrapper_refresh_count == 4,
      $sformatf("wrapper refresh count expected=4 actual=%0d",
        pcie_svt_cfg_init_recording_adapter::wrapper_refresh_count));
    topology_check(
      pcie_svt_cfg_init_recording_adapter::
        refresh_with_reset_asserted_count == 4,
      $sformatf(
        "refreshes with reset asserted expected=4 actual=%0d",
        pcie_svt_cfg_init_recording_adapter::
          refresh_with_reset_asserted_count));
    topology_check(
      pcie_svt_cfg_init_recording_adapter::reset_release_count == 1,
      $sformatf("reset release count expected=1 actual=%0d",
        pcie_svt_cfg_init_recording_adapter::reset_release_count));
    topology_check(
      pcie_svt_cfg_init_recording_adapter::last_refresh_ordinal <
        pcie_svt_cfg_init_recording_adapter::reset_release_ordinal,
      $sformatf("last refresh ordinal=%0d is not before release=%0d",
        pcie_svt_cfg_init_recording_adapter::last_refresh_ordinal,
        pcie_svt_cfg_init_recording_adapter::reset_release_ordinal));
    topology_check(
      pcie_svt_cfg_init_recording_adapter::reset_release_ordinal <
        pcie_svt_cfg_init_recording_adapter::first_post_refresh_ordinal,
      $sformatf("reset release ordinal=%0d is not before first post-refresh=%0d",
        pcie_svt_cfg_init_recording_adapter::reset_release_ordinal,
        pcie_svt_cfg_init_recording_adapter::first_post_refresh_ordinal));
    topology_check(
      pcie_svt_cfg_init_recording_adapter::post_refresh_call_count != 0,
      "no post-refresh cfg database or Target-App call was observed");
    topology_check(
      pcie_svt_cfg_init_recording_adapter::
        post_refresh_with_reset_released_count ==
      pcie_svt_cfg_init_recording_adapter::post_refresh_call_count,
      $sformatf(
        "post-refresh calls with reset released expected=%0d actual=%0d",
        pcie_svt_cfg_init_recording_adapter::post_refresh_call_count,
        pcie_svt_cfg_init_recording_adapter::
          post_refresh_with_reset_released_count));
    topology_check(env.vseqr.reset_vif.asserted === '0,
      $sformatf("cfg-init final reset expected released, got 0x%0h",
                env.vseqr.reset_vif.asserted));

    foreach (ep_links[i]) begin
      check_endpoint_operations(ep_links[i], expect_target_bars);
      check_cfg_database(ep_links[i], env.vseqr.descriptor_by_link[ep_links[i]]);
      topology_check(env.vseqr.cfg_state[ep_links[i]] == PCIE_SVT_STAGE_PASS,
                     {ep_links[i], ": Endpoint CFG state is not PASS"});
    end
    foreach (rc_links[i]) begin
      pcie_svt_cfg_init_recorded_operation rc_operations[$];
      pcie_svt_cfg_init_recording_adapter::get_link_operations(
        rc_links[i], rc_operations);
      topology_check(rc_operations.size() == 0,
        {rc_links[i], ": upstream RC emitted a cfg-init service record"});
      topology_check(env.vseqr.cfg_state[rc_links[i]] == PCIE_SVT_STAGE_PASS,
                     {rc_links[i], ": RC CFG state is not PASS"});
    end
    foreach (env.vseqr.status_by_link[link_id]) begin
      svt_pcie_device_status status;
      status = env.vseqr.status_by_link[link_id];
      topology_check((status != null) && (status.pcie_status != null) &&
                     (status.pcie_status.pl_status != null) &&
                     (status.pcie_status.pl_status.link_up === 1'b0),
        {link_id, ": effective link did not remain known-down"});
    end
  endfunction

  protected task start_with_reset_release_monitor(
      pcie_svt_cfg_init_vseq sequence_item);
    fork : reset_release_monitor
      forever begin
        @(env.vseqr.reset_vif.asserted);
        if (env.vseqr.reset_vif.asserted === '0)
          pcie_svt_cfg_init_recording_adapter::observe_reset_release();
      end
    join_none
    sequence_item.start(env.vseqr);
    #0;
    disable reset_release_monitor;
  endtask

  virtual task run_phase(uvm_phase phase);
    pcie_svt_cfg_init_vseq cfg_init;
    pcie_svt_cfg_init_vseq refresh_only;

    phase.raise_objection(this);
    if (profile_name != "SWITCH_1X16_4X4")
      `uvm_fatal("CFG_INIT_DIRECTED",
        "directed cfg-init test requires SWITCH_1X16_4X4")

    pcie_svt_cfg_init_recording_adapter::clear_records();
    pcie_svt_cfg_init_recording_adapter::observed_reset_vif =
      env.vseqr.reset_vif;
    cfg_init = pcie_svt_cfg_init_vseq::type_id::create("cfg_init");
    cfg_init.program_target_bars = 1'b1;
    start_with_reset_release_monitor(cfg_init);
    check_run(cfg_init, 1'b1);

    foreach (env.vseqr.cfg_state[link_id])
      env.vseqr.cfg_state[link_id] = PCIE_SVT_STAGE_NOT_RUN;
    env.vseqr.reset_vif.hold_all();
    #0;
    topology_check(env.vseqr.reset_vif.asserted === '1,
      $sformatf("refresh-only setup expected reset asserted, got 0x%0h",
                env.vseqr.reset_vif.asserted));
    pcie_svt_cfg_init_recording_adapter::clear_records();
    pcie_svt_cfg_init_recording_adapter::observed_reset_vif =
      env.vseqr.reset_vif;
    refresh_only = pcie_svt_cfg_init_vseq::type_id::create("refresh_only");
    refresh_only.program_target_bars = 1'b0;
    start_with_reset_release_monitor(refresh_only);
    check_run(refresh_only, 1'b0);

    env.vseqr.report_stage_table();
    phase.drop_objection(this);
  endtask
endclass
