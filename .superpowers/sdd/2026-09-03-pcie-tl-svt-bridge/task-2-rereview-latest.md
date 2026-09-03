# Task 2 latest re-review (through `ed5e77a` and follow-up bridge fixes)

## Scope and checks

Reviewed `pcie_svt_if_adapter`, `pcie_svt_tlp_mapper_bridge`, topology bridge
construction/RC adapter publication, the guarded adapter unit test, and the
R-2020.12 Mapper declarations.  `bash svt_pcie_integration/sim/check_tl_svt_bridge_contract.sh`
passes (`TL_SVT_BRIDGE_CONTRACT_PASS adapters=4 mapper_ports=2 legacy_filelists=2`).
`git diff --check` is clean for the Task 2 sources (an unrelated pre-existing
EOF-whitespace warning remains in `task-2-fix2-report.md`).

## Findings

### Important: the requested public SVT codec field is still not present

The brief names a public `pcie_svt_tlp_codec codec` configuration field.  The
adapter inherits the base class's `pcie_tl_codec codec` and instead exposes
`pcie_svt_tlp_codec codec_adapter` (`pcie_svt_if_adapter.sv:9-12`).  Conversion
continues to call static `pcie_svt_tlp_codec::encode/decode`, so assigning or
checking a caller-provided SVT codec handle is impossible.  This is an API
contract deviation, not a compile failure; either the brief must explicitly
adopt `codec_adapter`/static conversion or the public API needs an accessor or
non-static codec implementation.

### Minor: adapter unit coverage remains weaker than the Task 2 brief

The mock test now configures the application ID indirectly in adapter
`connect_phase`, and exercises `send` plus `receive`; that fixed the previous
deterministic RX failure.  It only checks TX queue count, requester ID, and
payload size (`pcie_svt_if_adapter_unit_test.sv:54-60`).  It does not compare
the captured wire fields/payload, nor exercise wrong-application-ID and
completion-tag-mismatch diagnostics called out in the brief.  This can miss
field/routing regressions while still passing.

## Verified correctness

- Mapper declarations match the installed R-2020.12 API: TX is
  `SVT_XVM(blocking_put_imp)#(...)` and RX is
  `svt_debug_opts_blocking_put_port#(...)`; the bridge uses the public members
  and the RX `uvm_blocking_put_imp` connection.
- Adapter construction is in `build_phase`; `connect_phase` no longer creates
  children and validates both TX/RX application-ID entries before binding.
- Mock endpoint application ID synchronization makes the adapter unit test's
  RX injection and receive path coherent.
- `PCIE_SVT_AVAILABLE` is defined by `pcie_svt_topology.f`, while TL-only
  filelists remain unaffected.  Chinese responsibility/error comments are
  present throughout touched bridge/adapter code.
- TL forward mode publishes RC adapters using `root_hierarchy` keys, matching
  the TL environment's per-root lookup and avoiding descriptor-order routing.

## Compile validation

The bridge-specific VCS command was attempted on the mandated VCS host with
the repository filelist and R-2020.12 paths.  VCS started but stopped before
compilation because no license file/`LM_LICENSE_FILE` was available, so no
simulator pass/fail claim can be made from this environment.

## Conclusion

No new critical compile or Mapper API defect was found.  The implementation is
structurally sound against the documented R-2020.12 declarations.  The public
codec-handle mismatch is an Important API issue to resolve or document, and
the adapter test should be strengthened before treating Task 2 as complete
verification.
