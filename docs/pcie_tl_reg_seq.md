# PCIe 寄存器访问与 AIP reg_acc

`pcie_tl_reg_seq` 位于 `pcie_tl_pkg`，访问 DUT BAR 映射后的 Memory 空间。
它复用 `pcie_tl_rw_seq`，可用于 Intel adapter、原生 TL 和其他已有 transport。
它不是 Configuration Space sequence；配置空间仍使用 `pcie_tl_cfg_rd/wr_seq`。

## 字段与字节顺序

| 字段 | 类型 / 默认值 | 含义 |
| --- | --- | --- |
| `is_write` | `bit` / 0 | 1 写、0 读 |
| `addr` | `longint unsigned` | PCIe 字节地址，必须 DWORD 对齐，BAR 偏移需调用者加基址 |
| `len` | `int unsigned` / 4 | 字节数，只接受 4、8、12、16 |
| `wdata` / `rdata` | `bit [127:0]` | 小端标量；低 8 位对应 `addr`，随后字节地址逐一加 1 |
| `mask` | `int unsigned` / 0 | bit i=1 跳过 `addr+i`；bit i=0 正常访问 |
| `rb_timeout_ns` | `int` / 50000 | 每个读请求等待 Completion 的期限，单位 ns |
| `status` | `pcie_rw_status_e` | `PCIE_RW_OK`、`PCIE_RW_ERR`、`PCIE_RW_TIMEOUT` |
| `error_msg` | `string` | 成功为空；失败说明原因 |
| `issued_tlps` | TLP 句柄队列 | 本次实际发出的请求；每次 `start()` 前清空 |

`mask` 不填写时全部正常访问。它是**字节屏蔽**，不是数据位掩码，也不会把屏蔽字节写成零。
例如 DUT 原值 `0xaabbccdd`，写 `data=0x11223344 mask=0x2` 后是 `0x1122cc44`。
`mask=0xf` 屏蔽 4 字节，`0xff` 屏蔽 8 字节，`0xfff` 屏蔽 12 字节，`0xffff` 屏蔽 16 字节。
`mask=0xffffffff` 对所有长度均表示全屏蔽；其他超出 `len` 的 mask 位报错。
读请求同样只访问未屏蔽字节，`rdata` 的屏蔽位置返回零。

完整访问形成一个 TLP；稀疏 mask 拆成若干连续有效字节区间，每区间一个 TLP。
全屏蔽不发请求。不会用读改写实现屏蔽，多区间访问不保证原子性，也不回滚已完成的区间。
所有访问须位于同一 4KB 页，地址范围不得溢出 64 位，写数据不得超过 `len*8` 位。
非法参数在任何 TLP 发出前返回错误；读失败保留已完成区间数据并停止后续区间。
posted 写成功表示发送完成；需要确认 DUT 已处理时应按 DUT 协议读回。

## 直接在 SV 中使用

```systemverilog
pcie_tl_reg_seq reg_seq;
reg_seq = pcie_tl_reg_seq::type_id::create("reg_seq");
reg_seq.is_write = 1;
reg_seq.addr = 64'h80000000;
reg_seq.len = 16;
reg_seq.wdata = 128'h112233445566778899aabbccddeeff00;
// mask 的构造默认值是 0：全部字节正常写入。
reg_seq.start(pcie_env.rc_agent.sequencer);
if (reg_seq.status != PCIE_RW_OK)
    `uvm_error("REG_ACCESS", reg_seq.error_msg)
```

字段均为非 rand；每次赋值后直接 `start()`。地址始终使用字节单位，不乘除 4。
同一对象可重复使用，但调用者须更新本次输入；输出状态和已发请求会自动清空。

## AIP 注册

需要包含宽数据/位置参数扩展的 **aip_core/update**，仅把 sequence 的 `wdata` 改成
128 位无法修复旧版 `aip_cmd_reg` 的 64 位解析限制。产品 sequence 本身不依赖 AIP。

```systemverilog
// 定义在测试包内，先编译 aip_core_pkg，再编译 pcie_tl_pkg。
class my_reg_context;
    static uvm_sequencer_base pcie_sqr;
endclass

`aip_cmd_reg(reg_acc, pcie_tl_reg_seq, my_reg_context::pcie_sqr, seq.error_msg)

// 在大 env 的 connect_phase 中绑定真实 requester。
my_reg_context::pcie_sqr = pcie_env.rc_agent.sequencer;

// 测试 run_phase 持有 objection 期间运行 AIP Tcl bridge。
aip_tcl_bridge::run_loop();
```

第四参数 `seq.error_msg` 是宏支持的可选错误表达式，`seq` 指本次创建的对象。
务必为本 sequence 提供它，才能让参数错误/读失败返回 Tcl 的非零状态，避免误报 OK。
原有三参数宏仍支持没有错误字段的旧 sequence。

## Tcl 命令

```tcl
# 位置顺序：op addr len data [mask]。省略的是参数名，不是这些参数值。
reg_acc write 0x80000000 4  0x11223344
reg_acc write 0x80000008 8  0x1122334455667788
reg_acc write 0x80000010 12 0x112233445566778899aabbcc
reg_acc write 0x80000020 16 0x112233445566778899aabbccddeeff00

reg_acc read 0x80000020 16
puts [aip_read_result]         ;# rdata=0x112233445566778899aabbccddeeff00
reg_acc read 0x80000000       ;# 默认 4 字节

# 屏蔽第二个字节，其他字节按原始 data 写入。
reg_acc write 0x80000000 4 0xaabbccdd mask=0x2
# 第五个位置参数也可以表示 mask。
reg_acc write 0x80000000 4 0xaabbccdd 0x2

# 原有命名格式继续支持；不要把命名 op/addr/len/data 和位置形式混用。
reg_acc op=write addr=0x80000000 len=4 data=0x12345678
reg_acc op=read addr=0x80000000
if {[aip_check_status] != 0} { error [aip_read_result] }
```

此版本 AIP 将省略 `mask` 的默认值从 `0xffffffff` 改为 **0**。
其他已有总线 sequence 若仍采用“1=使能”，需明确传原来的使能 mask 或调整封装，
不能只更新 AIP 后假定默认语义没有改变。AIP 只透传 mask，PCIe 屏蔽语义在本 sequence 实现。

## 回归入口

- `pcie_tl_vip/tests/pcie_tl_reg_seq_test.sv`：不依赖 AIP 的位宽、屏蔽和失败恢复契约。
- Intel 项目 `sim/filelist_aip_reg.f`：AIP→Intel bind 4x256 的原始引脚/内存/SCB 对照。
- AIP `make test_reg_wide`：位置参数、128 位整数、旧类兼容、溢出和错误回传。

所有 VCS 仿真在指定验证主机运行。测试结果由对应执行日志判定。

## 状态寄存器读与顺序

`pcie_tl_reg_seq.check_read_data` 默认1，逐请求传给底层RW/TLP和SCB。
读取AF等状态寄存器时可设0，仅跳过SCB按历史Memory Write保存值进行的RAM数据比较；
Completion状态、tag、长度和超时检查保持开启，调用方仍应校验寄存器期望状态。
该位是验证元数据，不改变线上TLP编码；复制、错误注入重编码与TX快照均保留它。

寄存器seq固定底层`strict_order=1`，约束TC=0、attr=0（RO/IDO关闭），
保证posted写后发起的状态读遵循PCIe顺序。普通`pcie_tl_rw_seq`默认`strict_order=0`，
保留原有通用流量随机化行为。AIP注册要暴露逐命令策略时使用第五参数：

```systemverilog
`aip_cmd_reg(reg_acc, pcie_tl_reg_seq, rc_sqr, seq.error_msg, seq.check_read_data)
```

```tcl
reg_acc read 0x80001010 check_read_data=0
```

上述原生seq使用绝对地址；Virtio的`project_pcie_reg_seq`包装类使用PF0 BAR0内偏移。
