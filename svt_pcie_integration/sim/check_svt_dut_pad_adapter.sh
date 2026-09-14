#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "$script_dir/../.." && pwd)
out_file=$(mktemp /tmp/pcie_svt_dut_pad_adapter_compile.XXXXXX.vvp)
trap 'rm -f "$out_file"' EXIT

# This is intentionally a syntax/elaboration smoke check only.  Full VCS/SVT
# regressions are owned by the user's real-DUT environment.
iverilog -g2012 -t null -I"$repo_dir/svt_pcie_integration/rtl" \
  -s pcie_svt_dut_pad_adapter_compile \
  "$repo_dir/svt_pcie_integration/tests/pcie_svt_dut_pad_adapter_compile.sv" \
  -o "$out_file"
echo "PCIE_SVT_DUT_PAD_ADAPTER_SYNTAX_PASS"
