//------------------------------------------------------------------------------
// Partial byte-enable（部分字节使能）回归测试。
//
// 该文件属于 pcie_tl_vip/tests，随 TL-only filelist 编译，依赖
// pcie_tl_pkg 与 host_mem_pkg。测试刻意构造 first/last BE 少于四字节的
// 单 DWORD 请求，并且不搭建完整 env：responder 的内存访问、read-back
// 计数和 wire codec 各自独立检查，避免正常 loopback 通路把越界访问等
// 边界违规掩盖掉。文件内的 probe/内存对象由本测试创建并持有，生命周期
// 与单次 run_phase 相同。
//------------------------------------------------------------------------------

import uvm_pkg::*;
import pcie_tl_pkg::*;
import host_mem_pkg::*;
`include "uvm_macros.svh"

// 微型内存探针。继承生产版 manager 的 API，但重写读操作，让测试能精确
// 证明 responder 请求了哪些地址/长度；返回确定性字节也让 payload 检查
// 更易读。之所以需要这一层：真实 manager 会把越界读淹没在正常数据里，
// 而这里的记录队列能把每次访问暴露给断言。
class pcie_tl_partial_be_mem extends host_mem_manager;
    `uvm_object_utils(pcie_tl_partial_be_mem)

    int read_count;
    int read_sizes[$];
    bit [63:0] read_addrs[$];

    // 构造函数：仅透传名字，无额外初始化。
    function new(string name = "pcie_tl_partial_be_mem");
        super.new(name);
    endfunction

    // 记录一次读访问（地址与长度入队），并返回由地址低位推导的确定性
    // 数据。无失败路径：任意地址都会返回 size 字节。
    virtual function void read_mem(bit [63:0] addr, int unsigned size,
                                   ref byte data[], input string file = "",
                                   input int line = 0);
        read_count++;
        read_addrs.push_back(addr);
        read_sizes.push_back(size);
        data = new[size];
        foreach (data[i])
            data[i] = byte'(8'hA0 + ((addr + i) & 8'h3F));
    endfunction
endclass

// 在不经过正常 adapter 的情况下捕获 responder 生成的 Completion。生产
// 版读处理路径以 virtual 方式调用 send_tlp()，因此该探针能在任何
// transport 编码之前拿到原始 CplD 对象——这正是检查 byte_count/
// lower_addr 边界所需要的观察点。
class pcie_tl_partial_be_ep_probe extends pcie_tl_ep_driver;
    `uvm_component_utils(pcie_tl_partial_be_ep_probe)

    pcie_tl_cpl_tlp completions[$];

    // 构造函数：仅透传参数，无额外初始化。
    function new(string name = "pcie_tl_partial_be_ep_probe",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // 重写发送出口：把 CplD 截留进 completions 队列供断言检查，非
    // Completion 的 TLP 直接丢弃（本测试不关心）。
    virtual task send_tlp(pcie_tl_tlp tlp);
        pcie_tl_cpl_tlp cpl;
        if ($cast(cpl, tlp))
            completions.push_back(cpl);
    endtask

    // 直接驱动一次 EP 侧内存读处理（绕过 sequencer），req 为待处理的
    // Memory Read 请求；产生的 Completion 经 send_tlp() 进入队列。
    task invoke_read(pcie_tl_mem_tlp req);
        handle_mem_read(req);
    endtask

    // 把 req 登记为待回读状态并清空历史计数，模拟 driver 发出请求后的
    // read-back 初始状态；副作用：覆盖同 tag 的旧登记。
    function void seed_readback(pcie_tl_tlp req);
        req.rb_data.delete();
        req.rb_done = 1'b0;
        req.rb_status = CPL_STATUS_SC;
        rb_outstanding[req.tag] = req;
        rb_recv.delete(req.tag);
        rb_total.delete(req.tag);
        rb_wire.delete(req.tag);
    endfunction

    // 把一个分片 CplD 折叠进 TLM read-back 计数，用于逐片检查
    // rb_done/rb_data 的推进是否按有效字节数收敛。
    function void fold_completion(pcie_tl_cpl_tlp cpl);
        rb_note_completion(cpl);
    endfunction

    // 空 run_phase：探针不自主运行，所有动作由测试显式调用。
    task run_phase(uvm_phase phase);
    endtask
endclass

// RC 侧探针，作用与 EP 探针相同：截留 Completion、绕过 sequencer 直接
// 驱动请求处理，用于验证 RC responder 的 partial-BE 行为。
class pcie_tl_partial_be_rc_probe extends pcie_tl_rc_driver;
    `uvm_component_utils(pcie_tl_partial_be_rc_probe)

    pcie_tl_cpl_tlp completions[$];

    // 构造函数：仅透传参数，无额外初始化。
    function new(string name = "pcie_tl_partial_be_rc_probe",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // 重写发送出口：截留 CplD 进队列，其余 TLP 丢弃。
    virtual task send_tlp(pcie_tl_tlp tlp);
        pcie_tl_cpl_tlp cpl;
        if ($cast(cpl, tlp))
            completions.push_back(cpl);
    endtask

    // 直接驱动一次 RC 侧请求处理（绕过 sequencer）。
    task invoke_read(pcie_tl_mem_tlp req);
        handle_request(req);
    endtask

    // 空 run_phase：探针不自主运行。
    task run_phase(uvm_phase phase);
    endtask
endclass

// 回归测试主体：按 run_phase 中的顺序依次执行七组独立检查，覆盖
// EP/RC responder 边界访问、真实 host_mem 边界、read-back registry、
// codec 填充、RCB 分片和分片回读生命周期。
class pcie_tl_partial_be_regression_test extends uvm_test;
    `uvm_component_utils(pcie_tl_partial_be_regression_test)

    pcie_tl_partial_be_ep_probe ep_probe;
    pcie_tl_partial_be_rc_probe rc_probe;
    pcie_tl_partial_be_mem ep_mem;
    pcie_tl_partial_be_mem rc_mem;
    host_mem_manager ep_real_mem;
    host_mem_manager rc_real_mem;

    // 构造函数：仅透传参数。
    function new(string name = "pcie_tl_partial_be_regression_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // 创建两个探针和两个记录型内存；真实 host_mem manager 在
    // check_real_host_boundary() 内按需创建。
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ep_probe = pcie_tl_partial_be_ep_probe::type_id::create("ep_probe", this);
        rc_probe = pcie_tl_partial_be_rc_probe::type_id::create("rc_probe", this);
        ep_mem = pcie_tl_partial_be_mem::type_id::create("ep_mem");
        rc_mem = pcie_tl_partial_be_mem::type_id::create("rc_mem");
    endfunction

    // 构造一个 3DW Memory Read TLP。输入为地址/DW 长度/首末 BE/tag，
    // requester_id 固定为 16'h0020；返回新建对象，不注册回读。
    function pcie_tl_mem_tlp make_read(string name, bit [63:0] addr,
                                       bit [9:0] length,
                                       bit [3:0] first_be, bit [3:0] last_be,
                                       bit [9:0] tag);
        pcie_tl_mem_tlp req;
        req = pcie_tl_mem_tlp::type_id::create(name);
        req.kind = TLP_MEM_RD;
        req.type_f = TLP_TYPE_MEM_RD;
        req.fmt = FMT_3DW_NO_DATA;
        req.addr = addr;
        req.length = length;
        req.first_be = first_be;
        req.last_be = last_be;
        req.requester_id = 16'h0020;
        req.tag = tag;
        req.is_64bit = 1'b0;
        return req;
    endfunction

    // 校验单个 CplD 的 byte_count/lower_addr/payload 长度，并交叉检查
    // payload 与 length 字段一致（DWORD 填充表示）。cpl 为 null 或任一
    // 字段不符即报 UVM_ERROR，label 用于定位是哪一组检查。
    function void check_cpl(string label, pcie_tl_cpl_tlp cpl,
                            int expected_byte_count,
                            bit [6:0] expected_lower,
                            int expected_payload_bytes);
        if (cpl == null) begin
            `uvm_error("PARTIAL_BE", {label, ": missing Completion"})
            return;
        end
        if (cpl.byte_count != expected_byte_count[11:0])
            `uvm_error("PARTIAL_BE", $sformatf(
                "%s: byte_count=%0d expected=%0d", label,
                cpl.byte_count, expected_byte_count))
        if (cpl.lower_addr != expected_lower)
            `uvm_error("PARTIAL_BE", $sformatf(
                "%s: lower_addr=0x%02h expected=0x%02h", label,
                cpl.lower_addr, expected_lower))
        // transport 表示是按 DWORD 填充的。这个断言单独抓一类 bug：
        // 分片恰好结束在 RCB 边界时 length 与 payload 变得不一致。
        if (cpl.payload.size() != expected_payload_bytes)
            `uvm_error("PARTIAL_BE", $sformatf(
                "%s: payload=%0d expected=%0d", label,
                cpl.payload.size(), expected_payload_bytes))
        if (cpl.payload.size() != (((cpl.length == 0) ? 1024 : cpl.length) * 4))
            `uvm_error("PARTIAL_BE", $sformatf(
                "%s: payload=%0d disagrees with length=%0d DW", label,
                cpl.payload.size(), (cpl.length == 0) ? 1024 : cpl.length))
    endfunction

    // EP responder 精确边界检查：2 字节使能的单 DW 读必须只对内存发出
    // 两次 1 字节读（禁用 lane 不得访问），且 CplD 禁用 lane 补零。
    task check_ep_exact_boundary();
        pcie_tl_mem_tlp req;
        ep_probe.completions.delete();
        ep_probe.mps_bytes = 128;
        ep_probe.rcb_bytes = 64;
        ep_probe.mem = ep_mem;
        ep_probe.use_unified_mem = 1'b1;
        req = make_read("ep_exact_two_byte_read", 64'h0000_1000,
                        10'd1, 4'h3, 4'h0, 10'h11);
        ep_probe.invoke_read(req);
        if (ep_mem.read_count != 2)
            `uvm_error("PARTIAL_BE", $sformatf(
                "EP responder issued %0d memory reads, expected two enabled lanes",
                ep_mem.read_count))
        foreach (ep_mem.read_sizes[i]) begin
            if (ep_mem.read_sizes[i] != 1)
                `uvm_error("PARTIAL_BE", $sformatf(
                    "EP read[%0d] requested %0d bytes across an exact 2-byte allocation",
                    i, ep_mem.read_sizes[i]))
        end
        if (ep_probe.completions.size() != 1)
            `uvm_error("PARTIAL_BE", $sformatf(
                "EP generated %0d completions, expected one", ep_probe.completions.size()))
        else begin
            check_cpl("EP exact-boundary", ep_probe.completions[0], 2, 7'h00, 4);
            if (ep_probe.completions[0].payload[0] !== 8'hA0 ||
                ep_probe.completions[0].payload[1] !== 8'hA1 ||
                ep_probe.completions[0].payload[2] !== 8'h00 ||
                ep_probe.completions[0].payload[3] !== 8'h00)
                `uvm_error("PARTIAL_BE", "EP disabled lanes were not zero-filled")
        end
    endtask

    // RC responder 精确边界检查：与 EP 同样的 2 字节用例，验证 RC 侧
    // auto response 路径也按 lane 粒度访问内存。
    task check_rc_exact_boundary();
        pcie_tl_mem_tlp req;
        rc_probe.completions.delete();
        rc_probe.mps_bytes = 128;
        rc_probe.rcb_bytes = 64;
        rc_probe.mem = rc_mem;
        rc_probe.use_unified_mem = 1'b1;
        rc_probe.auto_response_enable = 1'b1;
        req = make_read("rc_exact_two_byte_read", 64'h0000_2000,
                        10'd1, 4'h3, 4'h0, 10'h12);
        rc_probe.invoke_read(req);
        if (rc_mem.read_count != 2)
            `uvm_error("PARTIAL_BE", $sformatf(
                "RC responder issued %0d memory reads, expected two enabled lanes",
                rc_mem.read_count))
        foreach (rc_mem.read_sizes[i]) begin
            if (rc_mem.read_sizes[i] != 1)
                `uvm_error("PARTIAL_BE", $sformatf(
                    "RC read[%0d] requested %0d bytes across an exact 2-byte allocation",
                    i, rc_mem.read_sizes[i]))
        end
        if (rc_probe.completions.size() != 1)
            `uvm_error("PARTIAL_BE", $sformatf(
                "RC generated %0d completions, expected one", rc_probe.completions.size()))
        else
            check_cpl("RC exact-boundary", rc_probe.completions[0], 2, 7'h00, 4);
    endtask

    // 用真实 host_mem manager 的 2 字节精确分配复现历史缺陷：旧
    // responder 会整 DWORD 读取，从而在分配边界外触发 HOST_MEM 错误。
    // 本检查确认新实现只读使能字节且 payload 正确。
    task check_real_host_boundary();
        pcie_tl_mem_tlp req;
        bit [63:0] ep_addr;
        bit [63:0] rc_addr;
        byte ep_init[];
        byte rc_init[];

        // 线性、单字节粒度的 manager 让分配边界精确到字节。旧实现读整
        // DWORD，因此会在这些 2 字节块上触发 HOST_MEM 报错。
        ep_real_mem = new("ep_real_mem");
        ep_real_mem.set_alloc_policy(HOST_MEM_FIRST_FIT);
        ep_real_mem.init_region(64'h0000_4000, 64'h0000_4FFF,
                                MODE_LINEAR, 1, 8'h00);
        ep_addr = ep_real_mem.alloc(2, 4);
        ep_init = new[2];
        ep_init[0] = 8'h51;
        ep_init[1] = 8'h52;
        ep_real_mem.write_mem(ep_addr, ep_init);

        ep_probe.completions.delete();
        ep_probe.mem = ep_real_mem;
        ep_probe.use_unified_mem = 1'b1;
        req = make_read("ep_real_host_boundary", ep_addr,
                        10'd1, 4'h3, 4'h0, 10'h16);
        ep_probe.invoke_read(req);
        if (ep_probe.completions.size() != 1)
            `uvm_error("PARTIAL_BE", "EP real host boundary did not complete")
        else if (ep_probe.completions[0].payload[0] !== 8'h51 ||
                 ep_probe.completions[0].payload[1] !== 8'h52 ||
                 ep_probe.completions[0].payload[2] !== 8'h00 ||
                 ep_probe.completions[0].payload[3] !== 8'h00)
            `uvm_error("PARTIAL_BE", "EP real host boundary payload mismatch")

        rc_real_mem = new("rc_real_mem");
        rc_real_mem.set_alloc_policy(HOST_MEM_FIRST_FIT);
        rc_real_mem.init_region(64'h0000_5000, 64'h0000_5FFF,
                                MODE_LINEAR, 1, 8'h00);
        rc_addr = rc_real_mem.alloc(2, 4);
        rc_init = new[2];
        rc_init[0] = 8'h61;
        rc_init[1] = 8'h62;
        rc_real_mem.write_mem(rc_addr, rc_init);

        rc_probe.completions.delete();
        rc_probe.mem = rc_real_mem;
        rc_probe.use_unified_mem = 1'b1;
        rc_probe.auto_response_enable = 1'b1;
        req = make_read("rc_real_host_boundary", rc_addr,
                        10'd1, 4'h3, 4'h0, 10'h17);
        rc_probe.invoke_read(req);
        if (rc_probe.completions.size() != 1)
            `uvm_error("PARTIAL_BE", "RC real host boundary did not complete")
        else if (rc_probe.completions[0].payload[0] !== 8'h61 ||
                 rc_probe.completions[0].payload[1] !== 8'h62 ||
                 rc_probe.completions[0].payload[2] !== 8'h00 ||
                 rc_probe.completions[0].payload[3] !== 8'h00)
            `uvm_error("PARTIAL_BE", "RC real host boundary payload mismatch")
    endtask

    // read-back registry 检查：partial-BE 读的 rb_data 必须只压紧使能
    // 字节（2 字节），在有效 byte_count 处判定完成，且完成后表项必须
    // 被回收（防泄漏）。
    function void check_readback_registry();
        pcie_tl_mem_tlp req;
        pcie_tl_cpl_tlp cpl;
        bit [25:0] key;

        req = make_read("registry_partial_read", 64'h0000_3000,
                        10'd1, 4'h3, 4'h0, 10'h13);
        req.rb_data.delete();
        req.rb_done = 1'b0;
        pcie_rb_registry::register(req);
        cpl = pcie_tl_cpl_tlp::type_id::create("registry_partial_cpl");
        cpl.kind = TLP_CPLD;
        cpl.fmt = FMT_3DW_WITH_DATA;
        cpl.type_f = TLP_TYPE_CPL;
        cpl.requester_id = req.requester_id;
        cpl.tag = req.tag;
        cpl.cpl_status = CPL_STATUS_SC;
        cpl.byte_count = 12'd2;
        cpl.lower_addr = 7'h00;
        cpl.length = 10'd1;
        cpl.payload = new[4];
        cpl.payload[0] = 8'h11;
        cpl.payload[1] = 8'h22;
        cpl.payload[2] = 8'h00;
        cpl.payload[3] = 8'h00;
        pcie_rb_registry::note(cpl);
        if (req.rb_data.size() != 2 || req.rb_data[0] !== 8'h11 ||
            req.rb_data[1] !== 8'h22)
            `uvm_error("PARTIAL_BE", "read-back registry did not compact enabled lanes")
        if (!req.rb_done)
            `uvm_error("PARTIAL_BE", "partial-BE registry did not terminate at valid byte count")
        key = pcie_rb_registry::mk_key(req.requester_id, req.tag);
        if (pcie_rb_registry::reqs.exists(key))
            `uvm_error("PARTIAL_BE", "completed partial-BE registry entry leaked")
    endfunction

    // codec 填充检查：解码端必须以 TLP 头部 length 为准截取 payload，
    // 丢弃 transport 追加的零填充 beat。
    function void check_codec_padding();
        pcie_tl_codec codec;
        pcie_tl_cpl_tlp source;
        pcie_tl_tlp decoded;
        pcie_tl_cpl_tlp cpl;
        bit [7:0] bytes[];
        bit [7:0] padded[];

        codec = pcie_tl_codec::type_id::create("partial_codec");
        source = pcie_tl_cpl_tlp::type_id::create("partial_source");
        source.kind = TLP_CPLD;
        source.fmt = FMT_3DW_WITH_DATA;
        source.type_f = TLP_TYPE_CPL;
        source.length = 1;
        source.requester_id = 16'h0020;
        source.tag = 10'h14;
        source.cpl_status = CPL_STATUS_SC;
        source.byte_count = 2;
        source.lower_addr = 0;
        source.payload = new[4];
        source.payload[0] = 8'h11;
        source.payload[1] = 8'h22;
        source.payload[2] = 8'h00;
        source.payload[3] = 8'h00;
        codec.encode(source, bytes);
        // 256-bit transport 可能追加一个全零 beat。解码 payload 的依据
        // 是 TLP 头部 length，而不是这些 transport 填充。
        padded = new[bytes.size() + 8];
        foreach (bytes[i]) padded[i] = bytes[i];
        decoded = codec.decode(padded);
        if (!$cast(cpl, decoded)) begin
            `uvm_error("PARTIAL_BE", "codec lost CplD type while decoding padding")
        end else if (cpl.payload.size() != 4) begin
            `uvm_error("PARTIAL_BE", $sformatf(
                "codec retained %0d bytes of transport padding, expected 4",
                cpl.payload.size()))
        end
    endfunction

    // RCB 分片对齐检查：跨 64 字节 RCB 边界的 20 DW 读必须切成
    // 4/64/12 字节三个 DWORD 填充分片，且各分片 byte_count/lower_addr/
    // 首末 lane 编码正确。
    task check_rcb_chunk_alignment();
        pcie_tl_mem_tlp req;
        bit [63:0] wire_addr;
        ep_probe.completions.delete();
        ep_probe.mps_bytes = 128;
        ep_probe.rcb_bytes = 64;
        ep_probe.use_unified_mem = 1'b0;
        // 原始地址低位模拟按字节寻址的 API；wire 地址在 RCB 切分前必须
        // 先按 DWORD 对齐。该请求从 64 字节 RCB 边界前 4 字节开始，wire
        // 上共跨 80 字节，因此必须产生 4/64/12 字节的 DWORD 填充分片。
        req = make_read("rcb_alignment_read", 64'h0000_103F,
                        10'd20, 4'h2, 4'h4, 10'h15);
        wire_addr = {req.addr[63:2], 2'b00};
        for (int i = 0; i < 80; i++)
            ep_probe.mem_space[wire_addr + i] = 8'h30 + i;
        ep_probe.invoke_read(req);
        if (ep_probe.completions.size() != 3)
            `uvm_error("PARTIAL_BE", $sformatf(
                "RCB split produced %0d completions, expected three",
                ep_probe.completions.size()))
        else begin
            check_cpl("RCB first", ep_probe.completions[0], 74, 7'h3D, 4);
            check_cpl("RCB middle", ep_probe.completions[1], 73, 7'h40, 64);
            check_cpl("RCB last", ep_probe.completions[2], 9, 7'h00, 12);
            if (ep_probe.completions[0].payload[1] !== 8'h31 ||
                ep_probe.completions[0].payload[0] !== 8'h00 ||
                ep_probe.completions[2].payload[8] !== 8'h00 ||
                ep_probe.completions[2].payload[9] !== 8'h00 ||
                ep_probe.completions[2].payload[10] !== 8'h7E ||
                ep_probe.completions[2].payload[11] !== 8'h00)
                `uvm_error("PARTIAL_BE", "RCB partial lanes were not encoded correctly")
        end
    endtask

    // 分片回读生命周期检查：依赖上一步的三个 RCB 分片，逐片折叠进
    // TLM 与 SV_IF registry 两条回读路径，验证均在最后一片、恰好 74 个
    // 有效字节处判定完成，不提前也不滞后。
    task check_split_readback_lifecycle();
        pcie_tl_mem_tlp driver_req;
        pcie_tl_mem_tlp registry_req;
        bit [25:0] key;

        if (ep_probe.completions.size() != 3) begin
            `uvm_error("PARTIAL_BE", "split readback requires the three RCB completions")
            return;
        end

        driver_req = make_read("driver_split_readback", 64'h0000_103F,
                               10'd20, 4'h2, 4'h4, 10'h15);
        ep_probe.seed_readback(driver_req);
        ep_probe.fold_completion(ep_probe.completions[0]);
        if (driver_req.rb_done || driver_req.rb_data.size() != 1)
            `uvm_error("PARTIAL_BE",
                       "TLM readback retired before all split CplD fragments")
        ep_probe.fold_completion(ep_probe.completions[1]);
        if (driver_req.rb_done || driver_req.rb_data.size() != 65)
            `uvm_error("PARTIAL_BE",
                       "TLM readback miscounted the middle CplD fragment")
        ep_probe.fold_completion(ep_probe.completions[2]);
        if (!driver_req.rb_done || driver_req.rb_data.size() != 74)
            `uvm_error("PARTIAL_BE",
                       "TLM readback did not complete at 74 enabled bytes")

        registry_req = make_read("registry_split_readback", 64'h0000_103F,
                                 10'd20, 4'h2, 4'h4, 10'h15);
        registry_req.rb_data.delete();
        registry_req.rb_done = 1'b0;
        pcie_rb_registry::register(registry_req);
        key = pcie_rb_registry::mk_key(registry_req.requester_id,
                                       registry_req.tag);
        pcie_rb_registry::note(ep_probe.completions[0]);
        if (registry_req.rb_done || !pcie_rb_registry::reqs.exists(key))
            `uvm_error("PARTIAL_BE",
                       "SV_IF registry retired on the first split CplD")
        pcie_rb_registry::note(ep_probe.completions[1]);
        if (registry_req.rb_done || !pcie_rb_registry::reqs.exists(key))
            `uvm_error("PARTIAL_BE",
                       "SV_IF registry retired on the middle split CplD")
        pcie_rb_registry::note(ep_probe.completions[2]);
        if (!registry_req.rb_done || registry_req.rb_data.size() != 74 ||
            pcie_rb_registry::reqs.exists(key))
            `uvm_error("PARTIAL_BE",
                       "SV_IF registry did not retire at the final valid byte")
    endtask

    // 依次执行全部检查；check_split_readback_lifecycle 依赖
    // check_rcb_chunk_alignment 留下的分片，顺序不可调换。
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        check_ep_exact_boundary();
        check_rc_exact_boundary();
        check_real_host_boundary();
        check_readback_registry();
        check_codec_padding();
        check_rcb_chunk_alignment();
        check_split_readback_lifecycle();
        phase.drop_objection(this);
    endtask
endclass
