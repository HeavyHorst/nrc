package main

import "core:testing"
import pr "protocol"

@(test)
test_asset_page_exact_byte_boundary :: proc(t: ^testing.T) {
	// Empty header-only assets serialize to 55 bytes each. A 38-byte page
	// header plus two records with these previews is exactly 131072 bytes.
	preview := make([]byte, 65462)
	defer delete(preview)
	assets := [?]pr.Asset{{asset_id = 91, updated_at = 7, preview = preview}, {asset_id = 72, updated_at = 6, preview = preview}}
	msg := pr.AssetListPageMessage {
		assets                 = assets[:],
		next_cursor_asset_id   = 72,
		next_cursor_updated_at = 6,
		total_count            = 2,
	}
	bound_asset_list_page(&msg)
	testing.expect_value(t, len(msg.assets), 2)
	testing.expect_value(t, pr.getSizeAssetListPageMessage(msg), 131072)
	testing.expect(t, !msg.has_more)
	// One additional byte must cut at the first asset, not leave the cursor
	// pointing at the omitted second asset or report an exhausted result.
	assets[1].owner = []byte{'x'}
	msg.assets = assets[:]
	bound_asset_list_page(&msg)
	testing.expect_value(t, len(msg.assets), 1)
	testing.expect(t, msg.has_more)
	testing.expect_value(t, msg.next_cursor_asset_id, pr.AssetID(91))
	testing.expect_value(t, msg.next_cursor_updated_at, i64(7))
	testing.expect_value(t, msg.total_count, u32(2))
}
