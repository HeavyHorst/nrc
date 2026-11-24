package main

import (
	_ "embed"
	"encoding/json"
	"net/http"
	"strings"
)

//go:embed web/profile.html
var profileHTML string

type profileView struct {
	Name, Login, Requester, Company string
	Groups                          []profileGroup
	SharingUnavailable              bool
}

type profileGroup struct {
	Name    string
	Members []string
}

func profileTitle(preview string) string {
	var v struct{ Title string }
	if json.Unmarshal([]byte(preview), &v) != nil {
		return ""
	}
	return strings.TrimSpace(v.Title)
}

func (s *portal) profilePage(w http.ResponseWriter, r *http.Request, who account) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	profile := profileView{Name: who.Name, Login: who.Login, Requester: who.Requester}
	s.ticketSharing(r.Context(), who, &profile)
	s.render(w, false, view{Profile: &profile})
}
