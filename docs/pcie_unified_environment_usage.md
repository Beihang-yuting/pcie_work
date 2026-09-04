# PCIe environment usage

## Single control plane

`pcie_tl_env` is the only production PCIe environment.  It owns topology,
configuration-space images, BAR allocation, BDF assignment, enumeration,
completions, Memory traffic, and all project sequences.  Existing users may
continue to instantiate `pcie_tl_env` directly or use the topology-aware
`pcie_tl_custom_env` wrapper.

```text
pcie_tl_env / pcie_tl_custom_env
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

For graph-driven topologies, publish `pcie_topology_cfg` and a policy object
under `env`, then instantiate `pcie_tl_custom_env`.  The wrapper translates
the graph once and passes the resulting native policy to `pcie_tl_env`.

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

## Supported boundaries

- Existing `pcie_tl_vip` classes, sequences, and TL filelists remain stable.
- SVT R-2020.12 Serial integration is available through the dedicated adapter
  filelist; PIPE is reserved for a later adapter implementation.
- Removed SVT topology/peer wrappers were test scaffolding, not production
  control paths.  Real-DUT integration should provide its own HDL top while
  reusing the adapter package and official SVT agent interfaces.
