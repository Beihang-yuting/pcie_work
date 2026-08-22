# SVT PCIe Direct Passive Sidecar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Replace the five passive Switch Proxy Device Agent wrappers with direct standalone svt_pcie_agent monitors and prove five-link enumeration with zero warnings, errors, or fatals.

**Architecture:** Keep all ten active full Device Agents and the existing switch, adapter, enumeration, BAR, and scoreboard paths unchanged. Each input-only Serial tap feeds a width-matched passive VIF configured directly on one svt_pcie_configuration; one direct svt_pcie_agent publishes RX/TX observations and accepts monitor configuration-space services with an explicit USP or DSP role.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys SVT PCIe R-2020.12, VCS W-2024.09-SP1, Serial x16/x4 interfaces, Git.

---

## Constraints and File Map

Work only in:

~~~text
/home/ryan/.config/superpowers/worktrees/pcie_work/svt-switch-proxy
~~~

Run all VCS compilation and simulation serially on 10.11.10.53 under:

~~~text
/home/ubuntu/pcie-task9-full.Oeu6b5/pcie_work/svt_pcie_integration/sim
~~~

Use interactive SSH and rsync password prompts. Never put credentials in a
command, URL, script, log, or repository file. Before every build, synchronize
local sources over the remote sources so the disproved nested-configuration
experiment is overwritten.

Task 9 has an explicit no-intermediate-commit rule. This plan creates one
commit only after all GREEN gates pass.

Files and responsibilities:

- Modify svt_pcie_integration/uvm/pcie_svt_switch_sidecar_env.sv: own and
  configure the direct passive agent.
- Modify svt_pcie_integration/uvm/pcie_svt_env.sv: connect and validate the
  direct monitor.
- Modify svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv: verify the
  effective USP/DSP role and STAR policy.
- Modify
  svt_pcie_integration/uvm/sequences/pcie_svt_all_cfg_spaces_init_vseq.sv:
  validate the passive contract before configuration-space services.
- Modify
  svt_pcie_integration/sim/pcie_svt_switch_enum_registry_unit_test.sv:
  provide RED/GREEN direct-role and invalid-port coverage.
- Preserve all other Task 9 WIP without unrelated cleanup.
- Keep Serial as the only implemented passive interface in this task. The
  direct configuration boundary remains width/interface-selectable so a
  future PIPE branch can assign the documented standalone passive PIPE VIF
  without restoring a Device Agent wrapper.

## Task 1: Write the Direct-Role RED Test

**Files:**

- Modify: svt_pcie_integration/sim/pcie_svt_switch_enum_registry_unit_test.sv
- Test: remote build_task9_direct_role_red.*

- [ ] **Step 1: Require the direct configuration type**

Replace the Device Agent role object with this declaration and test:

~~~systemverilog
svt_pcie_configuration sidecar_role_cfg;

sidecar_role_cfg = svt_pcie_configuration::type_id::create(
  "unit_sidecar_role_cfg");
if (sidecar_role_cfg == null)
  `uvm_fatal("SIDECAR_ROLE_POLICY",
    "direct sidecar role cfg creation failed")

for (int port_index = 0; port_index < 5; port_index++) begin
  pcie_svt_switch_sidecar_env::configure_monitor_role(
    sidecar_role_cfg, port_index);
  if ((sidecar_role_cfg.tl_cfg.is_switch !== 1'b1) ||
      (sidecar_role_cfg.tl_cfg.is_tx_downstream !== (port_index != 0)) ||
      (sidecar_role_cfg.tl_cfg.cfg_space_mode !=
        svt_pcie_tl_configuration::CFG_SPACE_ENUMERATION_UPDATE))
    `uvm_fatal("SIDECAR_ROLE_POLICY", $sformatf(
      "direct sidecar port=%0d role is incomplete", port_index))
end
$display("SIDECAR_DIRECT_ROLE_POLICY_PASS usp=1 dsp=4 pre_child=1");

if (case_name == "invalid_sidecar_port")
  pcie_svt_switch_sidecar_env::configure_monitor_role(
    sidecar_role_cfg, 5);
~~~

Keep expect_failure equal to case_name != "valid". The new invalid case must
die in configure_monitor_role before registry construction.

- [ ] **Step 2: Synchronize the RED test only**

~~~bash
rsync -a \
  svt_pcie_integration/sim/pcie_svt_switch_enum_registry_unit_test.sv \
  ubuntu@10.11.10.53:/home/ubuntu/pcie-task9-full.Oeu6b5/pcie_work/svt_pcie_integration/sim/
~~~

Expected: rsync succeeds through the interactive prompt and does not touch the
Synopsys installation.

- [ ] **Step 3: Compile RED on host 53**

~~~bash
ssh -t ubuntu@10.11.10.53
source ~/.bashrc
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT="$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12"
cd /home/ubuntu/pcie-task9-full.Oeu6b5/pcie_work/svt_pcie_integration/sim
set -euo pipefail
b=$(mktemp -d build_task9_direct_role_red.XXXXXX)
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_SWITCH_1X16_4X4 \
  +define+PCIE_USE_SVT_SWITCH_PROXY \
  -f pcie_svt.f pcie_svt_switch_enum_registry_unit_test.sv \
  -top pcie_svt_switch_enum_registry_unit_test \
  -Mdir="$b/csrc" -P pli.tab msglog.o \
  -o "$b/simv" -l "$b/compile.log"
~~~

Expected RED: VCS exits nonzero because production still accepts
svt_pcie_device_configuration while the test passes svt_pcie_configuration.
Record the first type-mismatch diagnostic. Do not weaken the test.

## Task 2: Implement the Direct Agent and Migrate Consumers

**Files:**

- Modify: svt_pcie_integration/uvm/pcie_svt_switch_sidecar_env.sv
- Modify: svt_pcie_integration/uvm/pcie_svt_env.sv
- Modify: svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv
- Modify: svt_pcie_integration/uvm/sequences/pcie_svt_all_cfg_spaces_init_vseq.sv
- Test: remote build_task9_direct_role_green.*

- [ ] **Step 1: Replace wrapper-owned types and the role helper**

Use:

~~~systemverilog
svt_pcie_configuration cfg;
svt_pcie_agent         agent;
~~~

Remove svt_pcie_device_status, its construction/check, and shared_status
publication. Replace configure_monitor_role with:

~~~systemverilog
static function void configure_monitor_role(
    svt_pcie_configuration role_cfg,
    int role_port_index);
  if (role_cfg == null) begin
    `uvm_fatal("SIDECAR_ROLE_POLICY", "direct role cfg is null")
    return;
  end
  if ((role_port_index < 0) || (role_port_index >= 5)) begin
    `uvm_fatal("SIDECAR_ROLE_POLICY", $sformatf(
      "invalid switch sidecar port=%0d (expected 0 through 4)",
      role_port_index))
    return;
  end
  role_cfg.tl_cfg.is_switch = 1'b1;
  role_cfg.tl_cfg.is_tx_downstream = (role_port_index != 0);
  role_cfg.tl_cfg.cfg_space_mode =
    svt_pcie_tl_configuration::CFG_SPACE_ENUMERATION_UPDATE;
endfunction
~~~

- [ ] **Step 2: Configure the standalone passive agent before creation**

Replace the Device Agent setup with:

~~~systemverilog
cfg = svt_pcie_configuration::type_id::create("cfg");
if (cfg == null)
  `uvm_fatal("SIDECAR_CREATE",
             {get_full_name(), ": direct configuration creation failed"})

cfg.pl_cfg.set_link_width_values(lanes, supported_widths, lanes);
if ((cfg.pl_cfg.get_link_width_value() != lanes) ||
    (cfg.pl_cfg.get_supported_link_width_vector_value() !=
       supported_widths) ||
    (cfg.pl_cfg.get_expected_link_width_value() != lanes))
  `uvm_fatal("SIDECAR_LINK_WIDTH", $sformatf(
    "%s: failed to configure x%0d supported=0x%0h",
    get_full_name(), lanes, supported_widths))

cfg.pl_cfg.set_link_speed_values(
  supported_speeds, selected_speed, selected_speed);
if ((cfg.pl_cfg.get_supported_link_speeds_value() != supported_speeds) ||
    (cfg.pl_cfg.get_target_link_speed_value() != selected_speed) ||
    (cfg.pl_cfg.get_expected_link_speed_value() != selected_speed))
  `uvm_fatal("SIDECAR_LINK_SPEED", $sformatf(
    "%s: failed to configure Gen%0d speed vector=0x%0h",
    get_full_name(), pcie_gen, supported_speeds))

cfg.enable_monitor = 1'b1;
configure_monitor_role(cfg, port_index);
if (lanes == 16)
  cfg.serdes_x16_if = serdes_x16_vif;
else
  cfg.serdes_x4_if = serdes_x4_vif;

uvm_config_db#(svt_pcie_configuration)::set(
  this, "agent", "cfg", cfg);
agent = svt_pcie_agent::type_id::create("agent", this);
~~~

Delete pcie_spec_ver, is_active, device_is_root, model_instance_scope, and all
cfg.pcie_cfg paths. Preserve speed calculation and VIF validation.

- [ ] **Step 3: Connect direct monitor ports and the exact STAR rule**

~~~systemverilog
if ((cfg == null) || (agent == null) || (agent.tl_mon == null))
  `uvm_fatal("SIDECAR_CONNECT",
             {get_full_name(), ": cfg/agent/tl_mon handle is missing"})

if (apply_star_9000762979) begin
  if (agent.err_check == null)
    `uvm_fatal("SWITCH_STAR_9000762979", $sformatf(
      "port=%0d sidecar err_check handle is missing", port_index))
  void'(agent.err_check.disable_checks(
    "PASSIVE_DL_TX", "FLOW_CTRL_INIT", "txn_06_01_16"));
  star_9000762979_applied = 1'b1;
  `uvm_info("SWITCH_STAR_9000762979_APPLIED", $sformatf(
    "port=%0d rule=PASSIVE_DL_TX/FLOW_CTRL_INIT/txn_06_01_16",
    port_index), UVM_NONE)
end

if ((agent.tl_mon.rx_tlp_observed_port == null) ||
    (agent.tl_mon.tx_tlp_observed_port == null) ||
    (rx_subscriber == null) || (rx_subscriber.analysis_export == null) ||
    (tx_subscriber == null) || (tx_subscriber.analysis_export == null))
  `uvm_fatal("SIDECAR_CONNECT",
             {get_full_name(), ": passive monitor port is missing"})

agent.tl_mon.rx_tlp_observed_port.connect(rx_subscriber.analysis_export);
agent.tl_mon.tx_tlp_observed_port.connect(tx_subscriber.analysis_export);
~~~

Do not add another disable_checks call.

- [ ] **Step 4: Migrate environment and readiness consumers**

In pcie_svt_env.sv, replace sidecar-only agent.pcie_agent.tl_mon references
with agent.tl_mon. Replace the is_active assertion with:

~~~systemverilog
if (!switch_sidecar[i].cfg.enable_monitor)
  `uvm_fatal("SWITCH_PASSIVE_MONITOR", $sformatf(
    "port=%0d standalone sidecar monitor is disabled", i))
~~~

Connect:

~~~systemverilog
switch_sidecar_service_port[i].connect(
  switch_sidecar[i].agent.tl_mon.tl_service_in_port);
~~~

At end of elaboration require one RX, one TX, and one service connection.

In pcie_svt_all_cfg_spaces_init_vseq.sv use:

~~~systemverilog
if ((sidecar == null) || (sidecar.cfg == null) ||
    (sidecar.agent == null) || (sidecar.agent.tl_mon == null) ||
    (p_sequencer.switch_sidecar_service_port[port_index] == null))
  `uvm_fatal("SIDECAR_READY", $sformatf(
    "port=%0d passive checker handle is incomplete", port_index))
if (!sidecar.cfg.enable_monitor)
  `uvm_fatal("SWITCH_PASSIVE_MONITOR", $sformatf(
    "port=%0d passive monitor is disabled", port_index))
~~~

Preserve all service operations and ready markers.

- [ ] **Step 5: Verify effective direct-agent roles**

In pcie_svt_switch_proxy_test.sv read:

~~~systemverilog
env.switch_sidecar[i].agent.tl_mon.get_cfg(tl_mon_cfg_base);
~~~

Use direct input paths and require:

~~~systemverilog
`uvm_info("SWITCH_SIDECAR_ROLE_DIAG", $sformatf(
  {"port=%0d input=%0b tl_monitor=%0b tx_downstream=%0b ",
   "cfg_space_mode=%0d"},
  i, env.switch_sidecar[i].cfg.tl_cfg.is_switch,
  effective_pcie_cfg.tl_cfg.is_switch,
  effective_pcie_cfg.tl_cfg.is_tx_downstream,
  effective_pcie_cfg.tl_cfg.cfg_space_mode), UVM_NONE)

if (!env.switch_sidecar[i].cfg.tl_cfg.is_switch ||
    !effective_pcie_cfg.tl_cfg.is_switch ||
    (effective_pcie_cfg.tl_cfg.is_tx_downstream !== (i != 0)))
  `uvm_fatal("SWITCH_SIDECAR_ROLE", $sformatf(
    "port=%0d effective direct-agent switch role is invalid", i))
if (effective_pcie_cfg.tl_cfg.cfg_space_mode !=
    svt_pcie_tl_configuration::CFG_SPACE_ENUMERATION_UPDATE)
  `uvm_fatal("SWITCH_SIDECAR_CFG_SPACE_MODE", $sformatf(
    "port=%0d effective cfg_space_mode=%0d expected enumeration-update",
    i, effective_pcie_cfg.tl_cfg.cfg_space_mode))
~~~

Keep the five-port STAR configured/applied equality check.

- [ ] **Step 6: Prove wrapper hierarchy is gone from production**

~~~bash
rg -n "agent\.pcie_agent|cfg\.pcie_cfg|svt_pcie_device_(agent|configuration|status)|cfg\.is_active" \
  svt_pcie_integration/uvm/pcie_svt_switch_sidecar_env.sv \
  svt_pcie_integration/sim/pcie_svt_switch_enum_registry_unit_test.sv
rg -n "switch_sidecar.*(agent\.pcie_agent|cfg\.pcie_cfg|cfg\.is_active)" \
  svt_pcie_integration/uvm/pcie_svt_env.sv \
  svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv
rg -n "sidecar\.(agent\.pcie_agent|cfg\.pcie_cfg|cfg\.is_active)" \
  svt_pcie_integration/uvm/sequences/pcie_svt_all_cfg_spaces_init_vseq.sv
~~~

Expected: all three searches produce no matches. Active Device Agent paths
elsewhere in pcie_svt_env.sv and pcie_svt_tl_proxy_probe.sv are intentional.

- [ ] **Step 7: Synchronize all sources**

Run before every subsequent build:

~~~bash
rsync -a --exclude 'build*' --exclude 'simv*' --exclude 'csrc' \
  --exclude '*.log' --exclude 'pli.tab' --exclude 'msglog.o' \
  --exclude 'svc_util_parms.h' \
  pcie_tl_vip/ \
  ubuntu@10.11.10.53:/home/ubuntu/pcie-task9-full.Oeu6b5/pcie_work/pcie_tl_vip/

rsync -a --exclude 'build*' --exclude 'simv*' --exclude 'csrc' \
  --exclude '*.log' --exclude 'pli.tab' --exclude 'msglog.o' \
  --exclude 'svc_util_parms.h' \
  svt_pcie_integration/ \
  ubuntu@10.11.10.53:/home/ubuntu/pcie-task9-full.Oeu6b5/pcie_work/svt_pcie_integration/
~~~

- [ ] **Step 8: Compile and run GREEN role tests**

On host 53, compile a fresh binary:

~~~bash
source ~/.bashrc
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT="$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12"
cd /home/ubuntu/pcie-task9-full.Oeu6b5/pcie_work/svt_pcie_integration/sim
set -euo pipefail
b=$(mktemp -d build_task9_direct_role_green.XXXXXX)
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_SWITCH_1X16_4X4 \
  +define+PCIE_USE_SVT_SWITCH_PROXY \
  -f pcie_svt.f pcie_svt_switch_enum_registry_unit_test.sv \
  -top pcie_svt_switch_enum_registry_unit_test \
  -Mdir="$b/csrc" -P pli.tab msglog.o \
  -o "$b/simv" -l "$b/compile.log"
~~~

Then run:

~~~bash
"$b/simv" -no_save +REGISTRY_CASE=valid +UVM_NO_RELNOTES \
  -l "$b/run_valid.log"
grep -a -q 'SIDECAR_DIRECT_ROLE_POLICY_PASS usp=1 dsp=4 pre_child=1' \
  "$b/run_valid.log"
grep -a -q 'REGISTRY_UNIT_PASS usp=1 dsp=4 ep=4 bars=12' \
  "$b/run_valid.log"
grep -a -q 'UVM_WARNING *: *0' "$b/run_valid.log"
grep -a -q 'UVM_ERROR *: *0' "$b/run_valid.log"
grep -a -q 'UVM_FATAL *: *0' "$b/run_valid.log"

set +e
"$b/simv" -no_save +REGISTRY_CASE=invalid_sidecar_port \
  +UVM_NO_RELNOTES -l "$b/run_invalid_sidecar_port.log"
rc=$?
set -e
test "$rc" -ne 0
grep -a -q 'SIDECAR_ROLE_POLICY.*invalid switch sidecar port=5' \
  "$b/run_invalid_sidecar_port.log"
! grep -a -q 'REGISTRY_RED' "$b/run_invalid_sidecar_port.log"
~~~

## Task 3: Run Focused Unit Regressions

**Files:**

- Test: svt_pcie_integration/sim/pcie_svt_ep_bar_sizing_callback_unit_test.sv
- Test: svt_pcie_integration/sim/pcie_svt_switch_enum_registry_unit_test.sv
- Test: svt_pcie_integration/sim/pcie_svt_switch_adapter_unit_test.sv

- [ ] **Step 1: Build and run the BAR callback unit**

~~~bash
source ~/.bashrc
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT="$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12"
cd /home/ubuntu/pcie-task9-full.Oeu6b5/pcie_work/svt_pcie_integration/sim
set -euo pipefail
b=$(mktemp -d build_task9_bar_callback_final.XXXXXX)
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_SWITCH_1X16_4X4 \
  +define+PCIE_USE_SVT_SWITCH_PROXY \
  -f pcie_svt.f pcie_svt_ep_bar_sizing_callback_unit_test.sv \
  -top pcie_svt_ep_bar_sizing_callback_unit_test \
  -Mdir="$b/csrc" -P pli.tab msglog.o \
  -o "$b/simv" -l "$b/compile.log"
"$b/simv" -no_save +UVM_NO_RELNOTES -l "$b/run.log"
grep -a -q 'EP_BAR_SIZING_CALLBACK_PASS bars=6 sizing_writes=7' "$b/run.log"
grep -a -q 'UVM_WARNING *: *0' "$b/run.log"
grep -a -q 'UVM_ERROR *: *0' "$b/run.log"
grep -a -q 'UVM_FATAL *: *0' "$b/run.log"
~~~

- [ ] **Step 2: Run all registry cases independently**

Build one fresh registry binary and run the valid case:

~~~bash
b=$(mktemp -d build_task9_registry_final.XXXXXX)
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_SWITCH_1X16_4X4 \
  +define+PCIE_USE_SVT_SWITCH_PROXY \
  -f pcie_svt.f pcie_svt_switch_enum_registry_unit_test.sv \
  -top pcie_svt_switch_enum_registry_unit_test \
  -Mdir="$b/csrc" -P pli.tab msglog.o \
  -o "$b/simv" -l "$b/compile.log"
"$b/simv" -no_save +REGISTRY_CASE=valid +UVM_NO_RELNOTES \
  -l "$b/run_valid.log"
grep -a -q 'SIDECAR_DIRECT_ROLE_POLICY_PASS usp=1 dsp=4 pre_child=1' \
  "$b/run_valid.log"
grep -a -q 'REGISTRY_UNIT_PASS usp=1 dsp=4 ep=4 bars=12' \
  "$b/run_valid.log"
grep -a -q 'UVM_WARNING *: *0' "$b/run_valid.log"
grep -a -q 'UVM_ERROR *: *0' "$b/run_valid.log"
grep -a -q 'UVM_FATAL *: *0' "$b/run_valid.log"
~~~

Run each negative separately:

~~~text
invalid_sidecar_port
null_status
duplicate_bdf
endpoint_without_parent
bar_32bit
bar_non_prefetchable
bar_overlap
bar_outside_window
~~~

For every listed case, set mode and run:

~~~bash
set +e
"$b/simv" -no_save +REGISTRY_CASE="$mode" +UVM_NO_RELNOTES \
  -l "$b/run_$mode.log"
rc=$?
set -e
test "$rc" -ne 0
grep -a -q 'UVM_FATAL' "$b/run_$mode.log"
! grep -a -q 'REGISTRY_RED' "$b/run_$mode.log"
~~~

Each log must contain the production fatal ID implemented for its named case.

- [ ] **Step 3: Build the adapter unit**

~~~bash
b=$(mktemp -d build_task9_adapter_final.XXXXXX)
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_SWITCH_1X16_4X4 \
  +define+PCIE_USE_SVT_SWITCH_PROXY \
  -f pcie_svt.f pcie_svt_switch_adapter_unit_test.sv \
  -top pcie_svt_switch_adapter_unit_top \
  -Mdir="$b/csrc" -P pli.tab msglog.o \
  -o "$b/simv" -l "$b/compile.log"
~~~

- [ ] **Step 4: Run all adapter positives and negatives**

Run default and require SWITCH_ADAPTER_PASS. Run
+SVT_ADAPTER_TEST_DYNAMIC_BUS_WINDOW and require
SWITCH_ADAPTER_DYNAMIC_BUS_WINDOW_PASS. Run these independent positives with
+ADAPTER_POSITIVE=mode:

~~~text
scoreboard_cross_route
setup_cfg
scoreboard_cfg_rewrite
scoreboard_local_cfg_read
scoreboard_local_cfg_write
scoreboard_cpl_nonwire
scoreboard_request_nonwire
deferred_rx_first
deferred_event_first
deferred_cfg_rewrite
deferred_local_cfg_read
deferred_local_cfg_write
deferred_completion
~~~

Run the default and dynamic cases with:

~~~bash
"$b/simv" -no_save +UVM_NO_RELNOTES -l "$b/run_default.log"
grep -a -q 'SWITCH_ADAPTER_PASS' "$b/run_default.log"
"$b/simv" -no_save +SVT_ADAPTER_TEST_DYNAMIC_BUS_WINDOW \
  +UVM_NO_RELNOTES -l "$b/run_dynamic.log"
grep -a -q 'SWITCH_ADAPTER_DYNAMIC_BUS_WINDOW_PASS' "$b/run_dynamic.log"
~~~

For every listed positive, set mode and run:

~~~bash
"$b/simv" -no_save +ADAPTER_POSITIVE="$mode" +UVM_NO_RELNOTES \
  -l "$b/run_positive_$mode.log"
grep -a -q 'PASS' "$b/run_positive_$mode.log"
grep -a -q 'UVM_WARNING *: *0' "$b/run_positive_$mode.log"
grep -a -q 'UVM_ERROR *: *0' "$b/run_positive_$mode.log"
grep -a -q 'UVM_FATAL *: *0' "$b/run_positive_$mode.log"
~~~

Require the mode's exact PASS marker, not an unrelated PASS line. Run each of
these negative modes as a separate process with +ADAPTER_NEGATIVE=mode:

~~~text
callback_completion
callback_unsupported
callback_null
callback_adapter_null
callback_illegal_tuple
callback_clone
target_tx
subscriber_null
subscriber_clone
sidecar_rx_message
sidecar_tx_illegal_tuple
capture_null
capture_clone
raw_null
scoreboard_wrong_egress
scoreboard_duplicate
scoreboard_unmatched_completion
scoreboard_payload_mismatch
scoreboard_fnv_collision
scoreboard_tc_mismatch
scoreboard_attr_mismatch
scoreboard_prefix_mismatch
scoreboard_at_mismatch
scoreboard_tph_mismatch
scoreboard_loop
scoreboard_missing
scoreboard_self_route_expect
scoreboard_direction_mismatch
scoreboard_cfg_rewrite_loop
scoreboard_port_expect
scoreboard_port_observe
deferred_duplicate_event
deferred_duplicate_rx
deferred_wrong_ingress
deferred_wrong_egress
deferred_drop
deferred_malformed_broadcast_egress
deferred_malformed_broadcast_route
deferred_broadcast
deferred_payload_mismatch
deferred_missing_route
deferred_missing_rx
deferred_missing_tx
deferred_tx_before_rx
deferred_reused_tx_before_rx
deferred_nested_begin
deferred_end_strict
~~~

Each must exit nonzero with its intended fatal and no
SWITCH_ADAPTER_NEGATIVE_MISSED. The callback_completion,
callback_unsupported, callback_null, callback_adapter_null, and
callback_illegal_tuple modes must emit CALLBACK_DROP_PASS.

For every listed negative, set mode and run:

~~~bash
set +e
"$b/simv" -no_save +ADAPTER_NEGATIVE="$mode" +UVM_NO_RELNOTES \
  -l "$b/run_negative_$mode.log"
rc=$?
set -e
test "$rc" -ne 0
grep -a -q 'UVM_FATAL' "$b/run_negative_$mode.log"
! grep -a -q 'SWITCH_ADAPTER_NEGATIVE_MISSED' \
  "$b/run_negative_$mode.log"
~~~

Invoke superpowers:systematic-debugging before changing production code for
any failure.

## Task 4: Prove Link Baseline and Direct-Sidecar Neutrality

**Files:**

- Test: complete switch-proxy image
- Test: remote build_task9_direct_link_final.*

- [ ] **Step 1: Compile a fresh full image**

~~~bash
source ~/.bashrc
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT="$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12"
cd /home/ubuntu/pcie-task9-full.Oeu6b5/pcie_work/svt_pcie_integration/sim
set -euo pipefail
b=$(mktemp -d build_task9_direct_link_final.XXXXXX)
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_SWITCH_1X16_4X4 \
  +define+PCIE_USE_SVT_SWITCH_PROXY \
  -f pcie_svt.f -top pcie_svt_topology_top \
  -Mdir="$b/csrc" -P pli.tab msglog.o \
  -o "$b/simv" -l "$b/compile.log"
~~~

- [ ] **Step 2: Run ten-active-agent baseline**

~~~bash
"$b/simv" -no_save +UVM_TESTNAME=pcie_svt_switch_proxy_test \
  +PCIE_GEN=4 +PCIE_LINK_ONLY +PCIE_DISABLE_SWITCH_SIDECARS \
  +UVM_NO_RELNOTES -l "$b/run_link_disabled.log"
test "$(grep -a -c 'UVM_INFO.*\[LINK_PASS\]' "$b/run_link_disabled.log")" -eq 5
grep -a -q 'SWITCH_SIDECARS_DISABLED_LINK_ONLY' "$b/run_link_disabled.log"
test "$(grep -a -c 'SWITCH_SIDECAR_READY port=' "$b/run_link_disabled.log")" -eq 0
test "$(grep -a -c 'SWITCH_STAR_9000762979_APPLIED.*port=' "$b/run_link_disabled.log")" -eq 0
grep -a -q 'UVM_WARNING *: *0' "$b/run_link_disabled.log"
grep -a -q 'UVM_ERROR *: *0' "$b/run_link_disabled.log"
grep -a -q 'UVM_FATAL *: *0' "$b/run_link_disabled.log"
~~~

- [ ] **Step 3: Run five direct passive sidecars**

~~~bash
"$b/simv" -no_save +UVM_TESTNAME=pcie_svt_switch_proxy_test \
  +PCIE_GEN=4 +PCIE_LINK_ONLY +UVM_NO_RELNOTES \
  -l "$b/run_link_direct_sidecars.log"
test "$(grep -a -c 'UVM_INFO.*\[LINK_PASS\]' "$b/run_link_direct_sidecars.log")" -eq 5
test "$(grep -a -c 'SWITCH_SIDECAR_READY port=' "$b/run_link_direct_sidecars.log")" -eq 5
test "$(grep -a -c 'SWITCH_SIDECAR_ROLE_DIAG.*tl_monitor=1' "$b/run_link_direct_sidecars.log")" -eq 5
test "$(grep -a -c 'SWITCH_STAR_9000762979_APPLIED.*port=' "$b/run_link_direct_sidecars.log")" -eq 0
grep -a -q 'UVM_WARNING *: *0' "$b/run_link_direct_sidecars.log"
grep -a -q 'UVM_ERROR *: *0' "$b/run_link_direct_sidecars.log"
grep -a -q 'UVM_FATAL *: *0' "$b/run_link_direct_sidecars.log"
~~~

Inspect diagnostics: port 0 tx_downstream=0; ports 1-4 tx_downstream=1; all
five use enumeration-update mode.

## Task 5: Run Fresh Official Enumeration

**Files:**

- Test: complete enum-only image
- Test: remote build_task9_direct_enum_final.*

- [ ] **Step 1: Re-synchronize and compile independently**

After the two source rsync commands in Task 2 Step 7, run on host 53:

~~~bash
source ~/.bashrc
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT="$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12"
cd /home/ubuntu/pcie-task9-full.Oeu6b5/pcie_work/svt_pcie_integration/sim
set -euo pipefail
b=$(mktemp -d build_task9_direct_enum_final.XXXXXX)
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_SWITCH_1X16_4X4 \
  +define+PCIE_USE_SVT_SWITCH_PROXY \
  -f pcie_svt.f -top pcie_svt_topology_top \
  -Mdir="$b/csrc" -P pli.tab msglog.o \
  -o "$b/simv" -l "$b/compile.log"
~~~

Expected: the build is independent of RED, unit, and link directories and
compile/elaboration exits zero.

- [ ] **Step 2: Run Gen4 enumeration to normal completion**

~~~bash
"$b/simv" -no_save +UVM_TESTNAME=pcie_svt_switch_proxy_test \
  +PCIE_GEN=4 +PCIE_ENUM_ONLY +UVM_NO_RELNOTES \
  -l "$b/run_enum.log"
~~~

- [ ] **Step 3: Gate topology, roles, STAR, and BAR discovery**

~~~bash
test "$(grep -a -c 'UVM_INFO.*\[LINK_PASS\]' "$b/run_enum.log")" -eq 5
test "$(grep -a -c 'SWITCH_SIDECAR_READY port=' "$b/run_enum.log")" -eq 5
test "$(grep -a -c 'SWITCH_SIDECAR_ROLE_DIAG.*tl_monitor=1' "$b/run_enum.log")" -eq 5
test "$(grep -a -c 'SWITCH_STAR_9000762979_APPLIED.*port=' "$b/run_enum.log")" -eq 5
test "$(grep -a -c 'SWITCH_ENUM_DISCOVERY.*DSP\[' "$b/run_enum.log")" -eq 4
grep -a -q 'SWITCH_ENUM_PASS usp=1 dsp=4 ep=4 bars=12' "$b/run_enum.log"
~~~

Inspect four discovery lines. Per Endpoint require BAR0/1=32 MiB,
BAR2/3=64 KiB, BAR4/5=64 KiB, all 64-bit Prefetchable, non-overlapping, and
inside the parent DSP window.

- [ ] **Step 4: Gate forwarding quiescence and final report**

~~~bash
test "$(grep -a -c 'SWITCH_DEFERRED_SCOREBOARD_EMPTY' "$b/run_enum.log")" -eq 1
test "$(grep -a -c 'SWITCH_ADAPTER_REPORT port=' "$b/run_enum.log")" -eq 5
test "$(grep -a -c 'SWITCH_ADAPTER_REPORT port=.*request_q=0 completion_q=0 drops=0 unexpected_target_tx=0' "$b/run_enum.log")" -eq 5
! grep -a -q 'SWITCH_ADAPTER_DROP\|SCOREBOARD_ROUTE_DROP' "$b/run_enum.log"
grep -a -q 'UVM_WARNING *: *0' "$b/run_enum.log"
grep -a -q 'UVM_ERROR *: *0' "$b/run_enum.log"
grep -a -q 'UVM_FATAL *: *0' "$b/run_enum.log"
! grep -a -q 'snps_cfg_05_04_01' "$b/run_enum.log"
~~~

Inspect the switch report and require zero outstanding, deferred, broadcast,
and drop state. The former 893 USP errors must be absent through correct role
construction, not new suppression.

## Task 6: Run EP-x16 Regression, Review, and Commit

**Files:**

- Test: original EP-x16 peer image
- Review and commit: complete Task 9

- [ ] **Step 1: Compile and run a fresh EP-x16 image**

~~~bash
source ~/.bashrc
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT="$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12"
cd /home/ubuntu/pcie-task9-full.Oeu6b5/pcie_work/svt_pcie_integration/sim
set -euo pipefail
b=$(mktemp -d build_task9_ep_x16_regression.XXXXXX)
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_EP_X16 +define+PCIE_USE_SVT_PEER \
  -f pcie_svt.f -top pcie_svt_topology_top \
  -Mdir="$b/csrc" -P pli.tab msglog.o \
  -o "$b/simv" -l "$b/compile.log"
"$b/simv" -no_save +UVM_TESTNAME=pcie_svt_base_test \
  +PCIE_GEN=4 +UVM_NO_RELNOTES -l "$b/run.log"
test "$(grep -a -c 'UVM_INFO.*\[LINK_PASS\].*width=16.*speed=16GT/s' "$b/run.log")" -eq 1
grep -a -q 'SVT_PCIE_PEER_SMOKE_PASS' "$b/run.log"
! grep -a -q 'SWITCH_SIDECAR\|SWITCH_STAR_9000762979' "$b/run.log"
grep -a -q 'UVM_WARNING *: *0' "$b/run.log"
grep -a -q 'UVM_ERROR *: *0' "$b/run.log"
grep -a -q 'UVM_FATAL *: *0' "$b/run.log"
~~~

- [ ] **Step 2: Run local quality and hygiene checks**

~~~bash
git diff --check
git status --short
! git grep -n -E 'g[h]p_[[:alnum:]]{20,}|github_p[a]t_[[:alnum:]_]{20,}' -- .
! git ls-files | grep -E '(^|/)(build[^/]*|simv|csrc|.*\.log|msglog\.o)(/|$)'
~~~

Expected: diff check passes; both grep commands have no matches; only
intentional Task 9 files are present.

- [ ] **Step 3: Review the complete diff**

~~~bash
git diff --stat
git diff -- \
  pcie_tl_vip/src/switch/pcie_tl_switch_port.sv \
  svt_pcie_integration \
  docs/superpowers/specs/2026-08-20-svt-pcie-direct-passive-sidecar-design.md \
  docs/superpowers/plans/2026-08-20-svt-pcie-direct-passive-sidecar.md
~~~

Require:

~~~text
10 active Device Agents unchanged
5 direct passive svt_pcie_agent sidecars
no vendor/private/force/deposit/report-catcher mechanism
only PASSIVE_DL_TX/FLOW_CTRL_INIT/txn_06_01_16 suppression
effective USP/DSP role assertions
five-link and exact 12-BAR acceptance
no unrelated refactor
~~~

- [ ] **Step 4: Stage and create the single Task 9 commit**

~~~bash
git add \
  pcie_tl_vip/src/switch/pcie_tl_switch_port.sv \
  svt_pcie_integration/sim/pcie_svt_ep_bar_sizing_callback_unit_test.sv \
  svt_pcie_integration/sim/pcie_svt_switch_adapter_unit_test.sv \
  svt_pcie_integration/sim/pcie_svt_switch_enum_registry_unit_test.sv \
  svt_pcie_integration/sim/pcie_tl_switch_proxy_unit_test.sv \
  svt_pcie_integration/uvm/pcie_svt_env.sv \
  svt_pcie_integration/uvm/pcie_svt_ep_bar_sizing_callback.sv \
  svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv \
  svt_pcie_integration/uvm/pcie_svt_port_env.sv \
  svt_pcie_integration/uvm/pcie_svt_switch_enum_registry.sv \
  svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv \
  svt_pcie_integration/uvm/pcie_svt_switch_sidecar_env.sv \
  svt_pcie_integration/uvm/pcie_svt_virtual_sequencer.sv \
  svt_pcie_integration/uvm/sequences/pcie_svt_all_cfg_spaces_init_vseq.sv \
  svt_pcie_integration/uvm/sequences/pcie_svt_cfg_space_init_seq.sv \
  svt_pcie_integration/uvm/sequences/pcie_svt_switch_enumeration_vseq.sv \
  docs/superpowers/specs/2026-08-20-svt-pcie-direct-passive-sidecar-design.md \
  docs/superpowers/plans/2026-08-20-svt-pcie-direct-passive-sidecar.md
git diff --cached --check
git diff --cached --stat
git diff --cached
git status --short
git commit -m "feat: complete SVT switch enumeration proxy"
~~~

If evidence changed after a run, rerun the affected gate before committing.

## Final Acceptance Checklist

- [ ] RED failed for the expected Device/direct type mismatch.
- [ ] Role unit reports one USP and four DSPs; port five fails.
- [ ] Five sidecars are direct svt_pcie_agent instances with one VIF each.
- [ ] Serial remains the implemented path and the direct config boundary does
  not block a later standalone passive PIPE VIF branch.
- [ ] Effective USP/DSP directions and enumeration-update mode are correct.
- [ ] Each sidecar has one RX, one TX, and one TL service connection.
- [ ] Both link-only modes report five links and W/E/F=0/0/0.
- [ ] Enumeration applies exactly five instances of the approved STAR rule.
- [ ] Enumeration reports one USP, four DSPs, four EPs, and twelve correct BARs.
- [ ] Switch, adapter, and deferred-scoreboard state is empty with zero drops.
- [ ] Fresh enum-only and EP-x16 runs finish with W/E/F=0/0/0.
- [ ] No credential, vendor source, build artifact, or unrelated edit is staged.
- [ ] One Task 9 commit is created only after every gate is GREEN.
