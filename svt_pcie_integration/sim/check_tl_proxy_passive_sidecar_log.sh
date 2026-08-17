#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 baseline|sidecar-link|full LOG" >&2
  exit 2
fi

mode=$1
log=$2

case "$mode" in
  baseline|sidecar-link|full)
    ;;
  *)
    echo "invalid mode: $mode" >&2
    exit 2
    ;;
esac

if [[ ! -r $log ]]; then
  echo "unreadable log: $log" >&2
  exit 2
fi

count_marker() {
  grep -a -E -c -- "^UVM_(INFO|WARNING|ERROR|FATAL)([[:space:]]+[^[:space:]]+)?[[:space:]]+@[[:space:]]+[^:]+:[[:space:]]+[^[:space:]]+[[:space:]]+\\[$1\\]([[:space:]]|$)" "$log" || true
}

check_zero_summary() {
  local severity=$1
  local summary_count
  local zero_count

  summary_count=$(grep -a -E -c -- "^${severity}[[:space:]]*:" "$log" || true)
  zero_count=$(grep -a -E -c -- "^${severity}[[:space:]]*:[[:space:]]*0[[:space:]]*$" "$log" || true)
  test "$summary_count" -eq 1
  test "$zero_count" -eq 1
}

test "$(count_marker TL_PROXY_PASSIVE_SIDECAR_PROBE_BLOCKED)" -eq 0
check_zero_summary UVM_WARNING
check_zero_summary UVM_ERROR
check_zero_summary UVM_FATAL

if grep -a -Eiq -- 'unexpected[^[:cntrl:]]*completion|spurious[^[:cntrl:]]*completion' "$log"; then
  echo "unexpected/spurious Completion diagnostic found in $log" >&2
  exit 1
fi

case "$mode" in
  baseline)
    test "$(count_marker TL_PROXY_FOUR_ACTIVE_BASELINE_PASS)" -eq 1
    test "$(count_marker TL_PROXY_SOURCE_DRIVER_END_TRACE)" -eq 0
    test "$(count_marker TL_PROXY_PASSIVE_SIDECAR_STAGE_A_PASS)" -eq 0
    test "$(count_marker TL_PROXY_PASSIVE_SIDECAR_LINK_ONLY_PASS)" -eq 0
    test "$(count_marker TL_PROXY_PASSIVE_SIDECAR_MWR_STAGE_PASS)" -eq 0
    test "$(count_marker TL_PROXY_PASSIVE_SIDECAR_CFG_STAGE_PASS)" -eq 0
    test "$(count_marker TL_PROXY_PASSIVE_SIDECAR_PROBE_PASS)" -eq 0
    ;;
  sidecar-link)
    test "$(count_marker TL_PROXY_FOUR_ACTIVE_BASELINE_PASS)" -eq 0
    test "$(count_marker TL_PROXY_SOURCE_DRIVER_END_TRACE)" -eq 0
    test "$(count_marker TL_PROXY_PASSIVE_SIDECAR_STAGE_A_PASS)" -eq 1
    test "$(count_marker TL_PROXY_PASSIVE_SIDECAR_LINK_ONLY_PASS)" -eq 1
    test "$(count_marker TL_PROXY_PASSIVE_SIDECAR_MWR_STAGE_PASS)" -eq 0
    test "$(count_marker TL_PROXY_PASSIVE_SIDECAR_CFG_STAGE_PASS)" -eq 0
    test "$(count_marker TL_PROXY_PASSIVE_SIDECAR_PROBE_PASS)" -eq 0
    ;;
  full)
    test "$(count_marker TL_PROXY_FOUR_ACTIVE_BASELINE_PASS)" -eq 0
    test "$(count_marker TL_PROXY_SOURCE_DRIVER_END_TRACE)" -eq 1
    test "$(count_marker TL_PROXY_PASSIVE_SIDECAR_STAGE_A_PASS)" -eq 1
    test "$(count_marker TL_PROXY_PASSIVE_SIDECAR_LINK_ONLY_PASS)" -eq 0
    test "$(count_marker TL_PROXY_PASSIVE_SIDECAR_MWR_STAGE_PASS)" -eq 1
    test "$(count_marker TL_PROXY_PASSIVE_SIDECAR_CFG_STAGE_PASS)" -eq 1
    test "$(count_marker TL_PROXY_PASSIVE_SIDECAR_PROBE_PASS)" -eq 1
    ;;
esac
