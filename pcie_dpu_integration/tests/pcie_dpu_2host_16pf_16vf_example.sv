//------------------------------------------------------------------------------
// DPU 路线完整控制顺序 example：2 Host × 16 PF × 16 VF。
//
// 该文件属于 pcie_dpu_integration/tests，随 pcie_dpu_example_env.f 编译，
// 依赖 dpu_resource_pkg（dpu-common）、pcie_topology_pkg、pcie_tl_pkg、
// host_mem_pkg 与 pcie_dpu_integration_pkg。
//
// 演示 docs 中"完整控制顺序（DPU 路线）"的 ①~⑤ 步：
//   ① dpu-common authoring：固定 2 Host、每 Host 16 PF、每 PF 16 VF
//      （共 544 个 function），domain 采用 DPU_BAR_PLACEMENT_RANDOM，
//      resolver.resolve() 随机出全部 BAR 基址并冻结 snapshot；
//   ② PCIe 物理声明：每个 DUT Host 是一个物理 EP，VIP 作 RC —— 两条
//      x16 直连链路 RC0↔EP0 / RC1↔EP1；
//   ③ 投影：project_with_root_bindings() 把冻结的 BDF/BAR 复制进
//      pcie_global_cfg，并把两个逻辑域显式绑到 Root0/Root1；
//   ④ Host memory：两个 host_mem manager 按 Root 显式绑定；
//   ⑤ 构建 pcie_tl_env（本例 TL-only 后端，全 passive）。
//
// ⑥（建链/枚举/流量）需要真实 DUT 或 SVT Serial 顶层，不在本纯 class
// 示例中执行；接真实环境时把 global_cfg.backend 换成
// PCIE_BACKEND_SVT_REAL_DUT 并按 docs/pcie_svt_4rc_dut_ep_integration.md
// 补 hdl_slot/vif_key 与 link_en 启动即可，①~⑤ 的代码不变。
//
// run_phase 对投影结果做检查：function 数量、Root 绑定、BAR 按 size
// 对齐，并抽样打印随机基址供人工观察。
//------------------------------------------------------------------------------

`include "uvm_macros.svh"

import uvm_pkg::*;
import dpu_resource_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
import host_mem_pkg::*;
import pcie_dpu_integration_pkg::*;

class pcie_dpu_2host_16pf_16vf_example_test extends uvm_test;
  `uvm_component_utils(pcie_dpu_2host_16pf_16vf_example_test)

  // 规模参数：本示例的需求，全部不超过 dpu-common 模型上限
  // （DPU_MAX_HOSTS=4 / DPU_MAX_PFS_PER_HOST=16 / DPU_MAX_VFS_PER_PF=16）。
  localparam int unsigned NUM_HOSTS   = 2;
  localparam int unsigned PF_PER_HOST = 16;
  localparam int unsigned VF_PER_PF   = 16;

  // ① 的产物：冻结 snapshot；③ 的产物：backend-neutral 全局策略。
  dpu_device_snapshot snapshot;
  pcie_global_cfg     global_cfg;
  pcie_topology_cfg   topology;

  // ⑤ 的产物：TL 环境与其策略。
  pcie_tl_env        tl_env;
  pcie_tl_env_config tl_cfg;

  // ④ 的产物：每个 Root 一个 host memory manager。
  host_mem_manager host_mem[NUM_HOSTS];

  // 构造函数：仅透传参数。
  function new(string name = "pcie_dpu_2host_16pf_16vf_example_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 断言辅助：条件不成立时报 UVM_ERROR。
  function void require(bit condition, string message);
    if (!condition)
      `uvm_error("DPU_EXAMPLE", message)
  endfunction

  // --------------------------------------------------------------------------
  // ① dpu-common authoring + resolve：结构固定、BAR 随机。
  // --------------------------------------------------------------------------

  // 构造一个 function 的 authoring 记录。BDF 交给 resolver 自动分配
  // （DPU_ALLOC_AUTO），三个 BAR 请求尺寸从 caps profile 查询，保证与
  // DUT 能力一致。
  function dpu_function_cfg make_function(
      dpu_dut_caps caps,
      int unsigned host_id,
      int unsigned pf_id,
      dpu_function_kind_e kind,
      int unsigned vf_id);
    dpu_function_cfg function_cfg;
    dpu_bar_request bar;
    dpu_bar_profile_t profile;
    dpu_bar_role_e roles[3] = '{DPU_BAR_DEVICE_MEMORY, DPU_BAR_MAILBOX,
                                DPU_BAR_MSIX};
    string why;

    function_cfg = dpu_function_cfg::type_id::create($sformatf(
      "fn_h%0d_pf%0d_%s%0d", host_id, pf_id,
      (kind == DPU_FUNCTION_PF) ? "pf" : "vf", vf_id));
    function_cfg.key.host_id = host_id;
    function_cfg.key.pf_id = pf_id;
    function_cfg.key.kind = kind;
    function_cfg.key.vf_id = vf_id;
    function_cfg.domain_key.host_id = host_id;
    function_cfg.domain_key.segment_id = host_id;   // 每 Host 一个 segment
    function_cfg.bdf_mode = DPU_ALLOC_AUTO;
    function_cfg.pinned_bdf = '0;

    foreach (roles[r]) begin
      if (!caps.lookup_bar_profile(kind, roles[r], profile, why))
        `uvm_fatal("DPU_EXAMPLE", {"BAR profile 查询失败: ", why})
      bar = dpu_bar_request::type_id::create($sformatf("bar_%0d", r));
      bar.role = roles[r];
      bar.placement = DPU_ALLOC_AUTO;   // 基址交给 resolver 随机分配
      bar.pinned_base = '0;
      bar.even_bar_id = profile.even_bar_id;
      bar.size = profile.size;
      bar.alignment = profile.alignment;
      function_cfg.bars.push_back(bar);
    end
    return function_cfg;
  endfunction

  // 构造一个 Host 的逻辑域：独立 BDF 段 + 独立 4GB MMIO 窗口，并把
  // BAR 放置策略设为 RANDOM——这就是"随机 BAR"的生效点。
  function dpu_host_cfg make_host(int unsigned host_id);
    dpu_host_cfg host;
    dpu_pcie_domain_cfg domain;
    dpu_bdf_range_t bdf_range;
    dpu_mmio_window_cfg window;

    host = dpu_host_cfg::type_id::create($sformatf("host_%0d", host_id));
    host.host_id = host_id;

    domain = dpu_pcie_domain_cfg::type_id::create(
      $sformatf("domain_%0d", host_id));
    domain.key.host_id = host_id;
    domain.key.segment_id = host_id;

    // 每 Host 272 个 function（16 PF + 256 VF）。当前投影校验按全局
    // BDF 去重（未按 domain 区分），因此两个 Host 使用互不重叠的 BDF
    // 段：Host0 0x0100~0x07FF，Host1 0x0800~0x0FFF。
    bdf_range.first_bdf = 16'h0100 + host_id * 16'h0700;
    bdf_range.last_bdf  = bdf_range.first_bdf + 16'h06FF;
    domain.bdf_ranges.push_back(bdf_range);

    // 随机放置的碎片化约束：resolver 按 function 顺序放置（不按 size
    // 降序），随机撒下的 16KB VF BAR 会击穿 32MB 对齐槽位。因此
    // DEVICE_MEMORY 独占一个 64GB 大窗口（2048 个 32MB 槽，272 个小
    // BAR 最多打穿 272 个，first-fit 兜底必然成功），MAILBOX/MSIX 的
    // 小 BAR 另开 1GB 窗口，互不干扰。两 Host 的窗口区间不重叠。
    window = dpu_mmio_window_cfg::type_id::create(
      $sformatf("window_devmem_%0d", host_id));
    window.base  = 64'h0000_0100_0000_0000 +
                   host_id * 64'h0000_0100_0000_0000;
    window.limit = window.base + 64'h0000_0010_0000_0000;   // 64GB
    window.allowed_roles.push_back(DPU_BAR_DEVICE_MEMORY);
    domain.mmio_windows.push_back(window);

    window = dpu_mmio_window_cfg::type_id::create(
      $sformatf("window_small_%0d", host_id));
    window.base  = 64'h0000_0010_0000_0000 +
                   host_id * 64'h0000_0010_0000_0000;
    window.limit = window.base + 64'h0000_0000_4000_0000;   // 1GB
    window.allowed_roles.push_back(DPU_BAR_MAILBOX);
    window.allowed_roles.push_back(DPU_BAR_MSIX);
    domain.mmio_windows.push_back(window);

    // 随机 BAR 放置：resolver 用 UVM 随机流挑基址，保留全部对齐/窗口/
    // 同域防重叠约束。换成 DPU_BAR_PLACEMENT_FIRST_FIT 即得确定性布局。
    domain.bar_placement_policy = DPU_BAR_PLACEMENT_RANDOM;

    host.pcie_domains.push_back(domain);
    return host;
  endfunction

  // 组装完整 authoring 配置并 resolve 成冻结 snapshot。结构（Host/PF/
  // VF 数量）在这里固定；BAR 基址由 resolver 随机产生后随 snapshot 一
  // 起冻结，后端只能只读消费。
  function void build_frozen_snapshot();
    dpu_device_cfg cfg;
    dpu_device_resolver resolver;
    dpu_dut_caps caps;
    string why;

    cfg = dpu_device_cfg::type_id::create("authoring_cfg");

    // DUT 能力：显式放宽 PF 上限到 16（默认 4），其余沿用默认 profile。
    caps = dpu_dut_caps::type_id::create("caps");
    caps.max_hosts = NUM_HOSTS;
    caps.max_pfs_per_host = PF_PER_HOST;
    caps.max_vfs_per_pf = VF_PER_PF;
    cfg.dut_caps = caps;

    for (int unsigned h = 0; h < NUM_HOSTS; h++) begin
      cfg.hosts.push_back(make_host(h));
      for (int unsigned pf = 0; pf < PF_PER_HOST; pf++) begin
        cfg.functions.push_back(
          make_function(caps, h, pf, DPU_FUNCTION_PF, 0));
        for (int unsigned vf = 0; vf < VF_PER_PF; vf++)
          cfg.functions.push_back(
            make_function(caps, h, pf, DPU_FUNCTION_VF, vf));
      end
    end

    // AF（管理 function）选 Host0 PF0。
    cfg.af_request.mode = DPU_AF_SELECTED;
    cfg.af_request.requester.host_id = 0;
    cfg.af_request.requester.pf_id = 0;
    cfg.af_request.requester.kind = DPU_FUNCTION_PF;
    cfg.af_request.requester.vf_id = 0;

    resolver = dpu_device_resolver::type_id::create("resolver");
    if (!resolver.resolve(cfg, snapshot, why))
      `uvm_fatal("DPU_EXAMPLE", {"resolver 失败: ", why})
    require(snapshot.is_frozen(), "snapshot 未冻结");
  endfunction

  // --------------------------------------------------------------------------
  // ② PCIe 物理拓扑：每个 DUT Host 是一个物理 EP，VIP 作 RC。
  // --------------------------------------------------------------------------

  // 两条独立 x16 链：RC<h> ↔ EP<h>。DUT 侧（EP）在真实集成时接 RTL；
  // 本 TL-only 示例不涉及物理连线。
  function void build_topology();
    pcie_topology_builder builder;

    builder = pcie_topology_builder::type_id::create("example_builder");
    for (int unsigned h = 0; h < NUM_HOSTS; h++) begin
      void'(builder.add_rc($sformatf("RC%0d", h)));
      void'(builder.add_ep($sformatf("EP%0d", h)));
      void'(builder.connect($sformatf("RC%0d_EP%0d", h, h),
        $sformatf("RC%0d", h), PCIE_TOPO_PORT_RC, 0,
        $sformatf("EP%0d", h), PCIE_TOPO_PORT_EP, 0, 16, 4));
    end
    topology = builder.finish();
  endfunction

  // --------------------------------------------------------------------------
  // ③ 投影：物理 attachment + 逻辑域到 Root 的显式绑定。
  // --------------------------------------------------------------------------

  // 每个 function 挂到其 Host 对应的物理 EP/链路；两个逻辑域分别绑
  // Root0/Root1。BDF/BAR 全部照抄冻结值，adapter 不做任何分配。
  function void project_policy();
    pcie_dpu_cfg_adapter adapter;
    pcie_dpu_attachment_cfg attachments;
    pcie_dpu_root_binding_cfg root_bindings;
    dpu_function_key_t functions[$];
    string errors[$];
    string why;

    adapter = pcie_dpu_cfg_adapter::type_id::create("adapter");
    attachments = pcie_dpu_attachment_cfg::type_id::create("attachments");
    root_bindings = pcie_dpu_root_binding_cfg::type_id::create(
      "root_bindings");

    snapshot.list_functions(functions);
    foreach (functions[i]) begin
      if (!attachments.add(functions[i],
                           $sformatf("EP%0d", functions[i].host_id),
                           $sformatf("RC%0d_EP%0d", functions[i].host_id,
                                     functions[i].host_id),
                           1'b0, 0, why))
        `uvm_fatal("DPU_EXAMPLE", {"attachment 失败: ", why})
    end

    for (int unsigned h = 0; h < NUM_HOSTS; h++) begin
      if (!root_bindings.bind_domain_to_root(h, h, h, why))
        `uvm_fatal("DPU_EXAMPLE", {"Root 绑定失败: ", why})
    end

    if (!adapter.project_with_root_bindings(
          snapshot, null, topology, attachments, root_bindings,
          global_cfg, errors)) begin
      foreach (errors[i])
        `uvm_error("DPU_EXAMPLE", errors[i])
      `uvm_fatal("DPU_EXAMPLE", "snapshot 投影失败")
    end
    require(errors.size() == 0, "投影返回诊断");
  endfunction

  // --------------------------------------------------------------------------
  // ④⑤ Host memory 绑定 + TL 环境构建。
  // --------------------------------------------------------------------------

  // 本例 TL-only：backend 保持 PCIE_BACKEND_TL_ONLY、全 passive。接真实
  // DUT 时改 backend=PCIE_BACKEND_SVT_REAL_DUT，并给每条链补
  // use_svt/svt_role=RC/hdl_slot/vif_key（见集成文档），其余步骤不变。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    build_frozen_snapshot();      // ①
    build_topology();             // ②
    project_policy();             // ③

    // ④ 每个 Root 一个独立 host memory manager（默认 HOST_MEM_RANDOM
    // 随机地址分配），显式绑定；多 Root 环境必须逐个绑定。
    tl_cfg = pcie_tl_env_config::type_id::create("example_tl_cfg");
    tl_cfg.if_mode = TLM_MODE;
    tl_cfg.rc_is_active = UVM_PASSIVE;
    tl_cfg.ep_is_active = UVM_PASSIVE;
    tl_cfg.fc_enable = 1'b0;
    tl_cfg.scb_enable = 1'b0;
    tl_cfg.cov_enable = 1'b0;
    tl_cfg.use_unified_mem = 1'b0;
    for (int unsigned h = 0; h < NUM_HOSTS; h++) begin
      string bind_why;
      host_mem[h] = new($sformatf("host_mem_%0d", h));
      host_mem[h].set_host_id(h);   // 绑定校验要求 manager 自报同一 host
      host_mem[h].init_region(64'h0000_0000_8000_0000 * (h + 1),
                              64'h0000_0000_8000_0000 * (h + 1) +
                              64'h0000_0000_00FF_FFFF,
                              MODE_LINEAR, 1, 8'h00);
      if (!tl_cfg.bind_host_memory(h, h, host_mem[h], bind_why))
        `uvm_fatal("DPU_EXAMPLE", {"host memory 绑定失败: ", bind_why})
    end

    // ⑤ 发布策略并构建 TL 环境。global_cfg 携带 544 条 device 记录与
    // 两条物理链；TL-only 模式下不创建任何 SVT 对象。
    uvm_config_db#(pcie_global_cfg)::set(
      this, "tl_env", "global_cfg", global_cfg);
    uvm_config_db#(pcie_tl_env_config)::set(
      this, "tl_env", "tl_policy_cfg", tl_cfg);
    tl_env = pcie_tl_env::type_id::create("tl_env", this);
  endfunction

  // --------------------------------------------------------------------------
  // 投影结果检查 + 随机 BAR 抽样打印。
  // --------------------------------------------------------------------------

  // 判断字符串是否包含子串（标准 SV 无 contains，手写线性扫描）。
  function bit str_contains(string haystack, string needle);
    if (needle.len() == 0 || haystack.len() < needle.len())
      return 1'b0;
    for (int i = 0; i + needle.len() <= haystack.len(); i++) begin
      if (haystack.substr(i, i + needle.len() - 1) == needle)
        return 1'b1;
    end
    return 1'b0;
  endfunction

  task run_phase(uvm_phase phase);
    int unsigned pf_count[NUM_HOSTS];
    int unsigned vf_count[NUM_HOSTS];
    int unsigned printed;
    int unsigned expected_total;

    phase.raise_objection(this);

    expected_total = NUM_HOSTS * PF_PER_HOST * (1 + VF_PER_PF);

    // 数量：2 个 RC 节点记录 + 544 个 DPU function 记录。
    require(global_cfg.devices.size() == NUM_HOSTS + expected_total,
            $sformatf("device 记录数=%0d 预期=%0d",
                      global_cfg.devices.size(),
                      NUM_HOSTS + expected_total));

    foreach (global_cfg.devices[i]) begin
      pcie_device_cfg dev = global_cfg.devices[i];
      if ((dev == null) || (dev.role != PCIE_DEVICE_EP) ||
          (dev.function_key_name == ""))
        continue;

      // Root 绑定：host_id 域必须落到同号 Root。
      require(dev.root_index_valid &&
              (dev.root_index == dev.domain_host_id),
              $sformatf("%s Root 绑定错误", dev.device_id));

      // 用 key 编码里的 ".k1." 判定 VF：dpu_function_key_name 格式为
      // "h<id>.pf<id>.k<kind>.vf<id>"，kind=1 即 DPU_FUNCTION_VF。
      if (str_contains(dev.function_key_name, ".k1."))
        vf_count[dev.domain_host_id]++;
      else
        pf_count[dev.domain_host_id]++;

      // BAR 按 size 对齐（随机放置的硬约束之一）。
      foreach (dev.bars[b]) begin
        pcie_unified_bar_cfg bar = dev.bars[b];
        if ((bar == null) || (bar.aperture == 0))
          continue;
        require((bar.initial_base % bar.aperture) == 0,
                $sformatf("%s BAR%0d base=0x%016h 未按 size 对齐",
                          dev.device_id, b, bar.initial_base));
      end

      // 抽样打印前几个 function 的随机 BAR，肉眼确认随机效果。
      if (printed < 6) begin
        printed++;
        `uvm_info("DPU_EXAMPLE", $sformatf(
          "%s host=%0d bdf=0x%04h BAR0=0x%016h BAR2=0x%016h BAR4=0x%016h",
          dev.function_key_name, dev.domain_host_id, dev.bdf,
          (dev.bars[0] != null) ? dev.bars[0].initial_base : 64'h0,
          (dev.bars[2] != null) ? dev.bars[2].initial_base : 64'h0,
          (dev.bars[4] != null) ? dev.bars[4].initial_base : 64'h0),
          UVM_LOW)
      end
    end

    for (int unsigned h = 0; h < NUM_HOSTS; h++) begin
      require((pf_count[h] + vf_count[h]) ==
                PF_PER_HOST * (1 + VF_PER_PF),
              $sformatf("Host%0d function 数=%0d 预期=%0d",
                        h, pf_count[h] + vf_count[h],
                        PF_PER_HOST * (1 + VF_PER_PF)));
    end

    require(tl_env != null, "TL env 未创建");

    `uvm_info("DPU_EXAMPLE", $sformatf(
      "DPU 路线 ①~⑤ 完成：%0d Host × %0d PF × %0d VF，共 %0d function",
      NUM_HOSTS, PF_PER_HOST, VF_PER_PF, expected_total), UVM_NONE)

    phase.drop_objection(this);
  endtask
endclass
