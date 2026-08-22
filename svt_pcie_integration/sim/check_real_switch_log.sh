#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 compile|cfg|link|enum|traffic LOG" >&2
  exit 2
fi

mode=$1
log=$2

case "$mode" in
  compile|cfg|link|enum|traffic)
    ;;
  *)
    echo "invalid mode: $mode (expected compile|cfg|link|enum|traffic)" >&2
    exit 2
    ;;
esac

if [[ ! -f $log || ! -r $log ]]; then
  echo "log is not a readable regular file: $log" >&2
  exit 2
fi

grep_count() {
  local output
  local status

  if output=$(grep "$@"); then
    status=0
  else
    status=$?
  fi

  case "$status" in
    0)
      printf '%s\n' "$output"
      ;;
    1)
      printf '0\n'
      ;;
    *)
      echo "log read failed: grep_status=$status log=$log" >&2
      return 2
      ;;
  esac
}

count_marker() {
  grep_count -a -E -c -- "^UVM_(INFO|WARNING|ERROR|FATAL)([[:space:]]+[^[:space:]]+)?[[:space:]]+@[[:space:]]+[^:]+:[[:space:]]+[^[:space:]]+[[:space:]]+\\[$1\\]([[:space:]]|$)" "$log"
}

mismatch=0

check_zero_summary() {
  local severity=$1
  local summary_count
  local zero_count

  summary_count=$(grep_count -a -E -c -- "^${severity}[[:space:]]*:" "$log")
  zero_count=$(grep_count -a -E -c -- "^${severity}[[:space:]]*:[[:space:]]*0[[:space:]]*$" "$log")
  if [[ $summary_count -ne 1 || $zero_count -ne 1 ]]; then
    echo "summary mismatch: severity=$severity expected_total=1 expected_zero=1 actual_total=$summary_count actual_zero=$zero_count log=$log" >&2
    mismatch=1
  fi
}

check_marker_count() {
  local marker=$1
  local expected=$2
  local actual

  actual=$(count_marker "$marker")
  if [[ $actual -ne $expected ]]; then
    echo "marker count mismatch: mode=$mode marker=$marker expected=$expected actual=$actual log=$log" >&2
    mismatch=1
  fi
}

markers=(
  REAL_SWITCH_COMPILE_READY
  MULTI_EP_BAR_CHECK
  MULTI_EP_BAR_SKIP
  CFG_INIT_DONE
  RC_HOST_MEMORY_RANGE_READY
  REAL_SWITCH_CFG_INIT_PASS
  REAL_SWITCH_LINK_PASS
  REAL_SWITCH_ALL_LINKS_PASS
  REAL_SWITCH_ENUM_PASS
  REAL_SWITCH_TRAFFIC_FLOW_PASS
  REAL_SWITCH_TRAFFIC_PASS
)

case "$mode" in
  compile) expected=(1 0 0 0 0 0 0 0 0 0 0) ;;
  cfg)     expected=(0 24 1 5 1 1 0 0 0 0 0) ;;
  link)    expected=(0 24 1 5 1 0 5 1 0 0 0) ;;
  enum)    expected=(0 24 1 5 1 0 5 1 1 0 0) ;;
  traffic) expected=(0 24 1 5 1 0 5 1 1 8 1) ;;
esac

check_zero_summary UVM_WARNING
check_zero_summary UVM_ERROR
check_zero_summary UVM_FATAL

for index in "${!markers[@]}"; do
  check_marker_count "${markers[$index]}" "${expected[$index]}"
done

if [[ $mismatch -ne 0 ]]; then
  exit 1
fi
