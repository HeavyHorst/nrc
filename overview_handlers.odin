package main

import "byte_pool"
import pr "protocol"

send_workspace_overview :: proc(c: ^NRC_Connection, msg: pr.WorkspaceOverview) {
	size := pr.getSizeWorkspaceOverview(msg)
	buf, header_len := allocate_websocket_frame_buffer(size, "workspace overview")
	if buf == nil do return
	written := pr.serializeWorkspaceOverview(msg, buf[header_len:])
	if written <= 0 {byte_pool.release(td.spool, buf); return}
	send_pooled_buffer(c, buf[:header_len + written])
}
