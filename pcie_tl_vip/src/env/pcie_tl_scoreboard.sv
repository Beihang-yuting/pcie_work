//-----------------------------------------------------------------------------
// src/env：基于 Requester ID + Tag 的请求/Completion、数据与顺序检查。
// 依赖公共 TLP 类型及有效字节辅助函数；env 注入观察流，SCB 拥有 pending 深拷贝
// 和分片跟踪表，终止响应回收两者。TLM 沿用直接调用，bridge 另提供发送前预登记。
// 一个请求只在接收观察流计数；pending_imp 不计数，双 BFM 不重复检查 Completion。
// TLM 双向完成先同步检查再释放 Tag；迟到 monitor 仅去重/计数，不能复活已终止请求。
//-----------------------------------------------------------------------------

class pcie_tl_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(pcie_tl_scoreboard)

    //--- Analysis imports ---
    `uvm_analysis_imp_decl(_rc)
    `uvm_analysis_imp_decl(_ep)
    `uvm_analysis_imp_decl(_pending)

    uvm_analysis_imp_rc #(pcie_tl_tlp, pcie_tl_scoreboard) rc_imp;
    uvm_analysis_imp_ep #(pcie_tl_tlp, pcie_tl_scoreboard) ep_imp;

    // 发送前只建立期望，不把 TX 与 RX 两次观察算作两笔事务。
    uvm_analysis_imp_pending #(pcie_tl_tlp, pcie_tl_scoreboard)	pending_imp;

    // PCIe Tag 仅在同一 Requester 内唯一；双向请求可合法使用同一个 Tag。
    typedef bit [25:0]	request_key_t;
    pcie_tl_tlp	pending_requests[request_key_t];

    //--- Multi-completion tracking ---
    typedef struct {
        pcie_tl_tlp    orig_req;
        int            total_bytes;
        int            received_bytes;
        int            wire_bytes;
        bit [63:0]     expected_addr;
        int            cpl_count;
    } cpl_tracker_t;

    cpl_tracker_t	cpl_trackers[request_key_t];

    // 独立 SCB 默认在 EP RX 建立期望；env 的旧 TLM 路径会关闭它，因 loopback
    // 已预登记且可能在 EP monitor 消费请求前完成响应，RX 不得复活已结束的事务。
    bit	ep_rx_pending_enable = 1'b1;

    // EP DMA 在 TLM 同样先由 env 预登记。同步 Completion 可能早于 RC monitor
    // 的请求观察，因此 RC RX 也必须能只计数、不重新打开已经完成的 Requester/Tag。
    // 独立 SCB 和 bridge 保持接收时登记的原行为；环境只在 TLM 关闭此开关。
    bit	rc_rx_pending_enable = 1'b1;

    //--- Check enables ---
    bit ordering_check_enable   = 1;
    bit completion_check_enable = 1;
    bit data_integrity_enable   = 1;
    bit prefix_check_enable     = 0;
    // strict_check=1: mismatch/unexpected -> uvm_error (FAIL). 0: -> uvm_warning
    // (visibility only) for tests that DELIBERATELY inject error TLPs, e.g. the
    // multi-root stress test whose PASS criterion is isolation + no-hang.
    bit strict_check            = 1;

    int prefix_format_errors    = 0;
    int prefix_integrity_errors = 0;

    //--- Statistics ---
    int total_requests     = 0;
    int total_completions  = 0;
    int matched            = 0;
    int mismatched         = 0;
    int unexpected         = 0;
    int timed_out          = 0;

    //--- Data integrity: store write data for read comparison ---
    bit [7:0] written_data[bit [63:0]];  // addr -> data

    //--- Ordering history ---
    pcie_tl_tlp rc_sent_history[$];
    pcie_tl_tlp ep_sent_history[$];

    // TLM 双向 direct/monitor 共享同一个 Completion 句柄，只检查一次；第二次观察
    // 回收标记。以句柄而非 Tag 去重，合法 Tag 重用及同一请求的多个分片仍分别检查。
    // EP 只由明确承诺后续 monitor 观察的 direct 调用登记；legacy/bridge 单次观察不留标记。
    bit	cpl_processed[pcie_tl_tlp];

    // 构造 SCB；观察口在 build 创建，pending 快照由本组件持有直到终止响应。
    function new(string name = "pcie_tl_scoreboard", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // 创建接收和预登记入口；未连接的预登记口不改变旧 TLM 调用行为。
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        rc_imp = new("rc_imp", this);
        ep_imp = new("ep_imp", this);
        pending_imp = new("pending_imp", this);
    endfunction

    //=========================================================================
    // RC 接收侧观察流；只有对端 monitor 缺失时，env 用 EP TX 补足同一观察边界。
    //=========================================================================
    // RC 收到的请求计数并按模式登记，Completion 匹配；保留原 TLM 直接调用的句柄去重。
    // TLM 请求已预登记，迟到 RX 不得复活同步 Completion 已关闭的 pending。
    function void write_rc(pcie_tl_tlp tlp);
        case (tlp.get_category())
            TLP_CAT_NON_POSTED: begin
                // RC received a non-posted from EP (e.g. EP DMA read)
                total_requests++;
                if (rc_rx_pending_enable)
                    register_pending(tlp);
            end
            TLP_CAT_POSTED: begin
                // RC received a posted (EP DMA write or Memory Write)
                total_requests++;
                if (data_integrity_enable) begin
                    store_write_data(tlp);
                end
            end
            TLP_CAT_COMPLETION: begin
                // Skip if already processed via env direct call
                if (cpl_processed.exists(tlp)) begin
                    cpl_processed.delete(tlp);
                    return;
                end
                // RC received completion from EP (TLM loopback mode)
                cpl_processed[tlp] = 1;
                total_completions++;
                if (completion_check_enable)
                    check_completion(tlp);
            end
        endcase

        if (ordering_check_enable)
            check_ordering(tlp, rc_sent_history);

        rc_sent_history.push_back(tlp);
        check_prefix_format(tlp);
        if (rc_sent_history.size() > 64)
            void'(rc_sent_history.pop_front());
    endfunction

    //=========================================================================
    // EP 接收侧观察流；只有对端 monitor 缺失时，env 用 RC TX 补足同一观察边界。
    //=========================================================================
    // EP 收到的请求计数，按模式登记并匹配 Completion；TLM 禁止晚到 RX 复活 pending。
    // Completion 在 env 释放 EP Tag 前同步检查；随后 monitor 同句柄观察只回收去重标记。
    // expect_monitor_duplicate 仅由 TLM 同步入口置 1，且调用必须早于接收 FIFO 入队；
    // 默认 monitor/legacy/bridge 调用不登记新标记，避免单次观察永久持有 Completion。
    function void write_ep(pcie_tl_tlp	tlp, bit	expect_monitor_duplicate = 0);
        case (tlp.get_category())
            TLP_CAT_COMPLETION: begin
                if (cpl_processed.exists(tlp)) begin
                    cpl_processed.delete(tlp);
                    return;
                end
                if (expect_monitor_duplicate)
                    cpl_processed[tlp] = 1;
                total_completions++;
                if (completion_check_enable)
                    check_completion(tlp);
            end
            TLP_CAT_NON_POSTED: begin
                // bridge 预登记保留发送端元数据；仅有 EP 时则在首次 RX 建立快照。
                // TLM 由 env 提前登记，晚到的 monitor 请求不能重新打开已终止的键。
                total_requests++;
                if (ep_rx_pending_enable)
                    register_pending(tlp);
            end
            TLP_CAT_POSTED: begin
                // EP received posted from RC (e.g. MEM_WR) or EP sent DMA
                total_requests++;
                if (data_integrity_enable)
                    store_write_data(tlp);
            end
        endcase

        if (ordering_check_enable)
            check_ordering(tlp, ep_sent_history);

        ep_sent_history.push_back(tlp);
        check_prefix_format(tlp);
        if (ep_sent_history.size() > 64)
            void'(ep_sent_history.pop_front());
    endfunction

    // 组合键供产品代码和定向测试共用；调用者必须传入非空请求或 Completion。
    function request_key_t request_key(pcie_tl_tlp tlp);
        return {tlp.requester_id, tlp.tag};
    endfunction

    // TX analysis 入口只预登记 NP；posted/Completion 不产生 pending 和统计副作用。
    function void write_pending(pcie_tl_tlp tlp);
        register_pending(tlp);
    endfunction

    // 首次观察时深拷贝请求，防止 sequence 复用/修改原对象污染分片检查。
    // 同一键的 RX 副本不得覆盖 TX 快照：expected_cpl_status 等期望不在线上传输。
    // 已存在的键保持不变；终止 Completion 会释放键，使合法 Tag 重用重新登记。
    function void register_pending(pcie_tl_tlp tlp);
        request_key_t	key;
        pcie_tl_tlp	snapshot;

        if ((tlp == null) || !tlp.requires_completion())
            return;
        key = request_key(tlp);
        if (pending_requests.exists(key))
            return;
        if (!$cast(snapshot, tlp.clone())) begin
            `uvm_fatal("SCB_SNAPSHOT", "Cannot clone pending request")
            return;
        end
        pending_requests[key] = snapshot;
    endfunction

    //=========================================================================
    // Check 1: Request-Completion matching (multi-completion tracking)
    //=========================================================================
    // 按复合键匹配分片，验证状态、地址和有效字节；成功或终止错误均清理跟踪项。
    protected function void check_completion(pcie_tl_tlp tlp);
        pcie_tl_cpl_tlp cpl;
        cpl_tracker_t	tracker;
        request_key_t	key;

        if (!$cast(cpl, tlp)) return;
        key = request_key(cpl);

        // 该 Requester/Tag 的首片响应：从发送前保存的请求快照建立累计状态。
        if (!cpl_trackers.exists(key)) begin
            if (pending_requests.exists(key)) begin
                pcie_tl_tlp req = pending_requests[key];
                pcie_tl_mem_tlp mem_req;
                tracker.orig_req       = req;
                // AtomicOp CAS: 请求 payload=compare||swap=2*sz，但 CplD 只回 sz(旧值)；
                // 其余(MRd/FetchAdd/Swap)CplD 字节数 = length*4。
                if (req.kind == TLP_ATOMIC_CAS)
                    tracker.total_bytes = ((req.length == 0) ? 4096 : req.length * 4) / 2;
                else if ($cast(mem_req, req))
                    tracker.total_bytes = pcie_tl_mem_valid_bytes(mem_req);
                else
                    tracker.total_bytes = (req.length == 0) ? 4096 : req.length * 4;
                tracker.received_bytes = 0;
                tracker.wire_bytes     = 0;
                tracker.cpl_count      = 0;
                if ($cast(mem_req, req))
                    tracker.expected_addr = pcie_tl_mem_wire_addr(mem_req);
                else
                    tracker.expected_addr = 0;
                cpl_trackers[key] = tracker;
            end else begin
                `uvm_warning("SCB", $sformatf(
                    "Unexpected Completion: tag=0x%03h req_id=0x%04h",
                    cpl.tag, cpl.requester_id))
                unexpected++;
                return;
            end
        end

        tracker = cpl_trackers[key];

        // Verify requester_id match
        if (tracker.orig_req.requester_id != cpl.requester_id) begin
            `uvm_error("SCB", $sformatf(
                "Completion requester_id mismatch: tag=0x%03h expected=0x%04h got=0x%04h",
                cpl.tag, tracker.orig_req.requester_id, cpl.requester_id))
            mismatched++;
        end

        // Every Completion status is checked against the request contract.
        // An unexpected UR/CA/CRS is terminal, but it is not a successful
        // match.  Negative tests may explicitly declare an expected error.
        if (cpl.cpl_status != tracker.orig_req.expected_cpl_status) begin
            `uvm_error("SCB_CPL_STATUS", $sformatf(
                {"Completion status mismatch: tag=0x%03h expected=%s ",
                 "got=%s request=%s"},
                cpl.tag, tracker.orig_req.expected_cpl_status.name(),
                cpl.cpl_status.name(), tracker.orig_req.kind.name()))
            mismatched++;
            cpl_trackers.delete(key);
            pending_requests.delete(key);
            return;
        end

        // A declared error response is terminal and carries no successful
        // read payload.  Since the status matched the explicit expectation,
        // it completes the request successfully from the test's perspective.
        if (cpl.cpl_status != CPL_STATUS_SC) begin
            matched++;
            cpl_trackers.delete(key);
            pending_requests.delete(key);
            return;
        end

        // A successful no-data Completion is legal only for requests whose
        // protocol response has no payload.  A read receiving Cpl instead of
        // CplD is a terminal failure, not a successful match.
        if (!cpl.has_data()) begin
            if (tracker.orig_req.kind inside {
                    TLP_CFG_WR0, TLP_CFG_WR1, TLP_IO_WR}) begin
                matched++;
            end else begin
                `uvm_error("SCB_CPL_NODATA", $sformatf(
                    {"Successful no-data Completion for data-returning request: ",
                     "tag=0x%03h request=%s"},
                    cpl.tag, tracker.orig_req.kind.name()))
                mismatched++;
            end
            cpl_trackers.delete(key);
            pending_requests.delete(key);
            return;
        end

        // Verify lower_addr.  For a Memory request, the lower address points
        // to the first enabled byte in this Completion, not blindly to the
        // DWORD-aligned request address.
        begin
            bit [6:0] expected_lower_addr;
            pcie_tl_mem_tlp mem_req;
            int wire_payload_bytes;
            int first_valid;
            bit [63:0] expected_lower_full;
            wire_payload_bytes = (cpl.length == 0) ? 4096 : cpl.length * 4;
            if (wire_payload_bytes > cpl.payload.size())
                wire_payload_bytes = cpl.payload.size();
            if ($cast(mem_req, tracker.orig_req)) begin
                first_valid = pcie_tl_mem_first_valid_in_range(
                    mem_req, tracker.wire_bytes, wire_payload_bytes);
                expected_lower_full = pcie_tl_mem_wire_addr(mem_req) +
                                      tracker.wire_bytes + first_valid;
                expected_lower_addr = expected_lower_full[6:0];
            end else begin
                expected_lower_addr = tracker.expected_addr[6:0];
            end

            if (cpl.lower_addr != expected_lower_addr) begin
            `uvm_warning("SCB", $sformatf(
                "Completion lower_addr mismatch: tag=0x%03h expected=0x%02h got=0x%02h",
                cpl.tag, expected_lower_addr, cpl.lower_addr))
            end
        end

        // Verify byte_count matches remaining.
        // PCIe byte_count is a 12-bit field where 0x000 encodes 4096 (the max),
        // so a completion carrying exactly 4096 remaining bytes reports 0 — decode
        // it before comparing, else 4096-byte reads raise a false mismatch.
        if (((cpl.byte_count == 0) ? 4096 : cpl.byte_count) !=
            (tracker.total_bytes - tracker.received_bytes)) begin
            `uvm_warning("SCB", $sformatf(
                "Completion byte_count mismatch: tag=0x%03h expected=%0d got=%0d",
                cpl.tag, tracker.total_bytes - tracker.received_bytes,
                (cpl.byte_count == 0) ? 4096 : cpl.byte_count))
        end

        // Data integrity check for read completions
        begin
            int wire_payload_bytes;
            int valid_in_cpl;
            pcie_tl_mem_tlp mem_req;
            wire_payload_bytes = (cpl.length == 0) ? 4096 : cpl.length * 4;
            if (wire_payload_bytes > cpl.payload.size())
                wire_payload_bytes = cpl.payload.size();
            if (data_integrity_enable && cpl.kind == TLP_CPLD)
                check_data_integrity(tracker.orig_req, cpl, tracker.wire_bytes);

            if ($cast(mem_req, tracker.orig_req))
                valid_in_cpl = pcie_tl_mem_valid_bytes_in_range(
                    mem_req, tracker.wire_bytes, wire_payload_bytes);
            else
                valid_in_cpl = wire_payload_bytes;

            // Accumulate logical enabled bytes separately from the DWORD-
            // padded wire span.  Transport padding is never counted here.
            tracker.received_bytes += valid_in_cpl;
            tracker.wire_bytes     += wire_payload_bytes;
        end

        tracker.expected_addr  += cpl.payload.size();
        tracker.cpl_count++;
        cpl_trackers[key] = tracker;

        // Check if all bytes received
        if (tracker.received_bytes >= tracker.total_bytes) begin
            matched++;
            cpl_trackers.delete(key);
            pending_requests.delete(key);
        end
    endfunction

    //=========================================================================
    // Check 2: Data integrity (with byte offset for split completions)
    //=========================================================================
    // 只比较请求启用的字节；byte_offset 为已消耗的线上跨度，无已知写数据则跳过。
    protected function void check_data_integrity(pcie_tl_tlp req, pcie_tl_cpl_tlp cpl, int byte_offset = 0);
        pcie_tl_mem_tlp mem_req;
        if (!$cast(mem_req, req)) return;

        foreach (cpl.payload[i]) begin
            bit [63:0] addr = pcie_tl_mem_wire_addr(mem_req) + byte_offset + i;
            if (pcie_tl_mem_lane_enabled(mem_req, byte_offset + i) &&
                written_data.exists(addr)) begin
                if (written_data[addr] != cpl.payload[i]) begin
                    `uvm_error("SCB", $sformatf(
                        "Data mismatch at addr=0x%016h: expected=0x%02h got=0x%02h",
                        addr, written_data[addr], cpl.payload[i]))
                    mismatched++;
                    return;
                end
            end
        end
    endfunction

    //=========================================================================
    // Check 3: Ordering compliance
    //=========================================================================
    // 使用同侧有限历史输出简化顺序诊断；不改变事务状态或阻塞传输。
    protected function void check_ordering(pcie_tl_tlp tlp, ref pcie_tl_tlp history[$]);
        tlp_category_e new_cat;
        tlp_category_e prev_cat;
        // Simplified ordering check
        if (history.size() == 0) return;

        new_cat  = tlp.get_category();
        prev_cat = history[$].get_category();

        // Key violation: Non-Posted passing a Posted without RO
        if (new_cat == TLP_CAT_NON_POSTED && prev_cat == TLP_CAT_POSTED) begin
            if (!tlp.attr[0]) begin  // RO not set
                // This could be a violation if they share the same path
                `uvm_info("SCB", "Ordering: Non-Posted after Posted (check RO)", UVM_HIGH)
            end
        end
    endfunction

    //=========================================================================
    // Store write data for later comparison
    //=========================================================================
    // 记录 Memory Write 启用的字节供后续读回比较；其他 posted 类型直接忽略。
    protected function void store_write_data(pcie_tl_tlp tlp);
        pcie_tl_mem_tlp mem;
        if (tlp.kind != TLP_MEM_WR) return;
        if (!$cast(mem, tlp)) return;

        foreach (tlp.payload[i]) begin
            bit [63:0] addr = pcie_tl_mem_wire_addr(mem) + i;
            if (pcie_tl_mem_lane_enabled(mem, i))
                written_data[addr] = tlp.payload[i];
        end
    endfunction

    //=========================================================================
    // Check 5: Error response verification
    //=========================================================================
    // 检查注入错误请求的响应状态；意外成功只输出诊断，不登记新事务。
    function void check_error_response(pcie_tl_tlp err_tlp, pcie_tl_cpl_tlp response);
        if (err_tlp.inject_poisoned || err_tlp.inject_ecrc_err) begin
            // Expect error response
            if (response.cpl_status == CPL_STATUS_SC) begin
                `uvm_warning("SCB", $sformatf(
                    "Expected error response for injected error, got SC: tag=0x%03h",
                    err_tlp.tag))
            end
        end
    endfunction

    //=========================================================================
    // Check: TLP Prefix format legality
    //=========================================================================
    // 启用时检查 Prefix 数量和 Local/E2E 顺序；违规累计格式错误。
    protected function void check_prefix_format(pcie_tl_tlp tlp);
        int local_count = 0;
        bit seen_e2e = 0;

        if (!prefix_check_enable) return;
        if (tlp.prefixes.size() == 0) return;

        if (tlp.prefixes.size() > 4) begin
            `uvm_error("SCB_PREFIX", $sformatf(
                "TLP has %0d prefixes (max 4): tag=0x%03h",
                tlp.prefixes.size(), tlp.tag))
            prefix_format_errors++;
        end

        foreach (tlp.prefixes[i]) begin
            if (tlp.prefixes[i].is_local()) begin
                local_count++;
                if (seen_e2e) begin
                    `uvm_error("SCB_PREFIX", $sformatf(
                        "Local prefix at position %0d after E2E prefix: tag=0x%03h",
                        i, tlp.tag))
                    prefix_format_errors++;
                end
            end else begin
                seen_e2e = 1;
            end
        end

        if (local_count > 1) begin
            `uvm_error("SCB_PREFIX", $sformatf(
                "Multiple Local prefixes (%0d) found: tag=0x%03h",
                local_count, tlp.tag))
            prefix_format_errors++;
        end
    endfunction

    //=========================================================================
    // Check: E2E Prefix integrity (content unchanged after switch traversal)
    //=========================================================================
    // 对比发送/接收 E2E Prefix 内容；Local Prefix 可变化，缺失或不匹配累计错误。
    function void check_prefix_integrity(pcie_tl_tlp sent, pcie_tl_tlp received);
        int sent_e2e = 0;
        int recv_e2e = 0;

        if (!prefix_check_enable) return;

        foreach (sent.prefixes[i])
            if (sent.prefixes[i].is_e2e()) sent_e2e++;
        foreach (received.prefixes[i])
            if (received.prefixes[i].is_e2e()) recv_e2e++;

        if (sent_e2e != recv_e2e) begin
            `uvm_error("SCB_PREFIX", $sformatf(
                "E2E prefix count mismatch: sent=%0d received=%0d tag=0x%03h",
                sent_e2e, recv_e2e, sent.tag))
            prefix_integrity_errors++;
            return;
        end

        begin
            int si = 0, ri = 0;
            while (si < sent.prefixes.size() && ri < received.prefixes.size()) begin
                if (sent.prefixes[si].is_local()) begin si++; continue; end
                if (received.prefixes[ri].is_local()) begin ri++; continue; end
                if (sent.prefixes[si].raw_dw != received.prefixes[ri].raw_dw) begin
                    `uvm_error("SCB_PREFIX", $sformatf(
                        "E2E prefix content mismatch at index %0d: sent=0x%08h received=0x%08h tag=0x%03h",
                        si, sent.prefixes[si].raw_dw, received.prefixes[ri].raw_dw, sent.tag))
                    prefix_integrity_errors++;
                end
                si++;
                ri++;
            end
        end
    endfunction

    //=========================================================================
    // Report
    //=========================================================================
    // 汇总检查结果并报告未完成分片；strict_check 决定不匹配/意外响应的最终严重度。
    function void report_phase(uvm_phase phase);
        `uvm_info("SCB", $sformatf("\n========== Scoreboard Report ==========\n  Requests:     %0d\n  Completions:  %0d\n  Matched:      %0d\n  Mismatched:   %0d\n  Unexpected:   %0d\n  Timed Out:    %0d\n========================================",
            total_requests, total_completions, matched, mismatched, unexpected, timed_out
        ), UVM_LOW)

        if (prefix_check_enable)
            `uvm_info("SCB", $sformatf("  Prefix Format Errors:   %0d\n  Prefix Integrity Errors: %0d",
                prefix_format_errors, prefix_integrity_errors), UVM_LOW)

        // Check for incomplete multi-completion trackers
        if (cpl_trackers.size() > 0) begin
            request_key_t	key;
            if (cpl_trackers.first(key)) begin
                do begin
                    `uvm_warning("SCB", $sformatf(
                        "Incomplete completion: req_id=0x%04h tag=0x%03h received=%0d/%0d bytes (%0d splits)",
                        key[25:10], key[9:0], cpl_trackers[key].received_bytes,
                        cpl_trackers[key].total_bytes, cpl_trackers[key].cpl_count))
                    timed_out++;
                end while (cpl_trackers.next(key));
            end
        end

        if (mismatched > 0 || unexpected > 0) begin
            if (strict_check)
                `uvm_error("SCB", $sformatf("FAIL: %0d mismatches, %0d unexpected completions",
                                             mismatched, unexpected))
            else
                `uvm_warning("SCB", $sformatf(
                    "%0d mismatches, %0d unexpected completions (strict_check=0: injected-error noise, not asserted)",
                    mismatched, unexpected))
        end
    endfunction

endclass
