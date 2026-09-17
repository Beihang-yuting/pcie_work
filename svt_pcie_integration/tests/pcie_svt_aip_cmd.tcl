# 所属层次：tests；通过用户选择的命令名/seqr 执行真实双 SVT 双向访问。
# 依赖 AIP_CORE 源码 bootstrap 和专用 UVM test，脚本拥有命令次序/结果断言。
# SVT 内部产生发送时钟；脚本不 force 状态或访问内部 config，所有读写均走
# 新通用 sequence。SV observer 另行核验接收字段/计数/backing，避免仅凭日志通过。
# PCIE_AIP_EXPECT_TIMEOUT=1 为独立预期失败组：只使能 RC，要求建链超时
# 终止仿真；该分支不会执行正常双向 PASS/end_test，不与正常组共用结果。

source [file join $::env(AIP_CORE) dist aip_init.tcl]
puts "CMD_TCL_BOOTSTRAP_DONE"

# 每条命令必须有本次序号的 ack，不允许超时后复用上一条成功结果。
proc cmd_require_ack {} {
    set actual [aip_parse_int [get aip_core_pkg::__tcl_result_id]]
    if {$actual != $::_aip_cmd_seq} {
        error "AIP_CMD_FAIL: stale/missing ack expected=$::_aip_cmd_seq actual=$actual"
    }
}

# 执行合法命令并返回结果；失败立即终止脚本，最终 UVM report 亦会拒绝通过。
proc cmd_ok {args} {
    uplevel #0 $args
    cmd_require_ack
    set status [aip_check_status]
    set result [aip_read_result]
    puts "CMD_TCL_RESULT command=[lindex $args 0] status=$status result=$result"
    if {$status != 0} {error "AIP_CMD_FAIL: $args: $result"}
    return $result
}

# 读取结果中的地址增序字节流，不依赖格式化日志的大小写或整数 endian。
proc cmd_expect_data {result expected} {
    if {![regexp {(^| )data=([0-9a-fA-F]+)( |$)} $result unused before data after]} {
        error "AIP_CMD_FAIL: missing read data: $result"
    }
    if {[string tolower $data] ne [string tolower $expected]} {
        error "AIP_CMD_FAIL: data=$data expected=$expected result=$result"
    }
    if {![string match "COMPLETED cpl_status=SC*" $result]} {
        error "AIP_CMD_FAIL: read did not complete with SC: $result"
    }
}

# 错参应有明确非零状态/ERROR，且同一命令之后仍可恢复；是否无发包由接收端
# observer 的 checkpoint/rejected 配对检查证明，不能只相信错误文本。
proc cmd_reject {args} {
    uplevel #0 $args
    cmd_require_ack
    set status [aip_check_status]
    set result [aip_read_result]
    if {$status == 0 || ![string match "ERROR*" $result]} {
        error "AIP_CMD_FAIL: expected rejection for $args, got status=$status result=$result"
    }
    puts "CMD_TCL_REJECT_PASS command=[lindex $args 0] result=$result"
    incr ::cmd_reject_count
}

# SV watchdog另有独立2ms上限；AIP activity并不跟踪PHY，因此关闭其默认50us限制。
set ::aip_ack_timeout_ns 5000000
cmd_ok set_cmd_watchdog ns=0
set ready [cmd_ok pair_check stage=setup]
if {![regexp {host_addr=(0x[0-9a-fA-F]+)} $ready unused ha] ||
    ![regexp {endpoint_addr=(0x[0-9a-fA-F]+)} $ready unused ea]} {
    error "AIP_CMD_FAIL: bad test address publication: $ready"
}

# 同一 binary 的独立失败门禁；setup 已确认复位等待完成且命令有 fresh ack。
# 此处故意不使用 cmd_ok：UVM_FATAL 在 bridge 写回结果前结束仿真，最后这条
# 命令本来就不应返回 ack。若它正常返回，无论 status 为何都不是预期行为。
set expect_timeout 0
if {[info exists ::env(PCIE_AIP_EXPECT_TIMEOUT)]} {
    set expect_timeout $::env(PCIE_AIP_EXPECT_TIMEOUT)
}
if {$expect_timeout ni {0 1}} {
    error "AIP_CMD_FAIL: PCIE_AIP_EXPECT_TIMEOUT must be 0 or 1"
}
if {$expect_timeout == 1} {
    puts "CMD_TCL_EXPECT_TIMEOUT_BEGIN timeout_ns=1000 ep_enabled=0"
    rc_link_up enable=1 wait_l0=1 timeout_ns=1000
    error "AIP_CMD_FAIL: expected PCIE_AIP_LINK_TIMEOUT but rc_link_up returned unexpectedly"
}

# 双主动端先使能RC，再使能EP并等待L0；最后对RC幂等写enable=1并确认状态。
cmd_ok rc_link_up enable=1 wait_l0=0 timeout_ns=1000000
cmd_ok ep_link_up enable=1 wait_l0=1 timeout_ns=1000000
cmd_ok rc_link_up enable=1 wait_l0=1 timeout_ns=1000000
puts "CMD_TCL_LINK_PASS"

# Config 读标识、写Command低半字、非连续BE写scratch；不改变SVT内部配置。
cmd_expect_data [cmd_ok rc_cfg_rd bdf=0x0100 offset=0 timeout_ns=100000] cdab3412
cmd_ok rc_cfg_wr bdf=0x0100 offset=4 data=0x00000007 first_be=0x3 timeout_ns=100000
# 初始化PCIe capability后Status[4]=1；BE=3不能误清高半字这个状态位。
cmd_expect_data [cmd_ok rc_cfg_rd bdf=0x0100 offset=4 timeout_ns=100000] 07001000
cmd_ok rc_cfg_wr bdf=0x0100 offset=0x100 data=0x11223344 timeout_ns=100000
cmd_ok rc_cfg_wr bdf=0x0100 offset=0x100 data=0xaabbccdd first_be=5 timeout_ns=100000
cmd_expect_data [cmd_ok rc_cfg_rd bdf=0x0100 offset=0x100 timeout_ns=100000] dd33bb11
puts "CMD_TCL_CFG_PASS"

# RC→EP：高于4GB地址，bytes非对齐自动BE，再raw显式BE，禁用字节必须保持。
cmd_ok rc_mem_wr addr=$ea bytes=16 data=000102030405060708090a0b0c0d0e0f mps_bytes=128 is_64bit=1
set ea1 [format 0x%llx [expr {$ea + 1}]]
cmd_ok rc_mem_wr addr=$ea1 bytes=5 data=a0a1a2a3a4
cmd_expect_data [cmd_ok rc_mem_rd addr=$ea bytes=16 mrrs_bytes=128 timeout_ns=100000] 00a0a1a2a3a4060708090a0b0c0d0e0f
cmd_ok rc_mem_wr addr=$ea length_dw=2 first_be=0xe last_be=3 data=1020304050607080 relaxed=1 no_snoop=1
cmd_expect_data [cmd_ok rc_mem_rd addr=$ea length_dw=2 first_be=0xe last_be=3 timeout_ns=100000] 2030405060
puts "CMD_TCL_RC_EP_PASS"

# EP→RC：同一通用seq绑定另一真实seqr，显式Requester ID，并检查Root真实backing。
cmd_ok ep_mem_wr addr=$ha bytes=16 data=c0c1c2c3c4c5c6c7c8c9cacbcccdcecf requester_id=0x0100 is_64bit=0
set ha2 [format 0x%llx [expr {$ha + 2}]]
cmd_ok ep_mem_wr addr=$ha2 bytes=5 data=d0d1d2d3d4 requester_id=0x0100
cmd_expect_data [cmd_ok ep_mem_rd addr=$ha bytes=16 requester_id=0x0100 timeout_ns=100000] c0c1d0d1d2d3d4c7c8c9cacbcccdcecf
cmd_ok ep_mem_wr addr=$ha length_dw=2 first_be=0xc last_be=0xf data=1122334455667788 requester_id=0x0100 relaxed=1 no_snoop=1
cmd_expect_data [cmd_ok ep_mem_rd addr=$ha length_dw=2 first_be=0xc last_be=0xf requester_id=0x0100 timeout_ns=100000] 334455667788
puts "CMD_TCL_EP_RC_PASS"

# 负参组全部在发包前拒绝：拼写/溢出/重复/互斥/边界/长度/协议/未知目标字段。
cmd_ok pair_check stage=checkpoint
set ::cmd_reject_count 0
cmd_reject rc_mem_wr addr=$ea length_dw=1 fisrtbe=0xf data=11223344
cmd_reject rc_mem_wr addr=$ea length_dw=1 first_be=0x1f data=11223344
cmd_reject rc_mem_rd addr=0x10000000000000000 bytes=4
cmd_reject rc_mem_rd addr=$ea addr=$ea bytes=4
cmd_reject rc_mem_rd addr=$ea bytes=4 length_dw=1
cmd_reject rc_mem_rd addr=0x0000000180004ffe bytes=4
cmd_reject rc_mem_wr addr=$ea bytes=4 data=1122
cmd_reject rc_mem_rd addr=-1 bytes=4
cmd_reject rc_mem_rd addr=0xGG bytes=4
cmd_reject rc_mem_rd addr=$ea length_dw=1 first_be=0xf last_be=0xf
cmd_reject rc_mem_rd addr=$ea bytes=4 first_be=0xf
cmd_reject rc_mem_rd addr=$ea bytes=4 rc=0
cmd_reject rc_mem_rd addr=$ea bytes=4 mrrs_bytes=12
cmd_reject rc_cfg_rd bdf=0x10000 offset=0
cmd_reject rc_cfg_rd bdf=0x0100 offset=1
cmd_reject rc_cfg_rd bdf=0x0100 offset=0x1000
cmd_reject rc_cfg_wr bdf=0x0100 offset=4 data=0x100000000
cmd_reject rc_cfg_rd bdf=0x0100 offset=0 last_be=0
cmd_reject rc_cfg_rd bdf=0x0100 offset=0 tc=1
cmd_reject ep_mem_rd addr=$ha bytes=4 requester_id=0x10000
cmd_reject rc_mem_rd addr=$ea bytes=4 is_64bit=0
cmd_reject rc_mem_rd addr=0x1000 bytes=4 is_64bit=1
cmd_reject rc_mem_rd bytes=4
cmd_reject rc_mem_rd addr bytes=4
cmd_reject rc_mem_rd addr= bytes=4
cmd_reject rc_mem_rd addr=$ea bytes=4 timeout_ns=0
cmd_reject rc_mem_rd addr=$ea bytes=4 timeout_ns=1000000001
cmd_reject rc_mem_rd addr=$ea bytes=4 tc=8
cmd_reject rc_mem_rd addr=$ea bytes=513 mrrs_bytes=512
cmd_reject rc_mem_wr addr=$ea bytes=257 mps_bytes=256 data=00
cmd_reject rc_mem_wr addr=$ea bytes=2 data=aag0
cmd_reject rc_cfg_rd bdf=0x0100 offset=0 first_be=0
cmd_reject rc_cfg_rd bdf=0x0100 offset=0 data=0
cmd_reject rc_link_up enable=0 wait_l0=1
cmd_ok pair_check stage=rejected
puts "CMD_TCL_REJECTIONS_PASS count=$::cmd_reject_count"

# 同名命令经历错参后仍能成功；多次调用不携带上一条的地址/BE/requester残留。
cmd_expect_data [cmd_ok rc_mem_rd addr=$ea bytes=16 timeout_ns=100000] 002030405060060708090a0b0c0d0e0f
cmd_expect_data [cmd_ok ep_mem_rd addr=$ha bytes=16 requester_id=0x0100 timeout_ns=100000] c0c1334455667788c8c9cacbcccdcecf
set final [cmd_ok pair_check stage=final]
if {![string match "SERIAL_BIDIR_PASS*" $final]} {error "AIP_CMD_FAIL: $final"}
puts "CMD_TCL_BIDIR_PASS"

# end_test的ack仍停在$stop；run让UVM完成report，runner同时检查最终report标志。
cmd_ok end_test drain=100
run
