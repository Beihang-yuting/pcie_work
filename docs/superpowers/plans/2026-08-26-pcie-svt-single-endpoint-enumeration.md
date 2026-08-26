# SVT PCIe Single-Endpoint Enumeration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every current Endpoint SVT use the R-2020.12 standard Target App with a complete PF0 image and exact BAR sizing values so direct x16 and 2x8 official enumeration completes with zero warnings, errors, and fatals, while retaining per-port opt-in Multi-Endpoint support.

**Architecture:** A normalized descriptor carries an explicit Single-Endpoint or Multiple-BDF model selected by policy and optional link override. The device and CFG builders derive all SVT behavior from that descriptor: standard mode loads a complete PF0 image with BAR sizing values, while Multiple-BDF mode alone runs the documented Target App BAR services. The existing direct enumeration wrapper validates the peer model before starting the official R-2020.12 sequence.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys SVT PCIe R-2020.12, VCS W-2024.09-SP1, Serial PHY peer harness.

---

## Working-State Contract

Use the existing worktree:

```text
/home/ryan/.config/superpowers/worktrees/pcie_work/svt-topology-env-rewrite
```

Preserve the uncommitted Task-8 registry, enumeration wrapper, tests, package,
file-list, and peer-test changes. Stage only the files named by each commit.
Run VCS on `ubuntu@10.11.10.53`; stage into
`/home/ubuntu/pcie-svt-topology.7mYKzi` without `--delete`.

## File Responsibility Map

- `uvm/cfg/pcie_svt_backend_types.sv`: Endpoint-model enum and copied
  descriptor/override fields.
- `uvm/cfg/pcie_svt_topology_policy_cfg.sv`: default model and validation.
- `uvm/adapter/pcie_svt_topology_adapter.sv`: policy/override normalization.
- `uvm/cfg/pcie_svt_device_cfg_builder.sv`: SVT mode configuration.
- `uvm/cfg/pcie_svt_cfg_space_builder.sv`: PF0 and BAR sizing image.
- `uvm/sequences/pcie_svt_cfg_init_vseq.sv`: model-specific CFG dispatch.
- `uvm/sequences/pcie_svt_enumeration_vseq.sv`: official enumeration guard.
- `uvm/tests/*.sv`: focused unit and directed behavior checks.
- `sim/README.md`: current build and acceptance contract.

## Common Remote Commands

Stage changes:

```bash
sshpass -p 123 rsync -az \
  --exclude '.git' --exclude 'sim/build*' \
  /home/ryan/.config/superpowers/worktrees/pcie_work/svt-topology-env-rewrite/ \
  ubuntu@10.11.10.53:/home/ubuntu/pcie-svt-topology.7mYKzi/
```

Every remote command runs through `bash -lic` and begins with:

```bash
cd /home/ubuntu/pcie-svt-topology.7mYKzi/svt_pcie_integration/sim
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT="$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12"
```

The canonical compile command is:

```bash
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_EP_X16 +define+PCIE_USE_SVT_PEER \
  -f pcie_svt_topology.f -top pcie_svt_topology_top \
  -Mdir=BUILD_DIR/csrc -P pli.tab msglog.o \
  -o BUILD_DIR/simv -l BUILD_DIR/compile.log
```

For each invocation replace both occurrences of `BUILD_DIR` with the exact
directory named in that step. For 2x8 or Switch, replace only the topology
define with `PCIE_TOPO_EP_2X8` or `PCIE_TOPO_SWITCH_1X16_4X4`.

---

### Task 1: Add an Explicit Per-Port Endpoint Model

**Files:**
- Modify: `svt_pcie_integration/uvm/cfg/pcie_svt_backend_types.sv`
- Modify: `svt_pcie_integration/uvm/cfg/pcie_svt_topology_policy_cfg.sv`
- Modify: `svt_pcie_integration/uvm/adapter/pcie_svt_topology_adapter.sv`
- Modify: `svt_pcie_integration/uvm/cfg/pcie_svt_device_cfg_builder.sv`
- Test: `svt_pcie_integration/uvm/tests/pcie_svt_topology_adapter_unit_test.sv`
- Test: `svt_pcie_integration/uvm/tests/pcie_svt_device_cfg_unit_test.sv`

- [ ] **Step 1: Write failing policy, override, and device assertions**

Add these assertions to the adapter test after the legal 2x8 case:

```systemverilog
require(policy.default_endpoint_model == PCIE_SVT_EP_SINGLE,
        "default Endpoint model is not Single Endpoint");
$cast(propagation_policy, policy.clone());
override_cfg = pcie_svt_link_override_cfg::type_id::create(
  "endpoint_model_override");
override_cfg.link_id = "RC0_EP0";
override_cfg.has_endpoint_model = 1'b1;
override_cfg.endpoint_model = PCIE_SVT_EP_MULTI_BDF;
propagation_policy.link_overrides.push_back(override_cfg);
adapter.translate(topology, propagation_policy, ports, errors);
require(errors.size() == 0, "Endpoint model override was rejected");
require(ports[0].endpoint_model == PCIE_SVT_EP_MULTI_BDF,
        "per-link Multiple-BDF model did not propagate");
require(ports[1].endpoint_model == PCIE_SVT_EP_SINGLE,
        "Single-Endpoint default did not remain on the other link");
```

Extend the Endpoint device test to set `descriptor.endpoint_model` and assert:

```systemverilog
require(cfg.pcie_cfg.enable_multi_endpoint_mode ==
          (selected_model == PCIE_SVT_EP_MULTI_BDF),
        {case_name, ": Multi-Endpoint enable disagrees with descriptor"});
```

- [ ] **Step 2: Compile to verify RED**

Stage the tree and compile to `build_single_ep_policy_red` with the common
command.

Expected: compilation fails on `PCIE_SVT_EP_SINGLE`,
`default_endpoint_model`, or `endpoint_model`.

- [ ] **Step 3: Implement the model types and copy semantics**

Add:

```systemverilog
typedef enum {
  PCIE_SVT_EP_SINGLE,
  PCIE_SVT_EP_MULTI_BDF
} pcie_svt_endpoint_model_e;
```

Add `has_endpoint_model` plus `endpoint_model` to
`pcie_svt_link_override_cfg`, add `endpoint_model` to
`pcie_svt_port_descriptor`, and copy all three fields in their existing
`do_copy()` implementations.

Add to the policy:

```systemverilog
pcie_svt_endpoint_model_e default_endpoint_model;

// init_defaults()
default_endpoint_model = PCIE_SVT_EP_SINGLE;

// do_copy()
default_endpoint_model = source.default_endpoint_model;
```

Resolve the field in the adapter:

```systemverilog
protected function pcie_svt_endpoint_model_e effective_endpoint_model(
    pcie_svt_topology_policy_cfg policy,
    pcie_svt_link_override_cfg override_cfg);
  if ((override_cfg != null) && override_cfg.has_endpoint_model)
    return override_cfg.endpoint_model;
  return policy.default_endpoint_model;
endfunction

descriptor.endpoint_model = effective_endpoint_model(policy, override_cfg);
```

Include `has_endpoint_model` in the disabled-link active-override rejection.
Validate both enum fields by testing membership in
`{PCIE_SVT_EP_SINGLE, PCIE_SVT_EP_MULTI_BDF}`.

Derive the vendor configuration solely from the descriptor:

```systemverilog
if (descriptor.role == PCIE_SVT_ROLE_EP) begin
  cfg.pcie_cfg.enable_multi_endpoint_mode =
    descriptor.endpoint_model == PCIE_SVT_EP_MULTI_BDF;
  if (descriptor.endpoint_model == PCIE_SVT_EP_MULTI_BDF)
    cfg.target_cfg[0].default_bar_ro_map = 32'h0000_ffff;
end else begin
  cfg.pcie_cfg.enable_multi_endpoint_mode = 1'b0;
end
```

- [ ] **Step 4: Rebuild and run focused tests to verify GREEN**

Compile to `build_single_ep_policy_green`, then run:

```bash
./build_single_ep_policy_green/simv -no_save \
  +UVM_TESTNAME=pcie_svt_topology_adapter_unit_test +UVM_NO_RELNOTES \
  -l build_single_ep_policy_green/adapter_unit.log
./build_single_ep_policy_green/simv -no_save \
  +UVM_TESTNAME=pcie_svt_device_cfg_unit_test +UVM_NO_RELNOTES \
  -l build_single_ep_policy_green/device_cfg_unit.log
```

Expected: both UVM summaries are `0/0/0`.

- [ ] **Step 5: Commit only Task-1 files**

```bash
git add \
  svt_pcie_integration/uvm/cfg/pcie_svt_backend_types.sv \
  svt_pcie_integration/uvm/cfg/pcie_svt_topology_policy_cfg.sv \
  svt_pcie_integration/uvm/adapter/pcie_svt_topology_adapter.sv \
  svt_pcie_integration/uvm/cfg/pcie_svt_device_cfg_builder.sv \
  svt_pcie_integration/uvm/tests/pcie_svt_topology_adapter_unit_test.sv \
  svt_pcie_integration/uvm/tests/pcie_svt_device_cfg_unit_test.sv
git commit -m "feat(pcie-svt): select endpoint model per port"
```

---

### Task 2: Build a Complete Enumeratable PF0 Image

**Files:**
- Modify: `svt_pcie_integration/uvm/cfg/pcie_svt_cfg_space_builder.sv`
- Test: `svt_pcie_integration/uvm/tests/pcie_svt_device_cfg_unit_test.sv`

- [ ] **Step 1: Write failing exact-image assertions**

Extend `check_cfg_space_builder()` with a descriptor whose default BAR
template is 32 MiB/64 KiB/64 KiB. Set Single-Endpoint mode and assert:

```systemverilog
descriptor.endpoint_model = PCIE_SVT_EP_SINGLE;
builder.build_ep_pf0(descriptor, image);
require(builder.bar_sizing_value(descriptor.ep_bars[0], 1'b0) ==
          32'hfe00_000c,
        "32 MiB BAR sizing low DWORD is wrong");
require(builder.bar_sizing_value(descriptor.ep_bars[0], 1'b1) ==
          32'hffff_ffff,
        "32 MiB BAR sizing high DWORD is wrong");
require(builder.bar_sizing_value(descriptor.ep_bars[2], 1'b0) ==
          32'hffff_000c,
        "64 KiB BAR sizing low DWORD is wrong");
require(image['h010/4] == 32'hfe00_000c &&
        image['h014/4] == 32'hffff_ffff,
        "PF0 BAR0/1 sizing pair is wrong");
require(image['h018/4] == 32'hffff_000c &&
        image['h01c/4] == 32'hffff_ffff,
        "PF0 BAR2/3 sizing pair is wrong");
require(image['h020/4] == 32'hffff_000c &&
        image['h024/4] == 32'hffff_ffff,
        "PF0 BAR4/5 sizing pair is wrong");
require(image['h034/4] == 32'h0000_0040,
        "PF0 Capability Pointer is wrong");
require(image['h040/4] == 32'h0002_0010,
        "PF0 PCI Express Capability header is wrong");
require(image['h04c/4][9:4] == descriptor.link_width &&
        image['h04c/4][3:0] == descriptor.max_gen,
        "PF0 Link Capabilities width/generation is wrong");
require(image['h100/4] == 32'h0000_0000,
        "PF0 extended capability chain is not terminated");
```

Set a second descriptor to `PCIE_SVT_EP_MULTI_BDF` and preserve the existing
zero-base BAR-image assertions so the two paths remain distinct.

- [ ] **Step 2: Compile to verify RED**

Compile to `build_single_ep_image_red` with the common command.

Expected: compilation fails because `bar_sizing_value()` does not exist. After
adding its declaration alone, the exact BAR and capability assertions fail.

- [ ] **Step 3: Implement exact sizing and the capability image**

Add:

```systemverilog
function automatic bit [31:0] bar_sizing_value(
    pcie_svt_bar_cfg bar,
    bit high_dword);
  bit [63:0] sizing_mask;
  bit [31:0] value;

  if ((bar == null) || !bar.implemented)
    return 0;
  if (!bar_aperture_is_valid(bar.aperture)) begin
    `uvm_fatal("SVT_BAR",
      "BAR aperture must be a power of two and at least 16 bytes")
    return 0;
  end
  sizing_mask = ~(bar.aperture - 1);
  if (high_dword)
    return sizing_mask[63:32];
  value = sizing_mask[31:0] & 32'hffff_fff0;
  value[2:1] = bar.is_64bit ? 2'b10 : 2'b00;
  value[3] = bar.prefetchable;
  return value;
endfunction
```

Inside `build_ep_pf0()`, select sizing values only for Single Endpoint:

```systemverilog
if ((i > 0) && descriptor.ep_bars[i-1].implemented &&
    descriptor.ep_bars[i-1].is_64bit) begin
  image[4+i] = descriptor.endpoint_model == PCIE_SVT_EP_SINGLE ?
    bar_sizing_value(descriptor.ep_bars[i-1], 1'b1) :
    bar_initial_value(descriptor.ep_bars[i-1], 1'b1);
end else begin
  image[4+i] = descriptor.endpoint_model == PCIE_SVT_EP_SINGLE ?
    bar_sizing_value(descriptor.ep_bars[i], 1'b0) :
    bar_initial_value(descriptor.ep_bars[i], 1'b0);
end
```

Emit the minimal complete standard capability image:

```systemverilog
bit [6:0] supported_speed_vector;

supported_speed_vector = (7'b1 << descriptor.max_gen) - 1;
image['h034/4] = 32'h0000_0040;
image['h040/4] = 32'h0002_0010; // PCIe cap, next=0, v2, EP type 0
image['h044/4] = 32'h0000_0000; // Device Capabilities
image['h048/4] = 32'h0000_0000; // Device Control/Status
image['h04c/4] = {22'h0, descriptor.link_width[5:0],
                  descriptor.max_gen[3:0]};
image['h050/4] = 32'h0000_0000; // Link Control/Status
image['h064/4] = 32'h0000_0000; // Device Capabilities 2
image['h068/4] = 32'h0000_0000; // Device Control/Status 2
image['h06c/4] = {24'h0, supported_speed_vector, 1'b0};
image['h100/4] = 32'h0000_0000;
```

Keep `image[1] = 32'h0010_0000` so Status.Capabilities List is set, and keep
the Type-0 single-function header.

- [ ] **Step 4: Rebuild and run the image unit test**

Compile to `build_single_ep_image_green`, then run:

```bash
./build_single_ep_image_green/simv -no_save \
  +UVM_TESTNAME=pcie_svt_device_cfg_unit_test +UVM_NO_RELNOTES \
  -l build_single_ep_image_green/device_cfg_unit.log
```

Expected: exact image assertions pass and the summary is `0/0/0`.

- [ ] **Step 5: Commit the image change**

```bash
git add \
  svt_pcie_integration/uvm/cfg/pcie_svt_cfg_space_builder.sv \
  svt_pcie_integration/uvm/tests/pcie_svt_device_cfg_unit_test.sv
git commit -m "feat(pcie-svt): build enumeratable endpoint PF0 image"
```

---

### Task 3: Split CFG Initialization by Endpoint Model

**Files:**
- Modify: `svt_pcie_integration/uvm/sequences/pcie_svt_cfg_init_vseq.sv`
- Modify: `svt_pcie_integration/uvm/tests/pcie_svt_cfg_init_directed_test.sv`

- [ ] **Step 1: Demand standard-mode and Multiple-BDF dispatch in the test**

Give the recording adapter a descriptor registry:

```systemverilog
static pcie_svt_port_descriptor descriptor_by_link[string];
```

Populate it before each run. In `validate_published_refresh_cfg()`, replace the
hard-coded mode-one check with:

```systemverilog
bit expected_multi_endpoint;
expected_multi_endpoint =
  descriptor_by_link[link_id].endpoint_model == PCIE_SVT_EP_MULTI_BDF;
if (published_cfg.pcie_cfg.enable_multi_endpoint_mode !=
    expected_multi_endpoint)
  `uvm_fatal("CFG_INIT_DIRECTED", $sformatf(
    "%s published multi_endpoint=%0d expected=%0d",
    link_id, published_cfg.pcie_cfg.enable_multi_endpoint_mode,
    expected_multi_endpoint))
```

For the default Switch-profile run, require no Target App BAR records, 1024
PF0 writes per Endpoint, and readback of DWORDs `0x000`, `0x034`, `0x040`, and
all six BAR DWORDs. Then, before the second reset-held run, set every EP
descriptor and runtime configuration to Multiple-BDF and require six
`SET/WRITE/READ/GET` BAR groups per Endpoint.

Use this exact transition between the two runs:

```systemverilog
foreach (env.vseqr.descriptor_by_link[link_id]) begin
  pcie_svt_port_descriptor selected_descriptor;
  selected_descriptor = env.vseqr.descriptor_by_link[link_id];
  pcie_svt_cfg_init_recording_adapter::descriptor_by_link[link_id] =
    selected_descriptor;
  if (selected_descriptor.role == PCIE_SVT_ROLE_EP) begin
    selected_descriptor.endpoint_model = PCIE_SVT_EP_MULTI_BDF;
    env.vseqr.cfg_by_link[link_id].pcie_cfg.enable_multi_endpoint_mode = 1'b1;
  end
end
env.vseqr.reset_vif.hold_all();
#0;
multi_bdf_cfg = pcie_svt_cfg_init_vseq::type_id::create("multi_bdf_cfg");
multi_bdf_cfg.program_target_bars = 1'b1;
start_with_reset_release_monitor(multi_bdf_cfg);
check_run(multi_bdf_cfg, 1'b1);
```

The first run calls `check_run(cfg_init, 1'b0)` because all default Endpoint
descriptors are Single Endpoint even though `program_target_bars` remains 1.

- [ ] **Step 2: Run the directed test to verify RED**

Compile the Switch topology to `build_single_ep_cfg_red` and run:

```bash
./build_single_ep_cfg_red/simv -no_save \
  +UVM_TESTNAME=pcie_svt_cfg_init_directed_test \
  +PCIE_GEN=4 +UVM_NO_RELNOTES \
  -l build_single_ep_cfg_red/cfg_directed.log
```

Expected: default Single-Endpoint ports still emit Multi-Endpoint BAR records
or fail the published-mode assertion.

- [ ] **Step 3: Make validation and service dispatch model-specific**

Add:

```systemverilog
protected function bit expects_multi_endpoint();
  return (descriptor != null) &&
         (descriptor.endpoint_model == PCIE_SVT_EP_MULTI_BDF);
endfunction
```

In both `handles_are_valid()` and `refresh_configuration()`, compare
`enable_multi_endpoint_mode` with `expects_multi_endpoint()` rather than 1.
Keep the existing Target sequencer requirement because Task 9 will use the
standard Target App for Memory traffic.

Always preload the complete PF0 image. Dispatch Multi-Endpoint services only
when selected:

```systemverilog
if (program_target_bars && expects_multi_endpoint()) begin
  for (int unsigned bar_num = 0; bar_num < 6; bar_num++)
    program_one_bar(builder, bar_num);
  enable_completer_memory_space();
end
```

Expand the important readback set and report the standard image:

```systemverilog
int unsigned checked_dwords[16] =
  '{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 13, 15, 16, 19, 27};

`uvm_info("PCIE_SVT_CFG_SPACE_CHECK", $sformatf(
  "link=%s model=%s writes=1024 checked=%0d",
  descriptor.link_id, descriptor.endpoint_model.name(),
  checked_dwords.size()), UVM_NONE)
```

- [ ] **Step 4: Rebuild and run directed plus device tests**

Compile to `build_single_ep_cfg_green` and run:

```bash
./build_single_ep_cfg_green/simv -no_save \
  +UVM_TESTNAME=pcie_svt_cfg_init_directed_test \
  +PCIE_GEN=4 +UVM_NO_RELNOTES \
  -l build_single_ep_cfg_green/cfg_directed.log
./build_single_ep_cfg_green/simv -no_save \
  +UVM_TESTNAME=pcie_svt_device_cfg_unit_test +UVM_NO_RELNOTES \
  -l build_single_ep_cfg_green/device_cfg_unit.log
```

Expected: the Single-Endpoint run has image checks and zero Multi-Endpoint
services; the explicit Multiple-BDF run has six BAR groups per Endpoint. Both
summaries are `0/0/0`.

- [ ] **Step 5: Commit CFG dispatch**

```bash
git add \
  svt_pcie_integration/uvm/sequences/pcie_svt_cfg_init_vseq.sv \
  svt_pcie_integration/uvm/tests/pcie_svt_cfg_init_directed_test.sv
git commit -m "fix(pcie-svt): initialize target app by endpoint model"
```

---

### Task 4: Guard and Complete Direct Official Enumeration

**Files:**
- Modify: `svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_vseq.sv`
- Modify: `svt_pcie_integration/uvm/tests/pcie_svt_enumeration_registry_unit_test.sv`
- Modify: `svt_pcie_integration/uvm/tests/pcie_svt_peer_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt_topology.f`
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_registry.sv`

- [ ] **Step 1: Add failing peer-model compatibility checks**

Add these tests to the enumeration registry unit test:

```systemverilog
pcie_svt_enumeration_vseq enumeration;
string diagnostic;

enumeration = pcie_svt_enumeration_vseq::type_id::create("enumeration");
enumeration.is_ep_device_vip = 1'b1;
require(!enumeration.peer_model_allows_official_enum(
          "RC0_EP0", diagnostic),
        "missing peer Endpoint model was accepted");
require(uvm_is_match("*RC0_EP0*missing*", diagnostic),
        "missing-model diagnostic omitted the link ID");

enumeration.peer_endpoint_model_by_link["RC0_EP0"] =
  PCIE_SVT_EP_SINGLE;
require(enumeration.peer_model_allows_official_enum(
          "RC0_EP0", diagnostic),
        "Single-Endpoint peer was rejected");

enumeration.peer_endpoint_model_by_link["RC0_EP0"] =
  PCIE_SVT_EP_MULTI_BDF;
require(!enumeration.peer_model_allows_official_enum(
          "RC0_EP0", diagnostic),
        "Multiple-BDF peer was accepted by full enumeration");
require(uvm_is_match("*Multiple-BDF*", diagnostic),
        "Multiple-BDF diagnostic omitted the model");
```

- [ ] **Step 2: Run the registry unit test to verify RED**

Compile to `build_single_ep_enum_guard_red` and run:

```bash
./build_single_ep_enum_guard_red/simv -no_save \
  +UVM_TESTNAME=pcie_svt_enumeration_registry_unit_test \
  +UVM_NO_RELNOTES \
  -l build_single_ep_enum_guard_red/registry_unit.log
```

Expected: compilation fails because `peer_endpoint_model_by_link` and
`peer_model_allows_official_enum()` do not exist.

- [ ] **Step 3: Implement the compatibility gate and peer mapping**

Add to `pcie_svt_enumeration_vseq`:

```systemverilog
pcie_svt_endpoint_model_e peer_endpoint_model_by_link[string];

function bit peer_model_allows_official_enum(
    string link_id,
    output string diagnostic);
  diagnostic = "";
  if (!is_ep_device_vip)
    return 1'b1;
  if (!peer_endpoint_model_by_link.exists(link_id)) begin
    diagnostic = $sformatf(
      "%s peer Endpoint model mapping is missing", link_id);
    return 1'b0;
  end
  if (peer_endpoint_model_by_link[link_id] != PCIE_SVT_EP_SINGLE) begin
    diagnostic = $sformatf(
      "%s peer model is Multiple-BDF; R-2020.12 full Endpoint enumeration requires Single Endpoint",
      link_id);
    return 1'b0;
  end
  return 1'b1;
endfunction
```

Before creating the vendor sequence in `enumerate_link()`:

```systemverilog
string model_diagnostic;
if (!peer_model_allows_official_enum(link_id, model_diagnostic))
  `uvm_fatal("SVT_ENUM_ENDPOINT_MODEL", model_diagnostic)
```

In `pcie_svt_peer_test::run_direct_enumeration()`, map primary links to peer
models by equal `slot_index` and reject missing or duplicate matches:

```systemverilog
foreach (env.descriptors[i]) begin
  int unsigned matches;
  matches = 0;
  foreach (peer_env.descriptors[j]) begin
    if (peer_env.descriptors[j].slot_index ==
        env.descriptors[i].slot_index) begin
      enumeration.peer_endpoint_model_by_link[
        env.descriptors[i].link_id] =
          peer_env.descriptors[j].endpoint_model;
      matches++;
    end
  end
  if (matches != 1)
    `uvm_fatal("SVT_PEER_ENUM", $sformatf(
      "%s peer slot match count=%0d expected=1",
      env.descriptors[i].link_id, matches))
end
```

Keep `set_sequencer(rc_seqr)` before randomization, the L0/DL/VC0 wait,
independent hierarchy allocation, BAR validation, registry finalization, and
watchdog.

- [ ] **Step 4: Run unit GREEN and x16 Gen4 integration**

Compile to `build_single_ep_enum_x16`, then run:

```bash
./build_single_ep_enum_x16/simv -no_save \
  +UVM_TESTNAME=pcie_svt_enumeration_registry_unit_test \
  +UVM_NO_RELNOTES \
  -l build_single_ep_enum_x16/registry_unit.log
./build_single_ep_enum_x16/simv -no_save \
  +UVM_TESTNAME=pcie_svt_peer_test \
  +PCIE_ENUM_ONLY +PCIE_GEN=4 +UVM_NO_RELNOTES \
  -l build_single_ep_enum_x16/enum_gen4.log
```

Expected:

```text
one PCIE_SVT_LINK_PASS with Gen4 x16
one PCIE_SVT_ENUM_PASS for RC0_EP0 with three BAR pairs
PCIE_SVT_STAGE ... CFG=PASS LINK=PASS ENUM=PASS TRAFFIC=NOT_RUN
UVM_WARNING/UVM_ERROR/UVM_FATAL = 0/0/0
```

- [ ] **Step 5: Commit the complete Task-8 enumeration set**

```bash
git add \
  svt_pcie_integration/sim/pcie_svt_topology.f \
  svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv \
  svt_pcie_integration/uvm/tests/pcie_svt_peer_test.sv \
  svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_registry.sv \
  svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_vseq.sv \
  svt_pcie_integration/uvm/tests/pcie_svt_enumeration_registry_unit_test.sv
git commit -m "feat(pcie-svt): enumerate independent endpoint links"
```

---

### Task 5: Run the Full Remote Acceptance Matrix and Update the Contract

**Files:**
- Modify: `svt_pcie_integration/sim/README.md`

- [ ] **Step 1: Update the simulation contract**

Replace the claim that every Endpoint enables Multi-Endpoint Mode with:

```markdown
Every current Endpoint SVT uses the standard Single-Endpoint Target App. The
CFG stage refreshes the final configuration while reset is asserted, releases
reset with DL/PHY disabled, writes a complete PF0 image, and reads back the
header, BAR, and PCI Express Capability DWORDs. BAR0/1 is preloaded with
`fe00_000c/ffff_ffff`; BAR2/3 and BAR4/5 use
`ffff_000c/ffff_ffff`. These are R-2020.12 VIP sizing values for official
enumeration with `is_ep_device_vip=1`.

Multi-Endpoint Target App services are reserved for descriptors explicitly
configured as `PCIE_SVT_EP_MULTI_BDF`; current direct and Switch profiles do
not use them.
```

Document the x16 and 2x8 commands below and their exact PASS counts.

- [ ] **Step 2: Run x16 Gen4 and Gen5**

Use the Task-4 x16 image:

```bash
for gen in 4 5; do
  ./build_single_ep_enum_x16/simv -no_save \
    +UVM_TESTNAME=pcie_svt_peer_test \
    +PCIE_ENUM_ONLY +PCIE_GEN="$gen" +UVM_NO_RELNOTES \
    -l "build_single_ep_enum_x16/enum_gen${gen}.log"
done
```

For each log require exactly one emitted `PCIE_SVT_ENUM_PASS`, one stage row
with CFG/LINK/ENUM `PASS` and TRAFFIC `NOT_RUN`, and summary `0/0/0`.

- [ ] **Step 3: Build and run 2x8 Gen4 and Gen5**

Compile the final source with `PCIE_TOPO_EP_2X8` to
`build_single_ep_enum_2x8`, then run:

```bash
for gen in 4 5; do
  ./build_single_ep_enum_2x8/simv -no_save \
    +UVM_TESTNAME=pcie_svt_peer_test \
    +PCIE_ENUM_ONLY +PCIE_GEN="$gen" +UVM_NO_RELNOTES \
    -l "build_single_ep_enum_2x8/enum_gen${gen}.log"
done
```

For each log require exactly two emitted `PCIE_SVT_ENUM_PASS` records, roots 0
and 1, two PASS stage rows, and summary `0/0/0`. Both roots may use BDF `0100`.

- [ ] **Step 4: Rebuild and run Switch CFG/link regression**

Compile with `PCIE_TOPO_SWITCH_1X16_4X4` to `build_single_ep_switch`, then run:

```bash
./build_single_ep_switch/simv -no_save \
  +UVM_TESTNAME=pcie_svt_cfg_init_directed_test \
  +PCIE_GEN=4 +UVM_NO_RELNOTES \
  -l build_single_ep_switch/cfg_directed.log
./build_single_ep_switch/simv -no_save \
  +UVM_TESTNAME=pcie_svt_peer_test \
  +PCIE_LINK_ONLY +PCIE_GEN=4 +UVM_NO_RELNOTES \
  -l build_single_ep_switch/link_gen4.log
./build_single_ep_switch/simv -no_save \
  +UVM_TESTNAME=pcie_svt_peer_test \
  +PCIE_LINK_ONLY +PCIE_GEN=5 +UVM_NO_RELNOTES \
  -l build_single_ep_switch/link_gen5.log
```

Expected: five link passes per peer run; all five stage rows have CFG/LINK
`PASS` and ENUM/TRAFFIC `NOT_RUN`; all summaries are `0/0/0`.

- [ ] **Step 5: Run the affected unit regression**

```bash
for test_name in \
  pcie_svt_topology_model_unit_test \
  pcie_svt_topology_adapter_unit_test \
  pcie_svt_cli_parser_unit_test \
  pcie_svt_device_cfg_unit_test \
  pcie_svt_enumeration_registry_unit_test; do
  ./build_single_ep_enum_x16/simv -no_save \
    +UVM_TESTNAME="$test_name" +UVM_NO_RELNOTES \
    -l "build_single_ep_enum_x16/${test_name}.log"
done
```

Expected: all summaries are `0/0/0`; the registry test emits
`PCIE_SVT_ENUM_REGISTRY_UNIT_PASS=1`.

- [ ] **Step 6: Commit the verified simulation contract**

```bash
git add svt_pcie_integration/sim/README.md
git commit -m "docs(pcie-svt): document standard endpoint enumeration"
```

- [ ] **Step 7: Perform final repository verification**

```bash
git status --short --branch
git log --oneline -6
git diff --check HEAD~5..HEAD
```

Expected: no uncommitted implementation files, no whitespace errors, and the
five implementation/documentation commits follow design commit `8609713`.
