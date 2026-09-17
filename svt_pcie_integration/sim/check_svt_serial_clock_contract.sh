#!/usr/bin/env bash
# 所属层次：svt_pcie_integration/sim 的轻量源码契约检查。
# 职责：确保 Serial X4/X8/X16 声明宏显式选择内部发送 bit clock，且
#       PIPE 分支未混入 Serial 专用参数；本脚本不编译，也不执行仿真。
# 依赖：Bash、awk 及同仓库 rtl/pcie_svt_hdl_agent_macros.svh。
# 资源与生命周期：只读宏源文件，不创建临时文件、不修改仓库内容；
#                 所有状态只在本次 awk 进程内保存。
# 失败路径：源码不存在、分支/宏缺失、参数重复或值不为 1'b0 时返回非零。
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
macro_file="$script_dir/../rtl/pcie_svt_hdl_agent_macros.svh"

if [[ ! -r "$macro_file" ]]; then
  echo "SVT_SERIAL_CLOCK_CONTRACT_FAIL: 无法读取宏源文件: $macro_file" >&2
  exit 1
fi

# 按预处理条件嵌套层次识别 PIPE/Serial 分支，避免把 PIPE 内部 Gen 档位
# 的 else 当作物理层切换；按续行识别宏体，防止三个参数碰巧都落入同一宏。
# 这只是本文件的源码契约检查，不替代预处理器、VCS 编译或真实建链验证。
awk -v expected="1'b0" '
  # 记录具体失败原因并继续检查，以便一次输出全部不满足的契约；
  # 输入为错误说明，副作用为 stderr 输出和错误计数，最终由 END 返回失败。
  function fail(message) {
    print "SVT_SERIAL_CLOCK_CONTRACT_FAIL: " message > "/dev/stderr"
    errors++
  }

  BEGIN {
    names[1] = "PCIE_SVT_DECLARE_HDL_AGENT_X4"
    names[2] = "PCIE_SVT_DECLARE_HDL_AGENT_X8"
    names[3] = "PCIE_SVT_DECLARE_HDL_AGENT_X16"
    expected_parameter = ".SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE(" expected ")"
  }

  {
    line = $0
    sub(/\/\/.*$/, "", line)

    if (line ~ /^[[:space:]]*`ifn?def[[:space:]]/) {
      depth++
      if (line ~ /^[[:space:]]*`ifdef[[:space:]]+PCIE_SVT_HDL_PHY_PIPE[[:space:]]*$/) {
        phy_depth = depth
        branch = "pipe"
        pipe_branches++
      }
    } else if (line ~ /^[[:space:]]*`else([[:space:]]|$)/ && phy_depth && depth == phy_depth) {
      branch = "serial"
      serial_branches++
    } else if (line ~ /^[[:space:]]*`endif([[:space:]]|$)/) {
      if (phy_depth && depth == phy_depth) {
        branch = ""
        phy_depth = 0
      }
      depth--
    }

    if (line ~ /^[[:space:]]*`define[[:space:]]/) {
      macro = line
      sub(/^[[:space:]]*`define[[:space:]]+/, "", macro)
      sub(/[([:space:]].*$/, "", macro)
      if (branch == "serial" && macro ~ /^PCIE_SVT_DECLARE_HDL_AGENT_X(4|8|16)$/)
        definitions[macro]++
    }

    if (line ~ /\.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE[[:space:]]*\(/) {
      compact = line
      gsub(/[[:space:]]/, "", compact)
      parameter_count = gsub(/\.SVT_PCIE_UI_TRANSMIT_BIT_CLOCK_MODE\(/, "&", compact)
      if (branch == "pipe") {
        fail("PIPE 分支不应设置 Serial bit-clock 参数，行 " NR)
      } else if (branch != "serial" || macro !~ /^PCIE_SVT_DECLARE_HDL_AGENT_X(4|8|16)$/) {
        fail("bit-clock 参数出现在预期 Serial 宏之外，行 " NR)
      } else {
        parameters[macro] += parameter_count
        if (parameter_count != 1 || index(compact, expected_parameter) == 0)
          fail(macro " 必须仅设置 " expected_parameter "，行 " NR)
      }
    }

    if (line !~ /\\[[:space:]]*$/)
      macro = ""
  }

  END {
    if (pipe_branches != 1 || serial_branches != 1)
      fail("必须识别到唯一的 PIPE/Serial 条件分支")
    for (i = 1; i <= 3; i++) {
      name = names[i]
      if (definitions[name] != 1)
        fail(name " 在 Serial 分支必须恰好定义一次")
      if (parameters[name] != 1)
        fail(name " 必须恰好设置一次发送 bit-clock 参数")
    }
    if (errors)
      exit 1
    print "SVT_SERIAL_CLOCK_CONTRACT_PASS serial_widths=4,8,16 transmit_bit_clock_mode=0 pipe_bit_clock_parameter=absent validation=static_only"
  }
' "$macro_file"
