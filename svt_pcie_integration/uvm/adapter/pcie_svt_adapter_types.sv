// Metadata carried alongside transactions crossing the TL/SVT bridge.
typedef struct packed {
  bit [31:0] application_id;
  bit [31:0] link_id;
  bit [31:0] root_index;
  bit [15:0] requester_id;
  bit [9:0]  requester_tag;
  bit [15:0] completer_id;
  bit [2:0]  completion_status;
} pcie_svt_route_info;

function automatic pcie_svt_route_info pcie_svt_route_info_default();
  pcie_svt_route_info r;
  r = '{default:0};
  return r;
endfunction
