//-----------------------------------------------------------------------------
// src/agent：公共 TLP 发送流水线，依赖共享 Tag/FC/codec 与注入的 adapter。
// driver 拥有发送观察口和 read-back 表；共享组件归 env 所有，请求句柄归 sequence。
// tx_ap 在最终 Tag 已确定、adapter 尚未发送时同步发布，观察者不得修改请求。
//-----------------------------------------------------------------------------

class pcie_tl_base_driver extends uvm_driver #(pcie_tl_tlp);
    `uvm_component_utils(pcie_tl_base_driver)

    //--- Shared component references (injected by agent) ---
    pcie_tl_fc_manager         fc_mgr;
    pcie_tl_tag_manager        tag_mgr;
    pcie_tl_ordering_engine    ord_eng;
    pcie_tl_cfg_space_manager  cfg_mgr;
    pcie_tl_bw_shaper          bw_shaper;
    pcie_tl_codec              codec;

    // 发送方向的链路延时由 pcie_tl_env 按 RC/EP 方向注入；driver 不依赖
    // 任何具体的 Intel、Xilinx 或 SVT 接口类型。
    pcie_tl_link_delay_model   tx_delay_model;

    //--- Adapter reference ---
    pcie_tl_if_adapter         adapter;

    // 发送观察口覆盖 requester 和 responder；env 在 bridge 模式接入 SCB，
    // 避免把本应属于公共环境的 pending 登记硬编码在后端或测试中。
    uvm_analysis_port #(pcie_tl_tlp)	tx_ap;

    //--- Read-back capture (private outstanding map, independent of the shared
    //--- tag_mgr which env may free early). Maps tag -> requesting TLP handle
    //--- so returning Completions can be written back onto the seq's object. ---
    protected pcie_tl_tlp      rb_outstanding[bit [9:0]];
    protected int              rb_recv[bit [9:0]];   // enabled bytes received
    protected int              rb_total[bit [9:0]];  // enabled bytes expected
    protected int              rb_wire[bit [9:0]];   // padded wire bytes consumed

    // 创建 driver 及其发送观察口；共享组件由 agent 在 connect 阶段注入。
    function new(string name = "pcie_tl_base_driver", uvm_component parent = null);
        super.new(name, parent);
        tx_ap = new("tx_ap", this);
    endfunction

    // Called synchronously after a non-posted request receives its VIP tag and
    // before any ordering/flow-control wait or adapter send. Derived bridges
    // can publish an external-to-VIP tag mapping without racing a fast DUT
    // Completion. The base implementation intentionally does nothing.
    // 派生桥可在此登记 Tag 映射；不能用它替代所有 driver 都执行的 tx_ap 发布。
    virtual function void on_tag_assigned(pcie_tl_tlp tlp);
    endfunction

    //=========================================================================
    // Main run phase
    //=========================================================================
    // 从 sequencer 顺序取请求并发送；item_done 表示 adapter.send 已返回。
    task run_phase(uvm_phase phase);
        pcie_tl_tlp tlp;
        forever begin
            seq_item_port.get_next_item(tlp);
            send_tlp(tlp);
            seq_item_port.item_done();
        end
    endtask

    //=========================================================================
    // Core send pipeline (virtual - overridden by RC/EP)
    //=========================================================================
    // 分配 Tag、等待资源并发送一个 TLP；发送前同步通知观察者，防止快速响应抢先到达。
    virtual task send_tlp(pcie_tl_tlp tlp);
        bit [7:0] bytes[];

        // 1. Tag allocation (Non-Posted only)
        if (tlp.requires_completion()) begin
            bit [9:0] t = tag_mgr.alloc_tag(tlp.requester_id[2:0]);
            tlp.tag = t;
            tag_mgr.register_outstanding(t, tlp);
            // Register for read-back capture (private map, keyed by tag).
            tlp.rb_done = 0;
            tlp.rb_data = {};
            tlp.rb_status = CPL_STATUS_SC;
            rb_outstanding[t] = tlp;
            rb_recv.delete(t);
            rb_total.delete(t);
            rb_wire.delete(t);
            // Global registry for SV_IF/adapter mode, where the monitor (not the
            // env/driver completion path) folds the returning CplD.
            pcie_rb_registry::register(tlp);
            on_tag_assigned(tlp);
        end

        // 2. Ordering engine enqueue + wait
        if (ord_eng != null && !tlp.violate_ordering) begin
            ord_eng.enqueue(tlp);
        end

        // 3. Wait for send permission (FC + BW)
        wait_for_send_permission(tlp);

        // 4. Encode
        codec.encode(tlp, bytes);

        // 5. 最终 Tag 已分配，发送权限与编码已完成。必须先同步通知 SCB，
        // 再等待链路延时，最后进入具体 adapter.send；这样延时期间 pending
        // 和 Tag 仍然有效，Completion 不会被误判为 unexpected。
        tx_ap.write(tlp);
        if (tx_delay_model != null)
            tx_delay_model.wait_delay();
        adapter.send(tlp);

        // 6. Consume FC credit
        if (fc_mgr != null)
            fc_mgr.consume_credit(tlp);

        // 7. Consume BW tokens
        if (bw_shaper != null)
            bw_shaper.on_sent(bytes.size());

        `uvm_info(get_name(), $sformatf("Sent TLP: %s", tlp.convert2string()), UVM_HIGH)
    endtask

    //=========================================================================
    // Read-back capture: fold one returning Completion into its request object.
    // Called by RC/EP driver completion handlers. Accumulates CplD payload onto
    // the original request TLP (the same handle the sequence holds), and sets
    // rb_done once all requested bytes have arrived or an error status is seen.
    //=========================================================================
    // 把有效 Completion 字节折叠到原请求；终止响应置 rb_done 并回收私有跟踪项。
    function void rb_note_completion(pcie_tl_cpl_tlp cpl);
        pcie_tl_tlp req;
        bit last;
        if (!rb_outstanding.exists(cpl.tag)) return;   // not a request we track
        req = rb_outstanding[cpl.tag];
        if (!rb_total.exists(cpl.tag)) begin
            pcie_tl_mem_tlp mem_req;
            if ($cast(mem_req, req))
                rb_total[cpl.tag] = pcie_tl_mem_valid_bytes(mem_req);
            else
                rb_total[cpl.tag] = (req.length == 0) ? 4096 : req.length * 4;
            rb_recv[cpl.tag]  = 0;
            rb_wire[cpl.tag]  = 0;
        end

        if (cpl.has_data()) begin
            pcie_tl_mem_tlp mem_req;
            int declared_payload_bytes;
            int available_payload_bytes;
            int valid_in_cpl;

            declared_payload_bytes = (cpl.length == 0) ? 4096 : cpl.length * 4;
            available_payload_bytes = declared_payload_bytes;
            if (available_payload_bytes > cpl.payload.size())
                available_payload_bytes = cpl.payload.size();

            if ($cast(mem_req, req)) begin
                valid_in_cpl = pcie_tl_mem_valid_bytes_in_range(
                    mem_req, rb_wire[cpl.tag], available_payload_bytes);
                for (int i = 0; i < available_payload_bytes; i++) begin
                    if (pcie_tl_mem_lane_enabled(mem_req, rb_wire[cpl.tag] + i))
                        req.rb_data.push_back(cpl.payload[i]);
                end
            end else begin
                valid_in_cpl = available_payload_bytes;
                for (int i = 0; i < available_payload_bytes; i++)
                    req.rb_data.push_back(cpl.payload[i]);
            end

            rb_recv[cpl.tag] += valid_in_cpl;
            rb_wire[cpl.tag] += available_payload_bytes;
        end

        if (cpl.cpl_status != CPL_STATUS_SC) req.rb_status = cpl.cpl_status;
        // A successful configuration/IO write completes with TLP_CPL, which
        // intentionally carries no data. That Completion is terminal just
        // like an error Completion; only CplD needs payload-byte accounting.
        last = !cpl.has_data() ||
               (rb_recv[cpl.tag] >= rb_total[cpl.tag]) ||
               (rb_wire[cpl.tag] >= ((req.length == 0) ? 4096 : req.length * 4)) ||
               (cpl.cpl_status != CPL_STATUS_SC);
        if (last) begin
            req.rb_done = 1;
            rb_outstanding.delete(cpl.tag);
            rb_recv.delete(cpl.tag);
            rb_total.delete(cpl.tag);
            rb_wire.delete(cpl.tag);
        end
    endfunction

    //=========================================================================
    // Wait for FC credit and BW shaper permission
    //=========================================================================
    // 等待 FC credit 与带宽 token；组件未注入时跳过对应约束，不改变请求内容。
    virtual task wait_for_send_permission(pcie_tl_tlp tlp);
        // Wait for FC credit
        if (fc_mgr != null) begin
            while (!fc_mgr.check_credit(tlp)) begin
                `uvm_info(get_name(), "Waiting for FC credit...", UVM_DEBUG)
                #1ns;
            end
        end

        // Wait for BW shaper tokens
        if (bw_shaper != null) begin
            int bytes_needed = tlp.get_data_credits() * 4 + (tlp.is_4dw() ? 16 : 12);
            while (!bw_shaper.can_send(bytes_needed)) begin
                `uvm_info(get_name(), "Waiting for BW shaper tokens...", UVM_DEBUG)
                #1ns;
            end
        end
    endtask

endclass
