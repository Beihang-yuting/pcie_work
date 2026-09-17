#!/usr/bin/env bash
# 所属层次：sim；10.11.10.53上运行AIP通用命令的真实双SVT双向Serial门禁。
# 本脚本拥有build/aip_cmd产物和每轮独立日志目录，不改变外部VIP/AIP源码。
# 默认同时验证宏关闭的独立编译和开启后的真实配置/双向Memory/错参不发包。
# 正常组保持零WARNING/ERROR/FATAL；同一binary另在独立目录执行预期link timeout组，
# 仅接受精确的PCIE_AIP_LINK_TIMEOUT一次FATAL，不把主机超时或崩溃算作通过。
# PCIE_AIP_SKIP_BUILD=1只复用已编译专用simv，调用者负责源码版本一致性。
set -euo pipefail

# 所有失败非零退出，并保留完整日志路径供定位，不删除失败运行目录。
fail() {
  printf 'SVT_AIP_CMD_CHECK_FAIL: %s\n' "$*" >&2
  exit 1
}

# 只匹配真实输出行，不能把UCLI回显puts或未执行error分支当成通过/失败。
require_line() {
  grep -Eq -- "$2" "$1" || fail "missing runtime line '$2'; log=$1"
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd -- "$script_dir"
build_dir="$script_dir/build/aip_cmd"
sim_binary="$build_dir/simv"
skip_build=${PCIE_AIP_SKIP_BUILD:-0}
[[ "$skip_build" == 0 || "$skip_build" == 1 ]] || fail "PCIE_AIP_SKIP_BUILD must be 0 or 1"
for dependency in AIP_CORE HOST_MEM_ROOT PCIE_SVT_ROOT DESIGNWARE_HOME; do
  dependency_path=${!dependency:-}
  [[ -n "$dependency_path" && -d "$dependency_path" ]] || fail "invalid $dependency=$dependency_path"
done
[[ -r "$AIP_CORE/dist/aip_init.tcl" ]] || fail "AIP bootstrap is missing"
command -v timeout >/dev/null || fail "timeout is missing"
mkdir -p -- "$build_dir"

# 隔离门禁无AIP/UVM/SVT/filelist依赖，能证明不开开关时仅include也不吃外部类型。
if [[ "$skip_build" == 0 ]]; then
  command -v vcs >/dev/null || fail "vcs is missing"
  mkdir -p -- "$build_dir/disabled"
  if ! vcs -full64 -sverilog +incdir+../uvm/aip \
      ../tests/pcie_svt_aip_disabled_top.sv -top pcie_svt_aip_disabled_top \
      -Mdir=build/aip_cmd/disabled/csrc -o build/aip_cmd/disabled/simv \
      >"$build_dir/disabled/build.log" 2>&1; then
    tail -n 60 "$build_dir/disabled/build.log" >&2
    fail "disabled guard compile failed; log=$build_dir/disabled/build.log"
  fi
  "$build_dir/disabled/simv" -no_save -exitstatus >"$build_dir/disabled/run.log" 2>&1 ||
    fail "disabled guard run failed; log=$build_dir/disabled/run.log"
  require_line "$build_dir/disabled/run.log" '^PCIE_AIP_DISABLED_PASS dependencies=none[[:space:]]*$'

  printf 'SVT_AIP_CMD_BUILD log=%s/build.log\n' "$build_dir"
  if ! vcs -full64 -sverilog -ntb_opts uvm-1.2 -debug_access+r+w+f \
      -lca -j2 -f pcie_svt_aip_cmd.f -top pcie_svt_aip_cmd_top \
      -Mdir=build/aip_cmd/csrc -o build/aip_cmd/simv >"$build_dir/build.log" 2>&1; then
    tail -n 80 "$build_dir/build.log" >&2
    fail "VCS compile failed; log=$build_dir/build.log"
  fi
fi
[[ -x "$sim_binary" ]] || fail "missing executable $sim_binary"

# 新目录避免旧PASS污染；所有业务使用同一binary和固定seed，可重复定位。
run_dir=$(mktemp -d "$build_dir/run.XXXXXX")
run_status=0
(
  cd -- "$run_dir"
  PCIE_AIP_EXPECT_TIMEOUT=0 timeout 900s "$sim_binary" -no_save -exitstatus -ucli \
    -do "$script_dir/../tests/pcie_svt_aip_cmd.tcl" \
    +UVM_VERBOSITY=UVM_MEDIUM +ntb_random_seed=17
) >"$run_dir/run.log" 2>&1 || run_status=$?
[[ "$run_status" == 0 ]] || {
  tail -n 100 "$run_dir/run.log" >&2
  fail "simulation exit=$run_status; log=$run_dir/run.log"
}
check_log="$run_dir/run.no_color.log"
awk '{ gsub(/\033\[[0-9;]*m/, ""); print }' "$run_dir/run.log" >"$check_log"
if grep -Eq '^\[AIP_TCL_BRIDGE\].*no ack|^\[(ERROR|FATAL)[[:space:]]*\]|^[[:space:]]*(Error: )?AIP_CMD_FAIL:|^[[:space:]]*(Error-|Fatal([:[:space:]-]|$))|^UVM_(WARNING|ERROR|FATAL)[[:space:]]+[^[:space:]:]' "$check_log"; then
  fail "execution error; log=$run_dir/run.log"
fi
for severity in WARNING ERROR FATAL; do
  require_line "$check_log" "^[[:space:]]*UVM_${severity}[[:space:]]*:[[:space:]]*0[[:space:]]*$"
  if grep -Eq "^[[:space:]]*UVM_${severity}[[:space:]]*:[[:space:]]*[1-9]" "$check_log"; then
    fail "nonzero UVM $severity count; log=$run_dir/run.log"
  fi
done
for marker in BOOTSTRAP_DONE LINK_PASS CFG_PASS RC_EP_PASS EP_RC_PASS BIDIR_PASS; do
  require_line "$check_log" "^CMD_TCL_${marker}[[:space:]]*$"
done
require_line "$check_log" '^CMD_TCL_REJECTIONS_PASS count=34[[:space:]]*$'
require_line "$check_log" '^PARALLEL_READ_PASS rc=COMPLETED_SC ep=COMPLETED_SC data=checked[[:space:]]*$'
require_line "$check_log" '^CMD_TCL_RESULT command=pair_check status=0 result=SERIAL_BIDIR_PASS rc_to_ep=12 ep_to_rc=6 backing=checked fields=checked[[:space:]]*$'
require_line "$check_log" '^UVM_INFO[[:space:]].*\[SVT_AIP_CMD\][[:space:]]+SVT_AIP_CMD_REPORT_PASS[[:space:]]*$'
for command_name in rc_link_up ep_link_up rc_cfg_rd rc_cfg_wr rc_mem_rd rc_mem_wr ep_mem_rd ep_mem_wr; do
  for event in start done; do
    require_line "$check_log" "^\\[INFO[[:space:]]*\\][[:space:]].*\\[USER_SEQ\\][[:space:]]+$command_name[[:space:]]+$event[[:space:]]*$"
  done
done
# 复用同一编译产物，但重启全新仿真，确保EP未被正常组先前的建链命令使能。
# FATAL先打印唯一报告及汇总，再由uvm_root $finish；53上的VCS配合
# -exitstatus实测返回3，其他调用方式可能返回0/1。退出码只做初筛，后面
# 必须精确核对FATAL内容/计数；124及所有信号/崩溃退出立即拒绝。
timeout_dir=$(mktemp -d "$build_dir/timeout.XXXXXX")
timeout_status=0
(
  cd -- "$timeout_dir"
  PCIE_AIP_EXPECT_TIMEOUT=1 timeout 300s "$sim_binary" -no_save -exitstatus -ucli \
    -do "$script_dir/../tests/pcie_svt_aip_cmd.tcl" \
    +UVM_VERBOSITY=UVM_MEDIUM +ntb_random_seed=17
) >"$timeout_dir/run.log" 2>&1 || timeout_status=$?
if [[ "$timeout_status" != 0 && "$timeout_status" != 1 && "$timeout_status" != 3 ]]; then
  tail -n 80 "$timeout_dir/run.log" >&2
  fail "expected-timeout process exit=$timeout_status; log=$timeout_dir/run.log"
fi
timeout_log="$timeout_dir/run.no_color.log"
awk '{ gsub(/\033\[[0-9;]*m/, ""); print }' "$timeout_dir/run.log" >"$timeout_log"
require_line "$timeout_log" '^CMD_TCL_BOOTSTRAP_DONE[[:space:]]*$'
require_line "$timeout_log" '^CMD_TCL_RESULT command=pair_check status=0 result=READY([[:space:]]|$)'
require_line "$timeout_log" '^CMD_TCL_EXPECT_TIMEOUT_BEGIN timeout_ns=1000 ep_enabled=0[[:space:]]*$'
require_line "$timeout_log" '^UVM_FATAL[[:space:]]+[^[:space:]:].*\[PCIE_AIP_LINK_TIMEOUT\][[:space:]]+ERROR rc_link_up: link timeout link_up=[01] ltssm=[0-9]+; simulation must stop[[:space:]]*$'
require_line "$timeout_log" '^[[:space:]]*UVM_WARNING[[:space:]]*:[[:space:]]*0[[:space:]]*$'
require_line "$timeout_log" '^[[:space:]]*UVM_ERROR[[:space:]]*:[[:space:]]*0[[:space:]]*$'
require_line "$timeout_log" '^[[:space:]]*UVM_FATAL[[:space:]]*:[[:space:]]*1[[:space:]]*$'

# 精确统计真实UVM消息而非源码回显/summary；任何其他FATAL、非零ERROR汇总
# 或正常通过标记都说明跑错分支/错误原因，不能由预期FATAL的存在掩盖。
if ! awk '
  /^UVM_FATAL[[:space:]]+[^[:space:]:]/ {
    fatal_count++
    if ($0 !~ /\[PCIE_AIP_LINK_TIMEOUT\]/) unexpected++
  }
  /^[[:space:]]*UVM_ERROR[[:space:]]*:/ {
    if ($NF != 0) unexpected++
  }
  /^[[:space:]]*UVM_FATAL[[:space:]]*:/ {
    if ($NF != 1) unexpected++
  }
  END { exit !(fatal_count == 1 && unexpected == 0) }
' "$timeout_log"; then
  fail "expected-timeout UVM reports are not exactly ERROR=0/FATAL=1; log=$timeout_dir/run.log"
fi
if grep -Eq '^\[AIP_TCL_BRIDGE\].*no ack|^\[(ERROR|FATAL)[[:space:]]*\]|^[[:space:]]*(Error: )?AIP_CMD_FAIL:|^[[:space:]]*(Error-|Fatal([:[:space:]-]|$))|^UVM_ERROR[[:space:]]+[^[:space:]:]|^CMD_TCL_(LINK_PASS|CFG_PASS|RC_EP_PASS|EP_RC_PASS|BIDIR_PASS|REJECTIONS_PASS)([[:space:]]|$)|^CMD_TCL_RESULT command=end_test|^UVM_INFO[[:space:]].*\[SVT_AIP_CMD\][[:space:]]+SVT_AIP_CMD_REPORT_PASS|^\[INFO[[:space:]]*\][[:space:]].*\[USER_SEQ\][[:space:]]+ep_link_up[[:space:]]+start' "$timeout_log"; then
  fail "expected-timeout has unexpected execution or normal-PASS output; log=$timeout_dir/run.log"
fi
printf 'SVT_AIP_CMD_TIMEOUT_CHECK_PASS exit=%s logs=%s\n' "$timeout_status" "$timeout_dir"
printf 'SVT_AIP_CMD_CHECK_PASS logs=%s timeout_logs=%s\n' "$run_dir" "$timeout_dir"
