package main

import (
	"context"
	"encoding/json"
	"fmt"
	"mime/multipart"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	p "github.com/heavyhorst/nrc/protocol-go"
	"golang.org/x/crypto/bcrypt"
)

type revokingFiles struct {
	fileStore
	revoke func()
}

func (f revokingFiles) upload(ctx context.Context, header *multipart.FileHeader) (p.Attachment, error) {
	attachment, err := f.fileStore.upload(ctx, header)
	f.revoke()
	return attachment, err
}

func TestSharedTicketGrantRevokedDuringUpload(t *testing.T) {
	s, f := sharingFixture(t)
	s.files = revokingFiles{testFiles(t), func() {
		company := f.assets[123]
		company.Preview = `{"version":1,"title":"Nordwerk","ticket_groups":[]}`
		f.assets[123] = company
	}}
	w := multipartRequest(t, s, "/api/tickets/2/reply", map[string]string{"body": "Reply while access is revoked"}, []string{"diagnose.txt"}, []byte("diagnosis"))
	if w.Code != 404 || f.writes != 0 {
		t.Fatalf("reply committed after revocation during upload: status=%d writes=%d", w.Code, f.writes)
	}
	if w := own(s, "GET", "/api/tickets/1", ""); w.Code != 200 {
		t.Fatal("revocation also removed own ticket", w.Code)
	}
}

func sharingFixture(t *testing.T) (*portal, *fakeSource) {
	s, f := fixture(t)
	f.next = 200
	s.accounts[0].ContactID = "51"
	bea := s.accounts[0]
	bea.Login, bea.Requester, bea.Name, bea.ContactID = "bea", "bea@example.test", "Bea", "52"
	s.accounts = append(s.accounts, bea)
	a := f.assets[2]
	var original ticketPreview
	json.Unmarshal([]byte(a.Preview), &original)
	original.Title, original.RequesterName = "Rechnungsexport unvollständig", "Bea Sommer"
	preview, _ := json.Marshal(original)
	a.Preview, a.Payload = string(preview), "Seit dem letzten Update enthält unser CSV-Export nur noch die Kopfzeile. Können Sie das bitte prüfen?"
	f.assets[2] = a
	f.assets[123] = p.Asset{AssetID: 123, AssetType: p.AssetTypeCustomerCompany, Preview: `{"version":1,"title":"Nordwerk","ticket_groups":[{"id":"tech","name":"Technik","contact_ids":["51","52"]},{"id":"project","name":"Projektteam","contact_ids":["52","53"]}]}`}
	for _, id := range []uint64{51, 52, 53, 54} {
		f.assets[id] = p.Asset{AssetID: id, AssetType: p.AssetTypeCustomerContact, Preview: `{"version":1,"title":"Contact"}`}
		f.links = append(f.links, p.Edge{ConvID: 0, SourceType: 1, SourceID: id, TargetType: 1, TargetID: 123, Relation: p.RelationMemberOf})
	}
	// Reverse membership is equally valid, and is not a transitive group link.
	f.links[1].SourceID, f.links[1].TargetID = 123, 52
	for _, v := range []struct {
		id               uint64
		contact, company string
	}{{3, "53", "123"}, {4, "54", "123"}, {5, "52", "999"}} {
		b, _ := json.Marshal(ticketPreview{Version: 1, Title: fmt.Sprintf("Ticket %d", v.id), CompanyID: v.company, ContactID: v.contact, Requester: fmt.Sprintf("person%d@example.test", v.id), Status: "open"})
		f.assets[v.id] = p.Asset{AssetID: v.id, AssetType: ticketType, Preview: string(b), Payload: "Team original"}
	}
	for i, kind := range []string{"public_reply", "internal_note", "customer_reply"} {
		id := uint64(30 + i)
		b, _ := json.Marshal(entryPreview{1, kind, "Bea"})
		body := []string{"Wir prüfen den Export und melden uns mit einer Lösung.", "INTERNAL_ONLY_DIAGNOSIS", "Vielen Dank. Die betroffenen Rechnungen stammen aus September."}[i]
		f.assets[id] = p.Asset{AssetID: id, AssetType: entryType, ParentType: 2, ParentID: 2, Preview: string(b), Payload: body}
	}
	return s, f
}

func TestSharedTicketsReadReplyFilesAndRevocation(t *testing.T) {
	s, f := sharingFixture(t)
	s.files = testFiles(t)
	list := func(login string) []uint64 {
		t.Helper()
		w := call(s, "GET", "/api/tickets", "", "", login, "fixture-password-only")
		var v view
		if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &v) != nil {
			t.Fatal(w.Code, w.Body)
		}
		ids := []uint64{}
		for _, a := range v.Tickets {
			ids = append(ids, a.ID)
		}
		return ids
	}
	if got := list("anna"); !slices.Equal(got, []uint64{2, 1}) {
		t.Fatal("transitive/company access or missing historical ticket", got)
	}
	if got := list("bea"); !slices.Equal(got, []uint64{3, 2, 1}) {
		t.Fatal("mutual/direct overlap access", got)
	}
	w := own(s, "GET", "/api/tickets/2", "")
	if w.Code != 200 || strings.Contains(w.Body.String(), "INTERNAL_ONLY_DIAGNOSIS") || !strings.Contains(w.Body.String(), "Wir prüfen den Export") || !strings.Contains(w.Body.String(), `"shared":true`) {
		t.Fatal(w.Code, w.Body)
	}
	for _, id := range []int{3, 4, 5} {
		if w := own(s, "GET", fmt.Sprintf("/tickets/%d", id), ""); w.Code != 404 {
			t.Fatal("private direct URL", id, w.Code)
		}
		if w := own(s, "POST", fmt.Sprintf("/tickets/%d/reply", id), "body=forbidden"); w.Code != 404 {
			t.Fatal("private POST", id, w.Code)
		}
	}
	original := f.assets[2]
	w = multipartRequest(t, s, "/api/tickets/2/reply", map[string]string{"body": "Anna antwortet für das Team"}, []string{"diagnose.txt"}, []byte("team bytes"))
	if w.Code != 201 {
		t.Fatal(w.Code, w.Body)
	}
	entry := f.assets[201]
	var metadata entryPreview
	if json.Unmarshal([]byte(entry.Preview), &metadata) != nil || metadata.Author != "Anna" || metadata.Kind != "customer_reply" || f.assets[2].Preview != original.Preview || f.assets[2].Payload != original.Payload {
		t.Fatal("reply changed requester or author", entry)
	}
	file := entry.Attachments[0]
	for _, id := range []uint64{2, 30, 31} {
		a := f.assets[id]
		a.Attachments = []p.Attachment{file}
		f.assets[id] = a
	}
	for _, id := range []uint64{2, 30, 201} {
		path := fmt.Sprintf("/tickets/2/attachments/%d/%s", id, file.FileId)
		if w := own(s, "GET", path, ""); w.Code != 200 || w.Body.String() != "team bytes" {
			t.Fatal("team attachment", path, w.Code, w.Body)
		}
	}
	private := fmt.Sprintf("/tickets/2/attachments/31/%s", file.FileId)
	if w := own(s, "GET", private, ""); w.Code != 404 {
		t.Fatal("internal attachment leaked", w.Code)
	}
	// The same attachment ID on two records never bypasses record visibility.
	company := f.assets[123]
	company.Preview = `{"version":1,"title":"Nordwerk","ticket_groups":[{"id":"tech","name":"Technik","contact_ids":["51"]}]}`
	f.assets[123] = company
	if got := list("anna"); !slices.Equal(got, []uint64{1}) {
		t.Fatal("revoked list", got)
	}
	for _, path := range []string{"/tickets/2", "/api/tickets/2", fmt.Sprintf("/tickets/2/attachments/201/%s", file.FileId), fmt.Sprintf("/tickets/2/attachments/201/%s?preview=1", file.FileId)} {
		if w := own(s, "GET", path, ""); w.Code != 404 {
			t.Fatal("revocation bypass", path, w.Code)
		}
	}
	if w := own(s, "POST", "/api/tickets/2/reply", "body=revoked"); w.Code != 404 {
		t.Fatal("revoked POST", w.Code)
	}
	if w := own(s, "GET", "/api/tickets/1", ""); w.Code != 200 {
		t.Fatal("own access lost", w.Code)
	}
	if w := own(s, "POST", "/api/tickets", "title=Future&body=Original"); w.Code != 201 {
		t.Fatal(w.Code, w.Body)
	}
	var future ticketPreview
	json.Unmarshal([]byte(f.assets[202].Preview), &future)
	if future.ContactID != "51" || future.Requester != "anna@example.test" {
		t.Fatal("new ticket binding", future)
	}
}

func TestSharingFailsClosedButKeepsOwnTickets(t *testing.T) {
	for _, change := range []string{"unmapped", "different_company", "removed_edge", "deleted_contact", "deleted_company", "malformed", "wrong_case", "edge_failure"} {
		t.Run(change, func(t *testing.T) {
			s, f := sharingFixture(t)
			switch change {
			case "unmapped":
				s.accounts[0].ContactID = ""
			case "different_company":
				s.accounts[0].CompanyID = "999"
			case "removed_edge":
				f.links = f.links[1:]
			case "deleted_contact":
				delete(f.assets, 52)
			case "deleted_company":
				delete(f.assets, 123)
			case "malformed":
				a := f.assets[123]
				a.Preview = `{"version":1,"ticket_groups":null}`
				f.assets[123] = a
			case "wrong_case":
				a := f.assets[123]
				a.Preview = `{"version":1,"Ticket_Groups":[{"id":"tech","name":"Tech","contact_ids":["51","52"]}]}`
				f.assets[123] = a
			case "edge_failure":
				f.fail = true
			}
			if w := own(s, "GET", "/api/tickets/2", ""); w.Code != 404 {
				t.Fatal("unsafe group access", w.Code, w.Body)
			}
			if w := own(s, "GET", "/api/tickets/1", ""); w.Code != 200 {
				t.Fatal("own access blocked", w.Code, w.Body)
			}
		})
	}
}

func TestAccountContactBindings(t *testing.T) {
	h, _ := bcrypt.GenerateFromPassword([]byte("test-only-long-password"), 12)
	for _, variant := range []string{"valid", "unmapped", "duplicate", "missing_company", "noncanonical"} {
		t.Run(variant, func(t *testing.T) {
			a := []account{{"anna", string(h), "anna@example.test", "Anna", "123", "51"}}
			switch variant {
			case "unmapped":
				a[0].ContactID = ""
			case "duplicate":
				b := a[0]
				b.Login = "bea"
				b.Requester = "bea@example.test"
				a = append(a, b)
			case "missing_company":
				a[0].CompanyID = ""
			case "noncanonical":
				a[0].ContactID = "051"
			}
			data, _ := json.Marshal(a)
			path := filepath.Join(t.TempDir(), "accounts.json")
			os.WriteFile(path, data, 0600)
			_, err := loadAccounts(path)
			if (err == nil) != (variant == "valid" || variant == "unmapped") {
				t.Fatal(variant, err)
			}
		})
	}
}
