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

function automatic pcie_svt_route_info pcie_svt_route_info_default();
  pcie_svt_route_info r;

  r.application_id = 0;
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
