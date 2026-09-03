# Task 2 最终修订报告

- 修复 mock 测试 application_id 不一致：`connect_phase` 将 endpoint 的绑定 ID 同步为 adapter route ID，避免 route=7 而 queue 使用默认 0 导致接收失败。
- `pcie_svt_topology.f` 明确定义 `PCIE_SVT_AVAILABLE`，因此 SVT 文件列表会实际编译适配器测试；其他 TL-only filelist 不受影响。
- 移除 connect 阶段的 factory fallback；若 build 阶段未提供 endpoint，则立即 fatal，保证 UVM 层次稳定且配置错误尽早暴露。
- 适配器新增 `codec_adapter` 实例句柄并在 build 阶段构造。父类已定义 `codec`（TL codec 类型），故不能以不同类型重声明同名字段；实际转换继续调用静态 SVT codec API，句柄仅用于生命周期/配置检查。

验证：`git diff --check` 通过；SVT VCS 编译仍需在安装 R-2020.12 的主机执行。
