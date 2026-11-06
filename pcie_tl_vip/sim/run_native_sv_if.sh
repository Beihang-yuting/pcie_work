#!/usr/bin/env bash
set -euo pipefail

# 原生 SV_IF 专用回归：只依赖 host_mem 和本仓库，一次编译复用 RC/EP 单笔与重用/分片四项。
# BRIDGE_CONTRACT=1改跑既有fake-provider中性合同的三项，不需要也不代表真实SVT/RTL。
# VCS 退出码不保证 UVM 零错误；每个日志必须额外通过 W/E/F 检查和明确完成标记。
: "${HOST_MEM_ROOT:?请设置 HOST_MEM_ROOT 为 host_mem 仓库根目录}"
native_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export PCIE_WORK_ROOT
PCIE_WORK_ROOT=$(cd -- "$native_script_dir/../.." && pwd)
native_filelist="$native_script_dir/native_sv_if.f"
native_test=pcie_tl_native_sv_if_test
native_cases=(RC:single:0 EP:single:0 RC:split_reuse:0 EP:split_reuse:0)
case "${BRIDGE_CONTRACT:-0}" in
    0) native_build_default="$native_script_dir/build/native_sv_if" ;;
    1)
        native_filelist="$native_script_dir/bridge_completion.f"
        native_test=pcie_tl_bridge_completion_test
        native_cases=(RC:split_reuse:0 EP:split_reuse:0 EP:split_reuse:1)
        native_build_default="$native_script_dir/build/bridge_completion"
        ;;
    *) echo "BRIDGE_CONTRACT must be 0 or 1" >&2; exit 2 ;;
esac
native_build_dir=${BUILD_DIR:-"$native_build_default"}
mkdir -p "$native_build_dir"
native_build_dir=$(cd -- "$native_build_dir" && pwd)

# 只读日志判定；编译 warning/error 和运行 UVM warning/error/fatal 均严格失败。
# PASS 标记用于排除未执行完测试却零退出的情况，不会覆盖任何错误报告。
check_native_log() {
    python3 - "$1" "$2" <<'PY'
import pathlib
import re
import sys

path, mode = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text(errors="replace")
bad = re.search(r"(?:Warning|Error|Fatal)-\[", text)
bad = bad or re.search(r"^\s*UVM_(?:WARNING|ERROR|FATAL)\s+(?:@|[^:\n]+\([^\n]*\)\s*@)", text, re.M)
bad = bad or any(int(value) for value in re.findall(r"^\s*UVM_(?:WARNING|ERROR|FATAL)\s*:\s*(\d+)", text, re.M))
if mode == "run":
    bad = bad or "[NATIVE_SV_IF_PASS]" not in text
    bad = bad or not all(re.search(r"^\s*UVM_" + severity + r"\s*:\s*0\s*$", text, re.M)
                        for severity in ("WARNING", "ERROR", "FATAL"))
if bad:
    print(f"STRICT FAIL: {path}", file=sys.stderr)
    sys.exit(1)
print(f"STRICT PASS: {path}")
PY
}

vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps \
    -top pcie_tl_native_sv_if_tb_top \
    -Mdir="$native_build_dir/csrc" \
    -f "$native_filelist" \
    -o "$native_build_dir/simv" -l "$native_build_dir/compile.log"
check_native_log "$native_build_dir/compile.log" compile

native_failures=0
for native_case in "${native_cases[@]}"; do
    IFS=: read -r native_direction native_mode native_auto <<< "$native_case"
    native_args=(+UVM_TESTNAME="$native_test" +NATIVE_DIRECTION="$native_direction" +UVM_VERBOSITY=UVM_LOW)
    if [[ "$native_mode" == single ]]; then
        native_args+=(+NATIVE_SINGLE)
    fi
    if [[ "$native_auto" == 1 ]]; then
        native_args+=(+BRIDGE_AUTO_RESPONSE)
    fi
    native_log="$native_build_dir/${native_direction}_${native_mode}_auto${native_auto}.log"
    if ! "$native_build_dir/simv" "${native_args[@]}" -l "$native_log"; then
        native_failures=1
    fi
    if ! check_native_log "$native_log" run; then
        native_failures=1
    fi
done
exit "$native_failures"
