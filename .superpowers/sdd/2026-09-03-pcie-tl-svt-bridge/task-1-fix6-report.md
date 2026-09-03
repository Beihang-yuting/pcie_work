# Final route/payload fixes

Route completer/status checks are now applied only to completion TLPs. The
codec rejects payloads on no-data SVT transactions, and route metadata includes
an explicit application-ID validity bit so application zero remains selectable.
Chinese comments document these constraints.
