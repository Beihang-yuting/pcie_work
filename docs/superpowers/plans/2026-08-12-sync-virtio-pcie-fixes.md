# Synchronize Virtio PCIe TL Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reproduce five PCIe TL defect groups on the current remote `main`, port the still-relevant Virtio fixes without reverting newer upstream work, validate with VCS on `10.11.10.53`, and fast-forward the verified result to GitHub `main`.

**Architecture:** Add a focused UVM regression with small probe subclasses that expose existing protected behavior without adding test hooks to production classes. Establish a VCS RED log from pristine upstream plus the test commit, apply the reference fixes by intent in three behavioral commits, then establish GREEN and representative-regression evidence before publishing with an explicit fast-forward lease check.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys VCS, Git, SSH/SCP, Bash login environment on `ubuntu@10.11.10.53`.

---

## File Map

- Create `pcie_tl_vip/tests/pcie_tl_virtio_fix_regression_test.sv`: probe subclasses and deterministic assertions for terminal completions, byte enables, ordering, 1024-DW decode, and config completion metadata.
- Modify `pcie_tl_vip/sim/filelist.f`: compile the focused regression before the testbench top.
- Modify `pcie_tl_vip/src/agent/pcie_tl_base_driver.sv`: terminate read-back tracking for no-data completions.
- Modify `pcie_tl_vip/src/agent/pcie_tl_ep_driver.sv`: honor sparse byte enables and set config-read byte count.
- Modify `pcie_tl_vip/src/agent/pcie_tl_rc_driver.sv`: release tags for terminal no-data/error completions and retain byte accounting for CplD.
- Modify `pcie_tl_vip/src/env/pcie_tl_env.sv`: serialize endpoint ingress handling while preserving current safe-capture asynchronous RC paths and current completion-boundary behavior.
- Modify `pcie_tl_vip/src/env/pcie_tl_scoreboard.sv`: record only byte-enabled memory-write lanes.
- Modify `pcie_tl_vip/src/shared/pcie_tl_codec.sv`: represent decoded 1024-DW length without ten-bit overflow.

### Task 1: Add Focused Reproduction Coverage

**Files:**
- Create: `pcie_tl_vip/tests/pcie_tl_virtio_fix_regression_test.sv`
- Modify: `pcie_tl_vip/sim/filelist.f`

- [ ] **Step 1: Add probe classes to exercise real implementation boundaries**

Create an EP driver probe that publicly wraps inherited protected operations and
an ordering probe that deliberately holds a posted write before checking the
following read:

```systemverilog
class pcie_tl_fix_probe_ep_driver extends pcie_tl_ep_driver;
    `uvm_component_utils(pcie_tl_fix_probe_ep_driver)
    function new(string name="pcie_tl_fix_probe_ep_driver", uvm_component parent=null);
        super.new(name, parent);
    endfunction
    function void seed_readback(bit [9:0] tag, pcie_tl_tlp req);
        rb_outstanding[tag] = req;
        req.rb_done = 0;
    endfunction
    function void note_completion(pcie_tl_cpl_tlp cpl);
        rb_note_completion(cpl);
    endfunction
    task apply_request(pcie_tl_tlp req);
        response_delay_min = 0;
        response_delay_max = 0;
        handle_request(req);
    endtask
    function pcie_tl_cpl_tlp make_completion(pcie_tl_tlp req);
        return generate_completion(req, CPL_STATUS_SC);
    endfunction
endclass

class pcie_tl_order_probe_ep_driver extends pcie_tl_ep_driver;
    `uvm_component_utils(pcie_tl_order_probe_ep_driver)
    int ordered_state;
    int ordering_failures;
    function new(string name="pcie_tl_order_probe_ep_driver", uvm_component parent=null);
        super.new(name, parent);
    endfunction
    virtual task handle_request(pcie_tl_tlp req);
        if (req.kind == TLP_MEM_WR) begin
            #100ns;
            ordered_state = 1;
        end else if (req.kind == TLP_MEM_RD && ordered_state != 1) begin
            ordering_failures++;
        end
    endtask
endclass
```

- [ ] **Step 2: Add direct behavioral assertions**

Create `pcie_tl_virtio_fix_unit_test extends pcie_tl_base_test`. In `run_phase`,
construct real TLP/driver/scoreboard/codec objects and report one distinct
`uvm_error` ID per failed behavior:

```systemverilog
`uvm_error("FIX_NO_DATA", "successful no-data Completion did not finish read-back")
`uvm_error("FIX_RC_TAG", "RC retained tag after terminal no-data Completion")
`uvm_error("FIX_EP_BE", "sparse EP memory ignored first_be/last_be")
`uvm_error("FIX_SCB_BE", "scoreboard recorded a disabled byte lane")
`uvm_error("FIX_1024DW", $sformatf("decoded payload size=%0d expected=4096", decoded.payload.size()))
`uvm_error("FIX_CFG_BC", $sformatf("config read byte_count=%0d expected=4", cpl.byte_count))
```

The byte-enable request uses two DWORDs, `first_be=4'b0101`,
`last_be=4'b1010`, an unaligned input address whose stored base is checked at
`{addr[63:2],2'b00}`, and eight unique payload bytes. The codec assertion builds
a legal 3DW Memory Write byte array containing a zero Length field and 4096
payload bytes, then calls `pcie_tl_codec::decode`.

- [ ] **Step 3: Add deterministic direct-link ordering assertion**

Create `pcie_tl_virtio_fix_order_test extends pcie_tl_base_test`, install the
ordering probe through the UVM factory before `super.build_phase`, put a Memory
Write followed by a Memory Read into `env.rc_adapter.tlm_tx_fifo`, wait 250 ns,
and assert:

```systemverilog
if (probe.ordering_failures != 0)
    `uvm_error("FIX_ORDER", "endpoint ingress handled read before preceding posted write")
```

This test fails deterministically when the env forks both endpoint requests and
passes when the ingress task awaits each endpoint handler.

- [ ] **Step 4: Register the test file**

Add this line immediately before `pcie_tl_vip/tests/pcie_tl_tb_top.sv` in
`pcie_tl_vip/sim/filelist.f`:

```text
/home/ryan/pcie_work/pcie_tl_vip/tests/pcie_tl_virtio_fix_regression_test.sv
```

- [ ] **Step 5: Check and commit the test-only change**

Run:

```bash
git diff --check
git status --short
git add pcie_tl_vip/tests/pcie_tl_virtio_fix_regression_test.sv pcie_tl_vip/sim/filelist.f
git commit -m "test: reproduce virtio PCIe TL integration defects"
```

Expected: no whitespace errors and a commit containing only the new regression
and filelist registration.

### Task 2: Establish RED Evidence on `10.11.10.53`

**Files:**
- Test: `pcie_tl_vip/tests/pcie_tl_virtio_fix_regression_test.sv`

- [ ] **Step 1: Create a dedicated remote checkout**

Use `sshpass` without embedding credentials in Git configuration:

```bash
sshpass -p '123' ssh -o StrictHostKeyChecking=accept-new ubuntu@10.11.10.53 \
  "bash -lc 'test -n \"\$VCS_HOME\" || command -v vcs; mkdir -p /tmp/pcie-virtio-fix-20260812'"
git archive --format=tar HEAD | gzip -c | \
  sshpass -p '123' ssh ubuntu@10.11.10.53 \
  "bash -lc 'tar -xzf - -C /tmp/pcie-virtio-fix-20260812'"
```

Expected: the login shell finds VCS and the archive extracts without touching
an existing user checkout.

- [ ] **Step 2: Generate a remote-local filelist**

On the host, replace `/home/ryan/pcie_work` with the temporary checkout and
locate `host_mem` from the host's existing workspace. Keep the repository
filelist unchanged:

```bash
cd /tmp/pcie-virtio-fix-20260812/pcie_tl_vip/sim
sed -e 's#/home/ryan/pcie_work#/tmp/pcie-virtio-fix-20260812#g' \
    -e 's#/home/ryan/shm_work/host_mem#<resolved-host-mem-path>#g' \
    filelist.f > filelist.53.f
```

Expected: every absolute path in `filelist.53.f` exists on host 53.

- [ ] **Step 3: Compile the test snapshot**

Run through `bash -lc`:

```bash
vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps \
  -f filelist.53.f -o simv -l compile.red.log
```

Expected: exit 0 and no `Error-[` entries. A compile failure is a test harness
problem, not RED evidence, and must be corrected before continuing.

- [ ] **Step 4: Run both focused tests and capture expected failures**

Run:

```bash
./simv +UVM_TESTNAME=pcie_tl_virtio_fix_unit_test +ntb_random_seed=1 \
  +UVM_VERBOSITY=UVM_LOW -l run.fix-unit.red.log
./simv +UVM_TESTNAME=pcie_tl_virtio_fix_order_test +ntb_random_seed=1 \
  +UVM_VERBOSITY=UVM_LOW -l run.fix-order.red.log
```

Expected: the unit log reports `FIX_NO_DATA`, `FIX_RC_TAG`, `FIX_EP_BE`,
`FIX_SCB_BE`, `FIX_1024DW`, and `FIX_CFG_BC`; the ordering log reports
`FIX_ORDER`. Save the exact UVM summary counts and messages locally as RED
evidence before modifying production code.

### Task 3: Fix Terminal Completions, Byte Enables, and Endpoint Ordering

**Files:**
- Modify: `pcie_tl_vip/src/agent/pcie_tl_base_driver.sv`
- Modify: `pcie_tl_vip/src/agent/pcie_tl_ep_driver.sv`
- Modify: `pcie_tl_vip/src/agent/pcie_tl_rc_driver.sv`
- Modify: `pcie_tl_vip/src/env/pcie_tl_env.sv`
- Modify: `pcie_tl_vip/src/env/pcie_tl_scoreboard.sv`
- Test: `pcie_tl_vip/tests/pcie_tl_virtio_fix_regression_test.sv`

- [ ] **Step 1: Make no-data completions terminal in base read-back**

Replace the terminal expression in `rb_note_completion` with:

```systemverilog
last = !cpl.has_data() ||
       (rb_recv[cpl.tag] >= rb_total[cpl.tag]) ||
       (cpl.cpl_status != CPL_STATUS_SC);
```

- [ ] **Step 2: Make RC completion tracking distinguish Cpl and CplD**

In `handle_completion`, add `bit terminal;`, define:

```systemverilog
terminal = !cpl.has_data() || (cpl.cpl_status != CPL_STATUS_SC);
```

Create and increment `cpl_byte_trackers[cpl.tag]` only when `!terminal`; free
the tag when `terminal` or when the successful CplD byte count reaches the
request total. Guard the info message's tracker fields with `.exists`.

- [ ] **Step 3: Honor byte enables in sparse endpoint memory**

Replace the sparse loop in `handle_mem_write` with DWORD-aligned lane logic:

```systemverilog
int total_dw = (req.payload.size() + 3) / 4;
bit [63:0] dw_addr = {mem_req.addr[63:2], 2'b00};
foreach (req.payload[i]) begin
    int dw_index = i / 4;
    int byte_index = i % 4;
    bit [3:0] byte_enable;
    if (dw_index == 0)
        byte_enable = mem_req.first_be;
    else if (dw_index == total_dw - 1)
        byte_enable = mem_req.last_be;
    else
        byte_enable = 4'hF;
    if (byte_enable[byte_index])
        mem_space[dw_addr + i] = req.payload[i];
end
```

- [ ] **Step 4: Mirror byte-enable semantics in the scoreboard**

In `store_write_data`, calculate `total_dw = (mem.length == 0) ? 1024 :
mem.length`, choose first/last/interior byte enables per DWORD, and assign
`written_data[mem.addr + i]` only when `byte_enable[byte_index]` is set.

- [ ] **Step 5: Serialize only endpoint ingress handlers**

In `tlm_loopback_rc_to_ep`, `tlm_loopback_rc_to_ep_pair`, and
`switch_to_ep_loopback`, replace the endpoint `fork...join_none` wrappers with
direct calls:

```systemverilog
ep_agent.ep_driver.handle_request(tlp);
ep_agents[i].ep_driver.handle_request(tlp);
ep_agents[idx].ep_driver.handle_request(tlp);
```

Do not alter asynchronous RC responder blocks, `on_tag_assigned`, or the
current MPS/RCB splitting implementation.

- [ ] **Step 6: Check and commit the first production fix group**

Run:

```bash
git diff --check
git diff -- pcie_tl_vip/src/agent pcie_tl_vip/src/env
git add pcie_tl_vip/src/agent/pcie_tl_base_driver.sv \
        pcie_tl_vip/src/agent/pcie_tl_ep_driver.sv \
        pcie_tl_vip/src/agent/pcie_tl_rc_driver.sv \
        pcie_tl_vip/src/env/pcie_tl_env.sv \
        pcie_tl_vip/src/env/pcie_tl_scoreboard.sv
git commit -m "fix: preserve PCIe TLM request semantics"
```

Expected: the diff contains the five scoped behaviors and no reversion of
commits after `6913793`.

### Task 4: Fix 1024-DW Decode and Config Completion Metadata

**Files:**
- Modify: `pcie_tl_vip/src/shared/pcie_tl_codec.sv`
- Modify: `pcie_tl_vip/src/agent/pcie_tl_ep_driver.sv`
- Test: `pcie_tl_vip/tests/pcie_tl_virtio_fix_regression_test.sv`

- [ ] **Step 1: Widen the decoded length temporary**

Replace the ten-bit declaration with:

```systemverilog
int unsigned len_dw;
len_dw = (tlp.length == 0) ? 1024 : tlp.length;
```

Keep the current payload/ECRC bounds logic unchanged.

- [ ] **Step 2: Set byte count for configuration reads**

At the end of `generate_completion`, before `return cpl`, add:

```systemverilog
case (req.kind)
    TLP_CFG_RD0, TLP_CFG_RD1: cpl.byte_count = 12'd4;
    default: begin end
endcase
```

This common constructor covers normal and SR-IOV config-read handlers.

- [ ] **Step 3: Check and commit the metadata fixes**

Run:

```bash
git diff --check
git add pcie_tl_vip/src/shared/pcie_tl_codec.sv \
        pcie_tl_vip/src/agent/pcie_tl_ep_driver.sv
git commit -m "fix: preserve PCIe completion length metadata"
```

Expected: one two-file commit with no unrelated formatting changes.

### Task 5: Establish GREEN and Regression Evidence on Host 53

**Files:**
- Test: `pcie_tl_vip/tests/pcie_tl_virtio_fix_regression_test.sv`
- Test: existing tests in `pcie_tl_vip/tests/`

- [ ] **Step 1: Refresh the temporary remote snapshot**

Delete only the task-specific directory contents by moving the old directory to
a timestamped sibling, recreate `/tmp/pcie-virtio-fix-20260812`, and stream the
new `git archive HEAD`. Regenerate `filelist.53.f` exactly as in Task 2.

- [ ] **Step 2: Compile the fixed snapshot**

Run:

```bash
vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps \
  -f filelist.53.f -o simv -l compile.green.log
```

Expected: exit 0, no `Error-[`, and the focused test classes appear in the VCS
elaboration output.

- [ ] **Step 3: Run the two focused tests**

Run both tests with seed 1 and `UVM_LOW` as in Task 2.

Expected: each ends with `UVM_ERROR : 0` and `UVM_FATAL : 0`; none of the seven
`FIX_*` error IDs appears.

- [ ] **Step 4: Prove the regression tests are genuinely red/green**

Use Git to generate a reverse patch for only the production commits, apply it
to a second task-specific snapshot that retains the test, compile once, and run
the focused tests. Expected: the same `FIX_*` failures as Task 2. Restore the
fixed snapshot and rerun both tests; expected: zero errors and fatals.

- [ ] **Step 5: Run representative existing regressions**

Run serially with seed 1:

```text
pcie_tl_smoke_test
pcie_tl_rw_readback_test
pcie_tl_unified_mem_test
pcie_tl_switch_unified_mem_test
pcie_tl_dpu_501x_profile_test
```

Expected for each: process exit 0, `UVM_ERROR : 0`, and `UVM_FATAL : 0`.
Inspect complete log tails rather than relying solely on grep exit status.

### Task 6: Review, Publish, and Confirm Remote State

**Files:**
- Review: all commits after `origin/main`

- [ ] **Step 1: Perform final local review**

Run:

```bash
git status --short --branch
git diff --check origin/main..HEAD
git log --oneline --decorate origin/main..HEAD
git diff --stat origin/main..HEAD
git diff origin/main..HEAD -- pcie_tl_vip/src pcie_tl_vip/tests pcie_tl_vip/sim/filelist.f
```

Expected: clean worktree; design, plan, test, and scoped production commits;
no generated VCS artifacts.

- [ ] **Step 2: Fetch and enforce a fast-forward update**

Run:

```bash
git fetch --prune origin
test "$(git merge-base HEAD origin/main)" = "$(git rev-parse origin/main)"
git rev-list --left-right --count origin/main...HEAD
```

Expected: remote side count `0` and local side count equal to the planned
commits. If the test fails, rebase onto new `origin/main` and repeat affected
VCS verification before pushing.

- [ ] **Step 3: Push directly to main without force**

Run:

```bash
git push origin HEAD:refs/heads/main
```

Expected: a fast-forward update. Do not use `--force` or store the supplied PAT.

- [ ] **Step 4: Confirm the remote object ID**

Run:

```bash
git fetch origin main
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
git ls-remote --heads origin refs/heads/main
```

Expected: local HEAD, fetched `origin/main`, and `ls-remote` all report the same
object ID.
