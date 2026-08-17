# SVT PCIe Passive-Sidecar Transparent Proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove that two standalone passive R-2020.12 SERDES sidecars provide a public raw-TLP observation boundary for an exactly-once, transparent two-link PCIe proxy that preserves the original Configuration Read Requester ID and full 10-bit Tag.

**Architecture:** Keep four full active Device Agents on two Gen4 x4 Serial links, and attach one independent, input-only standalone passive Device Agent to each link from the Proxy-side perspective. The Ingress Target callback clones and suppresses requests, bridge worker threads reinject raw clones through the opposite active `tlp_seqr`, and the Egress passive RX stream supplies the original Completion for reverse reinjection; independent passive RX/TX observations compare the physical TLP DWORD arrays end to end.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys SVT PCIe R-2020.12, VCS W-2024.09-SP1, Bash, two Gen4 x4 Serial links on `10.11.10.53`.

---

## Execution Contract

- Work only in `/home/ryan/.config/superpowers/worktrees/pcie_work/svt-switch-proxy` on branch `feature/svt-switch-proxy`.
- This plan implements only Task 1 of `docs/superpowers/plans/2026-08-15-svt-pcie-switch-proxy.md`; do not begin enumeration, routing, Type conversion, arbitration, or the production five-port topology.
- Run every compile, elaboration, simulation, and performance measurement on `ubuntu@10.11.10.53` through a Bash login shell.
- Stage files under `/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work`; keep `/home/ubuntu/synopsys/designware_vip_R-2020.12` read-only.
- Use only declarations documented by the installed R-2020.12 HTML. Do not inspect or modify private vendor implementation source.
- Do not use hierarchical `force`, `deposit`, a report catcher, severity changes, a Driver App reconstruction path, or synthetic Completion generation.
- Keep all four active Agents, both real Serial links, explicit public
  `pl_status.ltssm_state == svt_pcie_types::L0` checks in addition to
  `link_up`, Gen4 speed, and x4 width, the 205 ns reset, and
  `+define+SVT_PCIE_ENABLE_10_BIT_TAGS`.
- Every callback and analysis `write()` method may clone, validate, increment a counter, and call `mailbox::try_put`; it may not wait, perform a blocking `put`, or start a sequence.
- Treat any unexpected or spurious Completion report from an active Agent as a feasibility failure. Do not suppress or downgrade it.
- Retain the two Mapper probe files until the full sidecar probe is GREEN. Delete them only in Task 7.
- Produce one atomic Task 1 implementation commit after the clean GREEN run. Do not commit partial Stage A/B implementations.

The approved design is
`docs/superpowers/specs/2026-08-17-svt-pcie-passive-sidecar-proxy-design.md`.

## Public R-2020.12 Evidence Used by This Plan

Read these files on `10.11.10.53` before editing if any signature is in doubt:

```text
/home/ubuntu/synopsys/designware_vip_R-2020.12/vip/svt/pcie_svt/R-2020.12/doc/
pcie_svt_uvm_class_reference/html/interfaces.html
pcie_svt_uvm_class_reference/html/configuration/class_svt_pcie_configuration.html
pcie_svt_uvm_class_reference/html/configuration/class_svt_pcie_device_configuration.html
pcie_svt_uvm_class_reference/html/configuration/class_svt_pcie_tl_configuration.html
pcie_svt_uvm_class_reference/html/monitor/class_svt_pcie_tl_monitor.html
pcie_svt_uvm_class_reference/html/status/class_svt_pcie_pl_status.html
pcie_svt_uvm_class_reference/html/callback/class_svt_pcie_driver_app_callback.html
pcie_svt_uvm_class_reference/html/transaction/class_svt_pcie_tlp.html
```

The relevant public contract is:

- `svt_pcie_serdes_x4_if(reset)` has RX/TX data and clocks for four lanes.
- Its `monitor_modport` declares RX data, TX data, `clkreq_n`, `wake_n`, and `reset` as inputs; its RX/TX clocking blocks only sample their respective data.
- `svt_pcie_configuration::serdes_x4_if` is documented as “only used by passive monitor in standalone mode.”
- `svt_pcie_device_configuration::set_initial_values_via_unified_vif()` is documented as inapplicable to passive monitors.
- `is_active=0` enables only the monitor; `enable_monitor=1` is mutually exclusive with an active Agent.
- `svt_pcie_tl_monitor` exposes public `rx_tlp_observed_port` and `tx_tlp_observed_port` analysis ports.
- `svt_pcie_tlp::get_dword_array()` returns the encoded TLP header and payload DWORDs, excluding Data Link sequence/LCRC and PHY framing.
- `svt_pcie_driver_app_callback::transaction_ended()` is called when the link partner has completed a Driver App transaction.

## File Structure

- Create `svt_pcie_integration/rtl/pcie_svt_passive_sidecar_tap.sv`: input-only x4 tap macros that map a project Serial port into a standalone passive interface from the monitored Proxy's perspective.
- Modify `svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv`: add the two sidecars, passive Agents, failure gate, sidecar subscribers, wire-DWORD checker, sink/source callbacks, staged traffic, runtime modes, and exact counters.
- Verify `svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.f`: retain the loader defines, 10-bit Tag define, R-2020.12 include/library paths, and the single probe compilation unit.
- Create `svt_pcie_integration/sim/check_tl_proxy_passive_sidecar_log.sh`: deterministic acceptance checks for link-only baseline, link-only sidecars, and the full traffic run.
- Modify `svt_pcie_integration/sim/README.md`: document the final clean build, three runs, expected markers, and performance artifacts.
- Delete `svt_pcie_integration/sim/pcie_svt_mapper_probe.sv` and `svt_pcie_integration/sim/pcie_svt_mapper_probe.f` only after every Task 1 gate is GREEN.

### Task 1: Preserve RED Evidence and Add the Acceptance Oracle

**Files:**
- Create: `svt_pcie_integration/sim/check_tl_proxy_passive_sidecar_log.sh`
- Reference only: remote `build_tl_proxy_probe_cfg_clean/run_cbpool.log`
- Test: Bash syntax and an intentional failure against the old active-callback log

- [ ] **Step 1: Confirm the active receive surfaces remain RED**

Run:

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim
  set -euo pipefail
  actual_pass=\$(grep -a -E -c -- \
    \"^UVM_(INFO|WARNING|ERROR|FATAL)([[:space:]]+[^[:space:]]+)?[[:space:]]+@[[:space:]]+[^:]+:[[:space:]]+[^[:space:]]+[[:space:]]+\\[TL_PROXY_API_PROBE_PASS\\]([[:space:]]|\$)\" \
    build_tl_proxy_probe_cfg_clean/run_cbpool.log || true)
  actual_blocked=\$(grep -a -E -c -- \
    \"^UVM_(INFO|WARNING|ERROR|FATAL)([[:space:]]+[^[:space:]]+)?[[:space:]]+@[[:space:]]+[^:]+:[[:space:]]+[^[:space:]]+[[:space:]]+\\[TL_PROXY_API_PROBE_BLOCKED\\]([[:space:]]|\$)\" \
    build_tl_proxy_probe_cfg_clean/run_cbpool.log || true)
  tuple_count=\$(grep -a -F -c -- \
    \"ingress_capture=0 ingress_forward=0 reverse_capture=0 reverse_forward=0\" \
    build_tl_proxy_probe_cfg_clean/run_cbpool.log || true)
  test \"\$actual_pass\" -eq 0
  test \"\$actual_blocked\" -eq 1
  test \"\$tuple_count\" -eq 1
  printf \"actual PASS=%s / actual BLOCKED=%s / tuple=%s\\n\" \
    \"\$actual_pass\" \"\$actual_blocked\" \"\$tuple_count\"
"'
```

Expected: exit zero and `actual PASS=0 / actual BLOCKED=1 / tuple=1`. Only
anchored, real UVM report lines count as markers; the duplicate entries under
`** Report counts by id` do not count. The old active TL callback captured no
request and never emitted a PASS marker.

- [ ] **Step 2: Create the log checker before changing the probe**

Create `svt_pcie_integration/sim/check_tl_proxy_passive_sidecar_log.sh` with:

```bash
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
```

Mark it executable:

```bash
chmod +x svt_pcie_integration/sim/check_tl_proxy_passive_sidecar_log.sh
```

- [ ] **Step 3: Verify the acceptance-oracle boundaries and the old log remains RED**

Create `/tmp/tl_proxy_passive_sidecar_full_with_summary.log` outside the
repository with exactly this synthetic valid full log:

```text
UVM_INFO @ 1000: uvm_test_top [TL_PROXY_PASSIVE_SIDECAR_STAGE_A_PASS] both active links and passive sidecars reached L0
UVM_INFO @ 2000: uvm_test_top [TL_PROXY_PASSIVE_SIDECAR_MWR_STAGE_PASS] memory write forwarded exactly once
UVM_INFO @ 3000: uvm_test_top [TL_PROXY_SOURCE_DRIVER_END_TRACE] transaction_type=CFG_RD completion_status=SUCCESSFUL cfg_read_success_count=1
UVM_INFO @ 4000: uvm_test_top [TL_PROXY_PASSIVE_SIDECAR_CFG_STAGE_PASS] configuration read preserved requester ID and tag
UVM_INFO @ 5000: uvm_test_top [TL_PROXY_PASSIVE_SIDECAR_PROBE_PASS] passive sidecar probe passed

--- UVM Report Summary ---

** Report counts by id
[TL_PROXY_PASSIVE_SIDECAR_STAGE_A_PASS] 1
[TL_PROXY_PASSIVE_SIDECAR_MWR_STAGE_PASS] 1
[TL_PROXY_SOURCE_DRIVER_END_TRACE] 1
[TL_PROXY_PASSIVE_SIDECAR_CFG_STAGE_PASS] 1
[TL_PROXY_PASSIVE_SIDECAR_PROBE_PASS] 1

** Report counts by severity
UVM_INFO :    5
UVM_WARNING :    0
UVM_ERROR :    0
UVM_FATAL :    0
```

Create the following additional temporary logs under `/tmp`, never in the
repository. Every valid/marker-focused log must contain exactly one warning,
error, and fatal summary line, each with value zero; both `: 0` and `:    0`
spacing are valid. Marker lines use the real UVM form
`UVM_INFO optional_file_token @ time: reporter [REPORT_ID] message`.

| Temporary path | Contents and expected profile |
| --- | --- |
| `/tmp/tl_proxy_valid_baseline.log` | `baseline`: baseline only; include a file token |
| `/tmp/tl_proxy_valid_sidecar_link.log` | `sidecar-link`: Stage A and link-only only; omit the file token |
| `/tmp/tl_proxy_id_body_mention.log` | Full markers except PROBE is only mentioned in the body after `[OTHER_ID]`; reject |
| `/tmp/tl_proxy_extra_error_nonzero.log` | Valid full plus a second `UVM_ERROR : 1`; reject |
| `/tmp/tl_proxy_duplicate_error_zero.log` | Valid full plus a duplicate `UVM_ERROR : 0`; reject |
| `/tmp/tl_proxy_baseline_forbidden_markers.log` | Baseline plus link-only, MWr, and CFG; reject |
| `/tmp/tl_proxy_sidecar_forbidden_markers.log` | Stage A/link-only plus baseline, MWr, and CFG; reject |
| `/tmp/tl_proxy_full_forbidden_markers.log` | Valid full plus baseline and link-only; reject |
| `/tmp/tl_proxy_source_marker_missing.log` | Valid full without `TL_PROXY_SOURCE_DRIVER_END_TRACE`; reject |
| `/tmp/tl_proxy_source_marker_duplicate.log` | Valid full with two `TL_PROXY_SOURCE_DRIVER_END_TRACE` reports; reject |
| `/tmp/tl_proxy_baseline_source_marker.log` | Valid baseline plus `TL_PROXY_SOURCE_DRIVER_END_TRACE`; reject |
| `/tmp/tl_proxy_sidecar_source_marker.log` | Valid sidecar-link plus `TL_PROXY_SOURCE_DRIVER_END_TRACE`; reject |
| `/tmp/tl_proxy_invalid_mode_malformed.log` | Malformed readable content used with an invalid mode; exit exactly 2 |
| `/tmp/tl_proxy_checker_option_name/--color=never` | Valid baseline content, passed as bare `--color=never`; accept |
| `/tmp/tl_proxy_checker_option_name/--color=always` | Valid baseline plus an unexpected Completion diagnostic; reject |

Then run locally from the worktree root:

```bash
set -euo pipefail
checker=$(pwd)/svt_pcie_integration/sim/check_tl_proxy_passive_sidecar_log.sh

bash -n "$checker"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$checker"
fi

"$checker" baseline /tmp/tl_proxy_valid_baseline.log
"$checker" sidecar-link /tmp/tl_proxy_valid_sidecar_link.log
"$checker" full /tmp/tl_proxy_passive_sidecar_full_with_summary.log

for mode_log in \
  "full:/tmp/tl_proxy_id_body_mention.log" \
  "full:/tmp/tl_proxy_extra_error_nonzero.log" \
  "full:/tmp/tl_proxy_duplicate_error_zero.log" \
  "baseline:/tmp/tl_proxy_baseline_forbidden_markers.log" \
  "sidecar-link:/tmp/tl_proxy_sidecar_forbidden_markers.log" \
  "full:/tmp/tl_proxy_full_forbidden_markers.log" \
  "full:/tmp/tl_proxy_source_marker_missing.log" \
  "full:/tmp/tl_proxy_source_marker_duplicate.log" \
  "baseline:/tmp/tl_proxy_baseline_source_marker.log" \
  "sidecar-link:/tmp/tl_proxy_sidecar_source_marker.log"; do
  mode=${mode_log%%:*}
  log=${mode_log#*:}
  if "$checker" "$mode" "$log"; then
    echo "ERROR: acceptance oracle accepted invalid fixture $log" >&2
    exit 1
  fi
done

set +e
"$checker" invalid-mode /tmp/tl_proxy_invalid_mode_malformed.log
invalid_mode_status=$?
set -e
test "$invalid_mode_status" -eq 2

(
  cd /tmp/tl_proxy_checker_option_name
  "$checker" baseline --color=never
  if "$checker" baseline --color=always; then
    echo "ERROR: option-like Completion fixture was accepted" >&2
    exit 1
  fi
)

scp ubuntu@10.11.10.53:/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim/build_tl_proxy_probe_cfg_clean/run_cbpool.log /tmp/tl_proxy_active_callback_red.log
if "$checker" full /tmp/tl_proxy_active_callback_red.log; then
  echo "ERROR: the new acceptance oracle accepted old RED evidence" >&2
  exit 1
fi
```

Expected: syntax and optional ShellCheck pass; valid baseline, sidecar-link,
full, and the option-like valid filename are accepted. A body-only marker,
duplicate/nonzero severity summaries, every forbidden profile-marker
combination, the option-like Completion log, and the old active-callback log
are rejected. Invalid mode exits exactly 2 before inspecting malformed log
content. The report-count summary duplicates do not affect marker counts.

### Task 2: Add Input-Only HDL Taps and Standalone Passive Agents

**Files:**
- Create: `svt_pcie_integration/rtl/pcie_svt_passive_sidecar_tap.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv:1-15,326-455,894-end`
- Verify: `svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.f`
- Test: remote Stage A clean compile/elaboration and link-only run

- [ ] **Step 1: Add the x4 tap macro**

Create `svt_pcie_integration/rtl/pcie_svt_passive_sidecar_tap.sv` with:

```systemverilog
`ifndef PCIE_SVT_PASSIVE_SIDECAR_TAP_SV
`define PCIE_SVT_PASSIVE_SIDECAR_TAP_SV

// The standalone monitor is oriented as the monitored Proxy port:
//   monitor RX samples peer -> Proxy traffic;
//   monitor TX samples Proxy -> peer traffic.
// Every assignment terminates on the standalone monitor interface. Nothing
// in this macro drives the active Serial port or an active SVT interface.
`define PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, lane) \
  assign mon_if.rx_clk_``lane``   = proxy_port.rx_clk[lane]; \
  assign mon_if.rx_datap_``lane`` = proxy_port.tx_p[lane]; \
  assign mon_if.rx_datan_``lane`` = proxy_port.tx_n[lane]; \
  assign mon_if.tx_clk_``lane``   = proxy_port.active_tx_transmit_clk[lane]; \
  assign mon_if.tx_datap_``lane`` = proxy_port.rx_p[lane]; \
  assign mon_if.tx_datan_``lane`` = proxy_port.rx_n[lane];

`define PCIE_SVT_TAP_PASSIVE_SERDES_X4(mon_if, proxy_port) \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 0) \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 1) \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 2) \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 3)

`endif
```

The mapping is deliberately based on the already-proven active adapter and peer harness:

```text
proxy_port.tx_p / tx_n  = traffic arriving at the Proxy = passive RX
proxy_port.rx_p / rx_n  = traffic transmitted by Proxy  = passive TX
proxy_port.rx_clk       = peer transmit clock            = passive RX clock
proxy_port.active_tx_transmit_clk = Proxy transmit clock = passive TX clock
```

- [ ] **Step 2: Instantiate independent standalone interfaces in the HDL top**

Add the include after the existing Serial adapter/peer-harness includes:

```systemverilog
`include "pcie_svt_passive_sidecar_tap.sv"
```

In `pcie_svt_tl_proxy_probe_top`, after the four project Serial interfaces, add:

```systemverilog
svt_pcie_serdes_x4_if ingress_sidecar_serdes(reset[1]);
svt_pcie_serdes_x4_if egress_sidecar_serdes(reset[2]);

`PCIE_SVT_TAP_PASSIVE_SERDES_X4(
  ingress_sidecar_serdes, ingress_proxy_serial)
`PCIE_SVT_TAP_PASSIVE_SERDES_X4(
  egress_sidecar_serdes, egress_proxy_serial)

assign ingress_sidecar_serdes.clkreq_n = clkreq_n[0];
assign ingress_sidecar_serdes.wake_n = wake_n;
assign egress_sidecar_serdes.clkreq_n = clkreq_n[1];
assign egress_sidecar_serdes.wake_n = wake_n;
```

Do not instantiate `svt_pcie_single_port_device_agent_hdl` for either sidecar. They are standalone passive interfaces, not two more active HDL transactors.

Before `run_test`, publish the two independent handles:

```systemverilog
uvm_config_db#(virtual svt_pcie_serdes_x4_if)::set(
  null, "uvm_test_top", "ingress_sidecar_vif", ingress_sidecar_serdes);
uvm_config_db#(virtual svt_pcie_serdes_x4_if)::set(
  null, "uvm_test_top", "egress_sidecar_vif", egress_sidecar_serdes);
```

- [ ] **Step 3: Add runtime modes and passive fields to the test**

Before adding the fields, add the shared failure gate below the package forward
declarations. Stage A failures must already use the final BLOCKED marker:

```systemverilog
class tl_proxy_probe_control extends uvm_component;
  bit blocked_marker_emitted;

  `uvm_component_utils(tl_proxy_probe_control)

  function new(string name = "tl_proxy_probe_control",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void fail(string message, string fatal_message);
    if (!blocked_marker_emitted) begin
      blocked_marker_emitted = 1'b1;
      `uvm_info("TL_PROXY_PASSIVE_SIDECAR_PROBE_BLOCKED",
        message, UVM_NONE)
    end
    `uvm_fatal("TL_PROXY_PASSIVE_SIDECAR_PROBE", fatal_message)
  endfunction
endclass
```

Create `control` as the first probe-owned component in `build_phase`. Replace
the test's old `blocked_fatal` body with `control.fail(message,
fatal_message)`, and assign `control` to every callback/component before it can
receive traffic.

Add these fields to `pcie_svt_tl_proxy_probe_test`:

```systemverilog
bit sidecars_enabled;
bit link_only;
virtual svt_pcie_serdes_x4_if ingress_sidecar_vif;
virtual svt_pcie_serdes_x4_if egress_sidecar_vif;
svt_pcie_device_configuration ingress_sidecar_cfg;
svt_pcie_device_configuration egress_sidecar_cfg;
svt_pcie_device_status ingress_sidecar_status;
svt_pcie_device_status egress_sidecar_status;
svt_pcie_device_agent ingress_sidecar;
svt_pcie_device_agent egress_sidecar;
```

At the beginning of `build_phase`, before creating Agents, set:

```systemverilog
sidecars_enabled = !$test$plusargs("TL_PROXY_DISABLE_SIDECARS");
link_only = $test$plusargs("TL_PROXY_LINK_ONLY");
if (!sidecars_enabled && !link_only)
  blocked_fatal(
    "sidecars may be disabled only for the four-active performance baseline",
    "full traffic requires both passive sidecars");
```

Only fetch the standalone handles when `sidecars_enabled` is true:

```systemverilog
if (sidecars_enabled &&
    (!uvm_config_db#(virtual svt_pcie_serdes_x4_if)::get(
       null, "uvm_test_top", "ingress_sidecar_vif", ingress_sidecar_vif) ||
     !uvm_config_db#(virtual svt_pcie_serdes_x4_if)::get(
       null, "uvm_test_top", "egress_sidecar_vif", egress_sidecar_vif)))
  blocked_fatal("one or more standalone passive SERDES VIFs are missing",
    "passive sidecar VIF handle missing");
```

- [ ] **Step 4: Add the standalone passive-Agent factory helper**

Add this complete helper next to the existing active `create_agent` helper:

```systemverilog
function void create_passive_agent(
    string agent_name,
    virtual svt_pcie_serdes_x4_if serdes_vif,
    bit device_is_root,
    output svt_pcie_device_configuration cfg,
    output svt_pcie_device_status status,
    output svt_pcie_device_agent agent);
  cfg = svt_pcie_device_configuration::type_id::create(
    {agent_name, "_cfg"}, this);
  status = svt_pcie_device_status::type_id::create(
    {agent_name, "_status"}, this);
  if ((cfg == null) || (status == null) || (serdes_vif == null))
    blocked_fatal({agent_name,
      ": passive configuration/status/SERDES VIF creation failed"},
      {agent_name, ": passive handle creation failed"});

  // The R-2020.12 manual explicitly excludes passive monitors from
  // set_initial_values_via_unified_vif().
  cfg.is_active = 1'b0;
  cfg.device_is_root = device_is_root;
  configure_common(cfg);
  cfg.pcie_cfg.enable_monitor = 1'b1;
  cfg.pcie_cfg.tl_cfg.cfg_space_mode =
    svt_pcie_tl_configuration::CFG_SPACE_DISABLED;
  cfg.pcie_cfg.serdes_x4_if = serdes_vif;

  uvm_config_db#(svt_pcie_device_configuration)::set(
    this, agent_name, "cfg", cfg);
  uvm_config_db#(svt_pcie_device_status)::set(
    this, agent_name, "shared_status", status);
  agent = svt_pcie_device_agent::type_id::create(agent_name, this);
  if (agent == null)
    blocked_fatal({agent_name, ": passive Device Agent creation failed"},
      {agent_name, ": passive Agent handle missing"});
endfunction
```

After the four active Agents are created, create the sidecars with the Proxy roles they monitor:

```systemverilog
if (sidecars_enabled) begin
  create_passive_agent("ingress_sidecar", ingress_sidecar_vif, 1'b0,
    ingress_sidecar_cfg, ingress_sidecar_status, ingress_sidecar);
  create_passive_agent("egress_sidecar", egress_sidecar_vif, 1'b1,
    egress_sidecar_cfg, egress_sidecar_status, egress_sidecar);
end
```

- [ ] **Step 5: Add Stage A exact handle and configuration checks**

Delete all requirements that any active Agent have a non-null `tl_mon`, delete
the four active-`tl_mon` analysis-port connections, and delete the old active
monitor subscriber objects. Retain checks for every active `pcie_agent`, both
Proxy `tl`, both Proxy `tlp_seqr`, all four active DL/PL sequencers, the Source
Driver App, and the three Target Apps used by the probe.

Add this temporary binding subscriber so Stage A proves all four passive
analysis ports are connectable before forwarding logic exists:

```systemverilog
class tl_proxy_sidecar_bind_subscriber extends
    uvm_subscriber #(svt_pcie_tlp);
  tl_proxy_probe_control control;
  int unsigned observed_count;

  `uvm_component_utils(tl_proxy_sidecar_bind_subscriber)

  function new(string name = "tl_proxy_sidecar_bind_subscriber",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void write(svt_pcie_tlp observed);
    if (control == null)
      `uvm_fatal("TL_PROXY_PASSIVE_SIDECAR_PROBE",
        "Stage A binding subscriber control is null")
    if (observed == null)
      control.fail("Stage A binding subscriber observed a null TLP",
        "passive analysis-port observation is null");
    observed_count++;
  endfunction
endclass
```

Add four fields to the test:

```systemverilog
tl_proxy_sidecar_bind_subscriber ingress_rx_bind_subscriber;
tl_proxy_sidecar_bind_subscriber ingress_tx_bind_subscriber;
tl_proxy_sidecar_bind_subscriber egress_rx_bind_subscriber;
tl_proxy_sidecar_bind_subscriber egress_tx_bind_subscriber;
```

When sidecars are enabled, create and configure all four:

```systemverilog
ingress_rx_bind_subscriber =
  tl_proxy_sidecar_bind_subscriber::type_id::create(
    "ingress_rx_bind_subscriber", this);
ingress_tx_bind_subscriber =
  tl_proxy_sidecar_bind_subscriber::type_id::create(
    "ingress_tx_bind_subscriber", this);
egress_rx_bind_subscriber =
  tl_proxy_sidecar_bind_subscriber::type_id::create(
    "egress_rx_bind_subscriber", this);
egress_tx_bind_subscriber =
  tl_proxy_sidecar_bind_subscriber::type_id::create(
    "egress_tx_bind_subscriber", this);
if ((ingress_rx_bind_subscriber == null) ||
    (ingress_tx_bind_subscriber == null) ||
    (egress_rx_bind_subscriber == null) ||
    (egress_tx_bind_subscriber == null))
  control.fail("one or more Stage A binding subscribers are missing",
    "passive analysis-port binding subscriber creation failed");
ingress_rx_bind_subscriber.control = control;
ingress_tx_bind_subscriber.control = control;
egress_rx_bind_subscriber.control = control;
egress_tx_bind_subscriber.control = control;
```

Connect both RX/TX ports on both passive monitors:

```systemverilog
ingress_sidecar.pcie_agent.tl_mon.rx_tlp_observed_port.connect(
  ingress_rx_bind_subscriber.analysis_export);
ingress_sidecar.pcie_agent.tl_mon.tx_tlp_observed_port.connect(
  ingress_tx_bind_subscriber.analysis_export);
egress_sidecar.pcie_agent.tl_mon.rx_tlp_observed_port.connect(
  egress_rx_bind_subscriber.analysis_export);
egress_sidecar.pcie_agent.tl_mon.tx_tlp_observed_port.connect(
  egress_tx_bind_subscriber.analysis_export);
```

Task 3 replaces these four binding subscribers with the direction-specific
final subscribers; never connect both sets at once.

In `connect_phase`, when sidecars are enabled, require:

```systemverilog
if ((ingress_sidecar == null) ||
    (ingress_sidecar.pcie_agent == null) ||
    (ingress_sidecar.pcie_agent.tl_mon == null) ||
    (egress_sidecar == null) ||
    (egress_sidecar.pcie_agent == null) ||
    (egress_sidecar.pcie_agent.tl_mon == null))
  blocked_fatal("a standalone passive TL monitor is unavailable",
    "passive sidecar tl_mon handle missing");

if (ingress_sidecar_cfg.is_active || egress_sidecar_cfg.is_active ||
    !ingress_sidecar_cfg.pcie_cfg.enable_monitor ||
    !egress_sidecar_cfg.pcie_cfg.enable_monitor ||
    (ingress_sidecar_cfg.pcie_cfg.tl_cfg.cfg_space_mode !=
       svt_pcie_tl_configuration::CFG_SPACE_DISABLED) ||
    (egress_sidecar_cfg.pcie_cfg.tl_cfg.cfg_space_mode !=
       svt_pcie_tl_configuration::CFG_SPACE_DISABLED) ||
    (ingress_sidecar_cfg.pcie_cfg.serdes_x4_if == null) ||
    (egress_sidecar_cfg.pcie_cfg.serdes_x4_if == null) ||
    (ingress_sidecar_cfg.pcie_cfg.serdes_x4_if ==
       egress_sidecar_cfg.pcie_cfg.serdes_x4_if))
  blocked_fatal("standalone passive configuration contract failed",
    "passive sidecar configuration invalid");
```

`wait_for_links()` must require all four active endpoint status objects to
report `pl_status.ltssm_state == svt_pcie_types::L0` at the same time as
`link_up`, `current_speed == SPEED_16_0G`, and
`negotiated_link_width == 4`. The public R-2020.12 PL-status example waits on
this LTSSM field directly; `current_speed` alone is not proof that the endpoint
has entered L0.

After `wait_for_links()` succeeds, emit exactly one Stage A marker:

```systemverilog
if (sidecars_enabled)
  `uvm_info("TL_PROXY_PASSIVE_SIDECAR_STAGE_A_PASS",
    "four active Agents plus two independent passive Agents; two Gen4 x4 links at L0",
    UVM_NONE)
```

For link-only runs, hold a fixed 10 us post-L0 window and stop without traffic:

```systemverilog
if (link_only) begin
  #10us;
  if (sidecars_enabled)
    `uvm_info("TL_PROXY_PASSIVE_SIDECAR_LINK_ONLY_PASS",
      "two passive sidecars remained link-neutral for 10 us after L0",
      UVM_NONE)
  else
    `uvm_info("TL_PROXY_FOUR_ACTIVE_BASELINE_PASS",
      "four-active baseline remained stable for 10 us after L0",
      UVM_NONE)
  phase.drop_objection(this);
  return;
end
```

- [ ] **Step 6: Stage and run a fresh Stage A build**

Run from the local worktree:

```bash
rsync -a --relative \
  svt_pcie_integration/rtl/pcie_svt_passive_sidecar_tap.sv \
  svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv \
  svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.f \
  svt_pcie_integration/sim/check_tl_proxy_passive_sidecar_log.sh \
  ubuntu@10.11.10.53:/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/

ssh ubuntu@10.11.10.53 'bash -lic "
  set -euo pipefail
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12
  build_dir=\$(mktemp -d build_tl_proxy_passive_stage_a.XXXXXX)
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    -f pcie_svt_tl_proxy_probe.f -top pcie_svt_tl_proxy_probe_top \
    -Mdir=\$build_dir/csrc -P pli.tab msglog.o \
    -o \$build_dir/simv -l \$build_dir/compile.log
  ./\$build_dir/simv -no_save +UVM_NO_RELNOTES +TL_PROXY_LINK_ONLY \
    +ntb_random_seed=1 -l \$build_dir/run.log
  ./check_tl_proxy_passive_sidecar_log.sh sidecar-link \$build_dir/run.log
  echo \$build_dir
"'
```

Expected: VCS creates `simv`; every active endpoint explicitly reports L0 at
Gen4 x4 before Stage A; both passive `tl_mon` handles are non-null; the
link-only marker occurs at least 10 us after the last active endpoint enters
Gen4 L0; Stage A and link-only markers each appear once; W/E/F is `0/0/0`.

If this step fails to bind or decode either standalone SERDES interface, stop Task 1. Do not implement a Driver App fallback.

### Task 3: Add Independent Sidecar Observation and Memory-Write Proof

**Files:**
- Modify: `svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv:package classes, build_phase, connect_phase, run_phase`
- Test: remote `+TL_PROXY_STOP_AFTER_MWR` run

- [ ] **Step 1: Retain the shared Stage A failure gate**

Keep the single `tl_proxy_probe_control` created in Task 2. Confirm every new
checker, subscriber, bridge, Target callback, sink callback, and Source Driver
callback receives the same non-null `control` handle. Delete the four temporary
`tl_proxy_sidecar_bind_subscriber` instances only when the four final
subscribers in Step 3 are created and connected.

- [ ] **Step 2: Add the wire-DWORD checker**

Add this checker. It retains only clones and compares the encoded TLP DWORDs, not UVM metadata:

```systemverilog
class tl_proxy_wire_checker extends uvm_component;
  typedef enum int unsigned {
    INGRESS_RX_REQUEST,
    EGRESS_TX_REQUEST,
    EGRESS_RX_COMPLETION,
    INGRESS_TX_COMPLETION
  } observation_role_e;

  tl_proxy_probe_control control;
  svt_pcie_tlp ingress_requests[$];
  svt_pcie_tlp egress_requests[$];
  svt_pcie_tlp sink_requests[$];
  svt_pcie_tlp egress_completions[$];
  svt_pcie_tlp ingress_completions[$];

  `uvm_component_utils(tl_proxy_wire_checker)

  function new(string name = "tl_proxy_wire_checker",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function svt_pcie_tlp clone_or_fail(svt_pcie_tlp observed,
                                      string boundary);
    svt_pcie_tlp captured;
    if ((observed == null) || !$cast(captured, observed.clone()))
      control.fail({boundary, ": TLP clone failed"},
        {boundary, ": observation clone failed"});
    return captured;
  endfunction

  function bit is_request(svt_pcie_tlp tlp);
    return (((tlp.tlp_type == svt_pcie_tlp::MEM_REQ) && tlp.has_data()) ||
            ((tlp.tlp_type == svt_pcie_tlp::TYPE_0_CFG_REQ) &&
             !tlp.has_data()));
  endfunction

  function void observe(observation_role_e role, svt_pcie_tlp observed);
    svt_pcie_tlp captured;
    captured = clone_or_fail(observed, "passive sidecar");
    case (role)
      INGRESS_RX_REQUEST: begin
        if (!is_request(captured))
          return;
        ingress_requests.push_back(captured);
      end
      EGRESS_TX_REQUEST: begin
        if (!is_request(captured))
          return;
        egress_requests.push_back(captured);
      end
      EGRESS_RX_COMPLETION: begin
        if (captured.tlp_type != svt_pcie_tlp::CPL)
          return;
        egress_completions.push_back(captured);
      end
      INGRESS_TX_COMPLETION: begin
        if (captured.tlp_type != svt_pcie_tlp::CPL)
          return;
        ingress_completions.push_back(captured);
      end
      default:
        control.fail("invalid passive observation role",
          "sidecar subscriber role invalid");
    endcase
  endfunction

  function void observe_sink(svt_pcie_tlp observed);
    svt_pcie_tlp captured;
    captured = clone_or_fail(observed, "sink Target");
    if (!is_request(captured))
      control.fail("sink Target received an unsupported request",
        "unsupported sink request");
    sink_requests.push_back(captured);
  endfunction

  function bit wire_equal(svt_pcie_tlp lhs, svt_pcie_tlp rhs);
    svt_pcie_types::dword_array_t lhs_dwords;
    svt_pcie_types::dword_array_t rhs_dwords;
    lhs_dwords = lhs.get_dword_array();
    rhs_dwords = rhs.get_dword_array();
    if (lhs_dwords.size() != rhs_dwords.size())
      return 1'b0;
    foreach (lhs_dwords[index])
      if (lhs_dwords[index] !== rhs_dwords[index])
        return 1'b0;
    return 1'b1;
  endfunction

  function void require_wire_equal(svt_pcie_tlp lhs,
                                   svt_pcie_tlp rhs,
                                   string path_name);
    if (!wire_equal(lhs, rhs))
      control.fail({path_name, ": encoded TLP DWORD mismatch"},
        {path_name, ": transparent forwarding failed"});
  endfunction
endclass
```

Add the checker field and create it before the final subscribers:

```systemverilog
tl_proxy_wire_checker checker;

checker = tl_proxy_wire_checker::type_id::create("checker", this);
if (checker == null)
  control.fail("wire checker creation failed",
    "wire checker handle missing");
checker.control = control;
```

- [ ] **Step 3: Add four direction-specific sidecar subscribers**

Add:

```systemverilog
class tl_proxy_sidecar_subscriber extends uvm_subscriber #(svt_pcie_tlp);
  tl_proxy_probe_control control;
  tl_proxy_wire_checker checker;
  tl_proxy_bridge bridge;
  tl_proxy_wire_checker::observation_role_e role;

  `uvm_component_utils(tl_proxy_sidecar_subscriber)

  function new(string name = "tl_proxy_sidecar_subscriber",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void write(svt_pcie_tlp t);
    if (control == null)
      `uvm_fatal("TL_PROXY_PASSIVE_SIDECAR_PROBE",
        "sidecar subscriber control is null")
    if ((checker == null) || (t == null))
      control.fail("sidecar subscriber received a null handle",
        "sidecar subscriber handle missing");
    checker.observe(role, t);
    if ((role == tl_proxy_wire_checker::EGRESS_RX_COMPLETION) &&
        (t.tlp_type == svt_pcie_tlp::CPL)) begin
      if (bridge == null)
        checker.control.fail("Egress RX Completion bridge is null",
          "reverse bridge handle missing");
      bridge.capture_completion(t);
    end
  endfunction
endclass
```

Replace the four binding-subscriber fields with these four final fields:

```systemverilog
tl_proxy_sidecar_subscriber ingress_rx_subscriber;
tl_proxy_sidecar_subscriber ingress_tx_subscriber;
tl_proxy_sidecar_subscriber egress_rx_subscriber;
tl_proxy_sidecar_subscriber egress_tx_subscriber;
```

Create exactly four instances and configure their roles:

```systemverilog
ingress_rx_subscriber = tl_proxy_sidecar_subscriber::type_id::create(
  "ingress_rx_subscriber", this);
ingress_tx_subscriber = tl_proxy_sidecar_subscriber::type_id::create(
  "ingress_tx_subscriber", this);
egress_rx_subscriber = tl_proxy_sidecar_subscriber::type_id::create(
  "egress_rx_subscriber", this);
egress_tx_subscriber = tl_proxy_sidecar_subscriber::type_id::create(
  "egress_tx_subscriber", this);
if ((ingress_rx_subscriber == null) || (ingress_tx_subscriber == null) ||
    (egress_rx_subscriber == null) || (egress_tx_subscriber == null))
  control.fail("one or more final sidecar subscribers are missing",
    "sidecar subscriber creation failed");
ingress_rx_subscriber.control = control;
ingress_tx_subscriber.control = control;
egress_rx_subscriber.control = control;
egress_tx_subscriber.control = control;
ingress_rx_subscriber.checker = checker;
ingress_tx_subscriber.checker = checker;
egress_rx_subscriber.checker = checker;
egress_tx_subscriber.checker = checker;
ingress_rx_subscriber.role = tl_proxy_wire_checker::INGRESS_RX_REQUEST;
ingress_tx_subscriber.role = tl_proxy_wire_checker::INGRESS_TX_COMPLETION;
egress_rx_subscriber.role = tl_proxy_wire_checker::EGRESS_RX_COMPLETION;
egress_tx_subscriber.role = tl_proxy_wire_checker::EGRESS_TX_REQUEST;
egress_rx_subscriber.bridge = bridge;
```

Connect them only to the two passive Agents:

```systemverilog
ingress_sidecar.pcie_agent.tl_mon.rx_tlp_observed_port.connect(
  ingress_rx_subscriber.analysis_export);
ingress_sidecar.pcie_agent.tl_mon.tx_tlp_observed_port.connect(
  ingress_tx_subscriber.analysis_export);
egress_sidecar.pcie_agent.tl_mon.rx_tlp_observed_port.connect(
  egress_rx_subscriber.analysis_export);
egress_sidecar.pcie_agent.tl_mon.tx_tlp_observed_port.connect(
  egress_tx_subscriber.analysis_export);
```

Do not connect to any active Agent's `tl_mon`; active `tl_mon` remains null by design.

- [ ] **Step 4: Restrict request capture to the Ingress Target callback**

Refactor the existing `tl_proxy_target_callback` to expose
`capture_requests`. Use these fields and constructor before its methods:

```systemverilog
tl_proxy_probe_control control;
tl_proxy_bridge bridge;
bit capture_requests;
int unsigned request_capture_count;
int unsigned target_tx_count;
```

Its complete RX/TX behavior must be:

```systemverilog
virtual function void post_rx_tlp_get(
    svt_pcie_target_app target_app,
    svt_pcie_tlp transaction,
    ref bit drop);
  if (control == null)
    `uvm_fatal("TL_PROXY_PASSIVE_SIDECAR_PROBE",
      "Proxy Target callback control is null")
  if ((target_app == null) || (transaction == null))
    control.fail("Proxy Target callback received a null handle",
      "Proxy Target RX handle missing");
  if (!capture_requests)
    control.fail("Egress Proxy Target received an unexpected request",
      "unexpected request at Egress Proxy Target");
  if (!(((transaction.tlp_type == svt_pcie_tlp::MEM_REQ) &&
         transaction.has_data()) ||
        ((transaction.tlp_type == svt_pcie_tlp::TYPE_0_CFG_REQ) &&
         !transaction.has_data())))
    control.fail("Ingress Proxy Target received an unsupported request",
      "unsupported Proxy request");
  bridge.capture_request(transaction);
  request_capture_count++;
  drop = 1'b1;
endfunction

virtual function void pre_tx_tlp_put(
    svt_pcie_target_app target_app,
    svt_pcie_tlp transaction,
    ref bit drop);
  if (control == null)
    `uvm_fatal("TL_PROXY_PASSIVE_SIDECAR_PROBE",
      "Proxy Target TX callback control is null")
  if ((target_app == null) || (transaction == null))
    control.fail("Proxy Target TX callback received a null handle",
      "Proxy Target TX handle missing");
  target_tx_count++;
  drop = 1'b1;
endfunction
```

Set `ingress_target_callback.capture_requests=1` and `egress_target_callback.capture_requests=0`. Both callbacks retain the TX safety wall, and the final gate requires both `target_tx_count` values to be zero.

- [ ] **Step 5: Make bridge capture clone internally and enqueue nonblocking**

Replace the ambiguous side flag with explicit methods:

```systemverilog
function void capture_request(svt_pcie_tlp observed);
  svt_pcie_tlp captured;
  bit accepted;
  if ((observed == null) || !$cast(captured, observed.clone()))
    control.fail("Ingress request clone failed",
      "request bridge clone failed");
  accepted = request_mailbox.try_put(captured);
  if (!accepted)
    control.fail("unbounded request mailbox rejected try_put",
      "request mailbox enqueue failed");
  request_capture_count++;
endfunction

function void capture_completion(svt_pcie_tlp observed);
  svt_pcie_tlp captured;
  bit accepted;
  if ((observed == null) || !$cast(captured, observed.clone()))
    control.fail("Egress RX Completion clone failed",
      "Completion bridge clone failed");
  accepted = completion_mailbox.try_put(captured);
  if (!accepted)
    control.fail("unbounded Completion mailbox rejected try_put",
      "Completion mailbox enqueue failed");
  completion_capture_count++;
endfunction
```

The request worker blocks on `request_mailbox.get()` and starts a fresh raw sequence on `egress_proxy.pcie_agent.tlp_seqr`. The Completion worker blocks on `completion_mailbox.get()` and starts a fresh raw sequence on `ingress_proxy.pcie_agent.tlp_seqr`. Increment `request_forward_count` or `completion_forward_count` only after `raw_sequence.start()` returns.

Implement both workers with this complete task and `run_phase`:

```systemverilog
task forward_one(bit forward_request);
  svt_pcie_tlp captured;
  svt_pcie_tlp injected;
  tl_proxy_raw_tlp_sequence raw_sequence;
  svt_pcie_tlp_sequencer sequencer;

  if (forward_request)
    request_mailbox.get(captured);
  else
    completion_mailbox.get(captured);

  if ((captured == null) || !$cast(injected, captured.clone()))
    control.fail("mailbox TLP clone failed",
      "raw reinjection clone failed");

  if (forward_request) begin
    if ((egress_proxy == null) || (egress_proxy.pcie_agent == null))
      control.fail("Egress Proxy Agent is unavailable",
        "request reinjection Agent missing");
    sequencer = egress_proxy.pcie_agent.tlp_seqr;
  end else begin
    if ((ingress_proxy == null) || (ingress_proxy.pcie_agent == null))
      control.fail("Ingress Proxy Agent is unavailable",
        "Completion reinjection Agent missing");
    sequencer = ingress_proxy.pcie_agent.tlp_seqr;
  end

  if (sequencer == null)
    control.fail("raw reinjection sequencer is unavailable",
      "raw tlp_seqr handle missing");
  raw_sequence = tl_proxy_raw_tlp_sequence::type_id::create(
    forward_request ? "request_raw_sequence" : "completion_raw_sequence");
  if (raw_sequence == null)
    control.fail("raw reinjection sequence creation failed",
      "raw sequence handle missing");
  raw_sequence.request = injected;
  raw_sequence.start(sequencer);

  if (forward_request)
    request_forward_count++;
  else
    completion_forward_count++;
endtask

virtual task run_phase(uvm_phase phase);
  fork
    forever forward_one(1'b1);
    forever forward_one(1'b0);
  join
endtask
```

- [ ] **Step 6: Observe the sink without suppressing its response**

Add a dedicated sink callback:

```systemverilog
class tl_proxy_sink_target_callback extends svt_pcie_target_app_callback;
  tl_proxy_probe_control control;
  tl_proxy_wire_checker checker;
  int unsigned write_count;
  int unsigned cfg_read_count;

  `uvm_object_utils(tl_proxy_sink_target_callback)

  function new(string name = "tl_proxy_sink_target_callback");
    super.new(name);
  endfunction

  virtual function void post_rx_tlp_get(
      svt_pcie_target_app target_app,
      svt_pcie_tlp transaction,
      ref bit drop);
    if (control == null)
      `uvm_fatal("TL_PROXY_PASSIVE_SIDECAR_PROBE",
        "sink Target callback control is null")
    if ((target_app == null) || (transaction == null) ||
        (checker == null))
      control.fail("sink Target callback received a null handle",
        "sink Target callback handle missing");
    checker.observe_sink(transaction);
    if ((transaction.tlp_type == svt_pcie_tlp::MEM_REQ) &&
        transaction.has_data())
      write_count++;
    else if ((transaction.tlp_type == svt_pcie_tlp::TYPE_0_CFG_REQ) &&
             !transaction.has_data())
      cfg_read_count++;
    else
      control.fail("sink Target received an unsupported TLP",
        "unsupported sink Target TLP");
    drop = 1'b0;
  endfunction
endclass
```

Register it on `sink_ep.target[0]`. It must never implement `pre_tx_tlp_put`; the sink's real Target App must generate the Configuration Completion normally.

- [ ] **Step 7: Add the exact Memory Write gate**

Keep the directed Memory Write fields exactly as approved, then wait at most 100 us for all Stage B counts. Add `+TL_PROXY_STOP_AFTER_MWR` support after the gate.

Next to the Source Driver's existing explicit-Tag configuration, enable
Requester-ID user control so the sequence value reaches the wire:

```systemverilog
source_rc_cfg.driver_cfg[0]
  .enable_tlp_field_user_control_vector[3] = 1'b1;
```

After the Memory Write sequence factory create and null check, bind its public
configuration handle before calling `randomize()`:

```systemverilog
write_seq.cfg = source_rc_cfg;
```

Do not constrain the high-level posted Memory Write's transaction `tag`.
R-2020.12's documented `reasonable_tag` constraint keeps that sequence field
in the enabled 10-bit range, while the Driver App applies the transaction Tag
only to non-posted requests. The posted Memory Write wire Tag therefore
remains `10'h000`, and Task 1's Configuration Read retains the full 10-bit Tag
preservation proof. Constrain `requester_id == 16'h0000`.

Use this bounded wait before evaluating the exact gate:

```systemverilog
begin
  bit mwr_ready;
  mwr_ready = 1'b0;
  fork
    begin
      wait ((checker.ingress_requests.size() >= 1) &&
            (checker.egress_requests.size() >= 1) &&
            (checker.sink_requests.size() >= 1) &&
            (ingress_target_callback.request_capture_count >= 1) &&
            (bridge.request_capture_count >= 1) &&
            (bridge.request_forward_count >= 1) &&
            (sink_target_callback.write_count >= 1));
      mwr_ready = 1'b1;
    end
    #100us;
  join_any
  disable fork;
  if (!mwr_ready)
    fail_with_full_counter_snapshot(
      "Memory Write path did not complete within 100 us",
      "Memory Write stage exceeded 100 us");
end

// Keep every callback and bridge worker active during a fixed quiet window.
// The exact-count, wire, and field gates below recheck the accumulated state.
#1us;
```

The exact Stage B check is:

```systemverilog
if ((checker.ingress_requests.size() != 1) ||
    (checker.egress_requests.size() != 1) ||
    (checker.sink_requests.size() != 1) ||
    (checker.egress_completions.size() != 0) ||
    (checker.ingress_completions.size() != 0) ||
    (ingress_target_callback.request_capture_count != 1) ||
    (egress_target_callback.request_capture_count != 0) ||
    (bridge.request_capture_count != 1) ||
    (bridge.request_forward_count != 1) ||
    (bridge.completion_capture_count != 0) ||
    (bridge.completion_forward_count != 0) ||
    (sink_target_callback.write_count != 1) ||
    (sink_target_callback.cfg_read_count != 0) ||
    (ingress_target_callback.target_tx_count != 0) ||
    (egress_target_callback.target_tx_count != 0))
  control.fail("Memory Write exact-count gate failed",
    "Memory Write was not forwarded exactly once");

checker.require_wire_equal(checker.ingress_requests[0],
  checker.egress_requests[0], "Ingress RX -> Egress TX Memory Write");
checker.require_wire_equal(checker.egress_requests[0],
  checker.sink_requests[0], "Egress TX -> sink Target Memory Write");

if ((checker.ingress_requests[0].address !=
       64'h0000_0000_8000_1040) ||
    (checker.ingress_requests[0].first_dw_be != 4'hf) ||
    (checker.ingress_requests[0].last_dw_be != 4'h0) ||
    (checker.ingress_requests[0].at != svt_pcie_tlp::UNTRANSLATED) ||
    (checker.ingress_requests[0].tag != 10'h000) ||
    (checker.ingress_requests[0].requester_id != 16'h0000) ||
    (checker.ingress_requests[0].traffic_class != 3'b000) ||
    (checker.ingress_requests[0].length != 10'd1) ||
    (checker.ingress_requests[0].payload.size() != 1) ||
    (checker.ingress_requests[0].payload[0] != 32'h4433_2211) ||
    checker.ingress_requests[0].ep)
  control.fail("directed Memory Write fields do not match the contract",
    "Memory Write stimulus or forwarding changed");

`uvm_info("TL_PROXY_PASSIVE_SIDECAR_MWR_STAGE_PASS",
  "one transparent Memory Write; no Completion; no Proxy Target response",
  UVM_NONE)

if ($test$plusargs("TL_PROXY_STOP_AFTER_MWR")) begin
  phase.drop_objection(this);
  return;
end
```

- [ ] **Step 8: Compile and run the Memory Write stage**

Stage the three changed files and run a new build directory with:

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  set -euo pipefail
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12
  build_dir=\$(mktemp -d build_tl_proxy_passive_mwr.XXXXXX)
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    -f pcie_svt_tl_proxy_probe.f -top pcie_svt_tl_proxy_probe_top \
    -Mdir=\$build_dir/csrc -P pli.tab msglog.o \
    -o \$build_dir/simv -l \$build_dir/compile.log
  ./\$build_dir/simv -no_save +UVM_NO_RELNOTES \
    +TL_PROXY_STOP_AFTER_MWR +ntb_random_seed=1 \
    -l \$build_dir/run.log
  count_marker() {
    grep -a -E -c -- \
      \"^UVM_(INFO|WARNING|ERROR|FATAL)([[:space:]]+[^[:space:]]+)?[[:space:]]+@[[:space:]]+[^:]+:[[:space:]]+[^[:space:]]+[[:space:]]+\\[\$1\\]([[:space:]]|\$)\" \
      \$build_dir/run.log || true
  }
  test \"\$(count_marker TL_PROXY_PASSIVE_SIDECAR_STAGE_A_PASS)\" -eq 1
  test \"\$(count_marker TL_PROXY_PASSIVE_SIDECAR_MWR_STAGE_PASS)\" -eq 1
  test \"\$(count_marker TL_PROXY_PASSIVE_SIDECAR_PROBE_BLOCKED)\" -eq 0
  grep -a -q \"^UVM_WARNING :    0\$\" \$build_dir/run.log
  grep -a -q \"^UVM_ERROR :    0\$\" \$build_dir/run.log
  grep -a -q \"^UVM_FATAL :    0\$\" \$build_dir/run.log
  echo \$build_dir
"'
```

Expected: Stage A and MWr markers each appear once, Ingress passive RX equals Egress passive TX equals sink Target, there are no Completion observations or Proxy Target transmissions, and W/E/F is `0/0/0`.

### Task 4: Forward Configuration Read and Raw Completion Transparently

**Files:**
- Modify: `svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv:callbacks, final stage, terminal gate`
- Test: fresh full-traffic VCS run

- [ ] **Step 1: Build and verify the minimal passive capability images**

Change both standalone sidecars from `CFG_SPACE_DISABLED` to the documented
`CFG_SPACE_BACKDOOR_UPDATE` mode. Create one probe-owned
`uvm_analysis_port #(svt_pcie_tl_service)` per sidecar in `build_phase` and
connect each port to the corresponding passive
`pcie_agent.tl_mon.tl_service_in_port` in `connect_phase`.

Before enabling either physical link, initialize only the configuration-space
structure needed by the passive 10-bit Tag checks. For each sidecar, send and
wait for these `MON_CONFIG_SPACE_WRITE_ADDR` services in order:

```systemverilog
write_sidecar_cfg_address(service_port,
  `SVT_PCIE_CONFIG_SPACE_FUNC_0_CAP_STAT_ADDR, 32'h0010_0000,
  {sidecar_name, " Status/Command"});
write_sidecar_cfg_address(service_port,
  `SVT_PCIE_CONFIG_SPACE_FUNC_0_CAP_PTR_ADDR, 32'h0000_0040,
  {sidecar_name, " Capability Pointer"});
write_sidecar_cfg_address(service_port,
  `SVT_PCIE_CONFIG_SPACE_FUNC_0_BASE_ADDR + 28'h000_0040,
  32'h0002_0010, {sidecar_name, " PCI Express Capability"});
```

These three DWORDs enable the conventional capability list, point it to byte
address 40h, and define PCIe Capability ID 10h with a null next pointer and
version 2. Every service uses mask `32'hffff_ffff`, waits on the public
`svt_pcie_tl_service::end_event`, and fails after a bounded 100 us wait. Do
not load BARs, AER, ATS, or any other capability; this is a minimal checker
image, not a complete copy of either active Proxy configuration space.

Then set exactly these function-0 fields with
`MON_CONFIG_SPACE_SET_FIELD`:

| Sidecar / monitored device | Field | Value |
| --- | --- | --- |
| Egress / Egress Proxy requester | `SVT_PCIE_PCIE_DEV_CTST_REG_EXTND_TAG_FIELD_EN_FLD` | 1 |
| Egress / Egress Proxy requester | `SVT_PCIE_PCIE_DEV_2_REG_10_BIT_TAG_REQUESTER_SUPP_FLD` | 1 |
| Egress / Egress Proxy requester | `SVT_PCIE_PCIE_DEV_CTST_2_REG_10_BIT_TAG_REQUESTER_EN_FLD` | 1 |
| Ingress / Ingress Proxy completer | `SVT_PCIE_PCIE_DEV_2_REG_10_BIT_TAG_COMPLETER_SUPP_FLD` | 1 |

Issue `MON_CONFIG_SPACE_GET_FIELD` for all four fields, wait on each service's
`end_event`, and require every returned value to equal one before any link or
traffic sequence starts. Emit `TL_PROXY_PASSIVE_CFG_TRACE` with the four
readbacks. Sending a service without successful readback is not acceptance.

- [ ] **Step 2: Add the Source Driver transaction-end callback**

Add:

```systemverilog
class tl_proxy_source_driver_callback extends svt_pcie_driver_app_callback;
  tl_proxy_probe_control control;
  bit cfg_read_armed;
  int unsigned total_end_count;
  int unsigned cfg_read_end_count;
  int unsigned cfg_read_success_count;

  `uvm_object_utils(tl_proxy_source_driver_callback)

  function new(string name = "tl_proxy_source_driver_callback");
    super.new(name);
  endfunction

  virtual function void transaction_ended(
      svt_pcie_driver_app driver,
      svt_pcie_driver_app_transaction transaction);
    if (control == null) begin
      tl_proxy_fatal_without_control(
        "Source Driver callback control is null",
        "Source Driver callback control is null");
      return;
    end
    if ((driver == null) || (transaction == null))
      control.fail("Source Driver transaction_ended received a null handle",
        "Source Driver callback handle missing");
    total_end_count++;
    if (cfg_read_armed) begin
      cfg_read_end_count++;
      if ((transaction.transaction_type ==
             svt_pcie_driver_app_transaction::CFG_RD) &&
          (transaction.completion_status ==
             svt_pcie_driver_app_transaction::SUCCESSFUL)) begin
        cfg_read_success_count++;
        `uvm_info("TL_PROXY_SOURCE_DRIVER_END_TRACE", $sformatf(
          {"transaction_type=CFG_RD completion_status=SUCCESSFUL ",
           "cfg_read_success_count=%0d"}, cfg_read_success_count), UVM_NONE)
      end else
        control.fail("armed Source transaction was not a successful CfgRd",
          "Source Configuration Read did not complete successfully");
    end
  endfunction
endclass
```

The public R-2020.12 HTML declares both transaction members and the
`CFG_RD`/`SUCCESSFUL` enum values. Check them only after `cfg_read_armed` is
set, so the posted Memory Write's documented default `AWAITED` status is not
treated as failure. Only the successful branch increments
`cfg_read_success_count` and emits the anchored source trace.

At package scope, keep one `tl_proxy_fatal_without_control()` helper that first
emits exactly one `TL_PROXY_PASSIVE_SIDECAR_PROBE_BLOCKED` and then calls
`` `uvm_fatal``. It is the only direct fatal site. `control.fail()` delegates
to it, and every `control == null` branch calls it inside an explicit block and
then returns, so no null handle is dereferenced even if report control changes.

Require `source_rc.driver.exists(0)` and `source_rc.driver[0] != null`, then register:

```systemverilog
uvm_callbacks#(svt_pcie_driver_app,
  svt_pcie_driver_app_callback)::add(
    source_rc.driver[0], source_driver_callback);
```

Before arming the Configuration Read, use this bounded wait and exact gate:

```systemverilog
begin
  bit source_mwr_ended;
  source_mwr_ended = 1'b0;
  fork
    begin
      wait (source_driver_callback.total_end_count >= 1);
      source_mwr_ended = 1'b1;
    end
    #100us;
  join_any
  disable fork;
  if (!source_mwr_ended)
    fail_with_full_counter_snapshot(
      "Source Memory Write transaction did not end within 100 us",
      "Source Memory Write Driver transaction-end timeout");
  if ((source_driver_callback.total_end_count != 1) ||
      (source_driver_callback.cfg_read_end_count != 0))
    control.fail("Source Memory Write Driver transaction-end gate failed",
      "Source Driver did not end the Memory Write exactly once");
end
```

Then set `cfg_read_armed=1` immediately before starting the CfgRd sequence. No
other Source Driver transaction may start after this point.

- [ ] **Step 3: Keep the CfgRd Tag runtime-assigned**

Create the high-level CfgRd sequence with only its documented fields:

```systemverilog
cfg_read_sequence =
  svt_pcie_driver_app_transaction_cfg_rd_sequence::type_id::create(
    "cfg_read_sequence");
cfg_read_sequence.cfg = source_rc_cfg;
if (!cfg_read_sequence.randomize() with {
      bdf == 16'h0000;
      register_number == 10'h000;
      requester_id == 16'h0000;
      first_dw_be == 4'hf;
      block == 1'b0;
      pkt_delay_ns == 0;
    })
  control.fail("Type-0 Configuration Read randomization failed",
    "Configuration Read setup failed");
source_driver_callback.cfg_read_armed = 1'b1;
cfg_read_sequence.start(source_rc.driver_transaction_seqr[0]);
```

Do not add a Tag property to this sequence and do not construct a replacement Completion. The complete runtime Tag comes from `checker.ingress_requests[1].tag`.

- [ ] **Step 4: Add the 100 us final-stage wait and timeout dump**

Define one `fail_with_full_counter_snapshot()` helper and call it from the
link-training wait, Stage B Memory Write wait, Source Memory Write end wait,
and Stage C request/Completion wait. It emits exactly one
`TL_PROXY_PASSIVE_SIDECAR_TIMEOUT_TRACE` containing the same complete snapshot
before calling `control.fail`; no one-off partial timeout formatter is allowed.
Every wait remains bounded by `#100us` or less.

Wait until all cumulative counts reach their expected lower bounds. The shared
snapshot contains all of these values:

```text
ingress_rx_requests egress_tx_requests sink_requests
egress_rx_completions ingress_tx_completions
ingress_target_requests egress_target_requests
request_mailbox_captures request_reinjections
completion_mailbox_captures completion_reinjections
sink_writes sink_cfg_reads source_driver_ends source_cfg_ends source_cfg_successes
ingress_target_tx egress_target_tx
```

Implement the wait, timeout dump, and failure as:

```systemverilog
begin
  bit cfg_path_ready;
  cfg_path_ready = 1'b0;
  fork
    begin
      wait ((checker.ingress_requests.size() >= 2) &&
            (checker.egress_requests.size() >= 2) &&
            (checker.sink_requests.size() >= 2) &&
            (checker.egress_completions.size() >= 1) &&
            (checker.ingress_completions.size() >= 1) &&
            (bridge.request_forward_count >= 2) &&
            (bridge.completion_forward_count >= 1) &&
            (source_driver_callback.cfg_read_end_count >= 1) &&
            (source_driver_callback.cfg_read_success_count >= 1));
      cfg_path_ready = 1'b1;
    end
    #100us;
  join_any
  disable fork;
  if (!cfg_path_ready)
    fail_with_full_counter_snapshot(
      "Configuration path did not complete within 100 us",
      "Configuration request/Completion timeout");
end
```

After the lower-bound wait succeeds, keep all callbacks, subscribers, and
bridge workers active for a fixed final quiet window:

```systemverilog
// Keep every callback and bridge worker active before the final gate.
#1us;
```

Do not evaluate the exact-count, field, or terminal-PASS gates until this
quiet window has completed.

- [ ] **Step 5: Add the final exact-count and transparent-DWORD checks**

After the final 1 us quiet window, require:

```systemverilog
if ((checker.ingress_requests.size() != 2) ||
    (checker.egress_requests.size() != 2) ||
    (checker.sink_requests.size() != 2) ||
    (checker.egress_completions.size() != 1) ||
    (checker.ingress_completions.size() != 1) ||
    (ingress_target_callback.request_capture_count != 2) ||
    (egress_target_callback.request_capture_count != 0) ||
    (bridge.request_capture_count != 2) ||
    (bridge.request_forward_count != 2) ||
    (bridge.completion_capture_count != 1) ||
    (bridge.completion_forward_count != 1) ||
    (sink_target_callback.write_count != 1) ||
    (sink_target_callback.cfg_read_count != 1) ||
    (source_driver_callback.total_end_count != 2) ||
    (source_driver_callback.cfg_read_end_count != 1) ||
    (source_driver_callback.cfg_read_success_count != 1) ||
    (ingress_target_callback.target_tx_count != 0) ||
    (egress_target_callback.target_tx_count != 0))
  control.fail("Configuration path exact-count gate failed",
    "Configuration request/Completion was not forwarded exactly once");

checker.require_wire_equal(checker.ingress_requests[1],
  checker.egress_requests[1], "Ingress RX -> Egress TX CfgRd0");
checker.require_wire_equal(checker.egress_requests[1],
  checker.sink_requests[1], "Egress TX -> sink Target CfgRd0");
checker.require_wire_equal(checker.egress_completions[0],
  checker.ingress_completions[0], "Egress RX -> Ingress TX Completion");
```

Then require the approved CfgRd and Completion fields explicitly:

```systemverilog
if ((checker.ingress_requests[1].tlp_type !=
       svt_pcie_tlp::TYPE_0_CFG_REQ) ||
    checker.ingress_requests[1].has_data() ||
    (checker.ingress_requests[1].bus_number != 8'h00) ||
    (checker.ingress_requests[1].device_number != 5'h00) ||
    (checker.ingress_requests[1].function_number != 3'h0) ||
    (checker.ingress_requests[1].register_number != 10'h000) ||
    (checker.ingress_requests[1].requester_id != 16'h0000) ||
    (checker.ingress_requests[1].first_dw_be != 4'hf) ||
    (checker.ingress_requests[1].traffic_class != 3'b000) ||
    (checker.ingress_requests[1].tag[9:8] == 2'b00))
  control.fail("Type-0 Configuration Read fields or 10-bit Tag changed",
    "Configuration Read contract failed");

if ((checker.egress_completions[0].completion_status !=
       svt_pcie_tlp::SUCCESSFUL) ||
    !checker.egress_completions[0].has_data() ||
    (checker.egress_completions[0].payload.size() != 1) ||
    (checker.egress_completions[0].requester_id !=
       checker.ingress_requests[1].requester_id) ||
    (checker.egress_completions[0].tag !=
       checker.ingress_requests[1].tag) ||
    (checker.ingress_completions[0].tag !=
       checker.ingress_requests[1].tag) ||
    (checker.egress_completions[0].completer_id !=
       checker.ingress_completions[0].completer_id) ||
    (checker.egress_completions[0].requester_id !=
       checker.ingress_completions[0].requester_id) ||
    (checker.egress_completions[0].byte_count !=
       checker.ingress_completions[0].byte_count) ||
    (checker.egress_completions[0].lower_address !=
       checker.ingress_completions[0].lower_address) ||
    (checker.egress_completions[0].length !=
       checker.ingress_completions[0].length) ||
    (checker.egress_completions[0].get_attr_value() !=
       checker.ingress_completions[0].get_attr_value()))
  control.fail("Configuration Completion identity or payload changed",
    "Requester ID/full Tag/Completion contract failed");
```

This is the explicit proof that the runtime-assigned full Tag survives request
forwarding and Completion return. Requiring nonzero `tag[9:8]` proves at
runtime that the test exercises the 10-bit Tag space rather than merely
comparing equal legacy-width values. Do not constrain a particular Tag value.

- [ ] **Step 6: Emit only the approved terminal markers**

After all checks pass:

```systemverilog
`uvm_info("TL_PROXY_PASSIVE_SIDECAR_CFG_STAGE_PASS",
  "one transparent CfgRd0 and one raw Completion; Requester ID/full Tag preserved",
  UVM_NONE)
`uvm_info("TL_PROXY_PASSIVE_SIDECAR_PROBE_PASS", $sformatf(
  {"two Gen4 x4 Serial links; active=4 passive=2; requests=%0d; ",
   "completions=%0d; source_cfg_success=%0d; proxy_target_tx=%0d"},
  bridge.request_forward_count, bridge.completion_forward_count,
  source_driver_callback.cfg_read_success_count,
  ingress_target_callback.target_tx_count +
    egress_target_callback.target_tx_count), UVM_NONE)
```

Do not include the words `unexpected Completion` or `spurious Completion` in successful messages; the acceptance checker reserves those phrases for actual diagnostics.

- [ ] **Step 7: Build and run a fresh full-traffic acceptance test**

Stage the current probe, tap, file list, and checker on `10.11.10.53`, then
create a new build directory and a new VCS `Mdir`. A reused Task 3 executable
is RED evidence only and cannot be used for GREEN:

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  set -euo pipefail
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12
  build_dir=\$(mktemp -d build_tl_proxy_passive_cfg.XXXXXX)

  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    -f pcie_svt_tl_proxy_probe.f -top pcie_svt_tl_proxy_probe_top \
    -Mdir=\$build_dir/csrc -P pli.tab msglog.o \
    -o \$build_dir/simv -l \$build_dir/compile.log

  ./\$build_dir/simv -no_save +UVM_NO_RELNOTES \
    +ntb_random_seed=1 -l \$build_dir/full_traffic.log
  ./check_tl_proxy_passive_sidecar_log.sh full \
    \$build_dir/full_traffic.log
  grep -a -E 'TL_PROXY_CFG_FIELDS_TRACE|TL_PROXY_CFG_GATE_TRACE' \
    \$build_dir/full_traffic.log
  echo \$build_dir
"'
```

The official full checker is the marker-count oracle. It must exit zero and
therefore prove Stage A, MWr, the anchored Source Driver successful-CfgRd
trace, Cfg, and terminal PASS exactly once, BLOCKED zero times, no reserved
Completion diagnostic, and UVM W/E/F `0/0/0`. Baseline and sidecar-link must
contain zero Source Driver success traces. The Cfg
field trace must show a runtime Tag greater than `10'h0ff` and the same value
on the request, Egress Completion, and Ingress Completion. The exact-gate
trace must show request queues `2/2/2`, Completion queues `1/1`, Target
requests `2/0`, bridge counts `2/2/1/1`, sink counts `1/1`, Source Driver
counts `2/1/1` (all ends/armed CfgRd ends/successful CfgRd ends), and Proxy
Target TX counts `0/0`. The fresh compile log may
contain the known `LIB-NO-EXT` warning, but must contain no `SV-ANDNMD` or new
warning class.
`TL_PROXY_PASSIVE_CFG_TRACE` must appear once with all four readbacks equal to
one.

### Task 5: Run Fresh Acceptance and Measure Sidecar Cost

**Files:**
- Verify: all Task 1 implementation files
- Test: one fresh build, two fixed-window link runs, one full traffic run
- Artifacts: three `.log` files and three GNU `time -v` files in the fresh remote build directory

- [ ] **Step 1: Review the diff before consuming simulation time**

Run locally:

```bash
git diff --check
git diff -- \
  svt_pcie_integration/rtl/pcie_svt_passive_sidecar_tap.sv \
  svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv \
  svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.f \
  svt_pcie_integration/sim/check_tl_proxy_passive_sidecar_log.sh
```

Expected: no whitespace errors; every assignment in the tap file has a sidecar-interface signal on its left-hand side; no active Serial or active SVT signal is driven by a sidecar.

- [ ] **Step 2: Create one fresh build and run all three measurements**

Run:

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  set -euo pipefail
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12
  build_dir=\$(mktemp -d build_tl_proxy_passive_accept.XXXXXX)

  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    -f pcie_svt_tl_proxy_probe.f -top pcie_svt_tl_proxy_probe_top \
    -Mdir=\$build_dir/csrc -P pli.tab msglog.o \
    -o \$build_dir/simv -l \$build_dir/compile.log

  /usr/bin/time -v -o \$build_dir/four_active.time \
    ./\$build_dir/simv -no_save +UVM_NO_RELNOTES \
      +TL_PROXY_LINK_ONLY +TL_PROXY_DISABLE_SIDECARS \
      +ntb_random_seed=1 -l \$build_dir/four_active.log
  ./check_tl_proxy_passive_sidecar_log.sh baseline \
    \$build_dir/four_active.log

  /usr/bin/time -v -o \$build_dir/two_sidecars.time \
    ./\$build_dir/simv -no_save +UVM_NO_RELNOTES \
      +TL_PROXY_LINK_ONLY +ntb_random_seed=1 \
      -l \$build_dir/two_sidecars.log
  ./check_tl_proxy_passive_sidecar_log.sh sidecar-link \
    \$build_dir/two_sidecars.log

  /usr/bin/time -v -o \$build_dir/full_traffic.time \
    ./\$build_dir/simv -no_save +UVM_NO_RELNOTES \
      +ntb_random_seed=1 -l \$build_dir/full_traffic.log
  ./check_tl_proxy_passive_sidecar_log.sh full \
    \$build_dir/full_traffic.log

  grep -E \"Elapsed \(wall clock\) time|Maximum resident set size\" \
    \$build_dir/four_active.time \$build_dir/two_sidecars.time \
    \$build_dir/full_traffic.time
  echo \$build_dir
"'
```

Expected:

- baseline and sidecar link runs use the same executable, seed, active
  configuration, explicit four-endpoint LTSSM-L0 gate, and 10 us post-L0
  window;
- all three runs report W/E/F `0/0/0`;
- both link runs reach Gen4 x4 on both links;
- the full run emits Stage A, MWr, Cfg, and final PASS exactly once each;
- the full run emits zero BLOCKED markers and no unexpected/spurious Completion text;
- the three `.time` files record wall time and peak RSS.

- [ ] **Step 3: Record the measured cost without inventing a threshold**

Copy the exact `Elapsed (wall clock) time` and `Maximum resident set size` lines into the Task 1 handoff. Compute and report the sidecar-minus-baseline delta for wall time and peak RSS. Do not call the overhead acceptable or unacceptable; the five-port scaling decision remains outside Task 1.

### Task 6: Document the Reproducible Task 1 Result

**Files:**
- Modify: `svt_pcie_integration/sim/README.md`
- Test: every documented command matches the accepted command line

- [ ] **Step 1: Add a focused passive-sidecar section**

Append this structure using the actual accepted build-directory name and measured values from Task 5:

```markdown
### Passive-sidecar transparent TL proxy feasibility probe

The Task 1 feasibility probe keeps four active full Device Agents on two Gen4
x4 Serial links and adds two standalone passive SERDES sidecars. The sidecars
are observation-only; request suppression remains owned by the Ingress Target
callback, raw request/Completion reinjection uses the opposite Proxy's public
`tlp_seqr`, and encoded TLP DWORD arrays are compared across independent
passive boundaries.

Runtime modes:

- `+TL_PROXY_LINK_ONLY +TL_PROXY_DISABLE_SIDECARS`: four-active baseline.
- `+TL_PROXY_LINK_ONLY`: four active plus two passive, fixed 10 us window.
- no probe mode plusarg: MWr plus CfgRd/CPL transparent traffic.

Acceptance uses:

```bash
: "${build_dir:?set build_dir to the fresh build path printed above}"
./check_tl_proxy_passive_sidecar_log.sh baseline "$build_dir/four_active.log"
./check_tl_proxy_passive_sidecar_log.sh sidecar-link "$build_dir/two_sidecars.log"
./check_tl_proxy_passive_sidecar_log.sh full "$build_dir/full_traffic.log"
```

The accepted run records GNU `time -v` output in `four_active.time`,
`two_sidecars.time`, and `full_traffic.time`. Preserve the build directory as
Task 1 evidence until the implementation and reviews are complete.
```

Add the six measured wall-time/RSS lines verbatim below the paragraph; do not round them.

- [ ] **Step 2: Verify documentation and implementation use identical markers**

Run:

```bash
rg -n 'TL_PROXY_(FOUR_ACTIVE_BASELINE|PASSIVE_SIDECAR)' \
  svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv \
  svt_pcie_integration/sim/check_tl_proxy_passive_sidecar_log.sh \
  svt_pcie_integration/sim/README.md
```

Expected: README commands and checker markers exactly match the implementation.

### Task 7: GREEN-Only Cleanup, Atomic Commit, and Two Reviews

**Files:**
- Delete only after GREEN: `svt_pcie_integration/sim/pcie_svt_mapper_probe.sv`
- Delete only after GREEN: `svt_pcie_integration/sim/pcie_svt_mapper_probe.f`
- Commit: all Task 1 implementation and documentation files
- Review: approved passive-sidecar specification and the final Task 1 diff

- [ ] **Step 1: Re-run the GREEN gate before deleting old evidence**

Run all three accepted-log checks again against the preserved fresh build directory:

```bash
read -r accepted_build_dir
svt_pcie_integration/sim/check_tl_proxy_passive_sidecar_log.sh \
  baseline "$accepted_build_dir/four_active.log"
svt_pcie_integration/sim/check_tl_proxy_passive_sidecar_log.sh \
  sidecar-link "$accepted_build_dir/two_sidecars.log"
svt_pcie_integration/sim/check_tl_proxy_passive_sidecar_log.sh \
  full "$accepted_build_dir/full_traffic.log"
```

Paste the absolute path printed by Task 5 into `read`. Run these commands on
the VCS host from `svt_pcie_integration/sim`; if any check fails, retain both
Mapper files and stop Task 1.

- [ ] **Step 2: Delete the superseded Mapper probe only after the gate passes**

Use `apply_patch` to delete exactly:

```text
svt_pcie_integration/sim/pcie_svt_mapper_probe.sv
svt_pcie_integration/sim/pcie_svt_mapper_probe.f
```

These two files are currently untracked, so their removal cannot appear as a
Git deletion. Before applying the deletion, verify the copies staged under
`/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim`
still exist; those remote copies are the recovery source until Task 1 handoff
is accepted.

- [ ] **Step 3: Run final local consistency checks**

Run:

```bash
bash -n svt_pcie_integration/sim/check_tl_proxy_passive_sidecar_log.sh
git diff --check
git status --short
git diff --stat
rg -n 'TL_PROXY_API_PROBE_BLOCKED|TL_PROXY_APP_CALLBACK_PROBE_PASS' \
  svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv \
  svt_pcie_integration/sim/check_tl_proxy_passive_sidecar_log.sh
```

Expected: Bash syntax and whitespace checks pass; the final `rg` finds no superseded markers; only the approved Task 1 files and Mapper deletions are present.

- [ ] **Step 4: Create the one atomic implementation commit**

Run:

```bash
git add \
  svt_pcie_integration/rtl/pcie_svt_passive_sidecar_tap.sv \
  svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv \
  svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.f \
  svt_pcie_integration/sim/check_tl_proxy_passive_sidecar_log.sh \
  svt_pcie_integration/sim/README.md
git commit -m "feat: prove transparent SVT proxy with passive sidecars"
```

Expected: one implementation commit containing the input-only taps, six-Agent
probe, transparent traffic proof, acceptance checker, and README evidence; the
two formerly untracked Mapper files are absent from the local worktree.

- [ ] **Step 5: Perform a specification-conformance review**

Give a fresh reviewer only:

```text
docs/superpowers/specs/2026-08-17-svt-pcie-passive-sidecar-proxy-design.md
the Task 1 implementation commit diff
the three accepted logs and three time files
```

The reviewer must explicitly verify every hard constraint, Stage A/B/C exact count, 100 us timeout, 10-bit Tag proof, no active-link drive from taps, zero unexpected/spurious Completion diagnostics, fresh-build evidence, and performance recording. Any unmet requirement reopens Task 1 and forbids Task 2.

- [ ] **Step 6: Perform a separate code-quality review**

Give a different fresh reviewer the implementation diff after specification review passes. Require findings on callback nonblocking behavior, clone ownership, mailbox ownership, subscriber filtering/loop prevention, raw-sequence lifecycle, null-handle safety, exact terminal markers, SystemVerilog type consistency, and maintainability. Resolve findings, rerun the full fresh acceptance command, and amend the single implementation commit only if the accepted behavior remains unchanged.

- [ ] **Step 7: Stop at the Task 1 boundary**

Report the implementation commit, remote fresh build directory, all three marker/count results, W/E/F counts, measured wall/RSS values and deltas, and both review outcomes. Do not begin the parent plan's Task 2 until the user explicitly continues after reviewing this evidence.
