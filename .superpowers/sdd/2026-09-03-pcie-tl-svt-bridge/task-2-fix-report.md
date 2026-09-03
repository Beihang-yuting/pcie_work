# Task 2 修订报告

- 修复 mock Mapper 场景：桥接器在无真实 Mapper 时捕获 TX 交易，不再触发 fatal；单元测试现在断言一次出站交易。
- 将真实桥接器优先在 `build_phase` 创建；`connect_phase` 增加 application_id 在 TX/RX 公开端口中的存在性检查。
- 删除未使用且易与父类 `codec` 混淆的 `svt_codec` 字段，统一调用 Task 1 codec 静态接口。
- RX mock 仍通过公开桥接队列注入并执行解码与 route 校验。

由于当前开发容器没有 SVT 类型库，未执行 VCS 编译；代码保持 `PCIE_SVT_AVAILABLE` 宏保护，TL-only 构建不受影响。`git diff --check` 已通过。

