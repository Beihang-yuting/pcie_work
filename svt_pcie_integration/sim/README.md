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

The generated `svc_util_parms.h`, `msglog.o`, and `pli.tab` artifacts belong
only in the simulation build directory. Do not generate them in this source
tree and do not copy installed Synopsys sources into the repository.

The `pcie_svt.f` file is an environment-relative source/include contract. Its
project RTL and UVM paths are resolved relative to this `sim` directory; the
referenced integration sources are supplied by later integration tasks.
