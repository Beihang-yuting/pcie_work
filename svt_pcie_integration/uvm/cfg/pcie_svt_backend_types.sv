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

  // Endpoint BARs are meaningful only when this descriptor represents an EP.
  pcie_svt_bar_cfg ep_bars[6];

  `uvm_object_utils(pcie_svt_port_descriptor)

  function new(string name = "pcie_svt_port_descriptor");
    super.new(name);
    foreach (ep_bars[i])
      ep_bars[i] = pcie_svt_bar_cfg::type_id::create(
        $sformatf("bar%0d", i));
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
