package main

import "core:mem/virtual"
import "core:testing"

@(test)
test_note_metadata_validated_fields :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	for fixture in ([?]struct {
			data, project: string,
			tags:          []string,
		}{{`{"project":" heavyhorst/srv ","tags":["infra"," ops ","infra",""]}`, "heavyhorst/srv", []string{"infra", "ops"}}, {`{"tags":["first"],"project":"after-tags"}`, "after-tags", []string{"first"}}, {`{"pro\u006aect":" caf\u00e9 ","ta\u0067s":["\uD83D\uDE00","😀","end\\","quote\""]}`, "café", []string{"😀", "end\\", "quote\""}}, {`{"extra":{"project":"fake","tags":["fake"]},"project":"real","tags":["yes"]}`, "real", []string{"yes"}}, {`{"extra":{"project":"fake","tags":["fake"]}}`, "", nil}, {`{"title":"Idea [proj1] [proj2]"}`, "", nil}, {`{"project":null,"tags":["alpha"]}`, "", []string{"alpha"}}, {`{"project":"p","tags":null}`, "p", nil}, {`{"project":"p","tags":[],"extra":[{"tags":["fake"]}]}`, "p", nil}}) {
		tags := make([dynamic]string)
		project := json_note_metadata_fields(transmute([]byte)fixture.data, &tags, a)
		testing.expect_value(t, project, fixture.project)
		testing.expect_value(t, len(tags), len(fixture.tags))
		if len(tags) == len(fixture.tags) {for tag, i in fixture.tags do testing.expect_value(t, tags[i], tag)}
		delete(tags)
	}
	for data in ([?]string{`{"project":17,"tags":["valid"]}`, `{"project":"p","tags":"bad"}`, `{"project":"p","tags":["valid",17]}`, `{"project":"p","tags":["valid",[]]}`, `{"project":"p","tags":["valid",{}]}`, `{"tags":["project":"p"]}`, `{"project":"p","project":"q"}`, `{"project":"p","pro\u006aect":"q"}`, `{"tags":["a"],"ta\u0067s":["b"]}`, `{"project":"p","tags":["ok"]} garbage`, `{"project":"p","tags":["ok"],}`, `{"project":"p","tags":["ok",]}`, `[]`, `{broken`}) {
		tags := make([dynamic]string)
		append(&tags, "existing")
		project := json_note_metadata_fields(transmute([]byte)data, &tags, a)
		testing.expect_value(t, project, "")
		testing.expect_value(t, len(tags), 1)
		testing.expect_value(t, tags[0], "existing")
		delete(tags)
	}
	complete := `{"project":"p","tags":["ok"],"extra":{"nested":true}}`
	for n in 0 ..< len(complete) {
		tags := make([dynamic]string)
		testing.expect_value(t, json_note_metadata_fields(transmute([]byte)complete[:n], &tags, a), "")
		testing.expect_value(t, len(tags), 0)
		delete(tags)
	}
}
