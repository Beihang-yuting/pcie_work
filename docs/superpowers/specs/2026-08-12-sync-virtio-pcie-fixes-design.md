# Synchronize Virtio PCIe TL Fixes Design

> Date: 2026-08-12
> Status: Approved in conversation; pending written-spec review

## Goal

Reproduce the PCIe TL defects observed by the Virtio integration against the
latest `pcie_work/main`, port only the still-relevant fixes, verify them with
VCS on `10.11.10.53`, and fast-forward the verified commits directly to the
remote `main` branch.

## Starting Point

- Upstream repository: `https://github.com/Beihang-yuting/pcie_work.git`
- Baseline: `origin/main` at `718cc6c` when this worktree was created
- Reference fixes from the Virtio submodule branch:
  - `3e2d8c9` — TLM ordering, byte enables, and terminal completions
  - `7fb5d13` — preserve the PCIe `Length == 0` encoding as 1024 DW
  - `f65eec8` — report four bytes for configuration-read completions
- Validation host: `ubuntu@10.11.10.53`, using a Bash login shell so VCS and
  license variables are loaded from `~/.bashrc`

The upstream commits after the reference branch's merge base must remain
intact. In particular, `06a03a5` has newer MPS/RCB completion-boundary logic,
`c688b4d` restores a cosimulation tag-assignment hook, and `718cc6c` fixes
capturing request handles before asynchronous forks.

## Approach

Work from an isolated branch based on the latest upstream `main`. Add focused
SystemVerilog regression coverage first and run it on the VCS host to establish
RED evidence against unmodified upstream code. Then port the behavioral changes
from the three reference commits by intent instead of merging their old tree.
This avoids reverting newer upstream work in files changed on both branches.

Each behavior follows a red/green cycle. When a single combined test is clearer
and compiles only once, it may contain several independently labelled checks,
but the pre-fix log must show every claimed defect failing for its expected
reason.

## Behaviors Under Test

1. **Terminal no-data completions**
   - A successful `Cpl` for a configuration or I/O write sets read-back done.
   - The RC completion tracker releases the request tag without waiting for
     payload bytes that cannot arrive.

2. **Sparse-memory byte enables**
   - The EP sparse-memory backend writes only lanes selected by `first_be` and
     `last_be`, using a DWORD-aligned base address.
   - The scoreboard records the same enabled lanes and does not invent expected
     data for disabled lanes.

3. **TLM ingress ordering**
   - A posted write followed by a read on the same endpoint ingress link is
     handled in FIFO order, so the read observes the preceding write.
   - Apply the same rule to direct, paired, and switch-to-endpoint paths.
   - Keep upstream's safe request capture for asynchronous RC responder paths.

4. **1024-DW decoding**
   - A data TLP whose encoded Length field is zero decodes as 4096 payload bytes;
     the temporary decoded length must be wide enough to represent 1024.

5. **Configuration-read completion metadata**
   - Successful configuration reads return `byte_count == 4` in both normal
     and SR-IOV paths through the common completion constructor.

## Files and Boundaries

- Add one focused regression test under `pcie_tl_vip/tests/` and register it in
  `pcie_tl_vip/sim/filelist.f`.
- Modify only the production files needed by failing assertions:
  - `src/agent/pcie_tl_base_driver.sv`
  - `src/agent/pcie_tl_ep_driver.sv`
  - `src/agent/pcie_tl_rc_driver.sv`
  - `src/env/pcie_tl_env.sv`
  - `src/env/pcie_tl_scoreboard.sv`
  - `src/shared/pcie_tl_codec.sv`
- Do not replace whole files or restore the old completion splitting code.

## VCS Validation

Copy or clone the isolated branch to a dedicated temporary directory on
`10.11.10.53`; never overwrite an existing checkout. Execute all simulation
commands through `bash -lc` after the login environment is loaded.

Validation gates:

1. The new regression compiles on the pristine upstream baseline and fails
   with the expected assertions for every defect being claimed.
2. The same regression passes after the ported fixes with zero `UVM_ERROR` and
   zero `UVM_FATAL`.
3. Existing representative regressions pass, covering direct TLM, read-back,
   unified memory, switch routing, and the current DPU configuration profile.
4. Compilation logs contain no VCS compile errors.

If a proposed assertion passes on pristine upstream, treat that behavior as
already fixed and do not make a production change for it without new evidence.
If an existing baseline test is already failing for an unrelated reason, stop
and report the baseline failure before broadening the change.

## Commit and Publication Strategy

Keep regression coverage and behavioral fixes in reviewable commits. Before
publication:

1. Fetch `origin` again.
2. Confirm the local branch is based on the current remote `main` and that the
   update is a fast-forward.
3. If `main` advanced, rebase the verified commits and rerun the affected VCS
   validation; do not force-push.
4. Push the local branch HEAD directly to `refs/heads/main` only after fresh
   verification succeeds.
5. Confirm the remote `main` object ID equals the pushed commit.

The supplied GitHub token is not embedded in URLs, stored in credential
helpers, scripts, Git configuration, or proxy configuration.

## Failure Handling

- A reproduction that fails to compile is not accepted as bug reproduction;
  fix the test harness until it compiles and fails on a behavioral assertion.
- A port conflict is resolved against current upstream semantics, with the
  reference commit used only to identify intended behavior.
- Any VCS failure blocks the direct push until its cause is understood.
- Any concurrent remote update blocks the push until it is integrated and the
  relevant verification is repeated.

