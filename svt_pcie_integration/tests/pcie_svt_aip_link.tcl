# 所属层次：svt_pcie_integration/tests；通过 AIP Tcl 命令触发真实 RC/EP 建链。
# 依赖 VCS UCLI、AIP_CORE 指向本次编译使用的源码、pcie_svt_aip_link_test。
# Tcl 拥有命令次序和结果检查；SV wrapper 拥有 1ms 建链超时，UVM test 拥有 objection。
# 本脚本不 force PCIe 状态，不伪造 L0，不依赖发布 .so 的旧内嵌脚本版本。

source [file join $::env(AIP_CORE) dist aip_init.tcl]
puts "PAIR_TCL_BOOTSTRAP_DONE"

# 每次检查 result_id，防止 no-ack 后把上条命令的 status/result 当作建链成功。
# 只读取 bridge 握手寄存器，不访问 SVT 私有对象。
proc pair_require_ack {} {
    set actual_id [aip_parse_int [get aip_core_pkg::__tcl_result_id]]
    if {$actual_id != $::_aip_cmd_seq} {
        error "PAIR_LINK_FAIL: missing/stale ack expected=$::_aip_cmd_seq actual=$actual_id"
    }
}

set pair_trace 0
if {[info exists ::env(PCIE_AIP_TRACE)]} {
    set pair_trace $::env(PCIE_AIP_TRACE)
}
if {$pair_trace ni {0 1}} {
    error "PCIE_AIP_TRACE must be 0 or 1"
}

# 两个默认 50us 限制都显式处理：ack 给 5ms；AIP 无 activity watchdog 关闭，
# 因为 SVT LTSSM 活动不会自动喂它。wrapper 的独立 1ms 超时仍然有效。
set ::aip_ack_timeout_ns 5000000
set_cmd_watchdog ns=0
pair_require_ack
if {[aip_check_status] != 0} {
    error "PAIR_LINK_FAIL: watchdog setup: [aip_read_result]"
}

puts "PAIR_TCL_BEGIN trace=$pair_trace"
svt_pair_link_up trace=$pair_trace
pair_require_ack
set pair_status [aip_check_status]
set pair_result [aip_read_result]
puts "PAIR_TCL_RESULT status=$pair_status result=$pair_result"
if {$pair_status != 0 || ![string match "PAIR_LINK_L0*" $pair_result]} {
    error "PAIR_LINK_FAIL: $pair_result"
}
puts "PAIR_TCL_LINK_PASS"

# end_test 的 ack 会停在 bridge $stop；再 run 才完成 drop objection 和 UVM report。
# shell 门禁还须检查 UVM ERROR/FATAL 计数及 SV report marker，不能只 grep Tcl PASS。
end_test drain=100
pair_require_ack
run
