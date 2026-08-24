# PCIe TL Configurable Topology Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a vendor-neutral PCIe topology model and a thin `pcie_tl_custom_env` backend that selects and functionally verifies `EP_X16`, `EP_2X8`, and `SWITCH_1X16_4X4` without changing the existing `pcie_tl_env` API.

**Architecture:** A common node/link graph is built either from a named profile or programmatically, validated as one complete object, and translated into the existing `pcie_tl_env_config` and `pcie_tl_switch_config`. The derived environment performs only that pre-build translation and then delegates all agents, switch routing, scoreboarding, sequencers, and TLM traffic to `pcie_tl_env`; the later SVT backend will consume the same graph in a separate change.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys VCS W-2024.09-SP1 on `10.11.10.53`, `host_mem` `master@3b9e000d5df4d10efbb3029f43605e0362e0caca`

**Spec:** `docs/superpowers/specs/2026-08-24-pcie-tl-topology-env-design.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `pcie_tl_vip/src/topology/pcie_topology_pkg.sv` | Create | Standalone vendor-neutral package consumable by TL and later SVT backends |
| `pcie_tl_vip/src/topology/pcie_topology_types.sv` | Create | Node/port enums plus deep-copyable node and link records |
| `pcie_tl_vip/src/topology/pcie_topology_cfg.sv` | Create | Topology container, lookup helpers, deep copy, complete phase-one validation |
| `pcie_tl_vip/src/topology/pcie_topology_builder.sv` | Create | Programmatic graph construction and three deterministic named profiles |
| `pcie_tl_vip/src/adapter/pcie_tl_topology_adapter.sv` | Create | Validated common-graph to native TL configuration translation and reverse audit |
| `pcie_tl_vip/src/env/pcie_tl_custom_env.sv` | Create | Thin derived environment that validates/translates before base-env agent creation |
| `pcie_tl_vip/src/pcie_tl_pkg.sv` | Modify | Import the common package and include the TL adapter/custom env in dependency order |
| `pcie_tl_vip/tests/pcie_topology_model_unit_test.sv` | Create | Deep-copy and clone isolation tests |
| `pcie_tl_vip/tests/pcie_topology_builder_unit_test.sv` | Create | Exact named-profile and programmatic-builder tests |
| `pcie_tl_vip/tests/pcie_topology_validation_unit_test.sv` | Create | Positive and focused negative validation tests |
| `pcie_tl_vip/tests/pcie_tl_topology_adapter_unit_test.sv` | Create | Direct, Switch, multi-USP, and corrupted-audit tests |
| `pcie_tl_vip/tests/pcie_tl_custom_base_test.sv` | Create | Strict command-line parser, policy hook, and custom-env creation |
| `pcie_tl_vip/tests/pcie_tl_custom_profile_test.sv` | Create | Three profile traffic tests plus a programmatic one-DSP/one-EP test |
| `pcie_tl_vip/sim/filelist.f` | Modify | Compile new tests; retain the current file order and legacy tests |
| `pcie_tl_vip/docs/PCIe_TL_VIP_User_Guide.md` | Modify | Public profile, plusarg, programmatic API, and TL-only semantics |
| `pcie_tl_vip/docs/PCIe_TL_VIP_Integration_Guide.md` | Modify | Derived-env integration and future SVT backend boundary |

No file under `svt_pcie_integration/` is modified in this phase.

## Remote VCS Test Recipe

Every compile/run step below uses the same staging directory and the approved simulation host. Set the password only in the executing shell; do not write it into a URL, file, or Git configuration.

```bash
read -s VCS_HOST_PASSWORD
export SSHPASS="$VCS_HOST_PASSWORD"
export PCIE_REMOTE_ROOT=/home/ubuntu/workspace/pcie_topology_env
export RSYNC_RSH="sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
rsync -az --exclude=.git --exclude=simv --exclude='*.daidir' \
  ./ ubuntu@10.11.10.53:${PCIE_REMOTE_ROOT}/
sshpass -e ssh ubuntu@10.11.10.53 \
  "test \"\$(git -C /home/ubuntu/workspace/host_mem rev-parse HEAD)\" = \
  3b9e000d5df4d10efbb3029f43605e0362e0caca"
sshpass -e ssh ubuntu@10.11.10.53 "sed \
  -e 's#/home/ryan/shm_work/host_mem#/home/ubuntu/workspace/host_mem#g' \
  -e 's#/home/ryan/pcie_work#/home/ubuntu/workspace/pcie_topology_env#g' \
  ${PCIE_REMOTE_ROOT}/pcie_tl_vip/sim/filelist.f \
  > ${PCIE_REMOTE_ROOT}/pcie_tl_vip/sim/filelist.remote.f"
sshpass -e ssh ubuntu@10.11.10.53 "bash -lic 'cd \
  /home/ubuntu/workspace/pcie_topology_env/pcie_tl_vip/sim && \
  vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps \
      -f filelist.remote.f -o simv -l compile.log'"
```

Expected successful compile evidence:

```bash
sshpass -e ssh ubuntu@10.11.10.53 "test -x \
  /home/ubuntu/workspace/pcie_topology_env/pcie_tl_vip/sim/simv && \
  ! grep -q 'Error-' \
  /home/ubuntu/workspace/pcie_topology_env/pcie_tl_vip/sim/compile.log"
```

For every accepted run, verify the final summary rather than relying only on the process exit code:

```bash
grep -E 'UVM_(WARNING|ERROR|FATAL) :' run_*.log | tail -3
```

Expected:

```text
UVM_WARNING :    0
UVM_ERROR :    0
UVM_FATAL :    0
```

---

### Task 1: Common Topology Records and Deep Copy

**Files:**
- Create: `pcie_tl_vip/src/topology/pcie_topology_types.sv`
- Create: `pcie_tl_vip/src/topology/pcie_topology_cfg.sv`
- Create: `pcie_tl_vip/src/topology/pcie_topology_pkg.sv`
- Modify: `pcie_tl_vip/src/pcie_tl_pkg.sv:7-11`
- Create: `pcie_tl_vip/tests/pcie_topology_model_unit_test.sv`
- Modify: `pcie_tl_vip/sim/filelist.f` before `pcie_tl_tb_top.sv`

- [ ] **Step 1: Add the failing clone-isolation test and compile it**

Create `pcie_tl_vip/tests/pcie_topology_model_unit_test.sv`:

```systemverilog
import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_topology_model_unit_test extends uvm_test;
  `uvm_component_utils(pcie_topology_model_unit_test)

  function new(string name = "pcie_topology_model_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void require(bit condition, string message);
    if (!condition) `uvm_error("TOPO_MODEL", message)
  endfunction

  task run_phase(uvm_phase phase);
    pcie_topology_cfg original;
    pcie_topology_cfg copied;
    pcie_topology_node_cfg rc;
    pcie_topology_node_cfg ep;
    pcie_topology_node_cfg sw;
    pcie_topology_link_cfg link;

    phase.raise_objection(this);
    original = pcie_topology_cfg::type_id::create("original");
    rc = pcie_topology_node_cfg::type_id::create("rc");
    rc.node_id = "RC0";
    rc.kind = PCIE_TOPO_NODE_RC;
    ep = pcie_topology_node_cfg::type_id::create("ep");
    ep.node_id = "EP0";
    ep.kind = PCIE_TOPO_NODE_EP;
    sw = pcie_topology_node_cfg::type_id::create("sw");
    sw.node_id = "SW0";
    sw.kind = PCIE_TOPO_NODE_SWITCH;
    sw.num_usp = 1;
    sw.num_dsp = 1;
    sw.dsp_owner_usp = new[1];
    sw.dsp_owner_usp[0] = 0;
    link = pcie_topology_link_cfg::type_id::create("link");
    link.link_id = "L0";
    link.upstream_node_id = "RC0";
    link.upstream_role = PCIE_TOPO_PORT_RC;
    link.downstream_node_id = "EP0";
    link.downstream_role = PCIE_TOPO_PORT_EP;
    link.link_width = 16;
    link.max_gen = 5;
    link.enabled = 1;
    original.nodes.push_back(rc);
    original.nodes.push_back(ep);
    original.nodes.push_back(sw);
    original.links.push_back(link);

    $cast(copied, original.clone());
    require(copied != null, "clone returned null");
    require(copied.nodes.size() == 3 && copied.links.size() == 1,
            "clone sizes differ from source");
    copied.nodes[0].node_id = "RC_CHANGED";
    copied.nodes[2].dsp_owner_usp[0] = 1;
    copied.links[0].link_width = 4;
    require(original.nodes[0].node_id == "RC0",
            "node clone aliases source");
    require(original.links[0].link_width == 16,
            "link clone aliases source");
    require(original.nodes[2].dsp_owner_usp[0] == 0,
            "Switch ownership clone aliases source");
    phase.drop_objection(this);
  endtask
endclass
```

Add the test file to `filelist.f`, run the remote compile recipe, and expect failure containing:

```text
Package scope resolution failed for 'pcie_topology_pkg'
```

- [ ] **Step 2: Implement the deep-copyable node and link records**

Create `pcie_tl_vip/src/topology/pcie_topology_types.sv`:

```systemverilog
typedef enum {
  PCIE_TOPO_NODE_RC,
  PCIE_TOPO_NODE_SWITCH,
  PCIE_TOPO_NODE_EP
} pcie_topology_node_kind_e;

typedef enum {
  PCIE_TOPO_PORT_RC,
  PCIE_TOPO_PORT_USP,
  PCIE_TOPO_PORT_DSP,
  PCIE_TOPO_PORT_EP
} pcie_topology_port_role_e;

class pcie_topology_node_cfg extends uvm_object;
  `uvm_object_utils(pcie_topology_node_cfg)
  string node_id;
  pcie_topology_node_kind_e kind;
  int unsigned num_usp = 0;
  int unsigned num_dsp = 0;
  int dsp_owner_usp[];

  function new(string name = "pcie_topology_node_cfg");
    super.new(name);
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_topology_node_cfg source;
    super.do_copy(rhs);
    if (!$cast(source, rhs))
      `uvm_fatal("TOPO_COPY", "node copy source has wrong type")
    node_id = source.node_id;
    kind = source.kind;
    num_usp = source.num_usp;
    num_dsp = source.num_dsp;
    dsp_owner_usp = new[source.dsp_owner_usp.size()];
    foreach (dsp_owner_usp[i]) dsp_owner_usp[i] = source.dsp_owner_usp[i];
  endfunction
endclass

class pcie_topology_link_cfg extends uvm_object;
  `uvm_object_utils(pcie_topology_link_cfg)
  string link_id;
  string upstream_node_id;
  pcie_topology_port_role_e upstream_role;
  int unsigned upstream_port_index = 0;
  string downstream_node_id;
  pcie_topology_port_role_e downstream_role;
  int unsigned downstream_port_index = 0;
  int unsigned link_width = 4;
  int unsigned max_gen = 4;
  bit enabled = 1;

  function new(string name = "pcie_topology_link_cfg");
    super.new(name);
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_topology_link_cfg source;
    super.do_copy(rhs);
    if (!$cast(source, rhs))
      `uvm_fatal("TOPO_COPY", "link copy source has wrong type")
    link_id = source.link_id;
    upstream_node_id = source.upstream_node_id;
    upstream_role = source.upstream_role;
    upstream_port_index = source.upstream_port_index;
    downstream_node_id = source.downstream_node_id;
    downstream_role = source.downstream_role;
    downstream_port_index = source.downstream_port_index;
    link_width = source.link_width;
    max_gen = source.max_gen;
    enabled = source.enabled;
  endfunction
endclass
```

- [ ] **Step 3: Implement the topology container and include order**

Create `pcie_tl_vip/src/topology/pcie_topology_cfg.sv`:

```systemverilog
class pcie_topology_cfg extends uvm_object;
  `uvm_object_utils(pcie_topology_cfg)
  pcie_topology_node_cfg nodes[$];
  pcie_topology_link_cfg links[$];

  function new(string name = "pcie_topology_cfg");
    super.new(name);
  endfunction

  function int find_node_index(string node_id);
    foreach (nodes[i])
      if (nodes[i] != null && nodes[i].node_id == node_id) return i;
    return -1;
  endfunction

  function pcie_topology_node_cfg find_node(string node_id);
    int index = find_node_index(node_id);
    return index < 0 ? null : nodes[index];
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_topology_cfg source;
    pcie_topology_node_cfg node_copy;
    pcie_topology_link_cfg link_copy;
    super.do_copy(rhs);
    if (!$cast(source, rhs))
      `uvm_fatal("TOPO_COPY", "topology copy source has wrong type")
    nodes.delete();
    links.delete();
    foreach (source.nodes[i]) begin
      node_copy = pcie_topology_node_cfg::type_id::create(
        $sformatf("node_copy_%0d", i));
      node_copy.copy(source.nodes[i]);
      nodes.push_back(node_copy);
    end
    foreach (source.links[i]) begin
      link_copy = pcie_topology_link_cfg::type_id::create(
        $sformatf("link_copy_%0d", i));
      link_copy.copy(source.links[i]);
      links.push_back(link_copy);
    end
  endfunction

  virtual function void validate(output string errors[$]);
    errors.delete();
  endfunction
endclass
```

Create the standalone `pcie_tl_vip/src/topology/pcie_topology_pkg.sv`:

```systemverilog
package pcie_topology_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "pcie_topology_types.sv"
  `include "pcie_topology_cfg.sv"
endpackage : pcie_topology_pkg
```

Add `import pcie_topology_pkg::*;` after `import uvm_pkg::*;` in
`pcie_tl_pkg.sv`. Add the topology include directory to `filelist.f` and compile
`pcie_topology_pkg.sv` after the two standalone helper packages but before
`pcie_tl_pkg.sv`:

```text
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/topology
/home/ryan/pcie_work/pcie_tl_vip/src/topology/pcie_topology_pkg.sv
```

- [ ] **Step 4: Compile and run the clone test**

Run the remote compile recipe, then:

```bash
sshpass -e ssh ubuntu@10.11.10.53 "bash -lic 'cd \
  /home/ubuntu/workspace/pcie_topology_env/pcie_tl_vip/sim && \
  ./simv +UVM_TESTNAME=pcie_topology_model_unit_test \
  +UVM_VERBOSITY=UVM_LOW -l run_topology_model.log'"
```

Expected: `UVM_ERROR : 0`, `UVM_FATAL : 0`.

- [ ] **Step 5: Commit the model slice**

```bash
git add pcie_tl_vip/src/topology pcie_tl_vip/src/pcie_tl_pkg.sv \
  pcie_tl_vip/tests/pcie_topology_model_unit_test.sv pcie_tl_vip/sim/filelist.f
git commit -m "feat: add common PCIe topology model"
```

---

### Task 2: Named Profiles and Programmatic Builder

**Files:**
- Create: `pcie_tl_vip/src/topology/pcie_topology_builder.sv`
- Modify: `pcie_tl_vip/src/topology/pcie_topology_pkg.sv`
- Create: `pcie_tl_vip/tests/pcie_topology_builder_unit_test.sv`
- Modify: `pcie_tl_vip/sim/filelist.f`

- [ ] **Step 1: Write exact-profile tests that fail before the builder exists**

Create `pcie_tl_vip/tests/pcie_topology_builder_unit_test.sv` with one UVM test that calls all three named builders and checks every record:

```systemverilog
import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_topology_builder_unit_test extends uvm_test;
  `uvm_component_utils(pcie_topology_builder_unit_test)
  function new(string name = "pcie_topology_builder_unit_test",
               uvm_component parent = null); super.new(name, parent); endfunction
  function void require(bit condition, string message);
    if (!condition) `uvm_error("TOPO_BUILD", message)
  endfunction
  function void check_link(pcie_topology_link_cfg link, string id,
      string up, pcie_topology_port_role_e up_role, int up_index,
      string down, pcie_topology_port_role_e down_role, int down_index,
      int width, int gen);
    require(link.link_id == id, {id, ": link ID"});
    require(link.upstream_node_id == up && link.upstream_role == up_role &&
            link.upstream_port_index == up_index, {id, ": upstream endpoint"});
    require(link.downstream_node_id == down && link.downstream_role == down_role &&
            link.downstream_port_index == down_index, {id, ": downstream endpoint"});
    require(link.link_width == width && link.max_gen == gen && link.enabled,
            {id, ": physical intent"});
  endfunction
  task run_phase(uvm_phase phase);
    pcie_topology_cfg cfg;
    phase.raise_objection(this);
    cfg = pcie_topology_builder::build_ep_x16(5);
    require(cfg.nodes.size() == 2 && cfg.links.size() == 1, "EP_X16 sizes");
    check_link(cfg.links[0], "RC0_EP0", "RC0", PCIE_TOPO_PORT_RC, 0,
               "EP0", PCIE_TOPO_PORT_EP, 0, 16, 5);

    cfg = pcie_topology_builder::build_ep_2x8(4);
    require(cfg.nodes.size() == 4 && cfg.links.size() == 2, "EP_2X8 sizes");
    check_link(cfg.links[0], "RC0_EP0", "RC0", PCIE_TOPO_PORT_RC, 0,
               "EP0", PCIE_TOPO_PORT_EP, 0, 8, 4);
    check_link(cfg.links[1], "RC1_EP1", "RC1", PCIE_TOPO_PORT_RC, 0,
               "EP1", PCIE_TOPO_PORT_EP, 0, 8, 4);

    cfg = pcie_topology_builder::build_switch_1x16_4x4(5);
    require(cfg.nodes.size() == 6 && cfg.links.size() == 5,
            "SWITCH_1X16_4X4 sizes");
    require(cfg.find_node("SW0").num_usp == 1 &&
            cfg.find_node("SW0").num_dsp == 4, "Switch port counts");
    check_link(cfg.links[0], "RC0_SW0_USP0", "RC0", PCIE_TOPO_PORT_RC, 0,
               "SW0", PCIE_TOPO_PORT_USP, 0, 16, 5);
    for (int i = 0; i < 4; i++) begin
      check_link(cfg.links[i+1], $sformatf("SW0_DSP%0d_EP%0d", i, i),
                 "SW0", PCIE_TOPO_PORT_DSP, i, $sformatf("EP%0d", i),
                 PCIE_TOPO_PORT_EP, 0, 4, 5);
      require(cfg.find_node("SW0").dsp_owner_usp[i] == 0,
              $sformatf("DSP%0d ownership", i));
    end
    phase.drop_objection(this);
  endtask
endclass
```

Add it to `filelist.f`. Compile and expect an unknown-type error for `pcie_topology_builder`.

- [ ] **Step 2: Implement the complete builder**

Create `pcie_tl_vip/src/topology/pcie_topology_builder.sv`:

```systemverilog
class pcie_topology_builder extends uvm_object;
  `uvm_object_utils(pcie_topology_builder)
  pcie_topology_cfg topology;

  function new(string name = "pcie_topology_builder");
    super.new(name);
    topology = pcie_topology_cfg::type_id::create({name, "_cfg"});
  endfunction

  function pcie_topology_node_cfg add_node(
      string node_id, pcie_topology_node_kind_e kind);
    pcie_topology_node_cfg node =
      pcie_topology_node_cfg::type_id::create({node_id, "_node"});
    node.node_id = node_id;
    node.kind = kind;
    topology.nodes.push_back(node);
    return node;
  endfunction

  function pcie_topology_node_cfg add_rc(string node_id);
    return add_node(node_id, PCIE_TOPO_NODE_RC);
  endfunction

  function pcie_topology_node_cfg add_ep(string node_id);
    return add_node(node_id, PCIE_TOPO_NODE_EP);
  endfunction

  function pcie_topology_node_cfg add_switch(string node_id,
      int unsigned num_usp, int unsigned num_dsp, input int owners[]);
    pcie_topology_node_cfg node = add_node(node_id, PCIE_TOPO_NODE_SWITCH);
    node.num_usp = num_usp;
    node.num_dsp = num_dsp;
    node.dsp_owner_usp = new[owners.size()];
    foreach (owners[i]) node.dsp_owner_usp[i] = owners[i];
    return node;
  endfunction

  function pcie_topology_link_cfg connect(string link_id,
      string upstream_node_id, pcie_topology_port_role_e upstream_role,
      int unsigned upstream_port_index, string downstream_node_id,
      pcie_topology_port_role_e downstream_role,
      int unsigned downstream_port_index, int unsigned link_width,
      int unsigned max_gen, bit enabled = 1);
    pcie_topology_link_cfg link =
      pcie_topology_link_cfg::type_id::create({link_id, "_link"});
    link.link_id = link_id;
    link.upstream_node_id = upstream_node_id;
    link.upstream_role = upstream_role;
    link.upstream_port_index = upstream_port_index;
    link.downstream_node_id = downstream_node_id;
    link.downstream_role = downstream_role;
    link.downstream_port_index = downstream_port_index;
    link.link_width = link_width;
    link.max_gen = max_gen;
    link.enabled = enabled;
    topology.links.push_back(link);
    return link;
  endfunction

  function pcie_topology_cfg finish();
    return topology;
  endfunction

  static function pcie_topology_cfg build_ep_x16(int unsigned max_gen);
    pcie_topology_builder builder = new("ep_x16_builder");
    void'(builder.add_rc("RC0"));
    void'(builder.add_ep("EP0"));
    void'(builder.connect("RC0_EP0", "RC0", PCIE_TOPO_PORT_RC, 0,
      "EP0", PCIE_TOPO_PORT_EP, 0, 16, max_gen));
    return builder.finish();
  endfunction

  static function pcie_topology_cfg build_ep_2x8(int unsigned max_gen);
    pcie_topology_builder builder = new("ep_2x8_builder");
    for (int i = 0; i < 2; i++) begin
      void'(builder.add_rc($sformatf("RC%0d", i)));
      void'(builder.add_ep($sformatf("EP%0d", i)));
      void'(builder.connect($sformatf("RC%0d_EP%0d", i, i),
        $sformatf("RC%0d", i), PCIE_TOPO_PORT_RC, 0,
        $sformatf("EP%0d", i), PCIE_TOPO_PORT_EP, 0, 8, max_gen));
    end
    return builder.finish();
  endfunction

  static function pcie_topology_cfg build_switch_1x16_4x4(
      int unsigned max_gen);
    pcie_topology_builder builder = new("switch_1x16_4x4_builder");
    int owners[] = new[4];
    foreach (owners[i]) owners[i] = 0;
    void'(builder.add_rc("RC0"));
    void'(builder.add_switch("SW0", 1, 4, owners));
    void'(builder.connect("RC0_SW0_USP0", "RC0", PCIE_TOPO_PORT_RC, 0,
      "SW0", PCIE_TOPO_PORT_USP, 0, 16, max_gen));
    for (int i = 0; i < 4; i++) begin
      void'(builder.add_ep($sformatf("EP%0d", i)));
      void'(builder.connect($sformatf("SW0_DSP%0d_EP%0d", i, i),
        "SW0", PCIE_TOPO_PORT_DSP, i, $sformatf("EP%0d", i),
        PCIE_TOPO_PORT_EP, 0, 4, max_gen));
    end
    return builder.finish();
  endfunction
endclass
```

Include it after `pcie_topology_cfg.sv` in `pcie_topology_pkg.sv`.

- [ ] **Step 3: Compile and run the builder test**

Run `pcie_topology_builder_unit_test` on 53. Expected: all three UVM summary counts are zero.

- [ ] **Step 4: Commit the builder slice**

```bash
git add pcie_tl_vip/src/topology/pcie_topology_builder.sv \
  pcie_tl_vip/src/topology/pcie_topology_pkg.sv \
  pcie_tl_vip/tests/pcie_topology_builder_unit_test.sv pcie_tl_vip/sim/filelist.f
git commit -m "feat: add deterministic PCIe topology profiles"
```

---

### Task 3: Complete Graph Validation

**Files:**
- Modify: `pcie_tl_vip/src/topology/pcie_topology_cfg.sv`
- Create: `pcie_tl_vip/tests/pcie_topology_validation_unit_test.sv`
- Modify: `pcie_tl_vip/sim/filelist.f`

- [ ] **Step 1: Write focused failing validation tests**

Create `pcie_tl_vip/tests/pcie_topology_validation_unit_test.sv`. Use a fresh clone for every mutation so cases do not contaminate one another:

```systemverilog
import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_topology_validation_unit_test extends uvm_test;
  `uvm_component_utils(pcie_topology_validation_unit_test)
  function new(string name = "pcie_topology_validation_unit_test",
               uvm_component parent = null); super.new(name, parent); endfunction
  function bit contains(input string errors[$], string fragment);
    foreach (errors[i])
      if (uvm_is_match({"*", fragment, "*"}, errors[i])) return 1;
    return 0;
  endfunction
  function void expect_error(pcie_topology_cfg cfg, string fragment);
    string errors[$];
    cfg.validate(errors);
    if (!contains(errors, fragment))
      `uvm_error("TOPO_VALID", $sformatf(
        "expected error containing '%s', got %p", fragment, errors))
  endfunction
  function pcie_topology_cfg copy_of(pcie_topology_cfg source);
    pcie_topology_cfg result;
    $cast(result, source.clone());
    return result;
  endfunction
  task run_phase(uvm_phase phase);
    pcie_topology_cfg valid;
    pcie_topology_cfg cfg;
    pcie_topology_builder b;
    pcie_topology_node_cfg extra;
    string errors[$];
    int owners[];
    phase.raise_objection(this);
    valid = pcie_topology_builder::build_switch_1x16_4x4(5);
    valid.validate(errors);
    if (errors.size() != 0)
      `uvm_error("TOPO_VALID", $sformatf("valid profile rejected: %p", errors))

    cfg = new("empty"); expect_error(cfg, "enabled link");
    cfg = copy_of(valid); cfg.nodes[1].node_id = "RC0";
    expect_error(cfg, "duplicate node ID");
    cfg = copy_of(valid); cfg.links[1].link_id = cfg.links[0].link_id;
    expect_error(cfg, "duplicate link ID");
    cfg = copy_of(valid); cfg.links[0].link_id = "";
    expect_error(cfg, "link ID is empty");
    cfg = copy_of(valid); cfg.links[0].upstream_node_id = "MISSING";
    expect_error(cfg, "unknown upstream node");
    cfg = copy_of(valid); cfg.links[0].upstream_role = PCIE_TOPO_PORT_EP;
    expect_error(cfg, "role does not match");
    cfg = copy_of(valid); cfg.links[1].upstream_port_index = 4;
    expect_error(cfg, "port index out of range");
    cfg = copy_of(valid); cfg.links[1].link_width = 2;
    expect_error(cfg, "unsupported width");
    cfg = copy_of(valid); cfg.links[1].max_gen = 3;
    expect_error(cfg, "unsupported generation");
    cfg = copy_of(valid); cfg.links[2].upstream_port_index = 0;
    expect_error(cfg, "reuses enabled port");
    cfg = copy_of(valid); cfg.links[4].enabled = 0;
    expect_error(cfg, "isolated node");
    cfg = copy_of(valid); cfg.links[4].enabled = 0;
    cfg.links[4].link_width = 2;
    expect_error(cfg, "unsupported width");

    cfg = pcie_topology_builder::build_ep_2x8(4);
    extra = pcie_topology_node_cfg::type_id::create("extra_rc");
    extra.node_id = "RC_EXTRA";
    extra.kind = PCIE_TOPO_NODE_RC;
    cfg.nodes.push_back(extra);
    expect_error(cfg, "direct topology");

    cfg = pcie_topology_builder::build_ep_x16(4);
    cfg.nodes[0].num_usp = 1;
    expect_error(cfg, "Switch-only state");

    cfg = copy_of(valid);
    b = new("direct_mix");
    extra = b.add_rc("RC_EXTRA"); cfg.nodes.push_back(extra);
    extra = b.add_ep("EP_EXTRA"); cfg.nodes.push_back(extra);
    cfg.links.push_back(b.connect("DIRECT_EXTRA", "RC_EXTRA",
      PCIE_TOPO_PORT_RC, 0, "EP_EXTRA", PCIE_TOPO_PORT_EP, 0, 4, 4));
    expect_error(cfg, "mixes direct and Switch links");

    cfg = copy_of(valid); cfg.links[1].downstream_node_id = "SW0";
    cfg.links[1].downstream_role = PCIE_TOPO_PORT_USP;
    expect_error(cfg, "Switch cascading");
    cfg = copy_of(valid);
    extra = pcie_topology_node_cfg::type_id::create("second_switch");
    extra.node_id = "SW1";
    extra.kind = PCIE_TOPO_NODE_SWITCH;
    extra.num_usp = 1;
    extra.num_dsp = 1;
    extra.dsp_owner_usp = new[1];
    extra.dsp_owner_usp[0] = 0;
    cfg.nodes.push_back(extra);
    expect_error(cfg, "exactly one Switch");
    cfg = copy_of(valid); cfg.links[0].enabled = 0;
    expect_error(cfg, "USP must have exactly one RC link");
    cfg = copy_of(valid); cfg.links[1].enabled = 0;
    expect_error(cfg, "DSP must have exactly one Endpoint link");
    cfg = copy_of(valid); cfg.links[2].downstream_node_id = "EP0";
    expect_error(cfg, "Endpoint must have exactly one parent");
    cfg = copy_of(valid); cfg.nodes[1].dsp_owner_usp = new[3];
    expect_error(cfg, "ownership array size");
    cfg = copy_of(valid); cfg.nodes[1].dsp_owner_usp[0] = 1;
    expect_error(cfg, "owner index out of range");

    owners = new[2]; owners[0] = 0; owners[1] = 0;
    b = new("two_usp");
    void'(b.add_rc("RC0")); void'(b.add_rc("RC1"));
    void'(b.add_switch("SW0", 2, 2, owners));
    void'(b.add_ep("EP0")); void'(b.add_ep("EP1"));
    void'(b.connect("U0", "RC0", PCIE_TOPO_PORT_RC, 0,
      "SW0", PCIE_TOPO_PORT_USP, 0, 8, 4));
    void'(b.connect("U1", "RC1", PCIE_TOPO_PORT_RC, 0,
      "SW0", PCIE_TOPO_PORT_USP, 1, 8, 4));
    void'(b.connect("D0", "SW0", PCIE_TOPO_PORT_DSP, 0,
      "EP0", PCIE_TOPO_PORT_EP, 0, 4, 4));
    void'(b.connect("D1", "SW0", PCIE_TOPO_PORT_DSP, 1,
      "EP1", PCIE_TOPO_PORT_EP, 0, 4, 4));
    expect_error(b.finish(), "USP owns no DSP");

    cfg = copy_of(valid);
    cfg.nodes[0].node_id = "";
    cfg.links[2].link_width = 1;
    cfg.validate(errors);
    if (errors.size() < 2 || !contains(errors, "node ID is empty") ||
        !contains(errors, "unsupported width"))
      `uvm_error("TOPO_VALID", "independent errors were not collected")
    phase.drop_objection(this);
  endtask
endclass
```

Compile and run. Expected before implementation: multiple `TOPO_VALID` errors because `validate()` returns an empty queue.

- [ ] **Step 2: Replace the minimal validator with complete structural checks**

Add these helpers to `pcie_topology_cfg`:

```systemverilog
  protected function bit role_matches(pcie_topology_node_cfg node,
                                       pcie_topology_port_role_e role);
    if (node == null) return 0;
    case (node.kind)
      PCIE_TOPO_NODE_RC: return role == PCIE_TOPO_PORT_RC;
      PCIE_TOPO_NODE_EP: return role == PCIE_TOPO_PORT_EP;
      PCIE_TOPO_NODE_SWITCH:
        return role inside {PCIE_TOPO_PORT_USP, PCIE_TOPO_PORT_DSP};
      default: return 0;
    endcase
  endfunction

  protected function bit port_in_range(pcie_topology_node_cfg node,
      pcie_topology_port_role_e role, int unsigned index);
    if (node == null) return 0;
    if (node.kind inside {PCIE_TOPO_NODE_RC, PCIE_TOPO_NODE_EP})
      return index == 0;
    if (role == PCIE_TOPO_PORT_USP) return index < node.num_usp;
    if (role == PCIE_TOPO_PORT_DSP) return index < node.num_dsp;
    return 0;
  endfunction
```

Replace `validate()` with the following deterministic implementation. Structural checks apply to all links; connectivity, port reuse, and isolation use only enabled links.

```systemverilog
  virtual function void validate(output string errors[$]);
    int node_id_count[string];
    int link_id_count[string];
    int used_port[string];
    int degree[];
    int rc_count = 0;
    int ep_count = 0;
    int switch_count = 0;
    int enabled_count = 0;
    int direct_count = 0;
    int switch_link_count = 0;
    int switch_index = -1;
    int ep_parent_count[string];

    errors.delete();
    degree = new[nodes.size()];
    if (nodes.size() < 2)
      errors.push_back("topology must contain at least two nodes");

    foreach (nodes[i]) begin
      if (nodes[i] == null) begin
        errors.push_back($sformatf("node[%0d] is null", i));
        continue;
      end
      if (nodes[i].node_id.len() == 0)
        errors.push_back($sformatf("node[%0d] node ID is empty", i));
      else begin
        node_id_count[nodes[i].node_id]++;
        if (node_id_count[nodes[i].node_id] > 1)
          errors.push_back($sformatf("duplicate node ID '%s'", nodes[i].node_id));
      end
      case (nodes[i].kind)
        PCIE_TOPO_NODE_RC: begin
          rc_count++;
          if (nodes[i].num_usp != 0 || nodes[i].num_dsp != 0 ||
              nodes[i].dsp_owner_usp.size() != 0)
            errors.push_back($sformatf(
              "RC node '%s' carries Switch-only state", nodes[i].node_id));
        end
        PCIE_TOPO_NODE_EP: begin
          ep_count++;
          if (nodes[i].num_usp != 0 || nodes[i].num_dsp != 0 ||
              nodes[i].dsp_owner_usp.size() != 0)
            errors.push_back($sformatf(
              "Endpoint node '%s' carries Switch-only state", nodes[i].node_id));
        end
        PCIE_TOPO_NODE_SWITCH: begin
          switch_count++;
          switch_index = i;
          if (nodes[i].num_usp == 0 || nodes[i].num_dsp == 0)
            errors.push_back($sformatf(
              "Switch '%s' must declare nonzero USP and DSP counts",
              nodes[i].node_id));
          if (nodes[i].dsp_owner_usp.size() != nodes[i].num_dsp)
            errors.push_back($sformatf(
              "Switch '%s' ownership array size %0d does not match DSP count %0d",
              nodes[i].node_id, nodes[i].dsp_owner_usp.size(), nodes[i].num_dsp));
          foreach (nodes[i].dsp_owner_usp[d])
            if (nodes[i].dsp_owner_usp[d] < 0 ||
                nodes[i].dsp_owner_usp[d] >= nodes[i].num_usp)
              errors.push_back($sformatf(
                "Switch '%s' DSP%0d owner index out of range: %0d",
                nodes[i].node_id, d, nodes[i].dsp_owner_usp[d]));
        end
      endcase
    end

    foreach (links[i]) begin
      int up_index;
      int down_index;
      pcie_topology_node_cfg up_node;
      pcie_topology_node_cfg down_node;
      string up_key;
      string down_key;
      bit is_direct;
      bit is_switch_up;
      bit is_switch_down;
      if (links[i] == null) begin
        errors.push_back($sformatf("link[%0d] is null", i));
        continue;
      end
      if (links[i].link_id.len() == 0)
        errors.push_back($sformatf("link[%0d] link ID is empty", i));
      else begin
        link_id_count[links[i].link_id]++;
        if (link_id_count[links[i].link_id] > 1)
          errors.push_back($sformatf("duplicate link ID '%s'", links[i].link_id));
      end
      if (!(links[i].link_width inside {4, 8, 16}))
        errors.push_back($sformatf("link '%s' has unsupported width x%0d",
          links[i].link_id, links[i].link_width));
      if (!(links[i].max_gen inside {4, 5}))
        errors.push_back($sformatf("link '%s' has unsupported generation Gen%0d",
          links[i].link_id, links[i].max_gen));

      up_index = find_node_index(links[i].upstream_node_id);
      down_index = find_node_index(links[i].downstream_node_id);
      up_node = up_index < 0 ? null : nodes[up_index];
      down_node = down_index < 0 ? null : nodes[down_index];
      if (up_node == null)
        errors.push_back($sformatf("link '%s' names unknown upstream node '%s'",
          links[i].link_id, links[i].upstream_node_id));
      if (down_node == null)
        errors.push_back($sformatf("link '%s' names unknown downstream node '%s'",
          links[i].link_id, links[i].downstream_node_id));
      if (up_node != null && !role_matches(up_node, links[i].upstream_role))
        errors.push_back($sformatf("link '%s' upstream role does not match node '%s'",
          links[i].link_id, up_node.node_id));
      if (down_node != null && !role_matches(down_node, links[i].downstream_role))
        errors.push_back($sformatf("link '%s' downstream role does not match node '%s'",
          links[i].link_id, down_node.node_id));
      if (up_node != null && !port_in_range(up_node, links[i].upstream_role,
                                            links[i].upstream_port_index))
        errors.push_back($sformatf("link '%s' upstream port index out of range",
          links[i].link_id));
      if (down_node != null && !port_in_range(down_node, links[i].downstream_role,
                                              links[i].downstream_port_index))
        errors.push_back($sformatf("link '%s' downstream port index out of range",
          links[i].link_id));

      is_direct = up_node != null && down_node != null &&
        up_node.kind == PCIE_TOPO_NODE_RC &&
        links[i].upstream_role == PCIE_TOPO_PORT_RC &&
        down_node.kind == PCIE_TOPO_NODE_EP &&
        links[i].downstream_role == PCIE_TOPO_PORT_EP;
      is_switch_up = up_node != null && down_node != null &&
        up_node.kind == PCIE_TOPO_NODE_RC &&
        down_node.kind == PCIE_TOPO_NODE_SWITCH &&
        links[i].downstream_role == PCIE_TOPO_PORT_USP;
      is_switch_down = up_node != null && down_node != null &&
        up_node.kind == PCIE_TOPO_NODE_SWITCH &&
        links[i].upstream_role == PCIE_TOPO_PORT_DSP &&
        down_node.kind == PCIE_TOPO_NODE_EP;
      if (up_node != null && down_node != null &&
          up_node.kind == PCIE_TOPO_NODE_SWITCH &&
          down_node.kind == PCIE_TOPO_NODE_SWITCH)
        errors.push_back($sformatf("link '%s' attempts unsupported Switch cascading",
          links[i].link_id));
      if (!(is_direct || is_switch_up || is_switch_down))
        errors.push_back($sformatf("link '%s' has unsupported phase-one link form",
          links[i].link_id));

      if (links[i].enabled) begin
        enabled_count++;
        if (up_index >= 0) degree[up_index]++;
        if (down_index >= 0) degree[down_index]++;
        if (is_direct) direct_count++;
        if (is_switch_up || is_switch_down) switch_link_count++;
        if (down_node != null && down_node.kind == PCIE_TOPO_NODE_EP)
          ep_parent_count[down_node.node_id]++;
        up_key = $sformatf("%s:%0d:%0d", links[i].upstream_node_id,
                          links[i].upstream_role, links[i].upstream_port_index);
        down_key = $sformatf("%s:%0d:%0d", links[i].downstream_node_id,
                            links[i].downstream_role, links[i].downstream_port_index);
        used_port[up_key]++;
        used_port[down_key]++;
        if (used_port[up_key] > 1)
          errors.push_back($sformatf("link '%s' reuses enabled port %s",
            links[i].link_id, up_key));
        if (used_port[down_key] > 1)
          errors.push_back($sformatf("link '%s' reuses enabled port %s",
            links[i].link_id, down_key));
      end
    end

    if (enabled_count == 0)
      errors.push_back("topology must contain at least one enabled link");
    foreach (nodes[i])
      if (nodes[i] != null && degree[i] == 0)
        errors.push_back($sformatf("isolated node '%s' has no enabled link",
          nodes[i].node_id));
    foreach (nodes[i])
      if (nodes[i] != null && nodes[i].kind == PCIE_TOPO_NODE_EP &&
          ep_parent_count[nodes[i].node_id] != 1)
        errors.push_back($sformatf(
          "Endpoint must have exactly one parent: '%s' has %0d",
          nodes[i].node_id, ep_parent_count[nodes[i].node_id]));

    if (switch_count == 0) begin
      if (direct_count != enabled_count || rc_count != enabled_count ||
          ep_count != enabled_count)
        errors.push_back("direct topology must reduce to independent one-RC/one-Endpoint pairs");
    end else begin
      pcie_topology_node_cfg sw_node;
      int usp_links[];
      int dsp_links[];
      bit owner_seen[];
      if (switch_count != 1)
        errors.push_back($sformatf(
          "phase one requires exactly one Switch, got %0d", switch_count));
      if (direct_count != 0 && switch_link_count != 0)
        errors.push_back("topology mixes direct and Switch links");
      if (switch_index >= 0) begin
        sw_node = nodes[switch_index];
        usp_links = new[sw_node.num_usp];
        dsp_links = new[sw_node.num_dsp];
        owner_seen = new[sw_node.num_usp];
        foreach (links[i]) if (links[i] != null && links[i].enabled) begin
          if (links[i].downstream_node_id == sw_node.node_id &&
              links[i].downstream_role == PCIE_TOPO_PORT_USP &&
              links[i].downstream_port_index < usp_links.size())
            usp_links[links[i].downstream_port_index]++;
          if (links[i].upstream_node_id == sw_node.node_id &&
              links[i].upstream_role == PCIE_TOPO_PORT_DSP &&
              links[i].upstream_port_index < dsp_links.size())
            dsp_links[links[i].upstream_port_index]++;
        end
        foreach (usp_links[u])
          if (usp_links[u] != 1)
            errors.push_back($sformatf(
              "Switch USP must have exactly one RC link: USP%0d has %0d",
              u, usp_links[u]));
        foreach (dsp_links[d])
          if (dsp_links[d] != 1)
            errors.push_back($sformatf(
              "Switch DSP must have exactly one Endpoint link: DSP%0d has %0d",
              d, dsp_links[d]));
        foreach (sw_node.dsp_owner_usp[d])
          if (sw_node.dsp_owner_usp[d] >= 0 &&
              sw_node.dsp_owner_usp[d] < owner_seen.size())
            owner_seen[sw_node.dsp_owner_usp[d]] = 1;
        foreach (owner_seen[u])
          if (!owner_seen[u])
            errors.push_back($sformatf("Switch USP owns no DSP: USP%0d", u));
      end
    end
  endfunction
```

- [ ] **Step 3: Run validator tests and all three builders through validation**

Run `pcie_topology_validation_unit_test` and `pcie_topology_builder_unit_test`. Expected: both logs end with W/E/F `0/0/0`.

- [ ] **Step 4: Commit the validator slice**

```bash
git add pcie_tl_vip/src/topology/pcie_topology_cfg.sv \
  pcie_tl_vip/tests/pcie_topology_validation_unit_test.sv pcie_tl_vip/sim/filelist.f
git commit -m "feat: validate supported PCIe topology graphs"
```

---

### Task 4: Transaction-Layer Adapter and Reverse Audit

**Files:**
- Create: `pcie_tl_vip/src/adapter/pcie_tl_topology_adapter.sv`
- Modify: `pcie_tl_vip/src/pcie_tl_pkg.sv`
- Create: `pcie_tl_vip/tests/pcie_tl_topology_adapter_unit_test.sv`
- Modify: `pcie_tl_vip/sim/filelist.f`

- [ ] **Step 1: Write failing direct, Switch, multi-USP, and audit tests**

Create `pcie_tl_vip/tests/pcie_tl_topology_adapter_unit_test.sv`:

```systemverilog
import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_tl_topology_adapter_unit_test extends uvm_test;
  `uvm_component_utils(pcie_tl_topology_adapter_unit_test)
  function new(string name = "pcie_tl_topology_adapter_unit_test",
               uvm_component parent = null); super.new(name, parent); endfunction
  function void require(bit condition, string message);
    if (!condition) `uvm_error("TOPO_ADAPT", message)
  endfunction
  function pcie_topology_cfg build_two_usp();
    pcie_topology_builder builder = new("two_usp_builder");
    int owners[] = new[3];
    owners[0] = 0;
    owners[1] = 1;
    owners[2] = 1;
    void'(builder.add_rc("RC0"));
    void'(builder.add_rc("RC1"));
    void'(builder.add_switch("SW0", 2, 3, owners));
    for (int i = 0; i < 3; i++)
      void'(builder.add_ep($sformatf("EP%0d", i)));
    void'(builder.connect("UP0", "RC0", PCIE_TOPO_PORT_RC, 0,
      "SW0", PCIE_TOPO_PORT_USP, 0, 8, 4));
    void'(builder.connect("UP1", "RC1", PCIE_TOPO_PORT_RC, 0,
      "SW0", PCIE_TOPO_PORT_USP, 1, 8, 4));
    for (int i = 0; i < 3; i++)
      void'(builder.connect($sformatf("DOWN%0d", i),
        "SW0", PCIE_TOPO_PORT_DSP, i, $sformatf("EP%0d", i),
        PCIE_TOPO_PORT_EP, 0, 4, 4));
    return builder.finish();
  endfunction
  task run_phase(uvm_phase phase);
    pcie_tl_topology_adapter adapter;
    pcie_tl_env_config cfg;
    pcie_topology_cfg source;
    string errors[$];
    phase.raise_objection(this);
    adapter = pcie_tl_topology_adapter::type_id::create("adapter");

    source = pcie_topology_builder::build_ep_x16(5);
    cfg = adapter.translate(source, errors);
    require(errors.size() == 0 && cfg != null, "EP_X16 translation");
    require(!cfg.switch_enable && cfg.num_rc == 1 && cfg.num_ep == 1,
            "EP_X16 native counts");

    source = pcie_topology_builder::build_ep_2x8(4);
    begin
      pcie_topology_link_cfg swap = source.links[0];
      source.links[0] = source.links[1];
      source.links[1] = swap;
    end
    cfg = adapter.translate(source, errors);
    require(errors.size() == 0 && cfg != null, "EP_2X8 translation");
    require(!cfg.switch_enable && cfg.num_rc == 2 && cfg.num_ep == 2,
            "EP_2X8 native counts");
    require(adapter.direct_link_ids.size() == 2 &&
            adapter.direct_link_ids[0] == "RC0_EP0" &&
            adapter.direct_link_ids[1] == "RC1_EP1",
            "direct link ordering");

    source = pcie_topology_builder::build_switch_1x16_4x4(5);
    cfg = adapter.translate(source, errors);
    require(errors.size() == 0 && cfg != null, "Switch translation");
    require(cfg.switch_enable && cfg.switch_cfg != null, "Switch enable");
    require(cfg.switch_cfg.num_usp == 1 && cfg.switch_cfg.num_ds_ports == 4,
            "Switch native counts");
    foreach (cfg.switch_cfg.dsp_owner[i])
      require(cfg.switch_cfg.dsp_owner[i] == 0, "Switch ownership");
    require(cfg.switch_cfg.ds_mem_base.size() == 4 &&
            cfg.switch_cfg.usp_sec_bus.size() == 1,
            "Switch generated array sizes");
    require(adapter.switch_ep_node_ids.size() == 4 &&
            adapter.switch_ep_node_ids[3] == "EP3",
            "Switch DSP-to-Endpoint ordering");

    source = build_two_usp();
    cfg = adapter.translate(source, errors);
    require(errors.size() == 0 && cfg != null, "multi-USP translation");
    require(cfg.switch_cfg.num_usp == 2 &&
            cfg.switch_cfg.num_ds_ports == 3,
            "multi-USP native counts");
    require(cfg.switch_cfg.dsp_owner.size() == 3 &&
            cfg.switch_cfg.dsp_owner[0] == 0 &&
            cfg.switch_cfg.dsp_owner[1] == 1 &&
            cfg.switch_cfg.dsp_owner[2] == 1,
            "multi-USP native ownership");

    cfg.num_ep++;
    adapter.audit(source, cfg, errors);
    require(adapter.error_contains(errors, "Endpoint count mismatch"),
            "audit detects corrupted native Endpoint count");
    cfg.num_ep--;
    cfg.switch_cfg.dsp_owner[2] = 0;
    adapter.audit(source, cfg, errors);
    require(adapter.error_contains(errors, "ownership mismatch"),
            "audit detects corrupted native ownership");
    phase.drop_objection(this);
  endtask
endclass
```

Add the test to `filelist.f`, compile, and expect failure because `pcie_tl_topology_adapter` is undeclared.

- [ ] **Step 2: Implement translation with stable direct ordering**

Create `pcie_tl_vip/src/adapter/pcie_tl_topology_adapter.sv`:

```systemverilog
class pcie_tl_topology_adapter extends uvm_object;
  `uvm_object_utils(pcie_tl_topology_adapter)
  string direct_link_ids[$];
  string direct_rc_node_ids[$];
  string direct_ep_node_ids[$];
  string switch_ep_node_ids[];

  function new(string name = "pcie_tl_topology_adapter");
    super.new(name);
  endfunction

  function bit error_contains(input string errors[$], string fragment);
    foreach (errors[i])
      if (uvm_is_match({"*", fragment, "*"}, errors[i])) return 1;
    return 0;
  endfunction

  function pcie_tl_env_config translate(pcie_topology_cfg topology,
                                         output string errors[$]);
    pcie_tl_env_config result;
    pcie_topology_link_cfg direct_links[$];
    pcie_topology_node_cfg switch_node;
    pcie_tl_switch_config switch_cfg;
    string validation_errors[$];
    errors.delete();
    direct_link_ids.delete();
    direct_rc_node_ids.delete();
    direct_ep_node_ids.delete();
    switch_ep_node_ids = new[0];
    if (topology == null) begin
      errors.push_back("topology is null");
      return null;
    end
    topology.validate(validation_errors);
    foreach (validation_errors[i]) errors.push_back(validation_errors[i]);
    if (errors.size() != 0) return null;

    result = pcie_tl_env_config::type_id::create("translated_tl_cfg");
    foreach (topology.nodes[i])
      if (topology.nodes[i].kind == PCIE_TOPO_NODE_SWITCH)
        switch_node = topology.nodes[i];

    if (switch_node == null) begin
      foreach (topology.links[i])
        if (topology.links[i].enabled) direct_links.push_back(topology.links[i]);
      for (int i = 0; i < direct_links.size(); i++)
        for (int j = i + 1; j < direct_links.size(); j++)
          if (direct_links[j].link_id < direct_links[i].link_id) begin
            pcie_topology_link_cfg swap = direct_links[i];
            direct_links[i] = direct_links[j];
            direct_links[j] = swap;
          end
      result.switch_enable = 0;
      result.rc_agent_enable = 1;
      result.ep_agent_enable = 1;
      result.num_rc = direct_links.size();
      result.num_ep = direct_links.size();
      foreach (direct_links[i]) begin
        direct_link_ids.push_back(direct_links[i].link_id);
        direct_rc_node_ids.push_back(direct_links[i].upstream_node_id);
        direct_ep_node_ids.push_back(direct_links[i].downstream_node_id);
      end
    end else begin
      result.switch_enable = 1;
      result.rc_agent_enable = 1;
      result.ep_agent_enable = 1;
      result.num_rc = switch_node.num_usp;
      result.num_ep = switch_node.num_dsp;
      switch_cfg = pcie_tl_switch_config::type_id::create("translated_switch_cfg");
      switch_cfg.num_usp = switch_node.num_usp;
      switch_cfg.num_ds_ports = switch_node.num_dsp;
      switch_cfg.dsp_owner = new[switch_node.dsp_owner_usp.size()];
      foreach (switch_cfg.dsp_owner[i])
        switch_cfg.dsp_owner[i] = switch_node.dsp_owner_usp[i];
      switch_cfg.init_defaults();
      result.switch_cfg = switch_cfg;
      switch_ep_node_ids = new[switch_node.num_dsp];
      foreach (topology.links[i]) begin
        if (topology.links[i].enabled &&
            topology.links[i].upstream_node_id == switch_node.node_id &&
            topology.links[i].upstream_role == PCIE_TOPO_PORT_DSP)
          switch_ep_node_ids[topology.links[i].upstream_port_index] =
            topology.links[i].downstream_node_id;
      end
    end

    audit(topology, result, errors);
    if (errors.size() != 0) return null;
    `uvm_info("TOPO_TL", $sformatf(
      "retained physical intent for %0d link(s); TL backend does not simulate lanes, training, or data rate",
      topology.links.size()), UVM_LOW)
    return result;
  endfunction

  function void audit(pcie_topology_cfg topology, pcie_tl_env_config native_cfg,
                      output string errors[$]);
    pcie_topology_node_cfg switch_node;
    int enabled_links = 0;
    errors.delete();
    if (topology == null || native_cfg == null) begin
      errors.push_back("audit input is null");
      return;
    end
    foreach (topology.nodes[i])
      if (topology.nodes[i].kind == PCIE_TOPO_NODE_SWITCH)
        switch_node = topology.nodes[i];
    foreach (topology.links[i]) if (topology.links[i].enabled) enabled_links++;
    if (switch_node == null) begin
      if (native_cfg.switch_enable)
        errors.push_back("direct topology unexpectedly enabled Switch mode");
      if (native_cfg.num_rc != enabled_links)
        errors.push_back($sformatf("RC count mismatch: %0d versus %0d",
          native_cfg.num_rc, enabled_links));
      if (native_cfg.num_ep != enabled_links)
        errors.push_back($sformatf("Endpoint count mismatch: %0d versus %0d",
          native_cfg.num_ep, enabled_links));
    end else begin
      if (!native_cfg.switch_enable || native_cfg.switch_cfg == null) begin
        errors.push_back("Switch topology lost native Switch configuration");
        return;
      end
      if (native_cfg.num_ep != switch_node.num_dsp)
        errors.push_back($sformatf("Endpoint count mismatch: %0d versus %0d",
          native_cfg.num_ep, switch_node.num_dsp));
      if (native_cfg.switch_cfg.num_usp != switch_node.num_usp)
        errors.push_back("Switch USP count mismatch");
      if (native_cfg.switch_cfg.num_ds_ports != switch_node.num_dsp)
        errors.push_back("Switch DSP count mismatch");
      if (native_cfg.switch_cfg.dsp_owner.size() !=
          switch_node.dsp_owner_usp.size())
        errors.push_back("Switch ownership size mismatch");
      else foreach (native_cfg.switch_cfg.dsp_owner[i])
        if (native_cfg.switch_cfg.dsp_owner[i] != switch_node.dsp_owner_usp[i])
          errors.push_back($sformatf("Switch DSP%0d ownership mismatch", i));
      if (native_cfg.switch_cfg.ds_mem_base.size() != switch_node.num_dsp ||
          native_cfg.switch_cfg.ds_mem_limit.size() != switch_node.num_dsp ||
          native_cfg.switch_cfg.usp_sec_bus.size() != switch_node.num_usp ||
          native_cfg.switch_cfg.usp_sub_bus.size() != switch_node.num_usp)
        errors.push_back("Switch generated window array size mismatch");
    end
  endfunction
endclass
```

Include the adapter after `env/pcie_tl_env_config.sv`, when both native configuration types are visible.

- [ ] **Step 3: Run adapter tests**

Compile and run `pcie_tl_topology_adapter_unit_test`. Expected: direct counts `1/1`, `2/2`; Switch counts `1/4`; multi-USP ownership preserved; corrupted audit detected without a UVM error from the test.

- [ ] **Step 4: Commit the adapter slice**

```bash
git add pcie_tl_vip/src/adapter/pcie_tl_topology_adapter.sv \
  pcie_tl_vip/src/pcie_tl_pkg.sv \
  pcie_tl_vip/tests/pcie_tl_topology_adapter_unit_test.sv pcie_tl_vip/sim/filelist.f
git commit -m "feat: translate common topology into TL configuration"
```

---

### Task 5: Thin Custom Environment and Strict CLI Base Test

**Files:**
- Create: `pcie_tl_vip/src/env/pcie_tl_custom_env.sv`
- Modify: `pcie_tl_vip/src/pcie_tl_pkg.sv`
- Create: `pcie_tl_vip/tests/pcie_tl_custom_base_test.sv`
- Modify: `pcie_tl_vip/sim/filelist.f`

- [ ] **Step 1: Write an elaboration test against the missing custom env**

Create `pcie_tl_custom_base_test` exactly as the public test entry below, add it after `pcie_tl_base_test.sv` in `filelist.f`, compile, and expect `pcie_tl_custom_env` to be undeclared.

- [ ] **Step 2: Implement the thin derived environment**

Create `pcie_tl_vip/src/env/pcie_tl_custom_env.sv`:

```systemverilog
class pcie_tl_custom_env extends pcie_tl_env;
  `uvm_component_utils(pcie_tl_custom_env)
  pcie_topology_cfg topology_cfg;
  pcie_tl_topology_adapter topology_adapter;

  function new(string name = "pcie_tl_custom_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    pcie_tl_env_config translated_cfg;
    pcie_tl_env_config policy_cfg;
    string errors[$];
    string message;

    if (!uvm_config_db#(pcie_topology_cfg)::get(
          this, "", "topology_cfg", topology_cfg) || topology_cfg == null) begin
      `uvm_fatal("TOPO_ENV", "non-null topology_cfg is required")
      return;
    end
    topology_cfg.validate(errors);
    if (errors.size() != 0) begin
      foreach (errors[i]) message = {message, i == 0 ? "" : "; ", errors[i]};
      `uvm_fatal("TOPO_ENV", {"topology validation failed: ", message})
      return;
    end
    topology_adapter = pcie_tl_topology_adapter::type_id::create(
      "topology_adapter");
    translated_cfg = topology_adapter.translate(topology_cfg, errors);
    if (translated_cfg == null || errors.size() != 0) begin
      message = "";
      foreach (errors[i]) message = {message, i == 0 ? "" : "; ", errors[i]};
      `uvm_fatal("TOPO_ENV", {"topology translation failed: ", message})
      return;
    end

    if (!uvm_config_db#(pcie_tl_env_config)::get(
          this, "", "tl_policy_cfg", policy_cfg) || policy_cfg == null)
      policy_cfg = pcie_tl_env_config::type_id::create("default_tl_policy_cfg");

    // The policy object owns every non-topology field. Only these six fields
    // are topology-derived, so policy application cannot mutate nodes or links.
    policy_cfg.rc_agent_enable = translated_cfg.rc_agent_enable;
    policy_cfg.ep_agent_enable = translated_cfg.ep_agent_enable;
    policy_cfg.num_rc = translated_cfg.num_rc;
    policy_cfg.num_ep = translated_cfg.num_ep;
    policy_cfg.switch_enable = translated_cfg.switch_enable;
    policy_cfg.switch_cfg = translated_cfg.switch_cfg;
    uvm_config_db#(pcie_tl_env_config)::set(this, "", "cfg", policy_cfg);
    `uvm_info("TOPO_ENV", "PCIE_TL_CUSTOM_ENV_READY", UVM_LOW)
    super.build_phase(phase);
  endfunction
endclass
```

Include it immediately after `env/pcie_tl_env.sv`. Do not override `connect_phase` or `run_phase`.

- [ ] **Step 3: Implement exact CLI parsing and the programmatic hook**

Create `pcie_tl_vip/tests/pcie_tl_custom_base_test.sv`:

```systemverilog
import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_tl_custom_base_test extends uvm_test;
  `uvm_component_utils(pcie_tl_custom_base_test)
  pcie_tl_custom_env env;
  pcie_topology_cfg topology_cfg;
  pcie_tl_env_config tl_policy_cfg;

  function new(string name = "pcie_tl_custom_base_test",
               uvm_component parent = null); super.new(name, parent); endfunction

  virtual function void configure_tl_policy();
    tl_policy_cfg.if_mode = TLM_MODE;
  endfunction

  // Return 1 and set result to bypass named profiles. Returning 0 selects CLI.
  virtual function bit configure_topology(output pcie_topology_cfg result);
    result = null;
    return 0;
  endfunction

  protected function void get_occurrences(string stem, string value_prefix,
      output string raw[$], output string values[$]);
    uvm_cmdline_processor clp = uvm_cmdline_processor::get_inst();
    raw.delete();
    values.delete();
    void'(clp.get_arg_matches(stem, raw));
    void'(clp.get_arg_values(value_prefix, values));
  endfunction

  virtual function void build_phase(uvm_phase phase);
    string topology_raw[$];
    string topology_values[$];
    string gen_raw[$];
    string gen_values[$];
    pcie_topology_cfg programmatic_cfg;
    bit programmatic;
    int generation;
    super.build_phase(phase);
    tl_policy_cfg = pcie_tl_env_config::type_id::create("tl_policy_cfg");
    configure_tl_policy();
    get_occurrences("+PCIE_TOPOLOGY", "+PCIE_TOPOLOGY=",
                    topology_raw, topology_values);
    get_occurrences("+PCIE_GEN", "+PCIE_GEN=", gen_raw, gen_values);
    programmatic = configure_topology(programmatic_cfg);

    if (programmatic) begin
      if (programmatic_cfg == null) begin
        `uvm_fatal("TOPO_CLI", "programmatic topology hook returned null")
        return;
      end
      if (topology_raw.size() != 0 || gen_raw.size() != 0) begin
        `uvm_fatal("TOPO_CLI",
          "programmatic topology cannot be mixed with PCIE_TOPOLOGY or PCIE_GEN")
        return;
      end
      topology_cfg = programmatic_cfg;
    end else begin
      if (topology_raw.size() != 1 || topology_values.size() != 1 ||
          topology_values[0].len() == 0) begin
        `uvm_fatal("TOPO_CLI",
          "exactly one non-empty +PCIE_TOPOLOGY=<profile> is required")
        return;
      end
      if (gen_raw.size() != 1 || gen_values.size() != 1 ||
          gen_values[0].len() == 0) begin
        `uvm_fatal("TOPO_CLI", "exactly one +PCIE_GEN=4 or +PCIE_GEN=5 is required")
        return;
      end
      if (gen_values[0] == "4") generation = 4;
      else if (gen_values[0] == "5") generation = 5;
      else begin
        `uvm_fatal("TOPO_CLI", "exactly one +PCIE_GEN=4 or +PCIE_GEN=5 is required")
        return;
      end
      case (topology_values[0])
        "EP_X16": topology_cfg = pcie_topology_builder::build_ep_x16(generation);
        "EP_2X8": topology_cfg = pcie_topology_builder::build_ep_2x8(generation);
        "SWITCH_1X16_4X4":
          topology_cfg = pcie_topology_builder::build_switch_1x16_4x4(generation);
        default: begin
          `uvm_fatal("TOPO_CLI", $sformatf(
            "unknown PCIE_TOPOLOGY value '%s'", topology_values[0]))
          return;
        end
      endcase
    end

    uvm_config_db#(pcie_topology_cfg)::set(
      this, "env", "topology_cfg", topology_cfg);
    uvm_config_db#(pcie_tl_env_config)::set(
      this, "env", "tl_policy_cfg", tl_policy_cfg);
    env = pcie_tl_custom_env::type_id::create("env", this);
  endfunction
endclass
```

- [ ] **Step 4: Run three elaboration profiles and strict negative CLI cases**

Accepted runs:

```bash
for args in \
  'EP_X16 4' \
  'EP_2X8 5' \
  'SWITCH_1X16_4X4 5'; do
  set -- $args
  sshpass -e ssh ubuntu@10.11.10.53 "bash -lic 'cd \
    /home/ubuntu/workspace/pcie_topology_env/pcie_tl_vip/sim && \
    ./simv +UVM_TESTNAME=pcie_tl_custom_base_test \
      +PCIE_TOPOLOGY=$1 +PCIE_GEN=$2 +UVM_VERBOSITY=UVM_LOW \
      -l run_elab_$1.log'"
done
```

Expected in each log: `PCIE_TL_CUSTOM_ENV_READY`, W/E/F `0/0/0`.

Run missing, bare, duplicate, empty, unknown, and bad-generation cases. Each must contain a fatal report with ID `TOPO_CLI` and must not contain `PCIE_TL_CUSTOM_ENV_READY`:

```text
<no topology arguments>
+PCIE_TOPOLOGY +PCIE_GEN=4
+PCIE_TOPOLOGY=EP_X16 +PCIE_TOPOLOGY=EP_2X8 +PCIE_GEN=4
+PCIE_TOPOLOGY= +PCIE_GEN=4
+PCIE_TOPOLOGY=UNKNOWN +PCIE_GEN=4
+PCIE_TOPOLOGY=EP_X16 +PCIE_GEN=3
```

- [ ] **Step 5: Commit the custom-env slice**

```bash
git add pcie_tl_vip/src/env/pcie_tl_custom_env.sv \
  pcie_tl_vip/src/pcie_tl_pkg.sv pcie_tl_vip/tests/pcie_tl_custom_base_test.sv \
  pcie_tl_vip/sim/filelist.f
git commit -m "feat: add topology-driven TL custom environment"
```

---

### Task 6: Profile Traffic and One-DSP/One-Endpoint Extension Test

**Files:**
- Create: `pcie_tl_vip/tests/pcie_tl_custom_profile_test.sv`
- Modify: `pcie_tl_vip/sim/filelist.f`

- [ ] **Step 1: Write the functional test before tuning policy**

Create `pcie_tl_custom_profile_test` extending the new base. Its policy is explicit and independent of the topology:

```systemverilog
import uvm_pkg::*;
import pcie_topology_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_tl_custom_profile_test extends pcie_tl_custom_base_test;
  `uvm_component_utils(pcie_tl_custom_profile_test)
  function new(string name = "pcie_tl_custom_profile_test",
               uvm_component parent = null); super.new(name, parent); endfunction
  virtual function void configure_tl_policy();
    super.configure_tl_policy();
    tl_policy_cfg.use_unified_mem = 0;
    tl_policy_cfg.fc_enable = 1;
    tl_policy_cfg.infinite_credit = 1;
    tl_policy_cfg.ep_auto_response = 1;
    tl_policy_cfg.scb_enable = 1;
    tl_policy_cfg.cpl_timeout_ns = 200000;
  endfunction

  function pcie_tl_ep_agent endpoint_at(int index);
    if (env.ep_agents.size() > index) return env.ep_agents[index];
    if (index == 0) return env.ep_agent;
    return null;
  endfunction

  task downstream_roundtrip(int pair, bit [63:0] address);
    pcie_tl_rw_seq write_seq;
    pcie_tl_rw_seq read_seq;
    byte expected[] = new[32];
    foreach (expected[i]) expected[i] = byte'(8'h40 + pair * 8'h20 + i);
    write_seq = pcie_tl_rw_seq::type_id::create($sformatf("write_%0d", pair));
    write_seq.op = PCIE_RW_WRITE;
    write_seq.addr = address;
    write_seq.byte_len = expected.size();
    write_seq.wdata = new[expected.size()];
    foreach (expected[i]) write_seq.wdata[i] = expected[i];
    write_seq.start(env.rc_agents[pair].sequencer);
    #1us;
    read_seq = pcie_tl_rw_seq::type_id::create($sformatf("read_%0d", pair));
    read_seq.op = PCIE_RW_READ;
    read_seq.addr = address;
    read_seq.byte_len = expected.size();
    read_seq.start(env.rc_agents[pair].sequencer);
    if (read_seq.status != PCIE_RW_OK || read_seq.rdata.size() != expected.size())
      `uvm_error("TOPO_TRAFFIC", $sformatf("pair %0d read failed", pair))
    else foreach (expected[i])
      if (read_seq.rdata[i] !== expected[i])
        `uvm_error("TOPO_TRAFFIC", $sformatf(
          "pair %0d byte %0d mismatch", pair, i))
  endtask

  task upstream_read(int endpoint_index);
    pcie_tl_rw_seq read_seq = pcie_tl_rw_seq::type_id::create(
      $sformatf("upstream_read_%0d", endpoint_index));
    pcie_tl_ep_agent endpoint = endpoint_at(endpoint_index);
    if (endpoint == null)
      `uvm_fatal("TOPO_TRAFFIC", "missing endpoint agent")
    read_seq.op = PCIE_RW_READ;
    read_seq.addr = 64'h0000_1000 + endpoint_index * 64'h100;
    read_seq.byte_len = 16;
    read_seq.start(endpoint.sequencer);
    if (read_seq.status != PCIE_RW_OK || read_seq.rdata.size() != 16)
      `uvm_error("TOPO_TRAFFIC", $sformatf(
        "Endpoint %0d upstream read failed", endpoint_index))
  endtask

  task run_phase(uvm_phase phase);
    int endpoint_count;
    phase.raise_objection(this);
    endpoint_count = env.cfg.switch_enable ? env.cfg.switch_cfg.num_ds_ports
                                           : env.cfg.num_ep;
    if (env.cfg.switch_enable) begin
      if (env.sw == null || env.sw.usp == null ||
          env.sw.dsp.size() != endpoint_count ||
          env.ep_agents.size() != endpoint_count)
        `uvm_fatal("TOPO_TRAFFIC", $sformatf(
          "Switch profile did not elaborate 1 USP/%0d DSP/%0d EP",
          endpoint_count, endpoint_count))
      for (int i = 0; i < endpoint_count; i++) begin
        bit [31:0] bus_register = env.sw.dsp[i].cfg_read(12'h018);
        if (bus_register[15:8] != env.cfg.switch_cfg.ds_secondary_bus[i])
          `uvm_error("TOPO_TRAFFIC", $sformatf("DSP%0d config-space audit failed", i))
        downstream_roundtrip(0, {32'h0, env.cfg.switch_cfg.ds_mem_base[i]});
        upstream_read(i);
      end
    end else begin
      for (int i = 0; i < endpoint_count; i++) begin
        automatic int pair = i;
        fork
          // Same address, pair-specific data: a crossed/shared backend fails.
          downstream_roundtrip(pair, 64'h0001_0000);
        join_none
      end
      wait fork;
    end
    `uvm_info("TOPO_TRAFFIC", $sformatf(
      "PROFILE_TRAFFIC_PASS endpoints=%0d", endpoint_count), UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass
```

Compile first and run all three profiles. Any routing or policy defect must make this test fail before implementation is adjusted.

- [ ] **Step 2: Add a programmatic one-DSP/one-Endpoint derived test**

Append this class to the same file:

```systemverilog
class pcie_tl_programmatic_1dsp_1ep_test extends pcie_tl_custom_profile_test;
  `uvm_component_utils(pcie_tl_programmatic_1dsp_1ep_test)
  function new(string name = "pcie_tl_programmatic_1dsp_1ep_test",
               uvm_component parent = null); super.new(name, parent); endfunction
  virtual function bit configure_topology(output pcie_topology_cfg result);
    pcie_topology_builder builder = new("one_dsp_builder");
    int owners[] = new[1];
    owners[0] = 0;
    void'(builder.add_rc("RC0"));
    void'(builder.add_switch("SW0", 1, 1, owners));
    void'(builder.add_ep("EP0"));
    void'(builder.connect("UP", "RC0", PCIE_TOPO_PORT_RC, 0,
      "SW0", PCIE_TOPO_PORT_USP, 0, 16, 5));
    void'(builder.connect("DOWN", "SW0", PCIE_TOPO_PORT_DSP, 0,
      "EP0", PCIE_TOPO_PORT_EP, 0, 4, 5));
    result = builder.finish();
    return 1;
  endfunction
endclass
```

This one-DSP test runs with no `PCIE_TOPOLOGY` or `PCIE_GEN` arguments and completes the same downstream and upstream traffic through the count-driven loop above.

- [ ] **Step 3: Run the complete profile matrix**

```text
pcie_tl_custom_profile_test +PCIE_TOPOLOGY=EP_X16 +PCIE_GEN=4
pcie_tl_custom_profile_test +PCIE_TOPOLOGY=EP_X16 +PCIE_GEN=5
pcie_tl_custom_profile_test +PCIE_TOPOLOGY=EP_2X8 +PCIE_GEN=4
pcie_tl_custom_profile_test +PCIE_TOPOLOGY=EP_2X8 +PCIE_GEN=5
pcie_tl_custom_profile_test +PCIE_TOPOLOGY=SWITCH_1X16_4X4 +PCIE_GEN=4
pcie_tl_custom_profile_test +PCIE_TOPOLOGY=SWITCH_1X16_4X4 +PCIE_GEN=5
pcie_tl_programmatic_1dsp_1ep_test
```

Expected in every accepted log: `PROFILE_TRAFFIC_PASS`; W/E/F `0/0/0`. The `TOPO_TL` message must say physical intent was retained and must not claim LTSSM/link-up, negotiated width, Serial training, PIPE training, or Gen4/Gen5 data rate.

- [ ] **Step 4: Commit the functional tests**

```bash
git add pcie_tl_vip/tests/pcie_tl_custom_profile_test.sv pcie_tl_vip/sim/filelist.f
git commit -m "test: verify topology profiles with TL traffic"
```

---

### Task 7: Documentation, Compatibility Regression, and Phase Boundary

**Files:**
- Modify: `pcie_tl_vip/docs/PCIe_TL_VIP_User_Guide.md`
- Modify: `pcie_tl_vip/docs/PCIe_TL_VIP_Integration_Guide.md`

- [ ] **Step 1: Add exact user-facing usage**

Add these commands and semantics to the user guide:

```text
+PCIE_TOPOLOGY=EP_X16            +PCIE_GEN=4|5
+PCIE_TOPOLOGY=EP_2X8            +PCIE_GEN=4|5
+PCIE_TOPOLOGY=SWITCH_1X16_4X4   +PCIE_GEN=4|5
```

State explicitly:

- the first profile is one independent RC/EP transaction path with x16 intent;
- the second is two independent RC/EP transaction paths with x8 intent;
- the third is one Switch, one USP, four DSPs, and exactly one Endpoint per DSP;
- arbitrary phase-one graphs use `pcie_topology_builder` from a derived test's `configure_topology()` hook;
- width and generation are retained configuration intent only in `pcie_tl_vip`;
- Serial/PIPE transport, LTSSM, negotiated width, and negotiated generation require the later SVT backend.

- [ ] **Step 2: Document the integration contract**

In the integration guide, show:

```systemverilog
uvm_config_db#(pcie_topology_cfg)::set(this, "env", "topology_cfg", topology);
uvm_config_db#(pcie_tl_env_config)::set(this, "env", "tl_policy_cfg", policy);
env = pcie_tl_custom_env::type_id::create("env", this);
```

Explain that `pcie_tl_custom_env` translates before `super.build_phase()`, while old tests may continue creating `pcie_tl_env` with native configuration. Record the later contract as `pcie_svt_topology_env extends pcie_device_unified_vip_env`, with Synopsys' official `tb_pcie_svt_uvm_unified_vip_sys` example remaining an installation dependency rather than copied source.

- [ ] **Step 3: Run object, adapter, CLI, and legacy regression gates on 53**

Run the four object-level tests, the seven functional matrix entries from Task 6, all six CLI-negative cases, and these compatibility anchors:

```text
pcie_tl_smoke_mem_test
pcie_tl_smoke_cfg_test
pcie_tl_rw_readback_test
pcie_tl_multipair_heavy_test +NUM_PAIRS=1
pcie_tl_multipair_heavy_test +NUM_PAIRS=2
pcie_tl_switch_rw_readback_test
pcie_tl_switch_unified_mem_test
pcie_tl_multi_root_route_test
pcie_tl_uneven_ownership_test
pcie_tl_per_root_tag_test
pcie_tl_cross_root_isolation_test
pcie_tl_tag_bit_runtime_test +TAG_BIT=8
pcie_tl_tag_bit_runtime_test +TAG_BIT=10
pcie_tl_bar_decoder_test
pcie_tl_bar_state_test
pcie_tl_virtio_fix_unit_test
pcie_tl_virtio_fix_order_test
```

Then run every pre-existing registered test class from `main`, excluding only the base class already exercised through its derived tests:

```bash
mapfile -t LEGACY_TESTS < <(
  git grep -h -E '^class [A-Za-z0-9_]+ extends (pcie_tl_base_test|uvm_test)' \
    main -- 'pcie_tl_vip/tests/*.sv' |
  sed -E 's/^class ([A-Za-z0-9_]+).*/\1/' |
  grep -v '^pcie_tl_base_test$' |
  sort -u
)
for test_name in "${LEGACY_TESTS[@]}"; do
  sshpass -e ssh ubuntu@10.11.10.53 "bash -lic 'cd \
    /home/ubuntu/workspace/pcie_topology_env/pcie_tl_vip/sim && \
    ./simv +UVM_TESTNAME=${test_name} +TAG_BIT=8 +UVM_VERBOSITY=UVM_LOW \
      -l run_legacy_${test_name}.log'"
done
```

Expected for every positive test: W/E/F `0/0/0`. For negative CLI tests, the only fatal is `TOPO_CLI`, and `PCIE_TL_CUSTOM_ENV_READY` is absent. If a pre-existing compatibility test fails on the unchanged base path, use `superpowers:systematic-debugging`, add a focused regression for the root cause, and keep any fix minimal and outside topology ownership.

- [ ] **Step 4: Verify scope and working-tree hygiene**

```bash
git diff --check main...HEAD
git diff --name-only main...HEAD | grep '^svt_pcie_integration/' && exit 1 || true
git status --short
```

Expected: no whitespace errors, no `svt_pcie_integration/` implementation changes, and no uncommitted implementation files. The unrelated main-worktree file `motd.legal-displayed` remains untouched.

- [ ] **Step 5: Commit documentation**

```bash
git add pcie_tl_vip/docs/PCIe_TL_VIP_User_Guide.md \
  pcie_tl_vip/docs/PCIe_TL_VIP_Integration_Guide.md
git commit -m "docs: describe topology-driven TL integration"
```

- [ ] **Step 6: Request final code review before integration**

Use `superpowers:requesting-code-review` against `main...HEAD`, address only verified findings, rerun the affected VCS tests plus `git diff --check`, and then use `superpowers:finishing-a-development-branch` to choose push/merge/cleanup.
