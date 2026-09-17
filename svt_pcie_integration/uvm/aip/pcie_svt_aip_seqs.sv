//------------------------------------------------------------------------------
// uvm/aip 可选命令层：将用户注册的 Tcl 参数严格转换为单次 TL 或 SVT 建链请求。
// 用户先编译 AIP/TL/SVT package，再在命令定义所在作用域 include 本文件；
// 本文件不导入 AIP 源码、不注册命令、不选择 Host/RC，也不改变生产 backend。
// 每次命令独占 parser、sequence 和 TLP；sequencer/status 仅借用环境对象。
// 请求进入 driver 后不可通过 kill_seq/watchdog 安全取消：命令超时使用 FATAL，
// 避免遗留 tag/Completion 继续污染仿真。参数错误发生在 start_item 之前，
// 只返回 status=1；用户脚本可捕获并修正，不产生 UVM_ERROR。
//------------------------------------------------------------------------------

`ifdef PCIE_ENABLE_AIP_CMDS
`ifndef PCIE_SVT_AIP_SEQS_SV
`define PCIE_SVT_AIP_SEQS_SV

import uvm_pkg::*;
import aip_core_pkg::*;
import pcie_tl_pkg::*;
`include "import_pcie_svt_uvm_pkgs.svi"
`include "uvm_macros.svh"

// 与 AIP 的便捷 get_arg 不同，本层检查整条输入，防止拼错参数被静默忽略。
// values 只活到一次 sequence 返回；不保存全局当前地址、目标或用户配置。
class pcie_aip_args;
  string values[string];
  string error;

  // 判断参数分隔空白；不接受引号/花括号形式的复杂值，payload 使用纯 hex。
  static function bit whitespace(byte c);
    return (c == 8'h20 || c == 8'h09 || c == 8'h0a || c == 8'h0d);
  endfunction

  // 返回十六进制数字值，非法字符返回 -1，不依赖会接受前缀垃圾的 sscanf。
  static function int digit(byte c);
    if (c >= "0" && c <= "9") return c - "0";
    if (c >= "a" && c <= "f") return c - "a" + 10;
    if (c >= "A" && c <= "F") return c - "A" + 10;
    return -1;
  endfunction

  // 保存首个诊断，使后续检查不能覆盖真正起因；返回0便于短路调用。
  function bit reject(string message);
    if (error == "") error = message;
    return 0;
  endfunction

  // allowed 两端及参数间必须有一个空格。拒绝缺少等号、空值、重复及未知名。
  function bit parse(string raw, string allowed);
    int pos;
    values.delete();
    error = "";
    pos = 0;
    while (pos < raw.len()) begin
      int first_pos;
      int equal_pos;
      string token;
      string key;
      string value;
      bit known;
      while (pos < raw.len() && whitespace(raw.getc(pos))) pos++;
      if (pos == raw.len()) break;
      first_pos = pos;
      while (pos < raw.len() && !whitespace(raw.getc(pos))) pos++;
      token = raw.substr(first_pos, pos - 1);
      equal_pos = -1;
      for (int i = 0; i < token.len(); i++) begin
        if (token.getc(i) == "=") begin
          if (equal_pos != -1)
            return reject({"malformed parameter '", token, "': expected key=value"});
          equal_pos = i;
        end
      end
      if (equal_pos <= 0 || equal_pos == token.len() - 1)
        return reject({"malformed parameter '", token, "': expected nonempty key=value"});
      key = token.substr(0, equal_pos - 1);
      value = token.substr(equal_pos + 1, token.len() - 1);
      known = 0;
      for (int i = 0; i + key.len() + 2 <= allowed.len(); i++)
        if (allowed.substr(i, i + key.len() + 1) == {" ", key, " "}) known = 1;
      if (!known) begin
        if (key == "fisrtbe" || key == "firstbe")
          return reject({"unknown parameter '", key, "'; use first_be"});
        return reject({"unknown parameter '", key, "'"});
      end
      if (values.exists(key)) return reject({"duplicate parameter '", key, "'"});
      values[key] = value;
    end
    return 1;
  endfunction

  // 逐位无符号累加，在运算前检查溢出；只支持十进制和0x，不接受符号/X/Z。
  // 缺省参数使用显式默认值；required 参数不存在则失败，绝不默认为地址0。
  function bit number(string key, bit required, longint unsigned default_value,
                      longint unsigned maximum, output longint unsigned value);
    string token;
    int radix;
    int pos;
    value = default_value;
    if (!values.exists(key)) begin
      if (required) return reject({"missing parameter '", key, "'"});
      return 1;
    end
    token = values[key];
    radix = 10;
    pos = 0;
    value = 0;
    if (token.len() >= 2 && (token.substr(0, 1) == "0x" ||
                            token.substr(0, 1) == "0X")) begin
      radix = 16;
      pos = 2;
    end
    if (pos == token.len()) return reject({"parameter ", key, "=", token, " has no digits"});
    for (int index = pos; index < token.len(); index++) begin
      int d;
      d = digit(token.getc(index));
      if (d < 0 || d >= radix)
        return reject({"parameter ", key, "=", token, " is not an unsigned decimal/0x number"});
      if (longint'(d) > maximum || value > (maximum - longint'(d)) / radix)
        return reject($sformatf("parameter %s=%s exceeds maximum 0x%0h", key, token, maximum));
      value = value * radix + d;
    end
    return 1;
  endfunction

  // 写数据由地址递增的字节对构成；禁止0x、补零和截断，长度精确匹配调用者。
  function bit hex_data(int expected_bytes, output bit [7:0] payload[]);
    string token;
    payload = new[0];
    if (!values.exists("data")) return reject("missing parameter 'data'");
    token = values["data"];
    if (token.len() != expected_bytes * 2)
      return reject($sformatf("parameter data has %0d characters; expected %0d hex characters (%0d bytes)",
        token.len(), expected_bytes * 2, expected_bytes));
    payload = new[expected_bytes];
    foreach (payload[i]) begin
      int hi;
      int lo;
      hi = digit(token.getc(i * 2));
      lo = digit(token.getc(i * 2 + 1));
      if (hi < 0 || lo < 0) return reject("parameter data must contain hex byte pairs without 0x");
      payload[i] = (hi << 4) | lo;
    end
    return 1;
  endfunction
endclass

// 共用发送层保证 cfg/mem 使用同一套错误、句柄和总超时契约；具体类只描述
// 操作种类。所有命令在当前 get_sequencer() 上发送，不引用 env 层次路径。
class pcie_aip_access_seq extends uvm_sequence #(pcie_tl_tlp);
  pcie_tl_tlp issued_tlp;
  aip_cmd command;
  pcie_aip_args arguments;
  bit config_access;
  bit write_access;
  longint unsigned timeout_ns;
  string request_summary;
  int expected_read_bytes;

  // 构造阶段不取得外部资源；每次body重新取得AIP句柄并创建参数对象。
  function new(string name = "pcie_aip_access_seq");
    super.new(name);
  endfunction

  // 参数/绑定错误通过Tcl返回，不提升UVM错误计数；用于发送前可恢复失败。
  function void reject_command(string message);
    if (command != null) begin
      command.status = 1;
      command.result_out = {"ERROR ", get_name(), ": ", message, "; no request issued"};
    end
    `uvm_info("PCIE_AIP_REJECT", {get_name(), ": ", message, "; no request issued"}, UVM_NONE)
  endfunction

  // 显式初始化公共wire字段，避免rand字段未约束产生Poison/ATS/Prefix等副作用。
  // tag由生产driver管理；requester/TC/Attributes来自本次经过范围检查的参数。
  function bit common_fields(pcie_tl_tlp tlp);
    longint unsigned requester;
    longint unsigned traffic_class;
    longint unsigned relaxed;
    longint unsigned no_snoop;
    if (!arguments.number("requester_id", 0, 0, 'hffff, requester) ||
        !arguments.number("tc", 0, 0, 7, traffic_class) ||
        !arguments.number("relaxed", 0, 0, 1, relaxed) ||
        !arguments.number("no_snoop", 0, 0, 1, no_snoop) ||
        !arguments.number("timeout_ns", 0, 50000, 1_000_000_000, timeout_ns)) return 0;
    if (timeout_ns == 0) return arguments.reject("parameter timeout_ns must be positive");
    if (config_access && (traffic_class != 0 || relaxed != 0 || no_snoop != 0))
      return arguments.reject("Configuration requests require tc=0 relaxed=0 no_snoop=0");
    tlp.requester_id = requester[15:0];
    tlp.tc = traffic_class[2:0];
    tlp.attr = {no_snoop[0], 1'b0, relaxed[0]};
    tlp.th = 0;
    tlp.td = 0;
    tlp.ep_bit = 0;
    tlp.at = 0;
    tlp.tag = 0;
    tlp.inject_ecrc_err = 0;
    tlp.inject_lcrc_err = 0;
    tlp.inject_poisoned = 0;
    tlp.violate_ordering = 0;
    tlp.field_bitmask = 0;
    tlp.constraint_mode_sel = CONSTRAINT_LEGAL;
    tlp.wire_error_materialized = 0;
    tlp.prefixes.delete();
    tlp.has_prefix = 0;
    tlp.expected_cpl_status = CPL_STATUS_SC;
    tlp.rb_data.delete();
    tlp.rb_status = CPL_STATUS_SC;
    tlp.rb_done = 0;
    return 1;
  endfunction

  // 配置空间仅支持一个DWORD；offset是字节偏移，data数值按PCIe小端拆字节。
  // BE非零即可（Config允许不连续），last_be/data-on-read等由白名单拒绝。
  function bit prepare_cfg();
    pcie_tl_cfg_tlp tlp;
    longint unsigned bdf;
    longint unsigned offset;
    longint unsigned first_be;
    longint unsigned type1;
    longint unsigned data;
    string allowed;
    allowed = " bdf offset first_be type1 requester_id tc relaxed no_snoop timeout_ns ";
    if (write_access) allowed = {allowed, "data "};
    if (!arguments.parse(command.args_in, allowed) ||
        !arguments.number("bdf", 1, 0, 'hffff, bdf) ||
        !arguments.number("offset", 1, 0, 'hffc, offset) ||
        !arguments.number("first_be", 0, 15, 15, first_be) ||
        !arguments.number("type1", 0, 0, 1, type1)) return 0;
    if ((offset & 3) != 0) return arguments.reject("parameter offset must be DWORD aligned");
    if (first_be == 0) return arguments.reject("parameter first_be must be nonzero");
    if (write_access && !arguments.number("data", 1, 0, 'hffffffff, data)) return 0;
    tlp = pcie_tl_cfg_tlp::type_id::create("aip_cfg_request");
    if (tlp == null) return arguments.reject("factory returned null Configuration TLP");
    if (!common_fields(tlp)) return 0;
    tlp.kind = write_access ? (type1 ? TLP_CFG_WR1 : TLP_CFG_WR0) :
                              (type1 ? TLP_CFG_RD1 : TLP_CFG_RD0);
    tlp.type_f = type1 ? TLP_TYPE_CFG_RD1 : TLP_TYPE_CFG_RD0;
    tlp.fmt = write_access ? FMT_3DW_WITH_DATA : FMT_3DW_NO_DATA;
    tlp.length = 1;
    tlp.completer_id = bdf[15:0];
    tlp.reg_num = offset[11:2];
    tlp.first_be = first_be[3:0];
    tlp.payload = new[write_access ? 4 : 0];
    foreach (tlp.payload[i]) tlp.payload[i] = data >> (8 * i);
    expected_read_bytes = write_access ? 0 : 4;
    request_summary = $sformatf("bdf=0x%04h offset=0x%03h first_be=0x%h type1=%0d requester_id=0x%04h",
      tlp.completer_id, offset[11:0], tlp.first_be, type1, tlp.requester_id);
    issued_tlp = tlp;
    return 1;
  endfunction

  // MPS/MRRS只限制本次命令，不配置链路；只接受PCIe规定的六档值。
  function bit transfer_limit(longint unsigned value);
    return value inside {128, 256, 512, 1024, 2048, 4096};
  endfunction

  // 内存请求分bytes和原始DWORD两种互斥形式。校验按wire跨度计算4KB和
  // MPS/MRRS，不用使能字节数冒充TLP长度；4096B编码为length=0而非空包。
  function bit prepare_mem();
    pcie_tl_mem_tlp tlp;
    longint unsigned addr;
    longint unsigned byte_len;
    longint unsigned dw_len;
    longint unsigned first_be;
    longint unsigned last_be;
    longint unsigned is_64bit;
    longint unsigned mps;
    longint unsigned mrrs;
    bit [63:0] wire_addr;
    int wire_bytes;
    int lane_offset;
    bit bytes_mode;
    bit [7:0] input_data[];
    string allowed;
    allowed = " addr bytes length_dw first_be last_be is_64bit requester_id tc relaxed no_snoop timeout_ns mps_bytes mrrs_bytes ";
    if (write_access) allowed = {allowed, "data "};
    if (!arguments.parse(command.args_in, allowed) ||
        !arguments.number("addr", 1, 0, 64'hffffffffffffffff, addr) ||
        !arguments.number("mps_bytes", 0, 256, 4096, mps) ||
        !arguments.number("mrrs_bytes", 0, 512, 4096, mrrs)) return 0;
    if (!transfer_limit(mps) || !transfer_limit(mrrs))
      return arguments.reject("mps_bytes/mrrs_bytes must be 128,256,512,1024,2048,4096");
    if (arguments.values.exists("bytes") == arguments.values.exists("length_dw"))
      return arguments.reject("exactly one of bytes and length_dw is required");
    bytes_mode = arguments.values.exists("bytes");
    lane_offset = addr[1:0];
    wire_addr = {addr[63:2], 2'b00};
    // 合法请求的头格式由地址范围决定：低于4GB使用3DW，其他使用4DW。
    // is_64bit仅用于显式核对格式，不提供强制生成异常头的入口；既禁止
    // 3DW截断高地址，也避免低地址4DW触发SVT的PCIe 2.2.4.1格式检查。
    if (!arguments.number("is_64bit", 0, addr[63:32] != 0, 1, is_64bit)) return 0;
    if (is_64bit == 0 && addr[63:32] != 0)
      return arguments.reject("is_64bit=0 cannot represent addr above 32 bits");
    if (is_64bit == 1 && addr[63:32] == 0)
      return arguments.reject("is_64bit=1 requires addr >= 0x100000000; addresses below 4GB must use a 3DW header (is_64bit=0)");
    if (bytes_mode) begin
      if (arguments.values.exists("first_be") || arguments.values.exists("last_be"))
        return arguments.reject("bytes mode derives first_be/last_be; do not specify either BE");
      if (!arguments.number("bytes", 1, 0, 4096, byte_len)) return 0;
      if (byte_len == 0) return arguments.reject("parameter bytes must be positive");
      dw_len = (lane_offset + byte_len + 3) / 4;
      first_be = 0;
      last_be = 0;
      for (int i = 0; i < 4; i++) begin
        if (i >= lane_offset && i < lane_offset + byte_len) first_be |= 1 << i;
        if (dw_len > 1 && (dw_len - 1) * 4 + i < lane_offset + byte_len) last_be |= 1 << i;
      end
    end else begin
      if (lane_offset != 0) return arguments.reject("length_dw mode requires DWORD aligned addr");
      if (!arguments.number("length_dw", 1, 0, 1024, dw_len)) return 0;
      if (dw_len == 0) return arguments.reject("parameter length_dw must be 1..1024 (not encoded zero)");
      if (!arguments.number("first_be", 0, 15, 15, first_be) ||
          !arguments.number("last_be", 0, dw_len == 1 ? 0 : 15, 15, last_be)) return 0;
      if (dw_len == 1) begin
        if (last_be != 0) return arguments.reject("length_dw=1 requires last_be=0");
        if (!(first_be inside {1,2,3,4,6,7,8,12,14,15}))
          return arguments.reject("single DWORD supports only nonzero contiguous first_be");
      end else begin
        if (first_be == 0 || last_be == 0)
          return arguments.reject("multiple DWORDs require nonzero first_be and last_be");
        // PCIe允许QW对齐的2DW使用不连续BE；其他多DW请求首尾必须连续。
        if (!(dw_len == 2 && addr[2] == 0) &&
            (!(first_be inside {8,12,14,15}) || !(last_be inside {1,3,7,15})))
          return arguments.reject("multi-DWORD BE must be contiguous to inner DWORDs (except QW-aligned 2DW)");
      end
      byte_len = dw_len * 4;
    end
    wire_bytes = dw_len * 4;
    if (dw_len > 1024) return arguments.reject("wire length exceeds 1024 DWORDs");
    if (wire_addr > 64'hffffffffffffffff - (wire_bytes - 1))
      return arguments.reject("addr plus wire span overflows 64-bit address space");
    if (int'(wire_addr[11:0]) + wire_bytes > 4096)
      return arguments.reject("request wire span crosses 4KB boundary; automatic splitting is not supported");
    if (write_access && wire_bytes > mps)
      return arguments.reject("request wire span exceeds mps_bytes; automatic splitting is not supported");
    if (!write_access && wire_bytes > mrrs)
      return arguments.reject("request wire span exceeds mrrs_bytes; automatic splitting is not supported");
    if (write_access && !arguments.hex_data(int'(byte_len), input_data)) return 0;
    tlp = pcie_tl_mem_tlp::type_id::create("aip_mem_request");
    if (tlp == null) return arguments.reject("factory returned null Memory TLP");
    if (!common_fields(tlp)) return 0;
    tlp.kind = write_access ? TLP_MEM_WR : TLP_MEM_RD;
    tlp.type_f = write_access ? TLP_TYPE_MEM_WR : TLP_TYPE_MEM_RD;
    tlp.is_64bit = is_64bit[0];
    tlp.fmt = write_access ? (tlp.is_64bit ? FMT_4DW_WITH_DATA : FMT_3DW_WITH_DATA) :
                             (tlp.is_64bit ? FMT_4DW_NO_DATA : FMT_3DW_NO_DATA);
    tlp.addr = wire_addr;
    tlp.length = dw_len[9:0];
    tlp.first_be = first_be[3:0];
    tlp.last_be = last_be[3:0];
    tlp.cfg_mps_bytes = int'(mps);
    tlp.cfg_mrrs_bytes = int'(mrrs);
    tlp.payload = new[write_access ? wire_bytes : 0];
    // bytes模式只在被禁止的padding lane填零，绝不替用户补齐缺失data。
    foreach (input_data[i]) tlp.payload[lane_offset + i] = input_data[i];
    expected_read_bytes = write_access ? 0 : pcie_tl_mem_valid_bytes(tlp);
    request_summary = $sformatf("addr=0x%016h input_addr=0x%016h length_dw=%0d first_be=0x%h last_be=0x%h wire_bytes=%0d is_64bit=%0b requester_id=0x%04h tc=%0d relaxed=%0b no_snoop=%0b",
      tlp.addr, addr, dw_len, tlp.first_be, tlp.last_be, wire_bytes,
      tlp.is_64bit, tlp.requester_id, tlp.tc, tlp.attr[0], tlp.attr[2]);
    issued_tlp = tlp;
    return 1;
  endfunction

  // 完整期限覆盖仲裁、driver发送和Completion等待。超时不kill后继续，
  // 而是FATAL终止；AIP外层watchdog必须关闭，禁止对本命令调用kill_seq。
  virtual task body();
    uvm_sequencer #(pcie_tl_tlp) typed_sequencer;
    bit finished;
    string read_hex;
    bit [31:0] read_value;
    issued_tlp = null;
    command = aip_cmd::get_handle(get_name());
    arguments = new();
    if (command == null) begin
      reject_command("AIP command handle is missing; register with aip_cmd_user_seq");
      return;
    end
    command.status = 0;
    command.result_out = "";
    if (!$cast(typed_sequencer, get_sequencer()) || typed_sequencer == null) begin
      reject_command("bound sequencer must be uvm_sequencer#(pcie_tl_tlp)");
      return;
    end
    if (!(config_access ? prepare_cfg() : prepare_mem())) begin
      issued_tlp = null;
      reject_command(arguments.error);
      return;
    end
    finished = 0;
    fork : request_deadline
      begin
        start_item(issued_tlp);
        finish_item(issued_tlp);
        if (issued_tlp.requires_completion()) wait (issued_tlp.rb_done);
        finished = 1;
      end
      begin
        #(timeout_ns * 1ns);
        if (!finished) begin
          command.status = 1;
          command.result_out = {"ERROR ", get_name(), ": transaction timeout; pending state is not cancelled; simulation must stop"};
          `uvm_fatal("PCIE_AIP_TIMEOUT", {command.result_out, " ", request_summary})
        end
      end
    join_any
    disable request_deadline;
    if (!finished) return;
    if (!issued_tlp.requires_completion()) begin
      command.result_out = {"POSTED_SENT ", request_summary};
      return;
    end
    if (issued_tlp.rb_status != CPL_STATUS_SC) begin
      command.status = 1;
      command.result_out = $sformatf("COMPLETION_ERROR cpl_status=%s %s",
        issued_tlp.rb_status.name(), request_summary);
      return;
    end
    if (!write_access && issued_tlp.rb_data.size() != expected_read_bytes) begin
      command.status = 1;
      command.result_out = $sformatf("COMPLETION_ERROR cpl_status=SC read_bytes=%0d expected_bytes=%0d %s",
        issued_tlp.rb_data.size(), expected_read_bytes, request_summary);
      return;
    end
    read_hex = "";
    read_value = 0;
    foreach (issued_tlp.rb_data[i]) begin
      read_hex = {read_hex, $sformatf("%02h", issued_tlp.rb_data[i])};
      if (i < 4) read_value |= 32'(issued_tlp.rb_data[i]) << (8 * i);
    end
    command.result_out = {"COMPLETED cpl_status=SC ", request_summary};
    if (!write_access) command.result_out = {command.result_out, " data=", read_hex};
    if (config_access && !write_access)
      command.result_out = {command.result_out, $sformatf(" value=0x%08h", read_value)};
  endtask
endclass

// 四个可重复注册的公开seq类型只固定操作语义，不持有用户的目标句柄。
class pcie_aip_cfg_rd_seq extends pcie_aip_access_seq;
  `uvm_object_utils(pcie_aip_cfg_rd_seq)
  // 指定配置读；公共body负责参数、类型检查、发送和结果回写。
  function new(string name = "pcie_aip_cfg_rd_seq");
    super.new(name);
    config_access = 1;
    write_access = 0;
  endfunction
endclass

class pcie_aip_cfg_wr_seq extends pcie_aip_access_seq;
  `uvm_object_utils(pcie_aip_cfg_wr_seq)
  // 指定配置写；只改变类型，不自动注册或猜测目标RC。
  function new(string name = "pcie_aip_cfg_wr_seq");
    super.new(name);
    config_access = 1;
    write_access = 1;
  endfunction
endclass

class pcie_aip_mem_rd_seq extends pcie_aip_access_seq;
  `uvm_object_utils(pcie_aip_mem_rd_seq)
  // 指定内存读；读结果是按地址递增的使能字节，不包含BE禁用lane。
  function new(string name = "pcie_aip_mem_rd_seq");
    super.new(name);
    config_access = 0;
    write_access = 0;
  endfunction
endclass

class pcie_aip_mem_wr_seq extends pcie_aip_access_seq;
  `uvm_object_utils(pcie_aip_mem_wr_seq)
  // 指定posted内存写；成功仅证明driver发送完毕，不声明DUT存储校验成功。
  function new(string name = "pcie_aip_mem_wr_seq");
    super.new(name);
    config_access = 0;
    write_access = 1;
  endfunction
endclass

// DL sequencer本身不足以判断L0，所以用户在env建立后显式绑定同一agent的
// status。静态表按UVM实例ID索引，只借用句柄，仿真期间不拥有/销毁agent。
class pcie_aip_link_binding;
  local static svt_pcie_device_agent agents[int];
  local static svt_pcie_device_status statuses[int];

  // 验证公开层次和status归属后绑定；失败返回0并打印可定位诊断，不创建对象。
  static function bit bind_agent(svt_pcie_device_agent agent,
                                 svt_pcie_device_status status);
    uvm_sequencer_base dl_sqr;
    if (agent == null || status == null) begin
      `uvm_info("PCIE_AIP_BIND", "agent/status is null", UVM_NONE)
      return 0;
    end
    if (agent.virt_seqr == null) begin
      `uvm_info("PCIE_AIP_BIND", {agent.get_full_name(), ": device virtual sequencer is null"}, UVM_NONE)
      return 0;
    end
    if (agent.virt_seqr.pcie_virt_seqr == null) begin
      `uvm_info("PCIE_AIP_BIND", {agent.get_full_name(), ": PCIe virtual sequencer is null"}, UVM_NONE)
      return 0;
    end
    dl_sqr = agent.virt_seqr.pcie_virt_seqr.dl_seqr;
    if (dl_sqr == null) begin
      `uvm_info("PCIE_AIP_BIND", {agent.get_full_name(), ": DL sequencer is null"}, UVM_NONE)
      return 0;
    end
    if (status.pcie_status == null) begin
      `uvm_info("PCIE_AIP_BIND", {agent.get_full_name(), ": PCIe status is null"}, UVM_NONE)
      return 0;
    end
    if (status.pcie_status.pl_status == null) begin
      `uvm_info("PCIE_AIP_BIND", {agent.get_full_name(), ": PL status is null"}, UVM_NONE)
      return 0;
    end
    if (agent.status != status) begin
      `uvm_info("PCIE_AIP_BIND", "status does not belong to the supplied agent", UVM_NONE)
      return 0;
    end
    agents[dl_sqr.get_inst_id()] = agent;
    statuses[dl_sqr.get_inst_id()] = status;
    return 1;
  endfunction

  // 仅提供按实际注册sequencer的只读查询，不支持Host编号或默认fallback。
  static function svt_pcie_device_status lookup(uvm_sequencer_base sequencer);
    if (sequencer == null) return null;
    if (!statuses.exists(sequencer.get_inst_id())) return null;
    return statuses[sequencer.get_inst_id()];
  endfunction
endclass

// 建链命令仅控制被注册的一个SVT端；真实DUT的PHY参考钟/复位/LTSSM仍由
// 用户环境负责。双SVT对打时需两端各注册一次，先enable-only再等待L0。
class pcie_aip_link_up_seq extends uvm_sequence #(uvm_sequence_item);
  `uvm_object_utils(pcie_aip_link_up_seq)

  // 构造时不选择agent；目标只由用户传给aip_cmd_user_seq的DL sequencer决定。
  function new(string name = "pcie_aip_link_up_seq");
    super.new(name);
  endfunction

  // enable默认1；wait_l0默认1。关闭链路时必须显式wait_l0=0，避免矛盾语义。
  // 同一总期限覆盖官方服务seq和L0等待，不负责等待/释放复位或生成时钟。
  virtual task body();
    aip_cmd command;
    pcie_aip_args arguments;
    svt_pcie_device_status status;
    svt_pcie_dl_service_set_link_en_sequence link_en;
    longint unsigned enable;
    longint unsigned wait_l0;
    longint unsigned timeout_ns;
    bit finished;
    command = aip_cmd::get_handle(get_name());
    if (command == null) begin
      `uvm_info("PCIE_AIP_REJECT", {get_name(), ": missing AIP command handle"}, UVM_NONE)
      return;
    end
    command.status = 0;
    command.result_out = "";
    arguments = new();
    status = pcie_aip_link_binding::lookup(get_sequencer());
    if (!arguments.parse(command.args_in, " enable wait_l0 timeout_ns ") ||
        !arguments.number("enable", 0, 1, 1, enable) ||
        !arguments.number("wait_l0", 0, 1, 1, wait_l0) ||
        !arguments.number("timeout_ns", 0, 1_000_000, 1_000_000_000, timeout_ns)) begin
      command.status = 1;
      command.result_out = {"ERROR ", get_name(), ": ", arguments.error, "; no request issued"};
      return;
    end
    if (status == null || timeout_ns == 0 || (enable == 0 && wait_l0 != 0)) begin
      command.status = 1;
      command.result_out = {"ERROR ", get_name(), ": missing DL/status binding, zero timeout, or enable=0 requires wait_l0=0; no request issued"};
      return;
    end
    link_en = svt_pcie_dl_service_set_link_en_sequence::type_id::create("aip_link_enable");
    if (link_en == null) begin
      command.status = 1;
      command.result_out = {"ERROR ", get_name(), ": factory returned null link-enable sequence; no request issued"};
      return;
    end
    link_en.enable = enable[0];
    finished = 0;
    fork : link_deadline
      begin
        link_en.start(get_sequencer());
        if (wait_l0)
          wait (status.pcie_status.pl_status.link_up == 1'b1 &&
                status.pcie_status.pl_status.ltssm_state == svt_pcie_types::L0);
        finished = 1;
      end
      begin
        #(timeout_ns * 1ns);
        if (!finished) begin
          command.status = 1;
          command.result_out = $sformatf("ERROR %s: link timeout link_up=%0b ltssm=%0d; simulation must stop",
            get_name(), status.pcie_status.pl_status.link_up, status.pcie_status.pl_status.ltssm_state);
          `uvm_fatal("PCIE_AIP_LINK_TIMEOUT", command.result_out)
        end
      end
    join_any
    disable link_deadline;
    if (finished)
      command.result_out = $sformatf("%s enable=%0d wait_l0=%0d link_up=%0b ltssm=%0d sequencer=%s",
        wait_l0 ? "LINK_L0" : "LINK_ENABLE_SENT", enable, wait_l0,
        status.pcie_status.pl_status.link_up, status.pcie_status.pl_status.ltssm_state,
        get_sequencer().get_full_name());
  endtask
endclass

`endif // PCIE_SVT_AIP_SEQS_SV
`endif // PCIE_ENABLE_AIP_CMDS
