# Task 1 review fixes

Addressed review findings in `pcie_svt_tlp_codec.sv`:

- Decode now restores format and address type, 64-bit memory width, lock variants, and completion type/kind.
- Unsupported TL/SVT formats fail immediately.
- Payloads must be whole DWORDs so byte length is not silently padded.
- Route requester ID/tag are validated on encode and decode, with diagnostics including route context.

Static validation: `git diff --check` passed. Full VCS/SVT simulation remains unavailable in this environment.
