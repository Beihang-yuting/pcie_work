//-----------------------------------------------------------------------------
// src/agent：PCIe RC requester/responder，依赖公共 driver、Tag 管理器和共享 Host 内存。
// driver 拥有 pending/分片超时状态，sequence 拥有请求，env 注入的共享资源不转移所有权。
// 接口模式通过 Completion analysis 入口统一回填和回收；TLM 由 loopback 同步调用。
// 超时从发送返回后起算，按请求句柄及分配代次隔离同 Tag 的旧定时任务。
// Host memory 读的数据在采样后、发送等待前同步发布；SCB 复制字节，不借用可变 backing。
//-----------------------------------------------------------------------------

// 公共 MSI-X 接收契约：RC 只负责识别 Requester、地址和 32 位 message data，
// 具体 Function/vector 归属由业务环境提供的 sink 负责。这样 RDMA 和 VIO 可以共享
// Memory Write 解码和 Host memory 防污染规则，而不会把各自的中断语义塞进公共 VIP。
virtual class pcie_tl_msix_sink extends uvm_object;
    // 功能：构造一个未绑定业务语义的 MSI-X sink 基类。
    // 输入输出及副作用：name 传给 UVM；基类不保存 Requester、vector 或消息目录。
    // 失败边界：基类不能直接实例化；派生 sink 必须实现 consume。
    function new(string name = "pcie_tl_msix_sink");
        super.new(name);
    endfunction

    // 功能：接收一笔已经匹配地址/data 的 MSI-X Memory Write，并提交给业务控制器。
    // 输入输出及副作用：request 只读观察；成功返回 1 且不得写 Host memory，why 输出失败原因。
    // 失败边界：Function 未绑定、vector 失效、epoch 过期或控制器拒绝时返回 0。
    pure virtual function bit consume(pcie_tl_mem_tlp request, output string why);
endclass

// 一条 RC 侧 MSI-X 地址/data 绑定；对象由 RC 拥有，sink 引用由环境保持生命周期。
class pcie_tl_msix_binding extends uvm_object;
    bit [15:0] requester_id;
    bit [63:0] message_address;
    bit [31:0] message_data;
    pcie_tl_msix_sink sink;

    // 功能：构造空 MSI-X 绑定记录，供 RC 注册时写入完整身份和 sink。
    // 输入输出及副作用：name 传给 UVM；字段保持零值和空 sink。
    // 失败边界：未填充 requester/address/data/sink 的记录不能交给 RC 使用。
    function new(string name = "pcie_tl_msix_binding");
        super.new(name);
        requester_id    = '0;
        message_address = '0;
        message_data    = '0;
        sink            = null;
    endfunction
endclass

class pcie_tl_rc_driver extends pcie_tl_base_driver;
    `uvm_component_utils(pcie_tl_rc_driver)

    //--- Completion timeout ---
    int  cpl_timeout_ns = 50000;  // 50us default

    // SV_IF/bridge 模式下，Completion 由 monitor 从外部适配器收到；该
    // analysis imp 将其重新交给 RC driver，复用既有 pending/tag 生命周期。
    uvm_analysis_imp #(pcie_tl_tlp, pcie_tl_rc_driver) completion_analysis_imp;

    //--- Outstanding requests awaiting completion ---
    pcie_tl_tlp pending_cpl[bit [9:0]];  // tag -> request

    //--- Multi-completion tracking: tag -> remaining bytes ---
    typedef struct {
        int  total_bytes;
        int  received_bytes;
    } cpl_byte_tracker_t;
    cpl_byte_tracker_t cpl_byte_trackers[bit [9:0]];

    //--- BAR allocation state ---
    bit [63:0] next_bar_addr = 64'h0000_0001_0000_0000;  // start at 4GB

    //--- Interrupt handling ---
    int  msi_received_count = 0;
    int  intx_asserted[4];  // INTA-INTD

    //--- Unified memory backend (injected by env when cfg.use_unified_mem=1) ---
    host_mem_api  mem;                     // null -> no memory model (default OFF)
    bit           use_unified_mem = 0;     // mirror of cfg.use_unified_mem; default 0
    bit           auto_response_enable = 1;

    // 每个 Requester 可以声明多个互斥地址视图；注册非拥有引用，生命周期由环境保证。
    typedef host_mem_api dma_views_t[$];
    protected dma_views_t dma_views[bit [15:0]];
    protected pcie_tl_msix_binding msix_bindings[$];
    // 功能：为 Requester 添加一个设备地址视图，重复同句柄注册幂等。
    // 输入输出及副作用：requester/view 为身份及非拥有引用，why 输出拒绝原因。
    // 失败边界：空或未初始化视图拒绝；地址冲突在每次访问前按动态账本检查。
    extern function bit register_dma_view(bit [15:0] requester, host_mem_api view, output string why);
    // 功能：为完整 Memory 请求选择唯一地址所有者并预检全部使能字节。
    // 输入输出及副作用：r 为请求；selected 输出视图，why 输出失败原因，无数据副作用。
    // 失败边界：未知 Requester、无所有者、多所有者、跨视图或权限失败全部拒绝。
    extern function bit select_dma_view(pcie_tl_mem_tlp r, output host_mem_api selected, output string why);
    // 功能：注册一个 Requester 的 MSI-X message address/data 接收 sink。
    // 输入输出及副作用：RC 保存 binding 和 sink 的非拥有引用；重复同一 binding 幂等。
    // 失败边界：空 sink、零/未对齐地址、重复地址/data 或未知字段拒绝，不改变已有目录。
    extern function bit register_msix_sink(
        bit [15:0] requester_id,
        bit [63:0] message_address,
        bit [31:0] message_data,
        pcie_tl_msix_sink sink,
        output string why
    );
    // 功能：移除指定 Requester 的 MSI-X 接收目录，供运行期消息模板原子重载。
    // 输入输出及副作用：删除 RC 持有的 binding，不触碰 sink 对象或 DMA view。
    // 失败边界：Requester 没有 binding 时保持幂等成功，不报告不存在错误。
    extern function void clear_msix_sinks(bit [15:0] requester_id);
    // 功能：解析并分发一笔完整 MSI-X Memory Write，返回是否已被 sink 消费。
    // 输入输出及副作用：recognized 表示命中目录；why 输出歧义或 sink 拒绝原因，不写 Host。
    // 失败边界：普通 Memory Write 返回未识别；匹配多个 sink、编码不合法或 sink 拒绝返回失败。
    extern protected function bit dispatch_msix(
        pcie_tl_tlp request,
        output bit recognized,
        output string why
    );

    // 源端读快照不经过线上编码；每个分片只发布一次，保留 Requester/Tag 的归属。
    // 使用现有 Completion 容器传递本次采样字节，接收者必须在 write 回调中复制。
    uvm_analysis_port #(pcie_tl_cpl_tlp)	host_read_ap;

    //--- Completion splitting config (injected by env) ---
    int mps_bytes = 256;
    int rcb_bytes = 64;

    // 构造只初始化组件与中断统计；端口在 build 创建，pending 随请求生命周期维护。
    function new(string	name = "pcie_tl_rc_driver", uvm_component	parent = null);
        super.new(name, parent);
        foreach (intx_asserted[i]) intx_asserted[i] = 0;
    endfunction

    // 创建接口 Completion 接收口，env 决定接线；本阶段不启动超时或分配 Tag。
    virtual function void build_phase(uvm_phase	phase);
        super.build_phase(phase);

        completion_analysis_imp = new("completion_analysis_imp", this);
        host_read_ap = new("host_read_ap", this);
    endfunction

    // monitor.tlp_ap 的统一回调；仅在 SV_IF 模式处理 Completion，避免
    // TLM 环路中的既有 env 路径被重复消费。
    virtual function void write(pcie_tl_tlp tlp);
        pcie_tl_cpl_tlp cpl;

        if ((adapter == null) || (adapter.mode != SV_IF_MODE) ||
            (tlp == null) || (tlp.get_category() != TLP_CAT_COMPLETION))
            return;
        if ($cast(cpl, tlp))
            void'(handle_completion(cpl));
    endfunction

    //=========================================================================
    // Unified-memory helpers (only called when mem != null)
    //=========================================================================
    // 功能：把已通过整笔预检的 Memory Write 使能字节写入本次选定的视图。
    // 输入输出及副作用：selected 为稳定非拥有引用，a/data/fbe/lbe 决定地址和有效字节。
    // 失败边界：调用者必须先完成全部权限预检；未使能字节不访问 backing。
    extern protected function void um_write(host_mem_api selected, bit [63:0] a, bit [7:0] data[], bit [3:0] fbe, bit [3:0] lbe);

    protected function void um_read(bit [63:0] a, int len, output bit [7:0] data[]);
        byte rd[];
        mem.read_mem(a, len, rd);
        data = new[len];
        foreach (rd[i]) data[i] = rd[i];
    endfunction

    //=========================================================================
    // Handle incoming request (called when RC receives a non-posted TLP from EP)
    // Gate: returns immediately when use_unified_mem=0 (OFF path unchanged)
    //=========================================================================
    // 功能：处理 EP Memory/Atomic 请求并复用既有 responder。
    // 输入输出及副作用：req 在注册模式按 Requester 选唯一视图；写更新 Host，读发送 Completion。
    // 失败边界：关闭 responder 或空请求立即返回；注册模式拒绝未知/冲突/越界/无权限，legacy 模式保留 mem 行为。
    extern virtual task handle_request(pcie_tl_tlp req);

    //=========================================================================
    // Send memory read completion(s), splitting per MPS/RCB rules
    // Mirrors ep_driver's handle_mem_read logic exactly
    //=========================================================================
    // 功能：按 MPS/RCB 分片读取所选视图并发送 Memory Completion。
    // 输入输出及副作用：r/k 保留请求身份和 Completion 类型；selected 在全部等待期间保持同一引用。
    // 失败边界：只读使能字节；授权由 handle_request 整笔预检，调用者负责视图在事务期间有效。
    extern protected task send_mem_completion(pcie_tl_mem_tlp r, tlp_kind_e k, host_mem_api selected);

    //=========================================================================
    // Send atomic operation completion (FetchAdd / Swap / CAS)
    // Returns old value, computes new value, writes back
    //=========================================================================
    protected task send_atomic_completion(pcie_tl_atomic_tlp a);
        int sz;
        bit [7:0] old_data[];
        bit [7:0] new_data[];
        pcie_tl_cpl_tlp cpl;
        int len_dw;

        sz = a.is_64bit ? 8 : 4;

        // Read current (old) value from host memory
        um_read(a.addr, sz, old_data);

        // Compute new value based on op type; operand(s) from payload (little-endian)
        new_data = new[sz];
        case (a.kind)
            TLP_ATOMIC_FETCHADD: begin
                bit [63:0] old_val = 0;
                bit [63:0] operand = 0;
                bit [63:0] new_val;
                bit [63:0] tmp;
                for (int i = 0; i < sz && i < old_data.size(); i++) begin
                    tmp = {56'h0, old_data[i]};
                    old_val |= (tmp << (i * 8));
                end
                for (int i = 0; i < sz && i < a.payload.size(); i++) begin
                    tmp = {56'h0, a.payload[i]};
                    operand |= (tmp << (i * 8));
                end
                new_val = old_val + operand;
                for (int i = 0; i < sz; i++)
                    new_data[i] = new_val[i*8 +: 8];
            end
            TLP_ATOMIC_SWAP: begin
                for (int i = 0; i < sz; i++)
                    new_data[i] = (i < a.payload.size()) ? a.payload[i] : 8'h00;
            end
            TLP_ATOMIC_CAS: begin
                // CAS payload = compare || swap (each sz bytes)
                // new = (old == compare) ? swap : old
                bit match = 1;
                for (int i = 0; i < sz; i++) begin
                    bit [7:0] cmp_byte = (i < a.payload.size()) ? a.payload[i] : 8'h00;
                    if (old_data[i] != cmp_byte) match = 0;
                end
                if (match) begin
                    for (int i = 0; i < sz; i++)
                        new_data[i] = (sz + i < a.payload.size()) ? a.payload[sz + i] : 8'h00;
                end else begin
                    for (int i = 0; i < sz; i++) new_data[i] = old_data[i];
                end
            end
            default: begin
                for (int i = 0; i < sz; i++) new_data[i] = old_data[i];
            end
        endcase

        // Write new value back to host memory
        begin
            bit [3:0] fbe = 4'hF;
            bit [3:0] lbe = (sz == 4) ? 4'h0 : 4'hF;
            um_write(mem, a.addr, new_data, fbe, lbe);
        end

        // Build CplD returning OLD value
        len_dw = (sz + 3) / 4;
        cpl = pcie_tl_cpl_tlp::type_id::create("rc_atomic_cpl");
        cpl.kind         = TLP_CPLD;
        cpl.fmt          = FMT_3DW_WITH_DATA;
        cpl.type_f       = TLP_TYPE_CPL;
        cpl.tc           = a.tc;
        cpl.td           = 0;
        cpl.ep_bit       = 0;
        cpl.attr         = a.attr;
        cpl.length       = len_dw[9:0];
        cpl.requester_id = a.requester_id;
        cpl.tag          = a.tag;
        cpl.completer_id = 16'h0000;  // RC BDF
        cpl.cpl_status   = CPL_STATUS_SC;
        cpl.bcm          = 0;
        cpl.byte_count   = sz[11:0];
        cpl.lower_addr   = a.addr[6:0];
        cpl.payload      = new[sz];
        for (int i = 0; i < sz; i++) cpl.payload[i] = old_data[i];

        send_tlp(cpl);
    endtask

    //=========================================================================
    // Override send_tlp to add completion tracking
    //=========================================================================
    // 发送后只为尚未完成的 NP 请求启动超时，保持原先从 adapter.send 返回后起算。
    // 接口可能在 send 返回前交回终片；此时 rb_done 已置位，不能重新创建旧 pending。
    // 在 fork 外捕获 Tag/请求/分配代次，后续 sequence 重用句柄或 Tag 不影响旧 timer 身份。
    virtual task send_tlp(pcie_tl_tlp	tlp);
        super.send_tlp(tlp);

        if (tlp.requires_completion() && !tlp.rb_done) begin
            automatic bit [9:0]	request_tag = tlp.tag;
            automatic pcie_tl_tlp	request = tlp;
            automatic longint unsigned	generation = tag_mgr.get_outstanding_generation(tlp.tag);

            pending_cpl[request_tag] = request;
            fork
                start_cpl_timeout(request_tag, request, generation);
            join_none
        end
    endtask

    //=========================================================================
    // Handle incoming completion
    //=========================================================================
    virtual function bit handle_completion(pcie_tl_cpl_tlp cpl);
        pcie_tl_tlp req;
        bit terminal;

        // Match with outstanding (look up without consuming)
        req = tag_mgr.match_completion(cpl);

        if (req == null) begin
            `uvm_warning("RC_DRV", $sformatf("Unexpected Completion: tag=0x%03h req_id=0x%04h",
                                              cpl.tag, cpl.requester_id))
            return 0;
        end

        // Fold payload/status back onto the request object for seq read-back.
        rb_note_completion(cpl);

        // TLP_CPL intentionally has no data (for example, successful Config
        // and IO writes) and is terminal. Keep byte accumulation only for
        // successful CplD traffic so a short data read cannot release its tag.
        terminal = req.rb_done;
        if (cpl.has_data() && (cpl.cpl_status == CPL_STATUS_SC)) begin
            if (!cpl_byte_trackers.exists(cpl.tag)) begin
                cpl_byte_tracker_t t;
                pcie_tl_mem_tlp mem_req;
                if ($cast(mem_req, req))
                    t.total_bytes = pcie_tl_mem_valid_bytes(mem_req);
                else
                    t.total_bytes = (req.length == 0) ? 4096 : req.length * 4;
                t.received_bytes = 0;
                cpl_byte_trackers[cpl.tag] = t;
            end
            // rb_note_completion() has already compacted disabled wire lanes.
            cpl_byte_trackers[cpl.tag].received_bytes = req.rb_data.size();
        end

        `uvm_info("RC_DRV", $sformatf("Completion matched: tag=0x%03h status=%s bytes=%0d/%0d",
                                       cpl.tag, cpl.cpl_status.name(),
                                       cpl_byte_trackers.exists(cpl.tag) ?
                                       cpl_byte_trackers[cpl.tag].received_bytes : 0,
                                       cpl_byte_trackers.exists(cpl.tag) ?
                                       cpl_byte_trackers[cpl.tag].total_bytes : 0), UVM_MEDIUM)

        // Free on a terminal no-data/error Completion, or only after every
        // byte of a successful CplD request has arrived.
        if (terminal) begin
            pcie_rb_registry::complete(cpl);
            cpl_byte_trackers.delete(cpl.tag);
            if (pending_cpl.exists(cpl.tag))
                pending_cpl.delete(cpl.tag);
            tag_mgr.free_tag(cpl.tag, cpl.requester_id[2:0]);
        end

        return 1;
    endfunction

    //=========================================================================
    // Completion timeout monitor
    //=========================================================================
    // 仅当前分配代次仍未完成时报告超时。句柄比较保护不同请求，generation 进一步
    // 保护 sequence 重用同一个请求对象；旧 timer 不得删除或释放后续同 Tag 的新请求。
    // 超时失败语义及原清理范围不变，不把未收到的响应伪造为成功回填。
    protected task start_cpl_timeout(bit [9:0]	tag, pcie_tl_tlp	req,
                                     longint unsigned	generation);
        #(cpl_timeout_ns * 1ns);
        if (pending_cpl.exists(tag) && pending_cpl[tag] == req &&
            tag_mgr.get_outstanding_generation(tag) == generation) begin
            `uvm_error("RC_DRV", $sformatf("Completion Timeout: tag=0x%03h after %0dns req=%s",
                                            tag, cpl_timeout_ns, req.convert2string()))
            pending_cpl.delete(tag);
            if (cpl_byte_trackers.exists(tag))
                cpl_byte_trackers.delete(tag);
            tag_mgr.free_tag(tag, req.requester_id[2:0]);
        end
    endtask

    //=========================================================================
    // BAR address allocation
    //=========================================================================
    function bit [63:0] allocate_bar_address(int size);
        bit [63:0] addr;
        // Align to size boundary
        bit [63:0] mask = size - 1;
        next_bar_addr = (next_bar_addr + mask) & ~mask;
        addr = next_bar_addr;
        next_bar_addr += size;
        return addr;
    endfunction

    //=========================================================================
    // Handle incoming interrupt messages
    //=========================================================================
    function void handle_interrupt(pcie_tl_msg_tlp msg);
        case (msg.msg_code)
            MSG_ASSERT_INTA:   intx_asserted[0]++;
            MSG_ASSERT_INTB:   intx_asserted[1]++;
            MSG_ASSERT_INTC:   intx_asserted[2]++;
            MSG_ASSERT_INTD:   intx_asserted[3]++;
            MSG_DEASSERT_INTA: intx_asserted[0]--;
            MSG_DEASSERT_INTB: intx_asserted[1]--;
            MSG_DEASSERT_INTC: intx_asserted[2]--;
            MSG_DEASSERT_INTD: intx_asserted[3]--;
            default: begin
                // MSI is a Memory Write to MSI address
                msi_received_count++;
                `uvm_info("RC_DRV", $sformatf("MSI received: count=%0d", msi_received_count), UVM_MEDIUM)
            end
        endcase
    endfunction

    //=========================================================================
    // Get pending completion count
    //=========================================================================
    function int get_pending_count();
        return pending_cpl.num();
    endfunction

endclass

// 功能：记录 requester 的非拥有 DMA 视图引用。
// 输入输出及副作用：view 加入 requester 的候选集合，why 输出状态。
// 失败边界：空/未初始化拒绝；相同对象重复注册不增加候选项。
function bit pcie_tl_rc_driver::register_dma_view(bit [15:0] requester, host_mem_api view, output string why);
    why = "DMA view is null or uninitialized";
    if (view == null || !view.is_initialized()) return 0;
    for (int unsigned i = 0; i < dma_views[requester].size(); i++)
        if (dma_views[requester][i] == view) begin
            why = "";
            return 1;
        end
    dma_views[requester].push_back(view);
    why = "";
    return 1;
endfunction

// 功能：按各视图声明的地址所有权选择整笔 DMA 的唯一访问对象。
// 输入输出及副作用：r 提供 Requester/BE/方向；selected 只在全部字节通过后发布。
// 失败边界：空请求、未注册、无使能字节、地址回绕、跨视图、冲突或权限失败不访问 backing。
function bit pcie_tl_rc_driver::select_dma_view(pcie_tl_mem_tlp r, output host_mem_api selected, output string why);
    host_mem_api candidate;
    host_mem_api owner;
    bit [64:0]	address;
    bit [63:0]	first_address;
    bit [63:0]	last_address;
    selected = null;
    candidate = null;
    why = "unregistered DMA Requester";
    if (r == null || !dma_views.exists(r.requester_id)) return 0;
    why = "invalid DMA Memory kind/Type/Fmt or payload";
    if (!(r.kind inside {TLP_MEM_RD, TLP_MEM_RD_LK, TLP_MEM_WR}) ||
        r.type_f != (r.kind == TLP_MEM_RD_LK ? TLP_TYPE_MEM_RD_LK : TLP_TYPE_MEM_RD) ||
        (r.kind == TLP_MEM_WR && !(r.fmt inside {FMT_3DW_WITH_DATA, FMT_4DW_WITH_DATA})) ||
        (r.kind != TLP_MEM_WR && !(r.fmt inside {FMT_3DW_NO_DATA, FMT_4DW_NO_DATA})) ||
        ((r.fmt inside {FMT_3DW_NO_DATA, FMT_3DW_WITH_DATA}) && r.addr[63:32] != 0) ||
        (r.kind == TLP_MEM_WR && r.payload.size() != pcie_tl_mem_dw_count(r) * 4)) return 0;
    address = {1'b0, pcie_tl_mem_wire_addr(r)} + pcie_tl_mem_dw_count(r) * 4 - 1;
    why = "DMA wire range overflows or crosses 4KB";
    if (address[64] || address[63:12] != r.addr[63:12]) return 0;
    for (int unsigned i = 0; i < pcie_tl_mem_dw_count(r) * 4; i++) begin
        if (!pcie_tl_mem_lane_enabled(r, i)) continue;
        address = {1'b0, pcie_tl_mem_wire_addr(r)} + i;
        why = "DMA address overflow";
        if (address[64]) return 0;
        owner = null;
        for (int unsigned v = 0; v < dma_views[r.requester_id].size(); v++) begin
            if (!dma_views[r.requester_id][v].claims_dma_address(address[63:0])) continue;
            why = "ambiguous DMA address ownership";
            if (owner != null) return 0;
            owner = dma_views[r.requester_id][v];
        end
        why = "DMA address is unowned or crosses views";
        if (owner == null || (candidate != null && candidate != owner)) return 0;
        if (candidate == null) first_address = address[63:0];
        last_address = address[63:0];
        candidate = owner;
    end
    why = "DMA request has no enabled bytes";
    if (candidate == null) return 0;
    // 完整使能跨度必须落入一次授权，禁止跨两次分配或映射逐字节拼接通过。
    if (!candidate.validate_dma_access(first_address, int'(last_address - first_address + 1),
            r.kind == TLP_MEM_WR, why)) return 0;
    selected = candidate;
    why = "";
    return 1;
endfunction

// 功能：登记一个 Requester 的 MSI-X message 地址/data 与业务 sink 的绑定。
// 输入输出及副作用：成功时向 RC 目录追加非拥有 sink 引用；相同 tuple 与同一 sink 重复注册幂等。
// 失败边界：空 sink、零地址、未对齐地址、未知 message data 或同 tuple 指向不同 sink 均拒绝。
function bit pcie_tl_rc_driver::register_msix_sink(
    bit [15:0] requester_id,
    bit [63:0] message_address,
    bit [31:0] message_data,
    pcie_tl_msix_sink sink,
    output string why
);
    pcie_tl_msix_binding binding;

    why = "MSI-X sink is null";
    if (sink == null) return 0;
    why = "MSI-X address is zero or unaligned";
    if (message_address == 0 || message_address[1:0] != 2'b00) return 0;
    why = "MSI-X message data is unknown";
    if ($isunknown(message_data)) return 0;
    foreach (msix_bindings[i]) begin
        if (msix_bindings[i].requester_id == requester_id &&
            msix_bindings[i].message_address == message_address &&
            msix_bindings[i].message_data == message_data) begin
            if (msix_bindings[i].sink != sink) begin
                why = "duplicate MSI-X address/data has different sinks";
                return 0;
            end
            why = "";
            return 1;
        end
    end
    binding = new($sformatf("msix_%04h_%016h_%08h", requester_id,
                            message_address, message_data));
    binding.requester_id    = requester_id;
    binding.message_address = message_address;
    binding.message_data    = message_data;
    binding.sink            = sink;
    msix_bindings.push_back(binding);
    why = "";
    return 1;
endfunction

// 功能：清除一个 Requester 的 MSI-X 目录，供消息模板变更后重新注册。
// 输入输出及副作用：删除匹配 Requester 的 binding；sink 对象仍由环境拥有，其他 Requester 不受影响。
// 失败边界：没有匹配项时保持幂等，不返回错误或改变 DMA view。
function void pcie_tl_rc_driver::clear_msix_sinks(bit [15:0] requester_id);
    for (int i = msix_bindings.size() - 1; i >= 0; i--) begin
        if (msix_bindings[i].requester_id == requester_id)
            msix_bindings.delete(i);
    end
endfunction

// 功能：把一笔完整四字节 Memory Write 匹配到唯一 MSI-X sink 并提交业务事件。
// 输入输出及副作用：普通 Memory Write 保持未识别；命中后 sink 消费请求且 RC 不写 Host memory。
// 失败边界：同 Requester 地址无效、数据不匹配、目录歧义或 sink 拒绝均返回失败并阻止 Host 写入。
function bit pcie_tl_rc_driver::dispatch_msix(
    pcie_tl_tlp request,
    output bit recognized,
    output string why
);
    pcie_tl_mem_tlp r;
    bit [63:0] wire_address;
    bit [31:0] message_data;
    int unsigned enabled_bytes;
    int first_lane;
    int last_lane;
    int match_count;
    pcie_tl_msix_binding matched;

    recognized = 0;
    why = "";
    if (!$cast(r, request) || r.kind != TLP_MEM_WR)
        return 1;

    wire_address = pcie_tl_mem_wire_addr(r);
    foreach (msix_bindings[i]) begin
        if (msix_bindings[i].requester_id == r.requester_id &&
            msix_bindings[i].message_address == wire_address) begin
            recognized = 1;
            break;
        end
    end
    if (!recognized)
        return 1;

    why = "MSI-X write must be one complete 32-bit Memory Write";
    if (!(r.fmt inside {FMT_3DW_WITH_DATA, FMT_4DW_WITH_DATA}) ||
        pcie_tl_mem_dw_count(r) != 1 || r.payload.size() != 4) return 0;
    first_lane = -1;
    last_lane = -1;
    enabled_bytes = 0;
    for (int unsigned lane = 0; lane < 4; lane++) begin
        if (pcie_tl_mem_lane_enabled(r, lane)) begin
            if (first_lane < 0) first_lane = int'(lane);
            last_lane = int'(lane);
            enabled_bytes++;
        end
    end
    if (first_lane != 0 || last_lane != 3 || enabled_bytes != 4) begin
        why = "MSI-X write has partial or non-contiguous byte enables";
        return 0;
    end
    message_data = '0;
    for (int unsigned byte_index = 0; byte_index < 4; byte_index++)
        message_data[byte_index * 8 +: 8] = r.payload[byte_index];

    match_count = 0;
    matched = null;
    foreach (msix_bindings[i]) begin
        if (msix_bindings[i].requester_id == r.requester_id &&
            msix_bindings[i].message_address == wire_address &&
            msix_bindings[i].message_data == message_data) begin
            match_count++;
            matched = msix_bindings[i];
        end
    end
    if (match_count == 0) begin
        why = "MSI-X message data does not match the registered sink";
        return 0;
    end
    if (match_count != 1 || matched == null || matched.sink == null) begin
        why = "MSI-X message has ambiguous or empty sink ownership";
        return 0;
    end
    why = "";
    if (!matched.sink.consume(r, why)) begin
        if (why == "") why = "MSI-X sink rejected the event";
        return 0;
    end
    return 1;
endfunction

    // 功能：把已通过整笔预检的 Memory Write 使能字节写入本次选定的视图。
    // 输入输出及副作用：selected 为稳定非拥有引用，a/data/fbe/lbe 决定地址和有效字节。
    // 失败边界：调用者必须先完成全部权限预检；未使能字节不访问 backing。
    function void pcie_tl_rc_driver::um_write(host_mem_api selected, bit [63:0] a, bit [7:0] data[], bit [3:0] fbe, bit [3:0] lbe);
        int total_dw = (data.size() + 3) / 4;
        int idx = 0;
        bit [63:0] wire_addr = {a[63:2], 2'b00};
        for (int dw = 0; dw < total_dw; dw++) begin
            bit [3:0] be = (dw == 0) ? fbe :
                           (dw == total_dw - 1 && total_dw > 1) ? lbe : 4'hF;
            for (int b = 0; b < 4; b++) begin
                if (idx < data.size()) begin
                    if (be[b]) begin
                        byte one[];
                        one = new[1];
                        one[0] = byte'(data[idx]);
                        selected.write_mem(wire_addr + idx, one);
                    end
                    idx++;
                end
            end
        end
    endfunction

    // 功能：处理 EP Memory/Atomic 请求并复用既有 responder。
    // 输入输出及副作用：req 在注册模式按 Requester 选唯一视图；写更新 Host，读发送 Completion。
    // 失败边界：关闭 responder 或空请求立即返回；注册模式拒绝未知/冲突/越界/无权限，legacy 模式保留 mem 行为。
    task pcie_tl_rc_driver::handle_request(pcie_tl_tlp req);
        host_mem_api selected;
        pcie_tl_mem_tlp request;
        bit msix_recognized;
        string why;
        if (!auto_response_enable || req == null) return;
        if (!dispatch_msix(req, msix_recognized, why)) begin
            `uvm_error("RC_MSIX", {"MSI-X request rejected: ", why})
            return;
        end
        if (msix_recognized) return;
        if (!use_unified_mem) return;
        selected = mem;
        if (dma_views.num() != 0) begin
            if (!$cast(request, req) || !select_dma_view(request, selected, why)) begin
                `uvm_error("RC_DMA_VIEW", {"DMA request rejected: ", why})
                return;
            end
        end
        if (selected == null) return;
        case (req.kind)
            TLP_MEM_WR: begin
                pcie_tl_mem_tlp w;
                if ($cast(w, req)) um_write(selected, w.addr, w.payload, w.first_be, w.last_be);
            end
            TLP_MEM_RD, TLP_MEM_RD_LK: begin
                pcie_tl_mem_tlp r;
                if ($cast(r, req)) begin
                    tlp_kind_e k = (req.kind == TLP_MEM_RD_LK) ? TLP_CPLD_LK : TLP_CPLD;
                    send_mem_completion(r, k, selected);
                end
            end
            TLP_ATOMIC_FETCHADD, TLP_ATOMIC_SWAP, TLP_ATOMIC_CAS: begin
                pcie_tl_atomic_tlp a;
                if ($cast(a, req)) send_atomic_completion(a);
            end
            default: ;
        endcase
    endtask

    // 功能：按 MPS/RCB 分片读取所选视图并发送 Memory Completion。
    // 输入输出及副作用：r/k 保留请求身份和 Completion 类型；selected 在全部等待期间保持同一引用。
    // 失败边界：只读使能字节；授权由 handle_request 整笔预检，调用者负责视图在事务期间有效。
    task pcie_tl_rc_driver::send_mem_completion(pcie_tl_mem_tlp r, tlp_kind_e k, host_mem_api selected);
        int total_wire_bytes;
        int remaining_wire_bytes;
        int remaining_valid_bytes;
        int wire_offset;
        bit [63:0] cur_addr;

        total_wire_bytes      = pcie_tl_mem_dw_count(r) * 4;
        remaining_wire_bytes  = total_wire_bytes;
        remaining_valid_bytes = pcie_tl_mem_valid_bytes(r);
        wire_offset            = 0;
        cur_addr               = pcie_tl_mem_wire_addr(r);

        while (remaining_wire_bytes > 0) begin
            pcie_tl_cpl_tlp cpl;
            int chunk;
            int bytes_to_rcb;
            int len_dw;
            int valid_in_chunk;
            int first_valid;
            bit [63:0] first_valid_addr;

            // Every Completion must end at or before the next RCB boundary.
            bytes_to_rcb = rcb_bytes - (cur_addr % rcb_bytes);
            if (bytes_to_rcb == 0) bytes_to_rcb = rcb_bytes;
            chunk = mps_bytes;
            if (bytes_to_rcb < chunk) chunk = bytes_to_rcb;
            if (chunk > remaining_wire_bytes) chunk = remaining_wire_bytes;

            // Completion length is DWORD based.  Keep the transport payload
            // DWORD padded and use BE only to decide which lanes are read.
            chunk = (chunk / 4) * 4;
            if (chunk == 0) chunk = remaining_wire_bytes;

            len_dw           = chunk / 4;
            valid_in_chunk   = pcie_tl_mem_valid_bytes_in_range(
                r, wire_offset, chunk);
            first_valid      = pcie_tl_mem_first_valid_in_range(
                r, wire_offset, chunk);
            first_valid_addr = cur_addr + first_valid;

            cpl = pcie_tl_cpl_tlp::type_id::create("rc_cpl");
            cpl.kind         = k;
            cpl.fmt          = FMT_3DW_WITH_DATA;
            cpl.type_f       = (k == TLP_CPLD_LK) ? TLP_TYPE_CPL_LK : TLP_TYPE_CPL;
            cpl.tc           = r.tc;
            cpl.td           = 0;
            cpl.ep_bit       = 0;
            cpl.attr         = r.attr;
            cpl.length       = (len_dw == 1024) ? 0 : len_dw[9:0];
            cpl.requester_id = r.requester_id;
            cpl.tag          = r.tag;
            cpl.completer_id = 16'h0000;  // RC BDF
            cpl.cpl_status   = CPL_STATUS_SC;
            cpl.bcm          = 0;
            cpl.byte_count   = remaining_valid_bytes[11:0];
            cpl.lower_addr   = first_valid_addr[6:0];
            cpl.payload      = new[chunk];
            foreach (cpl.payload[i]) cpl.payload[i] = 8'h00;

            // Read only enabled lanes so a partial-BE request cannot cross an
            // exact host-memory allocation boundary.
            for (int i = 0; i < chunk; i++) begin
                if (pcie_tl_mem_lane_enabled(r, wire_offset + i)) begin
                    byte rd[];
                    selected.read_mem(cur_addr + i, 1, rd);
                    if (rd.size() == 1) cpl.payload[i] = rd[0];
                end
            end

            // 此时 payload 刚从当前 mem（含 IOVA proxy）读取，尚未等待 FC/链路或被发送钩子修改。
            host_read_ap.write(cpl);
            send_tlp(cpl);

            cur_addr              += chunk;
            wire_offset           += chunk;
            remaining_wire_bytes  -= chunk;
            remaining_valid_bytes -= valid_in_chunk;
        end
    endtask
