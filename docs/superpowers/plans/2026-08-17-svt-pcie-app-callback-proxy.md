# SVT PCIe Application-Callback Proxy Probe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove that documented R-2020.12 Target App callbacks, TL monitor analysis ports, and the raw TLP sequencer can implement an exactly-once two-link full-Serial PCIe proxy without a duplicate Target App response.

**Architecture:** Capture and drop MWr/CfgRd0 requests in `svt_pcie_target_app_callback::post_rx_tlp_get`, capture CPL/CPLD through `svt_pcie_agent::tl_mon.rx_tlp_observed_port`, and reinject clones through the opposite Proxy's public `tlp_seqr`. A Target App `pre_tx_tlp_put` safety wall drops and counts any locally generated Proxy response; a nonzero count fails the probe.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys SVT PCIe R-2020.12, VCS W-2024.09-SP1, two real Serial x4 Gen4 links.

---

## Execution Contract

- Work only in `/home/ryan/.config/superpowers/worktrees/pcie_work/svt-switch-proxy` on branch `feature/svt-switch-proxy`.
- Run every compile and simulation on `ubuntu@10.11.10.53` using a Bash login shell.
- Stage only the two probe files under `/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work`.
- Keep `/home/ubuntu/synopsys/designware_vip_R-2020.12` read-only.
- Read only the installed public HTML declarations for SVT signatures; do not inspect vendor private implementation source.
- Do not use private fields, `force`, `deposit`, a modified Synopsys file, or a caught/downgraded unexpected-Completion report.
- Keep `+define+SVT_PCIE_ENABLE_10_BIT_TAGS`, the 205 ns reset sequence, TC0, and the directed 10-bit Tag.
- Stop before the parent plan's Task 2 unless this probe is GREEN and passes independent specification and code-quality reviews.

The focused design is
`docs/superpowers/specs/2026-08-17-svt-pcie-app-callback-proxy-design.md`.
It supersedes only Task 1 of
`docs/superpowers/plans/2026-08-15-svt-pcie-switch-proxy.md`.

## File Structure

- Modify `svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv`: replace the failed TL callback boundary and TL callback observers with Target App callbacks and TL monitor subscribers; retain the existing HDL topology, reset, link bring-up, raw sequence, and directed traffic.
- Verify `svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.f`: retain the R-2020.12 include/library paths and `SVT_PCIE_ENABLE_10_BIT_TAGS` define.
- Delete `svt_pcie_integration/sim/pcie_svt_mapper_probe.sv` and `svt_pcie_integration/sim/pcie_svt_mapper_probe.f` only after the replacement probe passes a fresh clean build and run.

### Task 1: Replace the Failed TL Receive Boundary

**Files:**
- Modify: `svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv:15-249`
- Verify: `svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.f`
- Reference only: R-2020.12 `class_svt_pcie_target_app_callback.html`, `class_svt_pcie_target_app.html`, `class_svt_pcie_device_agent.html`, `class_svt_pcie_tl_monitor.html`, and `class_svt_pcie_agent.html`
- Test: remote `svt_pcie_integration/sim/build_tl_proxy_app_cb_api/compile.log`

- [ ] **Step 1: Preserve the reproducible RED evidence**

Run this read-only check on the VCS host:

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim
  test \"\$(grep -a -c TL_PROXY_API_PROBE_PASS build_tl_proxy_probe_cfg_clean/run_cbpool.log)\" -eq 0
  test \"\$(grep -a -c TL_PROXY_API_PROBE_BLOCKED build_tl_proxy_probe_cfg_clean/run_cbpool.log)\" -eq 1
  grep -a -q \"ingress_capture=0 ingress_forward=0 reverse_capture=0 reverse_forward=0\" \
    build_tl_proxy_probe_cfg_clean/run_cbpool.log
"'
```

Expected: exit zero, proving the old enabled TL callback did not capture the real ingress request.

- [ ] **Step 2: Replace `tl_proxy_capture_callback` with the Target App callback**

Replace the old `svt_pcie_tl_callback` receive class with this exact public callback implementation:

```systemverilog
class tl_proxy_target_callback extends svt_pcie_target_app_callback;
  tl_proxy_bridge bridge;
  bit ingress_side;
  int unsigned request_capture_count;
  int unsigned target_tx_count;

  `uvm_object_utils(tl_proxy_target_callback)

  function new(string name = "tl_proxy_target_callback");
    super.new(name);
  endfunction

  function void blocked_fatal(string message, string fatal_message);
    `uvm_info("TL_PROXY_API_PROBE_BLOCKED", message, UVM_NONE)
    `uvm_fatal("TL_PROXY_PROBE", fatal_message)
  endfunction

  virtual function void post_rx_tlp_get(
      svt_pcie_target_app target_app,
      svt_pcie_tlp transaction,
      ref bit drop);
    svt_pcie_tlp captured;
    bit supported_request;
    if (transaction == null)
      blocked_fatal("Proxy Target App received a null request",
        "null Proxy request");
    supported_request =
      (((transaction.tlp_type == svt_pcie_tlp::MEM_REQ) &&
        transaction.has_data()) ||
       ((transaction.tlp_type == svt_pcie_tlp::TYPE_0_CFG_REQ) &&
        !transaction.has_data()));
    if (!supported_request)
      blocked_fatal("Proxy Target App received an unsupported request",
        "unsupported Proxy request class");
    if ((bridge == null) || !$cast(captured, transaction.clone()))
      blocked_fatal("Proxy Target request clone failed",
        "Target callback clone failed");
    bridge.capture(captured, ingress_side);
    request_capture_count++;
    drop = 1'b1;
    `uvm_info("TL_PROXY_TARGET_RX_TRACE", $sformatf(
      "side=%s type=%0d capture=%0d drop=%0b",
      ingress_side ? "ingress" : "reverse", transaction.tlp_type,
      request_capture_count, drop), UVM_NONE)
  endfunction

  virtual function void pre_tx_tlp_put(
      svt_pcie_target_app target_app,
      svt_pcie_tlp transaction,
      ref bit drop);
    target_tx_count++;
    drop = 1'b1;
    `uvm_info("TL_PROXY_TARGET_TX_SUPPRESSED", $sformatf(
      "side=%s target_tx_count=%0d type=%0d",
      ingress_side ? "ingress" : "reverse", target_tx_count,
      (transaction == null) ? -1 : transaction.tlp_type), UVM_NONE)
  endfunction
endclass
```

Do not start a sequence or wait inside either callback.

- [ ] **Step 3: Replace TL observation callbacks with a monitor subscriber**

Delete `tl_proxy_observation_callback` and add this subscriber after
`tl_proxy_bridge`. It clones only Proxy Completions; source and sink checks use
the object only during `write()`.

```systemverilog
class tl_proxy_monitor_subscriber extends uvm_subscriber #(svt_pcie_tlp);
  typedef enum int unsigned {
    PROXY_COMPLETION_ROLE,
    SOURCE_OBSERVER_ROLE,
    SINK_OBSERVER_ROLE
  } observation_role_e;

  observation_role_e role;
  tl_proxy_bridge bridge;
  bit proxy_ingress_side;
  int unsigned proxy_completion_count;
  int unsigned sink_write_count;
  int unsigned sink_cfg_read_count;
  int unsigned source_completion_count;

  `uvm_component_utils(tl_proxy_monitor_subscriber)

  function new(string name = "tl_proxy_monitor_subscriber",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void blocked_fatal(string message, string fatal_message);
    `uvm_info("TL_PROXY_API_PROBE_BLOCKED", message, UVM_NONE)
    `uvm_fatal("TL_PROXY_PROBE", fatal_message)
  endfunction

  virtual function void write(svt_pcie_tlp tlp);
    svt_pcie_tlp captured;
    bit valid;
    if (tlp == null)
      blocked_fatal("TL monitor subscriber received a null TLP",
        "monitor observation TLP is null");

    if (role == PROXY_COMPLETION_ROLE) begin
      if (tlp.tlp_type != svt_pcie_tlp::CPL)
        return;
      if ((bridge == null) || !$cast(captured, tlp.clone()))
        blocked_fatal("Proxy Completion clone failed",
          "monitor Completion clone failed");
      bridge.capture(captured, proxy_ingress_side);
      proxy_completion_count++;
      `uvm_info("TL_PROXY_MONITOR_CPL_TRACE", $sformatf(
        "side=%s completion_capture=%0d has_data=%0b",
        proxy_ingress_side ? "ingress" : "reverse",
        proxy_completion_count, tlp.has_data()), UVM_NONE)
      return;
    end

    if (role == SOURCE_OBSERVER_ROLE) begin
      if (tlp.tlp_type != svt_pcie_tlp::CPL)
        return;
      valid = tlp.has_data() &&
              (tlp.completion_status == svt_pcie_tlp::SUCCESSFUL) &&
              (tlp.payload.size() == 1);
      if (!valid)
        blocked_fatal($sformatf(
          "source Completion changed: has_data=%0b status=%0d payload_size=%0d",
          tlp.has_data(), tlp.completion_status, tlp.payload.size()),
          "Configuration Completion fields changed");
      source_completion_count++;
      return;
    end

    if ((tlp.tlp_type == svt_pcie_tlp::MEM_REQ) && tlp.has_data()) begin
      valid = (tlp.address == 64'h0000_0000_8000_1040) &&
              (tlp.first_dw_be == 4'hf) &&
              (tlp.requester_id == 16'h0000) &&
              (tlp.tag == 10'h12a) &&
              (tlp.length == 10'd1) &&
              (tlp.payload.size() == 1) &&
              (tlp.payload[0] == 32'h4433_2211);
      if (!valid)
        blocked_fatal($sformatf(
          {"sink MWr changed: address=0x%016h be=0x%0h requester=0x%04h ",
           "tag=0x%0h length=%0d payload_size=%0d"},
          tlp.address, tlp.first_dw_be, tlp.requester_id, tlp.tag,
          tlp.length, tlp.payload.size()), "Memory Write fields changed");
      sink_write_count++;
      return;
    end

    if ((tlp.tlp_type == svt_pcie_tlp::TYPE_0_CFG_REQ) &&
        !tlp.has_data()) begin
      valid = (tlp.register_number == 10'h000) &&
              (tlp.first_dw_be == 4'hf) &&
              (tlp.requester_id == 16'h0000);
      if (!valid)
        blocked_fatal($sformatf(
          "sink CfgRd0 changed: register=0x%0h be=0x%0h requester=0x%04h",
          tlp.register_number, tlp.first_dw_be, tlp.requester_id),
          "Configuration Read fields changed");
      sink_cfg_read_count++;
    end
  endfunction
endclass
```

- [ ] **Step 4: Instantiate and connect the new public surfaces**

Replace the old callback/observer fields in
`pcie_svt_tl_proxy_probe_test` with:

```systemverilog
tl_proxy_target_callback ingress_target_callback;
tl_proxy_target_callback egress_target_callback;
tl_proxy_monitor_subscriber ingress_proxy_monitor;
tl_proxy_monitor_subscriber egress_proxy_monitor;
tl_proxy_monitor_subscriber source_observer;
tl_proxy_monitor_subscriber sink_observer;
```

Create and configure them in `build_phase`:

```systemverilog
ingress_target_callback = tl_proxy_target_callback::type_id::create(
  "ingress_target_callback");
egress_target_callback = tl_proxy_target_callback::type_id::create(
  "egress_target_callback");
ingress_proxy_monitor = tl_proxy_monitor_subscriber::type_id::create(
  "ingress_proxy_monitor", this);
egress_proxy_monitor = tl_proxy_monitor_subscriber::type_id::create(
  "egress_proxy_monitor", this);
source_observer = tl_proxy_monitor_subscriber::type_id::create(
  "source_observer", this);
sink_observer = tl_proxy_monitor_subscriber::type_id::create(
  "sink_observer", this);

if ((bridge == null) || (ingress_target_callback == null) ||
    (egress_target_callback == null) || (ingress_proxy_monitor == null) ||
    (egress_proxy_monitor == null) || (source_observer == null) ||
    (sink_observer == null))
  blocked_fatal("one or more application-callback probe objects are missing",
    "probe object creation failed");

ingress_target_callback.bridge = bridge;
ingress_target_callback.ingress_side = 1'b1;
egress_target_callback.bridge = bridge;
egress_target_callback.ingress_side = 1'b0;

ingress_proxy_monitor.role =
  tl_proxy_monitor_subscriber::PROXY_COMPLETION_ROLE;
ingress_proxy_monitor.bridge = bridge;
ingress_proxy_monitor.proxy_ingress_side = 1'b1;
egress_proxy_monitor.role =
  tl_proxy_monitor_subscriber::PROXY_COMPLETION_ROLE;
egress_proxy_monitor.bridge = bridge;
egress_proxy_monitor.proxy_ingress_side = 1'b0;
source_observer.role = tl_proxy_monitor_subscriber::SOURCE_OBSERVER_ROLE;
sink_observer.role = tl_proxy_monitor_subscriber::SINK_OBSERVER_ROLE;
```

In `connect_phase`, require both Proxy Target App handles and all four TL
monitor handles, then connect the analysis ports:

```systemverilog
if (!ingress_proxy.target.exists(0) ||
    (ingress_proxy.target[0] == null) ||
    !egress_proxy.target.exists(0) ||
    (egress_proxy.target[0] == null) ||
    (ingress_proxy.pcie_agent.tl_mon == null) ||
    (egress_proxy.pcie_agent.tl_mon == null) ||
    (source_rc.pcie_agent.tl_mon == null) ||
    (sink_ep.pcie_agent.tl_mon == null))
  blocked_fatal("a public Target App or TL monitor handle is unavailable",
    "application-callback public handle check failed");

ingress_proxy.pcie_agent.tl_mon.rx_tlp_observed_port.connect(
  ingress_proxy_monitor.analysis_export);
egress_proxy.pcie_agent.tl_mon.rx_tlp_observed_port.connect(
  egress_proxy_monitor.analysis_export);
source_rc.pcie_agent.tl_mon.rx_tlp_observed_port.connect(
  source_observer.analysis_export);
sink_ep.pcie_agent.tl_mon.rx_tlp_observed_port.connect(
  sink_observer.analysis_export);
```

In `end_of_elaboration_phase`, remove every
`uvm_callbacks#(svt_pcie_tl, svt_pcie_tl_callback)::add` call and register only
the two Proxy Target callbacks:

```systemverilog
uvm_callbacks#(
  svt_pcie_target_app,
  svt_pcie_target_app_callback
)::add(ingress_proxy.target[0], ingress_target_callback);
uvm_callbacks#(
  svt_pcie_target_app,
  svt_pcie_target_app_callback
)::add(egress_proxy.target[0], egress_target_callback);
uvm_callbacks#(
  svt_pcie_target_app,
  svt_pcie_target_app_callback
)::display(ingress_proxy.target[0]);
uvm_callbacks#(
  svt_pcie_target_app,
  svt_pcie_target_app_callback
)::display(egress_proxy.target[0]);
```

- [ ] **Step 5: Verify the file-list contract**

Run locally:

```bash
grep -Fx '+define+SVT_PCIE_ENABLE_10_BIT_TAGS' \
  svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.f
grep -Fx 'pcie_svt_tl_proxy_probe.sv' \
  svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.f
! grep -n 'svt_pcie_tl_callback' \
  svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv
```

Expected: the two exact file-list lines are printed and no old TL callback
reference is found.

- [ ] **Step 6: Sync and compile the public API surface**

Run from the worktree root:

```bash
rsync -a --relative \
  svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.f \
  svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv \
  ubuntu@10.11.10.53:/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/

ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12
  mkdir -p build_tl_proxy_app_cb_api
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    -f pcie_svt_tl_proxy_probe.f -top pcie_svt_tl_proxy_probe_top \
    -Mdir=build_tl_proxy_app_cb_api/csrc -P pli.tab msglog.o \
    -o build_tl_proxy_app_cb_api/simv \
    -l build_tl_proxy_app_cb_api/compile.log
"'
```

Expected: VCS exits zero. If the shipped public signature differs, change only
the declaration or connection to match the installed HTML and record the
exact documented difference. Do not read vendor implementation source.

### Task 2: Add the Revised Exactly-Once Runtime Gates

**Files:**
- Modify: `svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv:250-655`
- Test: remote `svt_pcie_integration/sim/build_tl_proxy_app_cb_api/run.log`

- [ ] **Step 1: Make both directed requests explicitly non-poisoned**

Add this constraint to both the existing Memory Write and Config Read
`randomize() with` blocks:

```systemverilog
ep == 1'b0;
```

Keep the MWr `traffic_class == 3'b000` constraint. This removes the already
identified random poisoned-request warning without changing the callback
experiment.

- [ ] **Step 2: Replace the old inferred response count with direct Target counters**

Delete `proxy_target_response_count`. Extend the timeout diagnostic to print
the two Target callback counters and both Proxy monitor Completion counters:

```systemverilog
`uvm_info("TL_PROXY_TIMEOUT_COUNT_TRACE", $sformatf(
  {"purpose=%s ingress_capture=%0d ingress_forward=%0d ",
   "reverse_capture=%0d reverse_forward=%0d sink_write=%0d sink_cfg=%0d ",
   "source_cpl=%0d ingress_target_tx=%0d egress_target_tx=%0d ",
   "ingress_mon_cpl=%0d egress_mon_cpl=%0d"},
  purpose, bridge.ingress_capture_count, bridge.ingress_forward_count,
  bridge.reverse_capture_count, bridge.reverse_forward_count,
  sink_observer.sink_write_count, sink_observer.sink_cfg_read_count,
  source_observer.source_completion_count,
  ingress_target_callback.target_tx_count,
  egress_target_callback.target_tx_count,
  ingress_proxy_monitor.proxy_completion_count,
  egress_proxy_monitor.proxy_completion_count), UVM_NONE)
```

- [ ] **Step 3: Add a Memory Write stage gate before Config Read**

Immediately after the existing Memory Write wait, add:

```systemverilog
if ((ingress_target_callback.request_capture_count != 1) ||
    (bridge.ingress_capture_count != 1) ||
    (bridge.ingress_forward_count != 1) ||
    (sink_observer.sink_write_count != 1) ||
    (ingress_target_callback.target_tx_count != 0) ||
    (egress_target_callback.target_tx_count != 0))
  blocked_fatal($sformatf(
    {"MWr stage failed: target_capture=%0d bridge_capture=%0d ",
     "bridge_forward=%0d sink_write=%0d ingress_target_tx=%0d ",
     "egress_target_tx=%0d"},
    ingress_target_callback.request_capture_count,
    bridge.ingress_capture_count, bridge.ingress_forward_count,
    sink_observer.sink_write_count,
    ingress_target_callback.target_tx_count,
    egress_target_callback.target_tx_count),
    "application-callback Memory Write gate failed");
`uvm_info("TL_PROXY_MWR_STAGE_PASS",
  "Target callback drop and raw request reinjection passed", UVM_NONE)
```

Expected runtime count at this stage: one ingress request capture, one
request reinjection, one sink MWr, and zero Proxy Target transmissions.

- [ ] **Step 4: Replace the final gate and pass marker**

After the Type-0 Configuration Read Completion wait and the existing 1 us
duplicate window, replace the old inferred gate with:

```systemverilog
if ((sink_observer.sink_write_count != 1) ||
    (sink_observer.sink_cfg_read_count != 1) ||
    (source_observer.source_completion_count != 1) ||
    (ingress_target_callback.request_capture_count != 2) ||
    (egress_target_callback.request_capture_count != 0) ||
    (ingress_target_callback.target_tx_count != 0) ||
    (egress_target_callback.target_tx_count != 0) ||
    (ingress_proxy_monitor.proxy_completion_count != 0) ||
    (egress_proxy_monitor.proxy_completion_count != 1) ||
    (bridge.ingress_capture_count != 2) ||
    (bridge.reverse_capture_count != 1) ||
    (bridge.ingress_forward_count != 2) ||
    (bridge.reverse_forward_count != 1))
  blocked_fatal($sformatf(
    {"exact gate failed: sink_write=%0d sink_cfg=%0d source_cpl=%0d ",
     "ingress_req=%0d egress_req=%0d ingress_target_tx=%0d ",
     "egress_target_tx=%0d ingress_mon_cpl=%0d egress_mon_cpl=%0d ",
     "ingress_capture=%0d reverse_capture=%0d ingress_forward=%0d ",
     "reverse_forward=%0d"},
    sink_observer.sink_write_count, sink_observer.sink_cfg_read_count,
    source_observer.source_completion_count,
    ingress_target_callback.request_capture_count,
    egress_target_callback.request_capture_count,
    ingress_target_callback.target_tx_count,
    egress_target_callback.target_tx_count,
    ingress_proxy_monitor.proxy_completion_count,
    egress_proxy_monitor.proxy_completion_count,
    bridge.ingress_capture_count, bridge.reverse_capture_count,
    bridge.ingress_forward_count, bridge.reverse_forward_count),
    "application-callback exactly-once gate failed");

`uvm_info("TL_PROXY_APP_CALLBACK_PROBE_PASS", $sformatf(
  {"two x4 Gen4 Serial links; request_forward=%0d completion_forward=%0d; ",
   "sink_write=%0d sink_cfg=%0d source_completion=%0d target_tx=%0d/%0d"},
  bridge.ingress_forward_count, bridge.reverse_forward_count,
  sink_observer.sink_write_count, sink_observer.sink_cfg_read_count,
  source_observer.source_completion_count,
  ingress_target_callback.target_tx_count,
  egress_target_callback.target_tx_count), UVM_NONE)
```

- [ ] **Step 5: Run the first application-callback experiment**

Sync the updated source, rebuild the same API experiment directory, and run
on the VCS host:

```bash
rsync -a --relative \
  svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv \
  ubuntu@10.11.10.53:/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/

ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    -f pcie_svt_tl_proxy_probe.f -top pcie_svt_tl_proxy_probe_top \
    -Mdir=build_tl_proxy_app_cb_api/csrc -P pli.tab msglog.o \
    -o build_tl_proxy_app_cb_api/simv \
    -l build_tl_proxy_app_cb_api/compile_runtime_gates.log
  ./build_tl_proxy_app_cb_api/simv -no_save +PCIE_GEN=4 +UVM_NO_RELNOTES \
    -l build_tl_proxy_app_cb_api/run.log
"'
```

Inspect without changing code:

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim
  grep -aE \"TL_PROXY_(TARGET_RX|TARGET_TX|MONITOR_CPL|MWR_STAGE|APP_CALLBACK_PROBE|API_PROBE_BLOCKED)|Unexpected Completion|spurious Completion|UVM_(WARNING|ERROR|FATAL) :\" \
    build_tl_proxy_app_cb_api/run.log
"'
```

Expected GREEN:

```text
TL_PROXY_MWR_STAGE_PASS                 exactly 1
TL_PROXY_APP_CALLBACK_PROBE_PASS        exactly 1
TL_PROXY_API_PROBE_BLOCKED              0
TL_PROXY_TARGET_TX_SUPPRESSED           0
Unexpected Completion                  0
spurious Completion                    0
UVM_WARNING / UVM_ERROR / UVM_FATAL    0 / 0 / 0
```

If Target callback capture remains zero, a Proxy Target transmission occurs,
or a raw request produces an unexpected/spurious Completion report, stop this
plan and report that exact public-API limitation. Do not add a report catcher
or switch to private bookkeeping.

### Task 3: Run One Fresh Clean Proof and Commit the Probe

**Files:**
- Modify: `svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv`
- Verify: `svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.f`
- Delete: `svt_pcie_integration/sim/pcie_svt_mapper_probe.sv`
- Delete: `svt_pcie_integration/sim/pcie_svt_mapper_probe.f`
- Test: remote `svt_pcie_integration/sim/build_tl_proxy_app_cb_clean/run.log`

- [ ] **Step 1: Sync the final two probe files**

Run from the worktree root:

```bash
rsync -a --relative \
  svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.f \
  svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv \
  ubuntu@10.11.10.53:/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/
```

- [ ] **Step 2: Perform a literal-path clean build**

Run on the VCS host:

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12
  rm -rf -- build_tl_proxy_app_cb_clean
  mkdir -p build_tl_proxy_app_cb_clean
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    -f pcie_svt_tl_proxy_probe.f -top pcie_svt_tl_proxy_probe_top \
    -Mdir=build_tl_proxy_app_cb_clean/csrc -P pli.tab msglog.o \
    -o build_tl_proxy_app_cb_clean/simv \
    -l build_tl_proxy_app_cb_clean/compile.log
  ./build_tl_proxy_app_cb_clean/simv -no_save +PCIE_GEN=4 +UVM_NO_RELNOTES \
    -l build_tl_proxy_app_cb_clean/run.log
"'
```

Expected: compile and simulation both exit zero.

- [ ] **Step 3: Apply the complete fresh-run gate**

Run on the VCS host:

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim
  test \"\$(grep -a -c TL_PROXY_MWR_STAGE_PASS build_tl_proxy_app_cb_clean/run.log)\" -eq 1
  test \"\$(grep -a -c TL_PROXY_APP_CALLBACK_PROBE_PASS build_tl_proxy_app_cb_clean/run.log)\" -eq 1
  ! grep -a -q TL_PROXY_API_PROBE_BLOCKED build_tl_proxy_app_cb_clean/run.log
  ! grep -aiq \"unexpected completion\" build_tl_proxy_app_cb_clean/run.log
  ! grep -aiq \"spurious completion\" build_tl_proxy_app_cb_clean/run.log
  ! grep -a -q TL_PROXY_TARGET_TX_SUPPRESSED build_tl_proxy_app_cb_clean/run.log
  grep -a -q \"UVM_WARNING :    0\" build_tl_proxy_app_cb_clean/run.log
  grep -a -q \"UVM_ERROR :    0\" build_tl_proxy_app_cb_clean/run.log
  grep -a -q \"UVM_FATAL :    0\" build_tl_proxy_app_cb_clean/run.log
"'
```

Expected: exit zero. This command, not a reused-Mdir run, is the Task 1 GREEN
evidence.

- [ ] **Step 4: Remove the rejected Mapper probe with `apply_patch`**

Delete only these two untracked files using `apply_patch`:

```text
svt_pcie_integration/sim/pcie_svt_mapper_probe.f
svt_pcie_integration/sim/pcie_svt_mapper_probe.sv
```

Then verify locally:

```bash
test ! -e svt_pcie_integration/sim/pcie_svt_mapper_probe.f
test ! -e svt_pcie_integration/sim/pcie_svt_mapper_probe.sv
git diff --check
git status --short
```

Expected status before commit:

```text
?? svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.f
?? svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv
```

- [ ] **Step 5: Commit only the proven probe**

Run locally:

```bash
git add svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.f \
        svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv
git diff --cached --check
git commit -m "test: prove public SVT PCIe app-callback proxy API"
```

Expected: one commit containing exactly the two probe files.

- [ ] **Step 6: Stop for two independent reviews**

The controller must perform these reviews in order:

1. specification compliance against
   `docs/superpowers/specs/2026-08-17-svt-pcie-app-callback-proxy-design.md`;
2. code quality after the specification review is approved.

Any review issue returns to the same implementer, is fixed, is revalidated with
a fresh clean VCS run, and is re-reviewed. Do not enter the parent plan's Task
2 until both reviews approve the Task 1 commit.

After both reviews pass, revise the parent switch-proxy design and plan to use
the proven Target callback plus TL monitor boundary before implementing the
five-port production adapter. That documentation revision is intentionally
outside this feasibility-probe plan.
