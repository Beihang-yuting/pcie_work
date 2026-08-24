# PCIe TL Configurable Topology Environment Design

**Date:** 2026-08-24

**Status:** Approved for implementation planning

## 1. Purpose

The repository currently has two PCIe verification paths:

- `pcie_tl_vip`, a project-owned transaction-layer VIP and switch model; and
- `svt_pcie_integration`, a Synopsys SVT PCIe R-2020.12 integration.

The existing SVT integration grew to combine topology selection, command-line
parsing, profile generation, agent creation, proxy switching, passive sidecars,
scoreboarding, enumeration state, and staged test control in one environment.
Before rebuilding that path around Synopsys' official
`tb_pcie_svt_uvm_unified_vip_sys` example, the project needs one vendor-neutral
topology description with a proven project-owned backend.

This design introduces that topology description and a thin custom environment
derived from the existing `pcie_tl_env`. The first implementation phase supports
one Endpoint per Downstream Port while retaining a link-based API that can later
represent freer topologies.

## 2. Scope

### 2.1 In scope

- A vendor-neutral object model for PCIe nodes and links.
- Runtime selection of three named topology profiles:
  - one independent x16 Endpoint link;
  - two independent x8 Endpoint links; and
  - one x16 Switch Upstream Port plus four x4 Downstream Ports, with one
    Endpoint connected to each Downstream Port.
- Programmatic construction of equivalent topologies.
- Validation before any UVM agent or switch component is created.
- Translation of the common topology into the existing
  `pcie_tl_env_config` and `pcie_tl_switch_config` objects.
- A thin `pcie_tl_custom_env` derived from `pcie_tl_env`.
- A new base test that selects a topology and creates the custom environment.
- Positive, negative, translation, elaboration, and traffic tests.
- Preservation of all existing `pcie_tl_env` APIs and regression tests.

### 2.2 Out of scope

- Modifying `svt_pcie_integration` implementation files.
- Implementing `pcie_svt_topology_env`.
- Copying Synopsys example or product source into this repository.
- Switch cascading.
- Multiple Endpoints behind one Downstream Port.
- Runtime modeling of physical width or PCIe generation in `pcie_tl_vip`.
- PIPE transport.
- Replacing or deleting legacy tests that configure `pcie_tl_env_config`
  directly.

The later SVT phase will consume the same common topology and will derive its
SVT-facing environment from the official example class
`pcie_device_unified_vip_env`. That phase receives a separate design and plan
after the transaction-layer backend is green.

## 3. Architecture

The common topology is the sole topology source for new tests. Each backend is
an adapter from that source into its native configuration objects.

```text
command line or test override
            |
            v
pcie_topology_builder
            |
            v
pcie_topology_cfg.validate()
            |
            v
pcie_tl_topology_adapter
      |                 |
      v                 v
pcie_tl_env_config  pcie_tl_switch_config
      |                 |
      +--------+--------+
               v
pcie_tl_custom_env extends pcie_tl_env
               |
               v
existing agents, adapters, switch, scoreboard, and virtual sequencer
```

The custom environment does not recreate components already owned by
`pcie_tl_env`. Its only added responsibility is to obtain, validate, and
translate the common topology before calling the base implementation.

## 4. Common Topology Model

### 4.1 Node types

```systemverilog
typedef enum {
  PCIE_TOPO_NODE_RC,
  PCIE_TOPO_NODE_SWITCH,
  PCIE_TOPO_NODE_EP
} pcie_topology_node_kind_e;
```

`pcie_topology_node_cfg` contains:

- `string node_id`: a stable, non-empty identifier unique within a topology;
- `pcie_topology_node_kind_e kind`;
- for a Switch node, the number of Upstream and Downstream Ports; and
- for a Switch node, a complete `dsp_owner_usp[]` array mapping each
  Downstream Port index to an Upstream Port index.

RC and Endpoint nodes do not carry Switch port-count fields. The validator
rejects non-default Switch-only state on those node kinds.

### 4.2 Port roles

```systemverilog
typedef enum {
  PCIE_TOPO_PORT_RC,
  PCIE_TOPO_PORT_USP,
  PCIE_TOPO_PORT_DSP,
  PCIE_TOPO_PORT_EP
} pcie_topology_port_role_e;
```

Port indices are local to a node and role. For example, `SW0.DSP[3]` denotes
Downstream Port 3 of Switch `SW0`.

### 4.3 Link objects

`pcie_topology_link_cfg` contains:

- `string link_id`, unique and non-empty;
- upstream node ID, port role, and port index;
- downstream node ID, port role, and port index;
- `int unsigned link_width`, restricted to 4, 8, or 16;
- `int unsigned max_gen`, restricted to 4 or 5; and
- `bit enabled`.

The topology records physical intent even though the transaction-layer backend
does not simulate lane count or generation. The later SVT backend must apply
these fields to `svt_pcie_device_configuration`.

Disabled links are retained in the object for future profile composition but
are excluded from phase-one connectivity and translation. A node connected only
to disabled links is isolated and invalid.

### 4.4 Supported phase-one link forms

Only these enabled link forms are accepted:

```text
RC.RC[n]       <-> EP.EP[0]
RC.RC[n]       <-> SWITCH.USP[n]
SWITCH.DSP[n]  <-> EP.EP[0]
```

The first form creates an independent direct RC/Endpoint pair. The latter two
forms describe a single-level Switch topology.

The general node/link API is intentional. A future validator and backend may
allow additional link forms without changing existing tests or named profiles.

## 5. Topology Builder

`pcie_topology_builder` provides two APIs.

### 5.1 Named profiles

```systemverilog
build_ep_x16(int unsigned max_gen);
build_ep_2x8(int unsigned max_gen);
build_switch_1x16_4x4(int unsigned max_gen);
```

The generated topology is deterministic:

#### `EP_X16`

```text
RC0.RC[0] <-> EP0.EP[0], x16
```

#### `EP_2X8`

```text
RC0.RC[0] <-> EP0.EP[0], x8
RC1.RC[0] <-> EP1.EP[0], x8
```

#### `SWITCH_1X16_4X4`

```text
RC0.RC[0]  <-> SW0.USP[0], x16
SW0.DSP[0] <-> EP0.EP[0], x4
SW0.DSP[1] <-> EP1.EP[0], x4
SW0.DSP[2] <-> EP2.EP[0], x4
SW0.DSP[3] <-> EP3.EP[0], x4
```

All profile links use the requested Gen4 or Gen5 maximum generation.

### 5.2 Programmatic construction

The builder exposes operations equivalent to:

```systemverilog
add_rc(node_id);
add_switch(node_id, num_usp, num_dsp, dsp_owner_usp);
add_ep(node_id);
connect(link_id, upstream_endpoint, downstream_endpoint,
        link_width, max_gen);
```

These methods only construct objects. They do not perform partial UVM
component creation. The completed topology is validated as one transaction.

## 6. Validation

`pcie_topology_cfg.validate(output string errors[$])` checks the complete model
without emitting UVM reports. This permits deterministic unit testing and lets
the caller choose the reporting policy. `pcie_tl_custom_env` converts any
non-empty validation result into one fatal report before invoking the base env.

Validation includes:

1. At least one enabled link and at least two nodes exist.
2. Node IDs are non-empty and unique.
3. Link IDs are non-empty and unique.
4. Every link endpoint names an existing node.
5. Node kinds and port roles agree.
6. Port indices are in range.
7. Link width is x4, x8, or x16.
8. Maximum generation is Gen4 or Gen5.
9. Enabled links do not reuse a physical port endpoint.
10. Every node participates in at least one enabled link.
11. Direct topology components contain exactly one RC and one Endpoint.
12. A topology is either a collection of direct RC/Endpoint pairs or one
    Switch component; phase one rejects mixing direct pairs with a Switch.
13. A Switch topology contains no cascaded Switch connection.
14. Every Switch Upstream Port has exactly one RC link.
15. Every Switch Downstream Port has exactly one Endpoint link.
16. Every Endpoint has exactly one parent link.
17. `dsp_owner_usp[]` has one entry per Downstream Port.
18. Every DSP owner index names an existing Upstream Port.
19. Every Upstream Port owns at least one Downstream Port.

The validator collects all structural errors found in one pass where safe, so
a user does not need multiple simulations to discover independent topology
mistakes.

## 7. Transaction-Layer Adapter

`pcie_tl_topology_adapter` is a UVM object with no component hierarchy. It
accepts a validated topology and produces a fully initialized
`pcie_tl_env_config`.

### 7.1 Direct topology translation

- `switch_enable = 0`;
- `num_rc` equals the number of direct RC/Endpoint links;
- `num_ep` equals the same number;
- RC and Endpoint agents remain enabled; and
- the link ordering is stable by link ID, producing RC[i]/EP[i] pairs.

Because the existing direct multi-agent path is index-paired, the adapter must
reject a topology that cannot reduce losslessly to those pairs.

### 7.2 Switch topology translation

- `switch_enable = 1`;
- one `pcie_tl_switch_config` is created;
- `num_usp`, `num_ds_ports`, and `dsp_owner[]` come from the Switch node;
- `init_defaults()` is called only after counts and ownership are populated;
- generated bus and memory windows are checked for correct array sizes; and
- the result is assigned to `pcie_tl_env_config.switch_cfg`.

The phase-one adapter supports one Switch node per topology. Multiple
independent Switch nodes or Switch cascading remain reserved for a future
backend revision.

### 7.3 Physical attributes

The adapter verifies width and generation but does not map them into
`pcie_tl_env_config`, because `pcie_tl_vip` is transaction-layer only. It emits
one low-verbosity diagnostic summarizing the retained physical intent. It must
not imply that lane width, link training, or data rate was simulated.

### 7.4 Translation audit

Before returning, the adapter reconstructs these facts from the native
configuration and compares them to the source topology:

- direct RC/Endpoint pair count; or
- Switch USP count, DSP count, Endpoint count, and DSP ownership.

Any mismatch is an adapter failure. Silent node or link loss is forbidden.

## 8. Custom Environment

`pcie_tl_custom_env extends pcie_tl_env` implements this build sequence:

1. Get a non-null `pcie_topology_cfg` named `topology_cfg` from its
   `uvm_config_db` scope.
2. Validate the topology.
3. Translate it into a `pcie_tl_env_config`.
4. Apply optional non-topology TL policy supplied separately by the test, such
   as flow control, scoreboard, timeout, and unified-memory settings.
5. Put the final `pcie_tl_env_config` into the inherited env's configuration
   scope.
6. Call `super.build_phase(phase)` exactly once.

The derived env does not override `connect_phase` or `run_phase` in phase one.
It inherits all agent creation, adapter wiring, switch routing, scoreboarding,
virtual-sequencer population, and TLM loopback behavior.

Topology configuration and TL policy are intentionally separate. A common
topology must not hard-code scoreboard or traffic policy, and applying a policy
must not mutate nodes or links.

## 9. Test and Command-Line Entry

`pcie_tl_custom_base_test` owns command-line parsing and environment creation.
The env itself does not inspect profile plusargs.

Phase-one accepted arguments are:

```text
+PCIE_TOPOLOGY=EP_X16
+PCIE_TOPOLOGY=EP_2X8
+PCIE_TOPOLOGY=SWITCH_1X16_4X4
+PCIE_GEN=4
+PCIE_GEN=5
```

Exactly one topology argument and exactly one generation argument are required.
Bare, duplicate, empty, or unknown values are fatal before env creation.

The base test provides a virtual `configure_topology()` hook. Derived tests may
replace the named profile with a programmatically constructed topology without
changing the custom env. Such a test explicitly selects programmatic mode and
bypasses both required profile plusargs; mixing a programmatic topology with a
profile plusarg is fatal.

Per-link command-line syntax is deferred. Programmatic construction is the
supported extension interface until arbitrary topology requirements stabilize.

## 10. Compatibility and Migration

- `pcie_tl_env` and `pcie_tl_env_config` remain supported public classes.
- Existing tests continue to instantiate `pcie_tl_env` and configure native
  objects directly.
- Existing scalar aliases such as `rc_agent`, `ep_agent`, and `scb` remain
  unchanged.
- No existing file is deleted in phase one.
- New tests use `pcie_tl_custom_env` and the common topology.
- Existing tests are not mechanically migrated merely to exercise the new API.
- The default `pcie_tl_env` behavior remains one RC plus one Endpoint when no
  native configuration is supplied.

If implementation discovers that an existing base-env defect prevents a valid
translated topology, the defect receives a focused regression and minimal fix.
Such a fix must not move topology-building responsibility back into the env.

## 11. Verification

All simulation validation runs on `10.11.10.53` using a bash login shell so
VCS and license settings come from `/home/ubuntu/.bashrc`.

### 11.1 Object-level tests

- The three named builders produce exact expected node and link records.
- Deep copy and clone operations do not alias nested node/link objects.
- Each validation rule has a focused negative case.
- Multiple independent validation errors are reported deterministically.
- Disabled-link and isolated-node behavior is covered.

### 11.2 Translation tests

- `EP_X16` produces one native RC and one native Endpoint with Switch disabled.
- `EP_2X8` produces two index-paired RC/Endpoint links with Switch disabled.
- `SWITCH_1X16_4X4` produces one USP, four DSPs, four Endpoint agents, and
  ownership `{0,0,0,0}`.
- A multi-USP programmatic topology verifies nontrivial `dsp_owner[]`
  translation even though it is not a named command-line profile.
- Translation audit catches deliberately corrupted native results.

### 11.3 Environment tests

- All three profiles pass VCS compile and elaboration.
- `EP_X16` completes one Memory Write/Memory Read round trip.
- `EP_2X8` completes independent round trips on both pairs without crosstalk.
- `SWITCH_1X16_4X4` enumerates one USP and four DSP/Endpoint paths, then
  completes downstream and upstream traffic for every Endpoint.
- Invalid command-line combinations stop before agent creation.

### 11.4 Regression gate

- The existing `pcie_tl_vip` regression remains green.
- New accepted runs end with exactly zero UVM warnings, errors, and fatals.
- Logs distinguish transaction-layer validation from physical link validation;
  no accepted TL run may claim Serial link training, negotiated width, or
  negotiated generation.

## 12. Future SVT Backend Contract

The follow-on SVT design uses the same `pcie_topology_cfg` and named profiles.
Its environment will derive from the official R-2020.12 example environment:

```text
examples/sverilog/tb_pcie_svt_uvm_unified_vip_sys/
  env/pcie_device_unified_vip_env.sv
```

The Synopsys example remains an installation dependency and is not copied into
this public repository. The SVT backend will translate every external topology
link into the corresponding `svt_pcie_device_configuration`, status, agent, and
virtual-sequencer registration. Serial is the first transport; PIPE remains a
later adapter.

The future design must explicitly resolve how the official example's scalar
Root/Endpoint handles are generalized for multiple active links. This TL phase
does not pre-commit to an SVT agent-array implementation, but its topology and
test contracts must remain usable without modification.

## 13. Completion Criteria

Phase one is complete only when:

1. The common topology classes and builder are implemented and unit tested.
2. Validation rejects all unsupported phase-one graphs before component build.
3. The TL adapter translates supported topologies without information loss.
4. The thin custom env delegates component behavior to `pcie_tl_env`.
5. All three named profiles pass their functional smoke tests on VCS.
6. Existing transaction-layer regressions still pass.
7. Documentation states that physical width and generation are retained intent,
   not TL simulation results.
8. `svt_pcie_integration` implementation remains unchanged in this phase.
