# SVT PCIe Five-Sidecar Switch Proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the verification-only 1x16 USP plus 4x4 DSP Switch Proxy using five full active Proxy Device Agents, five input-only passive sidecars, official SVT enumeration, and exactly-once transparent forwarding.

**Architecture:** Active Proxy Target callbacks clone and suppress incoming Requests, while one passive sidecar per physical link supplies returning Completion TLPs and independent wire observations. Per-port dual-queue adapters normalize both sources into the repository `pcie_tl_switch`, and all egress traffic returns through each active Proxy Agent's public raw `tlp_seqr`.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys SVT PCIe R-2020.12, repository `pcie_tl_switch`, VCS W-2024.09-SP1 on `10.11.10.53`.

---

## Preconditions and Execution Contract

The following work is already complete and is not repeated by this plan:

- Task 1 accepted the two-link passive-sidecar feasibility probe at commit
  `b62cd53554ac823b1f008c96bcb1a926b4889cc9`.
- Task 2 accepted the host-memory-free switch package at commit
  `ed1894c5c078388d5709970e57a8cb5ca5b1e3d2`.
- The governing design is
  `docs/superpowers/specs/2026-08-18-svt-pcie-five-sidecar-switch-proxy-design.md`.

All compilation and simulation commands run on `ubuntu@10.11.10.53` through
`bash -lic`. Keep the Synopsys installation read-only. Use fresh build
directories under:

```text
/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim
```

Every GREEN gate requires its exact pass markers, no unexpected drop or
blocked marker, and UVM W/E/F=`0/0/0`. Negative tests run in separate
processes and require the named fatal; do not use a report catcher or severity
downgrade.

## File Structure

- `pcie_tl_vip/src/switch/pcie_tl_switch_port.sv`: Type-1 image and per-port
  programmed state.
- `pcie_tl_vip/src/switch/pcie_tl_switch_fabric.sv`: exact BDF and address
  lookup.
- `pcie_tl_vip/src/switch/pcie_tl_switch.sv`: local responses, Type conversion,
  and outstanding Completion ownership.
- `svt_pcie_integration/uvm/pcie_svt_tlp_converter.sv`: lossless supported TLP
  conversion.
- `svt_pcie_integration/uvm/pcie_svt_switch_target_callback.sv`: nonblocking
  active Target Request capture and local-response safety wall.
- `svt_pcie_integration/uvm/pcie_svt_switch_sidecar_subscriber.sv`: passive RX
  Completion capture and RX/TX scoreboard publication.
- `svt_pcie_integration/uvm/pcie_svt_switch_port_adapter.sv`: per-port Request,
  Completion, and egress workers.
- `svt_pcie_integration/uvm/pcie_svt_switch_sidecar_env.sv`: one passive Agent,
  width-matched standalone SERDES binding, and two subscribers.
- `svt_pcie_integration/uvm/pcie_svt_switch_scoreboard.sv`: exact signature and
  exactly-once checks.
- `svt_pcie_integration/rtl/pcie_svt_passive_sidecar_tap.sv`: input-only x4 and
  x16 tap macros.
- `svt_pcie_integration/rtl/pcie_svt_topology_top.sv`: five active Proxy HDL
  instances, five passive tap interfaces, and config-db publication.
- `svt_pcie_integration/uvm/sequences/pcie_svt_switch_enumeration_vseq.sv`:
  official enumeration and result collection.
- `svt_pcie_integration/uvm/sequences/pcie_svt_switch_traffic_vseq.sv`: four
  downstream and four upstream paths.

### Task 3: Implement Minimal Complete Type-1 Port Images

**Files:**
- Modify: `pcie_tl_vip/src/types/pcie_tl_types.sv`
- Modify: `pcie_tl_vip/src/switch/pcie_tl_switch_config.sv`
- Modify: `pcie_tl_vip/src/switch/pcie_tl_switch_port.sv`
- Modify: `svt_pcie_integration/sim/pcie_tl_switch_proxy_unit_test.sv`
- Test: `svt_pcie_integration/sim/build_switch_type1.*/run.log`

- [ ] **Step 1: Add Type-1 positive tests before implementation**

Extend the existing unit top with this exact helper and checks:

```systemverilog
task automatic check_eq(bit [31:0] actual, bit [31:0] expected,
                        string label);
    if (actual !== expected)
        $fatal(1, "%s expected=%08h actual=%08h", label, expected, actual);
endtask

pcie_tl_switch_port usp;
pcie_tl_switch_port dsp;
usp = new("usp", null);
dsp = new("dsp", null);
usp.init_type1_image(SWITCH_USP, 0, 16'h0100);
dsp.init_type1_image(SWITCH_DSP, 2, 16'h0202);

check_eq(usp.cfg_read(12'h000), 32'h5010_20f9, "USP vendor/device");
check_eq(usp.cfg_read(12'h008), 32'h0604_0001, "bridge class/revision");
check_eq(usp.cfg_read(12'h00c) & 32'h00ff_0000,
         32'h0001_0000, "header type 1");
check_eq(usp.cfg_read(12'h034) & 32'hff, 32'h40, "PCIe cap pointer");
check_eq((usp.cfg_read(12'h040) >> 20) & 4'hf, 4'h5,
         "USP port type");
check_eq((dsp.cfg_read(12'h040) >> 20) & 4'hf, 4'h6,
         "DSP port type");

usp.cfg_write(12'h018, 32'h0602_0100, 4'b1110);
check_eq(usp.cfg_read(12'h018), 32'h0602_0100, "bus byte enables");
usp.cfg_write(12'h004, 32'h0000_0002, 4'b0001);
check_eq(usp.cfg_read(12'h004) & 32'h0000_0002,
         32'h0000_0002, "Memory Space Enable");

dsp.cfg_write(12'h024, 32'h1071_1001, 4'hf);
dsp.cfg_write(12'h028, 32'h0000_0001, 4'hf);
dsp.cfg_write(12'h02c, 32'h0000_0001, 4'hf);
if ((dsp.pref_base != 64'h0000_0001_1000_0000) ||
    (dsp.pref_limit != 64'h0000_0001_107f_ffff))
    $fatal(1, "64-bit Prefetchable window decode failed");
```

- [ ] **Step 2: Run the unchanged switch unit build to establish RED**

On host 53, compile `pcie_tl_switch_unit.f` with
`-top pcie_tl_switch_proxy_unit_top` and run the result. Save it under a fresh
`build_switch_type1_red.XXXXXX` directory.

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  b=\$(mktemp -d build_switch_type1_red.XXXXXX) &&
  vcs -full64 -sverilog -ntb_opts uvm-1.2 \
    -f pcie_tl_switch_unit.f -top pcie_tl_switch_proxy_unit_top \
    -Mdir=\$b/csrc -o \$b/simv -l \$b/compile.log &&
  \$b/simv -l \$b/run.log
"'
```

Expected: compile failure for `init_type1_image` or runtime failure because the
identity and capability registers still read zero.

- [ ] **Step 3: Add explicit Type-1 state and byte merging**

Add these members and helper to `pcie_tl_switch_port`:

```systemverilog
bit [15:0] bdf;
bit [15:0] vendor_id = 16'h20f9;
bit [15:0] device_id;
bit [15:0] command;
bit [15:0] status = 16'h0010;
bit [7:0]  revision_id = 8'h01;
bit [23:0] class_code = 24'h060400;
bit [7:0]  header_type = 8'h01;
bit [15:0] pref_base_reg = 16'h0001;
bit [15:0] pref_limit_reg = 16'h0001;
bit [63:0] pref_base;
bit [63:0] pref_limit;
bit [31:0] pref_base_upper;
bit [31:0] pref_limit_upper;

function automatic bit [31:0] merge_be(
    bit [31:0] old_value, bit [31:0] new_value, bit [3:0] be);
    bit [31:0] result = old_value;
    foreach (be[i])
        if (be[i]) result[i*8 +: 8] = new_value[i*8 +: 8];
    return result;
endfunction

function void init_type1_image(switch_port_role_e image_role,
                               int unsigned index,
                               bit [15:0] image_bdf);
    role = image_role;
    bdf = image_bdf;
    device_id = (role == SWITCH_USP) ? 16'h5010 : 16'(16'h5020 + index);
    command = 16'h0000;
    status = 16'h0010;
    pref_base_reg = 16'h0001;
    pref_limit_reg = 16'h0001;
    pref_base_upper = 32'h0000_0000;
    pref_limit_upper = 32'h0000_0000;
    pref_base = 64'h0;
    pref_limit = 64'h0000_0000_000f_ffff;
endfunction
```

Implement exact reads:

```systemverilog
12'h000: return {device_id, vendor_id};
12'h004: return {status, command};
12'h008: return {class_code, revision_id};
12'h00c: return {8'h00, header_type, 16'h0000};
12'h018: return {route_entry.subordinate_bus,
                 route_entry.secondary_bus,
                 route_entry.primary_bus, 8'h00};
12'h020: return {route_entry.mem_limit[31:20], 4'h0,
                 route_entry.mem_base[31:20], 4'h0};
12'h024: return {pref_limit_reg, pref_base_reg};
12'h028: return pref_base_upper;
12'h02c: return pref_limit_upper;
12'h034: return 32'h0000_0040;
12'h040: return {8'h00, (role == SWITCH_USP) ? 4'h5 : 4'h6,
                 4'h2, 8'h00, 8'h10};
```

For writes, merge whole DWORDs first, then update only writable fields.
Vendor/Device ID, class code, Header Type, capability ID/version, and Status
remain read-only. Command accepts the low two bytes; bus-number bytes preserve
unselected bytes.

- [ ] **Step 4: Decode 64-bit Prefetchable registers**

After writes to 0x024/0x028/0x02c, recompute:

```systemverilog
pref_base = {pref_base_upper, pref_base_reg[15:4], 20'h00000};
pref_limit = {pref_limit_upper, pref_limit_reg[15:4], 20'hfffff};
```

Require the low-nibble type bits to read as `4'h1`. Preserve byte-enable
semantics independently for the low register and both upper registers.

- [ ] **Step 5: Run GREEN and commit**

Use a fresh `build_switch_type1_green.XXXXXX`. Require exactly one
`TYPE1_CFG_PASS`, one existing `SWITCH_PACKAGE_SMOKE_PASS`, and no
Warning/Error/Fatal diagnostics.

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  b=\$(mktemp -d build_switch_type1_green.XXXXXX) &&
  vcs -full64 -sverilog -ntb_opts uvm-1.2 \
    -f pcie_tl_switch_unit.f -top pcie_tl_switch_proxy_unit_top \
    -Mdir=\$b/csrc -o \$b/simv -l \$b/compile.log &&
  \$b/simv -l \$b/run.log &&
  test \"\$(grep -a -c TYPE1_CFG_PASS \$b/run.log)\" -eq 1 &&
  test \"\$(grep -a -c SWITCH_PACKAGE_SMOKE_PASS \$b/run.log)\" -eq 1
"'
```

```bash
git add pcie_tl_vip/src/types/pcie_tl_types.sv \
        pcie_tl_vip/src/switch/pcie_tl_switch_config.sv \
        pcie_tl_vip/src/switch/pcie_tl_switch_port.sv \
        svt_pcie_integration/sim/pcie_tl_switch_proxy_unit_test.sv
git commit -m "feat: model switch Type-1 configuration space"
```

### Task 4: Add Dynamic BDF, Window, Type, and Completion Routing

**Files:**
- Modify: `pcie_tl_vip/src/types/pcie_tl_types.sv`
- Modify: `pcie_tl_vip/src/switch/pcie_tl_switch_fabric.sv`
- Modify: `pcie_tl_vip/src/switch/pcie_tl_switch.sv`
- Modify: `svt_pcie_integration/sim/pcie_tl_switch_proxy_unit_test.sv`
- Test: `svt_pcie_integration/sim/build_switch_route.*/run*.log`

- [ ] **Step 1: Add positive routing tests**

Add independent checks for:

```systemverilog
task automatic check_route(int actual, int expected, string label);
    if (actual != expected)
        $fatal(1, "%s expected=%0d actual=%0d", label, expected, actual);
endtask

check_route(sw.local_port_for_bdf(16'h0100), 0, "USP BDF");
check_route(sw.local_port_for_bdf(16'h0200), 1, "DSP0 BDF");
check_route(sw.local_port_for_bdf(16'h0208), 2, "DSP1 BDF");
check_route(sw.local_port_for_bdf(16'h0210), 3, "DSP2 BDF");
check_route(sw.local_port_for_bdf(16'h0218), 4, "DSP3 BDF");
```

Program DSP0 with Memory Space Enable and the 64-bit Prefetchable window from
Task 3. Require address `64'h0000_0001_1040_0000` to route to DSP0, then clear
Memory Space Enable and require `SWITCH_ROUTE_DROP`.

Create a Type-1 Configuration Read for DSP0's directly attached Endpoint bus.
After forwarding, require `kind==TLP_CFG_RD0`, `type_f==TLP_TYPE_CFG_RD0`, and
all other supported fields unchanged.

Insert a non-posted request with `{Requester ID, Tag}={16'h0000,10'h155}` from
USP, inject its Completion from DSP0, and require return to USP plus an empty
outstanding table.

- [ ] **Step 2: Add separate negative modes and establish RED**

The unit top accepts exactly one optional plusarg:

```systemverilog
if ($test$plusargs("SWITCH_NEG_DUP_NP")) run_duplicate_np_negative();
else if ($test$plusargs("SWITCH_NEG_UNKNOWN_CPL"))
    run_unknown_completion_negative();
else run_positive_tests();
```

Run the positive image and both negative modes separately. Before
implementation, positive routing must fail. After implementation, each
negative run must terminate with its named UVM fatal:

```text
SWITCH_DUP_NP
SWITCH_UNKNOWN_CPL
```

Do not catch or downgrade either fatal.

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  b=\$(mktemp -d build_switch_route_red.XXXXXX) &&
  vcs -full64 -sverilog -ntb_opts uvm-1.2 \
    -f pcie_tl_switch_unit.f -top pcie_tl_switch_proxy_unit_top \
    -Mdir=\$b/csrc -o \$b/simv -l \$b/compile.log &&
  \$b/simv -l \$b/run_positive.log
"'
```

- [ ] **Step 3: Define exact key and routing state**

Add to `pcie_tl_types.sv`:

```systemverilog
typedef bit [25:0] switch_np_key_t;

function automatic switch_np_key_t switch_np_key(
    bit [15:0] requester_id, bit [9:0] tag);
    return {requester_id, tag};
endfunction
```

Add an exact BDF-to-port map and a non-posted ownership map to
`pcie_tl_switch`:

```systemverilog
int local_bdf_to_port[bit [15:0]];
int outstanding_ingress[switch_np_key_t];

function int unsigned outstanding_count();
    return outstanding_ingress.num();
endfunction
```

`refresh_local_bdf_map()` inserts the USP BDF and all four programmed DSP
BDFs. Duplicate insertions fatal. `local_port_for_bdf()` returns one exact
port or `SWITCH_ROUTE_DROP`; it does not infer a port from device number.

- [ ] **Step 4: Implement 64-bit address routing and exact Completion return**

The fabric examines non-Prefetchable and Prefetchable windows only when
`command[1]` is set. It rejects a base-greater-than-limit window. An unmatched
request from a DSP routes to its owning USP; an unmatched request from a USP
drops.

Before forwarding a non-posted request:

```systemverilog
switch_np_key_t key = switch_np_key(tlp.requester_id, tlp.tag);
if (outstanding_ingress.exists(key))
    `uvm_fatal("SWITCH_DUP_NP", $sformatf(
      "requester=%04h tag=%03h", tlp.requester_id, tlp.tag))
outstanding_ingress[key] = ingress_port_id;
```

On Completion, require the key, route to its recorded ingress, and delete it.
Do not route a Completion from Requester bus ranges.

Clone a Configuration Request before forwarding. Convert Type 1 to Type 0
only when the target bus equals the egress DSP's secondary bus. Preserve TC,
attributes, Requester ID, full Tag, register number, byte enables, and payload.

- [ ] **Step 5: Run GREEN and commit**

Require one `SWITCH_ROUTE_PASS`, empty outstanding state, W/E/F=`0/0/0` in the
positive run, plus the exact fatal ID in each negative run.

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  b=\$(mktemp -d build_switch_route_green.XXXXXX) &&
  vcs -full64 -sverilog -ntb_opts uvm-1.2 \
    -f pcie_tl_switch_unit.f -top pcie_tl_switch_proxy_unit_top \
    -Mdir=\$b/csrc -o \$b/simv -l \$b/compile.log &&
  \$b/simv -l \$b/run_positive.log &&
  test \"\$(grep -a -c SWITCH_ROUTE_PASS \$b/run_positive.log)\" -eq 1 &&
  ! \$b/simv +SWITCH_NEG_DUP_NP -l \$b/run_dup.log &&
  grep -a -q SWITCH_DUP_NP \$b/run_dup.log &&
  ! \$b/simv +SWITCH_NEG_UNKNOWN_CPL -l \$b/run_unknown.log &&
  grep -a -q SWITCH_UNKNOWN_CPL \$b/run_unknown.log
"'
```

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
- Modify: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt.f`
- Test: `svt_pcie_integration/sim/build_converter.*/run.log`

- [ ] **Step 1: Write table-driven round-trip tests**

Create one SVT vector for each supported tuple:

```text
MEM_REQ/no-data, MEM_REQ/data,
TYPE_0_CFG_REQ/no-data, TYPE_0_CFG_REQ/data,
TYPE_1_CFG_REQ/no-data, TYPE_1_CFG_REQ/data,
CPL/no-data, CPL/data
```

Set non-default TC, attributes, address, length, first/last BE, Requester ID,
Completer ID, full 10-bit Tag, Completion Status, byte count, lower address,
and payload. For every vector:

```systemverilog
pcie_tl_tlp normalized;
svt_pcie_tlp round_trip;
string reason;
if (!pcie_svt_tlp_converter::from_svt(source, normalized, reason))
    `uvm_fatal("CONVERTER", reason)
if (!pcie_svt_tlp_converter::to_svt(normalized, round_trip, reason))
    `uvm_fatal("CONVERTER", reason)
compare_supported_fields(source, round_trip);
```

Add one Message TLP negative vector and require a false return with a nonempty
reason.

- [ ] **Step 2: Run RED**

Compile the unit top against the production file list on host 53. Expected:
`pcie_svt_tlp_converter` is undefined.

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12 &&
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12 &&
  b=\$(mktemp -d build_converter_red.XXXXXX) &&
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    -f pcie_svt.f pcie_svt_tlp_converter_unit_test.sv \
    -top pcie_svt_tlp_converter_unit_top -Mdir=\$b/csrc \
    -P pli.tab msglog.o -o \$b/simv -l \$b/compile.log
"'
```

- [ ] **Step 3: Implement explicit tuple mapping**

`from_svt()` and `to_svt()` map the tuple, not a single enum:

```text
MEM_REQ + no data       <-> TLP_MEM_RD
MEM_REQ/DMEM_REQ + data <-> TLP_MEM_WR
TYPE_0_CFG_REQ no/data  <-> TLP_CFG_RD0/TLP_CFG_WR0
TYPE_1_CFG_REQ no/data  <-> TLP_CFG_RD1/TLP_CFG_WR1
CPL no/data             <-> TLP_CPL/TLP_CPLD
```

Instantiate the matching `pcie_tl_mem_tlp`, `pcie_tl_cfg_tlp`, or
`pcie_tl_cpl_tlp` subclass. Copy every supported field explicitly. Translate
payload bytes in PCIe address order; do not rely on `uvm_object::compare` for
payload equality.

Compile `pcie_tl_switch_pkg.sv` before the integration package in
`pcie_svt.f`, using `+incdir+../../pcie_tl_vip/src`. Import
`pcie_tl_switch_pkg::*` and include `pcie_svt_tlp_converter.sv` before all
adapter and sequence files in `pcie_svt_integration_pkg.sv`. Do not compile
`pcie_tl_pkg` in the same image.

- [ ] **Step 4: Run GREEN and commit**

Use a fresh build and require exactly one `TLP_CONVERTER_PASS` and
W/E/F=`0/0/0`.

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12 &&
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12 &&
  b=\$(mktemp -d build_converter_green.XXXXXX) &&
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    -f pcie_svt.f pcie_svt_tlp_converter_unit_test.sv \
    -top pcie_svt_tlp_converter_unit_top -Mdir=\$b/csrc \
    -P pli.tab msglog.o -o \$b/simv -l \$b/compile.log &&
  \$b/simv -no_save +UVM_NO_RELNOTES -l \$b/run.log &&
  test \"\$(grep -a -c TLP_CONVERTER_PASS \$b/run.log)\" -eq 1
"'
```

```bash
git add svt_pcie_integration/uvm/pcie_svt_tlp_converter.sv \
        svt_pcie_integration/sim/pcie_svt_tlp_converter_unit_test.sv \
        svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv \
        svt_pcie_integration/sim/pcie_svt.f
git commit -m "feat: convert public SVT and switch TLP objects"
```

### Task 6: Build the Dual-Source Port Adapter and Scoreboard

**Files:**
- Create: `svt_pcie_integration/uvm/pcie_svt_switch_target_callback.sv`
- Create: `svt_pcie_integration/uvm/pcie_svt_switch_sidecar_subscriber.sv`
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_raw_tlp_sequence.sv`
- Create: `svt_pcie_integration/uvm/pcie_svt_switch_port_adapter.sv`
- Create: `svt_pcie_integration/uvm/pcie_svt_switch_scoreboard.sv`
- Create: `svt_pcie_integration/sim/pcie_svt_switch_adapter_unit_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`
- Test: `svt_pcie_integration/sim/build_switch_adapter.*/run.log`

- [ ] **Step 1: Write RED ownership tests**

Directly exercise one adapter, callback, RX subscriber, and TX subscriber:

```systemverilog
drop = 0;
target_cb.post_rx_tlp_get(null, request, drop);
if (!drop || (adapter.request_capture_count != 1))
    `uvm_fatal("ADAPTER_TEST", "Request ownership failed")

rx_sub.write(completion);
if (adapter.completion_capture_count != 1)
    `uvm_fatal("ADAPTER_TEST", "Completion ownership failed")

rx_sub.write(request);
tx_sub.write(request);
if ((adapter.request_capture_count != 1) ||
    (adapter.completion_capture_count != 1))
    `uvm_fatal("ADAPTER_TEST", "sidecar observation re-entered switch")
```

Start adapter workers with a collecting `svt_pcie_tlp_sequencer` driver.
Require one normalized Request, one normalized Completion, and exactly one
raw egress clone. Verify the source objects remain unchanged.

- [ ] **Step 2: Run RED**

Expected: callback, subscriber, adapter, raw sequence, and scoreboard classes
are undefined.

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12 &&
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12 &&
  b=\$(mktemp -d build_switch_adapter_red.XXXXXX) &&
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    -f pcie_svt.f pcie_svt_switch_adapter_unit_test.sv \
    -top pcie_svt_switch_adapter_unit_top -Mdir=\$b/csrc \
    -P pli.tab msglog.o -o \$b/simv -l \$b/compile.log
"'
```

- [ ] **Step 3: Implement callback and sidecar subscriber functions**

The callback uses only nonblocking work:

```systemverilog
virtual function void post_rx_tlp_get(
    svt_pcie_target_app target_app,
    svt_pcie_tlp transaction,
    ref bit drop);
    adapter.capture_request(transaction);
    drop = 1'b1;
endfunction

virtual function void pre_tx_tlp_put(
    svt_pcie_target_app target_app,
    svt_pcie_tlp transaction,
    ref bit drop);
    adapter.note_unexpected_target_tx(transaction);
    drop = 1'b1;
endfunction
```

The subscriber always clones before publication. RX publishes every supported
wire TLP, but calls `adapter.capture_completion()` only for Completion classes.
TX is observation-only and never calls either capture method.

- [ ] **Step 4: Implement the adapter's two queues and three workers**

Construct both mailboxes as unbounded:

```systemverilog
mailbox #(svt_pcie_tlp) request_mbox = new();
mailbox #(svt_pcie_tlp) completion_mbox = new();
```

Both capture functions clone and use `try_put`; null, clone failure, or a
rejected unbounded put is fatal. Request and Completion counters increment
only after a successful enqueue.

In `run_phase`, fork:

```text
request_mbox.get -> from_svt -> switch_port.rx_fifo.put
completion_mbox.get -> from_svt -> switch_port.rx_fifo.put
switch_port.tx_fifo.get -> to_svt -> fresh raw sequence -> proxy_tlp_seqr
```

The raw sequence contains only:

```systemverilog
if (request == null)
    `uvm_fatal("SVT_RAW_TLP", "request is null")
start_item(request);
finish_item(request);
```

Callbacks and analysis `write()` never call these worker tasks.

- [ ] **Step 5: Implement exact scoreboard signatures**

Key expected and observed counts by:

```text
direction, ingress, egress, kind, Requester ID, Completer ID,
10-bit Tag, address, length, first/last BE, Completion fields,
32-bit FNV-1a payload digest
```

Expose `expect_forward`, `observe_wire`, and `check_empty`. Missing, duplicate,
wrong-egress, payload-mismatch, and unmatched-Completion entries fatal.

- [ ] **Step 6: Run GREEN and commit**

Require one `SWITCH_ADAPTER_PASS`, two ingress objects, one raw egress object,
zero unexpected Target transmissions, empty scoreboard state, and
W/E/F=`0/0/0`.

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12 &&
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12 &&
  b=\$(mktemp -d build_switch_adapter_green.XXXXXX) &&
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    -f pcie_svt.f pcie_svt_switch_adapter_unit_test.sv \
    -top pcie_svt_switch_adapter_unit_top -Mdir=\$b/csrc \
    -P pli.tab msglog.o -o \$b/simv -l \$b/compile.log &&
  \$b/simv -no_save +UVM_NO_RELNOTES -l \$b/run.log &&
  test \"\$(grep -a -c SWITCH_ADAPTER_PASS \$b/run.log)\" -eq 1
"'
```

```bash
git add svt_pcie_integration/uvm/pcie_svt_switch_target_callback.sv \
        svt_pcie_integration/uvm/pcie_svt_switch_sidecar_subscriber.sv \
        svt_pcie_integration/uvm/sequences/pcie_svt_raw_tlp_sequence.sv \
        svt_pcie_integration/uvm/pcie_svt_switch_port_adapter.sv \
        svt_pcie_integration/uvm/pcie_svt_switch_scoreboard.sv \
        svt_pcie_integration/sim/pcie_svt_switch_adapter_unit_test.sv \
        svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv
git commit -m "feat: bridge target requests and passive completions"
```

### Task 7: Add Five Input-Only Sidecar Taps and Compile Selection

**Files:**
- Modify: `svt_pcie_integration/rtl/pcie_svt_passive_sidecar_tap.sv`
- Modify: `svt_pcie_integration/rtl/pcie_svt_topology_checks.svh`
- Modify: `svt_pcie_integration/rtl/pcie_svt_topology_top.sv`
- Create: `svt_pcie_integration/uvm/pcie_svt_switch_sidecar_env.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`
- Test: `svt_pcie_integration/sim/build_switch_sidecar_compile.*/compile.log`

- [ ] **Step 1: Add compile-contract RED cases**

Compile these combinations separately and require `PCIe topology contract`:

```text
PCIE_USE_SVT_SWITCH_PROXY without PCIE_TOPO_SWITCH_1X16_4X4
PCIE_USE_SVT_SWITCH_PROXY with PCIE_USE_SVT_PEER
```

Compile the legal proxy combination before implementation. Expected RED:
missing Proxy VIF or sidecar VIF declarations.

Run the two negative compile contracts and the legal pre-implementation image
as three independent VCS processes:

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12 &&
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12 &&
  b0=\$(mktemp -d build_switch_sidecar_bad_topology.XXXXXX) &&
  if vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    +define+PCIE_USE_SVT_SWITCH_PROXY \
    -f pcie_svt.f -top pcie_svt_topology_top -Mdir=\$b0/csrc \
    -P pli.tab msglog.o -o \$b0/simv -l \$b0/compile.log; then exit 1; fi &&
  grep -a -q \"PCIe topology contract\" \$b0/compile.log &&
  b1=\$(mktemp -d build_switch_sidecar_bad_peer.XXXXXX) &&
  if vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    +define+PCIE_TOPO_SWITCH_1X16_4X4 \
    +define+PCIE_USE_SVT_SWITCH_PROXY +define+PCIE_USE_SVT_PEER \
    -f pcie_svt.f -top pcie_svt_topology_top -Mdir=\$b1/csrc \
    -P pli.tab msglog.o -o \$b1/simv -l \$b1/compile.log; then exit 1; fi &&
  grep -a -q \"PCIe topology contract\" \$b1/compile.log &&
  b2=\$(mktemp -d build_switch_sidecar_legal_red.XXXXXX) &&
  if vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    +define+PCIE_TOPO_SWITCH_1X16_4X4 \
    +define+PCIE_USE_SVT_SWITCH_PROXY \
    -f pcie_svt.f -top pcie_svt_topology_top -Mdir=\$b2/csrc \
    -P pli.tab msglog.o -o \$b2/simv -l \$b2/compile.log; then exit 1; fi &&
  grep -a -E -q \"proxy_.*_vif|sidecar.*vif|pcie_svt_switch_sidecar_env\" \
    \$b2/compile.log
"'
```

- [ ] **Step 2: Extend the input-only tap to x16**

Keep the existing lane macro and add an explicit x16 macro that invokes it for
lanes 0 through 15:

```systemverilog
`define PCIE_SVT_TAP_PASSIVE_SERDES_X16(mon_if, proxy_port) \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 0)  \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 1)  \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 2)  \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 3)  \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 4)  \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 5)  \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 6)  \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 7)  \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 8)  \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 9)  \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 10) \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 11) \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 12) \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 13) \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 14) \
  `PCIE_SVT_TAP_PASSIVE_SERDES_LANE(mon_if, proxy_port, 15)
```

Every assignment terminates on the passive interface. Add no assignment from
a passive signal to an active serial signal.

- [ ] **Step 3: Instantiate five active Proxy ports and five passive interfaces**

Under the legal proxy macro, instantiate:

```text
proxy_usp_spd:  Endpoint role, x16, hierarchy 0
proxy_dsp0_spd: Root role, x4, hierarchy 1
proxy_dsp1_spd: Root role, x4, hierarchy 2
proxy_dsp2_spd: Root role, x4, hierarchy 3
proxy_dsp3_spd: Root role, x4, hierarchy 4
```

Connect each active Proxy to its primary peer with the existing Serial peer
macro. Instantiate one `svt_pcie_serdes_x16_if` for the USP tap and four
`svt_pcie_serdes_x4_if` interfaces for DSP taps. Publish:

```text
proxy_usp_vif, proxy_dsp0_vif .. proxy_dsp3_vif
proxy_usp_sidecar_vif
proxy_dsp0_sidecar_vif .. proxy_dsp3_sidecar_vif
```

Use typed `uvm_config_db` entries for x16 and x4 passive VIFs.

- [ ] **Step 4: Implement one width-aware passive sidecar environment**

`pcie_svt_switch_sidecar_env` holds exactly one of:

```systemverilog
svt_pcie_serdes_x16_vif serdes_x16_vif;
svt_pcie_serdes_x4_vif  serdes_x4_vif;
int unsigned lanes;
```

It creates a passive Device Agent with:

```systemverilog
cfg.is_active = 1'b0;
cfg.pcie_cfg.enable_monitor = 1'b1;
cfg.pcie_cfg.tl_cfg.cfg_space_mode =
    svt_pcie_tl_configuration::CFG_SPACE_BACKDOOR_UPDATE;
```

Bind `serdes_x16_if` only for `lanes==16` and `serdes_x4_if` only for
`lanes==4`. Do not call `set_initial_values_via_unified_vif()` for the passive
Agent. Create one RX subscriber and one TX subscriber and connect them to
`tl_mon.rx_tlp_observed_port` and `tl_mon.tx_tlp_observed_port`.

- [ ] **Step 5: Compile GREEN and commit**

Require the legal image to compile/elaborate, the two illegal images to fail
with the contract text, and no vendor-source modification.

Re-run the two negative commands from Step 1, then compile and elaborate the
legal image in a fresh directory:

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12 &&
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12 &&
  b=\$(mktemp -d build_switch_sidecar_compile_green.XXXXXX) &&
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    +define+PCIE_TOPO_SWITCH_1X16_4X4 \
    +define+PCIE_USE_SVT_SWITCH_PROXY \
    -f pcie_svt.f -top pcie_svt_topology_top -Mdir=\$b/csrc \
    -P pli.tab msglog.o -o \$b/simv -l \$b/compile.log &&
  \$b/simv -no_save +UVM_TESTNAME=pcie_svt_base_test \
    +PCIE_GEN=4 +PCIE_COMPILE_ONLY +UVM_NO_RELNOTES -l \$b/run.log &&
  test \"\$(grep -a -c PCIE_SVT_COMPILE_ONLY_READY \$b/run.log)\" -eq 1 &&
  grep -a -q \"UVM_WARNING *: *0\" \$b/run.log &&
  grep -a -q \"UVM_ERROR *: *0\" \$b/run.log &&
  grep -a -q \"UVM_FATAL *: *0\" \$b/run.log
"'
```

```bash
git add svt_pcie_integration/rtl/pcie_svt_passive_sidecar_tap.sv \
        svt_pcie_integration/rtl/pcie_svt_topology_checks.svh \
        svt_pcie_integration/rtl/pcie_svt_topology_top.sv \
        svt_pcie_integration/uvm/pcie_svt_switch_sidecar_env.sv \
        svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv
git commit -m "feat: add five passive switch sidecar taps"
```

### Task 8: Build and Prove the Five Active Link Pairs

**Files:**
- Modify: `svt_pcie_integration/uvm/pcie_svt_port_env.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_env.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_virtual_sequencer.sv`
- Modify: `svt_pcie_integration/uvm/sequences/pcie_svt_all_cfg_spaces_init_vseq.sv`
- Modify: `svt_pcie_integration/uvm/sequences/pcie_svt_all_links_bringup_vseq.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_base_test.sv`
- Create: `svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt.f`
- Test: `svt_pcie_integration/sim/build_switch_links.*/run_*.log`

- [ ] **Step 1: Add runtime contract and link RED checks**

Reject `+PCIE_DISABLE_SWITCH_SIDECARS` unless `+PCIE_LINK_ONLY` is also
present. In legal link-only mode, require exactly five active `LINK_PASS`
markers:

```text
RC0 <-> Proxy USP, x16
EP0 <-> Proxy DSP0, x4
EP1 <-> Proxy DSP1, x4
EP2 <-> Proxy DSP2, x4
EP3 <-> Proxy DSP3, x4
```

Before environment implementation, expect missing Proxy or sidecar handles.

- [ ] **Step 2: Build ten full active Device Agents**

Reuse indices `PCIE_SVT_PEER_PORT0..4` for the five Proxy active Agents. Mark
only those five `is_switch_proxy=1`; all primary agents remain zero. Fatal if
a Proxy active configuration has `dut_model==RTL`.

Refresh lower-layer configuration for all ten active agents. Program Endpoint
BARs and completer-space state only on the five primary agents. Emit one
`PROXY_TARGET_CFG_SKIP` per Proxy Agent because the switch core owns visible
switch configuration behavior.

- [ ] **Step 3: Conditionally create five passive sidecars**

If `+PCIE_LINK_ONLY +PCIE_DISABLE_SWITCH_SIDECARS` is present, create no
passive Device Agent and emit exactly one
`SWITCH_SIDECARS_DISABLED_LINK_ONLY`. Otherwise create all five sidecar envs,
bind the published VIFs, assign port IDs 0 through 4, and require non-null
`tl_mon` plus both analysis connections.

- [ ] **Step 4: Construct and connect switch ownership objects**

Create one `pcie_tl_switch`, five adapters, five Target callbacks, five RX
subscribers, five TX subscribers, and one scoreboard only in proxy mode. Wire
adapter `i` to `switch.all_ports[i]` and the corresponding Proxy active
`pcie_agent.tlp_seqr`. Register exactly one callback on only that Proxy's
Target App:

```systemverilog
uvm_callbacks#(svt_pcie_target_app,
  svt_pcie_target_app_callback)::add(
    proxy_port[i].device_agent.target[0], target_callback[i]);
```

Do not register on any primary Target App. Give both subscribers the same
port ID, adapter, and scoreboard, with fixed RX or TX role.

For every enabled sidecar, initialize the minimal passive checker image with
`MON_CONFIG_SPACE_WRITE_ADDR` for Status/Command, Capability Pointer, and one
PCI Express Capability at 0x40. Use these exact DWORD writes before any field
SET/GET sequence:

```text
offset 0x004, data 32'h0010_0000  // Status/Command
offset 0x034, data 32'h0000_0040  // Capability Pointer
offset 0x040, data 32'h0002_0010  // PCIe Capability v2
```

Then SET and GET all four fields below and require readback value one:

```text
SVT_PCIE_PCIE_DEV_CTST_REG_EXTND_TAG_FIELD_EN_FLD
SVT_PCIE_PCIE_DEV_2_REG_10_BIT_TAG_REQUESTER_SUPP_FLD
SVT_PCIE_PCIE_DEV_CTST_2_REG_10_BIT_TAG_REQUESTER_EN_FLD
SVT_PCIE_PCIE_DEV_2_REG_10_BIT_TAG_COMPLETER_SUPP_FLD
```

Each passive service wait is bounded to 100 us. Emit one
`SWITCH_SIDECAR_READY port=<i> lanes=<n>` only after exact readback.
Any detected passive-to-active drive uses fatal ID `SWITCH_PASSIVE_DRIVE`.

- [ ] **Step 5: Bring all active pairs up concurrently**

Validate ten handles, fork ten `enable_port` calls, then fork five
`wait_for_pair` calls. Each pair must report Link Up, the requested generation,
the expected width, and LTSSM L0 at both active endpoints. A failure on any
pair prevents the sidecar-ready or enumeration stage.

- [ ] **Step 6: Run two fresh link-only GREEN cases**

Run Gen4 twice:

```text
+PCIE_LINK_ONLY +PCIE_DISABLE_SWITCH_SIDECARS
+PCIE_LINK_ONLY
```

The first requires five link passes and the disabled marker. The second
requires five link passes, five `SWITCH_SIDECAR_READY` markers, and no passive
drive diagnostic. Record GNU `time -v` wall time and peak RSS for both.

Compile once and run both cases as independent processes:

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12 &&
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12 &&
  b=\$(mktemp -d build_switch_links.XXXXXX) &&
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    +define+PCIE_TOPO_SWITCH_1X16_4X4 \
    +define+PCIE_USE_SVT_SWITCH_PROXY \
    -f pcie_svt.f -top pcie_svt_topology_top -Mdir=\$b/csrc \
    -P pli.tab msglog.o -o \$b/simv -l \$b/compile.log &&
  /usr/bin/time -v -o \$b/time_no_sidecars.txt \
    \$b/simv -no_save +UVM_TESTNAME=pcie_svt_switch_proxy_test \
      +PCIE_GEN=4 +PCIE_LINK_ONLY +PCIE_DISABLE_SWITCH_SIDECARS \
      +UVM_NO_RELNOTES -l \$b/run_no_sidecars.log &&
  test \"\$(grep -a -c \"UVM_INFO.*\\[LINK_PASS\\]\" \
    \$b/run_no_sidecars.log)\" -eq 5 &&
  test \"\$(grep -a -c SWITCH_SIDECARS_DISABLED_LINK_ONLY \
    \$b/run_no_sidecars.log)\" -eq 1 &&
  grep -a -q \"UVM_WARNING *: *0\" \$b/run_no_sidecars.log &&
  grep -a -q \"UVM_ERROR *: *0\" \$b/run_no_sidecars.log &&
  grep -a -q \"UVM_FATAL *: *0\" \$b/run_no_sidecars.log &&
  /usr/bin/time -v -o \$b/time_with_sidecars.txt \
    \$b/simv -no_save +UVM_TESTNAME=pcie_svt_switch_proxy_test \
      +PCIE_GEN=4 +PCIE_LINK_ONLY +UVM_NO_RELNOTES \
      -l \$b/run_with_sidecars.log &&
  test \"\$(grep -a -c \"UVM_INFO.*\\[LINK_PASS\\]\" \
    \$b/run_with_sidecars.log)\" -eq 5 &&
  test \"\$(grep -a -c \"SWITCH_SIDECAR_READY port=\" \
    \$b/run_with_sidecars.log)\" -eq 5 &&
  ! grep -a -q SWITCH_PASSIVE_DRIVE \$b/run_with_sidecars.log &&
  grep -a -q \"UVM_WARNING *: *0\" \$b/run_with_sidecars.log &&
  grep -a -q \"UVM_ERROR *: *0\" \$b/run_with_sidecars.log &&
  grep -a -q \"UVM_FATAL *: *0\" \$b/run_with_sidecars.log
"'
```

- [ ] **Step 7: Commit five-link environment**

```bash
git add svt_pcie_integration/uvm/pcie_svt_port_env.sv \
        svt_pcie_integration/uvm/pcie_svt_env.sv \
        svt_pcie_integration/uvm/pcie_svt_virtual_sequencer.sv \
        svt_pcie_integration/uvm/sequences/pcie_svt_all_cfg_spaces_init_vseq.sv \
        svt_pcie_integration/uvm/sequences/pcie_svt_all_links_bringup_vseq.sv \
        svt_pcie_integration/uvm/pcie_svt_base_test.sv \
        svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv \
        svt_pcie_integration/sim/pcie_svt.f
git commit -m "feat: bring up five active switch proxy links"
```

### Task 9: Run Official Dynamic Switch Enumeration

**Files:**
- Create: `svt_pcie_integration/uvm/pcie_svt_switch_enum_registry.sv`
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_switch_enumeration_vseq.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_env.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_virtual_sequencer.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`
- Test: `svt_pcie_integration/sim/build_switch_enum.*/run.log`

- [ ] **Step 1: Add registry RED checks**

Reject null status, duplicate BDF, an Endpoint without a parent DSP, a 32-bit
or non-Prefetchable BAR, overlapping BARs, and a BAR outside the parent DSP
window. Require one USP, four DSPs, four Endpoints, and BAR apertures:

```text
BAR0/1 = 32 MiB
BAR2/3 = 64 KiB
BAR4/5 = 64 KiB
```

- [ ] **Step 2: Start the official sequence only from primary RC0**

Use:

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
    `uvm_fatal("SWITCH_ENUM", "enumeration controls failed")
enum_seq.start(p_sequencer.port_seqr[PCIE_SVT_PRIMARY_RC0]);
if (enum_seq.switch_enumeration_status == null)
    `uvm_fatal("SWITCH_ENUM", "null enumeration status")
```

Do not preload final Endpoint BDFs, BAR bases, bridge bus numbers, or windows.
Until Task 11 installs the single top-level orchestrator, the proxy test's
`+PCIE_ENUM_ONLY` branch runs configuration initialization, reset release,
active-link bring-up, sidecar readiness, and this enumeration sequence in
that order, then stops.

- [ ] **Step 3: Populate and validate the registry**

Read USP/DSP data from `switch_enumeration_status.port_info[$]`. Read each
Endpoint function-zero BDF and BAR ranges from its DSP
`ep_enumeration_status`. Read back switch Type-1 registers and Endpoint BARs
through normal Configuration Reads. Enable Memory Space and Bus Master only
after structural and aperture checks pass.

- [ ] **Step 4: Run GREEN and commit**

Run `+PCIE_ENUM_ONLY`; require five link passes, five sidecar-ready markers,
one `SWITCH_ENUM_PASS usp=1 dsp=4 ep=4 bars=12`, zero adapter drops, empty
outstanding state, and W/E/F=`0/0/0`.

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12 &&
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12 &&
  b=\$(mktemp -d build_switch_enum.XXXXXX) &&
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    +define+PCIE_TOPO_SWITCH_1X16_4X4 \
    +define+PCIE_USE_SVT_SWITCH_PROXY \
    -f pcie_svt.f -top pcie_svt_topology_top -Mdir=\$b/csrc \
    -P pli.tab msglog.o -o \$b/simv -l \$b/compile.log &&
  \$b/simv -no_save +UVM_TESTNAME=pcie_svt_switch_proxy_test \
    +PCIE_GEN=4 +PCIE_ENUM_ONLY +UVM_NO_RELNOTES -l \$b/run.log &&
  test \"\$(grep -a -c \"UVM_INFO.*\\[LINK_PASS\\]\" \$b/run.log)\" -eq 5 &&
  test \"\$(grep -a -c \"SWITCH_SIDECAR_READY port=\" \$b/run.log)\" -eq 5 &&
  test \"\$(grep -a -c \"SWITCH_ENUM_PASS usp=1 dsp=4 ep=4 bars=12\" \
    \$b/run.log)\" -eq 1 &&
  ! grep -a -q SWITCH_ADAPTER_DROP \$b/run.log &&
  grep -a -q \"UVM_WARNING *: *0\" \$b/run.log &&
  grep -a -q \"UVM_ERROR *: *0\" \$b/run.log &&
  grep -a -q \"UVM_FATAL *: *0\" \$b/run.log
"'
```

```bash
git add svt_pcie_integration/uvm/pcie_svt_switch_enum_registry.sv \
        svt_pcie_integration/uvm/sequences/pcie_svt_switch_enumeration_vseq.sv \
        svt_pcie_integration/uvm/pcie_svt_env.sv \
        svt_pcie_integration/uvm/pcie_svt_virtual_sequencer.sv \
        svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv \
        svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv
git commit -m "feat: enumerate endpoints through switch proxy"
```

### Task 10: Verify Four Downstream Write/Read Paths

**Files:**
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_switch_traffic_vseq.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`
- Test: `svt_pcie_integration/sim/build_switch_downstream.*/run.log`

- [ ] **Step 1: Add deterministic RED expectations**

For Endpoint `i`, derive the address from enumerated BAR0 plus
`64'h100 + i*64'h40`, use Tag `10'h100+i`, and payload bytes
`{8'hd0+i,8'he0+i,8'hf0+i,8'h10+i}`. Register one expected Write, Read, and
Completion through DSP `i`.

- [ ] **Step 2: Implement the four paths**

Start the official switch-enumerated memory sequence on primary RC0. Constrain
the target DSP and BAR0 range from the registry, not a hard-coded final BAR.
Bound each read Completion to 100 us. Check both sidecar wire signatures and
Endpoint target-memory readback.

Add one temporary execution branch selected by the exact bare plusarg
`+PCIE_DOWNSTREAM_ONLY`. Reject duplicates, valued forms, or combination with
`+PCIE_LINK_ONLY`/`+PCIE_ENUM_ONLY`. The branch runs the same stages as enum
mode, then starts only the downstream half of
`pcie_svt_switch_traffic_vseq`. Task 11 moves this behavior into the single
top-level orchestrator.

- [ ] **Step 3: Run GREEN and commit**

Require exactly four `DOWNSTREAM_PATH_PASS`, no wrong egress, no duplicate or
unmatched Completion, zero drops, and W/E/F=`0/0/0`.

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12 &&
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12 &&
  b=\$(mktemp -d build_switch_downstream.XXXXXX) &&
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    +define+PCIE_TOPO_SWITCH_1X16_4X4 \
    +define+PCIE_USE_SVT_SWITCH_PROXY \
    -f pcie_svt.f -top pcie_svt_topology_top -Mdir=\$b/csrc \
    -P pli.tab msglog.o -o \$b/simv -l \$b/compile.log &&
  \$b/simv -no_save +UVM_TESTNAME=pcie_svt_switch_proxy_test \
    +PCIE_GEN=4 +PCIE_DOWNSTREAM_ONLY +UVM_NO_RELNOTES -l \$b/run.log &&
  test \"\$(grep -a -c \"UVM_INFO.*\\[LINK_PASS\\]\" \$b/run.log)\" -eq 5 &&
  test \"\$(grep -a -c \"SWITCH_SIDECAR_READY port=\" \$b/run.log)\" -eq 5 &&
  test \"\$(grep -a -c \"SWITCH_ENUM_PASS usp=1 dsp=4 ep=4 bars=12\" \
    \$b/run.log)\" -eq 1 &&
  test \"\$(grep -a -c DOWNSTREAM_PATH_PASS \$b/run.log)\" -eq 4 &&
  ! grep -a -E -q \
    \"SWITCH_WRONG_EGRESS|SWITCH_DUPLICATE|SWITCH_UNMATCHED_CPL|SWITCH_ADAPTER_DROP\" \
    \$b/run.log &&
  grep -a -q \"UVM_WARNING *: *0\" \$b/run.log &&
  grep -a -q \"UVM_ERROR *: *0\" \$b/run.log &&
  grep -a -q \"UVM_FATAL *: *0\" \$b/run.log
"'
```

```bash
git add svt_pcie_integration/uvm/sequences/pcie_svt_switch_traffic_vseq.sv \
        svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv \
        svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv
git commit -m "test: verify four downstream switch paths"
```

### Task 11: Verify Upstream Writes and Orchestrate the Full Flow

**Files:**
- Modify: `svt_pcie_integration/uvm/sequences/pcie_svt_switch_traffic_vseq.sv`
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_switch_proxy_vseq.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_base_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`
- Test: `svt_pcie_integration/sim/build_switch_full.*/run.log`

- [ ] **Step 1: Add upstream RED expectations**

Use RC receive base `64'h0000_0000_1000_0000` and offset `i*64'h1000`.
Require that range to be outside every downstream window. Endpoint `i` uses
Tag `10'h180+i` and payload `{8'ha0+i,8'hb0+i,8'hc0+i,8'hd0+i}`.

- [ ] **Step 2: Enable primary RC target memory and send four writes**

Start `svt_pcie_target_app_service_set_completer_space_enable_sequence` on
primary RC0 `target_seqr[0]` with `io_select==0` and `data==1`. Start one Memory
Write from each primary Endpoint. Require routing to USP, one sidecar-observed
wire copy, and correct RC target-memory content before emitting
`UPSTREAM_PATH_PASS`.

- [ ] **Step 3: Implement strict stage ownership**

`pcie_svt_switch_proxy_vseq` runs exactly:

```text
CFG_INIT
RESET_RELEASE_CHECK
ACTIVE_LINK_BRINGUP
SIDECAR_READY_CHECK
ENUMERATION
TRAFFIC
FINAL_CHECK
```

`+PCIE_LINK_ONLY` stops after active links and optional sidecar readiness.
`+PCIE_ENUM_ONLY` stops after enumeration. `+PCIE_DOWNSTREAM_ONLY` stops after
the four downstream paths and does not run upstream traffic. These three
bare plusargs are pairwise mutually exclusive; duplicates and valued forms
are fatal. Full mode omits all three. The proxy test starts only this virtual
sequence; the base test must not also start the peer smoke sequence. Emit
exactly one `SWITCH_STAGE_PASS stage=<stage-name>` after every completed stage
and never before its checks pass.

`FINAL_CHECK` validates the registry, scoreboard, all adapter queues, zero
unexpected Target transmissions, zero drops, and an empty outstanding table.
It emits exactly five
`SWITCH_ADAPTER_REPORT port=<i> request_q=0 completion_q=0 drops=0 unexpected_target_tx=0`
records followed by one
`SWITCH_FINAL_PASS outstanding=0 scoreboard=0` record.

- [ ] **Step 4: Run Gen4 full-flow GREEN and commit**

Require five link passes, five sidecar-ready markers, one enum pass, four
downstream passes, four upstream passes, one pass marker for every stage, and
W/E/F=`0/0/0`.

```bash
ssh ubuntu@10.11.10.53 'bash -lic "
  cd /home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/svt_pcie_integration/sim &&
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12 &&
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12 &&
  b=\$(mktemp -d build_switch_full.XXXXXX) &&
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    +define+PCIE_TOPO_SWITCH_1X16_4X4 \
    +define+PCIE_USE_SVT_SWITCH_PROXY \
    -f pcie_svt.f -top pcie_svt_topology_top -Mdir=\$b/csrc \
    -P pli.tab msglog.o -o \$b/simv -l \$b/compile.log &&
  \$b/simv -no_save +UVM_TESTNAME=pcie_svt_switch_proxy_test \
    +PCIE_GEN=4 +UVM_NO_RELNOTES -l \$b/run.log &&
  test \"\$(grep -a -c \"UVM_INFO.*\\[LINK_PASS\\]\" \$b/run.log)\" -eq 5 &&
  test \"\$(grep -a -c \"SWITCH_SIDECAR_READY port=\" \$b/run.log)\" -eq 5 &&
  test \"\$(grep -a -c \"SWITCH_ENUM_PASS usp=1 dsp=4 ep=4 bars=12\" \
    \$b/run.log)\" -eq 1 &&
  test \"\$(grep -a -c DOWNSTREAM_PATH_PASS \$b/run.log)\" -eq 4 &&
  test \"\$(grep -a -c UPSTREAM_PATH_PASS \$b/run.log)\" -eq 4 &&
  test \"\$(grep -a -c \"SWITCH_STAGE_PASS stage=\" \$b/run.log)\" -eq 7 &&
  test \"\$(grep -a -c \"SWITCH_ADAPTER_REPORT port=.*request_q=0 completion_q=0 drops=0 unexpected_target_tx=0\" \
    \$b/run.log)\" -eq 5 &&
  test \"\$(grep -a -c \"SWITCH_FINAL_PASS outstanding=0 scoreboard=0\" \
    \$b/run.log)\" -eq 1 &&
  grep -a -q \"UVM_WARNING *: *0\" \$b/run.log &&
  grep -a -q \"UVM_ERROR *: *0\" \$b/run.log &&
  grep -a -q \"UVM_FATAL *: *0\" \$b/run.log
"'
```

```bash
git add svt_pcie_integration/uvm/sequences/pcie_svt_switch_traffic_vseq.sv \
        svt_pcie_integration/uvm/sequences/pcie_svt_switch_proxy_vseq.sv \
        svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv \
        svt_pcie_integration/uvm/pcie_svt_base_test.sv \
        svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv
git commit -m "test: orchestrate full SVT switch proxy flow"
```

### Task 12: Run the Required Matrix and Document Reproduction

**Files:**
- Modify: `svt_pcie_integration/sim/README.md`
- Test: four fresh switch-proxy full-flow logs
- Test: two fresh switch-proxy link-only performance logs
- Test: four fresh single-Endpoint x16 regression logs

- [ ] **Step 1: Add exact clean-checkout commands**

Document the Task 3/4 switch unit command, converter and adapter unit commands,
proxy compile command, link-only baseline commands, enum-only command, and
full-flow matrix. State that the full proxy contains 5 primary active, 5 Proxy
active, and 5 passive agents; only link-only mode may disable sidecars.

- [ ] **Step 2: Run the four full proxy cases**

Run:

```text
Gen4 default
Gen5 default
Gen4 +PCIE_FAST_LINK_TRAIN=1
Gen5 +PCIE_FAST_LINK_TRAIN=1
```

Each requires five link passes, five sidecar-ready markers, one enumeration
pass, four downstream passes, four upstream passes, five adapter reports,
zero drops, empty scoreboard/outstanding state, and W/E/F=`0/0/0`. Gen4
requires 16 GT/s and Gen5 requires 32 GT/s; widths are one x16 and four x4.

- [ ] **Step 3: Measure the sidecar cost**

Run Gen4 link-only once with and once without
`+PCIE_DISABLE_SWITCH_SIDECARS` under `/usr/bin/time -v`. Record elapsed wall
time and maximum RSS. The disabled case proves only active link bring-up.

- [ ] **Step 4: Rebuild and run the x16 regression matrix**

Compile `PCIE_TOPO_EP_X16 + PCIE_USE_SVT_PEER` without the switch-proxy macro.
Run Gen4/Gen5 default/fast. Each log requires one link pass and
W/E/F=`0/0/0`; no Proxy or sidecar Agent may be created.

- [ ] **Step 5: Run repository and credential gates**

```bash
git diff --check
git status --short
git grep -n -E 'ghp_|github_pat_|10\.11\.10\.53.*123|license.*=' -- . && exit 1 || true
```

Confirm no `/home/ubuntu/synopsys` file, build directory, log, PLI object, or
simulation binary is tracked.

- [ ] **Step 6: Commit documentation**

```bash
git add svt_pcie_integration/sim/README.md
git commit -m "docs: add five-sidecar switch proxy matrix"
```

## Final Acceptance Checklist

- [ ] Type-1 and routing unit tests pass, including separate fatal negative
  processes.
- [ ] Converter and dual-source adapter unit tests preserve all supported
  fields and payload bytes.
- [ ] Five active link pairs reach L0 at the requested speed and width.
- [ ] Five passive sidecars remain input-only and publish RX/TX observations.
- [ ] Official enumeration reports one USP, four DSPs, four Endpoints, and
  twelve required BAR apertures.
- [ ] Four downstream and four upstream paths pass wire and memory checks.
- [ ] All four full-flow matrix logs have zero drops, empty state, and
  W/E/F=`0/0/0`.
- [ ] Original single-Endpoint x16 default/fast Gen4/Gen5 regressions remain
  clean.
