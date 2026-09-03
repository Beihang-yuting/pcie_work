// Metadata carried alongside transactions crossing the TL/SVT bridge.
typedef struct {
  bit [31:0] application_id;
  bit [31:0] link_id;
  // 可读的拓扑逻辑 ID；numeric link_id 继续保留以兼容旧路由检查。
  string link_name;
  bit [31:0] root_index;
  bit [15:0] requester_id;
  bit [9:0]  requester_tag;
  bit [15:0] completer_id;
  bit [2:0]  completion_status;
} pcie_svt_route_info;

function automatic pcie_svt_route_info pcie_svt_route_info_default();
  pcie_svt_route_info r;
  r = '{default:0};
  r.link_name = "";
  return r;
endfunction
