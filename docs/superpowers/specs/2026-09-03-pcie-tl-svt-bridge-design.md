# PCIe TL-VIP / SVT Bridge Architecture

## Goal

Make `pcie_tl_env` the single PCIe transaction and configuration control plane,
while allowing Synopsys SVT PCIe to provide the protocol/link/Serial or PIPE
transport through a well-defined adapter. Existing TL-only and legacy SVT users
must continue to compile without modification.

## Scope

The first implementation targets a compile/elaboration-ready 1-RC + 1-EP
Serial path. The interfaces and routing metadata must be sized for later
multi-link topologies, but this phase does not claim a working switch or PIPE
transport.

## Architecture

```text
pcie_tl_env / TL sequences
          |
          v
pcie_svt_if_adapter (pcie_tl_if_adapter subtype)
          |
          v
SVT TLP Mapper public TLM ports
          |
          v
SVT device agent and Serial/PIPE
          |
          v
real PCIe RTL
```

TL sequences remain responsible for Config Read/Write, BAR sizing, enumeration,
memory transactions, completions, and DPU register-plan execution. SVT native
sequences remain available only as compatibility/debug support and are not part
of the bridge control path.

## Components and contracts

### `pcie_svt_if_adapter`

`pcie_svt_if_adapter` extends `pcie_tl_if_adapter`. It exposes the same
`send(pcie_tl_tlp)` and `receive(output pcie_tl_tlp)` contract used by TL agents,
and adds configuration for `application_id`, `link_id`, and the SVT mapper
handle. It converts transactions through a dedicated codec and routes received
completions using requester ID/tag metadata.

### `pcie_svt_tlp_codec`

The codec owns all field-by-field conversion between `pcie_tl_tlp` and
`svt_pcie_tlp`. Unsupported or ambiguous fields produce a UVM error and do not
silently change transaction semantics. The codec is independently unit-testable
without constructing a full SVT environment.

### `pcie_svt_topology_env`

The environment remains the management layer. It builds `pcie_tl_env` from the
existing topology/global configuration, optionally creates one adapter per
active link, and connects adapters to SVT TLP Mapper exports. A TL-only mode
does not require SVT packages or SVT VIFs. Static HDL slot limits are enforced
by the existing macro; UVM arrays remain dynamic.

### Compatibility

`pcie_tl_env`, `pcie_tl_custom_env`, existing package names, native SVT files,
and current filelists are retained in this phase. No source deletion or enum
renaming is performed until the bridge path and legacy regression both pass.

## Configuration

The bridge is selected by an explicit backend/mode field in the global policy
configuration. Existing TL-only defaults remain unchanged. A bridge instance
is created only for descriptors marked active and with a valid SVT mapper/VIF;
missing required handles are fatal during build/connect rather than deferred to
run time.

## Error handling

- Null mapper, VIF, or codec handles are fatal configuration errors.
- Unknown TLP kinds or fields are reported with `uvm_error` and include link and
  application identifiers.
- Completion routing mismatches are reported by the adapter and scoreboard.
- The adapter never drives SVT private internals or raw Serial signals.

## Verification

1. Codec round-trip unit checks for Config, Memory, Completion, requester ID,
   tag, byte enables, payload, and error metadata.
2. Adapter route checks for one RC/one EP and multiple application IDs.
3. TL-only regression unchanged.
4. On the VCS host, compile/elaborate the 1-RC + 1-EP Serial filelist using the
   installed SVT R-2020.12 packages and placeholder RTL when real RTL is absent.

Successful completion of this phase means the bridge classes and example are
compile/elaboration clean; protocol bring-up and switch expansion are
follow-up phases.
