//------------------------------------------------------------------------------
// SVT-facing policy types.  These stay separate from the backend-neutral
// topology package so TL-only builds do not import SVT classes.
//------------------------------------------------------------------------------

typedef enum {PCIE_SVT_ROLE_RC, PCIE_SVT_ROLE_EP} pcie_svt_role_e;
typedef enum {PCIE_SVT_TRANSPORT_SERIAL, PCIE_SVT_TRANSPORT_PIPE}
  pcie_svt_transport_e;
typedef enum {PCIE_SVT_EP_SINGLE, PCIE_SVT_EP_MULTI_BDF}
  pcie_svt_endpoint_model_e;
typedef enum {PCIE_SVT_STAGE_NOT_RUN, PCIE_SVT_STAGE_PASS,
              PCIE_SVT_STAGE_FAIL} pcie_svt_stage_state_e;
typedef enum {PCIE_SVT_RUN_COMPILE, PCIE_SVT_RUN_CFG,
              PCIE_SVT_RUN_LINK, PCIE_SVT_RUN_ENUM,
              PCIE_SVT_RUN_TRAFFIC} pcie_svt_run_mode_e;

function automatic string pcie_svt_join_errors(input string errors[$]);
  string joined;
  joined = "";
  foreach (errors[i])
    joined = {joined, (i == 0) ? "" : "; ", errors[i]};
  return joined;
endfunction

//------------------------------------------------------------------------------
// Enumeration policy shared by every backend adapter.
//
// The project sequence owns the enumeration intent, while this object carries
// the knobs that are normally hidden in a vendor sequence constraint.  Keeping
// them here lets a test, config_db override, or future plusarg parser change
// BAR allocation windows and BDF policy without editing a sequence body.
//------------------------------------------------------------------------------
class pcie_svt_enum_cfg extends uvm_object;
  longint unsigned pref_mem_base_addr;
  longint unsigned pref_mem_limit_addr;
  longint unsigned pref_mem_window_stride;

  bit [7:0] bus_number;
  bit [4:0] device_number;
  int unsigned max_num_functions_supported;

  bit enable_sriov;
  bit enable_vf_memory_space;
  bit get_atomic_op_cap;
  bit enable_atomic_op_as_requester_support;
  bit find_all_base_capabilities;
  bit find_all_extended_capabilities;
  bit enable_incremental_bar_allocation;
  bit is_ep_device_vip;

  `uvm_object_utils(pcie_svt_enum_cfg)

  function new(string name = "pcie_svt_enum_cfg");
    super.new(name);
    init_defaults();
  endfunction

  function void init_defaults();
    // Preserve the historical project defaults: one 256 MiB window per root.
    pref_mem_base_addr = 64'h0000_0001_0000_0000;
    pref_mem_limit_addr = 64'h0000_0001_0fff_ffff;
    pref_mem_window_stride = 64'h0000_0000_1000_0000;
    bus_number = 8'h01;
    device_number = 5'h00;
    max_num_functions_supported = 1;
    enable_sriov = 1'b0;
    enable_vf_memory_space = 1'b0;
    get_atomic_op_cap = 1'b0;
    enable_atomic_op_as_requester_support = 1'b0;
    find_all_base_capabilities = 1'b0;
    find_all_extended_capabilities = 1'b0;
    enable_incremental_bar_allocation = 1'b1;
    is_ep_device_vip = 1'b0;
  endfunction

  function longint unsigned pref_mem_base_for(int unsigned root_hierarchy);
    return pref_mem_base_addr +
           (pref_mem_window_stride * root_hierarchy);
  endfunction

  function longint unsigned pref_mem_limit_for(int unsigned root_hierarchy);
    return pref_mem_limit_addr +
           (pref_mem_window_stride * root_hierarchy);
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_svt_enum_cfg source;
    super.do_copy(rhs);
    if (!$cast(source, rhs)) begin
      `uvm_fatal("SVT_COPY", "pcie_svt_enum_cfg source has the wrong type")
      return;
    end
    pref_mem_base_addr = source.pref_mem_base_addr;
    pref_mem_limit_addr = source.pref_mem_limit_addr;
    pref_mem_window_stride = source.pref_mem_window_stride;
    bus_number = source.bus_number;
    device_number = source.device_number;
    max_num_functions_supported = source.max_num_functions_supported;
    enable_sriov = source.enable_sriov;
    enable_vf_memory_space = source.enable_vf_memory_space;
    get_atomic_op_cap = source.get_atomic_op_cap;
    enable_atomic_op_as_requester_support =
      source.enable_atomic_op_as_requester_support;
    find_all_base_capabilities = source.find_all_base_capabilities;
    find_all_extended_capabilities = source.find_all_extended_capabilities;
    enable_incremental_bar_allocation =
      source.enable_incremental_bar_allocation;
    is_ep_device_vip = source.is_ep_device_vip;
  endfunction

  function void validate(output string errors[$]);
    longint unsigned window_size;
    errors.delete();
    if (pref_mem_limit_addr < pref_mem_base_addr)
      errors.push_back("enumeration Prefetchable memory limit precedes base");
    else begin
      window_size = pref_mem_limit_addr - pref_mem_base_addr + 1;
      if ((window_size == 0) ||
          ((pref_mem_window_stride != 0) &&
           (pref_mem_window_stride < window_size)))
        errors.push_back(
          "enumeration Prefetchable window stride is smaller than its window");
    end
    if (max_num_functions_supported == 0 ||
        max_num_functions_supported > 256)
      errors.push_back(
        "enumeration max_num_functions_supported must be in the range 1..256");
  endfunction
endclass

class pcie_svt_bar_cfg extends uvm_object;
  // BAR image used by the SVT Target App configuration-space builder.
  bit implemented;
  bit is_64bit;
  bit prefetchable;
  longint unsigned aperture;
  longint unsigned initial_base;

  `uvm_object_utils(pcie_svt_bar_cfg)

  function new(string name = "pcie_svt_bar_cfg");
    super.new(name);
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_svt_bar_cfg source;
    super.do_copy(rhs);
    if (!$cast(source, rhs)) begin
      `uvm_fatal("SVT_COPY", "pcie_svt_bar_cfg source has the wrong type")
      return;
    end
    implemented = source.implemented;
    is_64bit = source.is_64bit;
    prefetchable = source.prefetchable;
    aperture = source.aperture;
    initial_base = source.initial_base;
  endfunction
endclass

class pcie_svt_link_override_cfg extends uvm_object;
  // Optional per-link overrides parsed from command-line arguments.
  string link_id;

  bit has_enable, enabled;
  bit has_gen;
  int unsigned max_gen;
  bit has_width;
  int unsigned link_width;
  bit has_endpoint_model;
  pcie_svt_endpoint_model_e endpoint_model;
  bit has_fast_link_training, fast_link_training;
  bit has_link_timeout;
  time link_timeout;

  `uvm_object_utils(pcie_svt_link_override_cfg)

  function new(string name = "pcie_svt_link_override_cfg");
    super.new(name);
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_svt_link_override_cfg source;
    super.do_copy(rhs);
    if (!$cast(source, rhs)) begin
      `uvm_fatal("SVT_COPY",
                 "pcie_svt_link_override_cfg source has the wrong type")
      return;
    end
    link_id = source.link_id;
    has_enable = source.has_enable;
    enabled = source.enabled;
    has_gen = source.has_gen;
    max_gen = source.max_gen;
    has_width = source.has_width;
    link_width = source.link_width;
    has_endpoint_model = source.has_endpoint_model;
    endpoint_model = source.endpoint_model;
    has_fast_link_training = source.has_fast_link_training;
    fast_link_training = source.fast_link_training;
    has_link_timeout = source.has_link_timeout;
    link_timeout = source.link_timeout;
  endfunction
endclass

class pcie_svt_port_descriptor extends uvm_object;
  // One dynamic descriptor maps to one statically elaborated HDL slot.
  string link_id;
  string svt_node_id;
  string vif_key;

  int unsigned slot_index;
  int unsigned root_hierarchy;
  pcie_svt_role_e role;
  pcie_svt_endpoint_model_e endpoint_model;
  int unsigned physical_width;
  int unsigned link_width;
  int unsigned max_gen;
  bit fast_link_training;
  pcie_svt_transport_e transport;
  time cfg_timeout;
  time link_timeout;
  time enum_timeout;
  time traffic_timeout;

  // Enumeration policy is copied per descriptor so links can be adapted
  // independently while sharing one profile-level default.
  pcie_svt_enum_cfg enum_cfg;

  // Endpoint BARs are meaningful only when this descriptor represents an EP.
  pcie_svt_bar_cfg ep_bars[6];

  `uvm_object_utils(pcie_svt_port_descriptor)

  function new(string name = "pcie_svt_port_descriptor");
    super.new(name);
    foreach (ep_bars[i])
      ep_bars[i] = pcie_svt_bar_cfg::type_id::create(
        $sformatf("bar%0d", i));
    enum_cfg = pcie_svt_enum_cfg::type_id::create("enum_cfg");
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_svt_port_descriptor source;
    super.do_copy(rhs);

    if (!$cast(source, rhs)) begin
      `uvm_fatal("SVT_COPY",
                 "pcie_svt_port_descriptor source has the wrong type")
      return;
    end

    // Copy identity, slot binding, and negotiated capability policy first.
    link_id = source.link_id;
    svt_node_id = source.svt_node_id;
    vif_key = source.vif_key;
    slot_index = source.slot_index;
    root_hierarchy = source.root_hierarchy;
    role = source.role;
    endpoint_model = source.endpoint_model;
    physical_width = source.physical_width;
    link_width = source.link_width;
    max_gen = source.max_gen;
    fast_link_training = source.fast_link_training;
    transport = source.transport;
    cfg_timeout = source.cfg_timeout;
    link_timeout = source.link_timeout;
    enum_timeout = source.enum_timeout;
    traffic_timeout = source.traffic_timeout;
    if (source.enum_cfg == null) begin
      enum_cfg = null;
    end else begin
      if (enum_cfg == null)
        enum_cfg = pcie_svt_enum_cfg::type_id::create("enum_cfg");
      enum_cfg.copy(source.enum_cfg);
    end
    foreach (ep_bars[i]) begin
      if (source.ep_bars[i] == null) begin
        ep_bars[i] = null;
      end else begin
        if (ep_bars[i] == null)
          ep_bars[i] = pcie_svt_bar_cfg::type_id::create(
            $sformatf("bar%0d", i));
        ep_bars[i].copy(source.ep_bars[i]);
      end
    end
  endfunction
endclass
