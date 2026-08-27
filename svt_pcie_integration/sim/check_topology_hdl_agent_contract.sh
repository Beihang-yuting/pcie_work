#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
integration_dir=$(cd -- "$script_dir/.." && pwd)
macro_file="$integration_dir/rtl/pcie_svt_hdl_agent_macros.svh"
top_file="$integration_dir/rtl/pcie_svt_topology_env_top.sv"

fail() {
  echo "TOPOLOGY_HDL_AGENT_CONTRACT_FAIL: $*" >&2
  exit 1
}

if grep -n -E '(^|[^[:alnum:]_])defparam([^[:alnum:]_]|$)' \
    "$macro_file" "$top_file" >&2; then
  fail "active topology HDL sources contain defparam"
fi

parameter_names=(
  SVT_PCIE_UI_PCIE_SPEC_VER
  SVT_PCIE_UI_DISPLAY_NAME
  SVT_PCIE_UI_PHY_INTERFACE_TYPE
  SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE
  SVT_PCIE_UI_ENABLE_CFG_BLOCK
  SVT_PCIE_UI_CONNECT_ACTIVE_VIP
  SVT_PCIE_UI_NUM_PHYSICAL_LANES
  SVT_PCIE_UI_DEVICE_IS_ROOT
  SVT_PCIE_UI_HIERARCHY_NUMBER
)

for width in 4 8 16; do
  macro="PCIE_SVT_DECLARE_HDL_AGENT_X${width}"
  block=$(
    awk -v signature="\`define ${macro}(" '
      index($0, signature) == 1 { active = 1 }
      active { print }
      active && $0 !~ /\\[[:space:]]*$/ { exit }
    ' "$macro_file"
  )
  [[ -n $block ]] || fail "$macro definition is missing"
  [[ $block == *"svt_pcie_single_port_device_agent_hdl #("* ]] ||
    fail "$macro does not use parameterized HDL-agent instantiation"
  [[ $block == *"SVT_PCIE_UI_NUM_PHYSICAL_LANES(${width})"* ]] ||
    fail "$macro does not bind the exact x${width} lane count"
  [[ $block == *"PCIE_SVT_MAP_SERDES_X${width}"* ]] ||
    fail "$macro lost its x${width} Serial mapping"
  for parameter_name in "${parameter_names[@]}"; do
    count=$(grep -o -F ".${parameter_name}(" <<< "$block" | wc -l)
    [[ $count -eq 1 ]] ||
      fail "$macro binds $parameter_name $count times instead of once"
  done
done

echo "TOPOLOGY_HDL_AGENT_CONTRACT_PASS macros=3 parameters=9 serial_maps=3"
