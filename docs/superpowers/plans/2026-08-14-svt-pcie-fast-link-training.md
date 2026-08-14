# SVT PCIe Fast Link Training Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add optional `+PCIE_FAST_LINK_TRAIN=0/1` control that uses public R-2020.12 APIs to train from Gen1 directly to the selected Gen4 or Gen5 rate.

**Architecture:** `pcie_svt_env` validates one run-wide plusarg and distributes a bit to every active port. Each `pcie_svt_port_env` applies the generation-specific equalization policy before creating its SVT agent. Existing peer smoke tests verify final state and inspect clock/link logs to prove intermediate rates were bypassed.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys SVT PCIe R-2020.12, VCS W-2024.09-SP1 on `10.11.10.53`.

---

## File Structure

- Modify `svt_pcie_integration/uvm/pcie_svt_env.sv`: validate and distribute the plusarg.
- Modify `svt_pcie_integration/uvm/pcie_svt_port_env.sv`: apply the public Gen4/Gen5 policy before agent creation.
- Modify `svt_pcie_integration/sim/README.md`: document behavior, limitations, and commands.

### Task 1: Validate and Distribute the Runtime Argument

**Files:**
- Modify: `svt_pcie_integration/uvm/pcie_svt_env.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_port_env.sv`
- Test: `svt_pcie_integration/sim/build_peer_x16_red/run_fast_arg_invalid.log`

- [ ] **Step 1: Run the invalid-value RED test**

On `10.11.10.53`, run the current executable with:

```bash
cd /home/ubuntu/pcie-svt-task7-multiep.v0dBgt/pcie_work/svt_pcie_integration/sim
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT="$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12"
./build_peer_x16_red/simv -no_save \
  +UVM_TESTNAME=pcie_svt_base_test +PCIE_GEN=4 \
  +PCIE_FAST_LINK_TRAIN=2 +UVM_NO_RELNOTES \
  -l build_peer_x16_red/run_fast_arg_red.log
```

Expected RED: the unsupported value is ignored and the run reaches
`LINK_PASS`; there is no `UVM_FATAL [PCIE_FAST_LINK_TRAIN]`.

- [ ] **Step 2: Add strict parsing to `pcie_svt_env`**

Add the member:

```systemverilog
  bit fast_link_training;
```

Add `string fast_link_values[$];` in `build_phase`, then parse after
`PCIE_GEN`:

```systemverilog
    fast_link_training = 1'b0;
    void'(uvm_cmdline_processor::get_inst().get_arg_values(
      "+PCIE_FAST_LINK_TRAIN=", fast_link_values));
    if ((fast_link_values.size() > 1) ||
        ((fast_link_values.size() == 1) &&
         !((fast_link_values[0] == "0") ||
           (fast_link_values[0] == "1"))))
      `uvm_fatal("PCIE_FAST_LINK_TRAIN",
        "Optional +PCIE_FAST_LINK_TRAIN must occur at most once and be 0 or 1")
    if (fast_link_values.size() == 1)
      fast_link_training = (fast_link_values[0] == "1");
```

Before each port is created, distribute it:

```systemverilog
      uvm_config_db#(bit)::set(
        this, $sformatf("port[%0d]", i), "fast_link_training",
        fast_link_training);
```

- [ ] **Step 3: Require the distributed value in `pcie_svt_port_env`**

Add the member and lookup:

```systemverilog
  bit fast_link_training;
```

```systemverilog
    if (!uvm_config_db#(bit)::get(
          this, "", "fast_link_training", fast_link_training))
      `uvm_fatal("PORT_CFG",
        {get_full_name(), ": missing fast-link-training configuration"})
```

- [ ] **Step 4: Synchronize, compile, and verify GREEN**

From the local worktree, copy both changed files:

```bash
scp svt_pcie_integration/uvm/pcie_svt_env.sv \
  ubuntu@10.11.10.53:/home/ubuntu/pcie-svt-task7-multiep.v0dBgt/pcie_work/svt_pcie_integration/uvm/pcie_svt_env.sv
scp svt_pcie_integration/uvm/pcie_svt_port_env.sv \
  ubuntu@10.11.10.53:/home/ubuntu/pcie-svt-task7-multiep.v0dBgt/pcie_work/svt_pcie_integration/uvm/pcie_svt_port_env.sv
```

On the simulation host, enter the staging `sim` directory and run:

```bash
cd /home/ubuntu/pcie-svt-task7-multiep.v0dBgt/pcie_work/svt_pcie_integration/sim
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT="$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12"
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_EP_X16 +define+PCIE_USE_SVT_PEER \
  -f pcie_svt.f -top pcie_svt_topology_top \
  -Mdir=build_peer_x16_red/csrc -P pli.tab msglog.o \
  -o build_peer_x16_red/simv \
  -l build_peer_x16_red/compile_fast_arg_green.log
```

Run both negative cases:

```bash
./build_peer_x16_red/simv -no_save \
  +UVM_TESTNAME=pcie_svt_base_test +PCIE_GEN=4 \
  +PCIE_FAST_LINK_TRAIN=2 +UVM_NO_RELNOTES \
  -l build_peer_x16_red/run_fast_arg_invalid.log

./build_peer_x16_red/simv -no_save \
  +UVM_TESTNAME=pcie_svt_base_test +PCIE_GEN=4 \
  +PCIE_FAST_LINK_TRAIN=0 +PCIE_FAST_LINK_TRAIN=1 +UVM_NO_RELNOTES \
  -l build_peer_x16_red/run_fast_arg_duplicate.log
```

Each must end with one `PCIE_FAST_LINK_TRAIN` fatal before agent startup and
no `LINK_PASS`.

- [ ] **Step 5: Commit runtime validation**

```bash
git add svt_pcie_integration/uvm/pcie_svt_env.sv \
        svt_pcie_integration/uvm/pcie_svt_port_env.sv
git commit -m "feat: validate SVT fast link training option"
```

### Task 2: Apply the Public Generation-Specific Policy

**Files:**
- Modify: `svt_pcie_integration/uvm/pcie_svt_port_env.sv`
- Test: `svt_pcie_integration/sim/build_peer_x16_red/run_fast_gen4_green.log`
- Test: `svt_pcie_integration/sim/build_peer_x16_red/run_fast_gen5_green.log`

- [ ] **Step 1: Run the fast-Gen4 behavior RED test**

Run with `+PCIE_FAST_LINK_TRAIN=1`, then check:

```bash
cd /home/ubuntu/pcie-svt-task7-multiep.v0dBgt/pcie_work/svt_pcie_integration/sim
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT="$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12"
./build_peer_x16_red/simv -no_save \
  +UVM_TESTNAME=pcie_svt_base_test +PCIE_GEN=4 \
  +PCIE_FAST_LINK_TRAIN=1 +UVM_NO_RELNOTES \
  -l build_peer_x16_red/run_fast_gen4_red.log

grep -a -q "\[LINK_PASS\].*speed=16GT/s" \
  build_peer_x16_red/run_fast_gen4_red.log
! grep -a -q "Serial Tx bit clk period before applying ssc is 0.125000" \
  build_peer_x16_red/run_fast_gen4_red.log
! grep -a -q "Speed is 8Gb/s" \
  build_peer_x16_red/run_fast_gen4_red.log
```

Expected RED: the final-speed assertion passes, while a negative assertion
fails because configuration propagation alone still visits Gen3.

- [ ] **Step 2: Make fast mode an explicit helper input**

Change the signature and call:

```systemverilog
  function void apply_profile_to_cfg(
      pcie_svt_port_profile port_profile,
      svt_pcie_device_configuration device_cfg,
      bit enable_fast_link_training);
```

```systemverilog
    apply_profile_to_cfg(profile, cfg, fast_link_training);
```

- [ ] **Step 3: Apply exactly one public equalization policy**

Immediately after validated speed setup, add:

```systemverilog
    if (enable_fast_link_training) begin
      if (port_profile.max_gen == 4)
        device_cfg.pcie_cfg.pl_cfg.set_link_eq_attribute_values(
          svt_pcie_pl_configuration::LINK_EQ_MODE_FULL_EQUALIZATION_REQUIRED,
          1'b1, 3);
      else
        device_cfg.pcie_cfg.pl_cfg.set_link_eq_attribute_values(
          svt_pcie_pl_configuration::LINK_EQ_MODE_EQ_BYPASS_TO_HIGHEST_RATE,
          1'b0, 3);
    end
    `uvm_info("PCIE_SVT_FAST_LINK", $sformatf(
      "profile=%s gen=%0d enabled=%0d eq_mode=%0d direct_2_5_to_16=%0d",
      port_profile.port_id, port_profile.max_gen,
      enable_fast_link_training,
      device_cfg.pcie_cfg.pl_cfg.get_link_eq_attribute_values(),
      device_cfg.pcie_cfg.pl_cfg.enable_direct_speed_up_from_2_5g_to_16g),
      UVM_LOW)
```

Do not disable highest-rate equalization.

- [ ] **Step 4: Compile and run fast Gen4 GREEN**

Recompile and run Gen4:

```bash
cd /home/ubuntu/pcie-svt-task7-multiep.v0dBgt/pcie_work/svt_pcie_integration/sim
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT="$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12"
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_EP_X16 +define+PCIE_USE_SVT_PEER \
  -f pcie_svt.f -top pcie_svt_topology_top \
  -Mdir=build_peer_x16_red/csrc -P pli.tab msglog.o \
  -o build_peer_x16_red/simv \
  -l build_peer_x16_red/compile_fast_policy_green.log

./build_peer_x16_red/simv -no_save \
  +UVM_TESTNAME=pcie_svt_base_test +PCIE_GEN=4 \
  +PCIE_FAST_LINK_TRAIN=1 +UVM_NO_RELNOTES \
  -l build_peer_x16_red/run_fast_gen4_green.log
```

Check the required evidence:

```bash
grep -a -q "\[LINK_PASS\].*speed=16GT/s" \
  build_peer_x16_red/run_fast_gen4_green.log
! grep -a -q "Serial Tx bit clk period before applying ssc is 0.125000" \
  build_peer_x16_red/run_fast_gen4_green.log
! grep -a -q "Speed is 8Gb/s" \
  build_peer_x16_red/run_fast_gen4_green.log
grep -a -q "UVM_WARNING :    0" \
  build_peer_x16_red/run_fast_gen4_green.log
grep -a -q "UVM_ERROR :    0" \
  build_peer_x16_red/run_fast_gen4_green.log
grep -a -q "UVM_FATAL :    0" \
  build_peer_x16_red/run_fast_gen4_green.log
```

Expected: every command succeeds; 0.400000 ns changes directly to 0.062500
ns; `LINK_PASS` reports 16 GT/s x16; final W/E/F=0/0/0.

- [ ] **Step 5: Run fast Gen5 GREEN without recompiling**

```bash
cd /home/ubuntu/pcie-svt-task7-multiep.v0dBgt/pcie_work/svt_pcie_integration/sim
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT="$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12"
./build_peer_x16_red/simv -no_save \
  +UVM_TESTNAME=pcie_svt_base_test +PCIE_GEN=5 \
  +PCIE_FAST_LINK_TRAIN=1 +UVM_NO_RELNOTES \
  -l build_peer_x16_red/run_fast_gen5_green.log
```

Expected: 0.400000 ns changes directly to 0.031250 ns; no 8 or 16 Gb/s READY
evidence; `LINK_PASS` reports 32 GT/s x16; final W/E/F=0/0/0.

- [ ] **Step 6: Re-run normal Gen4 and Gen5**

Run both generations without the plusarg:

```bash
cd /home/ubuntu/pcie-svt-task7-multiep.v0dBgt/pcie_work/svt_pcie_integration/sim
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT="$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12"
./build_peer_x16_red/simv -no_save \
  +UVM_TESTNAME=pcie_svt_base_test +PCIE_GEN=4 +UVM_NO_RELNOTES \
  -l build_peer_x16_red/run_normal_gen4_regression.log

./build_peer_x16_red/simv -no_save \
  +UVM_TESTNAME=pcie_svt_base_test +PCIE_GEN=5 +UVM_NO_RELNOTES \
  -l build_peer_x16_red/run_normal_gen5_regression.log
```

Both must pass with W/E/F=0/0/0, and normal Gen4 must retain its intermediate
8 Gb/s evidence.

- [ ] **Step 7: Commit policy mapping**

```bash
git add svt_pcie_integration/uvm/pcie_svt_port_env.sv
git commit -m "feat: add optional SVT fast link training"
```

### Task 3: Document and Consolidate Evidence

**Files:**
- Modify: `svt_pcie_integration/sim/README.md`
- Test: logs generated by Tasks 1 and 2

- [ ] **Step 1: Document the exact contract**

Add:

```markdown
## Optional fast link training

Use `+PCIE_FAST_LINK_TRAIN=1` to shorten link training. The default is `0`.
Gen4 changes from Gen1 -> Gen3 -> Gen4 to Gen1 -> Gen4. Gen5 uses the public
equalization-bypass-to-highest-rate policy and changes from Gen1 -> Gen5.

Initial training still starts at Gen1. R-2020.12 documents the Gen4 direct
mode as non-standard behavior, so use it with a DUT only when the DUT supports
the same transition.
```

Also document that only one `=0` or `=1` occurrence is legal and that the
option applies to every active link.

- [ ] **Step 2: Run consolidated evidence checks**

```bash
cd /home/ubuntu/pcie-svt-task7-multiep.v0dBgt/pcie_work/svt_pcie_integration/sim
for log in \
  build_peer_x16_red/run_wait_target_green.log \
  build_peer_x16_red/run_x16_gen5_default.log \
  build_peer_x16_red/run_fast_gen4_green.log \
  build_peer_x16_red/run_fast_gen5_green.log; do
  grep -a -E "\[LINK_PASS\]|UVM_(WARNING|ERROR|FATAL) :" "$log"
done
```

Expected: one `LINK_PASS` and final W/E/F=0/0/0 in every log.

- [ ] **Step 3: Verify repository hygiene**

```bash
git diff --check
git status --short
git diff -- svt_pcie_integration/uvm/pcie_svt_env.sv \
            svt_pcie_integration/uvm/pcie_svt_port_env.sv \
            svt_pcie_integration/sim/README.md
```

Expected: no whitespace errors and no Synopsys installation changes.

- [ ] **Step 4: Commit documentation**

```bash
git add svt_pcie_integration/sim/README.md
git commit -m "docs: explain SVT fast link training"
```
