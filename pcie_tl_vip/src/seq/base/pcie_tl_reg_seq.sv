// pcie_tl_vip/src/seq/base：将标量寄存器访问转换为公共 Memory TLP sequence。
// 依赖 pcie_tl_rw_seq；不依赖 AIP、Intel 或 SVT。调用者拥有本对象，body 每次
// 新建子 sequence，issued_tlps 保留当次请求，下一次 start 时清空所有输出。
// addr 为 DWORD 对齐的 PCIe 字节地址，len 为 4/8/12/16 字节；mask 的低 len
// 位逐字节屏蔽，bit i 对应 addr+i 和 wdata[8*i +: 8]；0=正常访问，1=跳过。
// 稀疏 mask 拆成连续区间，避免伪造 PCIe 无法表达的中间 DWORD byte enable；
// 不进行读改写，未使能字节不访问，masked read 的未使能字节返回零。
// 写操作为 posted：成功只表示发送完成；多区间访问不提供原子性或失败回滚。
// check_read_data 默认启用 RAM 写值比较；状态寄存器可逐请求关闭，Completion 协议检查不变。
class pcie_tl_reg_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_reg_seq)

    bit	                is_write;
    longint unsigned	  addr;
    int unsigned	      len = 4;
    int unsigned	      mask = 0;
    bit [127:0]	        wdata;
    bit [127:0]	        rdata;
    pcie_rw_status_e	   status = PCIE_RW_OK;
    string	             error_msg;
    int	                rb_timeout_ns = 50000;
    bit	                check_read_data = 1;
    pcie_tl_mem_tlp	    issued_tlps[$];

    // 工厂构造；输入均为非 rand 字段，命令赋值后直接 start，不会重新随机地址。
    function new(string name = "pcie_tl_reg_seq");
        super.new(name);
    endfunction

    // 在发出任何 TLP 前校验整个访问，错误只写输出状态，允许 AIP 返回可处理错误。
    // mask='1 是全屏蔽哨兵；其他显式 mask 不允许包含访问长度以外的屏蔽位。
    function bit validate_request();
        if (!(len inside {4, 8, 12, 16}))
            error_msg = "len must be 4, 8, 12 or 16 bytes";
        else if (addr[1:0] != 0)
            error_msg = "register address must be DWORD aligned";
        else if (addr > (64'hffff_ffff_ffff_ffff - (len - 1)))
            error_msg = "address range overflows 64 bits";
        else if ((int'(addr[11:0]) + len) > 4096)
            error_msg = "register access must not cross a 4KB boundary";
        else if (mask != '1 && (mask >> len) != 0)
            error_msg = "mask contains bits outside len";
        else if (is_write && (wdata >> (len * 8)) != 0)
            error_msg = "write data exceeds len bytes";
        else if (!is_write && rb_timeout_ns <= 0)
            error_msg = "read timeout must be positive";
        else
            return 1;
        status = PCIE_RW_ERR;
        return 0;
    endfunction

    // 完整访问一次发送；部分 mask 逐连续区间发送并将读回字节放回原始位置。
    // 任一区间失败立即停止，保留已发请求及已读数据，status/error_msg 标识失败。
    task body();
        int unsigned	      index;
        int unsigned	      first;
        int unsigned	      count;
        pcie_tl_rw_seq	     rw;

        rdata = '0;
        status = PCIE_RW_OK;
        error_msg = "";
        issued_tlps.delete();
        if (!validate_request()) return;
        if (m_sequencer == null) begin
            status = PCIE_RW_ERR;
            error_msg = "PCIe register sequencer is null";
            return;
        end

        index = 0;
        while (index < len) begin
            if (mask[index]) begin
                index++;
                continue;
            end
            first = index;
            while (index < len && !mask[index]) index++;
            count = index - first;

            rw = pcie_tl_rw_seq::type_id::create($sformatf("reg_bytes_%0d", first));
            rw.op = is_write ? PCIE_RW_WRITE : PCIE_RW_READ;
            rw.addr = addr + first;
            rw.byte_len = count;
            rw.is_64bit = (rw.addr[63:32] != 0);
            rw.rb_timeout_ns = rb_timeout_ns;
            rw.check_read_data = check_read_data;
            // 寄存器写后读作为设备配置同步点：统一 TC0，禁止 Relaxed/ID-based Ordering。
            rw.strict_order = 1;
            if (is_write) begin
                rw.wdata = new[count];
                foreach (rw.wdata[i]) rw.wdata[i] = wdata[(first + i)*8 +: 8];
            end
            rw.start(m_sequencer, this);
            if (rw.issued_tlp != null) issued_tlps.push_back(rw.issued_tlp);
            if (rw.status != PCIE_RW_OK) begin
                status = rw.status;
                error_msg = $sformatf("read failed at addr=0x%016h: %s", rw.addr, status.name());
                return;
            end
            if (!is_write) begin
                // rw_seq 会补零，因此同时核对原始 Completion 字节数，防止短包伪成功。
                if (rw.issued_tlp == null || rw.rdata.size() != count ||
                    rw.issued_tlp.rb_data.size() != count) begin
                    status = PCIE_RW_ERR;
                    error_msg = "Completion data size does not match enabled bytes";
                    return;
                end
                foreach (rw.rdata[i]) rdata[(first + i)*8 +: 8] = rw.rdata[i];
            end
        end
    endtask
endclass
