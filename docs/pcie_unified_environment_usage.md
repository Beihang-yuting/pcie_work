# PCIe environment usage

## Single control plane

`pcie_tl_env` is the only production PCIe environment.  It owns topology,
configuration-space images, BAR allocation, BDF assignment, enumeration,
completions, Memory traffic, and all project sequences.  Existing users may
continue to instantiate `pcie_tl_env` directly.  Graph-driven users publish a
`pcie_topology_cfg` plus an optional policy object before creating the same
`pcie_tl_env`; the environment performs the translation before it creates any
agent.

```text
pcie_tl_env
        |
        +-- pcie_tl_if_adapter                 (TL-only default)
        |
        +-- pcie_svt_if_adapter                (optional SVT transport)
                    |
                    +-- official svt_pcie_device_agent.tlp_mapper
                    +-- Serial/PIPE adapter supplied by the user top
```

SVT is not a second configuration or traffic environment.  The optional
adapter is selected only in a dedicated SVT filelist and does not alter the
TL-only package or existing tests.

## TL-only example

```systemverilog
pcie_tl_env_config cfg;
cfg = pcie_tl_env_config::type_id::create("cfg");
cfg.if_mode = TLM_MODE;
cfg.rc_agent_enable = 1'b1;
cfg.ep_agent_enable = 1'b1;
uvm_config_db#(pcie_tl_env_config)::set(this, "env", "cfg", cfg);
env = pcie_tl_env::type_id::create("env", this);
```

For graph-driven topologies, publish `pcie_topology_cfg` and an optional
`pcie_tl_env_config` policy under `env`, then instantiate `pcie_tl_env`.  The
same environment validates and translates the graph once before creating its
native agents.  Native `cfg` injection remains valid when no graph is supplied.

## Optional SVT adapter

将 `svt_pcie_integration/sim/pcie_tl_svt_adapter.f` 作为 source-only 基础
filelist 引入用户工程，并在创建 `env` 前安装 factory override：

```systemverilog
pcie_tl_if_adapter::type_id::set_type_override(
  pcie_svt_if_adapter::get_type());
```

用户顶层必须创建官方 SVT device agent，并将每个 agent 发布到
the matching adapter instance with the `svt_agent` config-DB key.  The Mapper
must be the handle from `svt_pcie_device_agent.tlp_mapper`; creating an
isolated `svt_pcie_tlp_mapper` is unsupported because it has no service
sequencer.  Serial lane wiring, clocks, resets, and DUT connections remain a
top-level responsibility.

该 source-only filelist 不包含可独立运行的占位 test/top；用户必须追加自己
的 DUT top、SVT HDL agent、Serial/PIPE 物理连接和 test。桥接层不会自动启动
SVT 配置或 traffic sequence。TL sequence 仍然是 Config/BAR/enum/Memory
请求的唯一来源，SVT 只提供 transport endpoint。

## DPU-common integration

`pcie_dpu_integration` is optional and independent.  Its generic package
consumes frozen `dpu-common` snapshots and projects device/BAR/BDF data into
the native TL policy.  It does not import SVT packages, so the TL/DPU
filelists remain usable without a Synopsys installation.  A project-specific
system environment can apply that projected policy before constructing the
same `pcie_tl_env`; no unified or backend-selection environment is required.

`dpu_common` 只描述逻辑 Host、Segment、PF/VF、BDF 和 BAR。Host 不是 RC、EP
或 Switch，也不携带 Root/link 属性；这些物理关系必须在 `pcie_work` 侧
显式声明。这样同一份 DPU snapshot 可以被 TL-only、SVT Serial 或后续 PIPE
后端复用，而不会把 PCIe 物理假设反向写入 DPU 配置仓库。

### DPU snapshot 到 PCIe policy

典型调用顺序如下，`freeze()` 成功后 snapshot 是 BDF/BAR 的唯一权威来源：

```systemverilog
dpu_device_snapshot snapshot;
pcie_dpu_root_binding_cfg root_cfg;
pcie_global_cfg projected;
string errors[$];

// snapshot 由 dpu_common resolver 产生并冻结；这里不重新分配 BDF/BAR。
root_cfg = pcie_dpu_root_binding_cfg::type_id::create("root_cfg");
string why;
void'(root_cfg.bind_domain_to_root(0, 0, 0, why)); // Host0/Segment0 -> Root0

if (!adapter.project_with_root_bindings(
        snapshot, resource_snapshot, topology_cfg, attachments,
        root_cfg, projected, errors)) begin
    // 创建 pcie_tl_env 前处理 errors；错误不能延迟到运行期。
end
```

`pcie_dpu_root_binding_cfg` 检查逻辑域到 Root 的唯一性、Root 数量和
snapshot 中实际使用的 Host/Segment 是否一致。PF/VF 到 Endpoint/link 的
物理挂接由 `pcie_dpu_attachment_cfg` 单独负责；因此“Host 数量”不会被
错误地当成“RC 数量”。

投影出的 `pcie_device_cfg.root_index` 不只是审计字段：当调用方把
`pcie_global_cfg` 发布给 `pcie_tl_env` 时，环境会按 direct 链路或 Switch
DSP 的物理顺序生成 `ep_root_by_index[]`，随后用该 Root 选择对应的
tag/FC/ordering/config manager。这样
即使 DPU function 的声明顺序与链路顺序不同，EP 仍不会误用另一条 Root
的资源；Switch DSP 的 Root 元数据若与 `dsp_owner[]` 不一致会在 build 阶段
直接报错。

### 多 Root 共享 Host memory

启用统一内存时，Root-specific manager 也要显式绑定。下面的例子对应
Root0 → Host0、Root1 → Host1、Root2 → Host0：

```systemverilog
pcie_tl_env_config cfg;
host_mem_manager host0_mem, host1_mem;
string why;

cfg = pcie_tl_env_config::type_id::create("cfg");
cfg.use_unified_mem = 1'b1;
host0_mem = new("host0_mem"); host0_mem.set_host_id(0);
host1_mem = new("host1_mem"); host1_mem.set_host_id(1);

void'(cfg.bind_host_memory(0, 0, host0_mem, why));
void'(cfg.bind_host_memory(1, 1, host1_mem, why));
void'(cfg.bind_host_memory(2, 0, host0_mem, why));
```

多 Root 下每个 Root 都必须有显式绑定，不能回退到单一
`config_db("host_mem")`，也不能由环境偷偷创建私有 manager。相同 manager
被多个 Root 引用时，PREMAP backing memory 在一次环境中只分配一次；已经由
VIO/DPU 初始化的 manager 也不会被 `pcie_tl_env` 重新 `init_region()`。
单 Root 仍兼容旧的 `config_db("host_mem")` 注入；如果单 Root 使用显式
绑定，则显式绑定优先。EP 的 `dev_mem[i]` 仍可独立通过
`config_db("dev_mem_i")` 注入。

`pcie_work` 可以完全脱离 `dpu_common` 使用：直接创建
`pcie_tl_env_config`/`pcie_tl_env` 即可。集成 DPU 时只需额外编译
`pcie_dpu_integration`，设置 `DPU_COMMON_ROOT` 指向独立仓库根目录，并在
创建 TL 环境前执行 snapshot → policy 投影；两种使用方式互不污染。

## Supported boundaries

- Existing `pcie_tl_vip` classes, sequences, and TL filelists remain stable.
- SVT R-2020.12 Serial integration is available through the dedicated adapter
  filelist; PIPE is reserved for a later adapter implementation.
- The former `pcie_tl_custom_env` topology wrapper has been removed.  Its
  validation/translation behavior now belongs to `pcie_tl_env`, so there is
  only one production TL environment.  Real-DUT integration should provide
  its own HDL top while reusing the adapter package and official SVT agent
  interfaces.
