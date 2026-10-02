package protocol

const (
	RetrievePayloadNone           = "none"
	RetrievePayloadTop            = "top"
	RetrievePayloadAll            = "all"
	RetrievePayloadStateComplete  = "complete"
	RetrievePayloadStateOmitted   = "omitted"
	RetrievePayloadStateTruncated = "truncated"

	RetrievePathsNone = "none"
	RetrievePathsBest = "best"
	RetrievePathsAll  = "all"
)

// RetrieveRequest asks nrc-ai for one fused search and graph retrieval bundle.
type RetrieveRequest struct {
	Workspace       string   `json:"workspace"`
	ConvID          uint64   `json:"conv_id,string"`
	Query           string   `json:"query"`
	TopN            int      `json:"top_n,omitempty"`
	Depth           uint8    `json:"depth,omitempty"`
	Relations       []string `json:"relations,omitempty"`
	Direction       string   `json:"direction,omitempty"`
	NoGraph         bool     `json:"no_graph,omitempty"`
	PayloadMode     string   `json:"payload,omitempty"`
	PayloadTop      int      `json:"payload_top,omitempty"`
	MaxPayloadBytes int      `json:"max_payload_bytes,omitempty"`
	PathMode        string   `json:"paths,omitempty"`
}

type RetrieveEntityRef struct {
	Type SearchEntityType `json:"type"`
	ID   uint64           `json:"id,string"`
}

type RetrievePath struct {
	Anchor  RetrieveEntityRef `json:"anchor"`
	Depth   uint8             `json:"depth"`
	EdgeIDs SearchIDs         `json:"edges"`
}

type RetrieveResult struct {
	Type         SearchEntityType `json:"type"`
	ID           uint64           `json:"id,string"`
	Rank         int              `json:"rank"`
	Score        float64          `json:"score"`
	Origins      []string         `json:"origins"`
	Title        string           `json:"title,omitempty"`
	Project      string           `json:"project,omitempty"`
	Tags         []string         `json:"tags,omitempty"`
	Format       string           `json:"format,omitempty"`
	Teaser       string           `json:"teaser,omitempty"`
	Metadata     *SearchMetadata  `json:"metadata,omitempty"`
	Payload      string           `json:"payload,omitempty"`
	PayloadState string           `json:"payload_state"`
	Evidence     []RetrievePath   `json:"evidence,omitempty"`
}

type RetrieveEdge struct {
	ID       uint64            `json:"id,string"`
	From     RetrieveEntityRef `json:"from"`
	To       RetrieveEntityRef `json:"to"`
	Relation string            `json:"relation"`
}

type RetrieveTruncation struct {
	Results  bool `json:"results,omitempty"`
	Graph    bool `json:"graph,omitempty"`
	Payloads bool `json:"payloads,omitempty"`
}

type RetrieveResponse struct {
	Workspace        string             `json:"workspace"`
	ConvID           uint64             `json:"conv_id,string"`
	Query            string             `json:"query"`
	Stale            bool               `json:"stale,omitempty"`
	Truncation       RetrieveTruncation `json:"truncation,omitempty"`
	GraphEnabled     bool               `json:"graph_enabled"`
	GraphContributed bool               `json:"graph_contributed"`
	Warnings         []string           `json:"warnings,omitempty"`
	Results          []RetrieveResult   `json:"results"`
	Edges            []RetrieveEdge     `json:"edges,omitempty"`
}
