package main

import "core:os"
import "core:testing"

import "persistence"
import pr "protocol"

when !NRC_SIMULATION {
	_ :: os.remove
	_ :: persistence.LOG_HEADER_SIZE
	_ :: pr.AssetType
}

@(test)
test_customer_assets_create_list_persistence_roundtrip :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 208)
		defer simulation_test_end(&ctx)

		workspace_id := "customer-assets-roundtrip"
		wal_path, writer_ok := asset_query_test_init_writer(workspace_id, "customer_assets_roundtrip.log")
		defer os.remove(wal_path)
		testing.expect(t, writer_ok, "customer asset WAL should initialize")
		if !writer_ok do return
		defer shutdown_shard_writer_registry(&td.shard_writers)
		td.asset_seq = 0

		ops := [?]Sim_Op {
			{kind = .Connect, client_id = 1, workspace_id = workspace_id, username = "customer-user"},
			{kind = .Subscribe, client_id = 1, conv_id = 91},
			{kind = .Clear_Inboxes},
		}
		testing.expect(t, simulation_test_apply_ops(&ctx, ops[:]), "customer asset client should initialize")
		client := simulation_test_client(&ctx, 1)
		if client == nil do return

		asset_types := [?]pr.AssetType{.CustomerCompany, .CustomerContact, .CustomerActivity}
		for asset_type, index in asset_types {
			payload := transmute([]byte)string("customer metadata")
			handle_create_asset(
				client,
				pr.CreateAssetRequest {
					conv_id = 91,
					asset_type = asset_type,
					parent_type = .None,
					payload_encoding = .Plain,
					payload_raw_len = u32(len(payload)),
					preview = transmute([]byte)string("customer"),
					payload = payload,
					correlation_id = u32(2100 + index),
				},
			)
			testing.expect(t, simulation_test_commit_shards(&ctx.sim), "customer asset create should persist")
			created_payload, created_ok := asset_query_test_payload(t, &ctx.sim, client, .S_AssetCreated)
			if !created_ok do return
			created, created_err := pr.parseAssetCreatedMessage(created_payload)
			testing.expect(t, created_err == nil, "customer asset create response should decode")
			testing.expect_value(t, created.asset.asset_type, asset_type)
			testing.expect_value(t, created.asset.parent_type, pr.ParentType.None)

			nrc_sim_clear_inboxes(&ctx.sim)
			handle_list_assets(client, pr.ListAssetsRequest{conv_id = 91, filter_by_type = true, asset_type = asset_type, full_content = true})
			list_payload, list_ok := asset_query_test_payload(t, &ctx.sim, client, .S_AssetList)
			if !list_ok do return
			listed, list_err := pr.parseAssetListMessage(list_payload)
			defer if len(listed.assets) > 0 do delete(listed.assets)
			testing.expect(t, list_err == nil, "customer asset list response should decode")
			testing.expect_value(t, len(listed.assets), 1)
			if len(listed.assets) != 1 do return
			testing.expect_value(t, listed.assets[0].asset_type, asset_type)

			asset := get_conversation(get_connection_workspace(client), 91).assets[created.asset.asset_id]
			testing.expect(t, asset != nil, "created customer asset should exist")
			if asset == nil do return
			record_size := calculate_asset_payload_size(workspace_id, asset)
			record := make([]byte, persistence.LOG_HEADER_SIZE + record_size)
			serialize_asset_to_record(record, workspace_id, asset)
			record_payload := record[persistence.LOG_HEADER_SIZE:]
			_, offset, prefix_ok := persistence.parse_workspace_prefix(record_payload)
			parsed, parse_ok := parse_asset_from_payload(record_payload, offset, ASSET_LOG_VERSION)
			testing.expect(t, prefix_ok && parse_ok, "persisted customer asset should parse")
			if parse_ok {
				testing.expect_value(t, parsed.asset_type, asset_type)
				testing.expect_value(t, parsed.parent_type, pr.ParentType.None)
			}
			delete(record)
			nrc_sim_clear_inboxes(&ctx.sim)
		}
	}
}
