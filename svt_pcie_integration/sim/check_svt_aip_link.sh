#!/usr/bin/env bash
# 所属层次：svt_pcie_integration/sim；真实 SVT RC/EP 经 AIP Tcl 建链的双模式门禁。
# 依赖本目录的专用 filelist、VCS/UCLI、timeout，以及外部 AIP/host_mem/SVT 源码。
# 本脚本拥有 build/aip_pair 下的编译产物和日志；每轮仿真使用独立临时子目录，
# 防止 trace=0/1 或重跑时覆盖 SVT 默认同名日志。脚本不修改生产代码或厂商配置。
# 必须在配置好 VCS 和许可证的 10.11.10.53 上执行；PCIE_AIP_SKIP_BUILD=1
# 仅复用已存在的专用 simv，调用者负责确认其与当前源码/依赖版本一致。

set -euo pipefail

# 统一报告门禁失败并返回非零；调用点应同时给出可定位的日志绝对路径。
fail() {
  printf 'SVT_AIP_CHECK_FAIL: %s\n' "$*" >&2
  exit 1
}

# 只接受带运行时行首/消息格式的正则；不能用裸字符串把 UCLI 回显的 puts、
# error 或未执行 if 分支当成真实结果。输入日志已去除 AIP 的 ANSI 颜色码。
require_runtime_line() {
  local log_file=$1
  local expected=$2
  grep -Eq -- "$expected" "$log_file" ||
    fail "missing runtime line '$expected'; log=$log_file"
}

# 统计仅作 trace 两组的可读对照，不以厂商私有 report ID 或关键词数量判断建链。
# 所有计数只看真实 UVM 消息行，排除 report summary 和 Tcl 源码回显；
# LTSSM/LINK/SEQ 大小写不敏感且允许同一行多项命中，不猜厂商 report ID。
print_log_counts() {
  local trace_mode=$1
  local log_file=$2
  awk -v trace="$trace_mode" '
    /^UVM_(INFO|WARNING|ERROR|FATAL)[[:space:]]+[^[:space:]:]/ {
      uvm++
      upper = toupper($0)
      if (upper ~ /LTSSM/) ltssm++
      if (upper ~ /LINK/) link++
      if (upper ~ /SEQ/) seq++
    }
    END {
      printf "trace=%s PASS uvm_messages=%d UVM_LTSSM_lines=%d UVM_LINK_lines=%d UVM_SEQ_lines=%d (auxiliary counts only)\n", trace, uvm, ltssm, link, seq
    }
  ' "$log_file"
}

# 缺失依赖立即失败；即使跳过编译，运行时 Tcl 和 SVT 仍需要对应环境。
for dependency_name in AIP_CORE HOST_MEM_ROOT PCIE_SVT_ROOT DESIGNWARE_HOME; do
  dependency_value=${!dependency_name:-}
  [[ -n "$dependency_value" ]] || fail "$dependency_name must be set"
  [[ -d "$dependency_value" ]] ||
    fail "$dependency_name is not a directory: $dependency_value"
done
[[ -r "$AIP_CORE/dist/aip_init.tcl" ]] ||
  fail "AIP source bootstrap is missing: $AIP_CORE/dist/aip_init.tcl"
command -v timeout >/dev/null 2>&1 || fail "timeout command is unavailable"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd -- "$script_dir"
build_dir="$script_dir/build/aip_pair"
sim_binary="$build_dir/simv"
test_script="$script_dir/../tests/pcie_svt_aip_link.tcl"
build_log="$build_dir/build.log"
skip_build=${PCIE_AIP_SKIP_BUILD:-0}
[[ "$skip_build" == 0 || "$skip_build" == 1 ]] ||
  fail "PCIE_AIP_SKIP_BUILD must be 0 or 1"
[[ -r "$test_script" ]] || fail "test script is missing: $test_script"
mkdir -p -- "$build_dir"

# 相对 filelist 路径必须从 sim/ 解析；只在显式 skip 模式下复用二进制。
# 编译完整输出落盘，失败只显示日志尾部，避免终端被厂商编译信息淹没。
if [[ "$skip_build" == 0 ]]; then
  command -v vcs >/dev/null 2>&1 || fail "vcs command is unavailable"
  printf 'SVT_AIP_BUILD log=%s\n' "$build_log"
  if ! vcs -full64 -sverilog -ntb_opts uvm-1.2 -debug_access+r+w+f \
      -lca -j2 -f pcie_svt_aip_link.f -top pcie_svt_aip_link_top \
      -Mdir=build/aip_pair/csrc -o build/aip_pair/simv >"$build_log" 2>&1; then
    tail -n 80 "$build_log" >&2
    fail "VCS compilation failed; log=$build_log"
  fi
fi
[[ -x "$sim_binary" ]] || fail "compiled executable is missing: $sim_binary"

# 两组使用同一编译产物、相同 seed 和 verbosity，仅切换 wrapper trace 参数。
# 独立目录保留所有厂商附属日志；600s 是主机侧兜底，SV wrapper 另有 1ms 超时。
run_root=$(mktemp -d "$build_dir/runs.XXXXXX")
for trace_mode in 0 1; do
  run_dir="$run_root/trace_$trace_mode"
  mkdir -p -- "$run_dir"
  run_log="$run_dir/run.log"
  run_status=0
  (
    cd -- "$run_dir"
    PCIE_AIP_TRACE="$trace_mode" timeout 600s "$sim_binary" \
      -no_save -exitstatus -ucli -do "$test_script" \
      +UVM_VERBOSITY=UVM_MEDIUM +ntb_random_seed=17
  ) >"$run_log" 2>&1 || run_status=$?
  if [[ "$run_status" != 0 ]]; then
    tail -n 80 "$run_log" >&2
    fail "trace=$trace_mode simulation exit=$run_status; log=$run_log"
  fi

  # 原始日志完整保留；另存无颜色副本仅供精确的行首门禁使用，不删除任何消息。
  # VCS -do 会回显整个 Tcl if/proc，因此检查必须识别实际输出格式，不能扫描
  # 裸 PAIR_LINK_FAIL/PASS 等词；尤其未执行的 error 分支不代表运行失败。
  check_log="$run_dir/run.no_color.log"
  awk '{ gsub(/\033\[[0-9;]*m/, ""); print }' "$run_log" >"$check_log"

  # no-ack 的旧结果、watchdog 强杀和 VCS/UVM 错误都不得由后续 PASS 掩盖。
  # UVM 汇总行单独检查，因此正常的 UVM_ERROR/UVM_FATAL : 0 不误判为错误。
  if grep -Eq -- '^\[AIP_TCL_BRIDGE\].*no ack|^\[(ERROR|FATAL)[[:space:]]*\]|^[[:space:]]*(Error: )?PAIR_LINK_FAIL:|^[[:space:]]*(Error-|Fatal([:[:space:]-]|$))|^UVM_(ERROR|FATAL)[[:space:]]+[^[:space:]:]|^PAIR_TCL_RESULT[[:space:]]+status=-?[1-9][0-9]*([[:space:]]|$)' "$check_log"; then
    fail "trace=$trace_mode contains an execution error; log=$run_log"
  fi
  if grep -Eq -- '^[[:space:]]*UVM_(ERROR|FATAL)[[:space:]]*:[[:space:]]*[1-9][0-9]*[[:space:]]*$' "$check_log"; then
    fail "trace=$trace_mode has nonzero UVM ERROR/FATAL count; log=$run_log"
  fi
  for severity in ERROR FATAL; do
    grep -Eq -- "^[[:space:]]*UVM_${severity}[[:space:]]*:[[:space:]]*0[[:space:]]*$" "$check_log" ||
      fail "trace=$trace_mode lacks zero UVM $severity summary; log=$run_log"
  done

  require_runtime_line "$check_log" '^PAIR_TCL_BOOTSTRAP_DONE[[:space:]]*$'
  require_runtime_line "$check_log" '^PAIR_TCL_RESULT status=0 result=PAIR_LINK_L0([[:space:]]|$)'
  require_runtime_line "$check_log" '^PAIR_TCL_LINK_PASS[[:space:]]*$'
  require_runtime_line "$check_log" '^UVM_INFO[[:space:]].*\[SVT_AIP_LINK\][[:space:]]+SVT_AIP_REPORT_PASS[[:space:]]*$'
  for event in start done; do
    require_runtime_line "$check_log" "^\\[INFO[[:space:]]*\\][[:space:]].*\\[USER_SEQ\\][[:space:]]+svt_pair_link_up[[:space:]]+$event[[:space:]]*$"
  done

  # trace=0 要求没有 wrapper 过程日志，但两组都必须满足上面的真实 L0 门禁。
  # trace=1 检查两端各自的 enable 起止及建链前/后的状态，不能只看单侧成功。
  if [[ "$trace_mode" == 0 ]]; then
    if grep -Eq -- '^UVM_INFO[[:space:]].*\[SVT_AIP_LINK\][[:space:]]+SVT_AIP_(COMMAND_ENTER|PRELINK_NOT_L0|ENABLE_(START|DONE)|STATE|PAIR_L0)([[:space:]]|$)' "$check_log"; then
      fail "trace=0 unexpectedly emitted wrapper trace; log=$run_log"
    fi
  else
    require_runtime_line "$check_log" '^UVM_INFO[[:space:]].*\[SVT_AIP_LINK\][[:space:]]+SVT_AIP_COMMAND_ENTER([[:space:]]|$)'
    require_runtime_line "$check_log" '^UVM_INFO[[:space:]].*\[SVT_AIP_LINK\][[:space:]]+SVT_AIP_PRELINK_NOT_L0([[:space:]]|$)'
    for side in RC EP; do
      require_runtime_line "$check_log" "^UVM_INFO[[:space:]].*\\[SVT_AIP_LINK\\][[:space:]]+SVT_AIP_ENABLE_START side=$side([[:space:]]|$)"
      require_runtime_line "$check_log" "^UVM_INFO[[:space:]].*\\[SVT_AIP_LINK\\][[:space:]]+SVT_AIP_ENABLE_DONE side=$side([[:space:]]|$)"
    done
    require_runtime_line "$check_log" '^UVM_INFO[[:space:]].*\[SVT_AIP_LINK\][[:space:]]+SVT_AIP_PAIR_L0([[:space:]]|$)'
  fi

  print_log_counts "$trace_mode" "$check_log"
  printf 'trace=%s log=%s\n' "$trace_mode" "$run_log"
done

printf 'SVT_AIP_LINK_CHECK_PASS logs=%s\n' "$run_root"
