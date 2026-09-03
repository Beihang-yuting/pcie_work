`include "pcie_unified_limits.svh"

//------------------------------------------------------------------------------
// Unified PCIe environment configuration.
//
// This class is the single policy hand-off to TL and SVT backends.  It keeps
// pcie_topology_cfg as the authoritative graph and adds only device images,
// backend selection, and static-slot/runtime-link checks.
//------------------------------------------------------------------------------

class pcie_global_cfg extends uvm_object;
  // --------------------------------------------------------------------------
  // Authoritative graph and backend choice.
  // --------------------------------------------------------------------------
  // The graph is authoritative for node/link connectivity and ownership.
  pcie_topology_cfg topology;

  // Backend selection controls which child environment is constructed.
  pcie_backend_e backend = PCIE_BACKEND_TL_ONLY;

  // 后端无关的 SVT Mapper 桥接显式开关。将其放在公共配置中可让
  // TL-only 编译路径保持不依赖 SVT 枚举/类，同时保留默认关闭行为。
  bit svt_bridge_enable = 1'b0;

  // Runtime link count is bounded by compile-time project macros.
  int unsigned runtime_num_links;

  // --------------------------------------------------------------------------
  // Derived runtime policy.
  // --------------------------------------------------------------------------
  // Dynamic policy records are sized from the selected topology at build time.
  pcie_link_cfg links[$];
  pcie_device_cfg devices[$];

  `uvm_object_utils(pcie_global_cfg)

  function new(string name = "pcie_global_cfg");
    super.new(name);
  endfunction

  // Populate link/device policy from the existing graph.  No connectivity is
  // rebuilt here; this method only creates backend-neutral records and stable
  // default BDF/BAR values that later adapters may override.
  function void build_default_for_topology(pcie_topology_cfg topology_arg);
    int rc_index;
    int switch_index;
    int ep_index;

    // Reset all derived policy before consuming the new authoritative graph.
    topology = topology_arg;
    links.delete();
    devices.delete();
    runtime_num_links = (topology == null) ? 0 : topology.links.size();

    // BDF allocation uses independent counters so each role has stable device
    // numbering even when a topology contains several node classes.
    rc_index = 0;
    switch_index = 0;
    ep_index = 0;

    if (topology == null)
      return;

    // Build one backend-neutral runtime policy record for every graph link.
    foreach (topology.links[i]) begin
      pcie_link_cfg link;
      pcie_topology_link_cfg source;

      source = topology.links[i];

      if (source == null) begin
        links.push_back(null);
        continue;
      end

      link = pcie_link_cfg::type_id::create(
        $sformatf("link_%0d", i));

      // Connectivity and physical capabilities come directly from the graph.
      link.link_id               = source.link_id;
      link.upstream_node_id      = source.upstream_node_id;
      link.downstream_node_id    = source.downstream_node_id;
      link.upstream_role         = source.upstream_role;
      link.downstream_role       = source.downstream_role;
      link.upstream_port_index   = source.upstream_port_index;
      link.downstream_port_index = source.downstream_port_index;
      link.enabled               = source.enabled;
      link.use_svt               = 1'b0;
      link.link_width            = source.link_width;
      link.max_gen               = source.max_gen;

      links.push_back(link);
    end

    // Build one configuration-space policy record for every enumerated node.
    foreach (topology.nodes[i]) begin
      pcie_topology_node_cfg source;
      pcie_device_cfg device;

      source = topology.nodes[i];

      if (source == null) begin
        devices.push_back(null);
        continue;
      end

      device = pcie_device_cfg::type_id::create(
        $sformatf("device_%s", source.node_id));

      // Common command-register defaults apply before role-specific identity.
      device.device_id = source.node_id;
      device.cfg_space_enable = 1'b1;
      device.bus_master_enable = 1'b0;

      case (source.kind)
        PCIE_TOPO_NODE_RC: begin
          device.role = PCIE_DEVICE_RC;
          device.header_type = 8'h00;
          device.bdf = {8'h00, 5'(rc_index), 3'b000};
          rc_index++;
        end
        PCIE_TOPO_NODE_SWITCH: begin
          device.role = PCIE_DEVICE_SWITCH;
          device.header_type = 8'h01;
          device.bdf = {8'h01, 5'(switch_index), 3'b000};
          switch_index++;
        end
        PCIE_TOPO_NODE_EP: begin
          device.role = PCIE_DEVICE_EP;
          device.header_type = 8'h00;
          device.bdf = {8'h02, 5'(ep_index), 3'b000};
          ep_index++;
        end
        default: begin
          device.role = PCIE_DEVICE_EP;
          device.header_type = 8'h00;
        end
      endcase

      // Every device starts with the project BAR profile; scenarios may
      // replace individual descriptors in build_global_cfg().
      device.init_default_bars();
      devices.push_back(device);
    end
  endfunction

  // Validate all policy before either backend creates children.  In particular,
  // a duplicate static slot is rejected because two logical links cannot safely
  // share one HDL VIF even if only one happens to be active at runtime.
  function void validate(output string errors[$]);
    bit seen_link[string];
    string slot_owner[int unsigned];
    bit seen_bdf[bit [15:0]];

    errors.delete();

    // Validate the graph first; later checks assume its node/link references
    // are internally consistent.
    if (topology == null)
      errors.push_back("topology is null");
    else
      topology.validate(errors);

    // Dynamic policy is always bounded by the compile-time HDL allocation.
    if (runtime_num_links > `PCIE_SVT_ENV_MAX_NUM_LINKS)
      errors.push_back($sformatf(
        "runtime_num_links=%0d exceeds PCIE_SVT_ENV_MAX_NUM_LINKS=%0d",
        runtime_num_links, `PCIE_SVT_ENV_MAX_NUM_LINKS));
    if (links.size() > `PCIE_SVT_ENV_MAX_NUM_LINKS)
      errors.push_back($sformatf(
        "link policy count=%0d exceeds PCIE_SVT_ENV_MAX_NUM_LINKS=%0d",
        links.size(), `PCIE_SVT_ENV_MAX_NUM_LINKS));

    // Link checks cover identity, physical capability, and exclusive ownership
    // of each statically elaborated SVT HDL slot.
    foreach (links[i]) begin
      if (links[i] == null) begin
        errors.push_back($sformatf("link policy %0d is null", i));
        continue;
      end

      if (seen_link.exists(links[i].link_id))
        errors.push_back($sformatf("duplicate link ID '%s'", links[i].link_id));
      else
        seen_link[links[i].link_id] = 1'b1;

      if (!((links[i].link_width == 4) || (links[i].link_width == 8) ||
            (links[i].link_width == 16)))
        errors.push_back($sformatf("link '%s' has unsupported width x%0d",
                                   links[i].link_id, links[i].link_width));
      if (!((links[i].max_gen == 4) || (links[i].max_gen == 5)))
        errors.push_back($sformatf("link '%s' has unsupported Gen%0d",
                                   links[i].link_id, links[i].max_gen));

      if (links[i].has_hdl_slot) begin
        if (links[i].hdl_slot >= `PCIE_SVT_ENV_MAX_HDL_AGENTS)
          errors.push_back($sformatf(
            "link '%s' HDL slot %0d exceeds PCIE_SVT_ENV_MAX_HDL_AGENTS=%0d",
            links[i].link_id, links[i].hdl_slot,
            `PCIE_SVT_ENV_MAX_HDL_AGENTS));
        if (slot_owner.exists(links[i].hdl_slot))
          errors.push_back($sformatf(
            "HDL slot %0d is assigned to both '%s' and '%s'",
            links[i].hdl_slot, slot_owner[links[i].hdl_slot],
            links[i].link_id));
        else
          slot_owner[links[i].hdl_slot] = links[i].link_id;
      end
    end

    // Device checks ensure unique enumeration identity and legal BAR sizing.
    foreach (devices[i]) begin
      if (devices[i] == null) begin
        errors.push_back($sformatf("device policy %0d is null", i));
        continue;
      end

      if (seen_bdf.exists(devices[i].bdf))
        errors.push_back($sformatf("duplicate device BDF 0x%04h",
                                   devices[i].bdf));
      else
        seen_bdf[devices[i].bdf] = 1'b1;

      foreach (devices[i].bars[bar]) begin
        if ((devices[i].bars[bar] != null) &&
            devices[i].bars[bar].implemented) begin
          if ((devices[i].bars[bar].aperture < 16) ||
              ((devices[i].bars[bar].aperture &
                (devices[i].bars[bar].aperture - 1)) != 0))
            errors.push_back($sformatf(
              "device '%s' BAR%0d aperture is not a power of two",
              devices[i].device_id, bar));
          if (devices[i].bars[bar].is_64bit && (bar == 5))
            errors.push_back($sformatf(
              "device '%s' BAR5 cannot own a 64-bit BAR",
              devices[i].device_id));
        end
      end
    end

    // A selected SVT backend must own at least one enabled runtime link.  This
    // catches a policy that would otherwise elaborate an idle VIP environment.
    if ((backend != PCIE_BACKEND_TL_ONLY) &&
        (runtime_num_links != 0)) begin
      bit any_svt;

      any_svt = 1'b0;

      foreach (links[i])
        if ((links[i] != null) && links[i].enabled && links[i].use_svt)
          any_svt = 1'b1;
      if (!any_svt)
        errors.push_back("SVT backend selected but no enabled link uses SVT");
    end
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_global_cfg source;
    pcie_link_cfg link_copy;
    pcie_device_cfg device_copy;

    super.do_copy(rhs);

    if (!$cast(source, rhs)) begin
      `uvm_fatal("GLOBAL_CFG_COPY", "global source has the wrong type")
      return;
    end

    // The graph is immutable policy at this layer and remains shared.  Derived
    // link/device records are deep-copied for independent scenario overrides.
    topology = source.topology;
    backend = source.backend;
    svt_bridge_enable = source.svt_bridge_enable;
    runtime_num_links = source.runtime_num_links;

    links.delete();
    foreach (source.links[i]) begin
      if (source.links[i] == null)
        links.push_back(null);
      else begin
        link_copy = pcie_link_cfg::type_id::create(
          $sformatf("link_copy_%0d", i));

        link_copy.copy(source.links[i]);
        links.push_back(link_copy);
      end
    end

    devices.delete();
    foreach (source.devices[i]) begin
      if (source.devices[i] == null)
        devices.push_back(null);
      else begin
        device_copy = pcie_device_cfg::type_id::create(
          $sformatf("device_copy_%0d", i));

        device_copy.copy(source.devices[i]);
        devices.push_back(device_copy);
      end
    end
  endfunction
endclass
