# SVT PCIe Real Switch DUT Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a five-VIP Serial environment that compiles and initializes without a DUT today, then performs five-link training, official Switch enumeration, BAR validation, and RC↔4-EP MWr/MRd when a real Switch adapter is supplied.

**Architecture:** Keep the existing five primary Device Agents and place a stable HDL wrapper between their Serial bundles and either the idle placeholder or a user-supplied real-DUT adapter. Add a dedicated staged real-Switch test, split official enumeration from Proxy-only hooks, and use the validated enumeration registry to drive deterministic bidirectional traffic.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys SVT PCIe R-2020.12, VCS W-2024.09-SP1, PCIe Gen4/Gen5 Serial x16/x4, Bash, Git.

---

## Constraints and File Map

Work only in:

```text
/home/ryan/.config/superpowers/worktrees/pcie_work/svt-switch-proxy
```

Run all VCS compilation and simulation serially on `ubuntu@10.11.10.53`
from a bash login shell. Create a fresh remote staging directory with
`mktemp -d /home/ubuntu/pcie-real-switch-env.XXXXXX`; never edit the installed
Synopsys tree.

Task 9 already contains intentional uncommitted work. Preserve it, do not
discard or rewrite it, and create no intermediate commits. The final task
creates the one combined Task 9 commit requested by the user.

Files and responsibilities:

- Create `svt_pcie_integration/rtl/pcie_switch_dut_wrapper.sv`: fixed five-port
  Serial/reset boundary and placeholder/real-adapter selection.
- Modify `svt_pcie_integration/rtl/pcie_svt_topology_top.sv`: instantiate the
  stable wrapper in the non-Proxy Switch topology.
- Modify `svt_pcie_integration/rtl/pcie_svt_topology_checks.svh`: enforce legal
  macro combinations.
- Create `svt_pcie_integration/sim/pcie_real_switch_dut_adapter_compile_stub.sv`:
  test-only implementation of the adapter contract.
- Create `svt_pcie_integration/uvm/pcie_svt_real_switch_link_gate.sv`: pure
  link acceptance predicate.
- Create `svt_pcie_integration/uvm/pcie_svt_real_switch_traffic_plan.sv`:
  deterministic eight-flow address/requester/payload plan.
- Modify `svt_pcie_integration/uvm/pcie_svt_virtual_sequencer.sv`: record RC
  host-memory initialization.
- Modify `svt_pcie_integration/uvm/pcie_svt_env.sv`: create the enumeration
  registry for every Switch topology, not only Proxy mode.
- Create `svt_pcie_integration/uvm/sequences/pcie_svt_rc_host_memory_init_vseq.sv`:
  add the RC Memory Target aperture.
- Create `svt_pcie_integration/uvm/sequences/pcie_svt_real_switch_links_vseq.sv`:
  enable and gate only the five primary links.
- Create `svt_pcie_integration/uvm/sequences/pcie_svt_switch_enumeration_base_vseq.sv`:
  common official enumeration and BAR/readback logic.
- Modify `svt_pcie_integration/uvm/sequences/pcie_svt_switch_enumeration_vseq.sv`:
  retain Proxy-only pre/post hooks.
- Create `svt_pcie_integration/uvm/sequences/pcie_svt_real_switch_enumeration_vseq.sv`:
  common enumeration with no Proxy dependency.
- Create `svt_pcie_integration/uvm/sequences/pcie_svt_mem_write_read_seq.sv`:
  one deterministic MWr/MRd/readback flow.
- Create `svt_pcie_integration/uvm/sequences/pcie_svt_real_switch_traffic_vseq.sv`:
  eight-flow orchestration, watchdog, and idle gates.
- Create `svt_pcie_integration/uvm/pcie_svt_real_switch_test.sv`: strict staged
  run-mode owner.
- Modify `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`: include new
  package classes in dependency order.
- Modify `svt_pcie_integration/sim/pcie_svt.f`: compile wrapper and test.
- Create `svt_pcie_integration/sim/pcie_svt_real_switch_contract_unit_test.sv`:
  pure link/traffic-plan positives and negatives.
- Create `svt_pcie_integration/sim/check_real_switch_log.sh`: exact staged log
  gate.
- Create `svt_pcie_integration/sim/check_real_switch_log_unit_test.sh`: shell
  fixtures for the log gate.
- Modify `svt_pcie_integration/sim/README.md`: placeholder, adapter, mode, and
  future real-DUT commands.

## Task 1: Add the Focused RED Contract Tests

**Files:**

- Create: `svt_pcie_integration/sim/pcie_svt_real_switch_contract_unit_test.sv`
- Create: `svt_pcie_integration/sim/pcie_real_switch_dut_adapter_compile_stub.sv`
- Test: remote `build_real_switch_contract_red.*`

- [ ] **Step 1: Write the traffic-plan and link-gate unit test**

Create a module importing `pcie_svt_integration_pkg`. Its `make_registry()`
constructs a registry with `validated=1`, four Endpoint records keyed by
`dsp_index=0..3`, and three BAR-pair records per Endpoint. BAR0/1 bases are
`64'h0000_0001_0000_0000 + ep*64'h0800_0000`; BAR2/3 and BAR4/5 add
`64'h0200_0000` and `64'h0201_0000`. Apertures are 32 MiB, 64 KiB, 64 KiB.

The initial block must contain these exact checks:

```systemverilog
registry = make_registry();
plan = pcie_svt_real_switch_traffic_plan::type_id::create("plan");

require(pcie_svt_real_switch_link_gate::ready(
  4, 16, 1'b1, 1'b1, 1'b1, 4, 16), "Gen4 x16 ready rejected");
require(!pcie_svt_real_switch_link_gate::ready(
  4, 16, 1'b0, 1'b1, 1'b1, 4, 16), "PL-down accepted");
require(!pcie_svt_real_switch_link_gate::ready(
  5, 4, 1'b1, 1'b0, 1'b1, 5, 4), "DL-down accepted");
require(!pcie_svt_real_switch_link_gate::ready(
  5, 4, 1'b1, 1'b1, 1'b0, 5, 4), "non-L0 accepted");
require(!pcie_svt_real_switch_link_gate::ready(
  5, 4, 1'b1, 1'b1, 1'b1, 4, 4), "wrong speed accepted");
require(!pcie_svt_real_switch_link_gate::ready(
  5, 4, 1'b1, 1'b1, 1'b1, 5, 8), "wrong width accepted");

require(plan.build(registry, error), {"valid plan rejected: ", error});
require(plan.flows.size() == 8, "plan must contain eight flows");
for (int unsigned ep = 0; ep < 4; ep++) begin
  require(plan.flows[ep].direction == PCIE_SVT_FLOW_DOWNSTREAM,
          "first four flows must be downstream");
  require(plan.flows[ep].source_port == PCIE_SVT_PRIMARY_RC0,
          "downstream source must be RC0");
  require(plan.flows[ep].address ==
          registry.bar_apertures[ep * 3].base_address +
          64'h100 + ep * 64'h40, "downstream address mismatch");
  require(plan.flows[4 + ep].direction == PCIE_SVT_FLOW_UPSTREAM,
          "last four flows must be upstream");
  require(plan.flows[4 + ep].source_port == PCIE_SVT_PRIMARY_EP0 + ep,
          "upstream source mismatch");
  require(plan.flows[4 + ep].requester_id == registry.endpoints[ep].bdf,
          "upstream requester mismatch");
  for (int unsigned dw = 0; dw < 4; dw++) begin
    require(plan.flows[ep].payload[dw] ==
            (32'hd000_0000 | (ep << 12) | dw),
            "downstream payload mismatch");
    require(plan.flows[4 + ep].payload[dw] ==
            (32'he000_0000 | (ep << 12) | dw),
            "upstream payload mismatch");
  end
end
registry.validated = 1'b0;
require(!plan.build(registry, error), "unvalidated registry accepted");
require(error == "enumeration registry is not validated",
        {"unexpected error: ", error});
$display("REAL_SWITCH_CONTRACT_UNIT_PASS flows=8 link_negatives=5");
```

- [ ] **Step 2: Write the test-only adapter contract**

Create module `pcie_real_switch_dut_adapter` with `reset_asserted[4:0]`, one
x16 USP RX/TX differential bundle, and four x4 DSP RX/TX differential bundles.
Drive every `*_tx_p='0` and `*_tx_n='1`; leave all inputs observation-only.

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
  assign usp_tx_p = '0;
  assign usp_tx_n = '1;
  assign dsp0_tx_p = '0;
  assign dsp0_tx_n = '1;
  assign dsp1_tx_p = '0;
  assign dsp1_tx_n = '1;
  assign dsp2_tx_p = '0;
  assign dsp2_tx_n = '1;
  assign dsp3_tx_p = '0;
  assign dsp3_tx_n = '1;
endmodule
```

- [ ] **Step 3: Synchronize to a fresh remote stage**

```bash
stage=$(ssh ubuntu@10.11.10.53 \
  'mktemp -d /home/ubuntu/pcie-real-switch-env.XXXXXX')
echo "$stage"
rsync -a --exclude 'build*' --exclude 'simv*' --exclude 'csrc' \
  ./ ubuntu@10.11.10.53:"$stage/pcie_work/"
```

Record the printed absolute `stage` path. Do not use `--delete` later because
the stage will contain generated PLI and build evidence.

- [ ] **Step 4: Prepare the staged PLI inputs**

Open a login shell on host 53, assign `stage` to the recorded absolute path,
and run:

```bash
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT="$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12"
cd "$stage/pcie_work/svt_pcie_integration/sim"
"$PCIE_SVT_ROOT/bin/param2def.sh" \
  < "$PCIE_SVT_ROOT/verilog/src/vcs/svc_util_parms.vp" \
  > svc_util_parms.h
cc -c -I. -I"$VCS_HOME/include" -I"$PCIE_SVT_ROOT/C/include" \
  -DVCS_VERILOG -DUSE_VPI=1 -DPLI_64_BIT \
  "$PCIE_SVT_ROOT/C/src/msglog.c" -o msglog.o
"$VCS_HOME/bin/veriuser_to_pli_tab" -include "$VCS_HOME/include" \
  "$PCIE_SVT_ROOT/C/src/veriuser.c" > pli.tab
```

- [ ] **Step 5: Compile RED on host 53**

```bash
cd "$stage/pcie_work/svt_pcie_integration/sim"
b=$(mktemp -d build_real_switch_contract_red.XXXXXX)
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_SWITCH_1X16_4X4 \
  -f pcie_svt.f pcie_svt_real_switch_contract_unit_test.sv \
  -top pcie_svt_real_switch_contract_unit_test \
  -Mdir="$b/csrc" -P pli.tab msglog.o -o "$b/simv" \
  -l "$b/compile.log"
```

Expected RED: unknown types for the new link gate and traffic plan. Record the
first diagnostic and do not weaken the test.

## Task 2: Implement the Stable Wrapper and Pure Contracts

**Files:**

- Create: `svt_pcie_integration/rtl/pcie_switch_dut_wrapper.sv`
- Create: `svt_pcie_integration/uvm/pcie_svt_real_switch_link_gate.sv`
- Create: `svt_pcie_integration/uvm/pcie_svt_real_switch_traffic_plan.sv`
- Modify: `svt_pcie_integration/rtl/pcie_svt_topology_top.sv`
- Modify: `svt_pcie_integration/rtl/pcie_svt_topology_checks.svh`
- Modify: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt.f`
- Test: contract GREEN and adapter compile/elaboration

- [ ] **Step 1: Add the pure link predicate**

```systemverilog
class pcie_svt_real_switch_link_gate;
  static function bit ready(
      int unsigned expected_gen,
      int unsigned expected_width,
      bit pl_link_up,
      bit dl_link_up,
      bit in_l0,
      int unsigned actual_gen,
      int unsigned actual_width);
    return pl_link_up && dl_link_up && in_l0 &&
           (actual_gen == expected_gen) &&
           (actual_width == expected_width);
  endfunction
endclass
```

- [ ] **Step 2: Add the traffic plan**

Use these types and constants:

```systemverilog
typedef enum bit {
  PCIE_SVT_FLOW_DOWNSTREAM,
  PCIE_SVT_FLOW_UPSTREAM
} pcie_svt_real_switch_flow_direction_e;

class pcie_svt_real_switch_flow_record;
  pcie_svt_real_switch_flow_direction_e direction;
  int unsigned endpoint_index;
  int unsigned source_port;
  bit [15:0] requester_id;
  bit [63:0] address;
  bit [31:0] payload[4];
endclass

class pcie_svt_real_switch_traffic_plan extends uvm_object;
  localparam bit [63:0] HOST_BASE  = 64'h0000_0002_0000_0000;
  localparam bit [63:0] HOST_LIMIT = 64'h0000_0002_0000_ffff;
  pcie_svt_real_switch_flow_record flows[$];
  `uvm_object_utils(pcie_svt_real_switch_traffic_plan)
  function new(string name = "pcie_svt_real_switch_traffic_plan");
    super.new(name);
  endfunction
```

`build(registry, error)` must clear prior flows, reject a null/unvalidated
registry with exact error `enumeration registry is not validated`, build
one-to-one `endpoint_by_dsp[0..3]` and BAR0/1 maps, and reject duplicates or
missing records. It then pushes four downstream records followed by four
upstream records:

```systemverilog
function bit build(pcie_svt_switch_enum_registry registry,
                   output string error);
  pcie_svt_switch_enum_endpoint_record endpoint_by_dsp[4];
  pcie_svt_switch_enum_bar_record bar0_by_dsp[4];
  flows.delete();
  error = "";
  if ((registry == null) || !registry.validated) begin
    error = "enumeration registry is not validated";
    return 0;
  end
  foreach (registry.endpoints[i]) begin
    int unsigned dsp;
    dsp = registry.endpoints[i].dsp_index;
    if ((dsp >= 4) || (endpoint_by_dsp[dsp] != null)) begin
      error = "Endpoint-to-DSP mapping is not one-to-one";
      return 0;
    end
    endpoint_by_dsp[dsp] = registry.endpoints[i];
  end
  foreach (registry.bar_apertures[i]) begin
    int unsigned dsp;
    dsp = registry.bar_apertures[i].dsp_index;
    if ((dsp < 4) && (registry.bar_apertures[i].pair_index == 0)) begin
      if (bar0_by_dsp[dsp] != null) begin
        error = "DSP has duplicate BAR0/1 records";
        return 0;
      end
      bar0_by_dsp[dsp] = registry.bar_apertures[i];
    end
  end
```

Before constructing either flow for `ep`, reject a null
`endpoint_by_dsp[ep]` or `bar0_by_dsp[ep]` with
`DSP%0d has no Endpoint BAR0/1 mapping`. It then pushes four downstream
records followed by four upstream records:

```systemverilog
for (int unsigned ep = 0; ep < 4; ep++) begin
  pcie_svt_real_switch_flow_record down;
  down = new();
  down.direction = PCIE_SVT_FLOW_DOWNSTREAM;
  down.endpoint_index = ep;
  down.source_port = PCIE_SVT_PRIMARY_RC0;
  down.requester_id = 16'h0000;
  down.address = bar0_by_dsp[ep].base_address + 64'h100 + ep * 64'h40;
  if ((down.address + 15) > bar0_by_dsp[ep].limit_address) begin
    error = $sformatf("DSP%0d BAR0/1 cannot contain traffic payload", ep);
    return 0;
  end
  for (int unsigned dw = 0; dw < 4; dw++)
    down.payload[dw] = 32'hd000_0000 | (ep << 12) | dw;
  flows.push_back(down);
end
for (int unsigned ep = 0; ep < 4; ep++) begin
  pcie_svt_real_switch_flow_record up;
  up = new();
  up.direction = PCIE_SVT_FLOW_UPSTREAM;
  up.endpoint_index = ep;
  up.source_port = PCIE_SVT_PRIMARY_EP0 + ep;
  up.requester_id = endpoint_by_dsp[ep].bdf;
  up.address = HOST_BASE + ep * 64'h1000 + 64'h100;
  if ((up.address + 15) > HOST_LIMIT) begin
    error = $sformatf("EP%0d host payload exceeds range", ep);
    return 0;
  end
  for (int unsigned dw = 0; dw < 4; dw++)
    up.payload[dw] = 32'he000_0000 | (ep << 12) | dw;
  flows.push_back(up);
end
return 1;
endfunction
endclass
```

- [ ] **Step 3: Add the stable HDL wrapper**

The wrapper has the exact port list from the test stub. Its body is:

```systemverilog
`ifdef PCIE_USE_REAL_SWITCH_DUT
  pcie_real_switch_dut_adapter dut_adapter (.*);
`else
  pcie_dut_placeholder idle_dut (
    .reset(|reset_asserted),
    .usp_rx_p(usp_rx_p), .usp_rx_n(usp_rx_n),
    .usp_tx_p(usp_tx_p), .usp_tx_n(usp_tx_n),
    .dsp0_rx_p(dsp0_rx_p), .dsp0_rx_n(dsp0_rx_n),
    .dsp0_tx_p(dsp0_tx_p), .dsp0_tx_n(dsp0_tx_n),
    .dsp1_rx_p(dsp1_rx_p), .dsp1_rx_n(dsp1_rx_n),
    .dsp1_tx_p(dsp1_tx_p), .dsp1_tx_n(dsp1_tx_n),
    .dsp2_rx_p(dsp2_rx_p), .dsp2_rx_n(dsp2_rx_n),
    .dsp2_tx_p(dsp2_tx_p), .dsp2_tx_n(dsp2_tx_n),
    .dsp3_rx_p(dsp3_rx_p), .dsp3_rx_n(dsp3_rx_n),
    .dsp3_tx_p(dsp3_tx_p), .dsp3_tx_n(dsp3_tx_n)
  );
`endif
```

Replace only the non-Proxy Switch placeholder instance in
`pcie_svt_topology_top.sv`; pass all five reset bits. Leave EP x16 and 2x8
branches unchanged.

- [ ] **Step 4: Enforce macro ownership**

```systemverilog
`ifdef PCIE_USE_REAL_SWITCH_DUT
  `ifndef PCIE_TOPO_SWITCH_1X16_4X4
    `error "PCIE_USE_REAL_SWITCH_DUT requires PCIE_TOPO_SWITCH_1X16_4X4"
  `endif
  `ifdef PCIE_USE_SVT_SWITCH_PROXY
    `error "PCIE_USE_REAL_SWITCH_DUT and PCIE_USE_SVT_SWITCH_PROXY are mutually exclusive"
  `endif
  `ifdef PCIE_USE_SVT_PEER
    `error "PCIE_USE_REAL_SWITCH_DUT and PCIE_USE_SVT_PEER are mutually exclusive"
  `endif
`endif
```

- [ ] **Step 5: Register and run GREEN**

Include the link gate and traffic plan immediately after the registry. Add the
wrapper before the package/top in `pcie_svt.f`. Rsync changes, rebuild the
focused unit, run it, and require:

```text
REAL_SWITCH_CONTRACT_UNIT_PASS flows=8 link_negatives=5
UVM_FATAL : 0
```

Compile the adapter branch with the stub plus
`+define+PCIE_USE_REAL_SWITCH_DUT`; run `pcie_svt_base_test` with Gen4 and
`+PCIE_COMPILE_ONLY`. Require five primary agents, zero peer agents, and final
`0/0/0`.

## Task 3: Add RC Host Memory and Five-Primary-Link Sequences

**Files:**

- Modify: `svt_pcie_integration/uvm/pcie_svt_virtual_sequencer.sv`
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_rc_host_memory_init_vseq.sv`
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_real_switch_links_vseq.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`
- Test: package compile and contract regression

- [ ] **Step 1: Add host-memory state**

Add to `pcie_svt_virtual_sequencer`:

```systemverilog
bit rc_host_memory_initialized;
bit [63:0] rc_host_memory_base;
bit [63:0] rc_host_memory_limit;
```

- [ ] **Step 2: Implement RC Memory Target initialization**

Create `pcie_svt_rc_host_memory_init_vseq`. Validate RC0 and
`port_seqr[RC0].mem_target_seqr`, reject a second invocation, then create and
randomize:

```systemverilog
svt_pcie_mem_target_service_mem_range_sequence add_range;
add_range =
  svt_pcie_mem_target_service_mem_range_sequence::type_id::create(
    "add_rc_host_memory");
if (add_range == null)
  `uvm_fatal("RC_HOST_MEMORY", "host-memory service creation failed")
if (!add_range.randomize() with {
      service_type == svt_pcie_mem_target_service::ADD_MEM_RANGE;
      min_addr == 64'h0000_0002_0000_0000;
      max_addr == 64'h0000_0002_0000_ffff;
      attributes == 32'h0;
    })
  `uvm_fatal("RC_HOST_MEMORY", "host-memory service randomization failed")
add_range.start(p_sequencer.port_seqr[PCIE_SVT_PRIMARY_RC0].mem_target_seqr);
p_sequencer.rc_host_memory_initialized = 1'b1;
p_sequencer.rc_host_memory_base = 64'h0000_0002_0000_0000;
p_sequencer.rc_host_memory_limit = 64'h0000_0002_0000_ffff;
`uvm_info("RC_HOST_MEMORY_RANGE_READY",
  "base=0x0000000200000000 limit=0x000000020000ffff", UVM_NONE)
```

- [ ] **Step 3: Implement the five-primary link sequence**

Copy the existing child-enable watchdog without changing its 10 us deadline.
Operate only on indices RC0 and EP0..EP3, start all five child sequences
concurrently, and give each link a 3 ms deadline. Convert SVT status to the
pure predicate:

```systemverilog
actual_gen =
  (pl.current_speed == svt_pcie_pl_status::SPEED_32_0G) ? 5 :
  (pl.current_speed == svt_pcie_pl_status::SPEED_16_0G) ? 4 : 0;
reached = pcie_svt_real_switch_link_gate::ready(
  profile.max_gen, profile.link_width,
  pl.link_up, dl.dl_link_up, pl.ltssm_state == svt_pcie_types::L0,
  actual_gen, pl.negotiated_link_width);
```

On success emit five `REAL_SWITCH_LINK_PASS` records and one
`REAL_SWITCH_ALL_LINKS_PASS count=5`. The timeout fatal includes port ID,
PL-up, DL-up, LTSSM name, speed name, width, expected Gen, and expected width.

- [ ] **Step 4: Register dependencies and compile**

Include host memory after the virtual sequencer and real links after the link
child sequence. Rerun the contract unit and compile the placeholder package.
Expected: no include-order error and the unit stays GREEN.

## Task 4: Split Official Enumeration from Proxy Hooks

**Files:**

- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_switch_enumeration_base_vseq.sv`
- Modify: `svt_pcie_integration/uvm/sequences/pcie_svt_switch_enumeration_vseq.sv`
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_real_switch_enumeration_vseq.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_env.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`
- Test: registry unit and Proxy characterization

- [ ] **Step 1: Capture characterization GREEN**

Before the refactor, run the registry unit valid case and every current
negative, then compile `pcie_svt_switch_proxy_test`. Save exact markers, fatal
IDs, and zero-count summaries.

- [ ] **Step 2: Extract the common base**

Move into the base: `enum_seq`, config read/write helpers, bridge
and BAR readback, Command enable/readback, RC DL-up wait, official sequence
randomization/start, registry load, and registry finalization. Add no-op
`before_official_enumeration()` and `after_official_enumeration()` tasks plus a
virtual `report_success()`.

Declare the configuration helpers as protected virtual test seams. Keep full
DWORD writes as the default for existing callers, but pass the caller-selected
byte enable to the official sequence:

```systemverilog
protected virtual task read_config(
    bit [15:0] bdf,
    bit [11:0] byte_offset,
    output bit [31:0] data);
  svt_pcie_driver_app_transaction::completion_status_enum cpl_status;
  enum_seq.send_cfg_rd_w_switch_env(
    bdf[15:8], bdf[7:3], 8'h00, byte_offset, data, 16'h0000,
    4'hf, cpl_status);
  if (cpl_status != svt_pcie_driver_app_transaction::SUCCESSFUL)
    `uvm_fatal("SWITCH_ENUM_CFG_READ", $sformatf(
      "Configuration Read bdf=%04x offset=0x%03x completion_status=%0d",
      bdf, byte_offset, cpl_status))
endtask

protected virtual task write_config(
    bit [15:0] bdf,
    bit [11:0] byte_offset,
    bit [31:0] data,
    bit [3:0] first_dw_be = 4'hf);
  svt_pcie_driver_app_transaction::completion_status_enum cpl_status;
  enum_seq.send_cfg_wr_w_switch_env(
    bdf[15:8], bdf[7:3], 8'h00, byte_offset, data, 16'h0000,
    first_dw_be, cpl_status);
  if (cpl_status != svt_pcie_driver_app_transaction::SUCCESSFUL)
    `uvm_fatal("SWITCH_ENUM_CFG_WRITE", $sformatf(
      "Configuration Write bdf=%04x offset=0x%03x completion_status=%0d",
      bdf, byte_offset, cpl_status))
endtask
```

Enabling Memory Space and Bus Master is a read-modify-write of offset
`12'h004`, but the write enables only the lower two Command bytes. Never enable
the upper two Status bytes because nonzero Status values can contain W1C bits:

```systemverilog
read_config(bdf, 12'h004, command_status);
command_status[2:1] = 2'b11;
write_config(bdf, 12'h004, command_status, 4'b0011);
read_config(bdf, 12'h004, command_status);
if (command_status[2:1] !== 2'b11)
  `uvm_fatal("SWITCH_ENUM_COMMAND", $sformatf(
    "bdf=%04x failed to retain Memory Space and Bus Master enables; command=0x%04x",
    bdf, command_status[15:0]))
```

The base `body()` validates RC0 and the registry, invokes the before hook,
waits for RC DL-up, runs official enumeration and common validation, invokes
the after hook, then reports success. It must contain no reference to
`switch_core`, `switch_adapter`, `switch_scoreboard`, or sidecars.

- [ ] **Step 3: Retain Proxy hooks**

Make the existing class extend the base. Its before hook validates Proxy
handles, snapshots drop counts, and begins deferred enumeration. Its after
hook performs the old quiescence wait, ends deferred enumeration, and runs the
unchanged drop/outstanding checks. Preserve `SWITCH_ENUM_PASS`.

- [ ] **Step 4: Add the real-DUT subclass**

```systemverilog
class pcie_svt_real_switch_enumeration_vseq extends
    pcie_svt_switch_enumeration_base_vseq;
  `uvm_object_utils(pcie_svt_real_switch_enumeration_vseq)
  function new(string name = "pcie_svt_real_switch_enumeration_vseq");
    super.new(name);
  endfunction
  protected virtual function void report_success();
    `uvm_info("REAL_SWITCH_ENUM_PASS", $sformatf(
      "usp=%0d dsp=%0d ep=%0d bars=%0d",
      p_sequencer.switch_enum_registry.usp_count(),
      p_sequencer.switch_enum_registry.dsp_count(),
      p_sequencer.switch_enum_registry.ep_count(),
      p_sequencer.switch_enum_registry.bar_count()), UVM_NONE)
  endfunction
endclass
```

- [ ] **Step 5: Publish the registry in every Switch topology**

Create `switch_enum_registry` when `topology == PCIE_SVT_TOPO_SWITCH`, remove
its duplicate Proxy-only creation, and always assign it to the virtual
sequencer for Switch topology. Keep Switch core, adapters, callbacks,
sidecars, and scoreboard strictly under `PCIE_USE_SVT_SWITCH_PROXY`.

- [ ] **Step 6: Re-run characterization GREEN**

Rerun every baseline from Step 1. Require identical Proxy behavior and
registry negative results. Compile the non-Proxy placeholder image and require
the common base plus real subclass to compile without Proxy handles.

## Task 5: Implement Directed MWr/MRd and Eight-Flow Orchestration

**Files:**

- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_mem_write_read_seq.sv`
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_real_switch_traffic_vseq.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv`
- Test: contract unit and package compile

- [ ] **Step 1: Implement one write/readback flow**

Extend `svt_pcie_driver_app_transaction_base_sequence`. Add public inputs
`flow_index`, `endpoint_index`, `direction`, `address`, `requester_id`, and
`expected_payload[4]`; add outputs `completed` and `last_status`. Call
`super.body()`, retrieve and cast the sequencer configuration, then issue:

```systemverilog
write_tran.transaction_type = svt_pcie_driver_app_transaction::MEM_WR;
write_tran.address = address;
write_tran.length = 4;
write_tran.traffic_class = 0;
write_tran.address_translation = 0;
write_tran.first_dw_be = 4'hf;
write_tran.last_dw_be = 4'hf;
write_tran.requester_id = requester_id;
write_tran.ep = 0;
write_tran.block = 1;
write_tran.payload = new[4];
foreach (write_tran.payload[i])
  write_tran.payload[i] = expected_payload[i];
start_item(write_tran);
finish_item(write_tran);
get_response(write_tran);
```

Issue a blocking `MEM_RD` with identical address/length/BEs/requester fields,
then require:

```systemverilog
last_status == svt_pcie_driver_app_transaction::SUCCESSFUL
read_tran.payload.size() == 4
read_tran.payload[i] === expected_payload[i] for i=0..3
```

Use fatal IDs `REAL_SWITCH_TRAFFIC_COMPLETION`,
`REAL_SWITCH_TRAFFIC_LENGTH`, and `REAL_SWITCH_TRAFFIC_DATA`. Set
`completed=1` only after all comparisons, then emit one
`REAL_SWITCH_TRAFFIC_FLOW_PASS` containing flow index, direction, Endpoint,
and address.

- [ ] **Step 2: Build and start all eight flows**

The parent requires a validated registry and exactly:

```systemverilog
p_sequencer.rc_host_memory_initialized == 1'b1
p_sequencer.rc_host_memory_base == 64'h0000_0002_0000_0000
p_sequencer.rc_host_memory_limit == 64'h0000_0002_0000_ffff
```

Call `plan.build()`, create eight child sequences, copy each record, and start
all children in a `fork...join_none` loop on:

```systemverilog
p_sequencer.port_seqr[flow.source_port].driver_transaction_seqr[0]
```

Wrap the child group in one 1 ms watchdog. A timeout fatal lists every
unfinished flow and its `last_status`.

- [ ] **Step 3: Add final idle gates**

After all readbacks, start one
`svt_pcie_driver_app_service_wait_until_idle_sequence` on each of the five
`driver_seqr[0]` handles and one
`svt_pcie_target_app_service_wait_until_idle_sequence` on each of the four EP
`target_seqr[0]` handles. Run all nine under a 100 us watchdog.

No separate Memory Target idle sequence exists in R-2020.12. The four EP
posted writes are each ordered before a blocking read to the same RC host
address, and all four EP Driver Apps are in the final idle gate.

Emit after idle only:

```systemverilog
`uvm_info("REAL_SWITCH_TRAFFIC_PASS",
  "downstream=4 upstream=4 dwords_per_read=4", UVM_NONE)
```

- [ ] **Step 4: Register and compile GREEN**

Include the directed child before the traffic parent. Rerun the traffic-plan
unit and compile the package. Expected: the unit remains GREEN and both
sequences compile against the public R-2020.12 Driver/Target App APIs.

## Task 6: Add the Strict Staged Real-Switch Test

**Files:**

- Create: `svt_pcie_integration/uvm/pcie_svt_real_switch_test.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt.f`
- Test: compile-only, cfg-init, and negative placeholder modes

- [ ] **Step 1: Write strict mode parsing**

Derive from `pcie_svt_base_test`. Reuse inherited compile/cfg flags and parse
three additional bare flags with the Proxy test's exact-match pattern:
`+PCIE_LINK_ONLY`, `+PCIE_ENUM_ONLY`, and `+PCIE_TRAFFIC`. Require exactly one
of the five total modes. Reject valued, duplicate, absent, or conflicting
arguments with `PCIE_RUN_MODE`.

Under `` `ifndef PCIE_USE_REAL_SWITCH_DUT ``, reject link/enum/traffic with:

```text
real Switch link/enum/traffic requires PCIE_USE_REAL_SWITCH_DUT
```

- [ ] **Step 2: Check real-Switch ownership at elaboration**

After `super.end_of_elaboration_phase`, require:

```systemverilog
env.topology == PCIE_SVT_TOPO_SWITCH
env.active_primary_count() == 5
env.active_peer_count() == 0
env.switch_enum_registry != null
env.vseqr.switch_enum_registry == env.switch_enum_registry
```

Require all five Device virtual sequencers and
`driver_transaction_seqr[0]`; require RC0 `mem_target_seqr`; require EP0..EP3
`target_seqr[0]`.

- [ ] **Step 3: Implement the staged run phase**

Raise one objection and follow this exact order:

```systemverilog
if (compile_only) begin
  `uvm_info("REAL_SWITCH_COMPILE_READY", "active_primary=5 peer=0", UVM_NONE)
end else begin
  cfg_init.start(env.vseqr);
  host_memory_init.start(env.vseqr);
  if (cfg_init_only) begin
    `uvm_info("REAL_SWITCH_CFG_INIT_PASS",
      "active_primary=5 bar_checks=24 rc_skips=1", UVM_NONE)
  end else begin
    links.start(env.vseqr);
    if (enum_only || traffic_mode)
      enumeration.start(env.vseqr);
    if (traffic_mode)
      traffic.start(env.vseqr);
  end
end
```

Create and null-check only the sequences required by the selected stage. Drop
the objection once after the selected work.

- [ ] **Step 4: Establish test-registration RED and GREEN**

Before adding the source to `pcie_svt.f`, compile and run with
`+UVM_TESTNAME=pcie_svt_real_switch_test`; expected RED is factory test-not-
found. Add the source after the package and Proxy test, recompile, and require
factory discovery.

- [ ] **Step 5: Run the available no-DUT modes**

Without the real-DUT macro, run Gen4 and Gen5 compile and cfg:

```bash
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

Each cfg log must contain 24 `MULTI_EP_BAR_CHECK`, one
`MULTI_EP_BAR_SKIP`, five `CFG_INIT_DONE`, one
`RC_HOST_MEMORY_RANGE_READY`, one `REAL_SWITCH_CFG_INIT_PASS`, and final
Warnings/Errors/Fatals `0/0/0`.

- [ ] **Step 6: Run expected-negative mode cases**

Use separate processes for no mode, two modes, valued link, duplicate link,
and each of link/enum/traffic without `PCIE_USE_REAL_SWITCH_DUT`. Require the
exact intended `PCIE_RUN_MODE` fatal before link training; reject any timeout
or unrelated fatal.

## Task 7: Add Exact Log Gates and Commands

**Files:**

- Create: `svt_pcie_integration/sim/check_real_switch_log.sh`
- Create: `svt_pcie_integration/sim/check_real_switch_log_unit_test.sh`
- Modify: `svt_pcie_integration/sim/README.md`
- Test: shell fixtures and real placeholder logs

- [ ] **Step 1: Implement the staged checker**

Reuse `count_marker()` and `check_zero_summary()` from the passive-sidecar
checker. Accept exactly `compile|cfg|link|enum|traffic LOG`, require one each
of the zero Warning/Error/Fatal summaries, and enforce:

| Marker | compile | cfg | link | enum | traffic |
| --- | ---: | ---: | ---: | ---: | ---: |
| `REAL_SWITCH_COMPILE_READY` | 1 | 0 | 0 | 0 | 0 |
| `MULTI_EP_BAR_CHECK` | 0 | 24 | 24 | 24 | 24 |
| `MULTI_EP_BAR_SKIP` | 0 | 1 | 1 | 1 | 1 |
| `CFG_INIT_DONE` | 0 | 5 | 5 | 5 | 5 |
| `RC_HOST_MEMORY_RANGE_READY` | 0 | 1 | 1 | 1 | 1 |
| `REAL_SWITCH_CFG_INIT_PASS` | 0 | 1 | 0 | 0 | 0 |
| `REAL_SWITCH_LINK_PASS` | 0 | 0 | 5 | 5 | 5 |
| `REAL_SWITCH_ALL_LINKS_PASS` | 0 | 0 | 1 | 1 | 1 |
| `REAL_SWITCH_ENUM_PASS` | 0 | 0 | 0 | 1 | 1 |
| `REAL_SWITCH_TRAFFIC_FLOW_PASS` | 0 | 0 | 0 | 0 | 8 |
| `REAL_SWITCH_TRAFFIC_PASS` | 0 | 0 | 0 | 0 | 1 |

Exit 2 for bad CLI/unreadable log and 1 for content mismatch.

- [ ] **Step 2: Unit-test the checker**

The shell unit uses `mktemp -d` with a trap, creates five exact positive
fixtures, and requires them to pass. It then corrupts every marker class and
each severity summary one at a time and requires failure. Final marker:

```text
REAL_SWITCH_LOG_CHECKER_UNIT_PASS positive=5 negative=18
```

- [ ] **Step 3: Document all commands and boundaries**

Add placeholder compile/cfg commands, the fixed adapter port contract, the
real adapter source placed before `-f pcie_svt.f`, the required real-DUT macro,
all five modes, Gen4/Gen5, optional fast training, and checker commands. State:

```text
Current acceptance: compile/elaboration and cfg-init only; no real DUT exists.
Future real-DUT acceptance: link, enum, and traffic.
PIPE is not implemented; it replaces only the HDL transport adapter later.
```

- [ ] **Step 4: Gate the real placeholder logs**

Run the checker on both Gen4/Gen5 compile logs and both Gen4/Gen5 cfg logs.
All four must exit zero.

## Task 8: Run Remote VCS Acceptance and Existing Regressions

**Files:**

- Verify: all changed production, test, script, and documentation files
- Test host: `10.11.10.53`

- [ ] **Step 1: Refresh the remote stage**

```bash
rsync -a --exclude 'build*' --exclude 'simv*' --exclude 'csrc' \
  ./ ubuntu@10.11.10.53:"$stage/pcie_work/"
```

Do not use `--delete`; retain remote PLI/build evidence.

- [ ] **Step 2: Prepare PLI once**

On host 53 in a bash login shell:

```bash
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT="$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12"
cd "$stage/pcie_work/svt_pcie_integration/sim"
"$PCIE_SVT_ROOT/bin/param2def.sh" \
  < "$PCIE_SVT_ROOT/verilog/src/vcs/svc_util_parms.vp" \
  > svc_util_parms.h
cc -c -I. -I"$VCS_HOME/include" -I"$PCIE_SVT_ROOT/C/include" \
  -DVCS_VERILOG -DUSE_VPI=1 -DPLI_64_BIT \
  "$PCIE_SVT_ROOT/C/src/msglog.c" -o msglog.o
"$VCS_HOME/bin/veriuser_to_pli_tab" -include "$VCS_HOME/include" \
  "$PCIE_SVT_ROOT/C/src/veriuser.c" > pli.tab
```

- [ ] **Step 3: Run focused units serially**

Run one at a time:

```text
pcie_svt_real_switch_contract_unit_test
pcie_svt_ep_bar_sizing_callback_unit_test
pcie_svt_switch_enum_registry_unit_test valid and every negative
pcie_svt_tlp_converter_unit_test
pcie_svt_switch_adapter_unit_test default/dynamic/focused
pcie_tl_switch_proxy_unit_test complete matrix
check_real_switch_log_unit_test.sh
```

Require intended positive markers and `0/0/0`; require negative cases to match
only their expected fatal ID/message.

- [ ] **Step 4: Build the placeholder image once**

```bash
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

Run and gate Gen4/Gen5 compile and cfg as Tasks 6-7 specify.

- [ ] **Step 5: Compile the real-adapter branch with the stub**

Add `pcie_real_switch_dut_adapter_compile_stub.sv` and
`+define+PCIE_USE_REAL_SWITCH_DUT`. Run only `+PCIE_COMPILE_ONLY` at Gen4 and
Gen5. Require adapter elaboration and `0/0/0`. Do not run link/enum/traffic
against the idle stub.

- [ ] **Step 6: Run representative existing regressions**

Run the accepted EP x16 Gen4/Gen5 peer links, two-EP x8 compile/cfg, Switch
base cfg-init, and the complete Task 9 focused matrix. Require unchanged
markers and severity counts. Record the new aggregate pass count/digest;
compare unchanged cases individually to baseline aggregate digest
`1d3c8bf88e18ee9b7cc8c27dc313c16022d10cf485691822592ab7006759fe62`
rather than expecting the aggregate itself to stay unchanged after new tests.

- [ ] **Step 7: Record the deferred real-DUT boundary**

Validation notes must say exactly:

```text
Not executed: +PCIE_LINK_ONLY, +PCIE_ENUM_ONLY, +PCIE_TRAFFIC.
Reason: no real Switch DUT or functional adapter was supplied.
Implemented and compiled: all three stages and their public SVT dependencies.
```

Do not label those stages passed.

## Task 9: Final Review, Hygiene, and Single Commit

**Files:**

- Modify: `svt_pcie_integration/uvm/sequences/pcie_svt_switch_enumeration_base_vseq.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt_real_switch_sequences_unit_test.sv`
- Verify: focused sequence unit, package/placeholder compile gate, and quick
  local checks
- Review: complete Task 9 worktree diff
- Include: approved design and this plan

Complete this hardening RED/GREEN before the final hygiene and staging steps
below. Task 8 is the already-recorded GREEN baseline. The helper-seam edit and
probe are one RED patch protected by that baseline: first make the current I/O
behavior observable without changing it, then add the failing assertion. Do
not create an intermediate commit; all edits remain part of the one final
Task 9 commit.

Task 4 records the corrected target contract, but Tasks 1 through 8 have
already run against the present implementation, whose helpers are non-virtual
and whose Command write still uses the full-DWORD byte enable. Do not
retroactively treat the Task 4 target text as implemented; H1 through H7 are
the executable hardening sequence for the current worktree.

- [ ] **Hardening H1: Add the behavior-preserving virtual seam**

In `pcie_svt_switch_enumeration_base_vseq.sv`, replace the current helpers
with the following complete implementations. This refactor makes dispatch
observable and adds a defaulted byte-enable argument, but intentionally leaves
the Command-register caller unchanged, so it still takes the `4'hf` default:

```systemverilog
protected virtual task read_config(
    bit [15:0] bdf,
    bit [11:0] byte_offset,
    output bit [31:0] data);
  svt_pcie_driver_app_transaction::completion_status_enum cpl_status;
  enum_seq.send_cfg_rd_w_switch_env(
    bdf[15:8], bdf[7:3], 8'h00, byte_offset, data, 16'h0000,
    4'hf, cpl_status);
  if (cpl_status != svt_pcie_driver_app_transaction::SUCCESSFUL)
    `uvm_fatal("SWITCH_ENUM_CFG_READ", $sformatf(
      "Configuration Read bdf=%04x offset=0x%03x completion_status=%0d",
      bdf, byte_offset, cpl_status))
endtask

protected virtual task write_config(
    bit [15:0] bdf,
    bit [11:0] byte_offset,
    bit [31:0] data,
    bit [3:0] first_dw_be = 4'hf);
  svt_pcie_driver_app_transaction::completion_status_enum cpl_status;
  enum_seq.send_cfg_wr_w_switch_env(
    bdf[15:8], bdf[7:3], 8'h00, byte_offset, data, 16'h0000,
    first_dw_be, cpl_status);
  if (cpl_status != svt_pcie_driver_app_transaction::SUCCESSFUL)
    `uvm_fatal("SWITCH_ENUM_CFG_WRITE", $sformatf(
      "Configuration Write bdf=%04x offset=0x%03x completion_status=%0d",
      bdf, byte_offset, cpl_status))
endtask
```

Leave this existing call exactly as-is for RED:

```systemverilog
write_config(bdf, 12'h004, command_status);
```

- [ ] **Hardening H2: Add the complete failing Command-register probe**

In `pcie_svt_real_switch_sequences_unit_test.sv`, add this class after
`pcie_svt_real_switch_links_probe`. The two read values model nonzero,
W1C-like Status bits and non-target Command bits `0`, `8`, and `10`, while
allowing the existing Command readback check to pass. Target bits `[2:1]` start
clear and are the only Command bits the RMW may change:

```systemverilog
class pcie_svt_switch_enumeration_command_probe extends
    pcie_svt_switch_enumeration_base_vseq;
  int unsigned read_count;
  int unsigned write_count;
  bit [15:0] captured_bdf;
  bit [11:0] captured_offset;
  bit [31:0] captured_data;
  bit [3:0] captured_first_dw_be;

  function new(
      string name = "pcie_svt_switch_enumeration_command_probe");
    super.new(name);
  endfunction

  task exercise_enable(bit [15:0] bdf);
    enable_memory_and_bus_master(bdf);
  endtask

  protected virtual task read_config(
      bit [15:0] bdf,
      bit [11:0] byte_offset,
      output bit [31:0] data);
    if (byte_offset != 12'h004)
      `uvm_fatal("REAL_SWITCH_SEQUENCES_TEST", $sformatf(
        "Command probe read unexpected offset=0x%03x", byte_offset))
    read_count++;
    case (read_count)
      1: data = 32'hf900_0501;
      2: data = 32'hf900_0507;
      default:
        `uvm_fatal("REAL_SWITCH_SEQUENCES_TEST", $sformatf(
          "Command probe unexpected read count=%0d", read_count))
    endcase
  endtask

  protected virtual task write_config(
      bit [15:0] bdf,
      bit [11:0] byte_offset,
      bit [31:0] data,
      bit [3:0] first_dw_be = 4'hf);
    write_count++;
    captured_bdf = bdf;
    captured_offset = byte_offset;
    captured_data = data;
    captured_first_dw_be = first_dw_be;
  endtask
endclass
```

Add this declaration to the existing `initial` block declarations:

```systemverilog
pcie_svt_switch_enumeration_command_probe command_probe;
```

After the existing host-memory assertions, add all of these assertions in the
shown order:

```systemverilog
command_probe = new();
command_probe.exercise_enable(16'h0100);
require(command_probe.read_count == 2,
        $sformatf("Command probe reads expected=2 got=%0d",
                  command_probe.read_count));
require(command_probe.write_count == 1,
        $sformatf("Command probe writes expected=1 got=%0d",
                  command_probe.write_count));
require(command_probe.captured_bdf == 16'h0100,
        $sformatf("Command write BDF expected=0100 got=%04h",
                  command_probe.captured_bdf));
require(command_probe.captured_offset == 12'h004,
        $sformatf("Command write offset expected=004 got=%03h",
                  command_probe.captured_offset));
require(command_probe.captured_data == 32'hf900_0507,
        $sformatf("Command write DWORD expected=f9000507 got=%08h",
                  command_probe.captured_data));
require(command_probe.captured_data[2:1] == 2'b11,
        $sformatf("Command bits expected=11 got=%02b",
                  command_probe.captured_data[2:1]));
require(command_probe.captured_first_dw_be == 4'b0011,
        $sformatf(
          "Command-register write byte enable expected=0011 got=%04b",
          command_probe.captured_first_dw_be));
require((command_probe.captured_first_dw_be & 4'b1100) == 4'b0000,
        $sformatf("Status-byte enables expected=00 got=%02b",
                  command_probe.captured_first_dw_be[3:2]));
`ifdef PCIE_TASK9_COMMAND_BE_EXPECT_RED
  $display("REAL_SWITCH_COMMAND_BE_RED_MISSED");
`endif
```

Replace the final success marker with:

```systemverilog
$display({"TASK3_SEQUENCE_STATE_UNIT_PASS wait_wakes=1 ",
          "sticky_drop=1 reservation_rejects=2 command_be=0011 ",
          "status_bytes_disabled=1"});
```

Because H1 made both helpers virtual before this test runs, the inherited
`enable_memory_and_bus_master()` dispatches to these overrides. The Command
call still omits the fourth argument, so the captured value is reliably
`4'b1111`; RED must be a compiled runtime failure at the byte-enable assertion.
The exact DWORD assertion separately proves the RMW preserves non-target
Command bits `0`, `8`, and `10` plus the upper W1C-like Status half while setting
only target bits `[2:1]`.

- [ ] **Hardening H3: Sync and compile the RED unit without a compile timeout**

Use the existing Task 8 stage and never use `--delete`:

```bash
stage=/home/ubuntu/pcie-real-switch-env.mGUA2R
rsync -a --exclude 'build*' --exclude 'simv*' --exclude 'csrc' \
  ./ ubuntu@10.11.10.53:"$stage/pcie_work/"
```

Open a bash login shell on host 53. Use `/dev/shm` for the build and the exact
evidence directory below. Run only one VCS build at a time. Do not wrap the
`vcs` compile in `timeout`; a full focused compile may exceed five minutes.
Never place a build directory on the root disk; only the archived logs, RCs,
gates, and checksums belong under the evidence directory.

```bash
stage=/home/ubuntu/pcie-real-switch-env.mGUA2R
evidence_root="$stage/task9_command_be_evidence"
test ! -e "$evidence_root"
evidence_dir="$evidence_root/01_red"
mkdir -p "$evidence_dir"
cd "$stage/pcie_work/svt_pcie_integration/sim"
red_build=$(mktemp -d /dev/shm/pcie_task9_command_red.XXXXXX)
mkdir -p "$red_build/tmp"

set +e
TMPDIR="$red_build/tmp" vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_SWITCH_1X16_4X4 \
  +define+PCIE_TASK9_COMMAND_BE_EXPECT_RED \
  -f pcie_svt.f pcie_svt_real_switch_sequences_unit_test.sv \
  -top pcie_svt_real_switch_sequences_unit_test \
  -Mdir="$red_build/csrc" -P pli.tab msglog.o \
  -o "$red_build/simv" -l "$red_build/compile.log"
red_compile_rc=$?
set -e
printf 'red_compile_rc=%s\n' "$red_compile_rc" > "$evidence_dir/rc.txt"
cp "$red_build/compile.log" "$evidence_dir/compile.log"
if [ "$red_compile_rc" -ne 0 ]; then
  (cd "$evidence_dir" && \
    sha256sum compile.log rc.txt > SHA256SUMS && \
    sha256sum -c SHA256SUMS)
  case "$red_build" in
    /dev/shm/pcie_task9_command_red.*) rm -rf -- "$red_build" ;;
    *) exit 1 ;;
  esac
  exit 1
fi
```

- [ ] **Hardening H4: Run and gate the exact RED failure**

Apply `timeout` only to `simv`. Do not require a nonzero simulation process RC;
some UVM fatal exits return zero. Instead gate the exact UVM event and reject
the success/missed/timeout alternatives:

```bash
set +e
timeout -k 10s 5m "$red_build/simv" -no_save +UVM_NO_RELNOTES \
  -l "$red_build/run.log"
red_sim_rc=$?
set -e

red_id_count=$(grep -a -E -c \
  'UVM_FATAL.*\[REAL_SWITCH_SEQUENCES_TEST\]' \
  "$red_build/run.log" || true)
red_message_count=$(grep -a -F -c \
  'Command-register write byte enable expected=0011 got=1111' \
  "$red_build/run.log" || true)
red_total_fatal_events=$(grep -a -E -c 'UVM_FATAL.*\[[^]]+\]' \
  "$red_build/run.log" || true)
red_success_count=$(grep -a -F -c \
  'TASK3_SEQUENCE_STATE_UNIT_PASS' "$red_build/run.log" || true)
red_missed_count=$(grep -a -F -c \
  'REAL_SWITCH_COMMAND_BE_RED_MISSED' "$red_build/run.log" || true)
red_timeout_count=0
case "$red_sim_rc" in
  124|137) red_timeout_count=1 ;;
esac

printf 'red_sim_rc=%s\n' "$red_sim_rc" >> "$evidence_dir/rc.txt"
printf '%s\n' \
  "event_id=$red_id_count" \
  "exact_message=$red_message_count" \
  "total_fatal_events=$red_total_fatal_events" \
  "success_marker=$red_success_count" \
  "missed_sentinel=$red_missed_count" \
  "timeout=$red_timeout_count" > "$evidence_dir/gates.txt"
cp "$red_build/run.log" "$evidence_dir/run.log"
(cd "$evidence_dir" && \
  sha256sum compile.log run.log rc.txt gates.txt > SHA256SUMS && \
  sha256sum -c SHA256SUMS)

red_gate_rc=0
test "$red_id_count" -eq 1 || red_gate_rc=1
test "$red_message_count" -eq 1 || red_gate_rc=1
test "$red_total_fatal_events" -eq 1 || red_gate_rc=1
test "$red_success_count" -eq 0 || red_gate_rc=1
test "$red_missed_count" -eq 0 || red_gate_rc=1
test "$red_timeout_count" -eq 0 || red_gate_rc=1
case "$red_build" in
  /dev/shm/pcie_task9_command_red.*) rm -rf -- "$red_build" ;;
  *) exit 1 ;;
esac
test "$red_gate_rc" -eq 0
```

Any compile failure, null-handle failure, unrelated UVM event, missed sentinel,
or simulation timeout is an invalid RED and must be diagnosed before GREEN.

- [ ] **Hardening H5: Make the one-line GREEN behavior change**

In `enable_memory_and_bus_master()`, change only the Command-register call:

```systemverilog
write_config(bdf, 12'h004, command_status, 4'b0011);
```

Keep the RMW data and readback verification unchanged. Do not mask the upper
Status value in software; `4'b0011` is what prevents both W1C-sensitive Status
bytes from being written.

- [ ] **Hardening H6: Sync, rebuild, and run the focused GREEN**

Rsync without `--delete`, then use a fresh `/dev/shm` build in a host-53 bash
login shell. Do not define `PCIE_TASK9_COMMAND_BE_EXPECT_RED`:
The standalone unit may complete without printing a UVM report summary, so
gate anchored severity-event lines directly and require zero events.

```bash
stage=/home/ubuntu/pcie-real-switch-env.mGUA2R
rsync -a --exclude 'build*' --exclude 'simv*' --exclude 'csrc' \
  ./ ubuntu@10.11.10.53:"$stage/pcie_work/"
```

```bash
stage=/home/ubuntu/pcie-real-switch-env.mGUA2R
evidence_dir="$stage/task9_command_be_evidence/02_green"
mkdir -p "$evidence_dir"
cd "$stage/pcie_work/svt_pcie_integration/sim"
green_build=$(mktemp -d /dev/shm/pcie_task9_command_green.XXXXXX)
mkdir -p "$green_build/tmp"

set +e
TMPDIR="$green_build/tmp" vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_SWITCH_1X16_4X4 \
  -f pcie_svt.f pcie_svt_real_switch_sequences_unit_test.sv \
  -top pcie_svt_real_switch_sequences_unit_test \
  -Mdir="$green_build/csrc" -P pli.tab msglog.o \
  -o "$green_build/simv" -l "$green_build/compile.log"
green_compile_rc=$?
set -e
printf 'green_compile_rc=%s\n' "$green_compile_rc" > "$evidence_dir/rc.txt"
cp "$green_build/compile.log" "$evidence_dir/compile.log"
if [ "$green_compile_rc" -ne 0 ]; then
  (cd "$evidence_dir" && \
    sha256sum compile.log rc.txt > SHA256SUMS && \
    sha256sum -c SHA256SUMS)
  case "$green_build" in
    /dev/shm/pcie_task9_command_green.*) rm -rf -- "$green_build" ;;
    *) exit 1 ;;
  esac
  exit 1
fi

set +e
timeout -k 10s 5m "$green_build/simv" -no_save +UVM_NO_RELNOTES \
  -l "$green_build/run.log"
green_sim_rc=$?
set -e
green_timeout_count=0
case "$green_sim_rc" in
  124|137) green_timeout_count=1 ;;
esac
green_success_count=$(grep -a -F -c \
  'TASK3_SEQUENCE_STATE_UNIT_PASS wait_wakes=1 sticky_drop=1 reservation_rejects=2 command_be=0011 status_bytes_disabled=1' \
  "$green_build/run.log" || true)
green_warning_events=$(grep -a -E -c \
  '^[[:space:]]*UVM_WARNING.*\[[^]]+\]' \
  "$green_build/run.log" || true)
green_error_events=$(grep -a -E -c \
  '^[[:space:]]*UVM_ERROR.*\[[^]]+\]' \
  "$green_build/run.log" || true)
green_fatal_events=$(grep -a -E -c \
  '^[[:space:]]*UVM_FATAL.*\[[^]]+\]' \
  "$green_build/run.log" || true)

printf 'green_sim_rc=%s\n' "$green_sim_rc" >> "$evidence_dir/rc.txt"
printf '%s\n' \
  "success_marker=$green_success_count" \
  "warning_events=$green_warning_events" \
  "error_events=$green_error_events" \
  "fatal_events=$green_fatal_events" \
  "timeout=$green_timeout_count" > "$evidence_dir/gates.txt"
cp "$green_build/run.log" "$evidence_dir/run.log"
(cd "$evidence_dir" && \
  sha256sum compile.log run.log rc.txt gates.txt > SHA256SUMS && \
  sha256sum -c SHA256SUMS)

green_gate_rc=0
test "$green_sim_rc" -eq 0 || green_gate_rc=1
test "$green_success_count" -eq 1 || green_gate_rc=1
test "$green_warning_events" -eq 0 || green_gate_rc=1
test "$green_error_events" -eq 0 || green_gate_rc=1
test "$green_fatal_events" -eq 0 || green_gate_rc=1
test "$green_timeout_count" -eq 0 || green_gate_rc=1
case "$green_build" in
  /dev/shm/pcie_task9_command_green.*) rm -rf -- "$green_build" ;;
  *) exit 1 ;;
esac
test "$green_gate_rc" -eq 0
```

- [ ] **Hardening H7: Rebuild the placeholder integration gate once**

The byte-enable behavior is enumeration-only. The focused probe is its semantic
proof; the placeholder compile-only runs are the package/top integration
proof. Build once in `/dev/shm`, run Gen4 and Gen5 compile-only, and do not run
or claim real-DUT enumeration. Keep VCS scratch on the separate per-user tmpfs,
record both mounts before, during, and after compile, and stop if either mount
falls below 512 MiB free. Run VCS in its own process group: the monitor records
each 15-second sample, writes the floor-breach sentinel, sends TERM then KILL to
that group on a breach, and `wait` preserves the resulting VCS status. Do not
start either compile-only simulation unless VCS and its monitor both return zero
and no breach was recorded:

```bash
stage=/home/ubuntu/pcie-real-switch-env.mGUA2R
evidence_dir="$stage/task9_command_be_evidence/03_placeholder"
mkdir -p "$evidence_dir"
cd "$stage/pcie_work/svt_pcie_integration/sim"
placeholder_build=
placeholder_tmp=
placeholder_compile_pid=
placeholder_monitor_pid=
placeholder_compile_reaped=0
placeholder_monitor_reaped=0

cleanup_task9_placeholder() {
  task9_cleanup_rc=$1
  trap - EXIT HUP INT TERM

  case "${placeholder_monitor_pid:-}" in
    ''|*[!0-9]*) ;;
    *)
      if [ "${placeholder_monitor_reaped:-0}" -ne 1 ] && \
         kill -0 "$placeholder_monitor_pid" 2>/dev/null; then
        kill -TERM "$placeholder_monitor_pid" 2>/dev/null || true
      fi ;;
  esac

  case "${placeholder_compile_pid:-}" in
    ''|*[!0-9]*) ;;
    *)
      if [ "${placeholder_compile_reaped:-0}" -ne 1 ] && \
         kill -0 -- "-$placeholder_compile_pid" 2>/dev/null; then
        kill -TERM -- "-$placeholder_compile_pid" 2>/dev/null || true
        task9_cleanup_wait=0
        while kill -0 -- "-$placeholder_compile_pid" 2>/dev/null && \
              [ "$task9_cleanup_wait" -lt 10 ]; do
          sleep 1
          task9_cleanup_wait=$((task9_cleanup_wait + 1))
        done
        kill -KILL -- "-$placeholder_compile_pid" 2>/dev/null || true
      fi
      wait "$placeholder_compile_pid" 2>/dev/null || true ;;
  esac

  case "${placeholder_monitor_pid:-}" in
    ''|*[!0-9]*) ;;
    *) wait "$placeholder_monitor_pid" 2>/dev/null || true ;;
  esac

  case "${placeholder_build:-}" in
    /dev/shm/pcie_task9_command_placeholder.*)
      if [ -e "$placeholder_build" ]; then
        rm -rf -- "$placeholder_build"
      fi ;;
  esac
  case "${placeholder_tmp:-}" in
    /run/user/1000/pcie_task9_command_tmp.*)
      if [ -e "$placeholder_tmp" ]; then
        rm -rf -- "$placeholder_tmp"
      fi ;;
  esac
  exit "$task9_cleanup_rc"
}

placeholder_build=$(mktemp -d /dev/shm/pcie_task9_command_placeholder.XXXXXX)
trap 'cleanup_task9_placeholder $?' EXIT
trap 'cleanup_task9_placeholder 129' HUP
trap 'cleanup_task9_placeholder 130' INT
trap 'cleanup_task9_placeholder 143' TERM
placeholder_tmp=$(mktemp -d \
  /run/user/1000/pcie_task9_command_tmp.XXXXXX)
placeholder_min_free=536870912
placeholder_samples="$evidence_dir/resource_samples.txt"
placeholder_breach="$placeholder_build/resource_floor_breach"
: > "$placeholder_samples"
: > "$evidence_dir/gates.txt"
: > "$placeholder_build/compile.log"

sample_placeholder_resources() {
  placeholder_phase=$1
  sample_shm_free=$(df --output=avail -B1 /dev/shm | \
    awk 'NR == 2 {print $1}')
  sample_tmp_free=$(df --output=avail -B1 /run/user/1000 | \
    awk 'NR == 2 {print $1}')
  if [ "$placeholder_phase" = before ]; then
    printf 'timestamp=%s phase=%s dev_shm_free=%s run_user_free=%s build=%s tmp=%s\n' \
      "$(date --iso-8601=seconds)" "$placeholder_phase" \
      "$sample_shm_free" "$sample_tmp_free" \
      "$placeholder_build" "$placeholder_tmp"
  else
    printf 'timestamp=%s phase=%s dev_shm_free=%s run_user_free=%s\n' \
      "$(date --iso-8601=seconds)" "$placeholder_phase" \
      "$sample_shm_free" "$sample_tmp_free"
  fi >> "$placeholder_samples"
}

minimum_placeholder_resource() {
  resource_name=$1
  awk -v resource_name="$resource_name" '
    {
      for (field = 1; field <= NF; field++) {
        split($field, pair, "=")
        if (pair[1] == resource_name &&
            (minimum == "" || pair[2] + 0 < minimum))
          minimum = pair[2] + 0
      }
    }
    END {
      if (minimum == "")
        exit 1
      print minimum
    }
  ' "$placeholder_samples"
}

sample_placeholder_resources before
placeholder_gate_rc=0
placeholder_compile_rc=not_run
placeholder_monitor_rc=not_run
gen4_sim_rc=not_run
gen4_check_rc=not_run
gen4_timeout=not_run
gen5_sim_rc=not_run
gen5_check_rc=not_run
gen5_timeout=not_run

if [ "$sample_shm_free" -lt "$placeholder_min_free" ] || \
   [ "$sample_tmp_free" -lt "$placeholder_min_free" ]; then
  : > "$placeholder_breach"
  placeholder_gate_rc=1
fi

if [ "$placeholder_gate_rc" -eq 0 ]; then
  set +e
  TMPDIR="$placeholder_tmp" setsid vcs -full64 -sverilog \
    -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    +define+PCIE_TOPO_SWITCH_1X16_4X4 \
    -f pcie_svt.f -top pcie_svt_topology_top \
    -Mdir="$placeholder_build/csrc" -P pli.tab msglog.o \
    -o "$placeholder_build/simv" -l "$placeholder_build/compile.log" &
  placeholder_compile_pid=$!

  (
    placeholder_sample_index=0
    while kill -0 "$placeholder_compile_pid" 2>/dev/null; do
      placeholder_sample_index=$((placeholder_sample_index + 1))
      sample_placeholder_resources \
        "during_compile_${placeholder_sample_index}"
      if [ "$sample_shm_free" -lt "$placeholder_min_free" ] || \
         [ "$sample_tmp_free" -lt "$placeholder_min_free" ]; then
        : > "$placeholder_breach"
        kill -TERM -- "-$placeholder_compile_pid" 2>/dev/null || true
        placeholder_stop_wait=0
        while kill -0 -- "-$placeholder_compile_pid" 2>/dev/null && \
              [ "$placeholder_stop_wait" -lt 10 ]; do
          sleep 1
          placeholder_stop_wait=$((placeholder_stop_wait + 1))
        done
        kill -KILL -- "-$placeholder_compile_pid" 2>/dev/null || true
        exit 99
      fi
      sleep 15
    done
  ) &
  placeholder_monitor_pid=$!

  wait "$placeholder_compile_pid"
  placeholder_compile_rc=$?
  placeholder_compile_reaped=1
  wait "$placeholder_monitor_pid"
  placeholder_monitor_rc=$?
  placeholder_monitor_reaped=1
  set -e
fi

sample_placeholder_resources after_compile
if [ "$sample_shm_free" -lt "$placeholder_min_free" ] || \
   [ "$sample_tmp_free" -lt "$placeholder_min_free" ]; then
  : > "$placeholder_breach"
fi
printf 'placeholder_compile_rc=%s\n' "$placeholder_compile_rc" \
  > "$evidence_dir/rc.txt"
cp "$placeholder_build/compile.log" "$evidence_dir/compile.log"

test "$placeholder_compile_rc" = 0 || placeholder_gate_rc=1
test "$placeholder_monitor_rc" = 0 || placeholder_gate_rc=1
if [ -e "$placeholder_breach" ]; then
  placeholder_threshold_crossed=1
  placeholder_gate_rc=1
else
  placeholder_threshold_crossed=0
fi

if [ "$placeholder_gate_rc" -eq 0 ]; then
  for gen in 4 5; do
    set +e
    timeout -k 10s 5m "$placeholder_build/simv" -no_save \
      +UVM_TESTNAME=pcie_svt_real_switch_test +PCIE_GEN="$gen" \
      +PCIE_COMPILE_ONLY +UVM_NO_RELNOTES \
      -l "$placeholder_build/run_compile_gen${gen}.log"
    run_rc=$?
    ./check_real_switch_log.sh compile \
      "$placeholder_build/run_compile_gen${gen}.log" \
      > "$placeholder_build/check_compile_gen${gen}.log" 2>&1
    check_rc=$?
    set -e
    gen_timeout=0
    case "$run_rc" in
      124|137) gen_timeout=1 ;;
    esac
    case "$gen" in
      4)
        gen4_sim_rc=$run_rc
        gen4_check_rc=$check_rc
        gen4_timeout=$gen_timeout ;;
      5)
        gen5_sim_rc=$run_rc
        gen5_check_rc=$check_rc
        gen5_timeout=$gen_timeout ;;
    esac
    printf 'gen%s_sim_rc=%s\ngen%s_check_rc=%s\n' \
      "$gen" "$run_rc" "$gen" "$check_rc" >> "$evidence_dir/rc.txt"
    printf 'gen%s_timeout=%s\n' "$gen" "$gen_timeout" \
      >> "$evidence_dir/gates.txt"
    test "$run_rc" -eq 0 || placeholder_gate_rc=1
    test "$check_rc" -eq 0 || placeholder_gate_rc=1
    test "$gen_timeout" -eq 0 || placeholder_gate_rc=1
  done
fi

sample_placeholder_resources after_runs
placeholder_shm_after_runs=$sample_shm_free
placeholder_tmp_after_runs=$sample_tmp_free
placeholder_shm_min=$(minimum_placeholder_resource dev_shm_free)
placeholder_tmp_min=$(minimum_placeholder_resource run_user_free)
if [ "$placeholder_shm_min" -lt "$placeholder_min_free" ] || \
   [ "$placeholder_tmp_min" -lt "$placeholder_min_free" ]; then
  placeholder_threshold_crossed=1
  placeholder_gate_rc=1
fi
printf '%s\n' \
  "minimum_required_bytes=$placeholder_min_free" \
  "minimum_dev_shm_free_bytes=$placeholder_shm_min" \
  "minimum_run_user_free_bytes=$placeholder_tmp_min" \
  "after_runs_dev_shm_free_bytes=$placeholder_shm_after_runs" \
  "after_runs_run_user_free_bytes=$placeholder_tmp_after_runs" \
  "threshold_crossed=$placeholder_threshold_crossed" \
  > "$evidence_dir/resource_gates.txt"

for placeholder_artifact in \
    "$placeholder_build"/run_compile_gen*.log \
    "$placeholder_build"/check_compile_gen*.log; do
  if [ -f "$placeholder_artifact" ]; then
    cp "$placeholder_artifact" "$evidence_dir/"
  fi
done

placeholder_live_processes=$(
  {
    lsof -n -t +D "$placeholder_build" 2>/dev/null || true
    lsof -n -t +D "$placeholder_tmp" 2>/dev/null || true
  } | sort -u | wc -l
)
test "$placeholder_live_processes" -eq 0 || placeholder_gate_rc=1
placeholder_build_path=$placeholder_build
placeholder_tmp_path=$placeholder_tmp
case "$placeholder_build" in
  /dev/shm/pcie_task9_command_placeholder.*)
    if [ "$placeholder_live_processes" -eq 0 ]; then
      rm -rf -- "$placeholder_build"
    fi ;;
  *) exit 1 ;;
esac
case "$placeholder_tmp" in
  /run/user/1000/pcie_task9_command_tmp.*)
    if [ "$placeholder_live_processes" -eq 0 ]; then
      rm -rf -- "$placeholder_tmp"
    fi ;;
  *) exit 1 ;;
esac
sample_placeholder_resources after_cleanup
placeholder_build_removed=0
placeholder_tmp_removed=0
test ! -e "$placeholder_build_path" && placeholder_build_removed=1
test ! -e "$placeholder_tmp_path" && placeholder_tmp_removed=1
test "$placeholder_build_removed" -eq 1 || placeholder_gate_rc=1
test "$placeholder_tmp_removed" -eq 1 || placeholder_gate_rc=1
printf '%s\n' \
  "build_path=$placeholder_build_path" \
  "build_removed=$placeholder_build_removed" \
  "tmp_path=$placeholder_tmp_path" \
  "tmp_removed=$placeholder_tmp_removed" \
  "live_processes_before_cleanup=$placeholder_live_processes" \
  "after_cleanup_dev_shm_free_bytes=$sample_shm_free" \
  "after_cleanup_run_user_free_bytes=$sample_tmp_free" \
  'unrelated_directories_removed=0' > "$evidence_dir/cleanup.txt"

placeholder_status=PASS
test "$placeholder_gate_rc" -eq 0 || placeholder_status=FAIL
printf '%s\n' \
  "status=$placeholder_status" \
  "placeholder_compile_rc=$placeholder_compile_rc" \
  "gen4_sim_rc=$gen4_sim_rc" \
  "gen4_check_rc=$gen4_check_rc" \
  "gen4_timeout=$gen4_timeout" \
  "gen5_sim_rc=$gen5_sim_rc" \
  "gen5_check_rc=$gen5_check_rc" \
  "gen5_timeout=$gen5_timeout" \
  'real_dut_link_enum_traffic=not_run' > "$evidence_dir/FINAL_STATUS.txt"

placeholder_hash_files=(
  compile.log rc.txt gates.txt resource_samples.txt resource_gates.txt
  cleanup.txt FINAL_STATUS.txt
)
for placeholder_artifact in \
    run_compile_gen4.log run_compile_gen5.log \
    check_compile_gen4.log check_compile_gen5.log; do
  if [ -f "$evidence_dir/$placeholder_artifact" ]; then
    placeholder_hash_files+=("$placeholder_artifact")
  fi
done
(cd "$evidence_dir" && \
  sha256sum "${placeholder_hash_files[@]}" > SHA256SUMS && \
  sha256sum -c SHA256SUMS)
test "$placeholder_gate_rc" -eq 0
```

Run the quick Switch-Proxy unit only if this compile gate exposes a reused
package dependency that requires it. Do not launch the long unrelated matrix.

- [ ] **Hardening H8: Enforce registry bridge topology and window ownership**

Modify `pcie_svt_switch_enum_registry_unit_test.sv` first while leaving
`pcie_svt_switch_enum_registry.sv` unchanged. Add self-consistent mutations
that survive all existing registry checks and reach final validation:

```text
usp_bus_order             -> SWITCH_ENUM_BUS_ORDER
dsp_bus_order             -> SWITCH_ENUM_BUS_ORDER
dsp_primary_mismatch      -> SWITCH_ENUM_BUS_PARENT
dsp_bus_outside_usp       -> SWITCH_ENUM_BUS_PARENT
dsp_bus_overlap           -> SWITCH_ENUM_BUS_OVERLAP
dsp_window_outside_usp    -> SWITCH_ENUM_WINDOW_PARENT
dsp_window_overlap        -> SWITCH_ENUM_WINDOW_OVERLAP
```

Keep the `REGISTRY_RED` missed-validation sentinel. On `10.11.10.53`, compile
the registry unit once against the old production registry and run every new
case separately. Each RED must contain exactly the `REGISTRY_RED` fatal, with
no intended production fatal, unrelated fatal, or timeout. Archive under
`task9_final_review_bus_topology_evidence/01_red`.

Only after valid RED evidence, add a protected topology validator and call it
after record/count construction but before unique-BDF and BAR-layout
acceptance. Require `primary < secondary <= subordinate` for every bridge,
DSP Primary Bus equality with the USP Secondary Bus, DSP bus containment in
the USP range, disjoint inclusive sibling DSP bus ranges, DSP Prefetchable
window containment in the USP window, and disjoint inclusive sibling DSP
windows. Fatal messages must include the precise BDFs and ranges and return
immediately; do not hard-code the valid topology values.

Rebuild once in fresh tmpfs and run `valid`, every prior negative, and all
seven new negatives. The valid case must emit `REGISTRY_UNIT_PASS` with final
Warnings/Errors/Fatals `0/0/0`; every negative must emit exactly its mapped
production fatal, no `REGISTRY_RED`, no unrelated fatal, and no timeout.
Archive under `task9_final_review_bus_topology_evidence/02_green`. For both
phases, use exactly one VCS job, a fresh `/dev/shm` build, a separate fresh
`/run/user/1000` `TMPDIR`, monitored free-space gates, checksums, guarded
cleanup, and recorded post-cleanup state. Do not run or claim a real DUT.

- [ ] **Hardening H9: Run quick local checks**

```bash
bash svt_pcie_integration/sim/check_real_switch_log_unit_test.sh
git diff --check
git status --short
```

Expected: `REAL_SWITCH_LOG_CHECKER_UNIT_PASS positive=5 negative=18`, clean
whitespace, and only the intended uncommitted Task 9 paths. Continue with the
final review/staging steps below; do not commit between hardening and them.

- [ ] **Step 1: Run local static and credential checks**

```bash
git diff --check
git status --short
! git grep -n -E 'g[h]p_[[:alnum:]]{20,}|github_p[a]t_[[:alnum:]_]{20,}' -- .
! git ls-files | grep -E '(^|/)(build[^/]*|simv|csrc|.*\.log|msglog\.o|pli\.tab|svc_util_parms\.h)(/|$)'
```

Expected: no whitespace, credential, or tracked artifact failure.

- [ ] **Step 2: Review design coverage**

Require all of these in diff and evidence:

```text
stable Serial wrapper and macro checks
five primary VIPs and zero real-DUT peer/Proxy agents
Gen4/Gen5 and fast-link configuration preserved
24 BAR checks, one RC skip, five cfg completions
RC host aperture through mem_target_seqr
five-primary PL/L0/DL/speed/width gates
official enumeration shared without Proxy handles in real subclass
1 USP / 4 DSP / 4 EP / 12 BAR gate
USP/DSP bus hierarchy, parent containment, and sibling non-overlap gates
DSP Prefetchable-window parent containment and sibling non-overlap gates
four downstream plus four upstream deterministic MWr/MRd flows
blocking Completion/payload check and final idle gates
Serial implementation with future PIPE isolated to HDL transport
no claim of real-DUT link/enum/traffic success
```

- [ ] **Step 3: Review the complete diff**

```bash
git diff --stat
git diff -- pcie_tl_vip svt_pcie_integration docs/superpowers
```

Reject any disproved passive-USP experiment, vendor edit, force/deposit,
broad checker suppression, credential, generated artifact, or unrelated edit.

- [ ] **Step 4: Stage explicit intentional paths**

Use explicit `git add` paths from `git status --short`, including both
2026-08-21 documents and all previously approved Task 9 WIP. Then run:

```bash
git diff --cached --check
git diff --cached --stat
git diff --cached
git status --short
```

Expected: only reviewed Task 9 work is staged and no related file is omitted.

- [ ] **Step 5: Create the one final commit**

Only after all available GREEN gates:

```bash
git commit -m "feat: complete SVT switch DUT verification environment"
```

Report the commit hash, exact gates passed, and the three real-DUT-only stages
deferred for lack of DUT.

## Final Acceptance Checklist

- [ ] RED fails for the missing link/traffic contract types.
- [ ] Contract GREEN proves one positive and five negative link cases, eight
  flows, exact addresses/requester IDs, and exact payloads.
- [ ] Placeholder and compile-stub adapter branches elaborate.
- [ ] Gen4/Gen5 placeholder compile/cfg logs pass exact gates.
- [ ] Invalid modes fail immediately with intended run-mode fatals.
- [ ] Proxy enumeration and quiescence/drop gates are preserved.
- [ ] Real enumeration compiles without Proxy/sidecar/switch-model references.
- [ ] The enumeration Command probe observes offset `0x004`, exact write DWORD
  `0xf9000507` with non-target Command bits `0`, `8`, and `10` plus upper
  W1C-like Status preserved, byte enable `0011`, target bits `[2:1]` set, and
  both Status bytes disabled.
- [ ] Registry RED/GREEN covers USP/DSP bus order, DSP parent-bus equality and
  containment, sibling DSP bus overlap, DSP-window containment, and sibling
  DSP-window overlap with the five stable topology fatal IDs.
- [ ] Directed traffic compiles against public R-2020.12 APIs.
- [ ] Existing EP x16, two-EP x8, Switch, BAR, registry, adapter, converter,
  and Task 9 focused regressions remain GREEN.
- [ ] Real-DUT link/enum/traffic are reported as implemented but not executed.
- [ ] No credential, vendor source, generated artifact, or unrelated edit is
  staged.
- [ ] Exactly one final Task 9 commit is created.
