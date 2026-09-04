#!/usr/bin/env bash
set -euo pipefail

# TL/SVT 桥接契约检查：只检查公开文件和符号，不需要启动 VCS/SVT。
# 这样可在 CI 或提交前快速发现 filelist 漏项、Mapper 端口改名以及
# 旧 filelist 被意外改写等兼容性回归。
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "$script_dir/../.." && pwd)
svt_dir="$repo_dir/svt_pcie_integration"
tl_dir="$repo_dir/pcie_tl_vip"

fail() {
  echo "TL_SVT_BRIDGE_CONTRACT_FAIL: $*" >&2
  exit 1
}

# 桥接实现必须由 package 的 include 顺序统一带入；这里同时确认物理文件
# 仍然存在，避免只改了 package 而漏提交新 adapter。
required_files=(
  "$svt_dir/uvm/adapter/pcie_svt_adapter_types.sv"
  "$svt_dir/uvm/adapter/pcie_svt_tlp_codec.sv"
  "$svt_dir/uvm/adapter/pcie_svt_tlp_mapper_bridge.sv"
  "$svt_dir/uvm/adapter/pcie_svt_if_adapter.sv"
  "$svt_dir/uvm/adapter/pcie_svt_adapter_pkg.sv"
)
for file in "${required_files[@]}"; do
  [[ -f "$file" ]] || fail "缺少桥接文件: ${file#$repo_dir/}"
done

codec_file="${required_files[1]}"
adapter_file="${required_files[3]}"
mapper_file="${required_files[2]}"
pkg_file="$svt_dir/uvm/adapter/pcie_svt_adapter_pkg.sv"

# 公开 mapper 边界必须保持 blocking put 端口名称；适配器也必须继续继承
# TL adapter 并暴露 send/receive 转换入口。
grep -q 'class pcie_svt_if_adapter extends pcie_tl_if_adapter' "$adapter_file" \
  || fail "pcie_svt_if_adapter 未继承 pcie_tl_if_adapter"
grep -q 'virtual task send(pcie_tl_tlp tlp)' "$adapter_file" \
  || fail "适配器缺少 send(pcie_tl_tlp)"
grep -q 'virtual task receive(output pcie_tl_tlp tlp)' "$adapter_file" \
  || fail "适配器缺少 receive(output pcie_tl_tlp)"
grep -q 'pcie_svt_tlp_codec::encode' "$adapter_file" \
  || fail "适配器未调用公开 codec encode"
grep -q 'pcie_svt_tlp_codec::decode' "$adapter_file" \
  || fail "适配器未调用公开 codec decode"
grep -q 'tx_tlp_in_export' "$mapper_file" \
  || fail "Mapper TX 公共端口符号缺失"
grep -q 'rx_tlp_out_port' "$mapper_file" \
  || fail "Mapper RX 公共端口符号缺失"
grep -q 'function.*bind_application' "$mapper_file" \
  || fail "Mapper bridge 缺少 bind_application"
grep -q 'pcie_svt_tlp_codec::encode' "$codec_file" 2>/dev/null ||
  grep -q 'static.*function.*encode' "$codec_file" \
  || fail "codec encode 公共函数缺失"
grep -q 'function.*decode' "$codec_file" \
  || fail "codec decode 公共函数缺失"
grep -q 'adapter/pcie_svt_tlp_mapper_bridge.sv' "$pkg_file" \
  || fail "SVT adapter package 未 include Mapper bridge"

# TL-only 入口必须保持干净：桥接源码只能由专用 adapter filelist 引入，
# 不允许把 SVT 适配器偷偷注入原有 TL 回归。SVT topology filelist 是本次
# 收敛的生产入口，允许移除 peer-only 测试，但仍检查其不得引用 bridge。
legacy_lists=("$tl_dir/sim/filelist.f")
for list in "${legacy_lists[@]}"; do
  [[ -f "$list" ]] || fail "旧 filelist 不存在: ${list#$repo_dir/}"
  # TL-only filelist 可以正常做可移植性维护（例如把旧的 /home/ryan
  # 绝对路径替换成相对路径和 $HOST_MEM_ROOT）。这里不再把“存在 diff”
  # 本身当作错误，而是直接检查最终内容：不得出现 SVT bridge 源文件、
  # SVT include 路径或旧工作站绝对路径。这样既允许必要的 filelist 整理，
  # 又能防止桥接依赖悄悄污染 TL-only 编译入口。
  grep -Eq 'pcie_svt|SVT_SVT|DESIGNWARE|PCIE_SVT_ROOT' "$list" &&
    fail "TL-only filelist 引用了 SVT 依赖: ${list#$repo_dir/}"
  grep -Eq '/home/(ryan|ubuntu)/' "$list" &&
    fail "TL-only filelist 含机器相关绝对路径: ${list#$repo_dir/}"
  grep -q '\$HOST_MEM_ROOT/src/host_mem_pkg\.sv' "$list" ||
    fail "TL-only filelist 未使用 HOST_MEM_ROOT 注入 host_mem: ${list#$repo_dir/}"
  if grep -Eq '(^|/)(pcie_svt_(if_adapter|tlp_codec|tlp_mapper_bridge)|pcie_tl_svt_bridge)(\.sv)?$' "$list"; then
    fail "旧 filelist 引用了 TL/SVT bridge: ${list#$repo_dir/}"
  fi
done

# SVT adapter source filelist 是真实 DUT 工程可复用的基础；可直接运行的
# 验证入口由 formal/peer 两个专用 filelist 提供。
production_svt_list="$svt_dir/sim/pcie_tl_svt_adapter.f"
[[ -f "$production_svt_list" ]] || fail "SVT adapter filelist 不存在"
grep -q 'pcie_svt_adapter_pkg.sv' "$production_svt_list" \
  || fail "SVT adapter filelist 未包含 adapter package"

formal_svt_list="$svt_dir/sim/pcie_tl_svt_formal.f"
peer_svt_list="$svt_dir/sim/pcie_svt_peer_traffic.f"
[[ -f "$formal_svt_list" ]] || fail "FULL_VIP formal filelist 不存在"
[[ -f "$peer_svt_list" ]] || fail "SVT peer traffic filelist 不存在"
grep -q 'pcie_tl_svt_formal_top.sv' "$formal_svt_list" \
  || fail "formal filelist 未包含正式双向顶层"
grep -q 'pcie_svt_peer_traffic_top.sv' "$peer_svt_list" \
  || fail "peer filelist 未包含官方自检顶层"

# source-only adapter 列表不得重新带入已删除的占位测试/顶层。
grep -Eq 'pcie_tl_svt_adapter_(base|link)_test|pcie_tl_svt_adapter_tb_top' \
  "$production_svt_list" && fail "source-only adapter filelist 引用了已删除占位测试"

grep -q 'bind_agent' "$adapter_file" \
  || fail "adapter 缺少正式 SVT agent bind_agent 接口"

# FULL_VIP Root 必须将“观察”和“抑制 SVT 内建响应”分开：有 TL monitor
# 时由 monitor 统一入队、Target App callback 只负责 drop；无 monitor 时由
# Target App 入队请求、TL callback 只允许捕获 Completion。缺任一显式契约
# 都可能导致同一个请求重复入队或产生两份 Completion。
grep -q 'capture_transaction' "$adapter_file" \
  || fail "Target callback 缺少 capture_transaction 去重控制"
grep -q 'full_vip_target_rx_callback.drop_transaction = 1' "$adapter_file" \
  || fail "FULL_VIP Root/Endpoint 未显式抑制 SVT Target App 响应"
grep -q 'full_vip_rx_callback.completion_only = 1' "$adapter_file" \
  || fail "FULL_VIP Root fallback TL callback 未限制为 Completion"

echo "TL_SVT_BRIDGE_CONTRACT_PASS adapters=4 mapper_ports=2 legacy_filelists=1 root=pcie_tl_env"
