package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	p "github.com/heavyhorst/nrc/protocol-go"
	"strconv"
	"strings"
	"time"
)

type customer struct {
	ID       string    `json:"customer_id"`
	Name     string    `json:"name"`
	Contacts []contact `json:"contacts"`
	Members  []contact `json:"-"`
}
type customerSource interface {
	customers(context.Context) ([]customer, error)
}

// A service role is scoped to a company, and valid only while its MemberOf
// relationship exists. Stale metadata after unlinking cannot authorize delivery.
func (s nrcSource) customers(ctx context.Context) ([]customer, error) {
	return s.readCustomers(ctx, false)
}

// Directory reads include every membership, not just service-designated contacts.
// Delivery reads keep their existing restricted scope and cost.
func (s nrcSource) directory(ctx context.Context) ([]customer, error) {
	return s.readCustomers(ctx, true)
}

func (s nrcSource) readCustomers(ctx context.Context, directory bool) ([]customer, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	roles := map[string][]contact{}
	contacts := []contact{}
	companies := []customer{}
	for _, kind := range []uint16{p.AssetTypeCustomerContact, p.AssetTypeCustomerCompany} {
		var updated int64
		var id uint64
		cursor := false
		seen := map[uint64]bool{}
		for pages := 0; ; pages++ {
			if pages >= 10000 {
				return nil, errors.New("customer register exceeds limit")
			}
			r, err := s.assetPage(ctx, kind, updated, id, cursor)
			if err != nil {
				return nil, err
			}
			for _, a := range r.Assets {
				if a.ConvID != 0 || a.AssetType != kind || seen[a.AssetID] {
					return nil, errors.New("inconsistent customer page")
				}
				seen[a.AssetID] = true
				var v struct {
					Version      int
					Title, Email string
					Archived     bool
					ServiceFor   []string `json:"service_for"`
				}
				if json.Unmarshal([]byte(a.Preview), &v) != nil || v.Version != 1 || v.Title == "" {
					return nil, errors.New("invalid customer metadata")
				}
				if v.Archived {
					continue
				}
				key := strconv.FormatUint(a.AssetID, 10)
				if kind == p.AssetTypeCustomerCompany {
					companies = append(companies, customer{ID: key, Name: v.Title, Contacts: []contact{}})
				} else {
					contacts = append(contacts, contact{key, v.Title, normalize(v.Email)})
					for _, company := range v.ServiceFor {
						roles[company] = append(roles[company], contact{key, v.Title, normalize(v.Email)})
					}
				}
			}
			if !r.HasMore {
				break
			}
			if cursor && updated == r.NextCursorUpdatedAt && id == r.NextCursorAssetID {
				return nil, errors.New("stalled customer cursor")
			}
			updated, id, cursor = r.NextCursorUpdatedAt, r.NextCursorAssetID, true
		}
	}
	for i := range companies {
		co := &companies[i]
		if len(roles[co.ID]) == 0 && !directory {
			continue
		}
		id, _ := strconv.ParseUint(co.ID, 10, 64)
		members := map[uint64]bool{}
		var after uint64
		for pages := 0; ; pages++ {
			if pages >= 10000 {
				return nil, errors.New("membership register exceeds limit")
			}
			m, err := s.exchange(ctx, p.C_ListEdgesPaged, p.EncodeListEdgesPaged(0, p.TargetTypeAsset, id, 250, after, 1), p.S_EdgeListPage)
			if err != nil {
				return nil, err
			}
			r, err := p.DecodeEdgeListPage(m.Data)
			if err != nil {
				return nil, err
			}
			if r.ConvID != 0 || r.TargetType != p.TargetTypeAsset || r.TargetID != id || r.CorrelationID != 1 {
				return nil, errors.New("foreign membership page")
			}
			for _, e := range r.Edges {
				if e.ConvID != 0 {
					return nil, errors.New("foreign membership")
				}
				if e.Relation != p.RelationMemberOf || e.SourceType != p.TargetTypeAsset || e.TargetType != p.TargetTypeAsset {
					continue
				}
				if e.SourceID == id {
					members[e.TargetID] = true
				} else if e.TargetID == id {
					members[e.SourceID] = true
				}
			}
			if !r.HasMore {
				break
			}
			if len(r.Edges) == 0 || r.NextEdgeID <= after {
				return nil, errors.New("stalled membership cursor")
			}
			after = r.NextEdgeID
		}
		for _, ct := range roles[co.ID] {
			id, _ := strconv.ParseUint(ct.ID, 10, 64)
			if members[id] {
				co.Contacts = append(co.Contacts, ct)
			}
		}
		if directory {
			for _, ct := range contacts {
				id, _ := strconv.ParseUint(ct.ID, 10, 64)
				if members[id] {
					co.Members = append(co.Members, ct)
				}
			}
		}
	}
	return companies, nil
}

type audienceReport struct {
	Customers  int         `json:"customers"`
	Missing    []customer  `json:"missing"`
	Excluded   int         `json:"excluded"`
	Duplicates int         `json:"duplicates"`
	Recipients []recipient `json:"recipients"`
}

func audienceToken(report audienceReport) string {
	data, _ := json.Marshal(report)
	return fmt.Sprintf("%x", sha256.Sum256(data))
}

func validServiceDraft(d draft) bool {
	if d.Kind == "" || d.Kind == "newsletter" {
		return d.Audience == "" && len(d.CustomerIDs) == 0 && d.ServiceReason == ""
	}
	if d.Kind != "service" || strings.TrimSpace(d.ServiceReason) == "" || len(d.ServiceReason) > 2000 {
		return false
	}
	if d.Audience == "all_customers" {
		return len(d.CustomerIDs) == 0
	}
	if d.Audience != "selected_customers" || len(d.CustomerIDs) == 0 || len(d.CustomerIDs) > 1000 {
		return false
	}
	seen := map[string]bool{}
	for _, id := range d.CustomerIDs {
		n, err := strconv.ParseUint(id, 10, 64)
		if err != nil || n == 0 || strconv.FormatUint(n, 10) != id || seen[id] {
			return false
		}
		seen[id] = true
	}
	return true
}

// Caller holds the store lock. Newsletter optouts do not suppress necessary
// service information; delivery blocks (including spam complaints) always do.
func (a *app) campaignAudience(ctx context.Context, c *campaign) (audienceReport, error) {
	out := audienceReport{Missing: []customer{}, Recipients: []recipient{}}
	contacts := []contact{}
	if c.Kind == "service" {
		src, ok := a.source.(customerSource)
		if !ok {
			return out, errors.New("customer register unavailable")
		}
		companies, err := src.customers(ctx)
		if err != nil {
			return out, err
		}
		selected := map[string]bool{}
		for _, id := range c.CustomerIDs {
			selected[id] = true
		}
		for _, co := range companies {
			if c.Audience != "all_customers" && !selected[co.ID] {
				continue
			}
			delete(selected, co.ID)
			out.Customers++
			eligible := false
			for _, ct := range co.Contacts {
				if a.status(normalize(ct.Email)) != "blocked" {
					eligible = true
				}
				contacts = append(contacts, ct)
			}
			if !eligible {
				co.Contacts = nil
				out.Missing = append(out.Missing, co)
			}
		}
		if len(selected) != 0 {
			return out, errors.New("selected customer no longer active; revise audience")
		}
	} else {
		var err error
		contacts, err = a.source.contacts(ctx)
		if err != nil {
			return out, err
		}
	}
	seen := map[string]bool{}
	for _, ct := range contacts {
		ct.Email = normalize(ct.Email)
		status := a.status(ct.Email)
		if status == "blocked" || (c.Kind != "service" && status != "subscribed") {
			out.Excluded++
			continue
		}
		if seen[ct.Email] {
			out.Duplicates++
			continue
		}
		seen[ct.Email] = true
		out.Recipients = append(out.Recipients, recipient{contact: ct, Status: "pending"})
	}
	return out, nil
}

func (a *app) campaignLink(c *campaign, email string) string {
	if c.Kind == "service" {
		return ""
	}
	return a.unsubscribeLink(email)
}

// Dispatch validates the queued identity, not a newly chosen representative of
// its email address. Departed companies remove eligibility, not source availability.
func (a *app) recipientEligible(ctx context.Context, c *campaign, rc recipient) (bool, error) {
	if status := a.status(rc.Email); status == "blocked" || (c.Kind != "service" && status != "subscribed") {
		return false, nil
	}
	var contacts []contact
	if c.Kind == "service" {
		src, ok := a.source.(customerSource)
		if !ok {
			return false, errors.New("customer register unavailable")
		}
		companies, err := src.customers(ctx)
		if err != nil {
			return false, err
		}
		for _, co := range companies {
			selected := c.Audience == "all_customers"
			for _, id := range c.CustomerIDs {
				if co.ID == id {
					selected = true
					break
				}
			}
			if selected {
				contacts = append(contacts, co.Contacts...)
			}
		}
	} else {
		var err error
		contacts, err = a.source.contacts(ctx)
		if err != nil {
			return false, err
		}
	}
	for _, ct := range contacts {
		if ct.ID == rc.ID && normalize(ct.Email) == rc.Email {
			return true, nil
		}
	}
	return false, nil
}
