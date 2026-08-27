# PCIe SVT Topology Environment Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fixed-slot and Proxy-based SVT integration with `pcie_svt_topology_env extends pcie_device_unified_vip_env`, driven by `pcie_topology_cfg` and verified against Synopsys PCIe SVT R-2020.12.

**Architecture:** A new `pcie_svt_topology_pkg` translates the common node/link graph plus an SVT DUT-binding policy into one descriptor per effective DUT-facing link. The derived environment overrides the official example's build/connect lifecycle, creates only the required one-sided device agents, and exposes a link-ID-based virtual sequencer; configuration, link, enumeration, and traffic sequences consume that registry. A separate peer fixture creates opposite-role agents for self-test and never provides Switch forwarding.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys DesignWare PCIe SVT R-2020.12, Synopsys VCS W-2024.09-SP1 on `10.11.10.53`, Serial PHY integration

**Spec:** `docs/superpowers/specs/2026-08-25-pcie-svt-topology-env-design.md`

---

## File Map

| File | Action | Responsibility |
| --- | --- | --- |
| `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv` | Create | New package, official unified-env include, dependency order |
| `svt_pcie_integration/uvm/cfg/pcie_svt_backend_types.sv` | Create | Role, transport, stage, BAR, override, descriptor records |
| `svt_pcie_integration/uvm/cfg/pcie_svt_topology_policy_cfg.sv` | Create | DUT ownership, defaults, per-link overrides, validation |
| `svt_pcie_integration/uvm/cfg/pcie_svt_cli_parser.sv` | Create | Strict profile, generation, mode, and per-link argument parser |
| `svt_pcie_integration/uvm/cfg/pcie_svt_profile_factory.sv` | Create | Three common topologies and their standard DUT policies |
| `svt_pcie_integration/uvm/adapter/pcie_svt_topology_adapter.sv` | Create | Common topology plus policy to deterministic descriptors |
| `svt_pcie_integration/uvm/adapter/pcie_svt_peer_fixture_builder.sv` | Create | Independent direct-link topology for opposite-role peer agents |
| `svt_pcie_integration/uvm/cfg/pcie_svt_device_cfg_builder.sv` | Create | Descriptor to R-2020.12 device configuration |
| `svt_pcie_integration/uvm/cfg/pcie_svt_cfg_space_builder.sv` | Create | Minimal PF0 image and documented BAR RO-map calculations |
| `svt_pcie_integration/uvm/env/pcie_svt_topology_virtual_sequencer.sv` | Create | Link-ID registry and per-stage state |
| `svt_pcie_integration/uvm/env/pcie_svt_topology_env.sv` | Create | One-sided SVT agent construction; official compatibility aliases |
| `svt_pcie_integration/uvm/sequences/pcie_svt_cfg_init_vseq.sv` | Create | Refresh under reset, then reset release and Target App configuration with links disabled |
| `svt_pcie_integration/uvm/sequences/pcie_svt_link_vseq.sv` | Create | Parallel DL/PHY enable and negotiated link checks |
| `svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_registry.sv` | Create | Direct and Switch enumeration results keyed by hierarchy/link |
| `svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_vseq.sv` | Create | Official EP/Switch enumeration and configuration readback |
| `svt_pcie_integration/uvm/sequences/pcie_svt_memory_traffic_vseq.sv` | Create | RC-to-Endpoint Memory Write/Read and Completion/data checks |
| `svt_pcie_integration/uvm/sequences/pcie_svt_stage_vseq.sv` | Create | Ordered CFG/LINK/ENUM/TRAFFIC orchestration |
| `svt_pcie_integration/uvm/tests/pcie_svt_topology_model_unit_test.sv` | Create | Policy defaults, copying, and override tests |
| `svt_pcie_integration/uvm/tests/pcie_svt_topology_adapter_unit_test.sv` | Create | Binding, order, role, count, and negative translation tests |
| `svt_pcie_integration/uvm/tests/pcie_svt_cli_parser_unit_test.sv` | Create | Strict command-line token tests |
| `svt_pcie_integration/uvm/tests/pcie_svt_device_cfg_unit_test.sv` | Create | Width, speed, fast mode, Multi-Endpoint, and BAR tests |
| `svt_pcie_integration/uvm/tests/pcie_svt_topology_base_test.sv` | Create | Common profile/policy/env setup and stage selection |
| `svt_pcie_integration/uvm/tests/pcie_svt_peer_test.sv` | Create | Two-env direct and point-to-point peer validation |
| `svt_pcie_integration/uvm/tests/pcie_svt_real_dut_test.sv` | Create | Real-DUT compile/config/link/enum/traffic entry |
| `svt_pcie_integration/rtl/pcie_svt_hdl_agent_macros.svh` | Create | Focused x4/x8/x16 unified HDL declarations and mappings |
| `svt_pcie_integration/rtl/pcie_svt_topology_env_top.sv` | Create, then rename | Clean primary/peer/real-DUT Serial top |
| `svt_pcie_integration/rtl/pcie_svt_dut_wrapper.sv` | Create | Typed real-DUT adapter boundary and idle placeholder |
| `svt_pcie_integration/rtl/pcie_svt_topology_checks.svh` | Modify | Remove Proxy rules; enforce topology/connection macro contract |
| `svt_pcie_integration/rtl/pcie_svt_peer_harness.sv` | Modify | Retain only direct Serial cross-connect |
| `svt_pcie_integration/sim/pcie_svt_topology.f` | Create, then rename | New-path VCS file list without project TL package |
| `svt_pcie_integration/sim/check_pcie_svt_topology_log.sh` | Create | Stage-aware exact-count and final-severity gate |
| `svt_pcie_integration/sim/README.md` | Rewrite | Clean build/run and real-DUT integration contract |
| `pcie_tl_vip/docs/PCIe_TL_VIP_Integration_Guide.md` | Modify | Mark the SVT topology backend implemented |

The old `pcie_svt_integration_pkg` and its sources stay buildable until Task 12. New class names live in `pcie_svt_topology_pkg`, so red/green work does not destabilize the old package.

Every standalone UVM test file created below starts with:

~~~systemverilog
import uvm_pkg::*;
import pcie_topology_pkg::*;
import svt_uvm_pkg::*;
import svt_pcie_uvm_pkg::*;
import pcie_svt_topology_pkg::*;
`include "uvm_macros.svh"
~~~

Before Task 4, omit the two SVT package imports when the test uses only the policy/adapter layer.

## Remote VCS Recipe

All simulator-dependent steps run on `10.11.10.53`. Use a new remote staging directory for the implementation session. Do not write the login password into a file, URL, Git remote, or shell history.

~~~bash
read -s VCS_HOST_PASSWORD
export SSHPASS="$VCS_HOST_PASSWORD"
export PCIE_RSYNC_SSH="sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
export PCIE_REMOTE_ROOT
PCIE_REMOTE_ROOT=$(sshpass -e ssh -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null ubuntu@10.11.10.53 \
  'mktemp -d /home/ubuntu/pcie-svt-topology.XXXXXX')
RSYNC_RSH="$PCIE_RSYNC_SSH" rsync -az \
  --exclude=.git --exclude=simv --exclude='*.daidir' --exclude='build_*' \
  ./ "ubuntu@10.11.10.53:$PCIE_REMOTE_ROOT/"
~~~

Prepare the R-2020.12 PLI in the staged `sim` directory:

~~~bash
sshpass -e ssh -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null ubuntu@10.11.10.53 "bash -lic '
  cd $PCIE_REMOTE_ROOT/svt_pcie_integration/sim
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12
  \$PCIE_SVT_ROOT/bin/param2def.sh \
    < \$PCIE_SVT_ROOT/verilog/src/vcs/svc_util_parms.vp \
    > svc_util_parms.h
  cc -c -I. -I\$VCS_HOME/include -I\$PCIE_SVT_ROOT/C/include \
    -DVCS_VERILOG -DUSE_VPI=1 -DPLI_64_BIT \
    \$PCIE_SVT_ROOT/C/src/msglog.c -o msglog.o
  \$VCS_HOME/bin/veriuser_to_pli_tab -include \$VCS_HOME/include \
    \$PCIE_SVT_ROOT/C/src/veriuser.c > pli.tab
'"
~~~

After each local commit, repeat only the `rsync` command. Every VCS command below is wrapped in `bash -lic` so the VCS path and license environment come from the simulation user's login setup.

---

### Task 1: Backend Policy, BAR Defaults, and Stage State

**Files:**
- Create: `svt_pcie_integration/uvm/cfg/pcie_svt_backend_types.sv`
- Create: `svt_pcie_integration/uvm/cfg/pcie_svt_topology_policy_cfg.sv`
- Create: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Create: `svt_pcie_integration/uvm/tests/pcie_svt_topology_model_unit_test.sv`
- Create: `svt_pcie_integration/sim/pcie_svt_topology.f`

- [ ] **Step 1: Write the failing policy/default test**

Create `pcie_svt_topology_model_unit_test.sv` with one UVM test that constructs a policy, calls `init_defaults()`, clones it, and checks:

~~~systemverilog
class pcie_svt_topology_model_unit_test extends uvm_test;
  `uvm_component_utils(pcie_svt_topology_model_unit_test)

  function new(string name = "pcie_svt_topology_model_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void require(bit condition, string message);
    if (!condition) `uvm_error("SVT_MODEL", message)
  endfunction

  task run_phase(uvm_phase phase);
    pcie_svt_topology_policy_cfg policy;
    pcie_svt_topology_policy_cfg copy;
    pcie_svt_link_override_cfg override_cfg;
    string errors[$];

    phase.raise_objection(this);
    policy = pcie_svt_topology_policy_cfg::type_id::create("policy");
    policy.init_defaults();
    policy.dut_node_ids.push_back("SW0");
    policy.hdl_slot_by_link["RC0_SW0_USP0"] = 0;
    override_cfg = pcie_svt_link_override_cfg::type_id::create("override");
    override_cfg.link_id = "SW0_DSP0_EP0";
    override_cfg.has_gen = 1;
    override_cfg.max_gen = 5;
    policy.link_overrides.push_back(override_cfg);
    policy.validate(errors);

    require(errors.size() == 0, "valid default policy was rejected");
    require(policy.ep_bars[0].aperture == 64'd33554432,
            "BAR0 aperture is not 32 MiB");
    require(!policy.ep_bars[1].implemented,
            "BAR1 must be the upper DWORD of BAR0");
    require(policy.ep_bars[2].aperture == 64'd65536 &&
            policy.ep_bars[4].aperture == 64'd65536,
            "BAR2/BAR4 apertures are not 64 KiB");
    require(policy.ep_bars[0].is_64bit &&
            policy.ep_bars[0].prefetchable,
            "BAR0 is not 64-bit Prefetchable");
    require(policy.transport == PCIE_SVT_TRANSPORT_SERIAL,
            "Serial is not the default transport");

    $cast(copy, policy.clone());
    copy.dut_node_ids[0] = "CHANGED";
    copy.ep_bars[0].aperture = 64'd4096;
    copy.link_overrides[0].max_gen = 4;
    copy.hdl_slot_by_link["RC0_SW0_USP0"] = 4;
    require(policy.dut_node_ids[0] == "SW0",
            "DUT-node list clone aliases the source");
    require(policy.ep_bars[0].aperture == 64'd33554432,
            "BAR clone aliases the source");
    require(policy.link_overrides[0].max_gen == 5,
            "override clone aliases the source");
    require(policy.hdl_slot_by_link["RC0_SW0_USP0"] == 0,
            "HDL-slot map clone aliases the source");

    require(PCIE_SVT_STAGE_NOT_RUN.name() == "PCIE_SVT_STAGE_NOT_RUN",
            "stage enum is unavailable");
    phase.drop_objection(this);
  endtask
endclass
~~~

- [ ] **Step 2: Add the test and package paths, then prove the test is red**

The initial `pcie_svt_topology.f` contains the existing vendor bootstrap/interface inputs, the common topology package, the new package, the unit test, and the existing top:

~~~text
+incdir+../rtl
+incdir+../uvm
+incdir+../uvm/cfg
+incdir+../uvm/tests
+incdir+../../pcie_tl_vip/src/topology
+incdir+$PCIE_SVT_ROOT/sverilog/include
+incdir+$DESIGNWARE_HOME/vip/svt/common/R-2020.12/sverilog/include
+define+DESIGNWARE_INCDIR=$DESIGNWARE_HOME
+define+SVT_LOADER_UTIL_ENABLE_DWHOME_INCDIRS
+define+SVT_PCIE_ENABLE_10_BIT_TAGS
-y $PCIE_SVT_ROOT/verilog/src/vcs
-y $PCIE_SVT_ROOT/sverilog/src/vcs
../rtl/pcie_svt_vip_bootstrap.sv
../rtl/pcie_svt_serial_port_if.sv
../rtl/pcie_svt_reset_if.sv
../rtl/pcie_svt_serial_adapter.sv
../rtl/pcie_svt_peer_harness.sv
../rtl/pcie_dut_placeholder.sv
../rtl/pcie_switch_dut_wrapper.sv
../../pcie_tl_vip/src/topology/pcie_topology_pkg.sv
../uvm/pcie_svt_topology_pkg.sv
../uvm/tests/pcie_svt_topology_model_unit_test.sv
../rtl/pcie_svt_topology_top.sv
~~~

Run:

~~~bash
sshpass -e ssh -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null ubuntu@10.11.10.53 "bash -lic '
  cd $PCIE_REMOTE_ROOT/svt_pcie_integration/sim
  export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
  export PCIE_SVT_ROOT=\$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12
  mkdir -p build_model_red
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
    +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
    +define+PCIE_TOPO_EP_X16 -f pcie_svt_topology.f \
    -top pcie_svt_topology_top -P pli.tab msglog.o \
    -o build_model_red/simv -l build_model_red.log
'"
~~~

Expected: compile failure naming missing `pcie_svt_topology_policy_cfg` or `PCIE_SVT_TRANSPORT_SERIAL`.

- [ ] **Step 3: Implement focused data records**

Define these exact public fields and copy contracts in `pcie_svt_backend_types.sv`:

~~~systemverilog
typedef enum {PCIE_SVT_ROLE_RC, PCIE_SVT_ROLE_EP} pcie_svt_role_e;
typedef enum {PCIE_SVT_TRANSPORT_SERIAL, PCIE_SVT_TRANSPORT_PIPE}
  pcie_svt_transport_e;
typedef enum {PCIE_SVT_STAGE_NOT_RUN, PCIE_SVT_STAGE_PASS,
              PCIE_SVT_STAGE_FAIL} pcie_svt_stage_state_e;
typedef enum {PCIE_SVT_RUN_COMPILE, PCIE_SVT_RUN_CFG,
              PCIE_SVT_RUN_LINK, PCIE_SVT_RUN_ENUM,
              PCIE_SVT_RUN_TRAFFIC} pcie_svt_run_mode_e;

function automatic string pcie_svt_join_errors(input string errors[$]);
  string joined = "";
  foreach (errors[i])
    joined = {joined, (i == 0) ? "" : "; ", errors[i]};
  return joined;
endfunction

class pcie_svt_bar_cfg extends uvm_object;
  `uvm_object_utils(pcie_svt_bar_cfg)
  bit implemented;
  bit is_64bit;
  bit prefetchable;
  longint unsigned aperture;
  longint unsigned initial_base;
  function new(string name = "pcie_svt_bar_cfg");
    super.new(name);
  endfunction
  virtual function void do_copy(uvm_object rhs);
    pcie_svt_bar_cfg source;
    super.do_copy(rhs);
    if (!$cast(source, rhs)) `uvm_fatal("SVT_COPY", "BAR source type")
    implemented = source.implemented;
    is_64bit = source.is_64bit;
    prefetchable = source.prefetchable;
    aperture = source.aperture;
    initial_base = source.initial_base;
  endfunction
endclass

class pcie_svt_link_override_cfg extends uvm_object;
  `uvm_object_utils(pcie_svt_link_override_cfg)
  string link_id;
  bit has_enable, enabled;
  bit has_gen;
  int unsigned max_gen;
  bit has_width;
  int unsigned link_width;
  bit has_fast_link_training, fast_link_training;
  bit has_link_timeout;
  time link_timeout;
  function new(string name = "pcie_svt_link_override_cfg");
    super.new(name);
  endfunction
  virtual function void do_copy(uvm_object rhs);
    pcie_svt_link_override_cfg source;
    super.do_copy(rhs);
    if (!$cast(source, rhs)) `uvm_fatal("SVT_COPY", "override source type")
    link_id = source.link_id;
    has_enable = source.has_enable;
    enabled = source.enabled;
    has_gen = source.has_gen;
    max_gen = source.max_gen;
    has_width = source.has_width;
    link_width = source.link_width;
    has_fast_link_training = source.has_fast_link_training;
    fast_link_training = source.fast_link_training;
    has_link_timeout = source.has_link_timeout;
    link_timeout = source.link_timeout;
  endfunction
endclass

class pcie_svt_port_descriptor extends uvm_object;
  `uvm_object_utils(pcie_svt_port_descriptor)
  string link_id;
  string svt_node_id;
  string vif_key;
  int unsigned slot_index;
  int unsigned root_hierarchy;
  pcie_svt_role_e role;
  int unsigned physical_width;
  int unsigned link_width;
  int unsigned max_gen;
  bit fast_link_training;
  pcie_svt_transport_e transport;
  time cfg_timeout;
  time link_timeout;
  time enum_timeout;
  time traffic_timeout;
  pcie_svt_bar_cfg ep_bars[6];
  function new(string name = "pcie_svt_port_descriptor");
    super.new(name);
    foreach (ep_bars[i])
      ep_bars[i] = pcie_svt_bar_cfg::type_id::create(
        $sformatf("bar%0d", i));
  endfunction
  virtual function void do_copy(uvm_object rhs);
    pcie_svt_port_descriptor source;
    super.do_copy(rhs);
    if (!$cast(source, rhs)) `uvm_fatal("SVT_COPY", "descriptor source type")
    link_id = source.link_id;
    svt_node_id = source.svt_node_id;
    vif_key = source.vif_key;
    slot_index = source.slot_index;
    root_hierarchy = source.root_hierarchy;
    role = source.role;
    physical_width = source.physical_width;
    link_width = source.link_width;
    max_gen = source.max_gen;
    fast_link_training = source.fast_link_training;
    transport = source.transport;
    cfg_timeout = source.cfg_timeout;
    link_timeout = source.link_timeout;
    enum_timeout = source.enum_timeout;
    traffic_timeout = source.traffic_timeout;
    foreach (ep_bars[i]) ep_bars[i].copy(source.ep_bars[i]);
  endfunction
endclass
~~~

- [ ] **Step 4: Implement the policy and exact BAR defaults**

`pcie_svt_topology_policy_cfg` owns `dut_node_ids[$]`, `vif_prefix`, transport,
timeouts, defaults, BARs, overrides, and the optional associative array
`int unsigned hdl_slot_by_link[string]`. The normal real-DUT policy leaves the
map empty, meaning sorted physical topology-link order; the peer fixture fills
it so an active link retains its primary descriptor's physical HDL slot even
when an earlier link is disabled. Its `init_defaults()` clears the map and
sets:

~~~systemverilog
transport = PCIE_SVT_TRANSPORT_SERIAL;
vif_prefix = "primary_vif_";
reset_vif_key = "primary_reset_vif";
default_fast_link_training = 1'b0;
cfg_timeout = 1ms;
link_timeout = 3ms;
enum_timeout = 3ms;
traffic_timeout = 1ms;
foreach (ep_bars[i]) begin
  ep_bars[i].implemented = 1'b0;
  ep_bars[i].is_64bit = 1'b0;
  ep_bars[i].prefetchable = 1'b0;
  ep_bars[i].aperture = 0;
  ep_bars[i].initial_base = 0;
end
ep_bars[0].implemented = 1'b1;
ep_bars[0].is_64bit = 1'b1;
ep_bars[0].prefetchable = 1'b1;
ep_bars[0].aperture = 64'd33554432;
ep_bars[2].implemented = 1'b1;
ep_bars[2].is_64bit = 1'b1;
ep_bars[2].prefetchable = 1'b1;
ep_bars[2].aperture = 64'd65536;
ep_bars[4].implemented = 1'b1;
ep_bars[4].is_64bit = 1'b1;
ep_bars[4].prefetchable = 1'b1;
ep_bars[4].aperture = 64'd65536;
~~~

The six explicit BAR assignments are the complete default. Implement deep copy
for all arrays and `validate(output string errors[$])` with these exact checks:
non-empty unique DUT IDs; Serial-only transport; positive timeouts; six
non-null BAR handles; each implemented BAR power-of-two and at least 16 bytes;
aligned initial base; each 64-bit low BAR below BAR5 with an unimplemented upper
DWORD; non-empty unique override link IDs; legal override Gen/width; positive
override timeout; non-empty HDL-slot-map keys; and unique HDL slot values.

Create `pcie_svt_topology_pkg.sv`:

~~~systemverilog
package pcie_svt_topology_pkg;
  import uvm_pkg::*;
  import pcie_topology_pkg::*;
  `include "uvm_macros.svh"
  `include "cfg/pcie_svt_backend_types.sv"
  `include "cfg/pcie_svt_topology_policy_cfg.sv"
endpackage
~~~

- [ ] **Step 5: Recompile and run the green model test**

Create `build_model_green`, rerun the Task 1 compile command with both output
paths changed from `build_model_red` to `build_model_green`, then:

~~~bash
./build_model_green/simv -no_save \
  +UVM_TESTNAME=pcie_svt_topology_model_unit_test +UVM_NO_RELNOTES \
  -l build_model_green/run.log
~~~

Expected final summary: `UVM_ERROR : 0` and `UVM_FATAL : 0`.

- [ ] **Step 6: Commit**

~~~bash
git add svt_pcie_integration/uvm/cfg \
  svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv \
  svt_pcie_integration/uvm/tests/pcie_svt_topology_model_unit_test.sv \
  svt_pcie_integration/sim/pcie_svt_topology.f
git commit -m "feat(pcie-svt): add topology backend policy"
~~~

---

### Task 2: Topology-to-SVT Descriptor Adapter

**Files:**
- Create: `svt_pcie_integration/uvm/adapter/pcie_svt_topology_adapter.sv`
- Create: `svt_pcie_integration/uvm/tests/pcie_svt_topology_adapter_unit_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt_topology.f`

- [ ] **Step 1: Write failing positive and negative adapter tests**

The test builds all three profiles with `pcie_topology_builder` and checks these exact descriptor tables:

~~~systemverilog
task check_switch();
  pcie_topology_cfg topology;
  pcie_svt_topology_policy_cfg policy;
  pcie_svt_topology_adapter adapter;
  pcie_svt_port_descriptor ports[$];
  string errors[$];

  topology = pcie_topology_builder::build_switch_1x16_4x4(5);
  policy = pcie_svt_topology_policy_cfg::type_id::create("switch_policy");
  policy.init_defaults();
  policy.dut_node_ids.push_back("SW0");
  adapter = pcie_svt_topology_adapter::type_id::create("adapter");
  adapter.translate(topology, policy, ports, errors);
  require(errors.size() == 0, "Switch translation failed");
  require(ports.size() == 5, "Switch did not produce five ports");
  require(ports[0].link_id == "RC0_SW0_USP0" &&
          ports[0].role == PCIE_SVT_ROLE_RC &&
          ports[0].physical_width == 16, "USP descriptor mismatch");
  for (int i = 1; i < 5; i++)
    require(ports[i].role == PCIE_SVT_ROLE_EP &&
            ports[i].physical_width == 4 &&
            ports[i].root_hierarchy == 0,
            $sformatf("DSP descriptor %0d mismatch", i-1));
endtask
~~~

Add these checks for `EP_X16`:

~~~systemverilog
topology = pcie_topology_builder::build_ep_x16(4);
policy.init_defaults();
policy.dut_node_ids.delete();
policy.dut_node_ids.push_back("EP0");
adapter.translate(topology, policy, ports, errors);
require(errors.size() == 0 && ports.size() == 1,
        "EP_X16 translation failed");
require(ports[0].link_id == "RC0_EP0" &&
        ports[0].role == PCIE_SVT_ROLE_RC &&
        ports[0].physical_width == 16 &&
        ports[0].root_hierarchy == 0,
        "EP_X16 descriptor mismatch");
~~~

Add these checks for `EP_2X8`:

~~~systemverilog
topology = pcie_topology_builder::build_ep_2x8(5);
policy.init_defaults();
policy.dut_node_ids.delete();
policy.dut_node_ids.push_back("EP0");
policy.dut_node_ids.push_back("EP1");
adapter.translate(topology, policy, ports, errors);
require(errors.size() == 0 && ports.size() == 2,
        "EP_2X8 translation failed");
require(ports[0].link_id == "RC0_EP0" &&
        ports[1].link_id == "RC1_EP1" &&
        ports[0].role == PCIE_SVT_ROLE_RC &&
        ports[1].role == PCIE_SVT_ROLE_RC &&
        ports[0].physical_width == 8 &&
        ports[1].physical_width == 8 &&
        ports[0].root_hierarchy == 0 &&
        ports[1].root_hierarchy == 1,
        "EP_2X8 descriptor mismatch");
~~~

Clone that policy, add an `ENABLE=0` override for `RC0_EP0`, translate again,
and require one descriptor with `link_id == "RC1_EP1"`, `slot_index == 1`,
and `vif_key == "primary_vif_1"`. This is the regression that prevents active
descriptors from being compacted onto the wrong static HDL VIF.

The test also makes these calls and checks an error fragment for each:

~~~systemverilog
function bit error_contains(input string errors[$], string fragment);
  foreach (errors[i])
    if (uvm_is_match({"*", fragment, "*"}, errors[i])) return 1'b1;
  return 1'b0;
endfunction

task check_error(pcie_topology_cfg topology,
                 pcie_svt_topology_policy_cfg policy,
                 string expected_fragment);
  pcie_svt_port_descriptor translated[$];
  string local_errors[$];
  adapter.translate(topology, policy, translated, local_errors);
  require(local_errors.size() != 0, "negative adapter case passed");
  require(error_contains(local_errors, expected_fragment),
          {"missing error fragment: ", expected_fragment});
endtask

negative_topology = pcie_topology_builder::build_ep_x16(4);
base_policy = pcie_svt_topology_policy_cfg::type_id::create("base_policy");
base_policy.init_defaults();
base_policy.dut_node_ids.push_back("EP0");

$cast(policy_with_no_dut_nodes, base_policy.clone());
policy_with_no_dut_nodes.dut_node_ids.delete();
$cast(policy_with_both_link_ends_dut_owned, base_policy.clone());
policy_with_both_link_ends_dut_owned.dut_node_ids.push_back("RC0");
$cast(policy_with_missing_node, base_policy.clone());
policy_with_missing_node.dut_node_ids.delete();
policy_with_missing_node.dut_node_ids.push_back("MISSING");
$cast(policy_with_pipe_transport, base_policy.clone());
policy_with_pipe_transport.transport = PCIE_SVT_TRANSPORT_PIPE;

check_error(negative_topology, policy_with_no_dut_nodes,
            "at least one DUT node is required");
check_error(negative_topology, policy_with_both_link_ends_dut_owned,
            "exactly one endpoint must be DUT-owned");
check_error(negative_topology, policy_with_missing_node,
            "DUT node 'MISSING' is absent");
check_error(negative_topology, policy_with_pipe_transport,
            "PIPE transport is not implemented");

width_topology = pcie_topology_builder::build_ep_2x8(4);
width_policy = pcie_svt_topology_policy_cfg::type_id::create("width_policy");
width_policy.init_defaults();
width_policy.dut_node_ids.push_back("EP0");
width_policy.dut_node_ids.push_back("EP1");
width_override = pcie_svt_link_override_cfg::type_id::create(
  "width_override");
width_override.link_id = "RC0_EP0";
width_override.has_width = 1'b1;
width_override.link_width = 16;
width_policy.link_overrides.push_back(width_override);
check_error(width_topology, width_policy,
            "active width x16 exceeds physical width x8");

$cast(policy_with_unknown_override, base_policy.clone());
unknown_override = pcie_svt_link_override_cfg::type_id::create(
  "unknown_override");
unknown_override.link_id = "UNKNOWN";
unknown_override.has_gen = 1'b1;
unknown_override.max_gen = 5;
policy_with_unknown_override.link_overrides.push_back(unknown_override);
check_error(negative_topology, policy_with_unknown_override,
            "override references unknown link");
~~~

- [ ] **Step 2: Compile and prove the adapter test is red**

Add the adapter test to `pcie_svt_topology.f` and include the adapter after the policy in the package. Compile and expect failure naming missing `pcie_svt_topology_adapter`.

- [ ] **Step 3: Implement deterministic translation**

Implement `translate` with this public signature:

~~~systemverilog
function void translate(
    pcie_topology_cfg topology,
    pcie_svt_topology_policy_cfg policy,
    output pcie_svt_port_descriptor ports[$],
    output string errors[$]);
~~~

The algorithm is:

~~~systemverilog
string policy_errors[$];
pcie_topology_link_cfg physical_links[$];
pcie_topology_node_cfg svt_node;
pcie_svt_port_descriptor descriptor;

ports.delete();
errors.delete();
if ((topology == null) || (policy == null)) begin
  errors.push_back("topology and policy must both be non-null");
  return;
end
topology.validate(errors);
policy.validate(policy_errors);
foreach (policy_errors[i]) errors.push_back(policy_errors[i]);
foreach (policy.dut_node_ids[i])
  if (topology.find_node(policy.dut_node_ids[i]) == null)
    errors.push_back($sformatf("DUT node '%s' is absent",
                              policy.dut_node_ids[i]));
if (errors.size() != 0) return;

foreach (topology.links[i])
  physical_links.push_back(topology.links[i]);
sort_pending_links_by_link_id(physical_links);

foreach (physical_links[physical_slot]) begin
  pcie_topology_link_cfg link = physical_links[physical_slot];
  pcie_svt_link_override_cfg link_override;
  bit effective_enabled = link.enabled;
  if (find_override(policy, link.link_id, link_override) &&
      link_override.has_enable)
    effective_enabled = link_override.enabled;
  if (!effective_enabled) begin
    if ((link_override != null) &&
        (link_override.has_gen || link_override.has_width ||
         link_override.has_fast_link_training ||
         link_override.has_link_timeout))
      errors.push_back($sformatf(
        "link '%s': disabled link also carries an active override",
        link.link_id));
    continue;
  end
  pcie_topology_node_cfg up = topology.find_node(link.upstream_node_id);
  pcie_topology_node_cfg down = topology.find_node(link.downstream_node_id);
  bit up_is_dut = policy.is_dut_node(up.node_id);
  bit down_is_dut = policy.is_dut_node(down.node_id);
  if (up_is_dut == down_is_dut) begin
    errors.push_back($sformatf(
      "link '%s': exactly one endpoint must be DUT-owned", link.link_id));
    continue;
  end
  svt_node = up_is_dut ? down : up;
  if (svt_node.kind == PCIE_TOPO_NODE_SWITCH) begin
    errors.push_back($sformatf(
      "link '%s': SVT cannot implement a Switch node", link.link_id));
    continue;
  end
  descriptor = pcie_svt_port_descriptor::type_id::create(
    $sformatf("port_%0d", ports.size()));
  descriptor.link_id = link.link_id;
  descriptor.svt_node_id = svt_node.node_id;
  descriptor.slot_index = policy.hdl_slot_by_link.exists(link.link_id) ?
    policy.hdl_slot_by_link[link.link_id] : physical_slot;
  descriptor.vif_key = {policy.vif_prefix,
                        $sformatf("%0d", descriptor.slot_index)};
  descriptor.role = (svt_node.kind == PCIE_TOPO_NODE_RC) ?
                    PCIE_SVT_ROLE_RC : PCIE_SVT_ROLE_EP;
  descriptor.physical_width = link.link_width;
  descriptor.link_width = effective_width(link, link_override);
  descriptor.max_gen = effective_gen(link, link_override);
  descriptor.fast_link_training =
    effective_fast(policy, link_override);
  descriptor.transport = policy.transport;
  descriptor.cfg_timeout = policy.cfg_timeout;
  descriptor.link_timeout =
    effective_link_timeout(policy, link_override);
  descriptor.enum_timeout = policy.enum_timeout;
  descriptor.traffic_timeout = policy.traffic_timeout;
  foreach (descriptor.ep_bars[bar])
    descriptor.ep_bars[bar].copy(policy.ep_bars[bar]);
  ports.push_back(descriptor);
end
assign_root_hierarchies(topology, ports);
~~~

Implement these private helpers with the listed signatures:

~~~systemverilog
protected function bit find_override(
  pcie_svt_topology_policy_cfg policy, string link_id,
  output pcie_svt_link_override_cfg result);
protected function int unsigned effective_width(
  pcie_topology_link_cfg link, pcie_svt_link_override_cfg override_cfg);
protected function int unsigned effective_gen(
  pcie_topology_link_cfg link, pcie_svt_link_override_cfg override_cfg);
protected function bit effective_fast(
  pcie_svt_topology_policy_cfg policy,
  pcie_svt_link_override_cfg override_cfg);
protected function time effective_link_timeout(
  pcie_svt_topology_policy_cfg policy,
  pcie_svt_link_override_cfg override_cfg);
protected function void sort_pending_links_by_link_id(
  ref pcie_topology_link_cfg links[$]);
protected function void assign_root_hierarchies(
  pcie_topology_cfg topology,
  ref pcie_svt_port_descriptor ports[$]);
~~~

`assign_root_hierarchies` assigns each direct RC/EP link its original
sorted-physical-link index and assigns every link in the single-Switch profile
hierarchy 0. Before returning, reject unknown overrides, non-Serial transport,
illegal effective Gen/width, any non-enable field attached to an effectively
disabled link, duplicate descriptors, duplicate effective HDL slots, an
HDL-slot-map entry for an unknown link, and an empty descriptor result. An
override that only sets `ENABLE=0` is legal and is the supported way to omit
that UVM agent.

- [ ] **Step 4: Run the adapter test green**

Run:

~~~bash
./build_adapter/simv -no_save \
  +UVM_TESTNAME=pcie_svt_topology_adapter_unit_test +UVM_NO_RELNOTES \
  -l build_adapter/run.log
~~~

Expected: exact counts 1/2/5, no error/fatal summary, and all negative cases consumed as returned error strings rather than emitted UVM reports.

- [ ] **Step 5: Commit**

~~~bash
git add svt_pcie_integration/uvm/adapter \
  svt_pcie_integration/uvm/tests/pcie_svt_topology_adapter_unit_test.sv \
  svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv \
  svt_pcie_integration/sim/pcie_svt_topology.f
git commit -m "feat(pcie-svt): translate common topology to SVT ports"
~~~

---

### Task 3: Strict Runtime Profiles, Per-Link Overrides, and Peer Fixture

**Files:**
- Create: `svt_pcie_integration/uvm/cfg/pcie_svt_cli_parser.sv`
- Create: `svt_pcie_integration/uvm/cfg/pcie_svt_profile_factory.sv`
- Create: `svt_pcie_integration/uvm/adapter/pcie_svt_peer_fixture_builder.sv`
- Create: `svt_pcie_integration/uvm/tests/pcie_svt_cli_parser_unit_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt_topology.f`

- [ ] **Step 1: Write failing parser/profile tests**

Expose token-based parsing so malformed cases do not depend on the process command line:

~~~systemverilog
function void parse_tokens(
  input string args[$],
  output string profile_name,
  output int unsigned max_gen,
  output bit fast_link_training,
  output pcie_svt_transport_e transport,
  output pcie_svt_run_mode_e run_mode,
  output pcie_svt_link_override_cfg overrides[$],
  output string errors[$]);
~~~

The positive test passes:

~~~systemverilog
args = '{"+PCIE_TOPOLOGY=EP_2X8", "+PCIE_GEN=5",
         "+PCIE_TRANSPORT=SERIAL",
         "+PCIE_FAST_LINK_TRAIN=1", "+PCIE_LINK_RC1_EP1_GEN=4",
         "+PCIE_LINK_RC1_EP1_WIDTH=4", "+PCIE_TRAFFIC"};
parser.parse_tokens(
  args, profile, gen, fast, transport, mode, overrides, errors);
require(errors.size() == 0, "legal CLI was rejected");
require(profile == "EP_2X8" && gen == 5 && fast &&
        transport == PCIE_SVT_TRANSPORT_SERIAL &&
        mode == PCIE_SVT_RUN_TRAFFIC, "global CLI values mismatch");
require(overrides.size() == 1 && overrides[0].link_id == "RC1_EP1" &&
        overrides[0].has_gen && overrides[0].max_gen == 4 &&
        overrides[0].has_width && overrides[0].link_width == 4,
        "per-link override merge mismatch");
~~~

Test missing, bare, empty, duplicated, unknown profile, Gen3, duplicate run mode, bare fast mode, unknown link field, and conflicting duplicate per-link fields. Every negative case must return a precise string and emit no UVM report.

- [ ] **Step 2: Add a peer fixture test**

For each primary descriptor array, call:

~~~systemverilog
pcie_svt_peer_fixture_builder::build(
  primary_ports, peer_topology, peer_policy, errors);
~~~

Check that `EP_X16` produces one peer EP, `EP_2X8` produces two peer EPs, and the Switch profile produces one x16 peer EP plus four x4 peer RCs. The fixture topology contains only independent RC-to-EP links named with `$sformatf("PEER_LINK_%0d", slot)` for `slot=0` through `primary_ports.size()-1`, and `peer_policy.vif_prefix == "peer_vif_"`.

- [ ] **Step 3: Compile and prove both new tests are red**

Expected compile failures name `pcie_svt_cli_parser` and `pcie_svt_peer_fixture_builder`.

- [ ] **Step 4: Implement profile and policy construction**

`pcie_svt_profile_factory::build` has this contract:

~~~systemverilog
static function void build(
  string profile_name,
  int unsigned max_gen,
  output pcie_topology_cfg topology,
  output pcie_svt_topology_policy_cfg policy,
  output string errors[$]);
~~~

Use the existing common builders, then assign DUT nodes exactly:

~~~systemverilog
errors.delete();
topology = null;
policy = pcie_svt_topology_policy_cfg::type_id::create(
  {profile_name, "_policy"});
policy.init_defaults();
case (profile_name)
  "EP_X16": begin
    topology = pcie_topology_builder::build_ep_x16(max_gen);
    policy.dut_node_ids.push_back("EP0");
  end
  "EP_2X8": begin
    topology = pcie_topology_builder::build_ep_2x8(max_gen);
    policy.dut_node_ids.push_back("EP0");
    policy.dut_node_ids.push_back("EP1");
  end
  "SWITCH_1X16_4X4": begin
    topology =
      pcie_topology_builder::build_switch_1x16_4x4(max_gen);
    policy.dut_node_ids.push_back("SW0");
  end
  default:
    errors.push_back($sformatf("unknown topology profile '%s'",
                              profile_name));
endcase
~~~

Expose override application as a separate checked operation so the base test
does not mutate policy internals ad hoc:

~~~systemverilog
static function void apply_overrides(
  pcie_topology_cfg topology,
  input pcie_svt_link_override_cfg overrides[$],
  pcie_svt_topology_policy_cfg policy,
  output string errors[$]);
~~~

`apply_overrides` clears `errors`, rejects null arguments, rejects every
override whose `link_id` does not name a topology link, clones each accepted
override into `policy.link_overrides`, and finally calls `policy.validate`.
The base test calls `build`, then `apply_overrides`, then the topology adapter.

Add one package function used by the base test to reject runtime/compile mismatch:

~~~systemverilog
function automatic string pcie_svt_compiled_profile_name();
`ifdef PCIE_TOPO_EP_X16
  return "EP_X16";
`elsif PCIE_TOPO_EP_2X8
  return "EP_2X8";
`elsif PCIE_TOPO_SWITCH_1X16_4X4
  return "SWITCH_1X16_4X4";
`else
  return "";
`endif
endfunction
~~~

The base test compares this return value with the parsed profile before it creates either environment.

- [ ] **Step 5: Implement strict token parsing**

Use the `pcie_svt_run_mode_e` defined in Task 1. Parsing rules are:

- exactly one of `+PCIE_TOPOLOGY=EP_X16`, `EP_2X8`, or
  `SWITCH_1X16_4X4`;
- exactly one `+PCIE_GEN=4|5`;
- zero or one `+PCIE_TRANSPORT=SERIAL|PIPE`, default Serial; PIPE reaches
  policy validation and fails with the explicit not-implemented error;
- zero or one `+PCIE_FAST_LINK_TRAIN=0|1`, default 0;
- exactly one bare run-mode token from `+PCIE_COMPILE_ONLY`,
  `+PCIE_CFG_INIT_ONLY`, `+PCIE_LINK_ONLY`, `+PCIE_ENUM_ONLY`, or
  `+PCIE_TRAFFIC`;
- per-link arguments match `+PCIE_LINK_<link_id>_(ENABLE|GEN|WIDTH|FAST_LINK_TRAIN)=<value>`;
- repeated fields for one link are errors even when values match.

`parse_command_line` gets `uvm_cmdline_processor::get_inst().get_args(args)` and delegates to `parse_tokens`, so the behavior has one implementation.

- [ ] **Step 6: Implement peer fixture synthesis**

For each primary descriptor, create a standalone `RC_i`/`EP_i` pair with the
same width and generation. If the primary role is RC, list synthetic `RC_i` as
DUT-owned so the peer adapter creates EP. If the primary role is EP, list
synthetic `EP_i` as DUT-owned so it creates RC. Set
`peer_policy.hdl_slot_by_link[peer_link_id] = primary.slot_index`,
`vif_prefix="peer_vif_"`, and `reset_vif_key="peer_reset_vif"`. Do not add a
Switch node.

- [ ] **Step 7: Run tests and commit**

Expected: parser positive/negative cases and peer role tables pass with `UVM_ERROR/FATAL=0`.

~~~bash
git add svt_pcie_integration/uvm/cfg \
  svt_pcie_integration/uvm/adapter/pcie_svt_peer_fixture_builder.sv \
  svt_pcie_integration/uvm/tests/pcie_svt_cli_parser_unit_test.sv \
  svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv \
  svt_pcie_integration/sim/pcie_svt_topology.f
git commit -m "feat(pcie-svt): add runtime profiles and peer fixtures"
~~~

---

### Task 4: R-2020.12 Device Configuration Builder

**Files:**
- Create: `svt_pcie_integration/uvm/cfg/pcie_svt_device_cfg_builder.sv`
- Create: `svt_pcie_integration/uvm/cfg/pcie_svt_cfg_space_builder.sv`
- Create: `svt_pcie_integration/uvm/tests/pcie_svt_device_cfg_unit_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt_topology.f`

- [ ] **Step 1: Write failing BAR and device-configuration tests**

The BAR test checks:

~~~systemverilog
require(pcie_svt_cfg_space_builder::bar_ro_map(
          64'd33554432, 1'b0) == 32'h01ff_ffff,
        "BAR0 low RO map mismatch");
require(pcie_svt_cfg_space_builder::bar_ro_map(
          64'd33554432, 1'b1) == 32'h0000_0000,
        "BAR0 high RO map mismatch");
require(pcie_svt_cfg_space_builder::bar_ro_map(
          64'd65536, 1'b0) == 32'h0000_ffff,
        "64 KiB low RO map mismatch");
require(pcie_svt_cfg_space_builder::bar_initial_value(
          ep_descriptor.ep_bars[0], 1'b0) == 32'h0000_000c,
        "64-bit Prefetchable BAR attributes mismatch");
~~~

Create RC and EP descriptors for x4/x8/x16 and Gen4/Gen5, apply them to fresh `svt_pcie_device_configuration` objects, and check:

~~~systemverilog
require(rc_cfg.device_is_root == 1'b1, "RC role changed");
require(ep_cfg.device_is_root == 1'b0, "EP role changed");
require(ep_cfg.pcie_cfg.enable_multi_endpoint_mode == 1'b1,
        "EP Multi-Endpoint Mode is disabled");
require(rc_cfg.pcie_cfg.enable_multi_endpoint_mode == 1'b0,
        "RC Multi-Endpoint Mode is enabled");
require(ep_cfg.target_cfg.exists(0) &&
        ep_cfg.target_cfg[0].default_bar_ro_map == 32'h0000_ffff,
        "Endpoint Target App default RO map mismatch");
require(gen4_cfg.pcie_cfg.pl_cfg.get_target_link_speed_value() ==
          `SVT_PCIE_SPEED_16_0G, "Gen4 target speed mismatch");
require(gen5_cfg.pcie_cfg.pl_cfg.get_target_link_speed_value() ==
          `SVT_PCIE_SPEED_32_0G, "Gen5 target speed mismatch");
~~~

For fast mode, check Gen4 uses `FULL_EQUALIZATION_REQUIRED` with direct 2.5-to-16G enabled and Gen5 uses `EQ_BYPASS_TO_HIGHEST_RATE`.

- [ ] **Step 2: Add the official example include path and prove the test is red**

Add:

~~~text
+incdir+$PCIE_SVT_ROOT/examples/sverilog/tb_pcie_svt_uvm_unified_vip_sys/env
~~~

After the vendor package imports inside `pcie_svt_topology_pkg`, include the official class:

~~~systemverilog
import svt_uvm_pkg::*;
import svt_pcie_uvm_pkg::*;
`include "pcie_device_unified_vip_env.sv"
~~~

Then add the new cfg includes and test. Expected initial failure names `pcie_svt_device_cfg_builder`.

- [ ] **Step 3: Implement BAR calculations and a minimal PF0 image**

`bar_ro_map` and `bar_initial_value` are pure functions:

~~~systemverilog
static function bit [31:0] bar_ro_map(
    longint unsigned aperture, bit high_dword);
  bit [63:0] ro_map;
  if ((aperture < 16) || ((aperture & (aperture - 1)) != 0))
    `uvm_fatal("SVT_BAR", $sformatf("invalid aperture 0x%0h", aperture))
  ro_map = aperture - 1;
  return high_dword ? ro_map[63:32] : ro_map[31:0];
endfunction

static function bit [31:0] bar_initial_value(
    pcie_svt_bar_cfg bar, bit high_dword);
  bit [31:0] value;
  if ((bar == null) || !bar.implemented)
    return 32'h0;
  value = high_dword ? bar.initial_base[63:32] :
                       bar.initial_base[31:0];
  if (!high_dword) begin
    value[2:1] = bar.is_64bit ? 2'b10 : 2'b00;
    value[3] = bar.prefetchable;
  end
  return value;
endfunction
~~~

`build_ep_pf0` initializes all 1024 DWORDs to zero, then writes a legal type-0 PF0 image:

~~~systemverilog
foreach (image[i]) image[i] = 32'h0000_0000;
image[12'h000/4] = {16'h5011 + descriptor.slot_index[15:0], 16'h20f9};
image[12'h004/4] = 32'h0010_0000;
image[12'h008/4] = {24'h020000, 8'h00};
image[12'h00c/4] = 32'h0000_0000;
for (int bar = 0; bar < 6; bar++) begin
  if (descriptor.ep_bars[bar].implemented)
    image[(12'h010/4)+bar] =
      bar_initial_value(descriptor.ep_bars[bar], 1'b0);
  else if ((bar > 0) && descriptor.ep_bars[bar-1].implemented &&
           descriptor.ep_bars[bar-1].is_64bit)
    image[(12'h010/4)+bar] =
      bar_initial_value(descriptor.ep_bars[bar-1], 1'b1);
end
image[12'h02c/4] = {16'h5011 + descriptor.slot_index[15:0], 16'h20f9};
image[12'h03c/4] = 32'h0000_0100;
~~~

- [ ] **Step 4: Implement descriptor-to-SVT configuration**

Move the already verified width/speed logic from old
`pcie_svt_port_env::apply_profile_to_cfg` behind this exact interface:

~~~systemverilog
function void apply(pcie_svt_port_descriptor descriptor,
                    svt_pcie_vif vif,
                    svt_pcie_device_configuration cfg);
~~~

`apply` rejects null arguments, calls
`cfg.set_initial_values_via_unified_vif(1, vif)` exactly once, and then rejects
a VIF-derived `device_is_root` or physical-lane count that disagrees with the
descriptor before applying any policy value.

The width vectors remain exact:

~~~systemverilog
case (descriptor.link_width)
  4: supported_widths = 32'h0000_0007;
  8: supported_widths = 32'h0000_000f;
  16: supported_widths = 32'h0000_003f;
  default: `uvm_fatal("SVT_CFG", "unsupported active width")
endcase
cfg.pcie_cfg.pl_cfg.set_link_width_values(
  descriptor.link_width, supported_widths, descriptor.link_width);
~~~

The supported speed vector includes Gen1 through Gen4 and adds 32 GT/s only for Gen5. Set the target and expected speed to 16 GT/s or 32 GT/s. Preserve `disable_ext_bit_clock_mode=1` for `TRANSMIT_BIT_CLOCK_MODE=1`.

For fast mode:

~~~systemverilog
if (descriptor.fast_link_training && (descriptor.max_gen == 5))
  cfg.pcie_cfg.pl_cfg.set_link_eq_attribute_values(
    svt_pcie_pl_configuration::LINK_EQ_MODE_EQ_BYPASS_TO_HIGHEST_RATE,
    1'b0, 3);
else if (descriptor.fast_link_training)
  cfg.pcie_cfg.pl_cfg.set_link_eq_attribute_values(
    svt_pcie_pl_configuration::LINK_EQ_MODE_FULL_EQUALIZATION_REQUIRED,
    1'b1, 3);
~~~

For Endpoint descriptors, set `enable_multi_endpoint_mode=1` and `target_cfg[0].default_bar_ro_map=32'h0000_ffff`. For RC descriptors, set Multi-Endpoint Mode to zero. Do not create or register the old BAR TLP-rewrite callback.

- [ ] **Step 5: Compile/run and commit**

Expected: all six width/generation combinations and both fast modes pass; final warnings/errors/fatals are zero.

~~~bash
git add svt_pcie_integration/uvm/cfg \
  svt_pcie_integration/uvm/tests/pcie_svt_device_cfg_unit_test.sv \
  svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv \
  svt_pcie_integration/sim/pcie_svt_topology.f
git commit -m "feat(pcie-svt): build R-2020.12 device configurations"
~~~

---

### Task 5: One-Sided Unified-VIP Topology Environment

**Files:**
- Create: `svt_pcie_integration/uvm/env/pcie_svt_topology_virtual_sequencer.sv`
- Create: `svt_pcie_integration/uvm/env/pcie_svt_topology_env.sv`
- Create: `svt_pcie_integration/uvm/tests/pcie_svt_topology_base_test.sv`
- Create: `svt_pcie_integration/rtl/pcie_svt_hdl_agent_macros.svh`
- Create: `svt_pcie_integration/rtl/pcie_svt_dut_wrapper.sv`
- Create: `svt_pcie_integration/rtl/pcie_svt_topology_env_top.sv`
- Modify: `svt_pcie_integration/rtl/pcie_svt_topology_checks.svh`
- Modify: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt_topology.f`

- [ ] **Step 1: Write the failing environment contract test**

`pcie_svt_topology_base_test` parses the command line, builds topology/policy, publishes both to `env`, and creates `pcie_svt_topology_env`. Its elaboration check is:

~~~systemverilog
virtual function void end_of_elaboration_phase(uvm_phase phase);
  pcie_svt_topology_adapter count_adapter;
  pcie_svt_port_descriptor expected_ports[$];
  string adapter_errors[$];
  super.end_of_elaboration_phase(phase);
  count_adapter = pcie_svt_topology_adapter::type_id::create(
    "count_adapter");
  count_adapter.translate(topology_cfg, policy_cfg,
                          expected_ports, adapter_errors);
  if (adapter_errors.size() != 0)
    `uvm_fatal("SVT_ENV_COUNT", pcie_svt_join_errors(adapter_errors))
  if (env.port_count() != expected_ports.size())
    `uvm_fatal("SVT_ENV_COUNT", $sformatf(
      "profile=%s expected=%0d actual=%0d",
      profile_name, expected_ports.size(), env.port_count()))
  if (env.vseqr == null)
    `uvm_fatal("SVT_ENV_VSEQR", "topology virtual sequencer is null")
  `uvm_info("PCIE_SVT_ENV_READY", $sformatf(
    "profile=%s agents=%0d", profile_name, env.port_count()), UVM_NONE)
endfunction
~~~

Add unit checks that
`env.vseqr.get_port_descriptor("missing")` and
`env.vseqr.get_port_seqr("missing")` return null, every expected `link_id`
resolves once, `root` aliases the first RC, `endpoint` aliases the first EP,
and no UVM component path contains the old `port[5]` through `port[9]`
pattern. An effectively disabled link is absent from the environment and the
expected count, while its static compiled HDL slot remains idle.

- [ ] **Step 2: Add the new top/filelist and prove compilation is red**

The file is named `pcie_svt_topology_env_top.sv` during parallel development, but its module is `pcie_svt_topology_top` so the vendor bootstrap hierarchy macros remain valid. Replace the old top entry in the new file list with this file and compile `-top pcie_svt_topology_top`. Expected failure names missing `pcie_svt_topology_env`.

- [ ] **Step 3: Implement the link-ID virtual-sequencer registry**

The virtual sequencer stores associative arrays keyed by string:

~~~systemverilog
pcie_svt_port_descriptor descriptor_by_link[string];
svt_pcie_device_configuration cfg_by_link[string];
svt_pcie_device_status status_by_link[string];
svt_pcie_device_agent agent_by_link[string];
svt_pcie_device_virtual_sequencer seqr_by_link[string];
pcie_svt_stage_state_e cfg_state[string];
pcie_svt_stage_state_e link_state[string];
pcie_svt_stage_state_e enum_state[string];
pcie_svt_stage_state_e traffic_state[string];
bit host_memory_window_valid[string];
bit [63:0] host_memory_base[string];
bit [63:0] host_memory_limit[string];
virtual pcie_svt_reset_if reset_vif;
~~~

`register_port` rejects nulls and duplicates. `connect_port` adds the device virtual sequencer after agent construction. `get_port_descriptor` and `get_port_seqr` return null for a missing key; `require_port_seqr` emits a contextual fatal. `get_links_by_role` returns sorted link IDs. `report_stage_table` emits one `PCIE_SVT_STAGE` record per link with all four states.

`reserve_host_memory_window(link_id, base, limit)` accepts only a registered RC
link and a nonempty range that does not overlap another range in the same root
hierarchy, and records the three host-memory
fields above. `get_host_memory_window` returns `0` until a range has been
reserved. This is the retained extension point for later Endpoint-to-RC DMA;
it is not a pass criterion in this phase.

- [ ] **Step 4: Implement the derived environment without base lifecycle duplication**

Declare:

~~~systemverilog
class pcie_svt_topology_env extends pcie_device_unified_vip_env;
  `uvm_component_utils(pcie_svt_topology_env)
  pcie_topology_cfg topology_cfg;
  pcie_svt_topology_policy_cfg policy_cfg;
  pcie_svt_port_descriptor descriptors[$];
  svt_pcie_device_configuration port_cfg[];
  svt_pcie_device_status port_status[];
  svt_pcie_device_agent port_agent[];
  pcie_svt_topology_virtual_sequencer vseqr;
  pcie_svt_topology_adapter adapter;
  string errors[$];
  function new(string name = "pcie_svt_topology_env",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual function void connect_phase(uvm_phase phase);
endclass
~~~

`build_phase` deliberately does not call `super.build_phase`. It performs:

~~~systemverilog
if (!uvm_config_db#(pcie_topology_cfg)::get(
      this, "", "topology_cfg", topology_cfg) || topology_cfg == null)
  `uvm_fatal("SVT_ENV_CFG", "non-null topology_cfg is required")
if (!uvm_config_db#(pcie_svt_topology_policy_cfg)::get(
      this, "", "policy_cfg", policy_cfg) || policy_cfg == null)
  `uvm_fatal("SVT_ENV_CFG", "non-null policy_cfg is required")
adapter = pcie_svt_topology_adapter::type_id::create("adapter");
adapter.translate(topology_cfg, policy_cfg, descriptors, errors);
if (errors.size() != 0)
  `uvm_fatal("SVT_ENV_CFG", pcie_svt_join_errors(errors))
port_cfg = new[descriptors.size()];
port_status = new[descriptors.size()];
port_agent = new[descriptors.size()];
vseqr = pcie_svt_topology_virtual_sequencer::type_id::create("vseqr", this);
sys_virt_seqr =
  svt_pcie_device_system_virtual_sequencer::type_id::create(
    "sys_virt_seqr", this);
~~~

For each descriptor: get `svt_pcie_vif` from the parent test using
`descriptor.vif_key`; create cfg/status; call
`cfg_builder.apply(descriptor, vif, cfg)` (which performs the one permitted
`set_initial_values_via_unified_vif` call); publish cfg/status to child name
`$sformatf("port_%0d", i)`; create exactly one
`svt_pcie_device_agent`; register handles with `vseqr`. Get the reset VIF by
`policy_cfg.reset_vif_key`.

Assign inherited aliases without creating more agents:

~~~systemverilog
root = null;
endpoint = null;
foreach (descriptors[i]) begin
  if ((root == null) && descriptors[i].role == PCIE_SVT_ROLE_RC)
    root = port_agent[i];
  if ((endpoint == null) && descriptors[i].role == PCIE_SVT_ROLE_EP)
    endpoint = port_agent[i];
end
~~~

`connect_phase` also does not call the official implementation. Register every `port_agent[i].virt_seqr`. Populate `sys_virt_seqr.root_virt_seqr` and `endpoint_virt_seqr` only from the aliases that exist.

- [ ] **Step 5: Create clean primary HDL declarations**

`pcie_svt_hdl_agent_macros.svh` defines three macros, one per maximum width. Each macro instantiates `svt_pcie_if`, `svt_pcie_single_port_device_agent_hdl`, and `pcie_svt_serial_port_if`, sets Gen5-capable Serial parameters, role, hierarchy, and lane count, then invokes the existing `PCIE_SVT_MAP_SERDES_X4/X8/X16` mapping.

The new top declares only:

- one primary RC x16 for `EP_X16`;
- two primary RC x8 for `EP_2X8`;
- one primary RC x16 and four primary EP x4 for the Switch profile.

Publish keys `primary_vif_0` through `primary_vif_4` and `primary_reset_vif`. The idle DUT wrapper drives legal idle differential values and cannot train. Remove all Proxy and sidecar includes from this new top.

- [ ] **Step 6: Compile/elaborate all three profiles**

For each macro, compile the new file list. Then run these exact commands:

~~~bash
./build_ep_x16/simv -no_save \
  +UVM_TESTNAME=pcie_svt_topology_base_test \
  +PCIE_TOPOLOGY=EP_X16 +PCIE_GEN=4 +PCIE_COMPILE_ONLY \
  +UVM_NO_RELNOTES -l build_ep_x16/run_compile.log
./build_ep_2x8/simv -no_save \
  +UVM_TESTNAME=pcie_svt_topology_base_test \
  +PCIE_TOPOLOGY=EP_2X8 +PCIE_GEN=4 +PCIE_COMPILE_ONLY \
  +UVM_NO_RELNOTES -l build_ep_2x8/run_compile.log
./build_switch/simv -no_save \
  +UVM_TESTNAME=pcie_svt_topology_base_test \
  +PCIE_TOPOLOGY=SWITCH_1X16_4X4 +PCIE_GEN=4 \
  +PCIE_COMPILE_ONLY +UVM_NO_RELNOTES \
  -l build_switch/run_compile.log
~~~

Expected `PCIE_SVT_ENV_READY` counts are 1, 2, and 5. Expected final warnings/errors/fatals are zero. Use `uvm_top.print_topology()` evidence to confirm no second vendor-created RC/EP pair exists.

- [ ] **Step 7: Commit**

~~~bash
git add svt_pcie_integration/uvm/env \
  svt_pcie_integration/uvm/tests/pcie_svt_topology_base_test.sv \
  svt_pcie_integration/rtl/pcie_svt_hdl_agent_macros.svh \
  svt_pcie_integration/rtl/pcie_svt_dut_wrapper.sv \
  svt_pcie_integration/rtl/pcie_svt_topology_env_top.sv \
  svt_pcie_integration/rtl/pcie_svt_topology_checks.svh \
  svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv \
  svt_pcie_integration/sim/pcie_svt_topology.f
git commit -m "feat(pcie-svt): add one-sided unified topology env"
~~~

---

### Task 6: Official Multi-Endpoint Configuration and BAR Initialization

**Files:**
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_cfg_init_vseq.sv`
- Create: `svt_pcie_integration/uvm/tests/pcie_svt_cfg_init_directed_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Modify: `svt_pcie_integration/uvm/tests/pcie_svt_topology_base_test.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt_topology.f`

- [ ] **Step 1: Write a failing directed BAR-service test**

Use a factory override for the child sequence to record requested operations without waiting on HDL. For one Endpoint descriptor, require this order:

~~~text
REFRESH_CFG
BAR0 SET_MAP 01ff_ffff
BAR0 WRITE_ADDR 0000_000c
BAR0 READ_ADDR
BAR0 GET_MAP
BAR1 SET_MAP 0000_0000
BAR1 WRITE_ADDR 0000_0000
BAR1 READ_ADDR
BAR1 GET_MAP
BAR2 SET_MAP 0000_ffff
BAR2 WRITE_ADDR 0000_000c
BAR2 READ_ADDR
BAR2 GET_MAP
BAR3 SET_MAP 0000_0000
BAR3 WRITE_ADDR 0000_0000
BAR3 READ_ADDR
BAR3 GET_MAP
BAR4 SET_MAP 0000_ffff
BAR4 WRITE_ADDR 0000_000c
BAR4 READ_ADDR
BAR4 GET_MAP
BAR5 SET_MAP 0000_0000
BAR5 WRITE_ADDR 0000_0000
BAR5 READ_ADDR
BAR5 GET_MAP
SET_COMPLETER_SPACE_ENABLE memory=1
~~~

Require exactly 24 BAR checks for the four downstream Endpoint agents in the
Switch profile and zero BAR operations for the upstream RC. Do not expect or
emit a synthetic RC-skip record.

- [ ] **Step 2: Prove the directed test is red**

Expected compile failure names `pcie_svt_cfg_init_vseq`.

- [ ] **Step 3: Publish a normalized R-2020.12 runtime configuration**

For each Endpoint, call `agent.get_cfg()` to obtain the normalized current
configuration, clone it into a per-Endpoint runtime object, and require
Endpoint role, Multi-Endpoint Mode, and a non-null `target_cfg[0]`. Publish the
clone at the agent's exact config-DB scope immediately before `REFRESH_CFG`.
The topology registry retains its original configuration handle. Do not catch,
demote, or otherwise suppress an `is_valid` warning; the published clone must
pass `is_valid(0)` without adding a warning.

- [ ] **Step 4: Implement per-Endpoint refresh and BAR service**

Before `REFRESH_CFG`, fetch, clone, validate, and publish the agent-current
configuration:

~~~systemverilog
agent.get_cfg(generic_cfg);
if (!$cast(current_cfg, generic_cfg) ||
    !$cast(runtime_cfg, current_cfg.clone()))
  `uvm_fatal("SVT_CFG_REFRESH", descriptor.link_id)
if (runtime_cfg.device_is_root ||
    !runtime_cfg.pcie_cfg.enable_multi_endpoint_mode ||
    !runtime_cfg.target_cfg.exists(0) || runtime_cfg.target_cfg[0] == null)
  `uvm_fatal("SVT_CFG_REFRESH", descriptor.link_id)
uvm_config_db#(svt_pcie_device_configuration)::set(
  agent, "", "cfg", runtime_cfg);
refresh_seq = svt_pcie_device_agent_service_sequence::type_id::create(
  {descriptor.link_id, "_refresh"});
if (!refresh_seq.randomize() with {
      service_type == svt_pcie_device_agent_service::REFRESH_CFG;
    })
  `uvm_fatal("SVT_CFG_REFRESH", descriptor.link_id)
refresh_seq.start(seqr.device_agent_service_seqr);
~~~

After every Endpoint refresh returns, release reset once, confirm that all
effective links remain down, and do not start either the DL-link-enable or
PL-PHY-enable sequence. Only then allow the per-Endpoint PF0 and Target App
work to proceed.

For BAR0 through BAR5, derive the low/upper source BAR and expected values from the descriptor. Start `svt_pcie_target_app_service_set_bar_ro_map_sequence`, `write_addr_sequence`, `read_addr_sequence`, and `get_bar_ro_map_sequence` on `seqr.target_seqr[0]`. Use ECAM `{16'h0000, 12'(12'h010 + 4*bar)}`. Fatal on read or map mismatch.

For the same PF0, call `pcie_svt_cfg_space_builder::build_ep_pf0` and preload
all 1024 DWORDs through `svt_pcie_cfg_database_service::WRITE_CFG_DWORD` on
`seqr.cfg_database_seqr`; zero DWORDs are intentional reset data. Read back
DWORDs `000`, `004`, `008`, `00c`, `010` through `024`, `02c`, and `03c`
with `READ_CFG_DWORD` and compare the complete 32-bit values. All database and
Target App work occurs after reset release while links remain disabled. Bind
each configuration-database request to that Endpoint's published runtime clone,
not the topology registry object. One per-Endpoint `cfg_timeout` is a total
budget from child-sequence start through refresh, reset barrier, PF0 work, BAR
work, completer enable, and completion; do not restart the timeout at the reset
barrier. A completion scheduled exactly at the deadline is accepted after one
`#1step` settle; a later or absent completion is fatal, with start, deadline,
and completion times in the diagnostic.

Finally start:

~~~systemverilog
svt_pcie_target_app_service_set_completer_space_enable_sequence
~~~

with `io_select=0` and `data=1`.

- [ ] **Step 5: Run staged configuration without enabling links**

`pcie_svt_cfg_init_vseq` waits 205 ns with reset asserted, confirms every
effective link remains down, refreshes every Endpoint, releases reset without
enabling DL or PHY, and then performs the PF0/BAR/completer work. Endpoint work
runs in parallel, and each Endpoint receives one whole-sequence
`descriptor.cfg_timeout` budget before its CFG stage becomes PASS. RC agents
receive CFG PASS after cfg/status/sequencer handle validation but no BAR
service. The sequence has a `bit program_target_bars=1` control: primary
environments keep it enabled; a peer environment enables it only for direct EP
profiles where the peer Endpoint will be enumerated. Switch point-to-point
peers set it to zero, so the Switch peer run still checks exactly the four
primary downstream Endpoint BAR sets.

Run the idle Switch DUT wrapper at Gen4 and Gen5:

~~~bash
for gen in 4 5; do
  ./build_switch/simv -no_save \
    +UVM_TESTNAME=pcie_svt_topology_base_test \
    +PCIE_TOPOLOGY=SWITCH_1X16_4X4 +PCIE_GEN="$gen" \
    +PCIE_CFG_INIT_ONLY +UVM_NO_RELNOTES \
    -l "build_switch/run_cfg_gen$gen.log"
done
~~~

Expected: 4 refreshes, 24 `PCIE_SVT_BAR_CHECK` records, 5 CFG PASS states, and final 0/0/0. Confirm the HDL log shows Multi-Endpoint Mode enabled after refresh.

- [ ] **Step 6: Commit**

~~~bash
git add svt_pcie_integration/uvm/sequences/pcie_svt_cfg_init_vseq.sv \
  svt_pcie_integration/uvm/tests/pcie_svt_cfg_init_directed_test.sv \
  svt_pcie_integration/uvm/tests/pcie_svt_topology_base_test.sv \
  svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv \
  svt_pcie_integration/sim/pcie_svt_topology.f
git commit -m "feat(pcie-svt): configure endpoint BARs through target app"
~~~

---

### Task 7: Separate Peer Environments and Parallel Serial Link Training

**Files:**
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_link_vseq.sv`
- Create: `svt_pcie_integration/uvm/tests/pcie_svt_peer_test.sv`
- Modify: `svt_pcie_integration/rtl/pcie_svt_peer_harness.sv`
- Modify: `svt_pcie_integration/rtl/pcie_svt_topology_env_top.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt_topology.f`

- [ ] **Step 1: Write the failing two-environment peer test**

`pcie_svt_peer_test` extends the base test. Before component creation it uses the primary adapter result to build synthetic peer topology/policy, sets their VIF/reset prefixes, and creates a second `pcie_svt_topology_env peer_env`. Check:

~~~systemverilog
if (peer_env.port_count() != env.port_count())
  `uvm_fatal("SVT_PEER_COUNT", "primary/peer count mismatch")
foreach (env.descriptors[i]) begin
  pcie_svt_port_descriptor peer = peer_env.descriptors[i];
  if (peer.role == env.descriptors[i].role ||
      peer.link_width != env.descriptors[i].link_width ||
      peer.max_gen != env.descriptors[i].max_gen)
    `uvm_fatal("SVT_PEER_PAIR", $sformatf(
      "slot=%0d role/width/gen mismatch", i))
end
~~~

- [ ] **Step 2: Expand the clean HDL peer branch**

Under `PCIE_USE_SVT_PEER`, declare:

- EP x16 opposite the primary RC for `EP_X16`;
- two EP x8 devices opposite the two RCs for `EP_2X8`;
- one EP x16 opposite the Switch-facing upstream RC and four RC x4 devices opposite the downstream EPs.

Publish `$sformatf("peer_vif_%0d", slot)` for slots 0 through 4 as present in the compiled profile, plus `peer_reset_vif`. Use only `PCIE_SVT_CONNECT_SERIAL_PEERS`. Do not include sidecar interfaces, Target callbacks, `pcie_tl_switch`, or raw-TLP reinjection.

- [ ] **Step 3: Prove link flow is red before the sequence exists**

Run `+PCIE_LINK_ONLY` and expect failure naming missing `pcie_svt_link_vseq`.

- [ ] **Step 4: Implement link enable and checked wait**

For each registered link start these public sequences concurrently:

~~~systemverilog
svt_pcie_dl_service_set_link_en_sequence
svt_pcie_pl_service_set_phy_en_sequence
~~~

Randomize `enable=1` and `phy_enable=1` and start them on `dl_seqr` and `pl_seqr`. Primary and peer environments release their matching reset bits only after both CFG stages pass.

The checked wait is owned by the peer test's paired-link orchestrator, not by
either environment independently. It enables both sides, checks both status
objects, updates only the primary environment's `link_state`, and emits exactly
one `PCIE_SVT_LINK_PASS` record per physical link. It requires on both sides:

~~~systemverilog
pl.link_up == 1'b1 &&
dl.dl_link_up == 1'b1 &&
pl.ltssm_state == svt_pcie_types::L0 &&
pl.current_speed == expected_speed &&
pl.negotiated_link_width == descriptor.link_width
~~~

Use `descriptor.link_timeout` and include link ID, role, PL/DL up, LTSSM, observed/expected speed, and observed/expected width in a timeout fatal. Mark LINK PASS only after a final recheck.

- [ ] **Step 5: Run the six-profile/generation link matrix**

Compile with `PCIE_USE_SVT_PEER` and run Gen4 and Gen5 for all three profiles. Expected link-pass counts are 1, 2, and 5. Switch ENUM and TRAFFIC remain NOT_RUN.

Also run x16 Gen4 fast and x16 Gen5 fast. Confirm final speed/width and confirm log-period evidence omits the intermediate rates already documented for the supported fast path.

- [ ] **Step 6: Commit**

~~~bash
git add svt_pcie_integration/uvm/sequences/pcie_svt_link_vseq.sv \
  svt_pcie_integration/uvm/tests/pcie_svt_peer_test.sv \
  svt_pcie_integration/rtl/pcie_svt_peer_harness.sv \
  svt_pcie_integration/rtl/pcie_svt_topology_env_top.sv \
  svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv \
  svt_pcie_integration/sim/pcie_svt_topology.f
git commit -m "feat(pcie-svt): train topology links with peer envs"
~~~

---

### Task 8: Independent Direct-Endpoint Enumeration

**Files:**
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_registry.sv`
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_vseq.sv`
- Create: `svt_pcie_integration/uvm/tests/pcie_svt_enumeration_registry_unit_test.sv`
- Modify: `svt_pcie_integration/uvm/tests/pcie_svt_peer_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt_topology.f`

- [ ] **Step 1: Write a failing registry test**

Define the records with these public fields:

~~~systemverilog
class pcie_svt_bar_range extends uvm_object;
  int unsigned low_bar;
  int unsigned high_bar;
  bit is_64bit;
  bit prefetchable;
  bit [63:0] base_address;
  bit [63:0] limit_address;
  bit [63:0] aperture;
endclass

class pcie_svt_endpoint_record extends uvm_object;
  string link_id;
  int unsigned root_hierarchy;
  bit [15:0] bdf;
  pcie_svt_bar_range bars[3];
  function bit [63:0] bar_base(int unsigned pair);
    return bars[pair].base_address;
  endfunction
endclass

class pcie_svt_bridge_record extends uvm_object;
  bit is_usp;
  int unsigned index;
  bit [15:0] bdf;
  bit [7:0] primary_bus, secondary_bus, subordinate_bus;
  bit [63:0] prefetch_base, prefetch_limit;
endclass
~~~

The registry must reject duplicate link IDs, duplicate BDFs within one
hierarchy, an upper BAR without a 64-bit low BAR, zero/overlapping apertures,
and use before `finalize()`.

The positive test records:

~~~systemverilog
registry.record_direct_endpoint(
  "RC0_EP0", 0, 16'h0100, status0);
registry.record_direct_endpoint(
  "RC1_EP1", 1, 16'h0100, status1);
registry.finalize(errors);
require(errors.size() == 0, "two independent hierarchies rejected");
require(registry.endpoint_count() == 2, "endpoint count mismatch");
require(registry.find_endpoint("RC1_EP1").root_hierarchy == 1,
        "link lookup returned wrong hierarchy");
~~~

The same BDF is legal across the two independent hierarchies.

- [ ] **Step 2: Prove the test is red**

Expected compile failure names `pcie_svt_enumeration_registry`.

- [ ] **Step 3: Implement direct enumeration with the official sequence**

For each primary RC descriptor in a topology without a Switch node, first set
`rc_seqr = p_sequencer.require_port_seqr(descriptor.link_id)`, then create:

~~~systemverilog
svt_pcie_device_virtual_ep_enumeration_sequence enum_seq;
enum_seq =
  svt_pcie_device_virtual_ep_enumeration_sequence::type_id::create(
    {descriptor.link_id, "_enum"});
if (!enum_seq.randomize() with {
      device_parms.root_hierarchy == descriptor.root_hierarchy;
      device_parms.bus_number == 8'h01;
      device_parms.device_number == 5'h00;
      device_parms.max_num_functions_supported == 1;
      device_parms.enable_sriov == 1'b0;
      device_parms.enable_vf_memory_space == 1'b0;
      device_parms.get_atomic_op_cap == 1'b0;
      device_parms.enable_atomic_op_as_requester_support == 1'b0;
      device_parms.find_all_base_capabilities == 1'b0;
      device_parms.find_all_extended_capabilities == 1'b0;
      device_parms.enable_incremental_bar_allocation == 1'b1;
      device_parms.min_pref_mem_base_addr ==
        (64'h0000_0001_0000_0000 +
         (64'h0000_0000_1000_0000 * descriptor.root_hierarchy));
      device_parms.max_pref_mem_base_addr ==
        (64'h0000_0001_0fff_ffff +
         (64'h0000_0000_1000_0000 * descriptor.root_hierarchy));
    })
  `uvm_fatal("SVT_ENUM", {descriptor.link_id,
                          ": EP enumeration randomization failed"})
enum_seq.start(rc_seqr);
~~~

The peer Endpoint is a VIP, so set `device_parms.is_ep_device_vip=1` in peer
tests; the real-DUT test overrides it to zero. Require L0, DL_Up, and VC0
initialized before start. Store `enum_seq.ep_enumeration_status` in the
registry, verify PF0 exposes exactly BAR0/1, BAR2/3, and BAR4/5 as 64-bit
Prefetchable Memory BARs by checking both status type and configuration
readback bit 3, and verify apertures 32 MiB/64 KiB/64 KiB from status ranges.

- [ ] **Step 4: Run x16 and 2x8 enumeration**

Run Gen4 and Gen5 `+PCIE_ENUM_ONLY` peer tests. Expected:

- x16: one official EP enumeration, one validated registry entry;
- 2x8: two official sequences run in parallel, two independent registries/hierarchies;
- all Endpoint Command registers retain Memory Space and Bus Master enable;
- final warning/error/fatal counts are zero.

Do not run the Switch profile through this direct enumeration path.

- [ ] **Step 5: Commit**

~~~bash
git add svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_registry.sv \
  svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_vseq.sv \
  svt_pcie_integration/uvm/tests/pcie_svt_enumeration_registry_unit_test.sv \
  svt_pcie_integration/uvm/tests/pcie_svt_peer_test.sv \
  svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv \
  svt_pcie_integration/sim/pcie_svt_topology.f
git commit -m "feat(pcie-svt): enumerate independent endpoint links"
~~~

---

### Task 9: Direct RC-to-Endpoint Memory Traffic

**Files:**
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_memory_traffic_vseq.sv`
- Create: `svt_pcie_integration/uvm/tests/pcie_svt_memory_traffic_directed_test.sv`
- Modify: `svt_pcie_integration/uvm/tests/pcie_svt_peer_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt_topology.f`

- [ ] **Step 1: Write a failing transaction construction test**

Factory-override the Driver App transaction and verify one flow creates a blocking four-DWORD Memory Write followed by a blocking four-DWORD Memory Read with:

~~~systemverilog
transaction_type = svt_pcie_driver_app_transaction::MEM_WR;
address = endpoint.bar_base(0) + 64'h100;
length = 4;
first_dw_be = 4'hf;
last_dw_be = 4'hf;
requester_id = 16'h0000;
ep = 0;
block = 1;
payload[0] = 32'h5356_5400 ^ flow_index;
payload[1] = 32'h5043_4945 ^ flow_index;
payload[2] = 32'h544f_504f ^ flow_index;
payload[3] = 32'h4c4f_4759 ^ flow_index;
~~~

The read response must have `SUCCESSFUL` completion, exactly four DWORDs, and identical payload. Test unsuccessful Completion, wrong length, wrong data, and watchdog expiry as failures carrying the link ID and address.

- [ ] **Step 2: Prove the traffic test is red**

Expected failure names `pcie_svt_memory_traffic_vseq`.

- [ ] **Step 3: Implement one flow per enumerated Endpoint**

Resolve the RC's `driver_transaction_seqr[0]` by the endpoint record's link ID. Use the record's enumerated BAR0 base, not a hard-coded address. Start direct-link flows in parallel, bounded by each descriptor's `traffic_timeout`. After all flows complete, run `svt_pcie_driver_app_service_wait_until_idle_sequence` on each RC Driver App and `svt_pcie_target_app_service_wait_until_idle_sequence` on each peer Endpoint Target App.

Mark TRAFFIC PASS only after Completion/data and idle checks. Leave the reverse Endpoint-to-RC host-memory handles exposed in the virtual sequencer but do not generate reverse traffic in this task.

- [ ] **Step 4: Run direct profile traffic**

Run `+PCIE_TRAFFIC` for x16 and 2x8 at Gen4 and Gen5. The stage sequence must perform CFG, LINK, ENUM, then TRAFFIC. Expected flow counts are one and two; all stage states PASS and final counts 0/0/0.

- [ ] **Step 5: Commit**

~~~bash
git add svt_pcie_integration/uvm/sequences/pcie_svt_memory_traffic_vseq.sv \
  svt_pcie_integration/uvm/tests/pcie_svt_memory_traffic_directed_test.sv \
  svt_pcie_integration/uvm/tests/pcie_svt_peer_test.sv \
  svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv \
  svt_pcie_integration/sim/pcie_svt_topology.f
git commit -m "feat(pcie-svt): verify direct endpoint memory traffic"
~~~

---

### Task 10: Real-Switch Enumeration, Windows, and Traffic Entry

**Files:**
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_stage_vseq.sv`
- Create: `svt_pcie_integration/uvm/tests/pcie_svt_real_dut_test.sv`
- Create: `svt_pcie_integration/sim/pcie_real_dut_adapter_compile_stub.sv`
- Modify: `svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_registry.sv`
- Modify: `svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_vseq.sv`
- Modify: `svt_pcie_integration/uvm/sequences/pcie_svt_memory_traffic_vseq.sv`
- Modify: `svt_pcie_integration/rtl/pcie_svt_dut_wrapper.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt_topology.f`

- [ ] **Step 1: Write failing Switch registry and stage-order tests**

The Switch registry unit test constructs one `pcie_svt_bridge_record` for the
USP, four for the DSPs, four `pcie_svt_endpoint_record` objects, and twelve
`pcie_svt_bar_range` objects directly, then calls
`registry.load_switch_records(usp, dsps, endpoints, errors)`. It checks exactly
one USP, four DSPs, four Endpoints, twelve BAR pairs, unique BDFs, bridge bus
ranges, and Prefetchable windows covering every downstream BAR. Separate
copies remove one DSP, duplicate one BDF, reverse one bus range, shrink one DSP
window, and shrink the USP window; each must return its specific error and no
UVM report. The production `load_switch_status` method translates
`svt_pcie_switch_enumeration_seq_status` into the same record API before it
calls `finalize`.

The stage-order test factory-overrides child sequences and requires:

~~~text
COMPILE: no runtime child stage
CFG:     cfg
LINK:    cfg -> link
ENUM:    cfg -> link -> enum
TRAFFIC: cfg -> link -> enum -> traffic
~~~

No later child starts after a failed earlier stage.

- [ ] **Step 2: Prove tests are red**

Expected failures name missing Switch load support and `pcie_svt_stage_vseq`.

- [ ] **Step 3: Wrap the official Switch enumeration sequence**

For a topology containing `SW0`, resolve the one RC descriptor on `SW0.USP[0]` and create `svt_pcie_device_virtual_switch_enumeration_sequence`. Use the proven controls:

~~~systemverilog
if (!enum_seq.randomize() with {
      switch_parms.root_hierarchy == 0;
      switch_parms.enumerate_device_beneath_dsp == 1'b1;
      switch_parms.max_sw_dsp_device_number == 3;
      switch_parms.root_port_sec_bus_num == 8'h01;
      switch_parms.sw_usp_dev_num == 5'h00;
      switch_parms.sys_pref_mem_base_addr ==
        64'h0000_0001_0000_0000;
      switch_parms.sys_pref_mem_limit_addr ==
        64'h0000_0001_7fff_ffff;
    })
  `uvm_fatal("SVT_SWITCH_ENUM", "controls failed to randomize")
enum_seq.start(rc_seqr);
~~~

Load its status into the topology registry. Read back each bridge bus-number and Prefetchable-window register plus all Endpoint BAR DWORDs by using the official sequence's configuration read helper. Enable and verify Memory Space/Bus Master on USP, DSPs, and Endpoints.

- [ ] **Step 4: Make Switch traffic topology-driven**

Build four RC-to-Endpoint flows from the four registry Endpoint records. Every flow starts on the upstream RC Driver App, targets BAR0+`0x100` on one downstream Endpoint, and uses the Task 9 Completion/data checks. A PASS therefore requires the real DUT to forward USP-to-DSP and the Completion back DSP-to-USP.

- [ ] **Step 5: Define a typed real-DUT adapter contract**

`pcie_svt_dut_wrapper` instantiates `pcie_real_dut_adapter` only under `PCIE_USE_REAL_DUT`. For the Switch macro the compile stub exposes:

~~~systemverilog
module pcie_real_dut_adapter (
  input logic [4:0] reset_asserted,
  input logic [15:0] usp_rx_p, usp_rx_n,
  output logic [15:0] usp_tx_p, usp_tx_n,
  input logic [3:0] dsp0_rx_p, dsp0_rx_n,
  output logic [3:0] dsp0_tx_p, dsp0_tx_n,
  input logic [3:0] dsp1_rx_p, dsp1_rx_n,
  output logic [3:0] dsp1_tx_p, dsp1_tx_n,
  input logic [3:0] dsp2_rx_p, dsp2_rx_n,
  output logic [3:0] dsp2_tx_p, dsp2_tx_n,
  input logic [3:0] dsp3_rx_p, dsp3_rx_n,
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
~~~

Under `PCIE_TOPO_EP_X16` use this direct signature:

~~~systemverilog
module pcie_real_dut_adapter (
  input logic reset_asserted,
  input logic [15:0] ep0_rx_p, ep0_rx_n,
  output logic [15:0] ep0_tx_p, ep0_tx_n
);
  assign ep0_tx_p = '0;
  assign ep0_tx_n = '1;
endmodule
~~~

Under `PCIE_TOPO_EP_2X8` use:

~~~systemverilog
module pcie_real_dut_adapter (
  input logic [1:0] reset_asserted,
  input logic [7:0] ep0_rx_p, ep0_rx_n,
  output logic [7:0] ep0_tx_p, ep0_tx_n,
  input logic [7:0] ep1_rx_p, ep1_rx_n,
  output logic [7:0] ep1_tx_p, ep1_tx_n
);
  assign ep0_tx_p = '0;
  assign ep0_tx_n = '1;
  assign ep1_tx_p = '0;
  assign ep1_tx_n = '1;
endmodule
~~~

The stub is compile-only, emits exactly one `PCIE_SVT_DUT_STUB` marker at time
zero, and is never accepted for LINK, ENUM, or TRAFFIC.

- [ ] **Step 6: Verify current real-Switch readiness**

Compile the Switch image with `PCIE_USE_REAL_DUT` and the stub. Run `PCIE_COMPILE_ONLY` and `PCIE_CFG_INIT_ONLY` at Gen4/Gen5; both must pass. A `PCIE_LINK_ONLY` run against the stub must fail with the link watchdog and must not report LINK PASS.

Compile ENUM and TRAFFIC sequence code in the same image. Do not claim those stages pass until a functional real Switch adapter replaces the stub.

- [ ] **Step 7: Commit**

~~~bash
git add svt_pcie_integration/uvm/sequences \
  svt_pcie_integration/uvm/tests/pcie_svt_real_dut_test.sv \
  svt_pcie_integration/sim/pcie_real_dut_adapter_compile_stub.sv \
  svt_pcie_integration/rtl/pcie_svt_dut_wrapper.sv \
  svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv \
  svt_pcie_integration/sim/pcie_svt_topology.f
git commit -m "feat(pcie-svt): add real switch enumeration path"
~~~

---

### Task 11: Stage Reporting, Exact Log Gates, and Full New-Path Matrix

**Files:**
- Create: `svt_pcie_integration/sim/check_pcie_svt_topology_log.sh`
- Create: `svt_pcie_integration/sim/check_pcie_svt_topology_log_unit_test.sh`
- Modify: `svt_pcie_integration/uvm/env/pcie_svt_topology_virtual_sequencer.sv`
- Modify: `svt_pcie_integration/uvm/tests/pcie_svt_topology_base_test.sv`
- Modify: `svt_pcie_integration/uvm/tests/pcie_svt_peer_test.sv`
- Modify: `svt_pcie_integration/uvm/tests/pcie_svt_real_dut_test.sv`

- [ ] **Step 1: Write failing shell log-gate tests**

Generate fixture logs for:

- correct 1/2/5 agent counts;
- correct Switch peer `CFG=PASS LINK=PASS ENUM=NOT_RUN TRAFFIC=NOT_RUN`;
- false PASS with missing normal UVM summary;
- duplicate PASS marker;
- one unexpected warning;
- a Switch peer that incorrectly reports ENUM PASS;
- a placeholder real-DUT run that incorrectly reports LINK PASS.

Run `check_pcie_svt_topology_log_unit_test.sh` and expect failures because the checker does not exist.

- [ ] **Step 2: Implement a strict checker**

The checker accepts `connection profile stage log`, where connection is `peer`
or `real`. It requires exactly one normal completion marker, exactly one final
zero summary each for warning/error/fatal, exact agent/link/BAR/stage counts for
that profile/stage, and rejects markers from any later stage. A real log that
contains `PCIE_SVT_DUT_STUB` is accepted only for COMPILE or CFG.

Implement these shell primitives and profile counts:

~~~bash
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 peer|real PROFILE compile|cfg|link|enum|traffic LOG" >&2
  exit 2
fi
connection=$1
profile=$2
stage=$3
log=$4
[[ -r "$log" ]] || { echo "unreadable log: $log" >&2; exit 2; }

count_matches() {
  grep -Ec "$1" "$log" || true
}
require_count() {
  local pattern=$1 expected=$2 label=$3 actual
  actual=$(count_matches "$pattern")
  [[ "$actual" -eq "$expected" ]] || {
    echo "$label count=$actual expected=$expected" >&2
    exit 1
  }
}

case "$profile" in
  EP_X16) ports=1; peer_bar_checks=6 ;;
  EP_2X8) ports=2; peer_bar_checks=12 ;;
  SWITCH_1X16_4X4) ports=5; peer_bar_checks=24 ;;
  *) echo "unknown profile: $profile" >&2; exit 2 ;;
esac

require_count "\\[PCIE_SVT_ENV_READY\\].*profile=$profile agents=$ports" \
  1 "environment ready"
require_count '\[PCIE_SVT_TEST_PASS\]' 1 "final pass"
require_count 'UVM_WARNING[[:space:]]*:[[:space:]]*0$' 1 "warning summary"
require_count 'UVM_ERROR[[:space:]]*:[[:space:]]*0$' 1 "error summary"
require_count 'UVM_FATAL[[:space:]]*:[[:space:]]*0$' 1 "fatal summary"
require_count '\[PCIE_SVT_STAGE\]' "$ports" "stage table"

if [[ "$connection" == real ]] &&
   [[ "$(count_matches '\[PCIE_SVT_DUT_STUB\]')" -ne 0 ]] &&
   [[ "$stage" != compile && "$stage" != cfg ]]; then
  echo "real-DUT stub cannot pass stage=$stage" >&2
  exit 1
fi

bar_checks=0
if [[ "$stage" != compile ]]; then
  if [[ "$connection" == peer ]]; then
    bar_checks=$peer_bar_checks
  elif [[ "$profile" == SWITCH_1X16_4X4 ]]; then
    bar_checks=24
  fi
fi
require_count '\[PCIE_SVT_BAR_CHECK\]' "$bar_checks" "BAR check"

case "$stage" in
  compile)
    require_count 'CFG=NOT_RUN LINK=NOT_RUN ENUM=NOT_RUN TRAFFIC=NOT_RUN' \
      "$ports" "compile stage state"
    require_count '\[PCIE_SVT_LINK_PASS\]' 0 "early link pass"
    ;;
  cfg)
    require_count 'CFG=PASS LINK=NOT_RUN ENUM=NOT_RUN TRAFFIC=NOT_RUN' \
      "$ports" "cfg stage state"
    require_count '\[PCIE_SVT_LINK_PASS\]' 0 "early link pass"
    ;;
  link)
    require_count 'CFG=PASS LINK=PASS ENUM=NOT_RUN TRAFFIC=NOT_RUN' \
      "$ports" "link stage state"
    require_count '\[PCIE_SVT_LINK_PASS\]' "$ports" "link pass"
    ;;
  enum)
    require_count 'CFG=PASS LINK=PASS ENUM=PASS TRAFFIC=NOT_RUN' \
      "$ports" "enum stage state"
    require_count '\[PCIE_SVT_LINK_PASS\]' "$ports" "link pass"
    [[ "$profile" != SWITCH_1X16_4X4 || "$connection" == real ]] || exit 1
    ;;
  traffic)
    require_count 'CFG=PASS LINK=PASS ENUM=PASS TRAFFIC=PASS' \
      "$ports" "traffic stage state"
    require_count '\[PCIE_SVT_LINK_PASS\]' "$ports" "link pass"
    [[ "$profile" != SWITCH_1X16_4X4 || "$connection" == real ]] || exit 1
    ;;
  *) echo "unknown stage: $stage" >&2; exit 2 ;;
esac
~~~

For Switch peer LINK, require five LINK PASS rows and five ENUM/TRAFFIC NOT_RUN rows. For Switch real-DUT CFG, require 24 BAR checks and five CFG PASS rows. No checker mode interprets a READY message by itself as PASS.

Only the primary environment calls `report_stage_table()` and emits
`PCIE_SVT_ENV_READY`; the peer environment is identified in diagnostic records
but never contributes duplicate stage rows. The paired-link orchestrator emits
one LINK PASS marker per physical link after both primary and peer sides pass.

- [ ] **Step 3: Add final UVM report behavior**

Add a `stage_table_reported` guard and a shared
`report_stage_table_once()` helper. Call it from both the test's `pre_abort()`
and `report_phase()`, so a watchdog fatal still prints the primary links'
last known states while a normal run prints exactly one table. Topology-owned
parallel workers record per-link PASS/FAIL and an error string, wait for all
siblings, print the complete table, and only then raise one aggregate fatal;
an unavoidable fatal raised inside vendor code still uses the `pre_abort`
fallback.

In report phase, emit `PCIE_SVT_TEST_PASS` only when:

~~~systemverilog
server.get_severity_count(UVM_WARNING) == 0 &&
server.get_severity_count(UVM_ERROR) == 0 &&
server.get_severity_count(UVM_FATAL) == 0 &&
all_required_stage_states_match_selected_mode()
~~~

Peer Switch ENUM/TRAFFIC states remain NOT_RUN even after LINK succeeds. Direct profile stages become PASS through the requested stage. Real-DUT stages beyond the requested stage remain NOT_RUN.

- [ ] **Step 4: Run the complete accepted matrix**

On `10.11.10.53` run and gate:

| Topology | Gen | Connection | Accepted stages |
| --- | ---: | --- | --- |
| EP_X16 | 4, 5 | peer | COMPILE, CFG, LINK, ENUM, TRAFFIC |
| EP_2X8 | 4, 5 | peer | COMPILE, CFG, LINK, ENUM, TRAFFIC |
| SWITCH_1X16_4X4 | 4, 5 | peer | COMPILE, CFG, LINK |
| SWITCH_1X16_4X4 | 4, 5 | real-DUT stub | COMPILE, CFG |

Run Gen4 fast and Gen5 fast for x16, plus one Switch peer fast run at each generation. Each accepted log must pass the checker.

- [ ] **Step 5: Run negative macro/CLI builds**

Verify compilation fails for zero or multiple topology macros and for `PCIE_USE_REAL_DUT` combined with `PCIE_USE_SVT_PEER`. Verify runtime fatal for profile/macro mismatch, duplicate Gen, Gen3, PIPE selection, and an x16 width override on a compiled x8 link.

- [ ] **Step 6: Commit**

~~~bash
git add svt_pcie_integration/sim/check_pcie_svt_topology_log.sh \
  svt_pcie_integration/sim/check_pcie_svt_topology_log_unit_test.sh \
  svt_pcie_integration/uvm/env/pcie_svt_topology_virtual_sequencer.sv \
  svt_pcie_integration/uvm/tests
git commit -m "test(pcie-svt): gate topology stages and matrix"
~~~

---

### Task 12: Cut Over, Delete Legacy Integration, Document, and Regress

**Files:**
- Rename: `svt_pcie_integration/rtl/pcie_svt_topology_env_top.sv` to `svt_pcie_integration/rtl/pcie_svt_topology_top.sv`
- Rename: `svt_pcie_integration/sim/pcie_svt_topology.f` to `svt_pcie_integration/sim/pcie_svt.f`
- Rewrite: `svt_pcie_integration/sim/README.md`
- Modify: `pcie_tl_vip/docs/PCIe_TL_VIP_Integration_Guide.md`
- Delete: legacy files listed after the reference audit below

- [ ] **Step 1: Capture a read-only legacy dependency manifest**

Run:

~~~bash
rg -n "pcie_svt_(env|port_env|profile|profile_set|virtual_sequencer)|\
PCIE_SVT_MAX_PORTS|PCIE_SVT_PRIMARY_|PCIE_SVT_PEER_|\
PCIE_USE_SVT_SWITCH_PROXY|sidecar|pcie_tl_switch|pcie_svt_tlp_converter|\
pcie_svt_ep_bar_sizing_callback" \
  svt_pcie_integration pcie_tl_vip/docs \
  > /tmp/pcie_svt_legacy_refs.before
~~~

Classify every hit as new-path documentation to rewrite or a legacy source/test to delete. Confirm `pcie_svt_cfg_space_builder` and all retained Serial/reset files are the new focused versions, not the old fixed-profile versions.

- [ ] **Step 2: Switch the production package, top, and file list**

Rename the new top/filelist to the production names. The final file list compiles:

1. vendor bootstrap and Serial/reset interfaces;
2. common `pcie_topology_pkg`;
3. new `pcie_svt_topology_pkg`;
4. new test classes;
5. DUT wrapper and production top.

It does not compile `pcie_tl_switch_pkg` or `pcie_svt_integration_pkg`.

- [ ] **Step 3: Delete the old fixed/proxy path**

Delete these exact old files after the new production file list passes COMPILE and CFG:

~~~text
svt_pcie_integration/rtl/pcie_svt_passive_sidecar_tap.sv
svt_pcie_integration/rtl/pcie_switch_dut_wrapper.sv
svt_pcie_integration/uvm/pcie_svt_integration_pkg.sv
svt_pcie_integration/uvm/pcie_svt_profile.sv
svt_pcie_integration/uvm/pcie_svt_profile_set.sv
svt_pcie_integration/uvm/pcie_svt_profile_unit_test.sv
svt_pcie_integration/uvm/pcie_svt_cfg_space_builder.sv
svt_pcie_integration/uvm/pcie_svt_port_env.sv
svt_pcie_integration/uvm/pcie_svt_env.sv
svt_pcie_integration/uvm/pcie_svt_virtual_sequencer.sv
svt_pcie_integration/uvm/pcie_svt_ep_bar_sizing_callback.sv
svt_pcie_integration/uvm/pcie_svt_switch_scoreboard.sv
svt_pcie_integration/uvm/pcie_svt_switch_port_adapter.sv
svt_pcie_integration/uvm/pcie_svt_switch_sidecar_env.sv
svt_pcie_integration/uvm/pcie_svt_switch_sidecar_subscriber.sv
svt_pcie_integration/uvm/pcie_svt_switch_target_callback.sv
svt_pcie_integration/uvm/pcie_svt_tlp_converter.sv
svt_pcie_integration/uvm/pcie_svt_switch_enum_registry.sv
svt_pcie_integration/uvm/pcie_svt_real_switch_link_gate.sv
svt_pcie_integration/uvm/pcie_svt_real_switch_traffic_plan.sv
svt_pcie_integration/uvm/pcie_svt_switch_proxy_test.sv
svt_pcie_integration/uvm/pcie_svt_real_switch_test.sv
svt_pcie_integration/uvm/pcie_svt_base_test.sv
svt_pcie_integration/uvm/sequences/pcie_svt_raw_tlp_sequence.sv
svt_pcie_integration/uvm/sequences/pcie_svt_switch_enumeration_base_vseq.sv
svt_pcie_integration/uvm/sequences/pcie_svt_switch_enumeration_vseq.sv
svt_pcie_integration/uvm/sequences/pcie_svt_real_switch_enumeration_vseq.sv
svt_pcie_integration/uvm/sequences/pcie_svt_real_switch_links_vseq.sv
svt_pcie_integration/uvm/sequences/pcie_svt_real_switch_traffic_vseq.sv
svt_pcie_integration/uvm/sequences/pcie_svt_rc_host_memory_init_vseq.sv
svt_pcie_integration/uvm/sequences/pcie_svt_mem_write_read_seq.sv
svt_pcie_integration/uvm/sequences/pcie_svt_cfg_space_init_seq.sv
svt_pcie_integration/uvm/sequences/pcie_svt_all_cfg_spaces_init_vseq.sv
svt_pcie_integration/uvm/sequences/pcie_svt_link_bringup_seq.sv
svt_pcie_integration/uvm/sequences/pcie_svt_all_links_bringup_vseq.sv
svt_pcie_integration/uvm/sequences/pcie_svt_peer_smoke_vseq.sv
svt_pcie_integration/sim/pcie_svt_ep_bar_sizing_callback_unit_test.sv
svt_pcie_integration/sim/pcie_svt_real_switch_contract_unit_test.sv
svt_pcie_integration/sim/pcie_svt_real_switch_sequences_unit_test.sv
svt_pcie_integration/sim/pcie_svt_switch_adapter_unit_test.sv
svt_pcie_integration/sim/pcie_svt_switch_enum_registry_unit_test.sv
svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.f
svt_pcie_integration/sim/pcie_svt_tl_proxy_probe.sv
svt_pcie_integration/sim/pcie_svt_tlp_converter_unit_test.sv
svt_pcie_integration/sim/pcie_svt_watchdog_directed_test.sv
svt_pcie_integration/sim/pcie_tl_switch_proxy_unit_test.sv
svt_pcie_integration/sim/pcie_tl_switch_unit.f
svt_pcie_integration/sim/check_tl_proxy_passive_sidecar_log.sh
svt_pcie_integration/sim/check_real_switch_log.sh
svt_pcie_integration/sim/check_real_switch_log_unit_test.sh
~~~

Also delete the old root-level
`svt_pcie_integration/uvm/pcie_svt_cfg_space_builder.sv`; its focused
replacement is `uvm/cfg/pcie_svt_cfg_space_builder.sv`. Delete
`pcie_dut_placeholder.sv` and the old
`pcie_real_switch_dut_adapter_compile_stub.sv` only after confirming the new
`pcie_svt_dut_wrapper.sv` and generic compile stub replace all three profile
contracts. Because the production top and file-list names already exist,
remove the audited legacy versions immediately before the two `git mv`
operations; never overwrite an unreviewed file.

- [ ] **Step 4: Prove no legacy dependency remains**

Run the Task 12 `rg` again. Expected: no source/filelist hit for Proxy, sidecar, fixed slot constants, old package/classes, old callback, or TLP converter. Descriptive migration history in committed design/plan documents may remain.

Run:

~~~bash
git diff --check
git status --short
~~~

Expected: only intended source/doc changes plus the user's unrelated untracked `motd.legal-displayed`.

- [ ] **Step 5: Rewrite usage documentation**

Document:

- exact R-2020.12 installation dependency and official base-example path;
- the three compile macros and matching `PCIE_TOPOLOGY` values;
- Gen4/Gen5, fast mode, per-link override syntax, and five strict stage modes;
- primary versus peer agent counts;
- BAR0/1 32 MiB, BAR2/3 and BAR4/5 64 KiB, all 64-bit Prefetchable;
- the real-DUT Serial port/reset contract;
- Switch peer LINK-only limitation and ENUM/TRAFFIC NOT_RUN meaning;
- the real Switch enumeration/traffic acceptance criteria;
- Serial-first status and explicit PIPE-not-implemented fatal.

Change the TL integration guide's “SVT topology environment not implemented” statement to point to `pcie_svt_topology_env` and retain the warning that TL-backend results do not prove Serial training.

- [ ] **Step 6: Rerun the full SVT matrix after deletion**

Re-stage from the cleaned tree, rebuild all three macros from scratch, and repeat the entire Task 11 accepted matrix. No result from a pre-deletion simulator image counts.

- [ ] **Step 7: Run the public TL backend regression**

On `10.11.10.53` rebuild `pcie_tl_vip/sim/filelist.f` and run at least:

~~~text
pcie_topology_model_unit_test
pcie_topology_builder_unit_test
pcie_topology_validation_unit_test
pcie_tl_topology_adapter_unit_test
pcie_tl_custom_ep_x16_test
pcie_tl_custom_ep_2x8_test
pcie_tl_custom_switch_1x16_4x4_test
pcie_tl_custom_programmatic_test
pcie_tl_switch_basic_test
pcie_tl_multi_root_stress_test
~~~

Expected for every run: final `UVM_ERROR : 0` and `UVM_FATAL : 0`.

- [ ] **Step 8: Commit the cutover**

~~~bash
git add -A svt_pcie_integration \
  pcie_tl_vip/docs/PCIe_TL_VIP_Integration_Guide.md
git commit -m "refactor(pcie-svt): replace legacy integration with topology env"
~~~

- [ ] **Step 9: Final evidence check**

~~~bash
git diff HEAD^ --check
git status --short --branch
git log -12 --oneline
~~~

Expected: clean tracked worktree, `motd.legal-displayed` still untracked and untouched, new SVT/TL logs all gated, and no real-Switch ENUM/TRAFFIC PASS claim without a functional DUT.
