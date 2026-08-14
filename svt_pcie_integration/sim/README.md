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
