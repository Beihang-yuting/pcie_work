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

Compile exactly one topology macro and select Gen4 or Gen5 at run time. The
verified Switch directed-CFG image is compiled with:

```sh
mkdir -p build_dut_enum_switch
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_SWITCH_1X16_4X4 +define+PCIE_USE_SVT_PEER \
  -f pcie_svt_topology.f -top pcie_svt_topology_top \
  -Mdir=build_dut_enum_switch/csrc -P pli.tab msglog.o \
  -o build_dut_enum_switch/simv -l build_dut_enum_switch/compile.log
```

Run the directed configuration-only regression with all three mandatory
runtime selectors: topology, generation, and run mode.

```sh
./build_dut_enum_switch/simv -no_save \
  +UVM_TESTNAME=pcie_svt_cfg_init_directed_test \
  +PCIE_TOPOLOGY=SWITCH_1X16_4X4 +PCIE_CFG_INIT_ONLY \
  +PCIE_GEN=4 +UVM_NO_RELNOTES \
  -l build_dut_enum_switch/cfg_directed.log
```

The first phase keeps all four downstream ports at their default
`PCIE_SVT_EP_SINGLE` model with `enable_multi_endpoint_mode=0`. It loads the
ordinary PF0 image and emits one `REFRESH_CFG` per Endpoint without invoking
Target App BAR services. The test then explicitly changes those four ports to
`PCIE_SVT_EP_MULTI_BDF` with Multi-Endpoint Mode enabled. Only that
Multiple-BDF phase programs and reads back BAR0 through BAR5 through the
Target App service sequencer. The expected maps for its three 64-bit
Prefetchable BAR pairs are:

```text
BAR0/1: 01ff_ffff / 0000_0000  (32 MiB)
BAR2/3: 0000_ffff / 0000_0000  (64 KiB)
BAR4/5: 0000_ffff / 0000_0000  (64 KiB)
```

The directed test requires four Single-Endpoint and four Multiple-BDF
`PCIE_SVT_CFG_SPACE_CHECK` records, exactly 24 `PCIE_SVT_BAR_CHECK` records,
96 ordered BAR service operations, and five final
`CFG=PASS LINK=NOT_RUN ENUM=NOT_RUN TRAFFIC=NOT_RUN` stage rows. It finishes
with zero `UVM_WARNING`, `UVM_ERROR`, and `UVM_FATAL` counts. This regression
does not start Switch link, enumeration, or traffic stages and does not claim
Switch enumeration support.

## Active Endpoint enumeration

Current Endpoint peers default to `PCIE_SVT_EP_SINGLE` with
`enable_multi_endpoint_mode=0`. CFG initialization loads ordinary PF0 BAR
bases and attributes. During official enumeration, the wrapper selects DUT
semantics (`is_ep_device_vip=0`), and one active Target App callback per
Single-Endpoint port returns the descriptor-derived write-all-ones sizing
response. The callback does not drop TLPs and does not intercept ordinary
Configuration or Memory traffic.

The proven BAR contract is BAR0/1=32 MiB, BAR2/3=64 KiB, and BAR4/5=64 KiB;
all three are 64-bit Prefetchable Memory BARs. Multiple-BDF ports retain the
documented Target App BAR services and are excluded from full official
Endpoint enumeration.

The current command-line contract requires the compiled profile to be selected
again with exactly one `+PCIE_TOPOLOGY=<profile>` argument, exactly one
`+PCIE_GEN=<4|5>` argument, and exactly one run-mode argument. The following
commands are the verified x16 and 2x8 enumeration invocations:

```sh
./build_dut_enum_semantics_green/simv -no_save \
  +UVM_TESTNAME=pcie_svt_peer_test +PCIE_TOPOLOGY=EP_X16 \
  +PCIE_ENUM_ONLY +PCIE_GEN=4 +UVM_NO_RELNOTES \
  -l build_dut_enum_semantics_green/enum_gen4_x16.log

./build_dut_enum_semantics_green/simv -no_save \
  +UVM_TESTNAME=pcie_svt_peer_test +PCIE_TOPOLOGY=EP_X16 \
  +PCIE_ENUM_ONLY +PCIE_GEN=5 +UVM_NO_RELNOTES \
  -l build_dut_enum_semantics_green/enum_gen5_x16.log

./build_dut_enum_2x8_gen4/simv -no_save \
  +UVM_TESTNAME=pcie_svt_peer_test +PCIE_TOPOLOGY=EP_2X8 \
  +PCIE_ENUM_ONLY +PCIE_GEN=4 +UVM_NO_RELNOTES \
  -l build_dut_enum_2x8_gen4/enum_gen4.log

./build_dut_enum_2x8_gen5/simv -no_save \
  +UVM_TESTNAME=pcie_svt_peer_test +PCIE_TOPOLOGY=EP_2X8 \
  +PCIE_ENUM_ONLY +PCIE_GEN=5 +UVM_NO_RELNOTES \
  -l build_dut_enum_2x8_gen5/enum_gen5.log
```

The x16 runs each produce exactly one `PCIE_SVT_LINK_PASS`, one root-0
`PCIE_SVT_ENUM_PASS` for BDF `01:00.0` with three BAR pairs, and one final
`CFG=PASS LINK=PASS ENUM=PASS TRAFFIC=NOT_RUN` stage row. The 2x8 runs each
produce exactly two link passes, root-0 and root-1 enumeration passes (each
independent hierarchy may allocate BDF `01:00.0`) with three BAR pairs per
root, and two final PASS stage rows. The assigned apertures are:

| Root hierarchy | BAR0/1 | BAR2/3 | BAR4/5 |
| --- | --- | --- | --- |
| 0 | `0x100000000-0x101ffffff` | `0x102000000-0x10200ffff` | `0x102010000-0x10201ffff` |
| 1 (2x8 only) | `0x110000000-0x111ffffff` | `0x112000000-0x11200ffff` | `0x112010000-0x11201ffff` |

All four runs finish with idle BAR-sizing callbacks and final
`UVM_WARNING/UVM_ERROR/UVM_FATAL=0/0/0`. The x16 links negotiate x16 and the
2x8 links negotiate x8 at 16 GT/s for Gen4 or 32 GT/s for Gen5.

`SWITCH_1X16_4X4` remains callback-registration and link-only coverage. Its
five links train, but enumeration is not supported until a real Switch DUT
supplies Type-1 configuration spaces and forwarding.

## Real-Switch staged environment

Current acceptance: compile/elaboration and cfg-init only; no real DUT exists.

Future real-DUT acceptance: link, enum, and traffic.

### Placeholder build and accepted runs

From this `sim` directory, after the PLI preparation above, build the idle
placeholder image once. `SVT_PCIE_ENABLE_GEN5` keeps both Gen4 and Gen5
available in the image; the required run-time `+PCIE_GEN=4` or `+PCIE_GEN=5`
argument selects one generation.

```sh
mkdir -p build_real_switch_placeholder
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_SWITCH_1X16_4X4 \
  -f pcie_svt.f -top pcie_svt_topology_top \
  -Mdir=build_real_switch_placeholder/csrc -P pli.tab msglog.o \
  -o build_real_switch_placeholder/simv \
  -l build_real_switch_placeholder/compile.log
```

Run the accepted compile/elaboration and configuration-initialization stages
for both generations:

```sh
for gen in 4 5; do
  ./build_real_switch_placeholder/simv -no_save \
    +UVM_TESTNAME=pcie_svt_real_switch_test +PCIE_GEN="$gen" \
    +PCIE_COMPILE_ONLY +UVM_NO_RELNOTES \
    -l "build_real_switch_placeholder/run_compile_gen${gen}.log"
  ./build_real_switch_placeholder/simv -no_save \
    +UVM_TESTNAME=pcie_svt_real_switch_test +PCIE_GEN="$gen" \
    +PCIE_CFG_INIT_ONLY +UVM_NO_RELNOTES \
    -l "build_real_switch_placeholder/run_cfg_gen${gen}.log"
done
```

Gate those logs with the stage-specific checker:

```sh
for gen in 4 5; do
  ./check_real_switch_log.sh compile \
    "build_real_switch_placeholder/run_compile_gen${gen}.log"
  ./check_real_switch_log.sh cfg \
    "build_real_switch_placeholder/run_cfg_gen${gen}.log"
done
```

The `cfg` gate requires exactly 24 `MULTI_EP_BAR_CHECK`, one
`MULTI_EP_BAR_SKIP`, five `CFG_INIT_DONE`, one
`RC_HOST_MEMORY_RANGE_READY`, and one `REAL_SWITCH_CFG_INIT_PASS` report ID.
The checker also requires exactly one final zero summary for each of
`UVM_WARNING`, `UVM_ERROR`, and `UVM_FATAL`, and rejects markers belonging to
later stages.

### Fixed real-DUT adapter boundary

A user-supplied adapter must define `pcie_real_switch_dut_adapter` exactly
once with this fixed module and port contract:

```systemverilog
module pcie_real_switch_dut_adapter (
  input  logic [4:0] reset_asserted,
  input  logic [15:0] usp_rx_p, usp_rx_n,
  output logic [15:0] usp_tx_p, usp_tx_n,
  input  logic [3:0] dsp0_rx_p, dsp0_rx_n,
  output logic [3:0] dsp0_tx_p, dsp0_tx_n,
  input  logic [3:0] dsp1_rx_p, dsp1_rx_n,
  output logic [3:0] dsp1_tx_p, dsp1_tx_n,
  input  logic [3:0] dsp2_rx_p, dsp2_rx_n,
  output logic [3:0] dsp2_tx_p, dsp2_tx_n,
  input  logic [3:0] dsp3_rx_p, dsp3_rx_n,
  output logic [3:0] dsp3_tx_p, dsp3_tx_n
);
  // Convert reset polarity, provide native clocks and controls, and
  // instantiate/map the real Switch RTL here.
endmodule
```

Index 0 of `reset_asserted` belongs to the x16 upstream port; indices 1 through
4 belong to the four x4 downstream ports. Names are from the DUT point of
view: `*_rx_[pn]` enters the DUT from a VIP, and `*_tx_[pn]` leaves the DUT for
a VIP.

Place the adapter source on the VCS command line before `-f pcie_svt.f`, and
compile with the required `+define+PCIE_USE_REAL_SWITCH_DUT` macro. For
example:

```sh
real_adapter=/absolute/path/to/pcie_real_switch_dut_adapter.sv
test -r "$real_adapter"
mkdir -p build_real_switch
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_SWITCH_1X16_4X4 \
  +define+PCIE_USE_REAL_SWITCH_DUT \
  "$real_adapter" -f pcie_svt.f -top pcie_svt_topology_top \
  -Mdir=build_real_switch/csrc -P pli.tab msglog.o \
  -o build_real_switch/simv -l build_real_switch/compile.log
```

Do not also compile `pcie_real_switch_dut_adapter_compile_stub.sv` or another
adapter definition. The repository stub is only an interface/elaboration aid;
its idle outputs cannot train links.

### Run modes and log gates

`pcie_svt_real_switch_test` requires exactly one of the following bare
arguments. Missing, duplicated, valued, or conflicting mode arguments are
fatal.

| Bare argument | Ordered work | Checker mode | Idle placeholder |
| --- | --- | --- | --- |
| `+PCIE_COMPILE_ONLY` | Elaboration and five primary-VIP handle checks | `compile` | accepted |
| `+PCIE_CFG_INIT_ONLY` | Configuration-space initialization, then RC host-memory setup | `cfg` | accepted |
| `+PCIE_LINK_ONLY` | Configuration and host setup, then five-link bring-up | `link` | rejected |
| `+PCIE_ENUM_ONLY` | Configuration, host setup, links, then enumeration and BAR validation | `enum` | rejected |
| `+PCIE_TRAFFIC` | Configuration, host setup, links, enumeration, then eight traffic flows | `traffic` | rejected |

Every run must contain exactly one `+PCIE_GEN=4` or `+PCIE_GEN=5`. After a
functional real adapter is available, invoke a stage and gate the matching log
with the same mode, for example:

```sh
./build_real_switch/simv -no_save \
  +UVM_TESTNAME=pcie_svt_real_switch_test +PCIE_GEN=5 \
  +PCIE_LINK_ONLY +UVM_NO_RELNOTES \
  -l build_real_switch/run_link_gen5.log
./check_real_switch_log.sh link build_real_switch/run_link_gen5.log

./check_real_switch_log.sh enum build_real_switch/run_enum_gen5.log
./check_real_switch_log.sh traffic build_real_switch/run_traffic_gen5.log
```

The last two checker commands illustrate the log gates only; no real-DUT
link, enumeration, or traffic result is currently claimed. The optional
`+PCIE_FAST_LINK_TRAIN=1` run argument uses the existing fast-training policy;
omitting it (or using `+PCIE_FAST_LINK_TRAIN=0`) selects normal training. Use
the fast path with a real DUT only when that DUT supports the same direct rate
transition described below.

PIPE is not implemented; it replaces only the HDL transport adapter later.
The UVM profiles, staged sequences, run modes, and log gates remain unchanged
at that future boundary.

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
# Unified global-cfg environment

The backend-neutral configuration and environment-management contract is
documented in `../../docs/pcie_unified_environment_usage.md`.  The project
base test is `pcie_device_base_test`; it keeps topology connectivity in
`pcie_topology_cfg` and selects TL/SVT policy through `pcie_global_cfg`.

`PCIE_SVT_ENV_MAX_HDL_AGENTS` limits statically elaborated SVT HDL slots and
`PCIE_SVT_ENV_MAX_NUM_LINKS` limits runtime UVM link policy.  These are project
macros and must not be confused with Synopsys' `SVT_PCIE_MAX_NUM_LINKS`.
