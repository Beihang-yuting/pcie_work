# DUT Switch（1 USP + 4 DSP）集成说明（SVT RC + 4×SVT EP，含建链流程）

本文档描述"真实 DUT 是 PCIe Switch：上行 1 个 USP 接 SVT RC，下行 4 个
DSP 各接一个 SVT EP"的完整集成方式。DUT 完成物理转发；TL env 管理全部
端口策略。

对应 `docs/superpowers/specs/2026-09-06-svt-backend-configuration-design.md`
§8 拓扑表第四行：**SVT RC + DUT Switch + 四个 SVT EP → 自动创建
1 RC + 4 EP 共 5 个 SVT agent**。

```text
                SVT RC0
                  │ x16 Serial          link_id: RC0_SW0_USP0   hdl_slot 0
             ┌────┴────┐
             │ DUT SW0 │   （真实 Switch RTL，物理转发）
             └─┬──┬──┬─┬─┘
      x4 Serial│  │  │ │
        SVT EP0  EP1 EP2 EP3
   link_id: SW0_DSP0_EP0 .. SW0_DSP3_EP3    hdl_slot 1..4
```

链路共 5 条：1 条 USP 链 + 4 条 DSP 链。`pcie_topology_builder::
build_switch_1x16_4x4()` 直接生成该拓扑，link_id 为
`RC0_SW0_USP0`、`SW0_DSP0_EP0` … `SW0_DSP3_EP3`。

## 1. 角色与所有权模型

| 实体 | 数量 | 说明 |
|---|---|---|
| 物理链路 | 5 | 1 USP + 4 DSP |
| SVT RC agent | 1 | USP 链上 `svt_role=RC`（SVT 模拟 Root，DUT USP 是对端） |
| SVT EP agent | 4 | 每条 DSP 链上 `svt_role=EP`（SVT 模拟 EP，DUT DSP 是对端） |
| TL agent | 1 RC + 4 EP | 规范角色序号：RC→USP 端口号，EP→DSP 端口号 |
| DUT Switch | 1 | 不创建任何 SVT/TL agent，仅物理转发 |

规范序号规则（`pcie_global_cfg.canonical_link_id`）：Switch 场景
RC 槽位按 USP 端口号、EP 槽位按 DSP 端口号索引——`ep_agents[2]` 恒对应
物理 DSP2，与链路声明顺序无关；策略禁用某条 DSP 也不会让更高端口前移。

## 2. 静态 HDL 顶层

5 个 SVT 单端 HDL agent：1 个 x16 Root + 4 个 x4 Endpoint。

```systemverilog
`timescale 1ns/1fs
module my_switch_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "import_pcie_svt_uvm_pkgs.svi"
  `include `SVC_SOURCE_MAP_SUITE_UTIL_V(pcie_svc,PCIE,latest,svc_util_parms)
  `include `SVC_SOURCE_MAP_SUITE_MODEL_MODULE(pcie_svc,Include,latest,pciesvc_parms)
  `include "pcie_svt_hdl_agent_macros.svh"

  bit reset = 1'b1;
  int unsigned global_random_seed = 0;

  pciesvc_global_shadow #(.DISPLAY_NAME("global_shadow0.")) global_shadow0();

  // slot 0：USP 链的 SVT Root（x16，is_root=1，hierarchy 0）
  `PCIE_SVT_DECLARE_HDL_AGENT_X16(svt_rc0, "SVT_RC0.", 1'b0, 1'b0, reset, 1, 0)

  // slot 1..4：DSP 链的 SVT Endpoint（x4，is_root=0，hierarchy 1..4）
  `PCIE_SVT_DECLARE_HDL_AGENT_X4(svt_ep0, "SVT_EP0.", 1'b0, 1'b0, reset, 0, 1)
  `PCIE_SVT_DECLARE_HDL_AGENT_X4(svt_ep1, "SVT_EP1.", 1'b0, 1'b0, reset, 0, 2)
  `PCIE_SVT_DECLARE_HDL_AGENT_X4(svt_ep2, "SVT_EP2.", 1'b0, 1'b0, reset, 0, 3)
  `PCIE_SVT_DECLARE_HDL_AGENT_X4(svt_ep3, "SVT_EP3.", 1'b0, 1'b0, reset, 0, 4)

  // Serial 连线：
  //   svt_rc0_serial ↔ DUT Switch USP SerDes（x16）
  //   svt_ep<i>_serial ↔ DUT Switch DSP<i> SerDes（x4）
  my_switch_dut u_dut ( /* USP + DSP0..3 SerDes */ );

  // VIF 发布：RC 端 port 4'h0，EP 端 port 4'h1；数字 link_id 0..4 与
  // hdl_slot 一一对应。发布 key：
  //   link_0_vif_0（USP 链 RC 端）
  //   link_1_vif_1 .. link_4_vif_1（DSP 链 EP 端）
  initial begin
    svt_rc0_spd.update_if_variables(4'h0, 8'd0, "uvm_test_top", "uvm_test_top");
    svt_ep0_spd.update_if_variables(4'h1, 8'd1, "uvm_test_top", "uvm_test_top");
    svt_ep1_spd.update_if_variables(4'h1, 8'd2, "uvm_test_top", "uvm_test_top");
    svt_ep2_spd.update_if_variables(4'h1, 8'd3, "uvm_test_top", "uvm_test_top");
    svt_ep3_spd.update_if_variables(4'h1, 8'd4, "uvm_test_top", "uvm_test_top");
  end

  initial begin #200ns; reset = 1'b0; end
  initial run_test("my_switch_test");
endmodule
```

要点：SVT 作 Root 用 port ID `4'h0`，作 Endpoint 用 `4'h1`；
`update_if_variables` 必须在静态 `initial` 块调用。

## 3. 编译宏

```sh
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  +define+PCIE_TOPO_SWITCH_1X16_4X4 \
  user_svt_pkg_prefix.sv \
  -f svt_pcie_integration/sim/pcie_tl_svt_adapter.f \
  my_switch_top.sv my_switch_test.sv
```

| 宏 | 说明 |
|---|---|
| `PCIE_TOPO_SWITCH_1X16_4X4` | 预置拓扑选择：`pcie_svt_hdl_slot_cfg.svh` 据此把 `PCIE_SVT_ENV_MAX_NUM_LINKS` 定为 5 |
| `PCIE_SVT_ENV_MAX_NUM_LINKS=5` | 等价的显式写法，二选一 |
| `EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH` / `SVC_RANDOM_SEED_SCOPE` | 同四链路文档 §3，prefix 文件里定义后 include `svt_pcie.uvm.pkg` |

## 4. UVM 策略配置

```systemverilog
function void build_global_policy();
  pcie_topology_cfg topology;

  // 现成 builder：RC0—SW0(1 USP,4 DSP)—EP0..3，x16/x4，Gen4
  topology = pcie_topology_builder::build_switch_1x16_4x4(4);

  global_cfg = pcie_global_cfg::type_id::create("global_cfg");
  global_cfg.build_default_for_topology(topology);
  global_cfg.backend           = PCIE_BACKEND_SVT_REAL_DUT;
  global_cfg.svt_bridge_enable = 1'b1;
  global_cfg.runtime_num_links = 5;

  // 链路 0 = RC0_SW0_USP0（USP），1..4 = SW0_DSP<i>_EP<i>（DSP）
  foreach (global_cfg.links[i]) begin
    pcie_link_cfg link = global_cfg.links[i];
    bit is_usp = (link.link_id == "RC0_SW0_USP0");

    link.enabled        = 1'b1;
    link.use_svt        = 1'b1;
    link.svt_role_valid = 1'b1;
    // USP 链：SVT 模拟上游 Root；DSP 链：SVT 模拟下游 Endpoint。
    link.svt_role       = is_usp ? PCIE_DEVICE_RC : PCIE_DEVICE_EP;
    link.svt_node_id    = is_usp ? topology.links[i].upstream_node_id
                                 : topology.links[i].downstream_node_id;
    link.has_hdl_slot   = 1'b1;
    link.hdl_slot       = i;   // 与顶层静态实例/数字 link_id 对齐
    // RC 端 vif 后缀 _0，EP 端 _1，与 update_if_variables 的 port 一致
    link.vif_key        = is_usp ? $sformatf("link_%0d_vif_0", i)
                                 : $sformatf("link_%0d_vif_1", i);
  end
endfunction
```

config_db 发布与四链路文档 §4 完全相同（`global_cfg` /
`pcie_svt_backend_cfg` / `pcie_tl_backend_factory` / `cfg` 四个 key，
`tl_cfg.if_mode = SV_IF_MODE`）。backend 自动创建 1 个 SVT RC +
4 个 SVT EP agent，并给 TL env 返回 1 RC + 4 EP 的 adapter。

Switch 特有注意：

- TL env 会开启 Switch 端口管理（`cfg.switch_enable` 由拓扑翻译得出），
  USP manager 槽位始终保留；
- 某条链完全交给外部/DUT 时设 `use_svt=0`：其物理槽位保留为 null、序号
  不压缩，严格 provider 解析会拒绝对它的误访问；
- `ep_agents[i]`/`ep_adapters[i]` 的 `i` 恒等于物理 DSP 端口号。

## 5. 建链（link training）启动流程

5 条链 = 5 次 link_en，全部只启 **SVT 侧**；DUT Switch 两个方向的 LTSSM
（USP 上行口、DSP 下行口）由 DUT RTL 自行训练：

| 链 | SVT 侧启动对象 | 对端（自训练） |
|---|---|---|
| RC0_SW0_USP0 | SVT RC agent 的 `pcie_virt_seqr.dl_seqr` | DUT USP |
| SW0_DSP<i>_EP<i> | 对应 SVT EP agent 的 `pcie_virt_seqr.dl_seqr` | DUT DSP<i> |

```systemverilog
task run_phase(uvm_phase phase);
  pcie_svt_backend svt_be;
  phase.raise_objection(this);

  if (!$cast(svt_be, tl_env.backend_provider))
    `uvm_fatal("LINKUP", "backend provider 不是 pcie_svt_backend")

  #10us;

  // RC 与 4 个 EP 一视同仁：foreach 遍历 backend 的 link->agent 表，
  // 每链启动一次 DL service sequence 并等待 L0。
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

  // 5 条链全部 L0 后，TL 控制面从 Root 侧发起枚举：Config 经 DUT
  // Switch 转发到各 DSP 下的 SVT EP；BAR/Memory 流量同样经 DUT 转发。
  // 下行请求到达 SVT EP 后由 TL EP driver 生成 Completion 返回。
  ...
  phase.drop_objection(this);
endtask
```

与四链路场景的差异：

- 这里 SVT EP 侧也要启动 link_en——因为 DSP 链的 SVT 端是 VIP（四链路
  场景 EP 端是 DUT 才不启动）。判断标准始终是"该端是不是 SVT"，与
  RC/EP 角色无关。
- 枚举/流量路径跨 DUT Switch：USP 链进入 L0 只保证第一跳；四条 DSP 链
  都 L0 后 Config 转发才能到达 EP。超时预算应覆盖 5 条链的训练。

## 6. Host 绑定

单 Root 场景：一个 Host manager 即可，legacy config-db `host_mem` 路径
或 `tl_cfg.bind_host_memory(0, mem)` 均可。Host 数量不影响 5 个 SVT
agent 的创建（Host 只是 memory domain，见四链路文档 §5）。

## 7. 常见错误

| 现象 | 原因 |
|---|---|
| build fatal "缺少 svt_pcie_vif" | DSP 链 `vif_key` 误写 `_vif_0`（EP 端必须 `_vif_1`） |
| EP agent 数量不是 4 | DSP 链 `svt_role` 误设为 RC，或 `use_svt=0` |
| `ep_agents` 序号与物理 DSP 对不上 | 手工按声明顺序索引；应信任规范端口序号（canonical_link_id） |
| USP L0 但枚举读全超时 | DSP 链未启 link_en，Config 无法穿过 Switch 到达 EP |
| build fatal "runtime_num_links 超上限" | 未定义 `PCIE_TOPO_SWITCH_1X16_4X4`（或 MAX_NUM_LINKS=5） |
