//------------------------------------------------------------------------------
// DPU logical domain -> PCIe Root binding.
//
// dpu_common 只定义 Host/Segment 这样的逻辑地址域；Root 编号属于 PCIe
// 物理环境。这个对象把两者显式连接起来，避免根据数组下标或 PF/VF 数量
// 隐式猜测 Root。多 Root 场景必须在创建 TL/SVT child 之前完成校验。
//------------------------------------------------------------------------------

class pcie_dpu_root_binding extends uvm_object;
  `uvm_object_utils(pcie_dpu_root_binding)

  int unsigned host_id;
  int unsigned segment_id;
  int unsigned root_index;

  function new(string name = "pcie_dpu_root_binding");
    super.new(name);
    host_id = 0;
    segment_id = 0;
    root_index = 0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_dpu_root_binding source;

    super.do_copy(rhs);
    if (!$cast(source, rhs)) begin
      `uvm_fatal("DPU_ROOT_COPY", "root binding source has wrong type")
      return;
    end

    host_id = source.host_id;
    segment_id = source.segment_id;
    root_index = source.root_index;
  endfunction
endclass

class pcie_dpu_root_binding_cfg extends uvm_object;
  `uvm_object_utils(pcie_dpu_root_binding_cfg)

  // 动态记录保持物理 Root 数量由实际场景决定，而不是固定写死在 DPU 包中。
  pcie_dpu_root_binding bindings[$];

  function new(string name = "pcie_dpu_root_binding_cfg");
    super.new(name);
    bindings.delete();
  endfunction

  protected function bit same_domain(
      int unsigned lhs_host,
      int unsigned lhs_segment,
      int unsigned rhs_host,
      int unsigned rhs_segment);
    return (lhs_host == rhs_host) && (lhs_segment == rhs_segment);
  endfunction

  // 添加一个显式 Host/Segment -> Root 绑定。
  function bit bind_domain_to_root(
      int unsigned host_id,
      int unsigned segment_id,
      int unsigned root_index,
      inout string why = "");
    pcie_dpu_root_binding record;
    string reason;

    reason = why;
    if (reason == "")
      reason = "explicit PCIe Root binding";

    foreach (bindings[index]) begin
      if (bindings[index] == null)
        continue;
      if (same_domain(bindings[index].host_id, bindings[index].segment_id,
                      host_id, segment_id)) begin
        why = $sformatf(
          "%s: Host%0d/Segment%0d is already bound to Root%0d",
          reason, host_id, segment_id, bindings[index].root_index);
        return 1'b0;
      end
      if (bindings[index].root_index == root_index) begin
        why = $sformatf(
          "%s: Root%0d is already bound to Host%0d/Segment%0d",
          reason, root_index, bindings[index].host_id,
          bindings[index].segment_id);
        return 1'b0;
      end
    end

    record = pcie_dpu_root_binding::type_id::create(
      $sformatf("root_binding_%0d", bindings.size()));
    record.host_id = host_id;
    record.segment_id = segment_id;
    record.root_index = root_index;
    bindings.push_back(record);
    why = "";
    return 1'b1;
  endfunction

  function bit find_root(
      int unsigned host_id,
      int unsigned segment_id,
      output int unsigned root_index);
    root_index = 0;
    foreach (bindings[index]) begin
      if ((bindings[index] != null) &&
          same_domain(bindings[index].host_id, bindings[index].segment_id,
                      host_id, segment_id)) begin
        root_index = bindings[index].root_index;
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  // 只检查记录自身的唯一性和 Root 范围。快照相关的完整性由下方
  // validate_for_snapshot() 进一步检查。
  function void validate(
      int unsigned expected_root_count,
      output string errors[$]);
    bit seen_domain[string];
    bit seen_root[int unsigned];

    errors.delete();
    foreach (bindings[index]) begin
      string domain_name;

      if (bindings[index] == null) begin
        errors.push_back($sformatf("Root binding %0d is null", index));
        continue;
      end
      domain_name = $sformatf("h%0d.s%0d", bindings[index].host_id,
                              bindings[index].segment_id);
      if (seen_domain.exists(domain_name))
        errors.push_back({"duplicate logical domain binding ", domain_name});
      else
        seen_domain[domain_name] = 1'b1;

      if (seen_root.exists(bindings[index].root_index))
        errors.push_back($sformatf("Root%0d is bound more than once",
                                   bindings[index].root_index));
      else
        seen_root[bindings[index].root_index] = 1'b1;

      if ((expected_root_count != 0) &&
          (bindings[index].root_index >= expected_root_count))
        errors.push_back($sformatf(
          "Root%0d exceeds expected Root count %0d",
          bindings[index].root_index, expected_root_count));
    end

    if ((expected_root_count != 0) &&
        (bindings.size() != expected_root_count))
      errors.push_back($sformatf(
        "Root binding count %0d does not match expected Root count %0d",
        bindings.size(), expected_root_count));
  endfunction

  // 根据冻结快照中的函数域检查：每个实际使用的 Host/Segment 都必须有
  // 显式绑定。这样一个 Root 没有绑定时会在 backend child 创建前失败。
  function void validate_for_snapshot(
      dpu_device_snapshot snapshot,
      int unsigned expected_root_count,
      output string errors[$]);
    dpu_function_key_t functions[$];
    bit seen_domain[string];
    string local_errors[$];

    errors.delete();
    validate(expected_root_count, local_errors);
    foreach (local_errors[index])
      errors.push_back(local_errors[index]);

    if ((snapshot == null) || !snapshot.is_frozen()) begin
      errors.push_back("Root binding validation requires a frozen DPU snapshot");
      return;
    end

    snapshot.list_functions(functions);
    foreach (functions[index]) begin
      dpu_pcie_function_id_t pcie_id;
      string why;
      string domain_name;
      int unsigned root_index;

      if (!snapshot.get_pcie_id(functions[index], pcie_id, why)) begin
        errors.push_back({"cannot read snapshot domain: ", why});
        continue;
      end
      domain_name = dpu_pcie_domain_key_name(pcie_id.domain);
      if (seen_domain.exists(domain_name))
        continue;
      seen_domain[domain_name] = 1'b1;
      if (!find_root(pcie_id.domain.host_id, pcie_id.domain.segment_id,
                     root_index))
        errors.push_back({"missing Root binding for domain ", domain_name});
    end

    // Root 数量不要求等于快照中出现的逻辑 domain 数量：一个合法的
    // 拓扑可以保留暂时没有 DPU function 的空 Root。这里仅校验快照中
    // 实际出现的 domain 都有显式绑定；Root 总数/唯一性已由 validate()
    // 检查，避免把空 Root 误报为配置错误。
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_dpu_root_binding_cfg source;
    pcie_dpu_root_binding copy_record;

    super.do_copy(rhs);
    if (!$cast(source, rhs)) begin
      `uvm_fatal("DPU_ROOT_COPY", "root binding cfg source has wrong type")
      return;
    end

    bindings.delete();
    foreach (source.bindings[index]) begin
      if (source.bindings[index] == null) begin
        bindings.push_back(null);
      end else begin
        copy_record = pcie_dpu_root_binding::type_id::create(
          $sformatf("root_binding_copy_%0d", index));
        copy_record.copy(source.bindings[index]);
        bindings.push_back(copy_record);
      end
    end
  endfunction
endclass
