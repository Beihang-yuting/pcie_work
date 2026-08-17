# SVT PCIe simulation build contract

This simulation contract targets the installed Synopsys SVT PCIe R-2020.12
Gen5 Serial reference inputs on the VCS simulation host `10.11.10.53`. The
following prerequisites were verified there:

- `$PCIE_SVT_ROOT/examples/sverilog/tb_pcie_svt_uvm_unified_vip_sys/top.pcie_serdes5_topology.sv`;
- `$PCIE_SVT_ROOT/examples/sverilog/tb_pcie_svt_uvm_unified_vip_sys/tests/ts.base_serdes5_test.sv`;
- `$PCIE_SVT_ROOT/examples/sverilog/tb_pcie_svt_uvm_unified_vip_sys/hdl_interconnect_macros.sv`;
- `$PCIE_SVT_ROOT/sverilog/include/svt_pcie.uvm.pkg`;
- `$PCIE_SVT_ROOT/sverilog/include/svt_pcie_serdes_if.svi`;
- `$PCIE_SVT_ROOT/verilog/src/vcs/svc_util_parms.vp`;
- `$PCIE_SVT_ROOT/C/src/msglog.c`; and
- VCS W-2024.09-SP1.

Run simulation commands through a bash login/interactive shell (for example,
`bash -lic '<command>'`) so the host's VCS path and license environment are
loaded.

## Environment and PLI preparation

From the simulation build directory, prepare the PLI inputs with this exact
preamble:

```sh
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT="$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12"

"$PCIE_SVT_ROOT/bin/param2def.sh" \
  < "$PCIE_SVT_ROOT/verilog/src/vcs/svc_util_parms.vp" \
  > svc_util_parms.h
cc -c -I. -I"$VCS_HOME/include" -I"$PCIE_SVT_ROOT/C/include" \
  -DVCS_VERILOG -DUSE_VPI=1 -DPLI_64_BIT \
  "$PCIE_SVT_ROOT/C/src/msglog.c" -o msglog.o
"$VCS_HOME/bin/veriuser_to_pli_tab" -include "$VCS_HOME/include" \
  "$PCIE_SVT_ROOT/C/src/veriuser.c" > pli.tab
```

The generated `svc_util_parms.h`, `msglog.o`, and `pli.tab` artifacts are
disposable, untracked outputs created in the staged simulation working
directory. Do not commit them, and do not generate them in or otherwise modify
the installed Synopsys tree. Do not copy installed Synopsys sources into the
repository.

The `pcie_svt.f` file is an environment-relative source/include contract. Its
project RTL and UVM paths are resolved relative to this `sim` directory; the
referenced integration sources are supplied by later integration tasks.

## Configuration-space initialization regression

Compile exactly one topology macro and select Gen4 or Gen5 at run time. For
example, the switch-facing topology is compiled with:

```sh
mkdir -p build_switch
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_SWITCH_1X16_4X4 \
  -f pcie_svt.f -top pcie_svt_topology_top \
  -Mdir=build_switch/csrc -P pli.tab msglog.o \
  -o build_switch/simv -l build_switch/compile.log
```

Run the configuration-only flow with a bare `+PCIE_CFG_INIT_ONLY` argument:

```sh
./build_switch/simv -no_save \
  +UVM_TESTNAME=pcie_svt_base_test +PCIE_GEN=4 \
  +PCIE_CFG_INIT_ONLY +UVM_NO_RELNOTES \
  -l build_switch/run_cfg_init.log
```

For every Endpoint, the flow enables R-2020.12 Multi-Endpoint Mode, sets
`target_cfg[0].default_bar_ro_map` to `0000_ffff`, refreshes the agent while
the link is down, and programs then reads back BAR0 through BAR5 through the
Target App service sequencer. The expected maps for the three 64-bit
Prefetchable BAR pairs are:

```text
BAR0/1: 01ff_ffff / 0000_0000  (32 MiB)
BAR2/3: 0000_ffff / 0000_0000  (64 KiB)
BAR4/5: 0000_ffff / 0000_0000  (64 KiB)
```

R-2020.12 emits one incorrect `is_valid` role warning per Endpoint during
`REFRESH_CFG`, even though the Endpoint role is zero and the Target App accepts
the Multi-Endpoint requests. The integration catches only that exact message,
only during the refresh window, checks its expected count, and records
`MULTI_EP_REFRESH_VENDOR_WORKAROUND`. Other warnings are not caught.

The switch topology must report 24 `MULTI_EP_BAR_CHECK` operations, one RC
`MULTI_EP_BAR_SKIP`, five `CFG_INIT_DONE` operations, and zero final
`UVM_WARNING`, `UVM_ERROR`, and `UVM_FATAL` counts. The x16 and 2x8 DUT-Endpoint
topologies contain only primary RC VIPs, so their Target App BAR initialization
is intentionally skipped once and twice, respectively.

## Optional fast link training

Pass `+PCIE_FAST_LINK_TRAIN=1` to enable fast link training. Omitting the
plusarg selects the default value of 0, and an explicit
`+PCIE_FAST_LINK_TRAIN=0` has the same effect. The value is run-wide and is
applied uniformly to every active link. The plusarg may appear at most once
and must use the equals form with exactly `=0` or `=1`; an illegal value, a
duplicate, or a bare `+PCIE_FAST_LINK_TRAIN` causes a `UVM_FATAL` before any
agent is created. The required `+PCIE_GEN=<value>` plusarg must likewise appear
exactly once, must use the equals form, and accepts only `4` or `5`. A missing,
duplicate, bare, or illegal `PCIE_GEN` argument causes a `UVM_FATAL` before any
agent is created.

For Gen4, the standard path transitions Gen1 -> Gen3 -> Gen4. The fast path
transitions Gen1 -> Gen4 while retaining Gen4 equalization through the public
R-2020.12 full-equalization policy. For Gen5, the fast path uses the public
R-2020.12 equalization-bypass-to-highest-rate policy
`LINK_EQ_MODE_EQ_BYPASS_TO_HIGHEST_RATE` and transitions Gen1 -> Gen5. Initial
training cannot skip Gen1. R-2020.12 identifies the Gen4 direct mode as
non-standard; when connecting the VIP to a real DUT, the DUT must support the
same direct transition. The integration uses only public R-2020.12 APIs and
does not modify Synopsys source code.

From a clean checkout, first run the environment and PLI preparation above,
then compile the x16 SVT peer image with:

```sh
mkdir -p build_peer_x16
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_EP_X16 +define+PCIE_USE_SVT_PEER \
  -f pcie_svt.f -top pcie_svt_topology_top \
  -Mdir=build_peer_x16/csrc -P pli.tab msglog.o \
  -o build_peer_x16/simv -l build_peer_x16/compile.log
```

> **Compatibility warning:** Initial training still starts at Gen1. R-2020.12
> identifies the Gen1 -> Gen4 direct transition as non-standard. Use this mode
> with a real DUT only when the DUT explicitly supports the same transition.

The following commands reproduce the Gen4 and Gen5 default and fast cases.
The default commands intentionally omit `+PCIE_FAST_LINK_TRAIN`; an explicit
`+PCIE_FAST_LINK_TRAIN=0` is equivalent.

```sh
./build_peer_x16/simv -no_save \
  +UVM_TESTNAME=pcie_svt_base_test \
  +PCIE_GEN=4 +UVM_NO_RELNOTES \
  -l build_peer_x16/run_normal_gen4_regression.log

./build_peer_x16/simv -no_save \
  +UVM_TESTNAME=pcie_svt_base_test \
  +PCIE_GEN=5 +UVM_NO_RELNOTES \
  -l build_peer_x16/run_normal_gen5_regression.log

./build_peer_x16/simv -no_save \
  +UVM_TESTNAME=pcie_svt_base_test \
  +PCIE_GEN=4 +PCIE_FAST_LINK_TRAIN=1 +UVM_NO_RELNOTES \
  -l build_peer_x16/run_fast_gen4_green.log

./build_peer_x16/simv -no_save \
  +UVM_TESTNAME=pcie_svt_base_test \
  +PCIE_GEN=5 +PCIE_FAST_LINK_TRAIN=1 +UVM_NO_RELNOTES \
  -l build_peer_x16/run_fast_gen5_green.log
```

The following x16 evidence was generated from that stable build and verified
on `10.11.10.53`. Each log contains exactly one emitted
`UVM_INFO ... [LINK_PASS] primary=...` record. Separately, the UVM report
summary contains `[LINK_PASS] 1`. Every run finishes with `UVM_WARNING`,
`UVM_ERROR`, and `UVM_FATAL` counts of 0/0/0.

| Mode | Verified log | `LINK_PASS` result | Observed rate-path evidence |
| --- | --- | --- | --- |
| Gen4 default (plusarg omitted) | `build_peer_x16/run_normal_gen4_regression.log` | width 16, 16 GT/s | Serial Tx bit periods 0.400000, 0.125000, and 0.062500 ns show Gen1 -> Gen3 -> Gen4. |
| Gen5 default (plusarg omitted) | `build_peer_x16/run_normal_gen5_regression.log` | width 16, 32 GT/s | Final Gen5 rate reached. |
| Gen4 fast | `build_peer_x16/run_fast_gen4_green.log` | width 16, 16 GT/s | Only 0.400000 and 0.062500 ns were observed; no 0.125000 ns period or 8 Gb/s READY event was emitted. |
| Gen5 fast | `build_peer_x16/run_fast_gen5_green.log` | width 16, 32 GT/s | Only 0.400000 and 0.031250 ns were observed; no 8 or 16 Gb/s READY event was emitted. |

The period evidence above comes from the complete set of
`Serial Tx bit clk period before applying ssc is` messages in each log. The
`PCIE_SVT_FAST_LINK` diagnostic reports the requested/configured policy for
each active profile; use `LINK_PASS` and the final severity counts as the link
and test outcome rather than treating that diagnostic as final hardware state.

## Transaction-layer proxy feasibility probes

### Passive-sidecar transparent TL proxy feasibility probe

The Task 1 probe keeps four active full Device Agents on two Gen4 x4 Serial
links and adds two standalone passive SERDES sidecars. The sidecars are
observation-only. The Ingress Target callback clones and suppresses each
received request, and the bridge worker reinjects the raw request through the
opposite active Proxy's public `tlp_seqr`. A Completion observed at the Egress
passive RX is reinjected in the reverse direction by the bridge worker through
the Ingress active Proxy's public `tlp_seqr`. The checker compares encoded TLP
DWORD arrays across the independent passive boundaries.

The probe has three runtime modes:

- `+TL_PROXY_LINK_ONLY +TL_PROXY_DISABLE_SIDECARS`: four-active baseline.
- `+TL_PROXY_LINK_ONLY`: four active plus two passive sidecars, with a fixed
  10 us (`#10us`) observation window after all four active endpoint status
  objects explicitly report LTSSM L0 at Gen4 x4. Link-up, speed, and width
  remain additional gate conditions.
- No probe mode plusarg: MWr plus CfgRd/CPL transparent traffic.

The accepted Task 1 evidence build is:

```text
/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim/build_tl_proxy_passive_accept.yjoSMU
```

Retain this build until the implementation and review are complete. The
accepted run saved GNU `time -v` output alongside the logs as
`four_active.time`, `two_sidecars.time`, and `full_traffic.time`. The recorded
measurements are:

`four_active.time`:

```text
Elapsed (wall clock) time (h:mm:ss or m:ss): 1:40.63
Maximum resident set size (kbytes): 642812
```

`two_sidecars.time`:

```text
Elapsed (wall clock) time (h:mm:ss or m:ss): 2:45.49
Maximum resident set size (kbytes): 1089384
```

`full_traffic.time`:

```text
Elapsed (wall clock) time (h:mm:ss or m:ss): 2:15.47
Maximum resident set size (kbytes): 1085344
```

For `two_sidecars - four_active`, the measured delta is `+64.86 s` wall time
and `+446572 kbytes` peak RSS.

From this `sim` directory, validate the accepted logs with the checker modes
that correspond to each artifact:

```sh
build_dir=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim/build_tl_proxy_passive_accept.yjoSMU
: "${build_dir:?set build_dir to the fresh build path printed above}"
./check_tl_proxy_passive_sidecar_log.sh baseline "$build_dir/four_active.log"
./check_tl_proxy_passive_sidecar_log.sh sidecar-link "$build_dir/two_sidecars.log"
./check_tl_proxy_passive_sidecar_log.sh full "$build_dir/full_traffic.log"
```

This evidence is limited to the Task 1 feasibility probe. It does not establish
PCIe enumeration, routing, or completion of a real switch implementation.

## Configuration watchdog directed regression

`pcie_svt_watchdog_directed_test.sv` runs the production
`pcie_svt_all_cfg_spaces_init_vseq::run_one_port(0)` with a factory-overridden
child sequence. The test double's `start()` delegates directly to its delayed
`body()` to bypass the standard UVM sequence wrapper's post-body delta cycles;
this is test-only behavior that makes completion in the exact requested time
slot deterministic while leaving the production factory creation,
`child.start()`, and watchdog arbitration intact.

After preparing the PLI inputs above, compile the directed top at the production
time unit and precision:

```sh
mkdir -p build_watchdog_directed
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_EP_X16 \
  -f pcie_svt.f pcie_svt_watchdog_directed_test.sv \
  -top pcie_svt_watchdog_directed_top \
  -Mdir=build_watchdog_directed/csrc -P pli.tab msglog.o \
  -o build_watchdog_directed/simv \
  -l build_watchdog_directed/compile.log
```

Run all three boundary cases:

```sh
for mode in exact plus1fs plus2fs; do
  ./build_watchdog_directed/simv -no_save \
    +UVM_TESTNAME=pcie_svt_watchdog_directed_test \
    +WATCHDOG_MODE="$mode" +UVM_NO_RELNOTES \
    -l "build_watchdog_directed/run_${mode}.log"
done
```

Each log must contain exactly one `WATCHDOG_DIRECTED_PASS` for its mode and
zero final `UVM_WARNING`, `UVM_ERROR`, and `UVM_FATAL` counts. The `exact` case
expects no timeout. The `plus1fs` case must report the child-side
`completion=` diagnostic, and `plus2fs` must report the watchdog-side
`current=` diagnostic. Expected `CFG_INIT_TIMEOUT` reports are caught by the
test before the final UVM severity counts are produced.
