# 多根（多 USP）Switch Fabric — 回归矩阵

> Plan Task 9 验收记录。环境：VCS（Q-2020.03）@ `ryan@10.11.10.61:2222`，build `/tmp/pbuild`，`+ntb_random_seed=1`。
> Build：`vcs rc=0`，无 `Error-[`。

| Test | 类型 | UVM_ERROR | UVM_FATAL | 判定凭据 |
|---|---|---|---|---|
| `pcie_tl_smoke_mem_test` | 基线 | 0 | 0 | — |
| `pcie_tl_unified_mem_test` | 基线 | 0 | 0 | Leak check passed: 0 blocks |
| `pcie_tl_switch_basic_test` | switch 基线 | 0 | 0 | SWITCH BASIC ROUTING PASSED |
| `pcie_tl_switch_unified_mem_test` | switch 路径（num_usp=1 等价） | 0 | 0 | Leak 0；无回退 |
| `pcie_tl_multi_root_route_test` | 新 (T6) | 0 | 0 | cross_root_violations=1；MULTI_ROUTE PASSED |
| `pcie_tl_cross_root_isolation_test` | 新 (T7) | 0 | 0 | cross_root_violations=4 全捕获；ISO PASSED |
| `pcie_tl_uneven_ownership_test` | 新 (T8) | 0 | 0 | cross_root_violations=1；UNEVEN PASSED |
| `pcie_tl_per_root_tag_test` | 新 (T8) | 0 | 0 | cross_root_violations=0；TAGINDEP PASSED |

**结论：** 8/8 通过。num_usp=1 向后兼容（switch_unified_mem 无回退），4 个多根新 test 各自隔离/路由/tag 独立按 violation 计数断言全 PASS。Plan Task 9 完成。
