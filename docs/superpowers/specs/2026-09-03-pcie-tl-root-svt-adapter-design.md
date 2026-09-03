# PCIe TL 根环境与 SVT Adapter 收敛设计

## 目标

将本项目收敛为与 `xillinx_pcie/feat/adapter-mode` 一致的结构：
`pcie_tl_env` 是唯一 PCIe 控制面，SVT 只通过 `pcie_tl_if_adapter` 子类
接入 Serial/PIPE 或真实 DUT，不再维护第二套全局配置、枚举和流量环境。

## 当前问题

当前 `svt_pcie_integration` 同时存在 `pcie_unified_env`、SVT backend、
SVT topology env、独立 cfg/sequence 和 TL/SVT Mapper bridge。这些组件重复
拥有拓扑、链路和配置职责，导致用户无法判断哪个环境是根环境；此前手工创建
孤立 `svt_pcie_tlp_mapper` 还会在运行阶段访问空 service sequencer。

## 目标架构

```text
pcie_tl_env / pcie_tl_custom_env
        │  工厂覆盖 pcie_tl_if_adapter
        ▼
pcie_svt_if_adapter
        ├── 正式 svt_pcie_device_agent.tlp_mapper
        ├── SVT TLP 编解码
        └── Serial/PIPE 或真实 DUT 物理接口
```

- TL env 负责 Config、BAR、BDF、枚举、Memory、Completion 和所有用户
  sequence。
- SVT adapter 只负责 TLP 转换、Mapper 端口连接和物理承载。
- `TL_ONLY` 不创建 SVT 组件，不改变既有 `pcie_tl_env` API。
- 双侧 SVT peer test 作为独立链路自检保留，不作为生产控制环境。

## 文件边界

保留并重写的生产文件：

- `svt_pcie_integration/uvm/adapter/pcie_svt_if_adapter.sv`
- `svt_pcie_integration/uvm/adapter/pcie_svt_adapter_types.sv`
- `svt_pcie_integration/uvm/adapter/pcie_svt_tlp_codec.sv`
- `svt_pcie_integration/rtl/pcie_svt_serial_port_if.sv`
- `svt_pcie_integration/rtl/pcie_svt_serial_adapter.sv`
- `svt_pcie_integration/rtl/pcie_svt_hdl_agent_macros.svh`

删除重复的生产管理层：

- `uvm/env/pcie_unified_env.sv`
- `uvm/env/pcie_svt_topology_env.sv`
- `uvm/backend/*.sv`
- `uvm/cfg/pcie_svt_profile_factory.sv`
- `uvm/cfg/pcie_svt_cli_parser.sv`
- `uvm/cfg/pcie_svt_topology_policy_cfg.sv`
- `uvm/cfg/pcie_svt_device_cfg_builder.sv`
- `uvm/cfg/pcie_svt_cfg_space_builder.sv`
- `uvm/adapter/pcie_svt_topology_adapter.sv`
- 重复的 CFG/枚举/global-stage sequence

已验证的 peer link 自检所需文件暂时保留在 test-only 路径，不能被生产
TL adapter filelist 依赖。

## 生产测试接口

SVT adapter test 直接实例化上游 `pcie_tl_env`，通过工厂覆盖安装 adapter：

```systemverilog
pcie_tl_if_adapter::type_id::set_type_override(
    pcie_svt_if_adapter::get_type());

cfg = pcie_tl_env_config::type_id::create("cfg");
cfg.if_mode          = SV_IF_MODE;
cfg.rc_agent_enable  = 1'b1;
cfg.ep_agent_enable  = 1'b1;
cfg.ep_auto_response = 1'b1;
cfg.infinite_credit  = 1'b1;
cfg.scb_enable       = 1'b0;

uvm_config_db#(pcie_tl_env_config)::set(this, "env", "cfg", cfg);
env = pcie_tl_env::type_id::create("env", this);
```

SVT Mapper 必须来自正式 `svt_pcie_device_agent.tlp_mapper`；禁止在 test
中直接 `svt_pcie_tlp_mapper::type_id::create()`。

## 验收标准

1. `pcie_tl_vip` 原有 TL-only filelist 和测试不引入 SVT 依赖。
2. SVT adapter filelist 能编译 1RC+1EP/x16/Serial/Gen4。
3. 工厂覆盖后，正式 SVT agent Mapper 非空且 service sequencer 完整。
4. TL RC sequence 发出的 TLP 能经过 adapter 到达 SVT；SVT 返回的
   Completion 能回到 TL monitor。
5. 53 号机 VCS 运行结果 `UVM_ERROR=0`、`UVM_FATAL=0`。
6. 双侧 peer link 自检继续保持 `LINK PASS`，但与 TL adapter 生产 test
   分离。
