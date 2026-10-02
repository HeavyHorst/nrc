package main

import (
	"fmt"
	"strings"

	"github.com/heavyhorst/nrc/protocol-go"
)

type EntityType string

const (
	EntityTypeAsset EntityType = "asset"
	EntityTypeTask  EntityType = "task"
)

func (t EntityType) Valid() bool {
	return t == EntityTypeAsset || t == EntityTypeTask
}

type EntityIdentity struct {
	Workspace  string     `json:"workspace,omitempty"`
	EntityType EntityType `json:"type"`
	EntityID   uint64     `json:"id,string"`
	ConvID     uint64     `json:"conv_id,string"`
}

func (id EntityIdentity) Validate() error {
	if id.Workspace == "" {
		return fmt.Errorf("workspace is required")
	}
	if !id.EntityType.Valid() {
		return fmt.Errorf("unsupported entity type %q", id.EntityType)
	}
	if id.EntityID == 0 {
		return fmt.Errorf("entity id is required")
	}
	return nil
}

type entityKey struct {
	EntityType EntityType
	EntityID   uint64
	ConvID     uint64
}

func (id EntityIdentity) key() entityKey {
	return entityKey{EntityType: id.EntityType, EntityID: id.EntityID, ConvID: id.ConvID}
}

func assetIdentity(workspace string, assetID, convID uint64) EntityIdentity {
	return EntityIdentity{Workspace: workspace, EntityType: EntityTypeAsset, EntityID: assetID, ConvID: convID}
}

func taskIdentity(workspace string, taskID, convID uint64) EntityIdentity {
	return EntityIdentity{Workspace: workspace, EntityType: EntityTypeTask, EntityID: taskID, ConvID: convID}
}

func identityLess(a, b EntityIdentity) bool {
	if a.EntityType != b.EntityType {
		return a.EntityType < b.EntityType
	}
	if a.EntityID != b.EntityID {
		return a.EntityID < b.EntityID
	}
	return a.ConvID < b.ConvID
}

func resultIdentity(identity EntityIdentity, legacyAssetID uint64) EntityIdentity {
	if identity.EntityType == "" {
		identity.EntityType = EntityTypeAsset
		identity.EntityID = legacyAssetID
	}
	return identity
}

type SearchMetadata struct {
	AssetType uint16        `json:"asset_type,omitempty"`
	Task      *TaskMetadata `json:"task,omitempty"`
}

type TaskMetadata = protocol.SearchTaskMetadata

func taskMetadata(task *protocol.Task) SearchMetadata {
	return SearchMetadata{Task: &TaskMetadata{
		Status: task.Status, OrderIndex: task.OrderIndex, Assignee: task.Assignee,
		Priority: task.Priority, Color: task.Color, CreatedBy: task.CreatedBy,
		CreatedAt: task.CreatedAt, UpdatedAt: task.UpdatedAt, ExternalRef: task.ExternalRef,
		DueAt: task.DueAt, BlockedBy: task.BlockedBy, CompletedAt: task.CompletedAt,
		CompletedBy: task.CompletedBy, Project: task.Project,
	}}
}

func taskEmbeddingContent(task *protocol.Task) (string, string) {
	parts := make([]string, 0, 4)
	if value := strings.TrimSpace(task.Description); value != "" {
		parts = append(parts, value)
	}
	if value := strings.TrimSpace(task.Project); value != "" {
		parts = append(parts, "Project: "+value)
	}
	if value := strings.TrimSpace(task.Assignee); value != "" {
		parts = append(parts, "Assignee: "+value)
	}
	if value := strings.TrimSpace(task.ExternalRef); value != "" {
		parts = append(parts, "External reference: "+value)
	}
	return task.Title, strings.Join(parts, "\n")
}

type SearchFilters struct {
	EntityTypes []EntityType `json:"entity_types,omitempty"`
	AssetTypes  []uint16     `json:"asset_types,omitempty"`
	Task        *TaskFilters `json:"task,omitempty"`
}

type TaskFilters = protocol.SearchTaskFilters
