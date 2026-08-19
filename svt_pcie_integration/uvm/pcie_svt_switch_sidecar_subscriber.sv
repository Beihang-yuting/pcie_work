typedef enum int unsigned {
  PCIE_SVT_SIDECAR_RX,
  PCIE_SVT_SIDECAR_TX
} pcie_svt_sidecar_role_e;

class pcie_svt_switch_sidecar_subscriber extends
    uvm_subscriber #(svt_pcie_tlp);
  `uvm_component_utils(pcie_svt_switch_sidecar_subscriber)

  int port_index = -1;
  pcie_svt_sidecar_role_e role;
  pcie_svt_switch_port_adapter adapter;
  pcie_svt_switch_scoreboard scoreboard;

  function new(string name = "pcie_svt_switch_sidecar_subscriber",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  protected function bit is_supported_wire_tlp(svt_pcie_tlp transaction);
    case (transaction.tlp_type)
      svt_pcie_tlp::MEM_REQ:
        return transaction.fmt inside {
          svt_pcie_tlp::NO_DATA_3_DWORD,
          svt_pcie_tlp::NO_DATA_4_DWORD,
          svt_pcie_tlp::WITH_DATA_3_DWORD,
          svt_pcie_tlp::WITH_DATA_4_DWORD};
      svt_pcie_tlp::DMEM_REQ:
        return transaction.fmt inside {
          svt_pcie_tlp::WITH_DATA_3_DWORD,
          svt_pcie_tlp::WITH_DATA_4_DWORD};
      svt_pcie_tlp::TYPE_0_CFG_REQ,
      svt_pcie_tlp::TYPE_1_CFG_REQ:
        return transaction.fmt inside {
          svt_pcie_tlp::NO_DATA_3_DWORD,
          svt_pcie_tlp::WITH_DATA_3_DWORD};
      svt_pcie_tlp::CPL:
        return transaction.fmt inside {
          svt_pcie_tlp::NO_DATA_3_DWORD,
          svt_pcie_tlp::WITH_DATA_3_DWORD};
      default: return 1'b0;
    endcase
  endfunction

  virtual function void write(svt_pcie_tlp t);
    svt_pcie_tlp published;
    if (t == null) begin
      `uvm_fatal("SIDECAR_NULL", "sidecar subscriber received null")
      return;
    end
    if (!$cast(published, t.clone()) || (published == null)) begin
      `uvm_fatal("SIDECAR_CLONE", "sidecar subscriber clone failed")
      return;
    end
    if (!is_supported_wire_tlp(published)) begin
      `uvm_fatal("SIDECAR_UNSUPPORTED",
        $sformatf("unsupported wire TLP port=%0d role=%0d fmt=%0d type=%0d",
                  port_index, role, published.fmt, published.tlp_type))
      return;
    end
    if (scoreboard == null) begin
      `uvm_fatal("SIDECAR_SCOREBOARD_NULL",
                 "sidecar subscriber scoreboard is null")
      return;
    end

    case (role)
      PCIE_SVT_SIDECAR_RX: begin
        scoreboard.observe_wire(PCIE_SVT_WIRE_RX,
                                port_index, published);
        if (published.tlp_type == svt_pcie_tlp::CPL) begin
          if (adapter == null) begin
            `uvm_fatal("SIDECAR_ADAPTER_NULL",
                       "RX sidecar adapter is null")
            return;
          end
          adapter.capture_completion(published);
        end
      end
      PCIE_SVT_SIDECAR_TX:
        scoreboard.observe_wire(PCIE_SVT_WIRE_TX,
                                port_index, published);
      default:
        `uvm_fatal("SIDECAR_ROLE", "invalid sidecar role")
    endcase
  endfunction
endclass
