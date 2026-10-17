package main

import (
	"testing"

	p "github.com/heavyhorst/nrc/protocol-go"
)

func TestTicketCommandContract(t *testing.T) {
	for name, kind := range map[string]uint16{"ticket": p.AssetTypeTicket, "ticket_entry": p.AssetTypeTicketEntry} {
		got, e := parseAssetTypeName(name)
		if e != nil || got != kind || assetTypeName(got) != name {
			t.Fatalf("asset alias %s: %d %v", name, got, e)
		}
	}
	for _, name := range []string{"list", "get", "create", "update", "reply", "internal-note", "attachments", "download-attachment", "links", "link", "unlink", "create-task", "delete"} {
		c, _, e := rootCmd.Find([]string{"ticket", name})
		if e != nil || c.Name() != name {
			t.Fatalf("missing ticket %s", name)
		}
		read := name == "list" || name == "get" || name == "attachments" || name == "links"
		if (c.Annotations["mutation"] == "true") == read {
			t.Fatalf("wrong mutation annotation %s", name)
		}
	}
	update, _, _ := rootCmd.Find([]string{"ticket", "update"})
	for _, flag := range []string{"body", "body-file", "attach", "kind"} {
		if update.Flags().Lookup(flag) != nil {
			t.Fatalf("original editor flag exposed: %s", flag)
		}
	}
	reply, _, _ := rootCmd.Find([]string{"ticket", "reply"})
	public, e := reply.Flags().GetBool("public")
	if e != nil || public || reply.Flags().Lookup("kind") != nil {
		t.Fatal("staff replies must default internal and cannot spoof customer_reply")
	}
}
