# Task 4 实施报告

## 交付内容

- 新增 `svt_pcie_integration/sim/pcie_tl_svt_bridge_1rc1ep.f`：按 TL 包、SVT
  bridge/拓扑包、Serial/复位接口、placeholder、顶层测试的顺序列出编译输入，
  并保留 `$PCIE_SVT_ROOT`、`$DESIGNWARE_HOME`、`$HOST_MEM_ROOT` 环境变量。
- 新增 `svt_pcie_integration/sim/pcie_tl_svt_bridge_1rc1ep_tb.sv`：建立 1RC
  x16 Serial HDL agent，选择 `PCIE_BACKEND_SVT_TL_FORWARD`，发布 Mapper 及
  RC route（application ID `0`）；EP application ID `1` 仅作为未来真实 DUT/
  显式 EP 扩展的别名，direct EP_X16 当前不会创建对应 active adapter。默认
  连接 electrical-idle placeholder wrapper。
- 更新 `svt_pcie_integration/sim/README.md`：记录精确 VCS 命令、环境前置条件和
  placeholder 只能证明 compile/elaboration 的边界。

## 静态验证

在 `svt_pcie_integration/sim` 执行：

```text
FILELIST_REPOSITORY_PATHS_PASS
PACKAGE_DECLARATIONS_PASS
ENVIRONMENT_VARIABLE_REFERENCES_PASS
DIFF_CHECK_PASS
```

检查确认 filelist 中仓库相对路径均存在、显式 package 声明无重复，并且三个
环境变量引用未被硬编码替代。

## VCS 主机限制

已使用 `ubuntu/123` 登录 `10.11.10.53` 检查环境：VCS 可执行文件为
`/home/ubuntu/synopsys/vcs/W-2024.09-SP1/bin/vcs`，但 `PCIE_SVT_ROOT`、
`DESIGNWARE_HOME`、`HOST_MEM_ROOT` 均为 `UNSET`。由于 filelist 的 SVT/host
include 路径无法解析，未运行 VCS compile/elaboration；README 已记录该精确
限制及待执行命令。
