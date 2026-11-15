package main

import "core:mem/virtual"
import "core:strings"
import "core:testing"
import pr "protocol"

@(test)
test_history_asset_labels_exclude_private_content :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	for f in ([?]struct {
			kind:           pr.AssetType,
			preview, label: string,
		}{{.Note, `{"title":"Meeting \"notes\"","teaser":"private excerpt"}`, "Meeting \"notes\""}, {.Note, `{"teaser":"private excerpt"}`, ""}, {.Note, `[{"teaser":"private-array","n":9223372036854775808}]`, ""}, {.Note, `"private-scalar"`, ""}, {.Note, `{"title":9223372036854775808}`, ""}, {.Note, " Legacy title ", "Legacy title"}, {.Slice, `{"name":"Release","title":"not the name"}`, "Release"}, {.File, `{"filename":"report.pdf"}`, "report.pdf"}, {.File, `{"title":"Report","filename":"report.pdf"}`, "Report"}, {.Comment, `{"title":"private comment"}`, ""}}) {
		asset := pr.Asset {
			asset_type = f.kind,
			preview    = transmute([]byte)f.preview,
			payload    = transmute([]byte)string("private document body"),
		}
		label, kind := history_asset_label(&asset, a)
		testing.expect_value(t, label, f.label)
		testing.expect_value(t, kind, u16(f.kind))
	}
}

@(test)
test_history_asset_labels_bound_utf8 :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	long_title := strings.repeat("界", 90, a)
	preview := strings.concatenate({`{"title":"`, long_title, `"}`}, a)
	asset := pr.Asset {
		asset_type = .Note,
		preview    = transmute([]byte)preview,
	}
	label, _ := history_asset_label(&asset, a)
	testing.expect_value(t, label, strings.repeat("界", 85, a))
	asset.preview = []byte{'A', 0xff, 'B'}
	label, _ = history_asset_label(&asset, a)
	testing.expect_value(t, label, "A�B")
}
