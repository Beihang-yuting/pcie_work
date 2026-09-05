#!/usr/bin/env bash
set -euo pipefail

# TL-only 回归不依赖 SVT；唯一的外部依赖是 host_mem。调用者可以在
# 环境中指定其源码根目录，避免把某台机器的绝对路径写进 filelist。
: "${HOST_MEM_ROOT:?请先设置 HOST_MEM_ROOT（指向 host_mem 项目根目录）}"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$script_dir"

# 每次回归使用独立的 csrc/simv.daidir，避免并行测试覆盖编译产物。
build_dir=${BUILD_DIR:-build/tl_only}
mkdir -p "$build_dir"
vcs -sverilog -full64 -ntb_opts uvm-1.2 \
    -timescale=1ns/1ps \
    -Mdir="$build_dir/csrc" \
    -f filelist.f \
    -o "$build_dir/simv" \
    -l "$build_dir/compile.log"

# 实际定义在 pcie_tl_smoke_test.sv 中的是 pcie_tl_smoke_mem_test；保留
# 第一个位置参数作为可替换的 UVM test 名称，其余参数原样传给 simv，
# 这样 graph/custom test 可以直接使用 +PCIE_TOPOLOGY/+PCIE_GEN 等 CLI 配置。
TEST=${1:-pcie_tl_smoke_mem_test}
if [ "$#" -gt 0 ]; then
    shift
fi
TAG_BIT=${TAG_BIT:-8}
case "$TAG_BIT" in
    8|10) ;;
    *) echo "TAG_BIT must be 8 or 10, got: $TAG_BIT" >&2; exit 2 ;;
esac
"$build_dir/simv" \
    +UVM_TESTNAME="$TEST" \
    +UVM_VERBOSITY=UVM_MEDIUM \
    +TAG_BIT="$TAG_BIT" \
    "$@" \
    -l "$build_dir/run_${TEST}.log"
