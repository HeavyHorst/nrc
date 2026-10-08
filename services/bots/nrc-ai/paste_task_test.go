package main

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func TestValidateTaskDescriptionByteLimit(t *testing.T) {
	for _, tc := range []struct{ description, want string }{
		{strings.Repeat("x", 2049), strings.Repeat("x", 2049)},
		{strings.Repeat("ä", 2048), strings.Repeat("ä", 2048)},
		{strings.Repeat("x", 4095) + "ä", strings.Repeat("x", 4095)},
		{strings.Repeat("ä", 2048) + "x", strings.Repeat("ä", 2048)},
	} {
		task := extractedTask{Title: "Images", Description: tc.description}
		if err := validateTask(&task); err != nil {
			t.Fatal(err)
		}
		if task.Description != tc.want || !utf8.ValidString(task.Description) {
			t.Fatalf("%d bytes: got %d bytes, expected %d valid UTF-8 bytes", len(tc.description), len(task.Description), len(tc.want))
		}
	}
}
