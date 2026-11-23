package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"strings"
	"text/tabwriter"

	"github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	p "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
	"golang.org/x/crypto/bcrypt"
	"golang.org/x/term"
)

const portalAccountBcryptCost = 12

func ticketAccountCommand() *cobra.Command {
	root := &cobra.Command{Use: "account", Short: "Administer ticket portal accounts in the workspace"}
	for _, action := range []string{"list", "get", "create", "enable", "disable", "reset-password", "import"} {
		c := &cobra.Command{Use: action + " <id>", Short: action + " portal accounts", Args: cobra.ExactArgs(1)}
		if action != "list" && action != "get" {
			c.Annotations = map[string]string{"mutation": "true"}
		}
		switch action {
		case "list", "create", "import":
			c.Use, c.Args = action, cobra.NoArgs
		}
		switch action {
		case "list":
			c.Flags().String("cursor", "", "Continue listing from this cursor")
		case "create":
			c.Flags().String("login", "", "HTTP Basic login (no colon)")
			c.Flags().String("requester", "", "Exact canonical requester identity")
			c.Flags().String("name", "", "Customer-facing display name")
			c.Flags().String("company", "", "Company asset ID")
			c.Flags().String("contact", "", "Contact asset ID (requires company)")
			c.Flags().Bool("confirm", false, "Confirm this account will gain access to existing tickets for the specified requester")
		case "import":
			c.Flags().String("file", "", "Private legacy JSON file containing bcrypt hashes")
			c.Flags().Bool("dry-run", false, "Validate without writing")
			c.Flags().Bool("apply", false, "Write validated accounts")
			_ = c.MarkFlagRequired("file")
			c.MarkFlagsMutuallyExclusive("dry-run", "apply")
		}
		c.RunE = runTicketAccount
		root.AddCommand(c)
	}
	return root
}

func runTicketAccount(cmd *cobra.Command, args []string) error {
	q := p.PortalAccountRequest{Op: strings.ReplaceAll(cmd.Name(), "-", "_")}
	if len(args) == 1 {
		if args[0] == "" {
			return portalAccountInvalid(errors.New("account ID is required"))
		}
		q.ID = args[0]
	}
	switch q.Op {
	case "list":
		q.Cursor, _ = cmd.Flags().GetString("cursor")
	case "create":
		confirmed, _ := cmd.Flags().GetBool("confirm")
		if !confirmed {
			return portalAccountInvalid(errors.New("an account gains access to existing tickets for its exact requester; verify --requester and pass --confirm"))
		}
		var a p.PortalAccount
		a.Login, _ = cmd.Flags().GetString("login")
		a.Requester, _ = cmd.Flags().GetString("requester")
		a.Name, _ = cmd.Flags().GetString("name")
		a.CompanyID, _ = cmd.Flags().GetString("company")
		a.ContactID, _ = cmd.Flags().GetString("contact")
		if err := validatePortalAccountMetadata(a); err != nil {
			return portalAccountInvalid(err)
		}
		q.Accounts = []p.PortalAccount{a}
	case "import":
		q.DryRun, _ = cmd.Flags().GetBool("dry-run")
		apply, _ := cmd.Flags().GetBool("apply")
		if q.DryRun == apply {
			return portalAccountInvalid(errors.New("choose exactly one of --dry-run and --apply"))
		}
		file, _ := cmd.Flags().GetString("file")
		var err error
		q.Accounts, err = readPortalAccountImport(file)
		if err != nil {
			return portalAccountInvalid(err)
		}
	}

	var s *conn.Session
	var err error
	if q.Op == "create" || q.Op == "reset_password" || q.Op == "import" {
		s, err = conn.DialSecure("")
	} else {
		s, err = conn.Dial("")
	}
	if err != nil {
		return err
	}
	defer s.Close()

	if q.Op == "enable" || q.Op == "disable" || q.Op == "reset_password" {
		current, err := exchangePortalAccount(s, p.PortalAccountRequest{Op: "get", ID: q.ID}, 1)
		if err != nil {
			return err
		}
		if current.Account == nil || current.Account.ID != q.ID || current.Account.Revision == "" {
			return errors.New("portal account response did not identify a revision for the requested account")
		}
		q.IfRevision = current.Account.Revision
	}
	if q.Op == "create" {
		fmt.Fprintf(cmd.ErrOrStderr(), "Warning: this login will gain access to existing tickets for requester %q.\n", q.Accounts[0].Requester)
		q.Accounts[0].PasswordHash, err = promptPortalPassword(cmd)
	} else if q.Op == "reset_password" {
		q.PasswordHash, err = promptPortalPassword(cmd)
	}
	if err != nil {
		return err
	}
	resp, err := exchangePortalAccount(s, q, 2)
	if err != nil {
		return err
	}
	return emitPortalAccount(cmd, q.Op, resp)
}

func portalAccountInvalid(err error) error { return &conn.InvalidArgumentError{Err: err} }

func promptPortalPassword(cmd *cobra.Command) (string, error) {
	in, ok := cmd.InOrStdin().(*os.File)
	if !ok || !term.IsTerminal(int(in.Fd())) {
		return "", portalAccountInvalid(errors.New("password entry requires an interactive terminal"))
	}
	read := func(prompt string) ([]byte, error) {
		fmt.Fprint(cmd.ErrOrStderr(), prompt)
		password, err := term.ReadPassword(int(in.Fd()))
		fmt.Fprintln(cmd.ErrOrStderr())
		return password, err
	}
	password, err := read("Password (14–72 bytes): ")
	defer clear(password)
	if err != nil || len(password) < 14 || len(password) > 72 {
		return "", portalAccountInvalid(errors.New("password must contain 14–72 bytes"))
	}
	repeat, err := read("Repeat password: ")
	defer clear(repeat)
	if err != nil || !bytes.Equal(password, repeat) {
		return "", portalAccountInvalid(errors.New("password confirmation did not match"))
	}
	hash, err := bcrypt.GenerateFromPassword(password, portalAccountBcryptCost)
	if err != nil {
		return "", &conn.CommandError{Err: errors.New("could not hash password")}
	}
	return string(hash), nil
}

func exchangePortalAccount(s *conn.Session, q p.PortalAccountRequest, correlation uint32) (*p.PortalAccountResponse, error) {
	frame, err := p.EncodePortalAccountRequest(q, correlation)
	if err != nil {
		return nil, portalAccountInvalid(errors.New("could not encode portal account request"))
	}
	defer clear(frame)
	message, err := s.SendAndRecv(&p.Message{Opcode: p.C_PortalAccount, Data: frame[2:]})
	if err == nil && message.Opcode == p.S_PortalAccount {
		r, decodeErr := p.DecodePortalAccountResponse(message.Data)
		if decodeErr == nil && r.CorrelationID == correlation {
			if r.Status == "ok" {
				return r, nil
			}
			if q.Op == "import" && r.Status == "invalid" && r.ImportRow > 0 &&
				r.ImportRow <= len(q.Accounts) && r.ImportReason == "invalid_company_contact_binding" {
				return nil, &conn.ServerError{Message: fmt.Sprintf("account file row %d: company or contact is missing, or the contact is not a member of that company", r.ImportRow)}
			}
			return nil, portalAccountRejected(r.Status)
		}
	}
	// Do not print protocol payloads, including unexpected error strings.
	var rejected *conn.ServerError
	if errors.As(err, &rejected) && rejected.OriginOpcode == p.C_PortalAccount && rejected.CorrelationID == correlation {
		return nil, portalAccountRejected(rejected.Message)
	}
	if q.Op != "list" && q.Op != "get" && !q.DryRun {
		return nil, &conn.CommandError{Err: errors.New("portal account change unconfirmed; check current state before retrying")}
	}
	return nil, errors.New("no valid portal account response received")
}

func portalAccountRejected(status string) error {
	switch status {
	case "not_found":
		return &conn.ServerError{Message: "portal account not found"}
	case "conflict":
		return &conn.ServerError{Message: "portal account conflict; check current accounts and revisions"}
	case "forbidden":
		return &conn.ServerError{Message: "portal account administration is not authorized for this workspace"}
	case "invalid":
		return &conn.ServerError{Message: "invalid portal account request"}
	default:
		return &conn.ServerError{Message: "portal account request refused"}
	}
}

type portalAccountMetadata struct {
	ID        string `json:"id"`
	Revision  string `json:"revision"`
	Login     string `json:"login"`
	Requester string `json:"requester"`
	Name      string `json:"name"`
	CompanyID string `json:"company_id"`
	ContactID string `json:"contact_id"`
	Disabled  bool   `json:"disabled"`
}

func emitPortalAccount(cmd *cobra.Command, op string, resp *p.PortalAccountResponse) error {
	view := func(a p.PortalAccount) portalAccountMetadata {
		return portalAccountMetadata{a.ID, a.Revision, a.Login, a.Requester, a.Name, a.CompanyID, a.ContactID, a.Disabled}
	}
	var data any
	rows := make([]portalAccountMetadata, 0, len(resp.Accounts))
	if op == "list" || op == "import" {
		for _, a := range resp.Accounts {
			rows = append(rows, view(a))
		}
		data = struct {
			Status   string                  `json:"status"`
			Cursor   string                  `json:"cursor"`
			Accounts []portalAccountMetadata `json:"accounts"`
		}{resp.Status, resp.Cursor, rows}
	} else if resp.Account != nil {
		row := view(*resp.Account)
		rows = append(rows, row)
		data = row
	} else {
		if op == "get" {
			return errors.New("portal account response did not contain an account")
		}
		data = map[string]string{"status": resp.Status}
	}
	if !output.Human() {
		output.OutputJSON(data)
		return nil
	}
	w := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 4, 2, ' ', 0)
	if len(rows) != 0 || op == "list" {
		fmt.Fprintln(w, "ID\tREVISION\tLOGIN\tREQUESTER\tNAME\tCOMPANY\tCONTACT\tDISABLED")
		for _, a := range rows {
			fmt.Fprintf(w, "%q\t%q\t%q\t%q\t%q\t%q\t%q\t%t\n", a.ID, a.Revision, a.Login, a.Requester, a.Name, a.CompanyID, a.ContactID, a.Disabled)
		}
	} else {
		fmt.Fprintln(w, resp.Status)
	}
	if resp.Cursor != "" && op == "list" {
		fmt.Fprintf(w, "Next cursor: %q\n", resp.Cursor)
	}
	return w.Flush()
}
