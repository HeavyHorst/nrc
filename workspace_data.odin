package main

import "core:encoding/endian"
import pr "protocol"

// Every standalone data request starts with conv_id:u64. Transactions carry
// that field in each operation body and are validated separately after parsing.
is_workspace_data_opcode :: proc(opcode: pr.Opcode) -> bool {
	return(
		(opcode >= .C_ListSliceOwners && opcode <= .C_ListCalendarPeople) ||
		opcode == .C_ListTaskDependents ||
		opcode == .C_ListHistory ||
		opcode == .C_ListTaskAssignees ||
		opcode == .C_QueryCalendar ||
		opcode == .C_GetWorkspaceOverview ||
		opcode == .C_GetTasksByIDs ||
		opcode == .C_GetAssetsByIDs ||
		(opcode >= .C_CreateTask && opcode <= .C_ListTaskProjects && opcode != .C_ApplyTransaction) ||
		(opcode >= .C_CreateAsset && opcode <= .C_GraphCommonNeighbors) ||
		(opcode >= .C_GraphRank && opcode <= .C_SearchCustomers) \
	)
}

workspace_data_scope_valid :: proc(body: []byte) -> bool {
	if len(body) < 8 do return false
	scope, ok := endian.get_u64(body, .Big)
	return ok && scope == u64(pr.WORKSPACE_DATA_ID)
}
