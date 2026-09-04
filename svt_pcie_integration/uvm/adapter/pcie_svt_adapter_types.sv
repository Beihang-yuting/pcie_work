// Metadata carried alongside transactions crossing the TL/SVT bridge.
typedef struct {
  bit [31:0] application_id;
  bit        application_id_valid;
  bit [31:0] link_id;
  // 可读的拓扑逻辑 ID；numeric link_id 继续保留以兼容旧路由检查。
  string link_name;
  bit [31:0] root_index;
  bit        requester_id_valid;
  bit [15:0] requester_id;
  bit        requester_tag_valid;
  bit [9:0]  requester_tag;
  bit        completer_id_valid;
  bit [15:0] completer_id;
  bit        completion_status_valid;
  bit [2:0]  completion_status;
} pcie_svt_route_info;

// SVT 后端工作模式。
//
// MAPPER_APP 用于真实 RTL 的 Application Agent：TL TLP 通过
// svt_pcie_tlp_mapper 交给用户 DUT application interface。
// FULL_VIP 用于本项目的 peer/回归门禁：两个完整的 SVT PCIe agent 通过
// Serial/PIPE HDL interconnect 互连，TL 适配器直接使用 PCIe agent 的
// tlp_seqr 和 TL monitor，从而确保事务确实经过 SVT 的 DL/PL/PHY。
typedef enum {
  PCIE_SVT_BACKEND_MAPPER_APP,
  PCIE_SVT_BACKEND_FULL_VIP
} pcie_svt_backend_mode_e;

function automatic pcie_svt_route_info pcie_svt_route_info_default();
  pcie_svt_route_info r;

  // SVT 规定 0~99 为 Synopsys 内部应用保留值；用户侧桥接必须使用
  // 100 及以上的 application ID，避免与官方 TL/target application
  // 连接同一个 rx_tlp_out_port 而触发连接数超限。
  r.application_id = 100;
  r.application_id_valid = 1'b0;
  r.link_id = 0;
  r.link_name = "";
  r.root_index = 0;
  r.requester_id_valid = 1'b0;
  r.requester_id = 0;
  r.requester_tag_valid = 1'b0;
  r.requester_tag = 0;
  r.completer_id_valid = 1'b0;
  r.completer_id = 0;
  r.completion_status_valid = 1'b0;
  r.completion_status = 0;
  return r;
endfunction
