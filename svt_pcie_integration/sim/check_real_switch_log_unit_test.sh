#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
checker="$script_dir/check_real_switch_log.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

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

fail() {
  echo "REAL_SWITCH_LOG_CHECKER_UNIT_FAIL: $*" >&2
  exit 1
}

expected_count() {
  local mode=$1
  local marker=$2

  case "$mode:$marker" in
    compile:REAL_SWITCH_COMPILE_READY) echo 1 ;;
    cfg:MULTI_EP_BAR_CHECK|link:MULTI_EP_BAR_CHECK|enum:MULTI_EP_BAR_CHECK|traffic:MULTI_EP_BAR_CHECK) echo 24 ;;
    cfg:MULTI_EP_BAR_SKIP|link:MULTI_EP_BAR_SKIP|enum:MULTI_EP_BAR_SKIP|traffic:MULTI_EP_BAR_SKIP) echo 1 ;;
    cfg:CFG_INIT_DONE|link:CFG_INIT_DONE|enum:CFG_INIT_DONE|traffic:CFG_INIT_DONE) echo 5 ;;
    cfg:RC_HOST_MEMORY_RANGE_READY|link:RC_HOST_MEMORY_RANGE_READY|enum:RC_HOST_MEMORY_RANGE_READY|traffic:RC_HOST_MEMORY_RANGE_READY) echo 1 ;;
    cfg:REAL_SWITCH_CFG_INIT_PASS) echo 1 ;;
    link:REAL_SWITCH_LINK_PASS|enum:REAL_SWITCH_LINK_PASS|traffic:REAL_SWITCH_LINK_PASS) echo 5 ;;
    link:REAL_SWITCH_ALL_LINKS_PASS|enum:REAL_SWITCH_ALL_LINKS_PASS|traffic:REAL_SWITCH_ALL_LINKS_PASS) echo 1 ;;
    enum:REAL_SWITCH_ENUM_PASS|traffic:REAL_SWITCH_ENUM_PASS) echo 1 ;;
    traffic:REAL_SWITCH_TRAFFIC_FLOW_PASS) echo 8 ;;
    traffic:REAL_SWITCH_TRAFFIC_PASS) echo 1 ;;
    *) echo 0 ;;
  esac
}

append_marker() {
  local log=$1
  local marker=$2
  local count=$3
  local index

  for ((index = 1; index <= count; index++)); do
    printf 'UVM_INFO fixture.sv(%d) @ 0: reporter [%s] fixture_index=%d\n' \
      "$index" "$marker" "$index" >> "$log"
  done
}

fixture_marker_count() {
  local log=$1
  local marker=$2

  grep -a -E -c -- "^UVM_(INFO|WARNING|ERROR|FATAL)([[:space:]]+[^[:space:]]+)?[[:space:]]+@[[:space:]]+[^:]+:[[:space:]]+[^[:space:]]+[[:space:]]+\\[$marker\\]([[:space:]]|$)" "$log" || true
}

write_fixture() {
  local mode=$1
  local log=$2
  local marker

  : > "$log"
  printf 'UVM_INFO fixture.sv(0) @ 0: reporter [FIXTURE_NOTE] message-only marker names:' >> "$log"
  printf ' %s' "${markers[@]}" >> "$log"
  printf '\n' >> "$log"
  for marker in "${markers[@]}"; do
    append_marker "$log" "$marker" "$(expected_count "$mode" "$marker")"
  done
  printf 'UVM_WARNING :    0\nUVM_ERROR :    0\nUVM_FATAL :    0\n' >> "$log"
}

validate_fixture() {
  local mode=$1
  local log=$2
  local marker
  local expected
  local actual
  local severity

  for marker in "${markers[@]}"; do
    expected=$(expected_count "$mode" "$marker")
    actual=$(fixture_marker_count "$log" "$marker")
    [[ $actual -eq $expected ]] ||
      fail "fixture construction error: mode=$mode marker=$marker expected=$expected actual=$actual"
  done
  for severity in UVM_WARNING UVM_ERROR UVM_FATAL; do
    [[ $(grep -a -E -c -- "^${severity}[[:space:]]*:[[:space:]]*0[[:space:]]*$" "$log" || true) -eq 1 ]] ||
      fail "fixture construction error: mode=$mode severity=$severity"
  done
}

expect_exit() {
  local expected=$1
  local label=$2
  shift 2
  local output
  local status

  set +e
  output=$("$@" 2>&1)
  status=$?
  set -e
  last_output=$output
  if [[ $status -ne $expected ]]; then
    printf 'REAL_SWITCH_LOG_CHECKER_UNIT_FAIL: %s expected_exit=%d actual_exit=%d\n%s\n' \
      "$label" "$expected" "$status" "$output" >&2
    exit 1
  fi
}

for mode in compile cfg link enum traffic; do
  write_fixture "$mode" "$tmp_dir/$mode.log"
  validate_fixture "$mode" "$tmp_dir/$mode.log"
done

ln -s -- "$tmp_dir/compile.log" "$tmp_dir/compile_symlink.log"
ln -s -- "$tmp_dir/missing.log" "$tmp_dir/broken_symlink.log"
mkdir "$tmp_dir/grep_read_error_bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'echo "grep: simulated log read error" >&2' \
  'exit 2' > "$tmp_dir/grep_read_error_bin/grep"
chmod +x "$tmp_dir/grep_read_error_bin/grep"

if [[ ! -x $checker ]]; then
  echo "REAL_SWITCH_LOG_CHECKER_EXPECTED_RED: checker missing or not executable: $checker" >&2
  exit 1
fi

last_output=
expect_exit 0 "valid log symlink" \
  "$checker" compile "$tmp_dir/compile_symlink.log"

positive=0
for mode in compile cfg link enum traffic; do
  expect_exit 0 "positive $mode" "$checker" "$mode" "$tmp_dir/$mode.log"
  ((positive += 1))
done

negative=0
marker_modes=(compile cfg cfg cfg cfg cfg link link enum traffic traffic)
for index in "${!markers[@]}"; do
  marker=${markers[$index]}
  mode=${marker_modes[$index]}
  negative_log="$tmp_dir/negative_marker_${index}.log"
  cp -- "$tmp_dir/$mode.log" "$negative_log"
  append_marker "$negative_log" "$marker" 1
  expect_exit 1 "duplicate marker $marker" "$checker" "$mode" "$negative_log"
  ((negative += 1))
done

for severity in UVM_WARNING UVM_ERROR UVM_FATAL; do
  negative_log="$tmp_dir/negative_summary_${severity}.log"
  cp -- "$tmp_dir/compile.log" "$negative_log"
  sed -i -E "s/^${severity}[[:space:]]*:[[:space:]]*0[[:space:]]*$/${severity} :    1/" "$negative_log"
  expect_exit 1 "nonzero summary $severity" "$checker" compile "$negative_log"
  ((negative += 1))
done

expect_exit 2 "missing arguments" "$checker"
((negative += 1))
expect_exit 2 "invalid mode" "$checker" invalid "$tmp_dir/compile.log"
((negative += 1))
expect_exit 2 "directory log" "$checker" compile "$tmp_dir"
((negative += 1))
expect_exit 2 "broken log symlink" "$checker" compile "$tmp_dir/broken_symlink.log"
((negative += 1))

expect_exit 2 "grep read error" env \
  PATH="$tmp_dir/grep_read_error_bin:$PATH" \
  "$checker" compile "$tmp_dir/compile.log"
[[ $(grep -F -c -- 'grep: simulated log read error' <<< "$last_output") -eq 1 ]] ||
  fail "grep read error must be preserved exactly once"

[[ $positive -eq 5 ]] || fail "positive count expected=5 actual=$positive"
[[ $negative -eq 18 ]] || fail "negative count expected=18 actual=$negative"
echo "REAL_SWITCH_LOG_CHECKER_UNIT_PASS positive=$positive negative=$negative"
