# SVT PCIe R-2020.12 Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reusable Serial/SERDES Synopsys SVT PCIe integration framework for three compile-time DUT topologies, then prove all selected links reach L0 at Gen4 and Gen5 with an optional SVT peer harness.

**Architecture:** A topology-selected HDL top creates only the active Unified VIP ports and connects them through a vectorized Serial adapter to either a DUT placeholder or peer SVT ports. Independent UVM port environments consume strongly typed profiles, preload each VIP configuration database, program Endpoint BAR sizing behavior, bring links up concurrently, and expose later enumeration/post-enumeration sequences without coupling those sequences to the physical adapter.

**Tech Stack:** SystemVerilog, UVM, Synopsys SVT PCIe R-2020.12 Unified VIP, VCS W-2024.09-SP1, Bash login-shell validation on `10.11.10.53`.

---

## Implementation constraints

- Read the approved design before executing this plan:
  `docs/superpowers/specs/2026-08-13-svt-pcie-integration-design.md`.
- Perform implementation in an isolated worktree created with
  `superpowers:using-git-worktrees`.
- Use `superpowers:test-driven-development` for every behavior change.
- Run every compile, elaboration, and simulation check on `10.11.10.53` in a
  Bash login shell.
- Do not copy Synopsys source files into this repository. Include them from
  `DESIGNWARE_HOME`.
- Do not store the simulation-host password, a GitHub token, a license string,
  or a credential-bearing remote URL in any file or commit.
- Keep the existing untracked `motd.legal-displayed` file untouched.
- The three user-selected topology macros remain the public compile interface;
  no topology-selection shell wrapper is added.

## Final file map

```text
svt_pcie_integration/
├── rtl/
│   ├── pcie_svt_topology_checks.svh       # macro exclusivity and topology constants
│   ├── pcie_svt_serial_port_if.sv         # vectorized DUT-facing Serial port
│   ├── pcie_svt_reset_if.sv               # bounded, per-link reset coordinator API
│   ├── pcie_svt_serial_adapter.sv         # SVT scalar-lane to vector-port mapping
│   ├── pcie_svt_vip_bootstrap.sv          # SVT package/global-shadow compile contract
│   ├── pcie_dut_placeholder.sv            # topology-shaped no-LTSSM DUT shell
│   ├── pcie_svt_peer_harness.sv           # optional opposing SVT ports
│   └── pcie_svt_topology_top.sv            # Unified HDL agents, reset, topology wiring
├── uvm/
│   ├── pcie_svt_profile.sv                # port/function/BAR/capability profile types
│   ├── pcie_svt_profile_set.sv            # complete templates per topology and peer
│   ├── pcie_svt_cfg_space_builder.sv      # 4-KiB image and consistency validation
│   ├── pcie_svt_virtual_sequencer.sv      # active port sequencer/status registry
│   ├── pcie_svt_port_env.sv               # one-agent wrapper
│   ├── pcie_svt_env.sv                    # topology-selected port collection
│   ├── sequences/
│   │   ├── pcie_svt_cfg_space_init_seq.sv
│   │   ├── pcie_svt_all_cfg_spaces_init_vseq.sv
│   │   ├── pcie_svt_link_bringup_seq.sv
│   │   ├── pcie_svt_all_links_bringup_vseq.sv
│   │   ├── pcie_svt_topology_enumeration_vseq.sv
│   │   ├── pcie_svt_post_enum_enable_vseq.sv
│   │   └── pcie_svt_peer_smoke_vseq.sv
│   ├── pcie_svt_base_test.sv              # plusarg parsing and normal startup
│   ├── pcie_svt_profile_unit_test.sv      # pure profile/builder assertions
│   └── pcie_svt_integration_pkg.sv        # package include order
└── sim/
    ├── pcie_svt.f                         # project sources and SVT include contract
    └── README.md                          # exact topology/build/run usage
```

## Shared VCS-host command convention

For all tasks, first stage the current worktree into a fresh remote directory.
The executor records the printed path in `SVT_REMOTE_WORK`; this directory may
be removed after final verification because it contains only a disposable copy.

```bash
SVT_REMOTE_WORK=$(ssh ubuntu@10.11.10.53 \
  'mktemp -d /home/ubuntu/pcie-svt-integration.XXXXXX')
rsync -az --exclude=.git --exclude=motd.legal-displayed ./ \
  "ubuntu@10.11.10.53:${SVT_REMOTE_WORK}/pcie_work/"
ssh ubuntu@10.11.10.53 "bash -lic 'test -d ${SVT_REMOTE_WORK}/pcie_work && vcs -ID'"
```

Expected: the last command prints VCS `W-2024.09-SP1` identification. Refresh
the remote copy after each local commit with the same `rsync` command. All
subsequent remote examples assume:

```bash
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT="$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12"
cd "$SVT_REMOTE_WORK/pcie_work/svt_pcie_integration/sim"
```

Run those exports inside a quoted `bash -lic` command on the remote host; do
not add them to the host's shell startup files.

Every VCS invocation below runs from `svt_pcie_integration/sim`, never from a
child build directory. This keeps `pcie_svt.f` entries such as `../rtl` and
`../uvm` stable. Put generated outputs under a build directory with `-Mdir`,
`-o`, and `-l`.

### Task 1: Establish the R-2020.12 build baseline

**Files:**
- Create: `svt_pcie_integration/sim/README.md`
- Create: `svt_pcie_integration/sim/pcie_svt.f`

- [ ] **Step 1: Verify the installed Gen5 Serial reference inputs**

The installed tree contains example sources but not the generated Makefile or
runner, so use it as a read-only API/build reference. Verify every required
input before creating project files:

```bash
ssh ubuntu@10.11.10.53 "bash -lic '
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
  PCIE_SVT_ROOT=$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12
  EX=$PCIE_SVT_ROOT/examples/sverilog/tb_pcie_svt_uvm_unified_vip_sys
  test -r $EX/top.pcie_serdes5_topology.sv
  test -r $EX/tests/ts.base_serdes5_test.sv
  test -r $EX/hdl_interconnect_macros.sv
  test -r $PCIE_SVT_ROOT/sverilog/include/svt_pcie.uvm.pkg
  test -r $PCIE_SVT_ROOT/sverilog/include/svt_pcie_serdes_if.svi
  test -r $PCIE_SVT_ROOT/verilog/src/vcs/svc_util_parms.vp
  test -r $PCIE_SVT_ROOT/C/src/msglog.c
  vcs -ID
'"
```

Expected: all `test -r` checks return zero and VCS identifies itself as
`W-2024.09-SP1`. Do not run `dw_vip_setup`, install `csh`, or modify the
Synopsys tree. Task 8 is the first executable back-to-back Serial baseline and
uses our actual integration rather than a generated copy of the example.

- [ ] **Step 2: Create the minimal project file list contract**

Write `pcie_svt.f` with environment-relative entries only:

```text
+incdir+../rtl
+incdir+../uvm
+incdir+../uvm/sequences
+incdir+$PCIE_SVT_ROOT/sverilog/include
+incdir+$DESIGNWARE_HOME/vip/svt/common/R-2020.12/sverilog/include
-y $PCIE_SVT_ROOT/verilog/src/vcs
-y $PCIE_SVT_ROOT/sverilog/src/vcs
../rtl/pcie_svt_vip_bootstrap.sv
../rtl/pcie_svt_serial_port_if.sv
../rtl/pcie_svt_reset_if.sv
../uvm/pcie_svt_integration_pkg.sv
../rtl/pcie_svt_topology_top.sv
```

If the first compile reports a missing installed header, identify the owning
directory with `find "$PCIE_SVT_ROOT" "$DESIGNWARE_HOME/vip/svt/common/R-2020.12" \
-type f -name '<missing-header>' -print`, add its containing directory as an
environment-rooted `+incdir+` entry, and rerun the same compile. No installed
source is copied.

- [ ] **Step 3: Document the verified prerequisite and PLI preparation**

Add this exact build preamble to `README.md`:

```bash
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

Expected: `svc_util_parms.h`, `msglog.o`, and `pli.tab` are generated only in
the simulation build directory.

- [ ] **Step 4: Commit the baseline contract**

```bash
git add svt_pcie_integration/sim/pcie_svt.f \
        svt_pcie_integration/sim/README.md
git commit -m "build: establish SVT PCIe simulation contract"
```

### Task 2: Enforce topology selection and expose vector Serial ports

**Files:**
- Create: `svt_pcie_integration/rtl/pcie_svt_topology_checks.svh`
- Create: `svt_pcie_integration/rtl/pcie_svt_serial_port_if.sv`
- Create: `svt_pcie_integration/rtl/pcie_svt_reset_if.sv`
- Create: `svt_pcie_integration/rtl/pcie_dut_placeholder.sv`
- Test: VCS preprocessing/elaboration commands below

- [ ] **Step 1: Write compile-fail topology tests before defining constants**

Create a temporary probe in the remote build directory:

```systemverilog
`include "pcie_svt_topology_checks.svh"
module topology_contract_probe;
  initial $display("PORTS=%0d LANES=%0d", `PCIE_SVT_ACTIVE_PORTS,
                   `PCIE_SVT_TOTAL_LANES);
endmodule
```

Run it once without a topology macro and once with two macros:

```bash
vcs -full64 -sverilog +incdir+../rtl build_contract/topology_contract_probe.sv \
  -Mdir=build_contract/csrc_no_topology \
  -o build_contract/simv_no_topology
vcs -full64 -sverilog +incdir+../rtl \
  +define+PCIE_TOPO_EP_X16 +define+PCIE_TOPO_EP_2X8 \
  build_contract/topology_contract_probe.sv \
  -Mdir=build_contract/csrc_two_topologies \
  -o build_contract/simv_two_topologies
```

Expected before implementation: both commands fail because the include is
missing. After the next step: both fail with the explicit topology-contract
message rather than an unrelated syntax error.

- [ ] **Step 2: Implement mutual-exclusion checks and constants**

Use nested standard preprocessor branches so every invalid combination is
rejected without relying on non-standard arithmetic directives:

```systemverilog
`ifndef PCIE_SVT_TOPOLOGY_CHECKS_SVH
`define PCIE_SVT_TOPOLOGY_CHECKS_SVH

`ifdef PCIE_TOPO_EP_X16
  `ifdef PCIE_TOPO_EP_2X8
    `error "Define exactly one PCIe topology macro"
  `endif
  `ifdef PCIE_TOPO_SWITCH_1X16_4X4
    `error "Define exactly one PCIe topology macro"
  `endif
  `define PCIE_SVT_ACTIVE_PORTS 1
  `define PCIE_SVT_TOTAL_LANES 16
`elsif PCIE_TOPO_EP_2X8
  `ifdef PCIE_TOPO_SWITCH_1X16_4X4
    `error "Define exactly one PCIe topology macro"
  `endif
  `define PCIE_SVT_ACTIVE_PORTS 2
  `define PCIE_SVT_TOTAL_LANES 16
`elsif PCIE_TOPO_SWITCH_1X16_4X4
  `define PCIE_SVT_ACTIVE_PORTS 5
  `define PCIE_SVT_TOTAL_LANES 32
`else
  `error "Define one PCIE_TOPO_EP_X16, PCIE_TOPO_EP_2X8, or PCIE_TOPO_SWITCH_1X16_4X4"
`endif

`endif
```

- [ ] **Step 3: Implement the vectorized DUT-facing Serial interface**

```systemverilog
interface pcie_svt_serial_port_if #(int LANES = 1);
  logic [LANES-1:0] rx_p;
  logic [LANES-1:0] rx_n;
  logic [LANES-1:0] tx_p;
  logic [LANES-1:0] tx_n;
  logic [LANES-1:0] tx_clk;
  logic [LANES-1:0] rx_clk;
  logic [LANES-1:0] active_tx_transmit_clk;
  logic [LANES-1:0] active_rx_recovered_clk;
endinterface
```

The signal names are from the DUT perspective: `rx_*` are driven by SVT and
`tx_*` are driven by the DUT or peer.

Create a separate reset-control interface so UVM can release all active links
together or one link independently without forcing reset through lane data:

```systemverilog
interface pcie_svt_reset_if #(int MAX_LINKS = 5);
  logic [MAX_LINKS-1:0] asserted = '1;
  task automatic hold_all(); asserted = '1; endtask
  task automatic release_all(); asserted = '0; endtask
  task automatic hold_link(int unsigned id);
    if (id >= MAX_LINKS) $fatal(1, "reset link index %0d out of range", id);
    asserted[id] = 1'b1;
  endtask
  task automatic release_link(int unsigned id);
    if (id >= MAX_LINKS) $fatal(1, "reset link index %0d out of range", id);
    asserted[id] = 1'b0;
  endtask
endinterface
```

The HDL top maps `asserted[link_id]` to each active Unified SERDES
`vip_port_if.ser_if.reset` and to the corresponding DUT reset input. In peer
mode both ends of one physical link share the same reset bit.

- [ ] **Step 4: Implement the topology-shaped placeholder**

Use one module name with conditional port declarations and drive only DUT
transmit outputs:

```systemverilog
module pcie_dut_placeholder (
`ifdef PCIE_TOPO_EP_X16
  input logic reset, input logic [15:0] ep0_rx_p, ep0_rx_n,
  output logic [15:0] ep0_tx_p, ep0_tx_n
`elsif PCIE_TOPO_EP_2X8
  input logic reset, input logic [7:0] ep0_rx_p, ep0_rx_n,
  output logic [7:0] ep0_tx_p, ep0_tx_n,
  input logic [7:0] ep1_rx_p, ep1_rx_n,
  output logic [7:0] ep1_tx_p, ep1_tx_n
`else
  input logic reset, input logic [15:0] usp_rx_p, usp_rx_n,
  output logic [15:0] usp_tx_p, usp_tx_n,
  input logic [3:0] dsp0_rx_p, dsp0_rx_n,
  output logic [3:0] dsp0_tx_p, dsp0_tx_n,
  input logic [3:0] dsp1_rx_p, dsp1_rx_n,
  output logic [3:0] dsp1_tx_p, dsp1_tx_n,
  input logic [3:0] dsp2_rx_p, dsp2_rx_n,
  output logic [3:0] dsp2_tx_p, dsp2_tx_n,
  input logic [3:0] dsp3_rx_p, dsp3_rx_n,
  output logic [3:0] dsp3_tx_p, dsp3_tx_n
`endif
);
`ifdef PCIE_TOPO_EP_X16
  assign ep0_tx_p = '0; assign ep0_tx_n = '1;
`elsif PCIE_TOPO_EP_2X8
  assign ep0_tx_p = '0; assign ep0_tx_n = '1;
  assign ep1_tx_p = '0; assign ep1_tx_n = '1;
`else
  assign usp_tx_p = '0; assign usp_tx_n = '1;
  assign dsp0_tx_p = '0; assign dsp0_tx_n = '1;
  assign dsp1_tx_p = '0; assign dsp1_tx_n = '1;
  assign dsp2_tx_p = '0; assign dsp2_tx_n = '1;
  assign dsp3_tx_p = '0; assign dsp3_tx_n = '1;
`endif
endmodule
```

- [ ] **Step 5: Verify all valid topology contracts pass**

```bash
for topo in PCIE_TOPO_EP_X16 PCIE_TOPO_EP_2X8 PCIE_TOPO_SWITCH_1X16_4X4; do
  vcs -full64 -sverilog +incdir+../rtl +define+$topo \
    build_contract/topology_contract_probe.sv \
    -Mdir="build_contract/csrc_${topo}" \
    -o "build_contract/simv_${topo}"
  "./build_contract/simv_${topo}"
done
```

Expected: `PORTS=1 LANES=16`, `PORTS=2 LANES=16`, and
`PORTS=5 LANES=32`.

- [ ] **Step 6: Commit the topology contract**

```bash
git add svt_pcie_integration/rtl/pcie_svt_topology_checks.svh \
        svt_pcie_integration/rtl/pcie_svt_serial_port_if.sv \
        svt_pcie_integration/rtl/pcie_svt_reset_if.sv \
        svt_pcie_integration/rtl/pcie_dut_placeholder.sv
git commit -m "feat: define SVT PCIe topology and DUT ports"
```

### Task 3: Add strongly typed profiles and complete templates

**Files:**
- Create: `svt_pcie_integration/uvm/pcie_svt_profile.sv`
- Create: `svt_pcie_integration/uvm/pcie_svt_profile_set.sv`
- Create: `svt_pcie_integration/uvm/pcie_svt_profile_unit_test.sv`
- Create: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt.f`

- [ ] **Step 1: Write failing profile-template assertions**

The first compile uses the complete SVT package contract from Task 1, because
the profile classes extend `uvm_object` and use SVT enums later in the same
project package. `pcie_svt_integration_pkg.sv` must include files in this exact
dependency order:

```systemverilog
package pcie_svt_integration_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import svt_uvm_pkg::*;
  import svt_pcie_uvm_pkg::*;
  `include "pcie_svt_profile.sv"
  `include "pcie_svt_profile_set.sv"
  `include "pcie_svt_cfg_space_builder.sv"
  `include "pcie_svt_virtual_sequencer.sv"
  `include "pcie_svt_port_env.sv"
  `include "pcie_svt_env.sv"
  `include "sequences/pcie_svt_cfg_space_init_seq.sv"
  `include "sequences/pcie_svt_all_cfg_spaces_init_vseq.sv"
  `include "sequences/pcie_svt_link_bringup_seq.sv"
  `include "sequences/pcie_svt_all_links_bringup_vseq.sv"
  `include "sequences/pcie_svt_topology_enumeration_vseq.sv"
  `include "sequences/pcie_svt_post_enum_enable_vseq.sv"
  `include "sequences/pcie_svt_peer_smoke_vseq.sv"
  `include "pcie_svt_base_test.sv"
  `include "pcie_svt_profile_unit_test.sv"
endpackage
```

During Tasks 3 and 4, comment out only include lines whose files have not yet
been created, then enable each line in the task that creates that file. Do not
create empty placeholder classes. The unit test creates the switch template
and checks every Endpoint:

```systemverilog
class pcie_svt_profile_unit_test extends uvm_test;
  `uvm_component_utils(pcie_svt_profile_unit_test)
  function new(string name="pcie_svt_profile_unit_test", uvm_component p=null);
    super.new(name, p);
  endfunction
  task run_phase(uvm_phase phase);
    pcie_svt_profile_set profiles;
    phase.raise_objection(this);
    profiles = pcie_svt_profile_set::type_id::create("profiles");
    profiles.build_for_topology(PCIE_SVT_TOPO_SWITCH, 5);
    if (profiles.active_count() != 5)
      `uvm_error("PROFILE", "switch template must contain five active ports")
    for (int p = 1; p <= 4; p++) begin
      if (profiles.port[p].role != PCIE_SVT_EP ||
          profiles.port[p].link_width != 4)
        `uvm_error("PROFILE", $sformatf("port %0d must be EP x4", p))
      if (!profiles.port[p].functions[0].bars[0].is_64bit ||
          !profiles.port[p].functions[0].bars[0].prefetchable ||
          profiles.port[p].functions[0].bars[0].aperture != 64'd33554432)
        `uvm_error("PROFILE", $sformatf("port %0d BAR0 template mismatch", p))
      if (profiles.port[p].functions[0].bars[2].aperture != 64'd65536 ||
          profiles.port[p].functions[0].bars[4].aperture != 64'd65536)
        `uvm_error("PROFILE", $sformatf("port %0d BAR2/BAR4 mismatch", p))
    end
    phase.drop_objection(this);
  endtask
endclass
```

Run VCS from `svt_pcie_integration/sim` with `-f pcie_svt.f` and
`+define+PCIE_TOPO_SWITCH_1X16_4X4`, placing outputs under
`build_profile_unit/`. Expected: FAIL because the profile types do not exist.

- [ ] **Step 2: Define profile types with validation methods**

Define these public types and method contracts:

```systemverilog
typedef enum int {PCIE_SVT_RC, PCIE_SVT_EP} pcie_svt_role_e;
typedef enum int {PCIE_SVT_TOPO_EP_X16, PCIE_SVT_TOPO_EP_2X8,
                  PCIE_SVT_TOPO_SWITCH} pcie_svt_topology_e;

class pcie_svt_bar_profile extends uvm_object;
  bit implemented;
  bit is_64bit;
  bit prefetchable;
  longint unsigned aperture;
  longint unsigned initial_base;
  function bit validate(string path);
    if (!implemented) return 1;
    if (aperture < 16 || (aperture & (aperture-1)) != 0) begin
      `uvm_error("PROFILE", {path, ": BAR aperture must be a power of two"})
      return 0;
    end
    if ((initial_base & (aperture-1)) != 0) begin
      `uvm_error("PROFILE", {path, ": BAR base is not aperture aligned"})
      return 0;
    end
    return 1;
  endfunction
endclass

class pcie_svt_function_profile extends uvm_object;
  bit [15:0] vendor_id, device_id;
  bit [23:0] class_code;
  bit [7:0] revision_id, header_type;
  bit [15:0] subsystem_vendor_id, subsystem_device_id;
  bit [15:0] command_reset;
  bit [7:0] interrupt_pin;
  pcie_svt_bar_profile bars[6];
  pcie_svt_bar_profile expansion_rom;
  bit enable_msi, enable_msix, enable_aer, enable_sriov;
  bit enable_ats, enable_pri, enable_pasid, enable_ari, enable_acs, enable_rebar;
  bit [2:0] max_payload_supported, max_payload_size, max_read_request_size;
  bit [3:0] completion_timeout_ranges;
  bit [2:0] msix_table_bar, msix_pba_bar;
  bit [28:0] msix_table_offset, msix_pba_offset;
  bit [31:0] rebar_supported_sizes[6];
  bit [5:0] rebar_current_size[6];
  bit [31:0] raw_dw_override[int unsigned];
  function bit validate(string path);
    bit ok = 1;
    if (enable_pri && !enable_ats) begin
      `uvm_error("PROFILE", {path, ": PRI requires ATS"}); ok = 0;
    end
    if (enable_pasid && !enable_ats) begin
      `uvm_error("PROFILE", {path, ": PASID requires ATS"}); ok = 0;
    end
    foreach (bars[i]) ok &= bars[i].validate($sformatf("%s.BAR%0d",path,i));
    return ok;
  endfunction
endclass

class pcie_svt_port_profile extends uvm_object;
  string port_id;
  pcie_svt_role_e role;
  int unsigned link_width, max_gen, root_hierarchy;
  pcie_svt_function_profile functions[$];
  function bit validate();
    bit ok = link_width inside {4,8,16};
    if (!(max_gen inside {4,5})) ok = 0;
    foreach (functions[i]) ok &= functions[i].validate(
      $sformatf("%s.PF%0d", port_id, i));
    return ok;
  endfunction
endclass
```

Register every class with the UVM factory and implement constructors that
create all six BAR objects plus `expansion_rom`, so callers never dereference
null handles. Validation also rejects an MSI-X Table/PBA reference to an
unimplemented BAR, non-8-byte-aligned MSI-X offsets, a Resizable BAR entry for
an unimplemented BAR, or a current-size encoding absent from that BAR's
supported-size bitmap.

- [ ] **Step 3: Implement complete topology templates**

`build_for_topology()` creates the exact primary profiles:

```systemverilog
case (topology)
  PCIE_SVT_TOPO_EP_X16: begin
    add_port(make_rc("rc0", 16, 0, max_gen));
  end
  PCIE_SVT_TOPO_EP_2X8: begin
    add_port(make_rc("rc0", 8, 0, max_gen));
    add_port(make_rc("rc1", 8, 1, max_gen));
  end
  PCIE_SVT_TOPO_SWITCH: begin
    add_port(make_rc("rc0", 16, 0, max_gen));
    for (int i=0; i<4; i++)
      add_port(make_ep($sformatf("ep%0d",i), 4, 0, max_gen,
                       16'h20f9, 16'h5011+i));
  end
endcase
```

`make_ep()` creates PF0 and calls a helper three times:

```systemverilog
set_64b_prefetch_bar(fn, 0, 64'd32*1024*1024);
set_64b_prefetch_bar(fn, 2, 64'd64*1024);
set_64b_prefetch_bar(fn, 4, 64'd64*1024);
```

Use fixed legal defaults: revision `8'h00`, class `24'h020000`, subsystem
vendor equal to Vendor ID, subsystem device equal to Device ID, interrupt pin
`1`, MPS supported/current `128 B`, MRRS `512 B`, completion-timeout ranges
`4'b0001`, and zero initial BAR/Expansion-ROM bases. Expansion ROM, MSI,
MSI-X, AER, SR-IOV, ATS, PRI, PASID, ARI, ACS, and Resizable BAR default off;
the mandatory PCIe Capability is always emitted.

`make_rc()` also creates PF0, but uses Type-1 header `8'h01`, class code
`24'h060400`, no implemented BAR/Expansion ROM, interrupt pin zero, and the
same fixed PCIe Device/Link capability defaults. Thus configuration-database
initialization never receives an empty function list for a Root port.

- [ ] **Step 4: Add peer-template generation**

Implement `build_peer_for_topology()` with the opposite role and independent
root hierarchy per physical peer link:

```systemverilog
PCIE_SVT_TOPO_EP_X16: add_port(make_ep("peer_ep0",16,0,max_gen,16'h1af4,16'h1000));
PCIE_SVT_TOPO_EP_2X8: begin
  add_port(make_ep("peer_ep0",8,0,max_gen,16'h1af4,16'h1000));
  add_port(make_ep("peer_ep1",8,1,max_gen,16'h1af4,16'h1001));
end
PCIE_SVT_TOPO_SWITCH: begin
  add_port(make_ep("peer_ep_usp",16,0,max_gen,16'h1af4,16'h1100));
  for (int i=0; i<4; i++)
    add_port(make_rc($sformatf("peer_rc_dsp%0d",i),4,i+1,max_gen));
end
```

- [ ] **Step 5: Run profile tests at both generations**

```bash
mkdir -p build_profile_unit
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_SWITCH_1X16_4X4 -f pcie_svt.f \
  -Mdir=build_profile_unit/csrc -P pli.tab msglog.o \
  -o build_profile_unit/simv -l build_profile_unit/compile.log
./build_profile_unit/simv +UVM_TESTNAME=pcie_svt_profile_unit_test +PCIE_GEN=4 \
  -l build_profile_unit/run_gen4.log
./build_profile_unit/simv +UVM_TESTNAME=pcie_svt_profile_unit_test +PCIE_GEN=5 \
  -l build_profile_unit/run_gen5.log
```

Expected: zero `UVM_ERROR`/`UVM_FATAL`; all Endpoint BAR profiles have the
approved apertures and flags.

- [ ] **Step 6: Commit profiles**

```bash
git add svt_pcie_integration/uvm svt_pcie_integration/sim/pcie_svt.f
git commit -m "feat: add independent SVT PCIe port profiles"
```

### Task 4: Build and validate 4-KiB configuration images

**Files:**
- Create: `svt_pcie_integration/uvm/pcie_svt_cfg_space_builder.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_profile_unit_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`

- [ ] **Step 1: Add failing DWORD and BAR-mask assertions**

Extend the unit test with:

```systemverilog
pcie_svt_cfg_space_builder b;
bit [31:0] image[1024];
b = pcie_svt_cfg_space_builder::type_id::create("b");
if (!b.build_function(profiles.port[1].functions[0], 4, 5, image))
  `uvm_error("CFG_BUILD", "EP0 PF0 image build failed")
if (image['h000/4] !== 32'h5011_20f9)
  `uvm_error("CFG_BUILD", "Vendor/Device DWORD mismatch")
if (image['h010/4] !== 32'h0000_000c ||
    image['h018/4] !== 32'h0000_000c ||
    image['h020/4] !== 32'h0000_000c)
  `uvm_error("CFG_BUILD", "64-bit Prefetchable BAR attributes mismatch")
if (b.bar_sizing_dw(64'd32*1024*1024, 0) !== 32'hfe00_000c ||
    b.bar_sizing_dw(64'd64*1024, 0) !== 32'hffff_000c)
  `uvm_error("CFG_BUILD", "BAR sizing DWORD mismatch")
```

Expected: compile failure because the builder is absent.

- [ ] **Step 2: Implement image access and BAR helpers**

The builder exposes deterministic helpers:

```systemverilog
function automatic bit [31:0] bar_sizing_dw(longint unsigned aperture,
                                             bit upper);
  bit [63:0] mask = ~(aperture - 1);
  return upper ? mask[63:32] : (mask[31:0] | 32'h0000_000c);
endfunction

function automatic bit [31:0] bar_ro_map(longint unsigned aperture,
                                          bit upper);
  bit [63:0] ro_map = aperture - 1;
  return upper ? ro_map[63:32] : ro_map[31:0];
endfunction

function void put_dw(ref bit [31:0] image[1024],
                     int unsigned byte_offset, bit [31:0] value);
  image[byte_offset/4] = value;
endfunction
```

Reject unaligned offsets, offsets above `12'hffc`, and raw overrides of
`0x34`, capability-header next pointers, or BAR type bits.

- [ ] **Step 3: Implement fixed headers and capability chaining**

`build_function()` has this signature so physical-link fields never need to be
duplicated inside a function profile:

```systemverilog
function bit build_function(pcie_svt_function_profile fn,
                            int unsigned link_width,
                            int unsigned max_gen,
                            ref bit [31:0] image[1024]);
```

Build Type 0 headers and a fixed, non-overlapping capability layout:

```text
0x040 PCIe Capability
0x080 MSI (when enabled)
0x0A0 MSI-X (when enabled)
0x100 AER (when enabled)
0x180 SR-IOV (when enabled)
0x240 ATS (when enabled)
0x260 PRI (when enabled)
0x280 PASID (when enabled)
0x2A0 ARI (when enabled)
0x2C0 ACS (when enabled)
0x300 Resizable BAR (when enabled)
```

Use the function profile's `header_type[6:0]`: Type 0 emits six BARs,
Subsystem IDs, and Expansion ROM at `0x30`; Type 1 emits two bridge BARs and
bus/window registers with safe reset values. Any other header type is rejected.
For each standard capability set byte 1 to the next standard offset. For each
extended capability, encode `next_offset` in header bits `[31:20]`. Emit PCIe
Capability maximum speed from `max_gen`, maximum width from `link_width`, and
Supported Link Speeds Vector bits Gen1 through the selected generation. When
MSI-X is enabled, emit its Table/PBA BIR+offset fields from the validated
profile. When Resizable BAR is enabled, emit one entry per nonzero supported
size bitmap and require its current size to agree with the BAR aperture.

- [ ] **Step 4: Add negative validation tests**

Create cloned profiles and assert `build_function()` returns zero for:

```systemverilog
bad.functions[0].enable_pri = 1;
bad.functions[0].enable_ats = 0;

bad.functions[0].bars[0].aperture = 64'd3*1024*1024;

bad.functions[0].raw_dw_override['h034/4] = 32'hdead_beef;

bad.functions[0].enable_msix = 1;
bad.functions[0].msix_table_bar = 1; // upper half of BAR0/1 pair, not a window

bad.functions[0].enable_rebar = 1;
bad.functions[0].rebar_supported_sizes[0] = '0;
```

Use `uvm_report_catcher` to demote the five expected errors so the unit test
can assert the failure return values and still finish with zero unexpected
errors.

- [ ] **Step 5: Run the builder regression**

```bash
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_SWITCH_1X16_4X4 -f pcie_svt.f \
  -Mdir=build_profile_unit/csrc -P pli.tab msglog.o \
  -o build_profile_unit/simv -l build_profile_unit/compile.log
./build_profile_unit/simv +UVM_TESTNAME=pcie_svt_profile_unit_test +PCIE_GEN=5 \
  -l build_profile_unit/builder_gen5.log
```

Expected: all positive images pass, all five negative cases are rejected, and
the final UVM summary has no unexpected errors.

- [ ] **Step 6: Commit the builder**

```bash
git add svt_pcie_integration/uvm/pcie_svt_cfg_space_builder.sv \
        svt_pcie_integration/uvm/pcie_svt_profile_unit_test.sv \
        svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv
git commit -m "feat: build SVT PCIe configuration images"
```

### Task 5: Instantiate Unified HDL agents and verify placeholder elaboration

**Files:**
- Create: `svt_pcie_integration/rtl/pcie_svt_vip_bootstrap.sv`
- Create: `svt_pcie_integration/rtl/pcie_svt_serial_adapter.sv`
- Create: `svt_pcie_integration/rtl/pcie_svt_topology_top.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt.f`

- [ ] **Step 1: Write a scalar-lane mapping compile probe**

Before adding the full top, instantiate one official Unified port and attempt
to map lane 0 through the adapter macro. Expected: failure because the adapter
macro is not defined.

```systemverilog
svt_pcie_if probe_if(clkreq_n, wake_n);
svt_pcie_single_port_device_agent_hdl probe_spd(probe_if);
pcie_svt_serial_port_if #(16) probe_serial();
`PCIE_SVT_MAP_SERDES_LANE(probe_spd, probe_serial, 0)
```

- [ ] **Step 2: Implement lane and width mapping macros**

Each emitted lane uses the exact official signal direction:

```systemverilog
`define PCIE_SVT_MAP_SERDES_LANE(spd, port, lane) \
  assign port.rx_p[lane] = spd.vip_port_if.ser_if.tx_datap_``lane``; \
  assign port.rx_n[lane] = spd.vip_port_if.ser_if.tx_datan_``lane``; \
  assign spd.vip_port_if.ser_if.rx_datap_``lane`` = port.tx_p[lane]; \
  assign spd.vip_port_if.ser_if.rx_datan_``lane`` = port.tx_n[lane]; \
  assign port.active_tx_transmit_clk[lane] = \
    spd.vip_port_if.ser_if.active_tx_transmit_clk_``lane``; \
  assign port.active_rx_recovered_clk[lane] = \
    spd.vip_port_if.ser_if.active_rx_recovered_clk_``lane``; \
  assign spd.vip_port_if.ser_if.tx_clk_``lane`` = port.tx_clk[lane]; \
  assign spd.vip_port_if.ser_if.rx_clk_``lane`` = port.rx_clk[lane];
```

Define the width macros in terms of the verified lane macro; do not map
inactive lanes:

```systemverilog
`define PCIE_SVT_MAP_SERDES_X4(spd, port) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 0) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 1) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 2) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 3)
`define PCIE_SVT_MAP_SERDES_X8(spd, port) \
  `PCIE_SVT_MAP_SERDES_X4(spd, port) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 4) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 5) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 6) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 7)
`define PCIE_SVT_MAP_SERDES_X16(spd, port) \
  `PCIE_SVT_MAP_SERDES_X8(spd, port) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 8) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 9) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 10) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 11) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 12) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 13) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 14) \
  `PCIE_SVT_MAP_SERDES_LANE(spd, port, 15)
```

- [ ] **Step 3: Implement official per-port parameters**

Create the VIP bootstrap as the first project source in `pcie_svt.f`, before
the integration package imports the SVT packages:

```systemverilog
`define EXPERTIO_PCIESVC_GLOBAL_SHADOW_PATH \
  pcie_svt_topology_top.global_shadow0
`define SVC_RANDOM_SEED_SCOPE pcie_svt_topology_top.global_random_seed
`include "svt_pcie.uvm.pkg"
```

Inside `pcie_svt_topology_top`, import UVM/SVT packages, include
`import_pcie_svt_uvm_pkgs.svi`, include the generated utility parameters with
the official macros, and instantiate the required shadow and seed objects:

```systemverilog
import uvm_pkg::*;
`include "uvm_macros.svh"
`include "import_pcie_svt_uvm_pkgs.svi"
`include `SVC_SOURCE_MAP_SUITE_UTIL_V(pcie_svc,PCIE,latest,svc_util_parms)
`include `SVC_SOURCE_MAP_SUITE_MODEL_MODULE(pcie_svc,Include,latest,pciesvc_parms)
int unsigned global_random_seed = 0;
pciesvc_global_shadow #(.DISPLAY_NAME("global_shadow0.")) global_shadow0();
tri1 [4:0] clkreq_n;
tri1 wake_n;
```

For each instantiated HDL agent set:

```systemverilog
defparam spd.SVT_PCIE_UI_PCIE_SPEC_VER = `SVT_PCIE_UI_PCIE_SPEC_VER_5_0;
defparam spd.SVT_PCIE_UI_PHY_INTERFACE_TYPE =
  `SVT_PCIE_UI_PHY_INTERFACE_TYPE_SERDES;
defparam spd.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE = 1'b1;
defparam spd.SVT_PCIE_UI_ENABLE_CFG_BLOCK = 1'b1;
defparam spd.SVT_PCIE_UI_CONNECT_ACTIVE_VIP = 1'b1;
defparam spd.SVT_PCIE_UI_NUM_PHYSICAL_LANES = WIDTH;
defparam spd.SVT_PCIE_UI_DEVICE_IS_ROOT = IS_ROOT;
defparam spd.SVT_PCIE_UI_HIERARCHY_NUMBER = ROOT_HIERARCHY;
```

Instantiate one global shadow at top as required by the official package and
define its path before including `svt_pcie.uvm.pkg`.

- [ ] **Step 4: Publish explicit virtual interfaces to UVM**

After HDL construction, set handles with stable keys rather than relying on
the two-ended official example naming:

```systemverilog
initial begin
  primary_rc0_spd.update_if_variables(4'h0, 0,
    "uvm_test_top", "uvm_test_top");
  uvm_config_db#(svt_pcie_vif)::set(null, "uvm_test_top",
    "primary_rc0_vif", primary_rc0_if);
end
```

Use `primary_rc0_vif`, `primary_rc1_vif`, and `primary_ep0_vif` through
`primary_ep3_vif`. Peer keys use the `peer_` prefix.

Use Unified port side `4'h0` for every RC and `4'h1` for every Endpoint.
Assign link IDs `0..4` using the physical-link table from Task 9. After all
config-db publication initial blocks have executed, start UVM exactly once:

```systemverilog
initial begin
  repeat (100) #0;
  run_test();
end
```

- [ ] **Step 5: Elaborate all three placeholder topologies**

After preparing PLI objects as in Task 1, run three separate build directories:

```bash
for item in x16:PCIE_TOPO_EP_X16 x8:PCIE_TOPO_EP_2X8 switch:PCIE_TOPO_SWITCH_1X16_4X4; do
  name=${item%%:*}
  topo=${item#*:}
  mkdir -p "build_placeholder_${name}"
  vcs -full64 -sverilog \
    -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    +define+${topo} -f pcie_svt.f \
    -Mdir="build_placeholder_${name}/csrc" \
    -P pli.tab msglog.o \
    -o "build_placeholder_${name}/simv" \
    -l "build_placeholder_${name}/compile.log"
done
```

Expected: all three produce `simv`; there are no unresolved lane references,
multiple drivers, or width errors. Do not run these placeholder binaries.

- [ ] **Step 6: Commit HDL integration**

```bash
git add svt_pcie_integration/rtl/pcie_svt_serial_adapter.sv \
        svt_pcie_integration/rtl/pcie_svt_vip_bootstrap.sv \
        svt_pcie_integration/rtl/pcie_svt_topology_top.sv \
        svt_pcie_integration/sim/pcie_svt.f
git commit -m "feat: instantiate topology-selected SVT PCIe ports"
```

### Task 6: Create one-agent UVM port environments

**Files:**
- Create: `svt_pcie_integration/uvm/pcie_svt_virtual_sequencer.sv`
- Create: `svt_pcie_integration/uvm/pcie_svt_port_env.sv`
- Create: `svt_pcie_integration/uvm/pcie_svt_env.sv`
- Create: `svt_pcie_integration/uvm/pcie_svt_base_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`

- [ ] **Step 1: Write an elaboration test that requires exact port counts**

In `pcie_svt_base_test::end_of_elaboration_phase`, assert:

```systemverilog
if (env.active_primary_count() != `PCIE_SVT_ACTIVE_PORTS)
  `uvm_fatal("TOPOLOGY", $sformatf("created %0d primary ports, expected %0d",
    env.active_primary_count(), `PCIE_SVT_ACTIVE_PORTS))
```

Expected initially: compile failure because the environment does not exist.

- [ ] **Step 2: Implement the one-agent wrapper**

`pcie_svt_port_env` obtains `vif` and `profile`, then creates exactly one
`svt_pcie_device_agent`:

```systemverilog
cfg = svt_pcie_device_configuration::type_id::create("cfg", this);
cfg.set_initial_values_via_unified_vif(1, vif);
apply_profile_to_cfg(profile, cfg);
status = svt_pcie_device_status::type_id::create("status");
uvm_config_db#(svt_pcie_device_configuration)::set(this,"agent","cfg",cfg);
uvm_config_db#(svt_pcie_device_status)::set(this,"agent","shared_status",status);
agent = svt_pcie_device_agent::type_id::create("agent", this);
```

`apply_profile_to_cfg()` sets `pcie_spec_ver`, calls
`set_link_width_values(profile.link_width,
profile.link_width, profile.link_width)` (the R-2020.12 width-vector macros
encode x4/x8/x16 as `4`, `8`, and `16`), calls
`set_link_speed_values()` with Gen1-through-selected-Gen bits plus matching
target/expected speed, and enables
`pcie_cfg.enable_multi_endpoint_mode` for Endpoint BAR modeling. It maps only
documented configuration controls that exist in R-2020.12: ATS maps to
`pcie_cfg.dut_capabilities.enable_ats_support`; SR-IOV/PRI/PASID are expressed
through the Endpoint configuration-space image and the official enumeration
controls, not invented `dut_capabilities` fields. If a capability needs further
SVT behavior beyond config-TLP response, add that mapping only after locating
the exact R-2020.12 API and a failing focused test.

- [ ] **Step 3: Implement the topology environment and registry**

Create only the profile-selected ports. In `connect_phase`, populate the
top-level virtual sequencer:

```systemverilog
vseqr.port_seqr[index] = port[index].agent.virt_seqr;
vseqr.port_status[index] = port[index].status;
vseqr.port_profile[index] = port[index].profile;
vseqr.active_port[index] = 1'b1;
```

Use ten bounded global slots so the largest peer build can register all ten
agents without aliasing: primary indices `0..4`, peer indices `5..9`. Define
`PCIE_SVT_MAX_PORTS=10` and named indices (`PRIMARY_RC0`, `PRIMARY_EP0` through
`PRIMARY_EP3`, `PEER_PORT0` through `PEER_PORT4`) in the profile package;
every sequence uses those constants. `active_primary_count()` examines only
`0..4`; link tables explicitly pair one primary index with one peer index.

- [ ] **Step 4: Parse and apply `PCIE_GEN` before creating profiles**

```systemverilog
string gen_arg;
int unsigned pcie_gen;
if (!$value$plusargs("PCIE_GEN=%s", gen_arg) ||
    $sscanf(gen_arg, "%d", pcie_gen) != 1 ||
    !(pcie_gen inside {4,5}))
  `uvm_fatal("PCIE_GEN", "Required +PCIE_GEN must be 4 or 5")
profiles.build_for_topology(compiled_topology(), pcie_gen);
```

- [ ] **Step 5: Run topology elaboration tests**

Run each compiled placeholder binary with `+UVM_TESTNAME=pcie_svt_base_test
+PCIE_GEN=4 +PCIE_COMPILE_ONLY=1`. In `run_phase`, the test raises an objection,
checks the port count, and immediately drops it when `PCIE_COMPILE_ONLY` is
present, before reset/link activity.

Expected: UVM topology contains 1, 2, and 5 `svt_pcie_device_agent` instances.
Also run once without `PCIE_GEN` and once with `+PCIE_GEN=3`; both must end in
the explicit `PCIE_GEN` fatal.

- [ ] **Step 6: Commit the UVM hierarchy**

```bash
git add svt_pcie_integration/uvm
git commit -m "feat: add topology-selected SVT PCIe environments"
```

### Task 7: Preload SVT configuration spaces and BAR sizing behavior

**Files:**
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_cfg_space_init_seq.sv`
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_all_cfg_spaces_init_vseq.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_virtual_sequencer.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_base_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`

- [ ] **Step 1: Write a failing backdoor read-back test**

For an Endpoint peer profile, initialize then read DWORD 0 and require:

```systemverilog
if (readback !== {profile.functions[0].device_id,
                  profile.functions[0].vendor_id})
  `uvm_error("CFG_INIT", $sformatf(
    "%s PF0 DW0 got %08h", profile.port_id, readback))
```

Also run `svt_pcie_target_app_service_get_bar_ro_map_sequence` for BAR0, BAR2,
and BAR4 and require `01ff_ffff`, `0000_ffff`, and `0000_ffff`. Expected before
implementation: sequence type or read-back failure.

- [ ] **Step 2: Implement configuration database writes and reads**

For each implemented function and each builder-marked DWORD:

```systemverilog
req = svt_pcie_cfg_database_service::type_id::create("req");
start_item(req, -1, port_seqr.cfg_database_seqr);
if (!req.randomize() with {
      service_type == svt_pcie_cfg_database_service::WRITE_CFG_DWORD;
      function_num == local::function_num;
      dword_addr == local::dw_addr;
      byte_enables == 4'hf;
      dword_data == local::value;
    }) `uvm_fatal("CFG_INIT", "cfg database request randomization failed")
finish_item(req);
if (req.command_status != `SVT_PCIE_CFG_DATABASE_STATUS_SUCCESSFUL)
  `uvm_fatal("CFG_INIT", "cfg database write failed")
```

Use the same request class with `READ_CFG_DWORD` for Vendor/Device, Header,
Capability Pointer, PCIe Capability header, and every BAR low/high DWORD.

- [ ] **Step 3: Program Endpoint Target App BAR maps**

For BAR0, BAR2, and BAR4 start:

```systemverilog
set_map = svt_pcie_target_app_service_set_bar_ro_map_sequence::type_id::create(
  $sformatf("set_bar%0d_map", bar));
if (!set_map.randomize() with {
      bdf_num == local::bdf;
      bar_num == local::bar;
      data == local::ro_map;
    }) `uvm_fatal("BAR_MAP", "BAR map randomization failed")
set_map.start(port_seqr.target_seqr[0]);
```

Fail with `uvm_fatal` before `start()` if `target_seqr.exists(0)` is false.

Enable `cfg.pcie_cfg.enable_multi_endpoint_mode = 1` before agent creation.
For a single PF, use BDF `16'h0000` in the local Endpoint Target App model;
do not use the later enumerated bus number for backdoor setup.

Program and read back the read-only map for both DWORDs of every 64-bit BAR
pair. For the approved sub-4-GiB apertures, use these maps:

```text
BAR0 low/high: 01ff_ffff / 0000_0000
BAR2 low/high: 0000_ffff / 0000_0000
BAR4 low/high: 0000_ffff / 0000_0000
```

The low map preserves the `0xC` 64-bit/Prefetchable attribute bits on sizing
reads. A zero upper RO map leaves the paired high DWORD writable during the
all-ones sizing probe, producing the required `ffff_ffff` high sizing result.

- [ ] **Step 4: Initialize all active ports concurrently under reset**

`pcie_svt_all_cfg_spaces_init_vseq` forks one child per active primary and peer
port and waits for all children. The top reset remains asserted throughout.
Each child is enclosed by a `1ms` watchdog and fatals with port/function/DWORD
context on timeout. After join, emit one `CFG_INIT_DONE port=<id>` line per
port. In `pcie_svt_base_test::build_phase`, also install a last-resort whole
test timeout:

```systemverilog
uvm_root::get().set_timeout(30ms, 1'b1);
```

- [ ] **Step 5: Run the configuration initialization test**

Use the x16 peer build, stop before link release with
`+PCIE_CFG_INIT_ONLY=1`, and verify:

```text
CFG_INIT_DONE port=rc0
CFG_INIT_DONE port=peer_ep0
BAR_MAP_CHECK port=peer_ep0 bar=0 data=01ffffff
BAR_MAP_CHECK port=peer_ep0 bar=2 data=0000ffff
BAR_MAP_CHECK port=peer_ep0 bar=4 data=0000ffff
```

Expected: zero UVM errors/fatals.

- [ ] **Step 6: Commit configuration initialization**

```bash
git add svt_pcie_integration/uvm
git commit -m "feat: initialize SVT PCIe configuration spaces"
```

### Task 8: Add the peer harness and prove one x16 Gen4 link

**Files:**
- Create: `svt_pcie_integration/rtl/pcie_svt_peer_harness.sv`
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_link_bringup_seq.sv`
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_all_links_bringup_vseq.sv`
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_peer_smoke_vseq.sv`
- Modify: `svt_pcie_integration/rtl/pcie_svt_topology_top.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_base_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`

- [ ] **Step 1: Write the bounded L0 assertion first**

The peer smoke must fail if either end is not L0 before the timeout:

```systemverilog
time link_timeout = 3ms;
svt_pcie_pl_status::link_speed_enum expected_speed =
  (profile.max_gen == 5) ? svt_pcie_pl_status::SPEED_32_0G :
                           svt_pcie_pl_status::SPEED_16_0G;
fork
  begin
    wait (primary_status.pcie_status.pl_status.link_up &&
          peer_status.pcie_status.pl_status.link_up &&
          primary_status.pcie_status.pl_status.ltssm_state == svt_pcie_types::L0 &&
          peer_status.pcie_status.pl_status.ltssm_state == svt_pcie_types::L0);
    reached_l0 = 1;
  end
  begin
    #(link_timeout);
  end
join_any
disable fork;
if (!reached_l0)
  `uvm_fatal("LINK_TIMEOUT", $sformatf(
    "primary=%s peer=%s primary_state=%s peer_state=%s primary_speed=%s peer_speed=%s primary_width=%0d peer_width=%0d expected_speed=%s expected_width=%0d",
    primary_profile.port_id, peer_profile.port_id,
    primary_status.pcie_status.pl_status.ltssm_state.name(),
    peer_status.pcie_status.pl_status.ltssm_state.name(),
    primary_status.pcie_status.pl_status.current_speed.name(),
    peer_status.pcie_status.pl_status.current_speed.name(),
    primary_status.pcie_status.pl_status.negotiated_link_width,
    peer_status.pcie_status.pl_status.negotiated_link_width,
    expected_speed.name(), profile.link_width))
if (primary_status.pcie_status.pl_status.current_speed != expected_speed ||
    peer_status.pcie_status.pl_status.current_speed != expected_speed ||
    primary_status.pcie_status.pl_status.negotiated_link_width != profile.link_width ||
    peer_status.pcie_status.pl_status.negotiated_link_width != profile.link_width)
  `uvm_fatal("LINK_RESULT", "negotiated speed or width does not match profile")
```

Expected before peer wiring/bring-up: timeout with both port IDs in the message.

- [ ] **Step 2: Connect the peer through two adapters**

In peer mode, do not call the official direct SER-SER macro. Route signals
through the framework's vector interfaces:

```systemverilog
assign peer_port.tx_p = primary_port.rx_p;
assign peer_port.tx_n = primary_port.rx_n;
assign primary_port.tx_p = peer_port.rx_p;
assign primary_port.tx_n = peer_port.rx_n;
```

Map the primary and peer scalar SVT fields independently with
`PCIE_SVT_MAP_SERDES_X16`. Cross-connect monitor clocks exactly as the official
example does: each side's `rx_clk_N` receives the opposite
`active_tx_transmit_clk_N`, and each `tx_clk_N` receives the opposite
`active_rx_recovered_clk_N`.

- [ ] **Step 3: Implement the single-port link-enable wrapper**

```systemverilog
link_en_seq = svt_pcie_dl_service_set_link_en_sequence::type_id::create(
  {port_id,"_link_en"});
if (!link_en_seq.randomize() with { enable == 1'b1; })
  `uvm_fatal("LINK_EN", {port_id, ": randomization failed"})
link_en_seq.start(port_seqr.pcie_virt_seqr.dl_seqr);
```

Use the actual `svt_pcie_device_virtual_sequencer` hierarchy confirmed by the
Task 1 compile probe. If optimized compile exposes `mac_virt_seqr.dl_seqr`
instead, change this one wrapper only; callers must not reference the internal
SVT path.

- [ ] **Step 4: Release reset only after initialization**

Publish `virtual pcie_svt_reset_if` as `reset_vif` from the HDL top. The peer smoke
sequence performs:

```systemverilog
cfg_init.start(p_sequencer);
reset_vif.release_all();
all_links_bringup.start(p_sequencer);
```

The HDL top starts with reset asserted and never releases it from an autonomous
`initial #delay` block.

- [ ] **Step 5: Run the first green link test**

Build with:

```bash
mkdir -p build_peer_x16
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_EP_X16 +define+PCIE_USE_SVT_PEER \
  -f pcie_svt.f -Mdir=build_peer_x16/csrc \
  -P pli.tab msglog.o -o build_peer_x16/simv \
  -l build_peer_x16/compile.log
./build_peer_x16/simv +UVM_TESTNAME=pcie_svt_base_test +PCIE_GEN=4 \
  -l build_peer_x16/sim_gen4.log
```

Expected:

```text
LINK_PASS primary=rc0 peer=peer_ep0 width=16 speed=16GT/s
UVM_ERROR : 0
UVM_FATAL : 0
```

- [ ] **Step 6: Commit first link-up support**

```bash
git add svt_pcie_integration/rtl svt_pcie_integration/uvm
git commit -m "feat: bring up an SVT peer Serial link"
```

### Task 9: Scale peer bring-up to two x8 and five switch-facing links

**Files:**
- Modify: `svt_pcie_integration/rtl/pcie_svt_peer_harness.sv`
- Modify: `svt_pcie_integration/rtl/pcie_svt_topology_top.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_profile_set.sv`
- Modify: `svt_pcie_integration/uvm/sequences/pcie_svt_all_links_bringup_vseq.sv`
- Modify: `svt_pcie_integration/uvm/sequences/pcie_svt_peer_smoke_vseq.sv`

- [ ] **Step 1: Add simultaneous-link assertions before wiring**

For every active physical link, track a bit and require all bits:

```systemverilog
bit link_passed[5];
int expected_links = topology == PCIE_SVT_TOPO_SWITCH ? 5 :
                     topology == PCIE_SVT_TOPO_EP_2X8 ? 2 : 1;
for (int i=0; i<expected_links; i++)
  if (!link_passed[i])
    `uvm_error("LINK_SET", $sformatf("physical link %0d did not pass", i))
```

Expected: x8 and switch topology tests fail because only the first link is
wired.

- [ ] **Step 2: Add x8 peer ports and clocks**

Instantiate two peer Endpoint agents and two independent vector cross-connects.
Give links root hierarchies `0` and `1`. Emit one `LINK_PASS` line for each.

- [ ] **Step 3: Add the switch-facing peer set**

Instantiate:

```text
primary RC0 x16 <-> peer EP-USP x16
primary EP0 x4  <-> peer RC-DSP0 x4
primary EP1 x4  <-> peer RC-DSP1 x4
primary EP2 x4  <-> peer RC-DSP2 x4
primary EP3 x4  <-> peer RC-DSP3 x4
```

Each physical link has a unique HDL link ID and peer hierarchy. The four
primary Endpoint profiles stay in production root hierarchy 0; only the peer
RC registry treats their validation connections as independent roots.

- [ ] **Step 4: Run Gen4 multi-link tests**

```bash
./build_peer_x8/simv +UVM_TESTNAME=pcie_svt_base_test +PCIE_GEN=4 \
  -l build_peer_x8/sim_gen4.log
./build_peer_switch/simv +UVM_TESTNAME=pcie_svt_base_test +PCIE_GEN=4 \
  -l build_peer_switch/sim_gen4.log
```

Expected: two x8 `LINK_PASS` lines for the first test; one x16 and four x4
`LINK_PASS` lines for the second; zero UVM errors/fatals.

- [ ] **Step 5: Verify every expected port was actually checked**

```bash
test "$(grep -c '^.*LINK_PASS' build_peer_x8/sim_gen4.log)" -eq 2
test "$(grep -c '^.*LINK_PASS' build_peer_switch/sim_gen4.log)" -eq 5
grep -q 'width=16 speed=16GT/s' build_peer_switch/sim_gen4.log
test "$(grep -c 'width=4 speed=16GT/s' build_peer_switch/sim_gen4.log)" -eq 4
```

- [ ] **Step 6: Commit multi-link peer support**

```bash
git add svt_pcie_integration/rtl svt_pcie_integration/uvm
git commit -m "feat: validate all SVT PCIe topology links"
```

### Task 10: Add reusable enumeration and post-enumeration sequences

**Files:**
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_topology_enumeration_vseq.sv`
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_post_enum_enable_vseq.sv`
- Modify: `svt_pcie_integration/uvm/sequences/pcie_svt_peer_smoke_vseq.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`

- [ ] **Step 1: Add a peer Endpoint enumeration/BAR sizing assertion**

After L0 on the x16 peer link, run the official Endpoint enumeration sequence
from primary RC0. Then issue sizing writes/reads and require:

```systemverilog
expect_cfg_dw("BAR0 sizing", 12'h010, 32'hfe00_000c);
expect_cfg_dw("BAR1 sizing", 12'h014, 32'hffff_ffff);
expect_cfg_dw("BAR2 sizing", 12'h018, 32'hffff_000c);
expect_cfg_dw("BAR3 sizing", 12'h01c, 32'hffff_ffff);
expect_cfg_dw("BAR4 sizing", 12'h020, 32'hffff_000c);
expect_cfg_dw("BAR5 sizing", 12'h024, 32'hffff_ffff);
```

Expected before enumeration wrapper implementation: test cannot invoke the
topology operation.

- [ ] **Step 2: Implement topology dispatch**

Use the official sequence types:

```systemverilog
case (topology)
  PCIE_SVT_TOPO_EP_X16:
    begin
      ep_seq[0] = svt_pcie_device_virtual_ep_enumeration_sequence::type_id::create(
        "ep_enumeration_0");
      if (!ep_seq[0].randomize() with {
            device_parms.root_hierarchy == 0;
            device_parms.min_pref_mem_base_addr == 64'h0000_0001_0000_0000;
          }) `uvm_fatal("ENUM", "x16 Endpoint enumeration randomization failed")
      ep_seq[0].start(primary_rc_seqr[0]);
    end
  PCIE_SVT_TOPO_EP_2X8:
    fork
      begin
        ep_seq[0] = svt_pcie_device_virtual_ep_enumeration_sequence::type_id::create(
          "ep_enumeration_0");
        if (!ep_seq[0].randomize() with {
              device_parms.root_hierarchy == 0;
              device_parms.min_pref_mem_base_addr == 64'h0000_0001_0000_0000;
            }) `uvm_fatal("ENUM", "x8 root 0 enumeration randomization failed")
        ep_seq[0].start(primary_rc_seqr[0]);
      end
      begin
        ep_seq[1] = svt_pcie_device_virtual_ep_enumeration_sequence::type_id::create(
          "ep_enumeration_1");
        if (!ep_seq[1].randomize() with {
              device_parms.root_hierarchy == 1;
              device_parms.min_pref_mem_base_addr == 64'h0000_0002_0000_0000;
            }) `uvm_fatal("ENUM", "x8 root 1 enumeration randomization failed")
        ep_seq[1].start(primary_rc_seqr[1]);
      end
    join
  PCIE_SVT_TOPO_SWITCH: begin
    sw_seq = svt_pcie_device_virtual_switch_enumeration_sequence::type_id::create(
      "switch_enumeration");
    if (!sw_seq.randomize() with {
          switch_parms.enumerate_device_beneath_dsp == 1'b1;
          switch_parms.root_hierarchy == 0;
        }) `uvm_fatal("ENUM", "switch enumeration randomization failed")
    sw_seq.start(primary_rc_seqr[0]);
  end
endcase
```

The production switch branch is compile-covered but is not run in peer mode,
because the peer harness is not a forwarding switch.

Wrap each official enumeration `start()` in `fork...join_any` with a `3ms`
timeout branch, `disable fork` afterward, and fatal with topology,
root-hierarchy, and current link status if it expires. The same bounded wrapper
is used for the five independent RC/EP enumeration operations in switch peer
mode; no configuration-completion wait is unbounded.

- [ ] **Step 3: Implement post-enumeration dependency-safe enable**

Read-modify-write the Command register to set Memory Space Enable and Bus
Master Enable when requested. Walk the already validated standard capability
list from byte `0x34` and the extended list from `0x100`, rejecting a repeated,
unaligned, or out-of-range next pointer. Record bases by capability ID, then
enable MSI/MSI-X, SR-IOV, ATS, PRI, PASID, and AER only when the profile both
advertises and requests them. Each config transaction completes through the
official sequence before the next is issued, and the enclosing post-enum stage
has the same `3ms` timeout/fatal pattern as enumeration. Before any write
enforce:

```systemverilog
if ((enable_pri || enable_pasid) && !enable_ats)
  `uvm_fatal("POST_ENUM", "PRI/PASID enable requires ATS enable")
```

- [ ] **Step 4: Run the peer enumeration smoke tests**

Run the x16 peer and two-x8 peer at Gen4. Expected: each peer Endpoint returns
the approved BAR sizing values, receives assigned aligned BAR bases, and ends
with Memory Space Enable and Bus Master Enable set. For the switch-facing peer
set, run four independent peer-RC-to-primary-EP enumeration smokes; do not call
the switch enumeration sequence.

- [ ] **Step 5: Compile-cover the real-switch branch**

Build `PCIE_TOPO_SWITCH_1X16_4X4` without peers and with
`+PCIE_COMPILE_ONLY=1`. Expected: the official switch enumeration class,
control fields, status handles, and post-enumeration sequence all compile and
elaborate even though no link is run.

- [ ] **Step 6: Commit enumeration support**

```bash
git add svt_pcie_integration/uvm
git commit -m "feat: add SVT PCIe enumeration startup stages"
```

### Task 11: Run the full Gen4/Gen5 validation matrix

**Files:**
- Modify only if a failing test demonstrates a production defect in the files
  named by that failure.
- Record evidence outside Git in each remote build directory's `compile.log`
  and `sim.log`.

- [ ] **Step 1: Refresh a clean remote worktree and PLI artifacts**

Create a new `SVT_REMOTE_WORK`, rsync the committed tree, and regenerate
`svc_util_parms.h`, `msglog.o`, and `pli.tab`. Do not reuse binaries from prior
tasks.

- [ ] **Step 2: Build the three placeholder binaries**

From `svt_pcie_integration/sim`, run:

```bash
for item in x16:PCIE_TOPO_EP_X16 x8:PCIE_TOPO_EP_2X8 switch:PCIE_TOPO_SWITCH_1X16_4X4; do
  name=${item%%:*}; topo=${item#*:}
  mkdir -p "build_placeholder_${name}"
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    +define+${topo} -f pcie_svt.f \
    -Mdir="build_placeholder_${name}/csrc" -P pli.tab msglog.o \
    -o "build_placeholder_${name}/simv" \
    -l "build_placeholder_${name}/compile.log"
done
```

Expected: three successful compile/elaborations.

- [ ] **Step 3: Build the three peer binaries**

Build once per topology with `PCIE_USE_SVT_PEER`; generation remains a runtime
plusarg:

```bash
for item in x16:PCIE_TOPO_EP_X16 x8:PCIE_TOPO_EP_2X8 switch:PCIE_TOPO_SWITCH_1X16_4X4; do
  name=${item%%:*}; topo=${item#*:}
  mkdir -p "build_peer_${name}"
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    +define+PCIE_USE_SVT_PEER +define+${topo} -f pcie_svt.f \
    -Mdir="build_peer_${name}/csrc" -P pli.tab msglog.o \
    -o "build_peer_${name}/simv" -l "build_peer_${name}/compile.log"
done
```

Expected: three successful compile/elaborations.

- [ ] **Step 4: Run six simulations**

```bash
for gen in 4 5; do
  ./build_peer_x16/simv +UVM_TESTNAME=pcie_svt_base_test +PCIE_GEN=$gen \
    -l "build_peer_x16/sim_gen${gen}.log"
  ./build_peer_x8/simv +UVM_TESTNAME=pcie_svt_base_test +PCIE_GEN=$gen \
    -l "build_peer_x8/sim_gen${gen}.log"
  ./build_peer_switch/simv +UVM_TESTNAME=pcie_svt_base_test +PCIE_GEN=$gen \
    -l "build_peer_switch/sim_gen${gen}.log"
done
```

Expected Gen4 speed is 16 GT/s; expected Gen5 speed is 32 GT/s.

- [ ] **Step 5: Programmatically gate every log**

```bash
for log in build_peer_x16/sim_gen{4,5}.log \
           build_peer_x8/sim_gen{4,5}.log \
           build_peer_switch/sim_gen{4,5}.log; do
  ! grep -Eq 'UVM_(ERROR|FATAL)[^:]*:[[:space:]]*[1-9]' "$log"
  grep -q 'SVT_PCIE_PEER_SMOKE_PASS' "$log"
done
test "$(grep -c 'LINK_PASS' build_peer_x16/sim_gen4.log)" -eq 1
test "$(grep -c 'LINK_PASS' build_peer_x8/sim_gen4.log)" -eq 2
test "$(grep -c 'LINK_PASS' build_peer_switch/sim_gen4.log)" -eq 5
test "$(grep -c 'LINK_PASS' build_peer_x16/sim_gen5.log)" -eq 1
test "$(grep -c 'LINK_PASS' build_peer_x8/sim_gen5.log)" -eq 2
test "$(grep -c 'LINK_PASS' build_peer_switch/sim_gen5.log)" -eq 5
```

Also grep every log for `BAR_SIZING_PASS`. A link-only pass is not accepted if
the Endpoint configuration-space checks failed.

- [ ] **Step 6: Diagnose any failure before editing**

If any gate fails, invoke `superpowers:systematic-debugging`. Preserve the
first failing log, identify whether the cause is HDL mapping, reset timing,
profile/SVT mismatch, configuration-space setup, or an R-2020.12 API mismatch,
then add the smallest regression assertion before changing production code.

### Task 12: Finish documentation and perform final review

**Files:**
- Modify: `svt_pcie_integration/sim/README.md`
- Modify: `svt_pcie_integration/sim/pcie_svt.f`
- Review: all files under `svt_pcie_integration/`

- [ ] **Step 1: Document all public build selections**

The README must contain these three placeholder examples and the peer variant:

```text
+define+PCIE_TOPO_EP_X16
+define+PCIE_TOPO_EP_2X8
+define+PCIE_TOPO_SWITCH_1X16_4X4
+define+PCIE_USE_SVT_PEER
```

It must explicitly say exactly one topology macro is required and
`PCIE_USE_SVT_PEER` is optional.

- [ ] **Step 2: Document runtime controls and result boundaries**

Include:

```text
+PCIE_GEN=4  -> all active links target 16 GT/s
+PCIE_GEN=5  -> all active links target 32 GT/s
```

State that placeholder builds prove compile/elaboration, peer builds prove
independent physical link integration, and only the real DUT can prove
USP/DSP enumeration and switch forwarding.

- [ ] **Step 3: Run repository hygiene checks**

```bash
git diff --check
rg -n 'ghp_|password[[:space:]]*=|credential|access[_-]?token' \
  svt_pcie_integration \
  && exit 1 || true
find svt_pcie_integration -type f -size +1M -print
git status --short
```

Expected: no whitespace errors, no credentials, no copied commercial source,
and only intended files changed. `motd.legal-displayed` remains untracked and
unmodified.

- [ ] **Step 4: Run final verification from a clean remote copy**

Rerun the exact placeholder build loop, peer build loop, six-run loop, and log
gates from Task 11 after the documentation/file-list edits. Use
`superpowers:verification-before-completion` before reporting success.

- [ ] **Step 5: Request code review**

Invoke `superpowers:requesting-code-review` against the approved spec and this
plan. Resolve only evidence-backed issues, rerunning affected VCS cases.

- [ ] **Step 6: Commit final documentation**

```bash
git add svt_pcie_integration/sim/README.md \
        svt_pcie_integration/sim/pcie_svt.f
git commit -m "docs: document SVT PCIe integration usage"
```

- [ ] **Step 7: Prepare branch handoff**

Use `superpowers:finishing-a-development-branch`. Do not push, merge, delete a
worktree, or modify a remote branch without the user's explicit choice at that
handoff.
