# Task 2 实施报告

## 已完成

- 新增 `pcie_svt_if_adapter`，继承 `pcie_tl_if_adapter`，通过 `pcie_svt_tlp_codec` 完成 TL/SVT 转换，并在发送、接收时校验 route 元数据。
- 新增 `pcie_svt_tlp_mapper_bridge`，仅连接 SVT R-2020.12 公开的 `tx_tlp_in_export[application_id]` 与 `rx_tlp_out_port[application_id]`。
- 拓扑包加入两个适配器源码 include。
- 新增受 `PCIE_SVT_AVAILABLE` 保护的适配器单元测试骨架，覆盖一次出站编码和一次入站解码；无 SVT 安装时不会污染 TL-only 编译。

## 验证与限制

本地环境没有 Synopsys SVT 类型声明，无法执行 VCS 编译。已核对 R-2020.12 Mapper 声明：TX 为 blocking put export，RX 为 blocking put port；桥接代码未使用私有成员。`git diff --check` 通过。

`pcie_tl_if_adapter` 已有 `codec`（类型为 TL codec）字段，SystemVerilog 派生类不能安全重声明同名字段；SVT codec 句柄因此公开为 `svt_codec`，转换使用其静态 API。

