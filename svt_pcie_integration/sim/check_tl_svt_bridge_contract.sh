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
  "$svt_dir/uvm/env/pcie_svt_topology_env.sv"
  "$svt_dir/sim/pcie_tl_svt_bridge_1rc1ep.f"
)
for file in "${required_files[@]}"; do
  [[ -f "$file" ]] || fail "缺少桥接文件: ${file#$repo_dir/}"
done

codec_file="${required_files[1]}"
adapter_file="${required_files[3]}"
mapper_file="${required_files[2]}"
pkg_file="$svt_dir/uvm/pcie_svt_topology_pkg.sv"

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
  || fail "topology package 未 include Mapper bridge"

# 旧入口的 filelist 必须保持干净：桥接源码只能由新增 bridge filelist 引入，
# 不允许把 SVT 适配器偷偷注入 TL-only/native SVT 回归。
legacy_lists=("$tl_dir/sim/filelist.f" "$svt_dir/sim/pcie_svt_topology.f")
for list in "${legacy_lists[@]}"; do
  [[ -f "$list" ]] || fail "旧 filelist 不存在: ${list#$repo_dir/}"
  # 同时检查工作区和暂存区；只检查普通 diff 会漏掉已经 staged 的非法修改。
  git -C "$repo_dir" diff HEAD --quiet -- "${list#$repo_dir/}" \
    || fail "旧 filelist 有未授权修改: ${list#$repo_dir/}"
  if grep -Eq '(^|/)(pcie_svt_(if_adapter|tlp_codec|tlp_mapper_bridge)|pcie_tl_svt_bridge)(\.sv)?$' "$list"; then
    fail "旧 filelist 引用了 TL/SVT bridge: ${list#$repo_dir/}"
  fi
done

# 已跟踪的 legacy SVT 文件必须仍在工作树中，明确禁止删除公共 API 文件。
while IFS= read -r path; do
  [[ -e "$repo_dir/$path" ]] || fail "legacy 文件被删除: $path"
done < <(git -C "$repo_dir" ls-files 'svt_pcie_integration/rtl/*' 'svt_pcie_integration/uvm/*' | \
  grep -vE '/(adapter/pcie_svt_(adapter_types|if_adapter|tlp_codec|tlp_mapper_bridge)|env/pcie_svt_topology_env)\.sv$' || true)

echo "TL_SVT_BRIDGE_CONTRACT_PASS adapters=4 mapper_ports=2 legacy_filelists=2"
