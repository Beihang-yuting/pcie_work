# SVT PCIe Dynamic Control-Plane Observation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correlate official R-2020.12 switch-enumeration wire traffic with the Switch Proxy's actual routing decisions, then complete Gen4 enumeration with exact wire proof and only the documented STAR#9000762979 checker exception.

**Architecture:** `pcie_tl_switch` publishes one repository-owned, deep-cloned route event immediately before each egress FIFO write. The existing scoreboard retains strict pre-registration as its default and adds a Task-9-only deferred mode that joins passive RX observations with route events in either order before validating passive TX exactly once. The proxy test enables the one official passive checker workaround only for enum mode, and the enumeration sequence owns the deferred-mode lifetime and final empty-state gate.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys SVT PCIe R-2020.12, VCS W-2024.09-SP1, Serial PCIe Gen4, repository `pcie_tl_switch`.

---

## Preconditions and Execution Contract

The governing design is:

```text
docs/superpowers/specs/2026-08-19-svt-pcie-dynamic-control-plane-observation-design.md
```

Work in the existing isolated worktree and branch:

```text
/home/ryan/.config/superpowers/worktrees/pcie_work/svt-switch-proxy
feature/svt-switch-proxy
```

Do not discard, restore, or overwrite the current Task 9 WIP:

```text
M  svt_pcie_integration/uvm/pcie_svt_env.sv
M  svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv
M  svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv
M  svt_pcie_integration/uvm/pcie_svt_virtual_sequencer.sv
?? svt_pcie_integration/sim/pcie_svt_switch_enum_registry_unit_test.sv
?? svt_pcie_integration/uvm/pcie_svt_switch_enum_registry.sv
?? svt_pcie_integration/uvm/sequences/pcie_svt_switch_enumeration_vseq.sv
```

All VCS compilation and simulation runs are serial and execute only on
`ubuntu@10.11.10.53` through `bash -lic`. Use fresh build directories below:

```text
/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim
```

Every SVT command explicitly sets:

```bash
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT="$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12"
```

Keep the Synopsys installation read-only. Do not use a report catcher,
severity downgrade, private vendor state, `force`, `deposit`, or vendor-source
change. Negative tests run as separate simulator processes and pass only when
their exact production fatal ID appears.

Before each remote build, synchronize only the files named by the current
task. From the worktree root, use `rsync -aR <paths...>
ubuntu@10.11.10.53:/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/`;
authenticate interactively so no password is stored in the repository.

## File Structure

- `pcie_tl_vip/src/switch/pcie_tl_switch_route_event.sv`: route action,
  event-owned normalized TLP snapshots, event ID, and ports.
- `pcie_tl_vip/src/pcie_tl_switch_pkg.sv`: includes the route-event type before
  the switch class.
- `pcie_tl_vip/src/switch/pcie_tl_switch.sv`: publishes one event immediately
  before forward/local egress and one event for every drop/broadcast decision.
- `svt_pcie_integration/uvm/pcie_svt_switch_scoreboard.sv`: strict/deferred
  modes, normalized-event conversion, correlation state, and final gates.
- `svt_pcie_integration/uvm/pcie_svt_switch_sidecar_env.sv`: applies the exact
  STAR#9000762979 public checker call when enum mode requests it.
- `svt_pcie_integration/uvm/pcie_svt_env.sv`: connects one switch route port to
  the scoreboard and propagates enum-only STAR policy to all five sidecars.
- `svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv`: publishes enum mode
  to the environment before child build.
- `svt_pcie_integration/uvm/sequences/pcie_svt_switch_enumeration_vseq.sv`:
  brackets official enumeration plus readback with deferred mode and drop/
  queue/outstanding gates.
- `svt_pcie_integration/sim/pcie_tl_switch_proxy_unit_test.sv`: route-event
  timing, deep-clone, rewrite, local-response, Completion, and drop proof.
- `svt_pcie_integration/sim/pcie_svt_switch_adapter_unit_test.sv`: strict-mode
  preservation plus deferred positive and negative scoreboard tests.
- Existing Task 9 registry, virtual-sequencer, package, and registry-unit files
  remain the source of enumeration structure and BAR validation.

### Task 1: Publish Deep-Cloned Switch Route Events

**Files:**
- Create: `pcie_tl_vip/src/switch/pcie_tl_switch_route_event.sv`
- Modify: `pcie_tl_vip/src/pcie_tl_switch_pkg.sv`
- Modify: `pcie_tl_vip/src/switch/pcie_tl_switch.sv`
- Modify: `svt_pcie_integration/sim/pcie_tl_switch_proxy_unit_test.sv`
- Test: `svt_pcie_integration/sim/build_switch_route_observer.*/run.log`

- [ ] **Step 1: Add the route-event collector and assertions before implementation**

Add this collector above `pcie_tl_switch_proxy_unit_test`:

```systemverilog
class pcie_tl_route_event_collector extends uvm_component;
    `uvm_component_utils(pcie_tl_route_event_collector)

    uvm_analysis_imp #(pcie_tl_switch_route_event,
                       pcie_tl_route_event_collector) analysis_export;
    pcie_tl_switch source_switch;
    pcie_tl_switch_route_event events[$];

    function new(string name, uvm_component parent);
        super.new(name, parent);
        analysis_export = new("analysis_export", this);
    endfunction

    function void write(pcie_tl_switch_route_event event);
        if (event == null)
            `uvm_fatal("ROUTE_EVENT_TEST", "collector received null event")
        if ((event.action inside {PCIE_TL_ROUTE_FORWARD,
                                  PCIE_TL_ROUTE_LOCAL_RESPONSE}) &&
            (source_switch.all_ports[event.egress_port].tx_fifo.used() != 0))
            `uvm_fatal("ROUTE_EVENT_ORDER",
                       "event was not published before egress FIFO put")
        events.push_back(event);
    endfunction
endclass
```

Create `route_collector` in the unit test, assign `source_switch = sw`, and
connect it in `connect_phase`:

```systemverilog
sw.route_observed_port.connect(route_collector.analysis_export);
```

At the end of existing request/rewrite/Completion checks, require ordered
events with these contracts:

```systemverilog
if (route_collector.events.size() == 0)
    $fatal(1, "no switch route events were observed");
foreach (route_collector.events[i]) begin
    if (route_collector.events[i].event_id != i)
        $fatal(1, "route event ID expected=%0d actual=%0d", i,
               route_collector.events[i].event_id);
    if (route_collector.events[i].ingress_tlp == null)
        $fatal(1, "route event %0d has null ingress snapshot", i);
end
```

For the existing Type-1 read forwarded to DSP0, save the event index before
putting the request, then require:

```systemverilog
route_event = route_collector.events[event_index];
if ((route_event.action != PCIE_TL_ROUTE_FORWARD) ||
    (route_event.ingress_port != 0) || (route_event.egress_port != 1) ||
    (route_event.route_code != 1) ||
    (route_event.ingress_tlp.kind != TLP_CFG_RD1) ||
    (route_event.egress_tlp.kind != TLP_CFG_RD0))
    $fatal(1, "Cfg1-to-Cfg0 route event contract failed");
```

For local Configuration Read/Write, require `LOCAL_RESPONSE`, equal physical
ports, the original Configuration kind, and `TLP_CPLD`/`TLP_CPL`. For a
returning Completion, require `FORWARD`, DSP ingress, USP egress, and identical
Completion fields. Mutate the original request only after the event arrives
and require the stored event fields and prefixes stay unchanged. Print:

```text
SWITCH_ROUTE_OBSERVER_PASS forward=1 rewrite=1 local_read=1 local_write=1 completion=1 clone=1
```

- [ ] **Step 2: Run the switch unit test to establish RED**

Synchronize the modified unit test, then run:

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  b=\$(mktemp -d build_switch_route_observer_red.XXXXXX) &&
  vcs -full64 -sverilog -ntb_opts uvm-1.2 \
    -f pcie_tl_switch_unit.f -top pcie_tl_switch_proxy_unit_top \
    -Mdir=\$b/csrc -o \$b/simv -l \$b/compile.log
"'
```

Expected: compile failure naming undefined `pcie_tl_switch_route_event` or
missing `route_observed_port`. Preserve the build path and diagnostic.

- [ ] **Step 3: Implement the route-event value object**

Create `pcie_tl_switch_route_event.sv` with the design enum and class. Provide
one cloning helper that fixes the repository base-class copy omissions:

```systemverilog
static function pcie_tl_tlp snapshot(pcie_tl_tlp source,
                                     string label);
    pcie_tl_tlp result;
    pcie_tl_cfg_tlp source_cfg;
    pcie_tl_cfg_tlp result_cfg;
    pcie_tl_prefix prefix;

    if ((source == null) || !$cast(result, source.clone()) ||
        (result == null)) begin
        `uvm_fatal("SWITCH_ROUTE_EVENT_CLONE",
                   {label, ": normalized TLP clone failed"})
        return null;
    end
    result.at = source.at;
    result.prefixes.delete();
    foreach (source.prefixes[i]) begin
        if (source.prefixes[i] == null) begin
            `uvm_fatal("SWITCH_ROUTE_EVENT_CLONE",
                       {label, ": null prefix"})
            return null;
        end
        prefix = new($sformatf("prefix_%0d", i));
        prefix.prefix_type = source.prefixes[i].prefix_type;
        prefix.raw_dw = source.prefixes[i].raw_dw;
        result.prefixes.push_back(prefix);
    end
    if ($cast(source_cfg, source)) begin
        if (!$cast(result_cfg, result)) begin
            `uvm_fatal("SWITCH_ROUTE_EVENT_CLONE",
                       {label, ": Configuration clone type changed"})
            return null;
        end
        result_cfg.completer_id = source_cfg.completer_id;
        result_cfg.reg_num = source_cfg.reg_num;
        result_cfg.first_be = source_cfg.first_be;
    end
    return result;
endfunction
```

Use the helper in this complete event shell:

```systemverilog
typedef enum int unsigned {
    PCIE_TL_ROUTE_FORWARD,
    PCIE_TL_ROUTE_LOCAL_RESPONSE,
    PCIE_TL_ROUTE_DROP,
    PCIE_TL_ROUTE_UNSUPPORTED_BROADCAST
} pcie_tl_switch_route_action_e;

class pcie_tl_switch_route_event extends uvm_object;
    `uvm_object_utils(pcie_tl_switch_route_event)

    longint unsigned event_id;
    pcie_tl_switch_route_action_e action;
    int ingress_port;
    int egress_port;
    int route_code;
    pcie_tl_tlp ingress_tlp;
    pcie_tl_tlp egress_tlp;

    function new(string name = "pcie_tl_switch_route_event");
        super.new(name);
        event_id = '1;
        ingress_port = -1;
        egress_port = SWITCH_ROUTE_DROP;
        route_code = SWITCH_ROUTE_DROP;
    endfunction

    function void set_snapshots(pcie_tl_tlp ingress,
                                pcie_tl_tlp egress);
        ingress_tlp = snapshot(ingress, "ingress");
        if (action == PCIE_TL_ROUTE_DROP) begin
            if (egress != null)
                `uvm_fatal("SWITCH_ROUTE_EVENT_CONTRACT",
                           "drop event has a non-null egress TLP")
            egress_tlp = null;
        end else begin
            if (egress == null)
                `uvm_fatal("SWITCH_ROUTE_EVENT_CONTRACT",
                           "non-drop event has a null egress TLP")
            egress_tlp = snapshot(egress, "egress");
        end
    endfunction

    static function pcie_tl_tlp snapshot(pcie_tl_tlp source,
                                         string label);
        pcie_tl_tlp result;
        pcie_tl_cfg_tlp source_cfg;
        pcie_tl_cfg_tlp result_cfg;
        pcie_tl_prefix prefix;

        if ((source == null) || !$cast(result, source.clone()) ||
            (result == null)) begin
            `uvm_fatal("SWITCH_ROUTE_EVENT_CLONE",
                       {label, ": normalized TLP clone failed"})
            return null;
        end
        result.at = source.at;
        result.prefixes.delete();
        foreach (source.prefixes[i]) begin
            if (source.prefixes[i] == null) begin
                `uvm_fatal("SWITCH_ROUTE_EVENT_CLONE",
                           {label, ": null prefix"})
                return null;
            end
            prefix = new($sformatf("prefix_%0d", i));
            prefix.prefix_type = source.prefixes[i].prefix_type;
            prefix.raw_dw = source.prefixes[i].raw_dw;
            result.prefixes.push_back(prefix);
        end
        if ($cast(source_cfg, source)) begin
            if (!$cast(result_cfg, result)) begin
                `uvm_fatal("SWITCH_ROUTE_EVENT_CLONE",
                           {label, ": Configuration clone type changed"})
                return null;
            end
            result_cfg.completer_id = source_cfg.completer_id;
            result_cfg.reg_num = source_cfg.reg_num;
            result_cfg.first_be = source_cfg.first_be;
        end
        return result;
    endfunction
endclass
```

Include it in `pcie_tl_switch_pkg.sv` immediately after
`types/pcie_tl_tlp.sv` and before `pcie_tl_switch.sv`.

- [ ] **Step 4: Publish from every switch routing branch**

Add to `pcie_tl_switch`:

```systemverilog
uvm_analysis_port #(pcie_tl_switch_route_event) route_observed_port;
longint unsigned next_route_event_id;

function new(string name = "pcie_tl_switch", uvm_component parent = null);
    super.new(name, parent);
    route_observed_port = new("route_observed_port", this);
endfunction

protected function void publish_route_event(
    pcie_tl_switch_route_action_e action,
    int ingress_port, int egress_port, int route_code,
    pcie_tl_tlp ingress_tlp, pcie_tl_tlp egress_tlp);
    pcie_tl_switch_route_event event;
    event = pcie_tl_switch_route_event::type_id::create(
      $sformatf("route_event_%0d", next_route_event_id));
    if (event == null)
        `uvm_fatal("SWITCH_ROUTE_EVENT_CREATE", "event creation failed")
    event.event_id = next_route_event_id++;
    event.action = action;
    event.ingress_port = ingress_port;
    event.egress_port = egress_port;
    event.route_code = route_code;
    event.set_snapshots(ingress_tlp, egress_tlp);
    route_observed_port.write(event);
endfunction
```

Call it immediately before every corresponding `tx_fifo.put()`:

```systemverilog
publish_route_event(PCIE_TL_ROUTE_FORWARD, ingress_port_id, dst, dst,
                    tlp, forwarded_tlp);
all_ports[dst].tx_fifo.put(forwarded_tlp);
```

Returning Completions use the same `FORWARD` call. In
`handle_local_config()`, call `publish_route_event()` after constructing the
Completion and before the same-port put:

```systemverilog
publish_route_event(PCIE_TL_ROUTE_LOCAL_RESPONSE,
                    ingress_port_id, ingress_port_id, SWITCH_ROUTE_LOCAL,
                    tlp, cpl);
```

For no-route, cross-root, or invalid destination, publish `DROP` with
`egress_port=SWITCH_ROUTE_DROP`, the original `dst` in `route_code`, and null
egress. For broadcast, publish one `UNSUPPORTED_BROADCAST` event before the
loop, using `egress_port=SWITCH_ROUTE_BCAST`, `route_code=SWITCH_ROUTE_BCAST`,
and the original TLP as both snapshots.

- [ ] **Step 5: Run GREEN switch-unit coverage**

Synchronize all four Task 1 files and run a fresh build:

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  b=\$(mktemp -d build_switch_route_observer_green.XXXXXX) &&
  vcs -full64 -sverilog -ntb_opts uvm-1.2 \
    -f pcie_tl_switch_unit.f -top pcie_tl_switch_proxy_unit_top \
    -Mdir=\$b/csrc -o \$b/simv -l \$b/compile.log &&
  \$b/simv -l \$b/run.log &&
  test \"\$(grep -a -c SWITCH_ROUTE_OBSERVER_PASS \$b/run.log)\" -eq 1 &&
  test \"\$(grep -a -c SWITCH_ROUTE_PASS \$b/run.log)\" -eq 1 &&
  test \"\$(grep -a -c SWITCH_PACKAGE_SMOKE_PASS \$b/run.log)\" -eq 1 &&
  grep -a -q \"UVM_WARNING *: *0\" \$b/run.log &&
  grep -a -q \"UVM_ERROR *: *0\" \$b/run.log &&
  grep -a -q \"UVM_FATAL *: *0\" \$b/run.log
"'
```

Run the existing duplicate-NP, unknown-Completion, and duplicate-BDF negative
processes and require their original fatal IDs. They must not be masked by the
observer.

- [ ] **Step 6: Commit the switch observer**

```bash
git add pcie_tl_vip/src/switch/pcie_tl_switch_route_event.sv \
        pcie_tl_vip/src/pcie_tl_switch_pkg.sv \
        pcie_tl_vip/src/switch/pcie_tl_switch.sv \
        svt_pcie_integration/sim/pcie_tl_switch_proxy_unit_test.sv
git diff --cached --check
git commit -m "feat: publish switch route observation events"
```

### Task 2: Add Deferred Enumeration Correlation to the Scoreboard

**Files:**
- Modify: `svt_pcie_integration/uvm/pcie_svt_switch_scoreboard.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt_switch_adapter_unit_test.sv`
- Test: `svt_pcie_integration/sim/build_switch_deferred_scoreboard.*/run*.log`

- [ ] **Step 1: Add deferred positive tests before implementation**

Add helpers to create a normalized route event from SVT ingress/egress TLPs:

```systemverilog
function automatic pcie_tl_switch_route_event make_route_event(
    longint unsigned event_id,
    pcie_tl_switch_route_action_e action,
    int ingress, int egress,
    svt_pcie_tlp ingress_tlp,
    svt_pcie_tlp egress_tlp);
    pcie_tl_switch_route_event event;
    pcie_tl_tlp ingress_normalized;
    pcie_tl_tlp egress_normalized;
    string reason;
    require(pcie_svt_tlp_converter::from_svt(
              ingress_tlp, ingress_normalized, reason), reason);
    if (egress_tlp != null)
      require(pcie_svt_tlp_converter::from_svt(
                egress_tlp, egress_normalized, reason), reason);
    else
      egress_normalized = null;
    event = new($sformatf("event_%0d", event_id));
    event.event_id = event_id;
    event.action = action;
    event.ingress_port = ingress;
    event.egress_port = egress;
    event.route_code = (action == PCIE_TL_ROUTE_LOCAL_RESPONSE) ?
                       SWITCH_ROUTE_LOCAL : egress;
    event.set_snapshots(ingress_normalized, egress_normalized);
    return event;
endfunction
```

Add two independent positive tasks:

```systemverilog
scoreboard.begin_deferred_enumeration();
scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 1, request);
scoreboard.write(make_route_event(0, PCIE_TL_ROUTE_FORWARD,
                                  1, 2, request, request));
scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 2, request);
scoreboard.end_deferred_enumeration();
$display("SWITCH_DEFERRED_RX_FIRST_PASS");
```

```systemverilog
scoreboard.begin_deferred_enumeration();
scoreboard.write(make_route_event(1, PCIE_TL_ROUTE_FORWARD,
                                  1, 2, request, request));
scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 1, request);
scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 2, request);
scoreboard.end_deferred_enumeration();
$display("SWITCH_DEFERRED_EVENT_FIRST_PASS");
```

Add positive cases for Cfg1-to-Cfg0, local Configuration Read, local
Configuration Write, and Completion forwarding. Each case starts and ends its
own deferred phase and checks the exact physical ports and rewritten/generated
TLP.

- [ ] **Step 2: Add exact negative cases before implementation**

Extend `+ADAPTER_NEGATIVE=` with:

```text
deferred_duplicate_event
deferred_duplicate_rx
deferred_wrong_ingress
deferred_wrong_egress
deferred_drop
deferred_payload_mismatch
deferred_missing_route
deferred_missing_rx
deferred_missing_tx
deferred_tx_before_rx
deferred_nested_begin
deferred_end_strict
```

Each mode performs only the minimal triggering calls. For example:

```systemverilog
"deferred_missing_route": begin
  scoreboard.begin_deferred_enumeration();
  scoreboard.observe_wire(PCIE_SVT_WIRE_RX, 1, request);
  scoreboard.end_deferred_enumeration();
end
"deferred_tx_before_rx": begin
  scoreboard.begin_deferred_enumeration();
  scoreboard.write(make_route_event(2, PCIE_TL_ROUTE_FORWARD,
                                    1, 2, request, request));
  scoreboard.observe_wire(PCIE_SVT_WIRE_TX, 2, request);
end
```

Use these required fatal IDs:

| Mode | Fatal ID |
| --- | --- |
| duplicate event | `SCOREBOARD_ROUTE_DUPLICATE` |
| duplicate/ambiguous RX | `SCOREBOARD_AMBIGUOUS` or `SCOREBOARD_DUPLICATE` |
| wrong ingress/egress | `SCOREBOARD_WRONG_INGRESS` / `SCOREBOARD_WRONG_EGRESS` |
| route drop/broadcast | `SCOREBOARD_ROUTE_DROP` |
| payload mismatch | `SCOREBOARD_PAYLOAD_MISMATCH` |
| missing route/RX/TX | `SCOREBOARD_MISSING_ROUTE` / `SCOREBOARD_MISSING_INGRESS` / `SCOREBOARD_MISSING` |
| TX before RX | `SCOREBOARD_MISSING_INGRESS` |
| invalid mode transition | `SCOREBOARD_MODE` |

- [ ] **Step 3: Run the new tests to establish RED**

Synchronize the modified adapter unit and run the existing adapter compile
command in a fresh `build_switch_deferred_scoreboard_red.*` directory.
Expected: compile failures naming `begin_deferred_enumeration`, `write`, or
`end_deferred_enumeration`. Preserve the failing log.

- [ ] **Step 4: Implement explicit scoreboard modes and route-event input**

Add:

```systemverilog
typedef enum int unsigned {
  PCIE_SVT_SCOREBOARD_STRICT,
  PCIE_SVT_SCOREBOARD_DEFERRED_ENUM
} pcie_svt_scoreboard_mode_e;

class pcie_svt_switch_pending_rx;
  int port;
  pcie_svt_switch_value_signature signature;
endclass
```

Add these members to the scoreboard:

```systemverilog
uvm_analysis_imp #(pcie_tl_switch_route_event,
                   pcie_svt_switch_scoreboard) route_event_export;
pcie_svt_scoreboard_mode_e mode = PCIE_SVT_SCOREBOARD_STRICT;
protected pcie_svt_switch_pending_rx pending_rx[$];
protected bit seen_event_id[longint unsigned];
protected int unsigned dynamic_event_count;
protected int unsigned dynamic_complete_count;
```

Construct `route_event_export` in `new()`. Add
`make_signature_from_normalized()` by converting the normalized TLP through
`pcie_svt_tlp_converter::to_svt()` and then calling the existing full
`make_signature()`; conversion failure is `SCOREBOARD_ROUTE_CONVERSION`.

`begin_deferred_enumeration()` requires strict mode and empty `expected` plus
`pending_rx`, then clears `completed`, event IDs, and counters. Route events in
strict mode return without changing state.

- [ ] **Step 5: Implement the two-order correlation state machine**

Implement `write(pcie_tl_switch_route_event event)` with this order:

```text
validate event/action/ports/snapshots
reject reused event_id
fatal immediately on DROP or UNSUPPORTED_BROADCAST
convert ingress and egress snapshots to full value signatures
find exact pending RX matches on ingress
  more than one -> SCOREBOARD_AMBIGUOUS
  one -> remove it and create expectation with rx_seen=1
  zero -> create expectation with rx_seen=0
increment dynamic_event_count only after successful creation
```

In deferred `observe_rx()`:

```text
find exact live expectations on this ingress
  more than one -> SCOREBOARD_AMBIGUOUS
  one -> set rx_seen and return
reject exact live match on another ingress
reject duplicate exact unresolved pending RX
reject same-header/different-payload conflicts
append a full-signature pending RX entry
```

Keep strict `observe_rx()` behavior byte-for-byte unchanged behind the default
mode branch. Keep `observe_tx()` strict matching rules, but increment
`dynamic_complete_count` when a deferred expectation moves to `completed`.

`end_deferred_enumeration()` diagnoses residual state in this order:

```text
pending RX -> SCOREBOARD_MISSING_ROUTE
expected with rx_seen=0 -> SCOREBOARD_MISSING_INGRESS
expected with rx_seen=1 -> SCOREBOARD_MISSING
event/completion count mismatch -> SCOREBOARD_COUNT
```

On success, print exactly:

```text
SWITCH_DEFERRED_SCOREBOARD_EMPTY events=<n> completed=<n> pending=0 expected=0
```

Then return to strict mode. `check_empty()` continues to support strict unit
tests and also rejects a still-active deferred phase.

- [ ] **Step 6: Run deferred positive and negative GREEN tests**

Compile once on host 53 into a fresh
`build_switch_deferred_scoreboard_green.*`, then run these positive modes as
separate processes:

```text
deferred_rx_first
deferred_event_first
deferred_cfg_rewrite
deferred_local_cfg_read
deferred_local_cfg_write
deferred_completion
```

Require one named `*_PASS`, one
`SWITCH_DEFERRED_SCOREBOARD_EMPTY`, and W/E/F=`0/0/0` in every log. Run every
negative mode from Step 2 separately and require its named fatal ID and the
absence of `SWITCH_ADAPTER_NEGATIVE_MISSED`.

Finally run the unchanged default adapter unit and all existing strict
positive modes. Require `SWITCH_ADAPTER_PASS`, all existing scoreboard pass
markers, and W/E/F=`0/0/0`. This proves Task 6 strict behavior did not change.

- [ ] **Step 7: Commit deferred correlation**

```bash
git add svt_pcie_integration/uvm/pcie_svt_switch_scoreboard.sv \
        svt_pcie_integration/sim/pcie_svt_switch_adapter_unit_test.sv
git diff --cached --check
git commit -m "feat: correlate deferred switch wire observations"
```

### Task 3: Wire Enumeration Observation and the Exact STAR Workaround

**Files:**
- Modify: `svt_pcie_integration/uvm/pcie_svt_switch_sidecar_env.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_env.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv`
- Modify: `svt_pcie_integration/uvm/sequences/pcie_svt_switch_enumeration_vseq.sv`
- Preserve/complete: `svt_pcie_integration/uvm/pcie_svt_switch_enum_registry.sv`
- Preserve/complete: `svt_pcie_integration/uvm/pcie_svt_virtual_sequencer.sv`
- Preserve/complete: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`
- Preserve/complete: `svt_pcie_integration/sim/pcie_svt_switch_enum_registry_unit_test.sv`
- Test: `svt_pcie_integration/sim/build_switch_enum_observed.*/run*.log`

- [ ] **Step 1: Add connection and policy checks before implementation**

In proxy `end_of_elaboration_phase`, require enum mode to expose exactly one
route-event connection and all five STAR markers to be driven by configuration,
not by unconditional sidecar behavior. Add these public state fields:

```systemverilog
bit apply_star_9000762979;
bit star_9000762979_applied;
```

to `pcie_svt_switch_sidecar_env`, and check:

```systemverilog
if (enum_only && !env.switch_sidecar[i].star_9000762979_applied)
  `uvm_fatal("SWITCH_STAR_POLICY", $sformatf(
    "enum sidecar port=%0d did not apply STAR#9000762979", i))
if (link_only && env.switch_sidecar[i].star_9000762979_applied)
  `uvm_fatal("SWITCH_STAR_POLICY", $sformatf(
    "link-only sidecar port=%0d applied enum-only workaround", i))
```

Expected RED: compile failure because the state fields and route connection do
not yet exist.

- [ ] **Step 2: Propagate enum mode before sidecar child build**

In `pcie_svt_switch_proxy_test::build_phase`, after parsing mutually exclusive
run modes, publish:

```systemverilog
uvm_config_db#(bit)::set(this, "env", "enumeration_mode", enum_only);
```

In `pcie_svt_env`, read `enumeration_mode` with default zero. Before creating
each sidecar, publish:

```systemverilog
uvm_config_db#(bit)::set(
  this, $sformatf("switch_sidecar[%0d]", i),
  "apply_star_9000762979", enumeration_mode);
```

In the sidecar `build_phase`, read the bit with default zero.

- [ ] **Step 3: Apply only the official public checker call**

In the sidecar `connect_phase`, after validating `agent.pcie_agent.tl_mon`,
execute only when `apply_star_9000762979` is one:

```systemverilog
if (agent.err_check == null)
  `uvm_fatal("SWITCH_STAR_9000762979",
             {get_full_name(), ": public err_check handle is null"})
void'(agent.err_check.disable_checks(
  "PASSIVE_DL_TX", "FLOW_CTRL_INIT", "txn_06_01_16"));
star_9000762979_applied = 1'b1;
`uvm_info("SWITCH_STAR_9000762979_APPLIED", $sformatf(
  "port=%0d rule=PASSIVE_DL_TX/FLOW_CTRL_INIT/txn_06_01_16",
  port_index), UVM_NONE)
```

Do not add any other `disable_checks()` call. Do not disable
`vc_initialization_start_check`.

- [ ] **Step 4: Connect and validate the switch route observer**

In `pcie_svt_env::connect_phase`, before the per-port adapter loop:

```systemverilog
if ((switch_core.route_observed_port == null) ||
    (switch_scoreboard.route_event_export == null))
  `uvm_fatal("SWITCH_ROUTE_OBSERVER_CONNECT",
             "switch or scoreboard route-event endpoint is null")
switch_core.route_observed_port.connect(
  switch_scoreboard.route_event_export);
```

In `end_of_elaboration_phase`, require
`switch_core.route_observed_port.size() == 1`. Do not create a second
subscriber and do not connect any sidecar analysis port to this route-event
channel.

- [ ] **Step 5: Bracket the complete Task 9 control plane with deferred mode**

At the start of the enumeration body, snapshot:

```systemverilog
int unsigned switch_drop_start;
int unsigned adapter_drop_start[5];
switch_drop_start = p_sequencer.switch_core.total_dropped;
for (int unsigned i = 0; i < 5; i++)
  adapter_drop_start[i] = p_sequencer.switch_adapter[i].drop_count;
p_sequencer.switch_scoreboard.begin_deferred_enumeration();
```

Keep the official `enum_seq.start()` and all existing registry load,
Configuration readback, BAR validation, and Command-register writes inside
this deferred lifetime.

Replace the immediate quiescence function with a bounded task. Poll until the
switch outstanding table, all ten adapter mailboxes, and scoreboard live state
are empty, or 100 us expires. Expose a read-only scoreboard function:

```systemverilog
function bit deferred_idle();
  return (mode == PCIE_SVT_SCOREBOARD_DEFERRED_ENUM) &&
         (pending_rx.size() == 0) && (expected.size() == 0) &&
         (dynamic_event_count == dynamic_complete_count);
endfunction
```

After quiescence:

```systemverilog
p_sequencer.switch_scoreboard.end_deferred_enumeration();
if (p_sequencer.switch_core.total_dropped != switch_drop_start)
  `uvm_fatal("SWITCH_ENUM_DROP",
    "switch drop count changed during official enumeration")
for (int unsigned i = 0; i < 5; i++)
  if (p_sequencer.switch_adapter[i].drop_count != adapter_drop_start[i])
    `uvm_fatal("SWITCH_ENUM_DROP", $sformatf(
      "adapter port=%0d drop count changed during enumeration", i))
```

Only after these checks may the sequence print the existing
`SWITCH_ENUM_PASS usp=1 dsp=4 ep=4 bars=12` marker.

- [ ] **Step 6: Re-run the registry unit before full VCS integration**

Synchronize the current registry/package/unit files. Rebuild the registry unit
on host 53 and run `valid`, `null_status`, `duplicate_bdf`,
`endpoint_without_parent`, `bar_32bit`, `bar_non_prefetchable`, `bar_overlap`,
and `bar_outside_window` as separate processes. Require:

```text
REGISTRY_UNIT_PASS usp=1 dsp=4 ep=4 bars=12
```

for `valid`, and the existing exact registry fatal for every negative case.
This step proves the preserved Task 9 WIP was not damaged by observer wiring.

- [ ] **Step 7: Compile the complete proxy image**

Synchronize every Task 3 file and run:

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12 &&
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12 &&
  b=\$(mktemp -d build_switch_enum_observed.XXXXXX) &&
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    +define+PCIE_TOPO_SWITCH_1X16_4X4 \
    +define+PCIE_USE_SVT_SWITCH_PROXY \
    -f pcie_svt.f -top pcie_svt_topology_top -Mdir=\$b/csrc \
    -P pli.tab msglog.o -o \$b/simv -l \$b/compile.log &&
  echo \$b
"'
```

Expected: compile/elaboration exit zero. Preserve the printed build path for
Steps 8 and 9.

- [ ] **Step 8: Re-run both Task 8 link-only modes**

Run the compiled image twice as independent processes:

```text
+PCIE_GEN=4 +PCIE_LINK_ONLY +PCIE_DISABLE_SWITCH_SIDECARS
+PCIE_GEN=4 +PCIE_LINK_ONLY
```

The disabled run requires five `LINK_PASS`, one
`SWITCH_SIDECARS_DISABLED_LINK_ONLY`, zero STAR markers, and W/E/F=`0/0/0`.
The enabled run requires five `LINK_PASS`, five `SWITCH_SIDECAR_READY`, zero
STAR markers, and W/E/F=`0/0/0`.

- [ ] **Step 9: Run observed official enumeration**

Run:

```bash
./simv -no_save +UVM_TESTNAME=pcie_svt_switch_proxy_test \
  +PCIE_GEN=4 +PCIE_ENUM_ONLY +UVM_NO_RELNOTES -l run_enum.log
```

Gate the log with:

```bash
test "$(grep -a -c 'UVM_INFO.*\[LINK_PASS\]' run_enum.log)" -eq 5
test "$(grep -a -c 'SWITCH_SIDECAR_READY port=' run_enum.log)" -eq 5
test "$(grep -a -c 'SWITCH_STAR_9000762979_APPLIED.*port=' run_enum.log)" -eq 5
test "$(grep -a -c 'SWITCH_DEFERRED_SCOREBOARD_EMPTY' run_enum.log)" -eq 1
test "$(grep -a -c 'SWITCH_ENUM_PASS usp=1 dsp=4 ep=4 bars=12' run_enum.log)" -eq 1
! grep -a -q 'SWITCH_ADAPTER_DROP\|SCOREBOARD_ROUTE_DROP' run_enum.log
grep -a -q 'UVM_WARNING *: *0' run_enum.log
grep -a -q 'UVM_ERROR *: *0' run_enum.log
grep -a -q 'UVM_FATAL *: *0' run_enum.log
```

Also require five adapter reports with `request_q=0 completion_q=0 drops=0
unexpected_target_tx=0`, and a switch report with no outstanding ownership at
the sequence gate.

- [ ] **Step 10: Commit complete Task 9 integration**

This is the first commit that stages the preserved Task 9 WIP files. Review
the full staged diff so registry/sequence work is not lost or silently
rewritten:

```bash
git add svt_pcie_integration/uvm/pcie_svt_switch_sidecar_env.sv \
        svt_pcie_integration/uvm/pcie_svt_env.sv \
        svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv \
        svt_pcie_integration/uvm/pcie_svt_virtual_sequencer.sv \
        svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv \
        svt_pcie_integration/uvm/pcie_svt_switch_enum_registry.sv \
        svt_pcie_integration/uvm/sequences/pcie_svt_switch_enumeration_vseq.sv \
        svt_pcie_integration/sim/pcie_svt_switch_enum_registry_unit_test.sv
git diff --cached --check
git diff --cached --stat
git commit -m "feat: enumerate endpoints through observed switch routes"
```

### Task 4: Run the Required Regression Gate

**Files:**
- Test only: no source edit unless a failure is first diagnosed with `superpowers:systematic-debugging`
- Test: fresh Task 4, Task 6, Task 8, Task 9, and EP-x16 logs

- [ ] **Step 1: Rebuild and run the switch routing unit**

Use a new `build_switch_route_final.*`. Require one each of
`TYPE1_CFG_PASS`, `SWITCH_PACKAGE_SMOKE_PASS`, `SWITCH_ROUTE_PASS`,
`SWITCH_MULTI_ROOT_PASS`, and `SWITCH_ROUTE_OBSERVER_PASS`, plus
W/E/F=`0/0/0`. Run the three existing negative routing modes separately and
require their original fatal IDs.

- [ ] **Step 2: Rebuild and run strict plus deferred scoreboard units**

Use a new `build_switch_scoreboard_final.*`. Run the unchanged default strict
adapter test, all existing focused strict positives, all six deferred
positives, and all deferred negatives from Task 2. Positive logs require
W/E/F=`0/0/0`; negative logs require exactly the intended production fatal and
must not contain the missed-negative marker.

- [ ] **Step 3: Rebuild and run both five-link Task 8 cases**

Use a fresh switch proxy build. Run Gen4 link-only with sidecars disabled and
enabled. Gate exact counts: five link passes in both; five ready markers only
when sidecars are enabled; no STAR marker in either; W/E/F=`0/0/0`.

- [ ] **Step 4: Re-run Gen4 official enumeration**

Run one fresh `+PCIE_GEN=4 +PCIE_ENUM_ONLY`. Require the complete Task 3 Step 9
gate, including five exact STAR markers, one deferred empty marker, one
registry pass, zero drops/outstanding/residuals, and W/E/F=`0/0/0`.

- [ ] **Step 5: Rebuild and run the original EP-x16 peer smoke**

Compile without the switch-proxy macro:

```bash
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_EP_X16 +define+PCIE_USE_SVT_PEER \
  -f pcie_svt.f -top pcie_svt_topology_top \
  -Mdir=build_ep_x16_observer_regression/csrc \
  -P pli.tab msglog.o -o build_ep_x16_observer_regression/simv \
  -l build_ep_x16_observer_regression/compile.log
```

Run Gen4 with `+UVM_TESTNAME=pcie_svt_base_test +PCIE_GEN=4`. Require one
`LINK_PASS` containing `width=16 speed=16GT/s`, one
`SVT_PCIE_PEER_SMOKE_PASS`, no switch-sidecar/STAR markers, and
W/E/F=`0/0/0`.

- [ ] **Step 6: Run repository hygiene checks**

```bash
git diff --check
git status --short
git grep -n -E 'ghp_|github_pat_|10\.11\.10\.53.*123' -- . && exit 1 || true
git ls-files | grep -E '(^|/)(build[^/]*|simv|csrc|.*\.log|msglog\.o)(/|$)' && exit 1 || true
```

Require no Synopsys installation file, VCS build output, log, credential, or
token in the repository. The worktree must be clean after the three feature
commits and this plan/documentation commit.

## Final Acceptance Checklist

- [ ] One event is published before each supported switch egress FIFO put.
- [ ] Event TLPs are deep snapshots and preserve Configuration, Completion,
  Address Type, prefix, and payload fields.
- [ ] Strict scoreboard mode and all Task 6 tests remain unchanged by default.
- [ ] Deferred RX-first and event-first paths both pass.
- [ ] Cfg1-to-Cfg0, local read/write, and Completion routes are wire-proven.
- [ ] Drop, duplicate, ambiguity, wrong-port, and residual-state cases fail.
- [ ] Only enum mode applies STAR#9000762979, exactly once per sidecar.
- [ ] Link-only modes emit no STAR marker.
- [ ] Official enumeration reports one USP, four DSPs, four Endpoints, and
  twelve required 64-bit Prefetchable BAR apertures.
- [ ] Switch outstanding state, adapter queues/drop counts, and scoreboard
  pending/expectation state are empty at the enum gate.
- [ ] Task 4/6/8/9 and EP-x16 positive runs finish with W/E/F=`0/0/0`.
