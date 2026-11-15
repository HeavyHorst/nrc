package main

import "byte_pool"
import pr "protocol"

send_transaction_result :: proc(
	c: ^NRC_Connection,
	correlation_id: u32,
	status: pr.TransactionResultStatus,
	failed_operation: u16,
	results: []pr.TransactionOperationResult,
) {
	protocol_len := pr.getSizeTransactionResult(
		len(results),
	); buf, header_len := allocate_websocket_frame_buffer(protocol_len, "transaction result"); if buf == nil do return
	written := pr.serializeTransactionResult(
		correlation_id,
		status,
		failed_operation,
		results,
		buf[header_len:],
	); if written != protocol_len {byte_pool.release(td.spool, buf); return}; _ = send_pooled_buffer_priority(c, buf[:header_len + written])
}
