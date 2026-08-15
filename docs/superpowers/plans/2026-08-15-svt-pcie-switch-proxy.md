# SVT PCIe Switch Proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and prove a verification-only 1x16 USP plus 4x4 DSP PCIe Switch Proxy that uses five full R-2020.12 Serial SVT links, dynamically enumerates four downstream Endpoints, and forwards the approved eight traffic paths.

**Architecture:** Five Proxy-side full SVT Device Agents terminate the Serial links. A public `svt_pcie_tl_callback::pre_tlp_out_put` captures each received TLP and sets `drop=1`; per-port adapters translate clones to the repository-owned `pcie_tl_tlp` representation and reinject egress clones through the public `svt_pcie_agent::tlp_seqr`. An extended `pcie_tl_switch` owns Type-1 configuration images, dynamic BDF/window routing, Type-1-to-Type-0 conversion, and Completion return paths. The official SVT switch enumeration sequence remains the only allocator of final bus numbers and Endpoint BAR addresses; a registry and scoreboard turn its result into deterministic traffic and exactly-once checks.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys SVT PCIe R-2020.12, repository `pcie_tl_switch`, VCS W-2024.09-SP1 on `10.11.10.53`.

---

## Execution Contract

- Run every compile and simulation on `ubuntu@10.11.10.53` through a Bash login shell.
- Use `/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work` as the isolated remote staging checkout.
- Keep `/home/ubuntu/synopsys/designware_vip_R-2020.12` read-only.
- Do not put the host password, GitHub token, license strings, or a credential-bearing URL in a file or commit.
- Stop after Task 1 if the public TL-callback/raw-TLP-sequencer probe does not meet every gate. Do not replace it with private state, hierarchical `force`, vendor-source edits, or five unrelated peer links.
- Keep Endpoint BAR0/1 at 32 MiB and BAR2/3 plus BAR4/5 at 64 KiB; all three pairs are 64-bit Prefetchable.

Prepare the remote staging checkout once:

```bash
ssh ubuntu@10.11.10.53 'bash -lc "mkdir -p /home/ubuntu/pcie-svt-switch-proxy.20260815"'
rsync -a --exclude=.git --exclude='build*' --exclude='*.log' \
  ./ ubuntu@10.11.10.53:/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/
```

For all SVT builds, first run the PLI preparation commands already documented in `svt_pcie_integration/sim/README.md`, with:

```bash
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT="$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12"
```

## File Structure

- Create `svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.f`: isolated public-API probe file list.
- Create `svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv`: two-link TL callback/drop/raw-sequence and single-response probe.
- Create `pcie_tl_vip/src/pcie_tl_switch_pkg.sv`: lightweight switch-only package without `host_mem_pkg`.
- Create `svt_pcie_integration/sim/pcie_tl_switch_unit.f`: standalone switch-core unit-test file list.
- Create `svt_pcie_integration/sim/pcie_tl_switch_proxy_unit_test.sv`: Type-1, routing, window, and outstanding-table tests.
- Modify `pcie_tl_vip/src/types/pcie_tl_types.sv`: exact non-posted key and switch routing metadata.
- Modify `pcie_tl_vip/src/switch/pcie_tl_switch_config.sv`: one-USP/four-DSP identity and dynamic-enumeration defaults.
- Modify `pcie_tl_vip/src/switch/pcie_tl_switch_port.sv`: complete minimal Type-1 configuration image.
- Modify `pcie_tl_vip/src/switch/pcie_tl_switch_fabric.sv`: 64-bit Prefetchable and exact BDF routing.
- Modify `pcie_tl_vip/src/switch/pcie_tl_switch.sv`: local responder, Type conversion, and Completion ownership.
- Create `svt_pcie_integration/uvm/pcie_svt_tlp_converter.sv`: lossless supported-class conversion.
- Create `svt_pcie_integration/uvm/pcie_svt_switch_tl_callback.sv`: public receive capture and suppression ownership.
- Create `svt_pcie_integration/uvm/sequences/pcie_svt_raw_tlp_sequence.sv`: raw cloned-TLP injection through the public TL sequencer.
- Create `svt_pcie_integration/uvm/pcie_svt_switch_port_adapter.sv`: TL-callback-to-switch ingress/egress bridge.
- Create `svt_pcie_integration/uvm/pcie_svt_switch_scoreboard.sv`: signature, route, duplicate, drop, and Completion checks.
- Create `svt_pcie_integration/uvm/pcie_svt_switch_enum_registry.sv`: dynamic USP/DSP/Endpoint enumeration result registry.
- Create `svt_pcie_integration/uvm/sequences/pcie_svt_switch_enumeration_vseq.sv`: official enumeration and registry population.
- Create `svt_pcie_integration/uvm/sequences/pcie_svt_switch_traffic_vseq.sv`: four downstream Write/Read and four upstream Write checks.
- Create `svt_pcie_integration/uvm/sequences/pcie_svt_switch_proxy_vseq.sv`: strict full-flow stage orchestration.
- Create `svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv`: proxy-only UVM test selection.
- Modify `svt_pcie_integration/uvm/pcie_svt_port_env.sv`: identify full-Device-Agent Proxy ports without selecting Application Agent mode.
- Modify `svt_pcie_integration/uvm/pcie_svt_env.sv`: build Proxy agents, switch, adapters, registry, and scoreboard.
- Modify `svt_pcie_integration/uvm/pcie_svt_virtual_sequencer.sv`: publish switch/registry/scoreboard handles.
- Modify `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`: imports and include order.
- Modify `svt_pcie_integration/uvm/sequences/pcie_svt_all_cfg_spaces_init_vseq.sv`: initialize only primary Target Apps in proxy mode.
- Modify `svt_pcie_integration/uvm/sequences/pcie_svt_all_links_bringup_vseq.sv`: concurrent five-link bring-up.
- Modify `svt_pcie_integration/uvm/pcie_svt_base_test.sv`: proxy-mode guard and test ownership.
- Modify `svt_pcie_integration/rtl/pcie_svt_topology_checks.svh`: compile-mode legality.
- Modify `svt_pcie_integration/rtl/pcie_svt_topology_top.sv`: five Proxy Unified VIP HDL instances and Serial cross-connects.
- Modify `svt_pcie_integration/sim/pcie_svt.f`: lightweight switch package source and new UVM files.
- Modify `svt_pcie_integration/sim/README.md`: reproducible proxy build, matrix, and evidence gates.

### Task 1: Prove the Public Full-Serial TL Proxy API

**Files:**
- Create: `svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.f`
- Create: `svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv`
- Reference only: R-2020.12 `class_svt_pcie_tl_callback.html`, `class_svt_pcie_tl.html`, and `class_svt_pcie_agent.html`
- Test: `svt_pcie_integration/sim/build_tl_proxy_probe/run.log`

- [ ] **Step 1: Write the compile-failing public-surface probe**

Create two real Serial x4 links: source RC to ingress Proxy EP, and egress Proxy RC to sink EP. All four UVM agents remain normal full Device Agents; assert that neither Proxy has `dut_model=RTL`, that both `pcie_agent.tl` handles exist, and that both public `pcie_agent.tlp_seqr` handles exist.

Define a nonblocking receive callback and a raw egress sequence:

```systemverilog
class tl_proxy_capture_callback extends svt_pcie_tl_callback;
  tl_proxy_bridge bridge;
  bit ingress_side;

  virtual function void pre_tlp_out_put(
      svt_pcie_tl tl, svt_pcie_tlp tlp, ref bit drop);
    svt_pcie_tlp captured;
    if ((tlp == null) || !$cast(captured, tlp.clone()))
      `uvm_fatal("TL_PROXY_PROBE", "received TLP clone failed")
    drop = 1'b1;
    bridge.capture(captured, ingress_side);
  endfunction
endclass

class tl_proxy_raw_tlp_sequence extends uvm_sequence #(svt_pcie_tlp);
  svt_pcie_tlp request;
  virtual task body();
    if (request == null)
      `uvm_fatal("TL_PROXY_PROBE", "raw request is null")
    start_item(request);
    finish_item(request);
  endtask
endclass
```

`tl_proxy_bridge` owns two unbounded `mailbox #(svt_pcie_tlp)` instances. Its `capture` function calls `try_put` on exactly one mailbox and fatals if the nonblocking put fails. Its run task uses blocking `get` and starts a fresh `tl_proxy_raw_tlp_sequence` on `egress_proxy.pcie_agent.tlp_seqr` for ingress traffic and on `ingress_proxy.pcie_agent.tlp_seqr` for reverse traffic. The callback performs no wait or sequence start. Register callbacks only on the two Proxy TL components with `uvm_callbacks#(svt_pcie_tl, svt_pcie_tl_callback)::add`.

- [ ] **Step 2: Compile to establish RED or expose the exact shipped signature**

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12 &&
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12 &&
  mkdir -p build_tl_proxy_probe &&
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    -f pcie_svt_tl_proxy_probe.f -top pcie_svt_tl_proxy_probe_top \
    -Mdir=build_tl_proxy_probe/csrc -P pli.tab msglog.o \
    -o build_tl_proxy_probe/simv -l build_tl_proxy_probe/compile.log
"'
```

Expected RED before the probe is complete: a missing probe class or a public callback/sequencer signature mismatch. Adjust only to the exact installed HTML declaration; do not inspect or copy private implementation.

- [ ] **Step 3: Add directed write and exactly-one Completion checks**

Enable link and PHY on all four full Device Agents and require both Serial pairs to reach x4 Gen4 L0. Send a one-DW Memory Write from the source RC with address `64'h0000_0000_8000_1040`, `first_dw_be=4'hf`, Tag `10'h12a`, Requester ID `16'h0000`, and payload DWORD `32'h4433_2211`. The sink TL observation callback checks every field and requires exactly one copy.

Then send a Type-0 Configuration Read of the sink Vendor/Device ID. The Proxy callbacks must suppress both Proxy Target Apps, the sink Target App must generate the only Completion, and the reverse raw-TLP sequence must return exactly one Completion to the source. Pass only with:

```systemverilog
if (sink_write_count != 1)
  `uvm_fatal("TL_PROXY_PROBE", "write count is not one")
if (source_completion_count != 1)
  `uvm_fatal("TL_PROXY_PROBE", "completion count is not one")
if ((forward_count[0] != 2) || (forward_count[1] != 1))
  `uvm_fatal("TL_PROXY_PROBE", "forward counts are not exactly once")
`uvm_info("TL_PROXY_API_PROBE_PASS",
  "public TL capture/drop and raw tlp_seqr reinjection proved on two Serial links",
  UVM_NONE)
```

Bound link and packet waits to 100 us. Print `TL_PROXY_API_PROBE_BLOCKED` before every probe-owned fatal caused by missing public handles, link timeout, clone failure, reinjection failure, payload mismatch, or exactly-once failure.

- [ ] **Step 4: Run GREEN and gate continuation**

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  ./build_tl_proxy_probe/simv -no_save +PCIE_GEN=4 +UVM_NO_RELNOTES \
    -l build_tl_proxy_probe/run.log &&
  test \"\$(grep -a -c TL_PROXY_API_PROBE_PASS build_tl_proxy_probe/run.log)\" -eq 1 &&
  ! grep -a -q TL_PROXY_API_PROBE_BLOCKED build_tl_proxy_probe/run.log &&
  grep -a -q \"UVM_WARNING :    0\" build_tl_proxy_probe/run.log &&
  grep -a -q \"UVM_ERROR :    0\" build_tl_proxy_probe/run.log &&
  grep -a -q \"UVM_FATAL :    0\" build_tl_proxy_probe/run.log
"'
```

Expected GREEN: two real Serial links, one probe pass, no blocked marker, exact packet counts, and W/E/F=0/0/0. If any gate fails, stop this plan and report the public-API limitation.

- [ ] **Step 5: Commit the proven API probe**

```bash
git add svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.f \
        svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv
git commit -m "test: prove public SVT PCIe full-Serial proxy API"
```

### Task 2: Add a Host-Memory-Free Switch Package

**Files:**
- Create: `pcie_tl_vip/src/pcie_tl_switch_pkg.sv`
- Create: `svt_pcie_integration/sim/pcie_tl_switch_unit.f`
- Create: `svt_pcie_integration/sim/pcie_tl_switch_proxy_unit_test.sv`
- Test: `svt_pcie_integration/sim/build_switch_unit/run_package.log`

- [ ] **Step 1: Write the package smoke test**

The test imports only `uvm_pkg` and `pcie_tl_switch_pkg`, creates a `pcie_tl_switch_config`, calls `init_defaults()`, and requires one USP plus four DSPs. It must not import `host_mem_pkg` or `pcie_tl_pkg`.

```systemverilog
module pcie_tl_switch_proxy_unit_top;
  import uvm_pkg::*;
  import pcie_tl_switch_pkg::*;
  initial begin
    pcie_tl_switch_config cfg = new("cfg");
    cfg.num_usp = 1;
    cfg.num_ds_ports = 4;
    cfg.init_defaults();
    if ((cfg.usp_sec_bus.size() != 1) || (cfg.ds_secondary_bus.size() != 4))
      $fatal(1, "SWITCH_PACKAGE_SMOKE_FAIL");
    $display("SWITCH_PACKAGE_SMOKE_PASS");
    $finish;
  end
endmodule
```

- [ ] **Step 2: Run RED against the absent package**

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  mkdir -p build_switch_unit &&
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -f pcie_tl_switch_unit.f \
    -top pcie_tl_switch_proxy_unit_top -o build_switch_unit/simv \
    -l build_switch_unit/compile_package_red.log
"'
```

Expected RED: `pcie_tl_switch_pkg` is not found.

- [ ] **Step 3: Create the minimal package and relative file list**

```systemverilog
package pcie_tl_switch_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "types/pcie_tl_types.sv"
  `include "types/pcie_tl_prefix.sv"
  `include "types/pcie_tl_tlp.sv"
  `include "shared/pcie_tl_fc_manager.sv"
  `include "shared/pcie_tl_link_delay_model.sv"
  `include "switch/pcie_tl_switch_config.sv"
  `include "switch/pcie_tl_switch_port.sv"
  `include "switch/pcie_tl_switch_fabric.sv"
  `include "switch/pcie_tl_switch.sv"
endpackage
```

`pcie_tl_switch_unit.f` must use paths relative to `svt_pcie_integration/sim` and compile the package before the test.

- [ ] **Step 4: Compile and run GREEN**

Run the Task 2 compile command again, then:

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  ./build_switch_unit/simv -l build_switch_unit/run_package.log &&
  grep -a -q SWITCH_PACKAGE_SMOKE_PASS build_switch_unit/run_package.log
"'
```

Expected: package smoke pass and no reference to a `host_mem` source path in `compile_package_red.log` or the GREEN compile log.

- [ ] **Step 5: Commit the isolated package**

```bash
git add pcie_tl_vip/src/pcie_tl_switch_pkg.sv \
        svt_pcie_integration/sim/pcie_tl_switch_unit.f \
        svt_pcie_integration/sim/pcie_tl_switch_proxy_unit_test.sv
git commit -m "build: isolate PCIe switch core package"
```

### Task 3: Implement Minimal Complete Type-1 Port Images

**Files:**
- Modify: `pcie_tl_vip/src/types/pcie_tl_types.sv`
- Modify: `pcie_tl_vip/src/switch/pcie_tl_switch_config.sv`
- Modify: `pcie_tl_vip/src/switch/pcie_tl_switch_port.sv`
- Modify: `svt_pcie_integration/sim/pcie_tl_switch_proxy_unit_test.sv`
- Test: `svt_pcie_integration/sim/build_switch_unit/run_type1.log`

- [ ] **Step 1: Add failing Type-1 read/write tests**

Create one USP and four DSP port objects and assert:

```systemverilog
check_eq(usp.cfg_read(12'h000), 32'h5010_20f9, "USP vendor/device");
check_eq(usp.cfg_read(12'h008), 32'h0604_0001, "bridge class/revision");
check_eq(usp.cfg_read(12'h00c) & 32'h00ff_0000,
         32'h0001_0000, "header type 1");
check_eq(usp.cfg_read(12'h034) & 32'hff, 32'h40, "PCIe cap pointer");
check_eq((usp.cfg_read(12'h040) >> 20) & 4'hf, 4'h5, "USP port type");
check_eq((dsp.cfg_read(12'h040) >> 20) & 4'hf, 4'h6, "DSP port type");
```

Write bus numbers with one-byte enables and require untouched bytes to remain unchanged. Write Command bit 1 with `be=4'b0001` and require Memory Space Enable to read back.

- [ ] **Step 2: Run RED**

Expected RED: identity, header, capability, and Command values currently read as zero.

- [ ] **Step 3: Add explicit identity and configuration state**

Add these port members:

```systemverilog
bit [15:0] bdf;
bit [15:0] vendor_id = 16'h20f9;
bit [15:0] device_id;
bit [15:0] command;
bit [15:0] status = 16'h0010;
bit [7:0] revision_id = 8'h01;
bit [23:0] class_code = 24'h060400;
bit [7:0] header_type = 8'h01;
```

Assign device `16'h5010` to the USP and `16'h5020 + dsp_index` to each DSP. Implement reads for `0x000`, `0x004`, `0x008`, `0x00c`, `0x018`, `0x020`, `0x024`, `0x028`, `0x02c`, `0x034`, and a PCIe capability at `0x040`. The PCIe Capabilities register must advertise version 2 and port type 5 for USP or 6 for DSP.

Use one helper for byte writes:

```systemverilog
function automatic bit [31:0] merge_be(
    bit [31:0] old_value, bit [31:0] new_value, bit [3:0] be);
  bit [31:0] result = old_value;
  foreach (be[i]) if (be[i]) result[i*8 +: 8] = new_value[i*8 +: 8];
  return result;
endfunction
```

Mask writes so Vendor/Device ID, Class Code, Header Type, capability ID/version, and read-only Status bits never change.

- [ ] **Step 4: Add 64-bit Prefetchable register tests and implementation**

Program:

```systemverilog
dsp.cfg_write(12'h024, 32'h1071_1001, 4'hf);
dsp.cfg_write(12'h028, 32'h0000_0001, 4'hf);
dsp.cfg_write(12'h02c, 32'h0000_0001, 4'hf);
```

Require `pref_base == 64'h0000_0001_1000_0000` and `pref_limit == 64'h0000_0001_107f_ffff`. Preserve the low-nibble 64-bit encoding in config reads and decode the base/limit using the PCIe 1 MiB granularity.

- [ ] **Step 5: Run GREEN and commit**

Expected: `TYPE1_CFG_PASS` and W/E/F=0/0/0.

```bash
git add pcie_tl_vip/src/types/pcie_tl_types.sv \
        pcie_tl_vip/src/switch/pcie_tl_switch_config.sv \
        pcie_tl_vip/src/switch/pcie_tl_switch_port.sv \
        svt_pcie_integration/sim/pcie_tl_switch_proxy_unit_test.sv
git commit -m "feat: model switch Type-1 configuration space"
```

### Task 4: Add Dynamic BDF, Window, and Completion Routing

**Files:**
- Modify: `pcie_tl_vip/src/types/pcie_tl_types.sv`
- Modify: `pcie_tl_vip/src/switch/pcie_tl_switch_fabric.sv`
- Modify: `pcie_tl_vip/src/switch/pcie_tl_switch.sv`
- Modify: `svt_pcie_integration/sim/pcie_tl_switch_proxy_unit_test.sv`
- Test: `svt_pcie_integration/sim/build_switch_unit/run_route.log`

- [ ] **Step 1: Write failing routing tests**

Test all of these cases independently:

- BDF `01:00.0` resolves only to USP.
- After USP bus register becomes primary=1, secondary=2, subordinate=6, BDFs `02:00.0` through `02:03.0` resolve to DSP0 through DSP3.
- A Configuration Type 1 request for an Endpoint on a DSP's secondary bus exits that DSP as Type 0.
- Address `64'h0000_0001_1040_0000` routes through a matching Prefetchable window even though it is above 4 GiB.
- The same address does not route when Command.MemorySpaceEnable is zero.
- An unmatched request arriving from a DSP routes to USP.
- A Completion with `{Requester ID, Tag}={16'h0000,10'h155}` returns to the recorded ingress and removes the record.
- A duplicate outstanding key and an unmatched Completion each cause one caught fatal in the directed unit test.

- [ ] **Step 2: Run RED**

Expected RED: current routing uses bus ranges or 32-bit `mem_base/mem_limit`, changes no Configuration Type, and has no outstanding table.

- [ ] **Step 3: Add exact BDF map and 64-bit address routing**

Add:

```systemverilog
typedef bit [25:0] switch_np_key_t;

function automatic switch_np_key_t switch_np_key(
    bit [15:0] requester_id, bit [9:0] tag);
  return {requester_id, tag};
endfunction
```

`pcie_tl_switch::refresh_local_bdf_map()` must set USP BDF from `sw_cfg.switch_bdf` and DSP BDFs from the current USP secondary bus plus device indices 0 through 3. `pcie_tl_switch_fabric::local_port_for_bdf(bit[15:0] target_bdf)` must return one exact port or `SWITCH_ROUTE_DROP`; duplicate matches are fatal.

For Memory routing, search both 32-bit non-Prefetchable and 64-bit Prefetchable windows only when that bridge's Command.MemorySpaceEnable is one. Reject base-greater-than-limit windows rather than treating them as a match.

- [ ] **Step 4: Add Type conversion and outstanding ownership**

Before forwarding a non-posted request, insert:

```systemverilog
switch_np_key_t key = switch_np_key(tlp.requester_id, tlp.tag);
if (outstanding_ingress.exists(key))
  `uvm_fatal("SWITCH_DUP_NP", $sformatf("requester=%04h tag=%03h",
    tlp.requester_id, tlp.tag))
outstanding_ingress[key] = ingress_port_id;
```

On Completion, look up, route, and delete that key. Never use the Completion Requester bus as a substitute for this table.

Clone a forwarded Configuration request; if its target bus equals the egress DSP secondary bus, change `TLP_CFG_RD1/TLP_CFG_WR1` to `TLP_CFG_RD0/TLP_CFG_WR0` and update `type_f`. Preserve every other field.

- [ ] **Step 5: Run GREEN and commit**

Expected: `SWITCH_ROUTE_PASS`, no uncaught severity, and an empty outstanding table at report phase.

```bash
git add pcie_tl_vip/src/types/pcie_tl_types.sv \
        pcie_tl_vip/src/switch/pcie_tl_switch_fabric.sv \
        pcie_tl_vip/src/switch/pcie_tl_switch.sv \
        svt_pcie_integration/sim/pcie_tl_switch_proxy_unit_test.sv
git commit -m "feat: route switch requests and completions dynamically"
```

### Task 5: Implement and Prove SVT TLP Conversion

**Files:**
- Create: `svt_pcie_integration/uvm/pcie_svt_tlp_converter.sv`
- Create: `svt_pcie_integration/sim/pcie_svt_tlp_converter_unit_test.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt.f`
- Test: `svt_pcie_integration/sim/build_converter/run.log`

- [ ] **Step 1: Write table-driven round-trip tests**

Create one vector each for Configuration Read/Write Type 0 and Type 1, Memory Read, Memory Write, Completion, and Completion with Data. Set non-default TC, attributes, length, address, first/last DW byte enables, Requester ID, Completer ID, 10-bit Tag, Completion Status, byte count, lower address, and payload bytes.

For every vector run:

```systemverilog
pcie_tl_tlp normalized;
svt_pcie_tlp round_trip;
if (!pcie_svt_tlp_converter::from_svt(source, normalized, reason))
  `uvm_fatal("CONVERTER", reason)
if (!pcie_svt_tlp_converter::to_svt(normalized, round_trip, reason))
  `uvm_fatal("CONVERTER", reason)
compare_supported_fields(source, round_trip);
```

Add one Message TLP negative test and require a false return with a non-empty reason.

- [ ] **Step 2: Run RED**

Expected RED: `pcie_svt_tlp_converter` is undefined.

- [ ] **Step 3: Implement explicit tuple mapping**

Use the public SVT fields `fmt`, `tlp_type`, `tc`, ordering attributes, `length`, `address`, `first_dw_be`, `last_dw_be`, `requester_id`, `completer_id`, `tag`, `completion_status`, `byte_count`, `lower_address`, and `payload`.

Map the `(tlp_type, fmt)` tuple explicitly:

- `MEM_REQ` plus no-data -> `TLP_MEM_RD`;
- `MEM_REQ` or `DMEM_REQ` plus data -> `TLP_MEM_WR`;
- `TYPE_0_CFG_REQ` plus no-data/data -> `TLP_CFG_RD0/TLP_CFG_WR0`;
- `TYPE_1_CFG_REQ` plus no-data/data -> `TLP_CFG_RD1/TLP_CFG_WR1`;
- `CPL` plus no-data/data -> `TLP_CPL/TLP_CPLD`.

Translate payload DWORDs byte-for-byte in PCIe address order. Do not use `uvm_object::compare` as the only check because the existing `pcie_tl_tlp::do_compare` does not compare payload contents.

- [ ] **Step 4: Compile and run GREEN**

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  mkdir -p build_converter &&
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    -f pcie_svt.f pcie_svt_tlp_converter_unit_test.sv \
    -top pcie_svt_tlp_converter_unit_top -Mdir=build_converter/csrc \
    -P pli.tab msglog.o -o build_converter/simv -l build_converter/compile.log &&
  ./build_converter/simv -l build_converter/run.log &&
  grep -a -q TLP_CONVERTER_PASS build_converter/run.log
"'
```

- [ ] **Step 5: Commit converter and tests**

```bash
git add svt_pcie_integration/uvm/pcie_svt_tlp_converter.sv \
        svt_pcie_integration/sim/pcie_svt_tlp_converter_unit_test.sv \
        svt_pcie_integration/sim/pcie_svt.f
git commit -m "feat: convert public SVT and switch TLP objects"
```

### Task 6: Connect TL Callback Adapters and Exactly-Once Scoreboard

**Files:**
- Create: `svt_pcie_integration/uvm/pcie_svt_switch_tl_callback.sv`
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_raw_tlp_sequence.sv`
- Create: `svt_pcie_integration/uvm/pcie_svt_switch_port_adapter.sv`
- Create: `svt_pcie_integration/uvm/pcie_svt_switch_scoreboard.sv`
- Create: `svt_pcie_integration/sim/pcie_svt_switch_adapter_unit_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`
- Test: `svt_pcie_integration/sim/build_adapter/run.log`

- [ ] **Step 1: Write failing adapter ownership tests**

Create a callback with a real adapter and invoke `pre_tlp_out_put` for a Configuration Read, Memory Write, and Completion. For each call require `drop==1`, one cloned object in the adapter capture queue, one normalized switch ingress object, and no mutation of the source object. Inject one unsupported Message and require one caught `SVT_TLP_UNSUPPORTED` fatal plus `drop_count==1`.

Connect the adapter's raw egress sequence to a unit-test `svt_pcie_tlp_sequencer` and a collecting driver. Put one object in the switch `tx_fifo`; require the driver to receive exactly one field-equal clone. This tests the same public sequencer path used by the full Serial probe.

- [ ] **Step 2: Run RED**

Expected RED: TL callback, raw sequence, adapter, and scoreboard classes are undefined.

- [ ] **Step 3: Implement the public TL callback and raw sequencer boundary**

Use:

```systemverilog
class pcie_svt_switch_tl_callback extends svt_pcie_tl_callback;
  pcie_svt_switch_port_adapter adapter;
  virtual function void pre_tlp_out_put(
      svt_pcie_tl tl, svt_pcie_tlp tlp, ref bit drop);
    adapter.capture_from_tl(tlp);
    drop = 1'b1;
  endfunction
endclass

class pcie_svt_raw_tlp_sequence extends uvm_sequence #(svt_pcie_tlp);
  svt_pcie_tlp request;
  virtual task body();
    if (request == null)
      `uvm_fatal("SVT_RAW_TLP", "request is null")
    start_item(request);
    finish_item(request);
  endtask
endclass

class pcie_svt_switch_port_adapter extends uvm_component;
  mailbox #(svt_pcie_tlp) captured_mbox;
  svt_pcie_tlp_sequencer proxy_tlp_seqr;
  pcie_tl_switch_port switch_port;
  int unsigned switch_port_id;
  function void capture_from_tl(svt_pcie_tlp tlp);
  virtual task run_phase(uvm_phase phase);
endclass
```

Implement the nonblocking capture boundary exactly once:

```systemverilog
function void pcie_svt_switch_port_adapter::capture_from_tl(
    svt_pcie_tlp tlp);
  svt_pcie_tlp captured;
  if ((tlp == null) || !$cast(captured, tlp.clone())) begin
    drop_count++;
    `uvm_fatal("SVT_TL_CAPTURE", "received TLP clone failed")
  end
  if (!captured_mbox.try_put(captured)) begin
    drop_count++;
    `uvm_fatal("SVT_TL_CAPTURE", "unbounded capture mailbox rejected TLP")
  end
  rx_count++;
endfunction
```

Construct `captured_mbox = new()` in the adapter constructor. In `run_phase`, one forked thread blocks on `captured_mbox.get`, converts the clone, and puts exactly one normalized object into `switch_port.rx_fifo`. A second thread blocks on `switch_port.tx_fifo.get`, converts to one SVT object, assigns it to a fresh `pcie_svt_raw_tlp_sequence`, and starts that sequence on `proxy_tlp_seqr`. A failed conversion or sequence start is fatal and increments no successful forwarding count.

Register one callback only on each of the five full Proxy agents' public `pcie_agent.tl` components. The callback must never be registered on a primary agent and must never call a task or start a sequence.

- [ ] **Step 4: Implement stable signatures and checks**

Define a scoreboard signature containing direction, ingress, egress, kind, Requester ID, Completer ID, Tag, address, length, first/last BE, and a 32-bit FNV-1a payload digest. Maintain expected/observed counts keyed by the full signature and a Completion key `{Requester ID, Tag}`.

Expose:

```systemverilog
function void expect_forward(int ingress, int egress, pcie_tl_tlp tlp);
function void observe_forward(int ingress, int egress, pcie_tl_tlp tlp);
function void check_empty();
```

`check_empty()` must fatal on a missing, duplicate, wrong-egress, payload-mismatch, or unmatched Completion entry.

Each adapter maintains `rx_count`, `tx_count`, `completion_count`, and `drop_count`. Its report phase emits exactly one `SWITCH_ADAPTER_REPORT port=<id> rx=<n> tx=<n> cpl=<n> drop=<n>`; a production unsupported TLP is fatal and still increments `drop_count` so the final diagnostic identifies its ingress.

- [ ] **Step 5: Run GREEN and commit**

Expected: `SWITCH_ADAPTER_PASS`, exactly three forwarded objects, and W/E/F=0/0/0.

```bash
git add svt_pcie_integration/uvm/pcie_svt_switch_tl_callback.sv \
        svt_pcie_integration/uvm/sequences/pcie_svt_raw_tlp_sequence.sv \
        svt_pcie_integration/uvm/pcie_svt_switch_port_adapter.sv \
        svt_pcie_integration/uvm/pcie_svt_switch_scoreboard.sv \
        svt_pcie_integration/sim/pcie_svt_switch_adapter_unit_test.sv \
        svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv
git commit -m "feat: bridge SVT TL callbacks through switch adapters"
```

### Task 7: Build the Compile-Selected Five-Link Proxy

**Files:**
- Modify: `svt_pcie_integration/rtl/pcie_svt_topology_checks.svh`
- Modify: `svt_pcie_integration/rtl/pcie_svt_topology_top.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_port_env.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_env.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_virtual_sequencer.sv`
- Modify: `svt_pcie_integration/uvm/sequences/pcie_svt_all_cfg_spaces_init_vseq.sv`
- Modify: `svt_pcie_integration/uvm/sequences/pcie_svt_all_links_bringup_vseq.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_base_test.sv`
- Test: `svt_pcie_integration/sim/build_switch_proxy/run_links_gen4.log`

- [ ] **Step 1: Write compile-mode and five-link RED tests**

Compile these illegal combinations and require a compile failure containing `PCIe topology contract`:

```text
PCIE_USE_SVT_SWITCH_PROXY without PCIE_TOPO_SWITCH_1X16_4X4
PCIE_USE_SVT_SWITCH_PROXY with PCIE_USE_SVT_PEER
```

For the legal peer or proxy cases, define one internal `PCIE_SVT_HAS_OPPOSING_AGENTS` macro in `pcie_svt_topology_checks.svh`. Use that internal macro for profile creation and active-opponent counts in `pcie_svt_env` and `pcie_svt_base_test`; keep `PCIE_USE_SVT_SWITCH_PROXY` for proxy-only switch/adapter construction and test selection.

Compile the legal proxy image and run Gen4. Expected RED before implementation: no Proxy VIFs or fewer than five `LINK_PASS` records.

- [ ] **Step 2: Add five opposing Unified VIP HDL instances**

Under the switch topology and `PCIE_USE_SVT_SWITCH_PROXY`, instantiate:

- `proxy_usp_spd`, Endpoint role, x16, hierarchy 0, connected to primary RC0;
- `proxy_dsp0_spd` through `proxy_dsp3_spd`, Root role, x4, hierarchies 1 through 4, connected to primary EP0 through EP3.

Use interface IDs 5 through 9, distinct display names, the existing Serial mapping macros, and the same reset bit as the primary peer on each physical link. Publish VIF keys `proxy_usp_vif` and `proxy_dsp0_vif` through `proxy_dsp3_vif`.

Update `pcie_svt_env::peer_vif_key()` so the switch topology returns those five `proxy_*_vif` keys under `PCIE_USE_SVT_SWITCH_PROXY` and retains the existing `peer_*_vif` keys under `PCIE_USE_SVT_PEER`.

- [ ] **Step 3: Build Proxy profiles and full Device Agents**

Reuse the opposing role/width/generation values from `build_peer_for_topology`, but select them when either peer or proxy mode is compiled. Add `bit is_switch_proxy` to `pcie_svt_port_env` configuration, but retain the normal full Device Agent mode:

```systemverilog
if (is_switch_proxy &&
    (cfg.dut_model == svt_pcie_device_configuration::RTL))
  `uvm_fatal("SWITCH_PROXY_CFG",
    "Serial Proxy must remain a full Device Agent")
```

Set `is_switch_proxy` to one only for indices `PCIE_SVT_PEER_PORT0` through `PCIE_SVT_PEER_PORT4` in a proxy build and to zero for all five primary indices and every non-proxy build.

In `pcie_svt_env`, create one `pcie_tl_switch` with one USP and four DSPs, five TL callbacks, five adapters, one registry, and one scoreboard only under `PCIE_USE_SVT_SWITCH_PROXY`. Set `sw_cfg.enum_mode=1` and `sw_cfg.p2p_enable=0`. Give each adapter its matching Proxy `pcie_agent.tlp_seqr` and switch port, give each callback its matching adapter, and register each callback on only that Proxy's `pcie_agent.tl`.

In `pcie_svt_all_cfg_spaces_init_vseq`, keep all ten ports in reset validation and run the normal lower-layer `REFRESH_CFG` for all ten full Device Agents. Run configuration-image programming, Multi-Endpoint BAR setup, and vendor-warning accounting only for the five primary ports. Emit one `PROXY_TARGET_CFG_SKIP` for each Proxy full Device Agent. The expected R-2020.12 warning count is four, from the four primary Endpoint Target Apps; a Proxy port must never start a Target-App BAR or completer-space sequence because the switch core owns its visible configuration and memory response behavior.

- [ ] **Step 4: Bring all five pairs up concurrently**

Extend `pcie_svt_all_links_bringup_vseq::body()` with a switch branch that validates ten agent handles, forks ten `enable_port` calls, then forks five `wait_for_pair` calls. A wait timeout on one pair must prevent enumeration.

The five expected pairs are:

```text
PCIE_SVT_PRIMARY_RC0  <-> PCIE_SVT_PEER_PORT0  x16
PCIE_SVT_PRIMARY_EP0  <-> PCIE_SVT_PEER_PORT1  x4
PCIE_SVT_PRIMARY_EP1  <-> PCIE_SVT_PEER_PORT2  x4
PCIE_SVT_PRIMARY_EP2  <-> PCIE_SVT_PEER_PORT3  x4
PCIE_SVT_PRIMARY_EP3  <-> PCIE_SVT_PEER_PORT4  x4
```

The existing `PCIE_SVT_PEER_PORT0..4` numeric slots are reused as the Proxy slots so no third index namespace is introduced; diagnostics and VIF keys call them Proxy ports in this compile mode.

- [ ] **Step 5: Compile, run, and commit**

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  mkdir -p build_switch_proxy &&
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    +define+PCIE_TOPO_SWITCH_1X16_4X4 \
    +define+PCIE_USE_SVT_SWITCH_PROXY \
    -f pcie_svt.f -top pcie_svt_topology_top \
    -Mdir=build_switch_proxy/csrc -P pli.tab msglog.o \
    -o build_switch_proxy/simv -l build_switch_proxy/compile.log &&
  ./build_switch_proxy/simv -no_save \
    +UVM_TESTNAME=pcie_svt_switch_proxy_test +PCIE_GEN=4 \
    +PCIE_LINK_ONLY +UVM_NO_RELNOTES -l build_switch_proxy/run_links_gen4.log &&
  test \"\$(grep -a -c '\[LINK_PASS\].*primary=' build_switch_proxy/run_links_gen4.log)\" -eq 5
"'
```

Expected: one x16 and four x4 `LINK_PASS`, all at 16 GT/s, W/E/F=0/0/0.

```bash
git add svt_pcie_integration/rtl/pcie_svt_topology_checks.svh \
        svt_pcie_integration/rtl/pcie_svt_topology_top.sv \
        svt_pcie_integration/uvm/pcie_svt_port_env.sv \
        svt_pcie_integration/uvm/pcie_svt_env.sv \
        svt_pcie_integration/uvm/pcie_svt_virtual_sequencer.sv \
        svt_pcie_integration/uvm/sequences/pcie_svt_all_cfg_spaces_init_vseq.sv \
        svt_pcie_integration/uvm/sequences/pcie_svt_all_links_bringup_vseq.sv \
        svt_pcie_integration/uvm/pcie_svt_base_test.sv
git commit -m "feat: instantiate five-link SVT switch proxy"
```

### Task 8: Run Official Dynamic Switch Enumeration

**Files:**
- Create: `svt_pcie_integration/uvm/pcie_svt_switch_enum_registry.sv`
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_switch_enumeration_vseq.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_virtual_sequencer.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`
- Test: `svt_pcie_integration/sim/build_switch_proxy/run_enum_gen4.log`

- [ ] **Step 1: Write registry and structure RED checks**

The registry must reject a null enumeration status, duplicate BDF, an Endpoint without a parent DSP, any non-Prefetchable/32-bit Endpoint BAR, overlapping Endpoint BARs, and a BAR outside its parent DSP Prefetchable window.

Require exactly one USP, four DSP entries, and four Endpoint entries. For each Endpoint require BAR apertures `[32 MiB, 64 KiB, 64 KiB]` at BAR indices `[0,2,4]`.

- [ ] **Step 2: Run RED after links**

Expected RED: no enumeration sequence or registry exists.

- [ ] **Step 3: Start the official sequence from primary RC0 only**

```systemverilog
svt_pcie_device_virtual_switch_enumeration_sequence enum_seq;
enum_seq = svt_pcie_device_virtual_switch_enumeration_sequence::type_id::create(
  "enum_seq");
if (!enum_seq.randomize() with {
      switch_parms.root_hierarchy == 0;
      switch_parms.enumerate_device_beneath_dsp == 1'b1;
      switch_parms.max_sw_dsp_device_number == 3;
      switch_parms.root_port_sec_bus_num == 8'h01;
      switch_parms.sw_usp_dev_num == 5'h00;
      switch_parms.sys_pref_mem_base_addr == 64'h0000_0001_0000_0000;
      switch_parms.sys_pref_mem_limit_addr == 64'h0000_0001_7fff_ffff;
    })
  `uvm_fatal("SWITCH_ENUM", "enumeration controls failed to randomize")
enum_seq.start(p_sequencer.port_seqr[PCIE_SVT_PRIMARY_RC0]);
if (enum_seq.switch_enumeration_status == null)
  `uvm_fatal("SWITCH_ENUM", "official sequence returned null status")
```

Do not preload final Endpoint BDFs, BAR bases, bridge bus numbers, or bridge windows.

- [ ] **Step 4: Populate and verify the registry**

Use `switch_enumeration_status.port_info[$]` for USP/DSP type, device, primary/secondary/subordinate buses, and window fields. Use each DSP's `ep_enumeration_status.captured_bus_number`, `captured_device_number`, `min_per_bar_address_range[0][bar]`, and `max_per_bar_address_range[0][bar]` for Endpoint function 0.

Read back each switch Type-1 bus/window register through normal RC Configuration Reads and each Endpoint BAR through normal Configuration Reads. Require Memory Space and Bus Master bits only after all structure and aperture checks pass.

Emit exactly one:

```text
SWITCH_ENUM_PASS usp=1 dsp=4 ep=4 bars=12
```

- [ ] **Step 5: Run GREEN and commit**

Run without `+PCIE_LINK_ONLY`, with `+PCIE_ENUM_ONLY`, and require five link passes, one enum pass, zero scoreboard drops, and W/E/F=0/0/0.

```bash
git add svt_pcie_integration/uvm/pcie_svt_switch_enum_registry.sv \
        svt_pcie_integration/uvm/sequences/pcie_svt_switch_enumeration_vseq.sv \
        svt_pcie_integration/uvm/pcie_svt_virtual_sequencer.sv \
        svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv
git commit -m "feat: enumerate SVT endpoints through switch proxy"
```

### Task 9: Verify Four Downstream Write/Read Paths

**Files:**
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_switch_traffic_vseq.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`
- Test: `svt_pcie_integration/sim/build_switch_proxy/run_downstream_gen4.log`

- [ ] **Step 1: Write downstream RED expectations**

For Endpoint `i`, use enumerated BAR0 base plus offset `64'h100 + i*64'h40`, Tag `10'h100+i`, and payload bytes `{8'hd0+i,8'he0+i,8'hf0+i,8'h10+i}`. Expect egress DSP `i`, one Memory Write, one Memory Read, and one Completion with matching payload.

- [ ] **Step 2: Run RED**

Expected RED: traffic stage and `DOWNSTREAM_PATH_PASS` markers do not exist.

- [ ] **Step 3: Implement four deterministic paths**

Start `svt_pcie_driver_app_mem_request_w_switch_env_enumerated_data_sequence` on primary RC0's `driver_transaction_seqr[0]`. For Endpoint `i`, constrain `root_hierarchy==0`, `target_sw_port_bar==0`, `target_sw_port_index` to the registry's official `port_info` index for DSP `i`, and `address_range_index` to the registry range containing BAR0. Constrain the inherited `transaction_type`, `tag`, and `write_payload` for the Write and Read pair. Cross-check the sequence-selected address against the registry rather than using a constant final BAR. Register expected signatures before each request and bound each read completion to 100 us.

After readback, emit:

```systemverilog
`uvm_info("DOWNSTREAM_PATH_PASS", $sformatf(
  "ep=%0d dsp=%0d bdf=%04h bar=0 addr=%016h tag=%03h",
  i, i, ep.bdf, address, 10'h100+i), UVM_NONE)
```

- [ ] **Step 4: Run GREEN**

Require exactly four downstream path passes, no unmatched request/Completion, no drop, and W/E/F=0/0/0.

- [ ] **Step 5: Commit downstream traffic**

```bash
git add svt_pcie_integration/uvm/sequences/pcie_svt_switch_traffic_vseq.sv \
        svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv
git commit -m "test: verify four downstream switch paths"
```

### Task 10: Verify Four Upstream Endpoint Writes

**Files:**
- Modify: `svt_pcie_integration/uvm/sequences/pcie_svt_switch_traffic_vseq.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_env.sv`
- Test: `svt_pcie_integration/sim/build_switch_proxy/run_upstream_gen4.log`

- [ ] **Step 1: Write upstream RED expectations**

Reserve RC receive base `64'h0000_0000_1000_0000` and offsets `i*64'h1000`. Require that this range is outside every downstream bridge window. Endpoint `i` uses Tag `10'h180+i` and payload `{8'ha0+i,8'hb0+i,8'hc0+i,8'hd0+i}`.

- [ ] **Step 2: Enable primary RC target memory explicitly**

Before traffic, start `svt_pcie_target_app_service_set_completer_space_enable_sequence` on primary RC0 `target_seqr[0]`, randomized with `io_select==0` and `data==1`. Fatal if the target sequencer is null. Record four non-overlapping receive locations in the scoreboard.

- [ ] **Step 3: Send all four Endpoint writes**

Start one Memory Write sequence on each primary Endpoint's `driver_transaction_seqr[0]`. The switch must route an address not matching a downstream window to USP. Verify both RC target-memory content and the adapter scoreboard signature, then emit one `UPSTREAM_PATH_PASS` per Endpoint.

- [ ] **Step 4: Run GREEN**

Require exactly four upstream passes plus the four downstream passes, an empty outstanding table, no scoreboard residue, zero drops, and W/E/F=0/0/0.

- [ ] **Step 5: Commit upstream traffic**

```bash
git add svt_pcie_integration/uvm/sequences/pcie_svt_switch_traffic_vseq.sv \
        svt_pcie_integration/uvm/pcie_svt_env.sv
git commit -m "test: verify four upstream switch paths"
```

### Task 11: Orchestrate One Strict Full Flow

**Files:**
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_switch_proxy_vseq.sv`
- Create: `svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_base_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`
- Test: `svt_pcie_integration/sim/build_switch_proxy/run_full_gen4.log`

- [ ] **Step 1: Write stage-order and mode RED tests**

Add strict plusargs `+PCIE_LINK_ONLY` and `+PCIE_ENUM_ONLY`, each bare and mutually exclusive. The full run omits both. Reject `pcie_svt_switch_proxy_test` unless both the switch topology and proxy macro are compiled.

- [ ] **Step 2: Implement the ordered virtual sequence**

Run exactly:

```text
CFG_INIT -> RESET_RELEASE_CHECK -> LINK_BRINGUP -> ENUMERATION -> TRAFFIC -> FINAL_CHECK
```

`CFG_INIT` starts the existing all-config-spaces sequence, which releases all five reset bits together after its hold interval. `RESET_RELEASE_CHECK` does not release a second time; it verifies `reset_vif.asserted==='0` and that all ten agents still report Link Down before link enable. Emit `SWITCH_STAGE_PASS stage=<name>` after each stage. Do not start a later child when the earlier child reports a fatal or timeout. `FINAL_CHECK` calls registry validation, scoreboard `check_empty()`, verifies switch outstanding count zero and drop count zero, and requires four downstream plus four upstream path passes.

- [ ] **Step 3: Give the proxy test sole run ownership**

`pcie_svt_switch_proxy_test::run_phase` starts only `pcie_svt_switch_proxy_vseq`. The ordinary base test retains existing x16 peer behavior; it must not also start `pcie_svt_peer_smoke_vseq` in proxy mode.

- [ ] **Step 4: Run the Gen4 default full flow**

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  ./build_switch_proxy/simv -no_save \
    +UVM_TESTNAME=pcie_svt_switch_proxy_test +PCIE_GEN=4 \
    +UVM_NO_RELNOTES -l build_switch_proxy/run_full_gen4.log &&
  test \"\$(grep -a -c '\[LINK_PASS\].*primary=' build_switch_proxy/run_full_gen4.log)\" -eq 5 &&
  test \"\$(grep -a -c '\[SWITCH_ENUM_PASS\]' build_switch_proxy/run_full_gen4.log)\" -eq 1 &&
  test \"\$(grep -a -c '\[DOWNSTREAM_PATH_PASS\]' build_switch_proxy/run_full_gen4.log)\" -eq 4 &&
  test \"\$(grep -a -c '\[UPSTREAM_PATH_PASS\]' build_switch_proxy/run_full_gen4.log)\" -eq 4
"'
```

Expected: all counts exact and final W/E/F=0/0/0.

- [ ] **Step 5: Commit orchestration**

```bash
git add svt_pcie_integration/uvm/sequences/pcie_svt_switch_proxy_vseq.sv \
        svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv \
        svt_pcie_integration/uvm/pcie_svt_base_test.sv \
        svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv
git commit -m "test: orchestrate SVT switch proxy full flow"
```

### Task 12: Run the Required Matrix and Preserve x16 Regressions

**Files:**
- Modify: `svt_pcie_integration/sim/README.md`
- Test: four `build_switch_proxy/run_full_*.log` files
- Test: four `build_peer_x16/run_*.log` files

- [ ] **Step 1: Document exact build and run commands**

Add the proxy compile command from Task 7, the API-gate command from Task 1, the switch-core, converter, and adapter unit-test commands, and the four full-flow commands. Document that `PCIE_USE_SVT_SWITCH_PROXY` is legal only with the switch topology and that it adds five full Device Agent Proxy ports only in that build.

- [ ] **Step 2: Run four proxy full-flow cases**

```bash
for spec in gen4_default gen5_default gen4_fast gen5_fast; do
  case "$spec" in
    gen4_default) args='+PCIE_GEN=4' ;;
    gen5_default) args='+PCIE_GEN=5' ;;
    gen4_fast)    args='+PCIE_GEN=4 +PCIE_FAST_LINK_TRAIN=1' ;;
    gen5_fast)    args='+PCIE_GEN=5 +PCIE_FAST_LINK_TRAIN=1' ;;
  esac
  ./build_switch_proxy/simv -no_save \
    +UVM_TESTNAME=pcie_svt_switch_proxy_test $args +UVM_NO_RELNOTES \
    -l "build_switch_proxy/run_full_${spec}.log" || exit 1
done
```

- [ ] **Step 3: Gate every proxy log mechanically**

For each log require exactly five `LINK_PASS`, one `SWITCH_ENUM_PASS`, four `DOWNSTREAM_PATH_PASS`, four `UPSTREAM_PATH_PASS`, five per-port adapter reports, zero unmatched requests/Completions, zero drops, an empty outstanding table, and UVM W/E/F=0/0/0. Gen4 logs require 16 GT/s and Gen5 logs require 32 GT/s; every run requires one x16 and four x4 widths. The final report must print all five pairs' LTSSM/speed/width state and each adapter's receive/forward/Completion/drop counts.

- [ ] **Step 4: Rebuild and rerun the original x16 matrix**

Compile with `PCIE_TOPO_EP_X16` plus `PCIE_USE_SVT_PEER`, without `PCIE_USE_SVT_SWITCH_PROXY`, then rerun Gen4/Gen5 default/fast exactly as documented. Each log must retain one `LINK_PASS` and W/E/F=0/0/0.

- [ ] **Step 5: Perform credential/vendor-source and repository checks**

```bash
if git grep -n -E 'ghp_|10\.11\.10\.53.*123|license.*=' -- .; then
  exit 1
fi
git status --short
git diff --check
```

Also confirm no file from `/home/ubuntu/synopsys` is tracked and no generated build/log/PLI artifact appears in `git status`.

- [ ] **Step 6: Commit documentation and final evidence contract**

```bash
git add svt_pcie_integration/sim/README.md
git commit -m "docs: add SVT switch proxy validation matrix"
```

## Final Acceptance Checklist

- [ ] Public TL callback/drop/raw-`tlp_seqr` probe passed over two real Serial links without private state or modified vendor files.
- [ ] Switch unit tests proved Type-1 identity, byte enables, dynamic BDFs, 64-bit Prefetchable windows, Type conversion, and exact Completion return.
- [ ] Converter round trips preserved every supported field and payload byte.
- [ ] Gen4 default, Gen5 default, Gen4 fast, and Gen5 fast each produced five link passes, one enumeration pass, and eight traffic passes.
- [ ] Every full run ended with zero unmatched requests/Completions, zero drops, and UVM W/E/F=0/0/0.
- [ ] Original x16 Gen4/Gen5 default/fast regression remained clean.
- [ ] README commands reproduce the results from a clean checkout on `10.11.10.53`.
