//------------------------------------------------------------------------------
// PCIe backend provider neutral contract.
//
// 该文件属于 pcie_tl_pkg，只定义 TL 环境需要的最小后端接口。这里不能
// 出现任何 Synopsys SVT 类型，否则普通 TL-only filelist 会被迫依赖 SVT
// 安装路径。SVT 集成包通过继承本契约提供具体实现。
//------------------------------------------------------------------------------

virtual class pcie_tl_backend_provider extends uvm_object;
    // 后端共享的公共配置。具体 provider 可以保存同一个句柄，但不能
    // 修改 topology 的连接关系；连接关系始终由 pcie_global_cfg 所有。
    pcie_global_cfg    global_cfg;
    pcie_tl_env_config tl_cfg;

    // provider 建立外部 transport 时置位。pcie_tl_env 用该标志选择
    // SV_IF_MODE 并关闭内部 TLM loopback；TL-only provider 保持为 0。
    bit bridge_required;

    // 这些计数表达“provider 实际拥有的物理 transport 方向”，不等同于
    // Host 数量。pcie_tl_env 用它们决定是否创建对应的 TL requester/
    // responder agent；TL agent 仍然是控制面，provider agent 是物理面。
    int unsigned rc_adapter_count;
    int unsigned ep_adapter_count;

    // 物理 link_id 是后端和 TL 环境之间唯一稳定的连接键。role ordinal
    // 只适合表示“已经筛选出的 provider 数组”，不能反向推断物理链路：
    // declaration order、Switch 端口顺序以及 use_svt 稀疏性都可能不同。
    // 因此 provider 在 build_backend() 中必须显式发布这两个关联数组。
    // map 本身保持中性 pcie_tl_if_adapter 类型，TL package 不依赖 SVT。
    protected pcie_tl_if_adapter adapters_by_link[string];
    protected pcie_device_role_e adapter_role_by_link[string];
    protected int unsigned adapter_publish_count_by_link[string];

    // 构造函数：仅透传名字，映射表保持为空。
    function new(string name = "pcie_tl_backend_provider");
        super.new(name);
    endfunction

    // 保存配置句柄的公共入口。build_backend() 会再次调用该方法，方便
    // 用户 provider subclass 在创建 agent 前增加自己的策略处理。
    virtual function void configure(
        pcie_global_cfg global_cfg_arg,
        pcie_tl_env_config tl_cfg_arg);
        global_cfg = global_cfg_arg;
        tl_cfg     = tl_cfg_arg;
        clear_adapter_link_mapping();
    endfunction

    // 清除一次 build 产生的 link map。具体 provider 可以在重建 backend
    // 时调用，也可以依赖 configure() 自动清除；单独提供入口是为了让
    // fake/provider subclass 不必直接触碰 protected associative array。
    virtual function void clear_adapter_link_mapping();
        adapters_by_link.delete();
        adapter_role_by_link.delete();
        adapter_publish_count_by_link.delete();
    endfunction

    // 发布一个物理链路的 adapter。即使 adapter 为 null 也记录该键，令
    // validate_link_adapter_mapping() 报出“缺失 adapter”，而不是把错误
    // 隐藏成少一个 map entry。重复发布同一 link 同样保留计数并在验证时
    // 拒绝，防止后创建的句柄静默覆盖前一个物理连接。
    virtual function void publish_adapter_for_link(
        string link_id,
        pcie_device_role_e role,
        pcie_tl_if_adapter adapter);
        if (!adapter_publish_count_by_link.exists(link_id))
            adapter_publish_count_by_link[link_id] = 0;
        adapter_publish_count_by_link[link_id]++;
        adapters_by_link[link_id] = adapter;
        adapter_role_by_link[link_id] = role;
    endfunction

    // 在 TL agent 创建之前完成 provider 的动态 UVM 对象构建。
    // parent 是 pcie_tl_env，因此 provider 创建的 adapter/agent 都挂在
    // 同一个环境树下，不会形成第二套 PCIe 控制环境。
    pure virtual function bit build_backend(
        uvm_component parent,
        pcie_global_cfg global_cfg_arg,
        pcie_tl_env_config tl_cfg_arg,
        output string errors[$]);

    // provider 只需要为实际存在的角色返回 adapter；TL 环境不关心其
    // 内部是 SVT FULL_VIP、Mapper 还是未来的其他 transport。
    virtual function pcie_tl_if_adapter get_rc_adapter(int index);
        return null;
    endfunction

    // EP 版本的紧凑序号查询；基类默认返回 null，由具体 provider 重写。
    virtual function pcie_tl_if_adapter get_ep_adapter(int index);
        return null;
    endfunction

    // 按权威全局 link ID 解析一个物理 adapter。这里刻意不提供序号/声明
    // 顺序回退：否则稀疏混合 provider 拓扑会把一个有效 adapter 绑到错误
    // 的物理槽位，而所有简单的非空/计数检查仍然通过。
    virtual function pcie_tl_if_adapter get_adapter_for_link(string link_id);
        if (link_id == "")
            return null;
        if (adapters_by_link.exists(link_id))
            return adapters_by_link[link_id];
        return null;
    endfunction

    // 按角色限定的别名让调用点的跨角色误查显式暴露，同时保持单一的
    // 规范 link-ID 解析入口。
    virtual function pcie_tl_if_adapter get_rc_adapter_for_link(string link_id);
        if (adapter_role_by_link.exists(link_id) &&
            (adapter_role_by_link[link_id] == PCIE_DEVICE_RC))
            return get_adapter_for_link(link_id);
        return null;
    endfunction

    // EP 角色版本：link_id 未登记为 EP 时返回 null，不回退到 RC 表。
    virtual function pcie_tl_if_adapter get_ep_adapter_for_link(string link_id);
        if (adapter_role_by_link.exists(link_id) &&
            (adapter_role_by_link[link_id] == PCIE_DEVICE_EP))
            return get_adapter_for_link(link_id);
        return null;
    endfunction

    // 在 pcie_tl_env 开始创建 agent 之前校验 provider 发布的 adapter 集
    // 合。缺失 adapter 是构建错误；静默创建 TL-only 回退会把流量绑到
    // 错误的物理链路上。
    virtual function bit validate_link_adapter_mapping(
        output string errors[$]);
        int expected_rc;
        int expected_ep;
        int mapped_rc;
        int mapped_ep;
        string canonical_ids[$];
        string published_link_ids[$];

        errors.delete();
        expected_rc = 0;
        expected_ep = 0;
        mapped_rc = 0;
        mapped_ep = 0;

        if (global_cfg == null) begin
            errors.push_back("backend provider has no configured global_cfg");
            return 1'b0;
        end

        foreach (global_cfg.links[i]) begin
            pcie_link_cfg link;
            pcie_tl_if_adapter adapter;

            link = global_cfg.links[i];
            if ((link == null) || !link.enabled || !link.use_svt)
                continue;
            if (!link.svt_role_valid ||
                !((link.svt_role == PCIE_DEVICE_RC) ||
                  (link.svt_role == PCIE_DEVICE_EP))) begin
                errors.push_back($sformatf(
                    "link '%s' has no valid provider role", link.link_id));
                continue;
            end

            if (!adapters_by_link.exists(link.link_id)) begin
                errors.push_back($sformatf(
                    "provider has no published adapter for link '%s'",
                    link.link_id));
            end
            else begin
                adapter = adapters_by_link[link.link_id];
                if (adapter == null)
                    errors.push_back($sformatf(
                        "provider has null adapter for link '%s'",
                        link.link_id));
                if (!adapter_role_by_link.exists(link.link_id))
                    errors.push_back($sformatf(
                        "provider has no published role for link '%s'",
                        link.link_id));
                else if (adapter_role_by_link[link.link_id] != link.svt_role)
                    errors.push_back($sformatf(
                        "provider role mismatch for link '%s'", link.link_id));
                if (!adapter_publish_count_by_link.exists(link.link_id) ||
                    (adapter_publish_count_by_link[link.link_id] != 1))
                    errors.push_back($sformatf(
                        "provider published link '%s' %0d times",
                        link.link_id,
                        adapter_publish_count_by_link.exists(link.link_id) ?
                          adapter_publish_count_by_link[link.link_id] : 0));
            end

            if (link.svt_role == PCIE_DEVICE_RC)
                expected_rc++;
            else
                expected_ep++;
        end

        if (get_rc_adapter_count() != expected_rc)
            errors.push_back($sformatf(
                "provider RC adapter count=%0d does not match enabled links=%0d",
                get_rc_adapter_count(), expected_rc));
        if (get_ep_adapter_count() != expected_ep)
            errors.push_back($sformatf(
                "provider EP adapter count=%0d does not match enabled links=%0d",
                get_ep_adapter_count(), expected_ep));

        // 任何映射表项都不得指向已禁用、外部 DUT、未知或其他非法的
        // 策略链路。这堵上反向漏洞：计数恰好一致但某个 adapter 被
        // 静默遗弃。
        foreach (adapters_by_link[map_link_id]) begin
            pcie_link_cfg mapped_link;

            mapped_link = global_cfg.find_link(map_link_id);
            if ((mapped_link == null) || !mapped_link.enabled ||
                !mapped_link.use_svt || !mapped_link.svt_role_valid) begin
                errors.push_back($sformatf(
                    "provider map contains unowned/unknown link '%s'",
                    map_link_id));
                continue;
            end
            if (!((mapped_link.svt_role == PCIE_DEVICE_RC) ||
                  (mapped_link.svt_role == PCIE_DEVICE_EP)))
                errors.push_back($sformatf(
                    "provider map link '%s' has invalid policy role",
                    map_link_id));
            if (!adapter_role_by_link.exists(map_link_id) ||
                (adapter_role_by_link[map_link_id] != mapped_link.svt_role))
                errors.push_back($sformatf(
                    "provider map role does not match policy for link '%s'",
                    map_link_id));
            if (adapters_by_link[map_link_id] == null)
                errors.push_back($sformatf(
                    "provider map contains null adapter for link '%s'",
                    map_link_id));
        end

        // 每条物理 link 必须拥有独立的非空 adapter identity。一个句柄
        // 同时发布给两个 link_id 时，其单一 VIF/codec/agent 绑定无法
        // 表示两条 transport；若只检查计数和 role，交换后的错误会被
        // 静默接受。用句柄相等性做反向检查，null 仍由上面的缺失诊断
        // 处理，不把多个缺失项误报成 alias。
        published_link_ids.delete();
        foreach (adapters_by_link[map_link_id]) begin
            if (adapters_by_link[map_link_id] != null)
                published_link_ids.push_back(map_link_id);
        end
        for (int first_link = 0;
             first_link < published_link_ids.size(); first_link++) begin
            for (int second_link = first_link + 1;
                 second_link < published_link_ids.size(); second_link++) begin
                if (adapters_by_link[published_link_ids[first_link]] ==
                    adapters_by_link[published_link_ids[second_link]])
                    errors.push_back($sformatf(
                        "adapter identity alias: links '%s' and '%s' share one non-null adapter",
                        published_link_ids[first_link],
                        published_link_ids[second_link]));
            end
        end

        // A role map entry without an adapter entry is also an invalid
        // publication. Iterate separately because associative arrays may have
        // intentionally different key sets after a faulty subclass build.
        foreach (adapter_role_by_link[map_link_id]) begin
            if (!adapters_by_link.exists(map_link_id))
                errors.push_back($sformatf(
                    "provider role map has no adapter for link '%s'",
                    map_link_id));
        end

        foreach (adapters_by_link[map_link_id]) begin
            if (adapter_role_by_link.exists(map_link_id)) begin
                if (adapter_role_by_link[map_link_id] == PCIE_DEVICE_RC)
                    mapped_rc++;
                else if (adapter_role_by_link[map_link_id] == PCIE_DEVICE_EP)
                    mapped_ep++;
            end
        end
        if (mapped_rc != expected_rc)
            errors.push_back($sformatf(
                "provider RC map entries=%0d does not match owned links=%0d",
                mapped_rc, expected_rc));
        if (mapped_ep != expected_ep)
            errors.push_back($sformatf(
                "provider EP map entries=%0d does not match owned links=%0d",
                mapped_ep, expected_ep));

        // 紧凑角色数组保留为兼容视图，但其序号顺序要对照规范物理 ID
        // 和映射表句柄身份严格核对。即使每个槽位非空且总数正确，也能
        // 发现被调换的 adapter。
        global_cfg.get_role_link_ids(PCIE_DEVICE_RC, canonical_ids, 1'b1);
        if (canonical_ids.size() != get_rc_adapter_count()) begin
            errors.push_back($sformatf(
                "provider RC packed array size=%0d does not match canonical map size=%0d",
                get_rc_adapter_count(), canonical_ids.size()));
        end
        else begin
            foreach (canonical_ids[i]) begin
                if (get_rc_adapter(i) != get_adapter_for_link(canonical_ids[i]))
                    errors.push_back($sformatf(
                        "provider RC ordinal %0d is not mapped to link '%s'",
                        i, canonical_ids[i]));
            end
        end

        canonical_ids.delete();
        global_cfg.get_role_link_ids(PCIE_DEVICE_EP, canonical_ids, 1'b1);
        if (canonical_ids.size() != get_ep_adapter_count()) begin
            errors.push_back($sformatf(
                "provider EP packed array size=%0d does not match canonical map size=%0d",
                get_ep_adapter_count(), canonical_ids.size()));
        end
        else begin
            foreach (canonical_ids[i]) begin
                if (get_ep_adapter(i) != get_adapter_for_link(canonical_ids[i]))
                    errors.push_back($sformatf(
                        "provider EP ordinal %0d is not mapped to link '%s'",
                        i, canonical_ids[i]));
            end
        end

        return (errors.size() == 0);
    endfunction

    // 返回本 provider 拥有的 RC adapter 数量（build_backend 成功后有效）。
    virtual function int unsigned get_rc_adapter_count();
        return rc_adapter_count;
    endfunction

    // 返回本 provider 拥有的 EP adapter 数量（build_backend 成功后有效）。
    virtual function int unsigned get_ep_adapter_count();
        return ep_adapter_count;
    endfunction
endclass

//------------------------------------------------------------------------------
// Provider factory contract。
//
// pcie_tl_env 通过 config_db 获取该对象。TL-only 路径没有 factory 时完全
// 不创建后端；SVT package 可以发布一个 subclass factory，因而 TL package
// 不需要静态引用 SVT provider 名称。
//------------------------------------------------------------------------------

virtual class pcie_tl_backend_factory extends uvm_object;
    // 构造函数：仅透传名字。
    function new(string name = "pcie_tl_backend_factory");
        super.new(name);
    endfunction

    pure virtual function pcie_tl_backend_provider create_backend(
        string name);
endclass
