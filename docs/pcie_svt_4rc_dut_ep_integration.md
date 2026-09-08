# 四链路 SVT RC + DUT EP 集成说明（含多 Host 绑定与建链流程）

本文档描述"四条独立物理链路，每条链路 SVT VIP 模拟 Root Complex、对端为
真实 DUT Endpoint"的完整集成方式，覆盖静态 HDL 顶层、编译宏、UVM 策略
配置、Host memory 绑定和链路训练（link training）启动流程。

对应 `docs/superpowers/specs/2026-09-06-svt-backend-configuration-design.md`
§8 拓扑表第二行：**四条独立 DUT EP 链路 → 自动创建 4 个 SVT RC agent，
DUT EP 侧不创建任何 SVT agent**。

```text
SVT RC0 ──x4 Serial── DUT EP0        link_id: RC0_EP0   hdl_slot 0
SVT RC1 ──x4 Serial── DUT EP1        link_id: RC1_EP1   hdl_slot 1
SVT RC2 ──x4 Serial── DUT EP2        link_id: RC2_EP2   hdl_slot 2
SVT RC3 ──x4 Serial── DUT EP3        link_id: RC3_EP3   hdl_slot 3
```

## 1. 角色与所有权模型

| 实体 | 数量 | 说明 |
|---|---|---|
| 物理链路 | 4 | agent 创建的唯一驱动来源（不是 Host 数量） |
| SVT RC agent | 4 | 由 `pcie_svt_backend` 按 `enabled && use_svt` 链路自动创建 |
| SVT EP agent | 0 | 对端是真实 DUT，`svt_role=RC` 表示 SVT 只模拟 RC 端 |
| TL RC agent | 4 | `pcie_tl_env` 按 provider 返回的 RC 计数创建 |
| Host memory manager | 1~4 | 纯内存域对象，与链路解耦，见 §5 |

## 2. 静态 HDL 顶层

每条链路一个 SVT 单端 HDL agent，使用
`svt_pcie_integration/rtl/pcie_svt_hdl_agent_macros.svh` 中的
`PCIE_SVT_DECLARE_HDL_AGENT_X4/X8/X16` 宏（按 lane 宽度选择）：

```systemverilog
`timescale 1ns/1fs
module my_4rc_dut_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "import_pcie_svt_uvm_pkgs.svi"
  `include `SVC_SOURCE_MAP_SUITE_UTIL_V(pcie_svc,PCIE,latest,svc_util_parms)
  `include `SVC_SOURCE_MAP_SUITE_MODEL_MODULE(pcie_svc,Include,latest,pciesvc_parms)
  `include "pcie_svt_hdl_agent_macros.svh"

  bit reset = 1'b1;
  int unsigned global_random_seed = 0;

  // 全局 shadow；EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH 必须指向它
  pciesvc_global_shadow #(.DISPLAY_NAME("global_shadow0.")) global_shadow0();

  // 4 个 SVT RC HDL slot。宏参数依次为：
  //   instance_name, display_name, clkreq, wake, reset, is_root, hierarchy
  // is_root=1 表示 SVT 侧是 Root；hierarchy 每实例必须唯一。
  // 展开产物：<name>_if（svt_pcie_if）、<name>_spd（HDL agent）、
  //           <name>_serial（pcie_svt_serial_port_if，接 DUT SerDes）
  `PCIE_SVT_DECLARE_HDL_AGENT_X4(svt_rc0, "SVT_RC0.", 1'b0, 1'b0, reset, 1, 0)
  `PCIE_SVT_DECLARE_HDL_AGENT_X4(svt_rc1, "SVT_RC1.", 1'b0, 1'b0, reset, 1, 1)
  `PCIE_SVT_DECLARE_HDL_AGENT_X4(svt_rc2, "SVT_RC2.", 1'b0, 1'b0, reset, 1, 2)
  `PCIE_SVT_DECLARE_HDL_AGENT_X4(svt_rc3, "SVT_RC3.", 1'b0, 1'b0, reset, 1, 3)

  // Serial 物理连线：svt_rc<i>_serial 的 tx/rx 接 DUT 第 i 个 EP SerDes
  my_dut u_dut ( /* EP0..EP3 SerDes ↔ svt_rc0..3_serial */ );

  // 每个静态 HDL agent 必须在静态 initial 块调用官方 update_if_variables，
  // 不能从 UVM class/function 调用。RC 端使用 port ID 4'h0；第二个参数
  // 是数字 link_id，发布的 config-DB key 为 link_<link_id>_vif_0。
  initial begin
    svt_rc0_spd.update_if_variables(4'h0, 8'd0, "uvm_test_top", "uvm_test_top");
    svt_rc1_spd.update_if_variables(4'h0, 8'd1, "uvm_test_top", "uvm_test_top");
    svt_rc2_spd.update_if_variables(4'h0, 8'd2, "uvm_test_top", "uvm_test_top");
    svt_rc3_spd.update_if_variables(4'h0, 8'd3, "uvm_test_top", "uvm_test_top");
  end
  // → 发布 link_0_vif_0 / link_1_vif_0 / link_2_vif_0 / link_3_vif_0

  initial begin #200ns; reset = 1'b0; end
  initial run_test("my_4rc_test");
endmodule
```

## 3. 编译宏与 filelist 顺序

```text
# user_svt_pkg_prefix.sv —— 必须排在 -f 列表之前：
`define EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH my_4rc_dut_top.global_shadow0
`define SVC_RANDOM_SEED_SCOPE               my_4rc_dut_top.global_random_seed
`include "svt_pcie.uvm.pkg"
```

```sh
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  +define+PCIE_SVT_ENV_MAX_NUM_LINKS=4 \
  user_svt_pkg_prefix.sv \
  -f svt_pcie_integration/sim/pcie_tl_svt_adapter.f \
  my_4rc_dut_top.sv my_4rc_test.sv
```

宏说明：

| 宏 | 作用 | 本场景取值 |
|---|---|---|
| `PCIE_SVT_ENV_MAX_NUM_LINKS` | 静态 HDL slot 上限；`runtime_num_links` 超过它会在 build 校验失败 | 4（默认是 1，必须显式给出） |
| `EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH` | 官方 package 需要的全局 shadow 实例路径 | 用户顶层的 `global_shadow0` |
| `SVC_RANDOM_SEED_SCOPE` | 官方 package 的随机种子作用域 | 用户顶层的 `global_random_seed` |
| `PCIE_SVT_DECLARE_HDL_AGENT_X4/X8/X16` | 展开一组 svt_pcie_if + HDL agent + Serial 端口 | 每链一次，is_root=1 |

## 4. UVM 策略配置（自动 backend）

构建链：`global_cfg → pcie_tl_env → pcie_tl_backend_factory
→ pcie_svt_backend → 4× svt_pcie_device_agent`。test 不手工创建任何
SVT agent/config/status。

```systemverilog
function void build_global_policy();
  pcie_topology_builder builder;
  pcie_topology_cfg topology;

  builder = pcie_topology_builder::type_id::create("b");
  for (int i = 0; i < 4; i++) begin
    void'(builder.add_rc($sformatf("RC%0d", i)));
    void'(builder.add_ep($sformatf("EP%0d", i)));
    void'(builder.connect($sformatf("RC%0d_EP%0d", i, i),
      $sformatf("RC%0d", i), PCIE_TOPO_PORT_RC, 0,
      $sformatf("EP%0d", i), PCIE_TOPO_PORT_EP, 0, 4, 4));  // x4, Gen4
  end
  topology = builder.finish();

  global_cfg = pcie_global_cfg::type_id::create("global_cfg");
  global_cfg.build_default_for_topology(topology);
  global_cfg.backend           = PCIE_BACKEND_SVT_REAL_DUT;
  global_cfg.svt_bridge_enable = 1'b1;
  global_cfg.runtime_num_links = 4;

  foreach (global_cfg.links[i]) begin
    pcie_link_cfg link = global_cfg.links[i];
    link.enabled        = 1'b1;
    link.use_svt        = 1'b1;
    link.svt_role_valid = 1'b1;
    link.svt_role       = PCIE_DEVICE_RC;      // SVT 只模拟 RC 端
    link.svt_node_id    = topology.links[i].upstream_node_id;
    link.has_hdl_slot   = 1'b1;
    link.hdl_slot       = i;                   // 对应静态实例 svt_rc<i>
    link.vif_key        = $sformatf("link_%0d_vif_0", i);
  end
endfunction

function void build_phase(uvm_phase phase);
  super.build_phase(phase);
  build_global_policy();

  svt_backend_cfg = pcie_svt_backend_cfg::type_id::create("svt_cfg");
  svt_backend_cfg.init_defaults();              // SERIAL + FULL_VIP
  svt_backend_cfg.enable_shadow_cfg_lookup = 1'b0;

  backend_factory = pcie_svt_backend_factory::type_id::create("factory");

  tl_cfg = pcie_tl_env_config::type_id::create("tl_cfg");
  tl_cfg.if_mode = SV_IF_MODE;
  // num_rc/num_ep 由 provider 计数覆盖，无需手填

  uvm_config_db#(pcie_global_cfg)::set(this, "tl_env", "global_cfg", global_cfg);
  uvm_config_db#(pcie_svt_backend_cfg)::set(this, "tl_env",
    "pcie_svt_backend_cfg", svt_backend_cfg);
  uvm_config_db#(pcie_tl_backend_factory)::set(this, "tl_env",
    "pcie_tl_backend_factory", backend_factory);
  uvm_config_db#(pcie_tl_env_config)::set(this, "tl_env", "cfg", tl_cfg);

  tl_env = pcie_tl_env::type_id::create("tl_env", this);
endfunction
```

关键约束（build 阶段 fatal，不静默降级）：

- `vif_key` 必须与 HDL `update_if_variables` 发布的 key 逐字符一致；
- 每条启用的 SVT 链路必须 `has_hdl_slot=1` 且 slot 唯一；
- transport 只支持 SERIAL；PIPE 会被 `validate()` 拒绝；
- Gen 只支持 4/5，EQ mode 0~3（0 = 自动策略）。

### 每链差异化（可选）

```systemverilog
pcie_svt_link_override_cfg ov =
  pcie_svt_link_override_cfg::type_id::create("ov");
ov.has_max_gen = 1'b1;  ov.max_gen = 5;          // 让第 2 条链跑 Gen5
svt_backend_cfg.link_override["RC2_EP2"] = ov;    // key 是 link_id
```

## 5. Host memory 绑定（"四 Host"部分）

Host 只是 memory domain，不携带任何链路属性；链路/agent 数量永远由物理
link 决定，与 Host 数量无关（回归 `pcie_tl_backend_provider_unit_test`
用 Host1/Host4 变体固定验证这一点）。

四 Root 场景两种典型绑定，多 Root 环境必须为**每个 Root 显式**绑定：

```systemverilog
// 方式 A：四 Host —— 每个 Root 一个独立 manager
host_mem_manager host_mem[4];
foreach (host_mem[i]) begin
  host_mem[i] = new($sformatf("host_mem_%0d", i));
  void'(tl_cfg.bind_host_memory(i, host_mem[i]));
end

// 方式 B：单 Host —— 四个 Root 共享一个 manager
host_mem_manager shared_mem = new("shared_host_mem");
for (int i = 0; i < 4; i++)
  void'(tl_cfg.bind_host_memory(i, shared_mem));
```

规则（`pcie_tl_env_config.validate_host_memory_bindings`）：

- 一旦使用 `host_mem_by_root`，绑定数必须等于 Root 数，缺一个即报错；
- 共享 manager 允许（多个 Root 指向同一句柄），PREMAP backing memory 对
  同一 manager 只初始化一次，不会重复分配；
- 只有单 Root 旧路径允许从 config-db `host_mem` key 隐式获取。

## 6. 建链（link training）启动流程

backend 只负责 agent 创建前的链路配置（速率/宽度/EQ 通过官方
`set_link_speed_values` / `set_link_width_values` /
`set_link_eq_attribute_values` 生效），**不会自动启动链路训练**。
训练由 test 在 `run_phase` 显式启动：

1. 只启动 SVT RC 侧的 DL service sequence——DUT EP 是真实 RTL，其 LTSSM
   自行训练；
2. 每条链一个 `svt_pcie_dl_service_set_link_en_sequence`（enable=1），
   跑在该链 SVT agent 的 `pcie_virt_seqr.dl_seqr` 上；
3. 等待该链 status 进入 L0，四条链并行，统一超时兜底。

```systemverilog
task run_phase(uvm_phase phase);
  pcie_svt_backend svt_be;
  phase.raise_objection(this);

  // env 持有中性 provider 句柄；downcast 拿 SVT 的 link->agent/status 表
  if (!$cast(svt_be, tl_env.backend_provider))
    `uvm_fatal("LINKUP", "backend provider 不是 pcie_svt_backend")

  #10us;   // 等 Serial HDL model 出复位

  foreach (svt_be.svt_agent_by_link[link_id]) begin
    automatic string id = link_id;
    fork begin
      svt_pcie_dl_service_set_link_en_sequence en;
      en = svt_pcie_dl_service_set_link_en_sequence::type_id::create(
        {"link_en_", id});
      en.enable = 1'b1;
      en.start(svt_be.svt_agent_by_link[id].pcie_virt_seqr.dl_seqr);

      wait (svt_be.svt_status_by_link[id]
              .pcie_status.pl_status.link_up == 1'b1);
      wait (svt_be.svt_status_by_link[id]
              .pcie_status.pl_status.ltssm_state == svt_pcie_types::L0);
      `uvm_info("LINKUP", {id, " 进入 L0"}, UVM_LOW)
    end join_none
  end

  fork
    wait fork;
    begin #500us; `uvm_fatal("LINKUP", "Serial link-up 超时") end
  join_any

  // L0 之后 TL 控制面接管：Config/BAR 枚举/Memory 全部由 TL sequence
  // 从对应 Root 的 sequencer 发起（按 Root，不按 Host）。
  // 例：tl_env.v_seqr.rc_seqr（单 Root 别名）或 per-Root sequencer。
  ...
  phase.drop_objection(this);
endtask
```

要点：

- **是否每个 Host 都启动？不是。** 建链按物理 link 逐条启动（本场景 4
  次），Host 从不参与建链；无链路的 Host 只创建内存对象。
- 多 Host 绑同一批 Root 不改变启动次数；共享 Host manager 也只初始化
  一次。
- `svt_agent_by_link` / `svt_status_by_link` 是 `pcie_svt_backend` 的公开
  关联数组（以 link_id 为 key），即诊断/建链的权威入口；不要按序号猜。

## 7. 常见错误

| 现象 | 原因 |
|---|---|
| build fatal "缺少 svt_pcie_vif" | `vif_key` 与 `update_if_variables` 发布的 key 不一致 |
| build fatal "runtime_num_links 超上限" | 未加 `+define+PCIE_SVT_ENV_MAX_NUM_LINKS=4` |
| 链路一直不进 L0 | 忘记启动 RC 侧 link_en，或 DUT 侧复位/时钟未释放 |
| 只有一条链建起来 | `update_if_variables` 的数字 link_id 重复或与 hdl_slot 不对应 |
| host memory 校验失败 | 多 Root 下只绑了部分 Root 的 manager |
