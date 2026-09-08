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

  // 所有 backend 共用的规范物理链路顺序。直连链路按 link_id 字典序
  // 排序（与 TL topology adapter 一致），Switch USP/DSP 链路按物理端口
  // 号索引。policy 队列刻意保持声明顺序以兼容静态 HDL slot/VIF 元数
  // 据；下面这些数组才是角色序号的唯一权威来源。
  string direct_link_ids[$];
  string switch_usp_link_ids[];
  string switch_dsp_link_ids[];

  `uvm_object_utils(pcie_global_cfg)

  // 构造函数：仅透传名字。
  function new(string name = "pcie_global_cfg");
    super.new(name);
  endfunction

  // 按稳定物理 link ID 查找策略记录的下标；找不到返回 -1。返回原始
  // 对象（而非拷贝）使后续 backend 覆盖对所有策略消费者可见。
  function int find_link_index(string link_id);
    if (link_id == "")
      return -1;
    foreach (links[i]) begin
      if ((links[i] != null) && (links[i].link_id == link_id))
        return i;
    end
    return -1;
  endfunction

  function pcie_link_cfg find_link(string link_id);
    int index;

    index = find_link_index(link_id);
    if (index < 0)
      return null;
    return links[index];
  endfunction

  // 返回权威拓扑图中是否仍存在该 ID 对应的启用边。policy 的 `enabled`
  // 是运行期选择位，不得改变物理槽位序号；槽位是否存在由图上的位
  // 控制。
  function bit topology_link_enabled(string link_id);
    if ((topology == null) || (link_id == ""))
      return 1'b0;
    foreach (topology.links[i]) begin
      if ((topology.links[i] != null) &&
          (topology.links[i].link_id == link_id))
        return topology.links[i].enabled;
    end
    return 1'b0;
  endfunction

  // 按 link_id 返回权威拓扑图中的边记录；不存在时返回 null。
  function pcie_topology_link_cfg find_topology_link(string link_id);
    if ((topology == null) || (link_id == ""))
      return null;
    foreach (topology.links[i]) begin
      if ((topology.links[i] != null) &&
          (topology.links[i].link_id == link_id))
        return topology.links[i];
    end
    return null;
  endfunction

  // 从当前运行期策略重建按角色排序的 ID 表。查询方法都会调用它，因为
  // 调用者可能在图翻译之后禁用链路。缺失的 Switch 端口保持空位并由
  // 拓扑校验诊断；声明顺序永远不作为隐式回退。
  function void refresh_link_order();
    pcie_topology_node_cfg switch_node;
    pcie_link_cfg direct_links[$];
    pcie_link_cfg swap_link;

    direct_link_ids.delete();
    switch_usp_link_ids = new[0];
    switch_dsp_link_ids = new[0];
    switch_node = null;

    if (topology != null) begin
      foreach (topology.nodes[i]) begin
        if ((topology.nodes[i] != null) &&
            (topology.nodes[i].kind == PCIE_TOPO_NODE_SWITCH)) begin
          switch_node = topology.nodes[i];
          break;
        end
      end
    end

    if (switch_node == null) begin
      if (topology != null) begin
        // 物理槽位是否存在由图定义。即使场景随后禁用了某条策略记
        // 录，也要在规范表中保留其槽位；否则禁用 link 0 会让 link 1
        // 被悄悄重新编号。
        foreach (topology.links[i]) begin
          pcie_link_cfg policy_link;

          if ((topology.links[i] == null) || !topology.links[i].enabled)
            continue;
          policy_link = find_link(topology.links[i].link_id);
          if (policy_link != null)
            direct_links.push_back(policy_link);
        end
      end
      else begin
        foreach (links[i]) begin
          if (links[i] != null)
            direct_links.push_back(links[i]);
        end
      end
      for (int i = 0; i < direct_links.size(); i++) begin
        for (int j = i + 1; j < direct_links.size(); j++) begin
          if (direct_links[j].link_id < direct_links[i].link_id) begin
            swap_link = direct_links[i];
            direct_links[i] = direct_links[j];
            direct_links[j] = swap_link;
          end
        end
      end
      foreach (direct_links[i])
        direct_link_ids.push_back(direct_links[i].link_id);
      return;
    end

    // 在 validate() 报出编译期链路上限之前，避免按被污染/乱码的维度
    // 分配数组。非法拓扑暴露空的规范数组；校验失败后任何调用者都不得
    // 使用它们。
    if ((switch_node.num_usp > `PCIE_SVT_ENV_MAX_NUM_LINKS) ||
        (switch_node.num_dsp > `PCIE_SVT_ENV_MAX_NUM_LINKS)) begin
      switch_usp_link_ids = new[0];
      switch_dsp_link_ids = new[0];
      return;
    end
    switch_usp_link_ids = new[switch_node.num_usp];
    switch_dsp_link_ids = new[switch_node.num_dsp];
    foreach (links[i]) begin
      pcie_link_cfg link;

      link = links[i];
      if (link == null)
        continue;

      // 与直连链路相同：物理 Switch 槽位来源于图的启用边集合，而不是
      // 可变的策略 enabled 位。策略禁用只是把 ID 留在其端口槽位上，
      // 由严格的 provider 解析拒绝，而不是把更高端口整体前移。
      if ((topology != null) && !topology_link_enabled(link.link_id))
        continue;

      if ((link.downstream_node_id == switch_node.node_id) &&
          (link.downstream_role == PCIE_TOPO_PORT_USP) &&
          (link.downstream_port_index < switch_usp_link_ids.size())) begin
        switch_usp_link_ids[link.downstream_port_index] = link.link_id;
      end
      else if ((link.upstream_node_id == switch_node.node_id) &&
               (link.upstream_role == PCIE_TOPO_PORT_DSP) &&
               (link.upstream_port_index < switch_dsp_link_ids.size())) begin
        switch_dsp_link_ids[link.upstream_port_index] = link.link_id;
      end
    end
  endfunction

  // 返回占据某个物理角色槽位的链路 ID。直连 RC 和 EP 共享成对序号；
  // Switch 场景 RC 对应 USP、EP 对应 DSP。外部 DUT 槽位（use_svt==0）
  // 也会返回，调用者由此区分"刻意不拥有"与"映射缺失"。
  function string canonical_link_id(
      pcie_device_role_e role,
      int slot_index);
    refresh_link_order();
    canonical_link_id = "";
    if (slot_index < 0)
      return canonical_link_id;

    if ((topology != null) && (switch_usp_link_ids.size() != 0 ||
                               switch_dsp_link_ids.size() != 0)) begin
      if (role == PCIE_DEVICE_RC) begin
        if (slot_index < switch_usp_link_ids.size())
          canonical_link_id = switch_usp_link_ids[slot_index];
      end
      else if (role == PCIE_DEVICE_EP) begin
        if (slot_index < switch_dsp_link_ids.size())
          canonical_link_id = switch_dsp_link_ids[slot_index];
      end
    end
    else if ((role == PCIE_DEVICE_RC) || (role == PCIE_DEVICE_EP)) begin
      if (slot_index < direct_link_ids.size())
        canonical_link_id = direct_link_ids[slot_index];
    end
  endfunction

  // 按规范物理顺序返回角色 ID 列表。provider_only 过滤出启用且 SVT
  // 拥有的链路并保持其规范相对顺序；要寻址物理槽位的调用者必须改用
  // canonical_link_id()，稀疏所有权才不会意外压缩进别的槽位。
  function void get_role_link_ids(
      pcie_device_role_e role,
      output string role_link_ids[$],
      input bit provider_only = 1'b0);
    string canonical_ids[$];

    role_link_ids.delete();
    refresh_link_order();
    if ((topology != null) && (switch_usp_link_ids.size() != 0 ||
                               switch_dsp_link_ids.size() != 0)) begin
      if (role == PCIE_DEVICE_RC)
        foreach (switch_usp_link_ids[i])
          canonical_ids.push_back(switch_usp_link_ids[i]);
      else if (role == PCIE_DEVICE_EP)
        foreach (switch_dsp_link_ids[i])
          canonical_ids.push_back(switch_dsp_link_ids[i]);
    end
    else if ((role == PCIE_DEVICE_RC) || (role == PCIE_DEVICE_EP)) begin
      foreach (direct_link_ids[i])
        canonical_ids.push_back(direct_link_ids[i]);
    end

    foreach (canonical_ids[i]) begin
      pcie_link_cfg link;

      link = find_link(canonical_ids[i]);
      if ((link == null) || (canonical_ids[i] == ""))
        continue;
      // 直连链路的两端可以分配不同的 provider 角色；Switch 拓扑同样有
      // USP/RC 与 DSP/EP 物理槽位。因此角色查询除 use_svt 外还必须过
      // 滤显式的策略角色，否则 EP 拥有的直连链路会被错误地放进 RC
      // 紧凑视图（反之亦然）。
      if (provider_only && (!link.enabled || !link.use_svt ||
                            !link.svt_role_valid ||
                            (link.svt_role != role)))
        continue;
      role_link_ids.push_back(canonical_ids[i]);
    end
  endfunction

  function bit link_is_provider_owned(string link_id);
    pcie_link_cfg link;

    link = find_link(link_id);
    return (link != null) && link.enabled && link.use_svt &&
           link.svt_role_valid &&
           ((link.svt_role == PCIE_DEVICE_RC) ||
            (link.svt_role == PCIE_DEVICE_EP));
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
      link.svt_role_valid        = 1'b0;
      link.svt_node_id           = "";
      link.svt_role              = PCIE_DEVICE_RC;
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

    // 固化初始的规范物理顺序。运行期修改 enabled/use_svt 后，查询方法
    // 会再次刷新。
    refresh_link_order();
  endfunction

  // Validate all policy before either backend creates children.  In particular,
  // a duplicate static slot is rejected because two logical links cannot safely
  // share one HDL VIF even if only one happens to be active at runtime.
  function void validate(output string errors[$]);
    bit seen_link[string];
    string slot_owner[int unsigned];
    bit seen_bdf[bit [15:0]];

    errors.delete();
    // 即使校验报出其他策略错误，也保持对外的规范数组同步；这样诊断
    // 信息和后续消费者看到的物理槽位视图完全一致。
    refresh_link_order();

    // Validate the graph first; later checks assume its node/link references
    // are internally consistent.
    if (topology == null)
      errors.push_back("topology is null");
    else
      topology.validate(errors);

    // policy 队列可以被刻意打乱，但仍必须与图一一对应。在这里拒绝
    // 缺失/未知 ID 及端点元数据漂移，可防止规范刷新静默压缩物理槽
    // 位、把后面的 adapter 绑到错误的边上。对图中存在的边允许
    // `enabled=0`（槽位保留并按外部/DUT 所有解析）；重新启用权威图里
    // 已禁用的边则不允许。
    if (topology != null) begin
      foreach (topology.links[topology_index]) begin
        pcie_topology_link_cfg graph_link;
        pcie_link_cfg policy_link;

        graph_link = topology.links[topology_index];
        if (graph_link == null)
          continue;
        policy_link = find_link(graph_link.link_id);
        if (policy_link == null) begin
          errors.push_back($sformatf(
            "topology link '%s' has no global link policy",
            graph_link.link_id));
          continue;
        end
        if ((policy_link.upstream_node_id != graph_link.upstream_node_id) ||
            (policy_link.downstream_node_id != graph_link.downstream_node_id) ||
            (policy_link.upstream_role != graph_link.upstream_role) ||
            (policy_link.downstream_role != graph_link.downstream_role) ||
            (policy_link.upstream_port_index != graph_link.upstream_port_index) ||
            (policy_link.downstream_port_index != graph_link.downstream_port_index))
          errors.push_back($sformatf(
            "global link policy '%s' endpoint metadata differs from topology",
            graph_link.link_id));
        if (policy_link.enabled && !graph_link.enabled)
          errors.push_back($sformatf(
            "global link policy '%s' re-enables a disabled topology edge",
            graph_link.link_id));
      end
      foreach (links[policy_index]) begin
        if ((links[policy_index] != null) &&
            (find_topology_link(links[policy_index].link_id) == null))
          errors.push_back($sformatf(
            "global link policy '%s' is absent from topology",
            links[policy_index].link_id));
      end
    end

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

      // SVT 角色是链路级显式策略。没有它时，backend 无法在同一条链路
      // 上区分“SVT RC + DUT EP”和“DUT RC + SVT EP”，必须在 build 前报错。
      if (links[i].use_svt) begin
        if (!links[i].svt_role_valid)
          errors.push_back($sformatf(
            "SVT link '%s' must declare svt_role and svt_node_id",
            links[i].link_id));
        else if (links[i].svt_node_id == "")
          errors.push_back($sformatf(
            "SVT link '%s' has an empty svt_node_id", links[i].link_id));
        else if (!((links[i].svt_role == PCIE_DEVICE_RC) ||
                    (links[i].svt_role == PCIE_DEVICE_EP)))
          errors.push_back($sformatf(
            "SVT link '%s' role must be RC or EP", links[i].link_id));
        else if (topology != null) begin
          pcie_topology_node_cfg svt_node;
          bit is_link_endpoint;

          svt_node = topology.find_node(links[i].svt_node_id);
          if (svt_node == null)
            errors.push_back($sformatf(
              "SVT link '%s' references unknown node '%s'",
              links[i].link_id, links[i].svt_node_id));
          else begin
            is_link_endpoint =
              (links[i].svt_node_id == links[i].upstream_node_id) ||
              (links[i].svt_node_id == links[i].downstream_node_id);
            if (!is_link_endpoint)
              errors.push_back($sformatf(
                "SVT node '%s' is not an endpoint of link '%s'",
                links[i].svt_node_id, links[i].link_id));
            else if (((links[i].svt_role == PCIE_DEVICE_RC) &&
                    (svt_node.kind != PCIE_TOPO_NODE_RC)) ||
                   ((links[i].svt_role == PCIE_DEVICE_EP) &&
                    (svt_node.kind != PCIE_TOPO_NODE_EP)))
              errors.push_back($sformatf(
                "SVT link '%s' role does not match node '%s' kind",
                links[i].link_id, links[i].svt_node_id));
          end
        end
      end

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

    refresh_link_order();
  endfunction
endclass
