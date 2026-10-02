package main

import (
	"bytes"
	"encoding/binary"
	"encoding/gob"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"go.etcd.io/bbolt"
)

type QueueEntry struct {
	ConvID    uint64
	AssetType uint16
	Content   string
	Preview   string
	Metadata  SearchMetadata
	Version   uint64
}

type StoredEmbedding struct {
	ConvID      uint64
	ContentHash uint64
	Vector      []float32
	Chunks      []StoredChunkEmbedding
	AssetType   uint16
	Preview     string
	Payload     string
	Metadata    SearchMetadata
}

type StoredChunkEmbedding struct {
	Index  int
	Vector []float32
}

type RoomSyncState struct {
	LastFullSync time.Time
}

type Storage struct {
	db *bbolt.DB
}

var (
	bucketQueue            = []byte("queue")
	bucketEntityQueue      = []byte("entity_queue_v1")
	bucketEmbeddings       = []byte("embeddings")
	bucketEntityEmbeddings = []byte("entity_embeddings_v1")
	bucketRoomSync         = []byte("room_sync")
	bucketMeta             = []byte("meta")
	metaEmbeddingSchema    = []byte("embedding_schema")
)

func uint64ToKey(v uint64) []byte {
	b := make([]byte, 8)
	binary.BigEndian.PutUint64(b, v)
	return b
}

func keyToUint64(b []byte) uint64 {
	return binary.BigEndian.Uint64(b)
}

func gobEncode(v any) ([]byte, error) {
	var buf bytes.Buffer
	if err := gob.NewEncoder(&buf).Encode(v); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func gobDecode(data []byte, v any) error {
	return gob.NewDecoder(bytes.NewReader(data)).Decode(v)
}

func NewStorage(dataDir string) (*Storage, error) {
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}

	dbPath := filepath.Join(dataDir, "search.db")
	db, err := bbolt.Open(dbPath, 0o600, &bbolt.Options{Timeout: 1 * time.Second})
	if err != nil {
		return nil, fmt.Errorf("open bbolt db: %w", err)
	}

	err = db.Update(func(tx *bbolt.Tx) error {
		for _, name := range [][]byte{bucketQueue, bucketEntityQueue, bucketEmbeddings, bucketEntityEmbeddings, bucketRoomSync, bucketMeta} {
			if _, err := tx.CreateBucketIfNotExists(name); err != nil {
				return err
			}
		}
		return migrateLegacyEmbeddings(tx)
	})
	if err != nil {
		db.Close()
		return nil, fmt.Errorf("create buckets: %w", err)
	}

	slog.Info("storage opened", "path", dbPath)
	return &Storage{db: db}, nil
}

func entityStorageKey(identity EntityIdentity) ([]byte, error) {
	var typeByte byte
	switch identity.EntityType {
	case EntityTypeAsset:
		typeByte = 1
	case EntityTypeTask:
		typeByte = 2
	default:
		return nil, fmt.Errorf("unsupported entity type %q", identity.EntityType)
	}
	key := make([]byte, 17)
	key[0] = typeByte
	binary.BigEndian.PutUint64(key[1:9], identity.ConvID)
	binary.BigEndian.PutUint64(key[9:17], identity.EntityID)
	return key, nil
}

func identityFromStorageKey(workspace string, key []byte) (EntityIdentity, error) {
	if len(key) != 17 {
		return EntityIdentity{}, fmt.Errorf("invalid entity key length %d", len(key))
	}
	var typ EntityType
	switch key[0] {
	case 1:
		typ = EntityTypeAsset
	case 2:
		typ = EntityTypeTask
	default:
		return EntityIdentity{}, fmt.Errorf("invalid entity type tag %d", key[0])
	}
	return EntityIdentity{Workspace: workspace, EntityType: typ, ConvID: binary.BigEndian.Uint64(key[1:9]), EntityID: binary.BigEndian.Uint64(key[9:17])}, nil
}

func deleteEntityID(bucket *bbolt.Bucket, workspace string, typ EntityType, id uint64) error {
	if bucket == nil {
		return nil
	}
	cursor := bucket.Cursor()
	for key, _ := cursor.First(); key != nil; key, _ = cursor.Next() {
		identity, err := identityFromStorageKey(workspace, key)
		if err == nil && identity.EntityType == typ && identity.EntityID == id {
			if err := cursor.Delete(); err != nil {
				return err
			}
		}
	}
	return nil
}

func migrateLegacyEmbeddings(tx *bbolt.Tx) error {
	legacy := tx.Bucket(bucketEmbeddings)
	entities := tx.Bucket(bucketEntityEmbeddings)
	if legacy == nil || entities == nil {
		return nil
	}
	return legacy.ForEach(func(wsKey, value []byte) error {
		if value != nil {
			return fmt.Errorf("invalid legacy workspace record %q", string(wsKey))
		}
		legacyWS := legacy.Bucket(wsKey)
		if legacyWS == nil {
			return nil
		}
		entityWS, err := entities.CreateBucketIfNotExists(wsKey)
		if err != nil {
			return err
		}
		return legacyWS.ForEach(func(key, value []byte) error {
			if len(key) != 8 || value == nil {
				return fmt.Errorf("invalid legacy embedding key in workspace %q", string(wsKey))
			}
			var emb StoredEmbedding
			if err := gobDecode(value, &emb); err != nil {
				return fmt.Errorf("decode legacy embedding for workspace %q asset_id %d: %w", string(wsKey), keyToUint64(key), err)
			}
			entityKey, err := entityStorageKey(assetIdentity(string(wsKey), keyToUint64(key), emb.ConvID))
			if err != nil {
				return err
			}
			existing := entityWS.Get(entityKey)
			if existing == nil {
				return entityWS.Put(entityKey, value)
			}
			if !bytes.Equal(existing, value) {
				return fmt.Errorf("legacy embedding conflicts with typed entity: workspace=%q asset_id=%d conv_id=%d", string(wsKey), keyToUint64(key), emb.ConvID)
			}
			return nil
		})
	})
}

func (s *Storage) Close() error {
	return s.db.Close()
}

func hasWorkspaceData(parent *bbolt.Bucket) (bool, error) {
	if parent == nil {
		return false, nil
	}
	hasData := false
	err := parent.ForEach(func(k, v []byte) error {
		if v != nil {
			hasData = true
			return nil
		}
		sub := parent.Bucket(k)
		if sub != nil && sub.Stats().KeyN > 0 {
			hasData = true
		}
		return nil
	})
	return hasData, err
}

func clearWorkspaceBuckets(parent *bbolt.Bucket) error {
	if parent == nil {
		return nil
	}
	var buckets [][]byte
	err := parent.ForEach(func(k, v []byte) error {
		if v == nil {
			keyCopy := make([]byte, len(k))
			copy(keyCopy, k)
			buckets = append(buckets, keyCopy)
		}
		return nil
	})
	if err != nil {
		return err
	}
	for _, k := range buckets {
		if err := parent.DeleteBucket(k); err != nil {
			return err
		}
	}
	return nil
}

func (s *Storage) EnsureEmbeddingSchema(schema string) (migrated bool, previous string, err error) {
	err = s.db.Update(func(tx *bbolt.Tx) error {
		meta := tx.Bucket(bucketMeta)
		if meta == nil {
			return fmt.Errorf("metadata bucket missing")
		}

		current := meta.Get(metaEmbeddingSchema)
		if bytes.Equal(current, []byte(schema)) {
			return nil
		}

		needsReset := false
		if current == nil {
			legacyHasEmbeddings, err := hasWorkspaceData(tx.Bucket(bucketEmbeddings))
			if err != nil {
				return fmt.Errorf("check legacy embeddings: %w", err)
			}
			needsReset = legacyHasEmbeddings
		} else {
			previous = string(current)
			needsReset = true
		}

		if needsReset {
			if err := clearWorkspaceBuckets(tx.Bucket(bucketEmbeddings)); err != nil {
				return fmt.Errorf("clear embeddings: %w", err)
			}
			if err := clearWorkspaceBuckets(tx.Bucket(bucketEntityEmbeddings)); err != nil {
				return fmt.Errorf("clear entity embeddings: %w", err)
			}
			if err := clearWorkspaceBuckets(tx.Bucket(bucketRoomSync)); err != nil {
				return fmt.Errorf("clear room sync: %w", err)
			}
			migrated = true
		}

		return meta.Put(metaEmbeddingSchema, []byte(schema))
	})
	return migrated, previous, err
}

func (s *Storage) workspaceBucket(tx *bbolt.Tx, parent []byte, workspace string) (*bbolt.Bucket, error) {
	p := tx.Bucket(parent)
	if p == nil {
		return nil, fmt.Errorf("parent bucket %q not found", parent)
	}
	return p.CreateBucketIfNotExists([]byte(workspace))
}

func (s *Storage) workspaceBucketRead(tx *bbolt.Tx, parent []byte, workspace string) *bbolt.Bucket {
	p := tx.Bucket(parent)
	if p == nil {
		return nil
	}
	return p.Bucket([]byte(workspace))
}

func (s *Storage) EnqueueAsset(workspace string, assetID uint64, entry QueueEntry) error {
	val, err := gobEncode(entry)
	if err != nil {
		return fmt.Errorf("encode queue entry: %w", err)
	}

	return s.db.Update(func(tx *bbolt.Tx) error {
		b, err := s.workspaceBucket(tx, bucketQueue, workspace)
		if err != nil {
			return err
		}
		return b.Put(uint64ToKey(assetID), val)
	})
}

func (s *Storage) EnqueueEntity(identity EntityIdentity, entry QueueEntry) error {
	if err := identity.Validate(); err != nil {
		return err
	}
	if entry.ConvID != identity.ConvID {
		return fmt.Errorf("entity conv_id %d conflicts with queue conv_id %d", identity.ConvID, entry.ConvID)
	}
	value, err := gobEncode(entry)
	if err != nil {
		return fmt.Errorf("encode entity queue entry: %w", err)
	}
	key, err := entityStorageKey(identity)
	if err != nil {
		return err
	}
	return s.db.Update(func(tx *bbolt.Tx) error {
		bucket, err := s.workspaceBucket(tx, bucketEntityQueue, identity.Workspace)
		if err != nil {
			return err
		}
		return bucket.Put(key, value)
	})
}

func (s *Storage) DequeueAsset(workspace string) (assetID uint64, entry QueueEntry, ok bool, err error) {
	err = s.db.Update(func(tx *bbolt.Tx) error {
		b, err := s.workspaceBucket(tx, bucketQueue, workspace)
		if err != nil {
			return err
		}
		c := b.Cursor()
		k, v := c.First()
		if k == nil {
			return nil
		}

		assetID = keyToUint64(k)
		if err := gobDecode(v, &entry); err != nil {
			return fmt.Errorf("decode queue entry: %w", err)
		}
		ok = true

		return b.Delete(k)
	})
	return
}

func (s *Storage) StoreEmbedding(workspace string, assetID uint64, emb StoredEmbedding) error {
	val, err := gobEncode(emb)
	if err != nil {
		return fmt.Errorf("encode embedding: %w", err)
	}

	return s.db.Update(func(tx *bbolt.Tx) error {
		b, err := s.workspaceBucket(tx, bucketEmbeddings, workspace)
		if err != nil {
			return err
		}
		if err := b.Put(uint64ToKey(assetID), val); err != nil {
			return err
		}
		entityBucket, err := s.workspaceBucket(tx, bucketEntityEmbeddings, workspace)
		if err != nil {
			return err
		}
		if err := deleteEntityID(entityBucket, workspace, EntityTypeAsset, assetID); err != nil {
			return err
		}
		key, err := entityStorageKey(assetIdentity(workspace, assetID, emb.ConvID))
		if err != nil {
			return err
		}
		return entityBucket.Put(key, val)
	})
}

func (s *Storage) StoreEntityEmbedding(identity EntityIdentity, emb StoredEmbedding) error {
	if err := identity.Validate(); err != nil {
		return err
	}
	if emb.ConvID != 0 && emb.ConvID != identity.ConvID {
		return fmt.Errorf("entity conv_id %d conflicts with embedding conv_id %d", identity.ConvID, emb.ConvID)
	}
	emb.ConvID = identity.ConvID
	val, err := gobEncode(emb)
	if err != nil {
		return fmt.Errorf("encode embedding: %w", err)
	}
	key, err := entityStorageKey(identity)
	if err != nil {
		return err
	}
	return s.db.Update(func(tx *bbolt.Tx) error {
		bucket, err := s.workspaceBucket(tx, bucketEntityEmbeddings, identity.Workspace)
		if err != nil {
			return err
		}
		return bucket.Put(key, val)
	})
}

func (s *Storage) UpdateEntityEmbeddingMetadataAndCancelQueue(identity EntityIdentity, metadata SearchMetadata) (StoredEmbedding, bool, error) {
	if err := identity.Validate(); err != nil {
		return StoredEmbedding{}, false, err
	}
	key, err := entityStorageKey(identity)
	if err != nil {
		return StoredEmbedding{}, false, err
	}
	var embedding StoredEmbedding
	found := false
	err = s.db.Update(func(tx *bbolt.Tx) error {
		embeddings := s.workspaceBucketRead(tx, bucketEntityEmbeddings, identity.Workspace)
		if embeddings == nil {
			return nil
		}
		value := embeddings.Get(key)
		if value == nil {
			return nil
		}
		if err := gobDecode(value, &embedding); err != nil {
			return fmt.Errorf("decode entity embedding: %w", err)
		}
		embedding.Metadata = metadata
		updated, err := gobEncode(embedding)
		if err != nil {
			return fmt.Errorf("encode entity embedding: %w", err)
		}
		if err := embeddings.Put(key, updated); err != nil {
			return err
		}
		queue := s.workspaceBucketRead(tx, bucketEntityQueue, identity.Workspace)
		if queue != nil {
			if err := queue.Delete(key); err != nil {
				return err
			}
		}
		found = true
		return nil
	})
	return embedding, found, err
}

func (s *Storage) DeleteEntityState(identity EntityIdentity) error {
	if err := identity.Validate(); err != nil {
		return err
	}
	key, err := entityStorageKey(identity)
	if err != nil {
		return err
	}
	return s.db.Update(func(tx *bbolt.Tx) error {
		queue := s.workspaceBucketRead(tx, bucketEntityQueue, identity.Workspace)
		if queue != nil {
			if err := queue.Delete(key); err != nil {
				return err
			}
		}
		embeddings := s.workspaceBucketRead(tx, bucketEntityEmbeddings, identity.Workspace)
		if embeddings != nil {
			return embeddings.Delete(key)
		}
		return nil
	})
}

// CommitEntityEmbedding stores an embedding and consumes the queue entry only
// when that exact entry is still current. A newer live mutation or deletion
// therefore cannot be overwritten by an embedding job already in flight.
func (s *Storage) CommitEntityEmbedding(identity EntityIdentity, entry QueueEntry, emb StoredEmbedding) (bool, error) {
	if err := identity.Validate(); err != nil {
		return false, err
	}
	queueValue, err := gobEncode(entry)
	if err != nil {
		return false, fmt.Errorf("encode entity queue entry: %w", err)
	}
	emb.ConvID = identity.ConvID
	embValue, err := gobEncode(emb)
	if err != nil {
		return false, fmt.Errorf("encode embedding: %w", err)
	}
	key, err := entityStorageKey(identity)
	if err != nil {
		return false, err
	}
	committed := false
	err = s.db.Update(func(tx *bbolt.Tx) error {
		queue := s.workspaceBucketRead(tx, bucketEntityQueue, identity.Workspace)
		if queue == nil || !bytes.Equal(queue.Get(key), queueValue) {
			return nil
		}
		embeddings, err := s.workspaceBucket(tx, bucketEntityEmbeddings, identity.Workspace)
		if err != nil {
			return err
		}
		if err := embeddings.Put(key, embValue); err != nil {
			return err
		}
		if err := queue.Delete(key); err != nil {
			return err
		}
		committed = true
		return nil
	})
	return committed, err
}

func (s *Storage) DeleteEntityEmbedding(identity EntityIdentity) error {
	if err := identity.Validate(); err != nil {
		return err
	}
	return s.db.Update(func(tx *bbolt.Tx) error {
		bucket := s.workspaceBucketRead(tx, bucketEntityEmbeddings, identity.Workspace)
		if bucket == nil {
			return nil
		}
		key, err := entityStorageKey(identity)
		if err != nil {
			return err
		}
		return bucket.Delete(key)
	})
}

func (s *Storage) DeleteEmbedding(workspace string, assetID uint64) error {
	return s.db.Update(func(tx *bbolt.Tx) error {
		b, err := s.workspaceBucket(tx, bucketEmbeddings, workspace)
		if err != nil {
			return err
		}
		if err := b.Delete(uint64ToKey(assetID)); err != nil {
			return err
		}
		entities := s.workspaceBucketRead(tx, bucketEntityEmbeddings, workspace)
		if entities == nil {
			return nil
		}
		cursor := entities.Cursor()
		for key, _ := cursor.First(); key != nil; key, _ = cursor.Next() {
			identity, err := identityFromStorageKey(workspace, key)
			if err == nil && identity.EntityType == EntityTypeAsset && identity.EntityID == assetID {
				if err := cursor.Delete(); err != nil {
					return err
				}
			}
		}
		return nil
	})
}

func (s *Storage) LoadAllEntityEmbeddings() (map[EntityIdentity]StoredEmbedding, error) {
	result := make(map[EntityIdentity]StoredEmbedding)
	err := s.db.View(func(tx *bbolt.Tx) error {
		parent := tx.Bucket(bucketEntityEmbeddings)
		if parent == nil {
			return nil
		}
		return parent.ForEach(func(wsKey, value []byte) error {
			if value != nil {
				return fmt.Errorf("invalid entity workspace record %q", string(wsKey))
			}
			bucket := parent.Bucket(wsKey)
			return bucket.ForEach(func(key, value []byte) error {
				identity, err := identityFromStorageKey(string(wsKey), key)
				if err != nil {
					return fmt.Errorf("decode entity embedding key for workspace %q: %w", string(wsKey), err)
				}
				var emb StoredEmbedding
				if err := gobDecode(value, &emb); err != nil {
					return fmt.Errorf("decode entity embedding for workspace %q: %w", string(wsKey), err)
				}
				if emb.ConvID != identity.ConvID {
					return fmt.Errorf("entity embedding conv_id conflicts with key for workspace %q", string(wsKey))
				}
				result[identity] = emb
				return nil
			})
		})
	})
	return result, err
}

func (s *Storage) LoadAllEmbeddings(workspace string) (map[uint64]StoredEmbedding, error) {
	result := make(map[uint64]StoredEmbedding)

	err := s.db.View(func(tx *bbolt.Tx) error {
		b := s.workspaceBucketRead(tx, bucketEmbeddings, workspace)
		if b == nil {
			return nil
		}
		return b.ForEach(func(k, v []byte) error {
			var emb StoredEmbedding
			if err := gobDecode(v, &emb); err != nil {
				slog.Warn("skipping corrupt embedding", "asset_id", keyToUint64(k), "error", err)
				return nil
			}
			result[keyToUint64(k)] = emb
			return nil
		})
	})

	return result, err
}

func (s *Storage) LoadAllEmbeddingsAllWorkspaces() (map[string]map[uint64]StoredEmbedding, error) {
	result := make(map[string]map[uint64]StoredEmbedding)

	err := s.db.View(func(tx *bbolt.Tx) error {
		parent := tx.Bucket(bucketEmbeddings)
		if parent == nil {
			return nil
		}
		return parent.ForEach(func(wsKey, v []byte) error {
			if v != nil {
				return nil
			}
			ws := string(wsKey)
			sub := parent.Bucket(wsKey)
			if sub == nil {
				return nil
			}
			wsMap := make(map[uint64]StoredEmbedding)
			err := sub.ForEach(func(k, v []byte) error {
				var emb StoredEmbedding
				if err := gobDecode(v, &emb); err != nil {
					slog.Warn("skipping corrupt embedding", "workspace", ws, "asset_id", keyToUint64(k), "error", err)
					return nil
				}
				wsMap[keyToUint64(k)] = emb
				return nil
			})
			if err != nil {
				return err
			}
			if len(wsMap) > 0 {
				result[ws] = wsMap
			}
			return nil
		})
	})

	return result, err
}

func (s *Storage) GetRoomSync(workspace string, convID uint64) (RoomSyncState, bool, error) {
	var state RoomSyncState
	var found bool

	err := s.db.View(func(tx *bbolt.Tx) error {
		b := s.workspaceBucketRead(tx, bucketRoomSync, workspace)
		if b == nil {
			return nil
		}
		v := b.Get(uint64ToKey(convID))
		if v == nil {
			return nil
		}
		if err := gobDecode(v, &state); err != nil {
			return fmt.Errorf("decode room sync state: %w", err)
		}
		found = true
		return nil
	})

	return state, found, err
}

func (s *Storage) SetRoomSync(workspace string, convID uint64, state RoomSyncState) error {
	val, err := gobEncode(state)
	if err != nil {
		return fmt.Errorf("encode room sync state: %w", err)
	}

	return s.db.Update(func(tx *bbolt.Tx) error {
		b, err := s.workspaceBucket(tx, bucketRoomSync, workspace)
		if err != nil {
			return err
		}
		return b.Put(uint64ToKey(convID), val)
	})
}

func (s *Storage) DeleteEmbeddingsByConvID(workspace string, convID uint64) error {
	return s.db.Update(func(tx *bbolt.Tx) error {
		b, err := s.workspaceBucket(tx, bucketEmbeddings, workspace)
		if err != nil {
			return err
		}
		c := b.Cursor()

		var toDelete [][]byte
		for k, v := c.First(); k != nil; k, v = c.Next() {
			var emb StoredEmbedding
			if err := gobDecode(v, &emb); err != nil {
				slog.Warn("skipping corrupt embedding during delete", "asset_id", keyToUint64(k), "error", err)
				continue
			}
			if emb.ConvID == convID {
				keyCopy := make([]byte, len(k))
				copy(keyCopy, k)
				toDelete = append(toDelete, keyCopy)
			}
		}

		for _, k := range toDelete {
			if err := b.Delete(k); err != nil {
				return err
			}
		}

		entities := s.workspaceBucketRead(tx, bucketEntityEmbeddings, workspace)
		if entities != nil {
			cursor := entities.Cursor()
			for key, _ := cursor.First(); key != nil; key, _ = cursor.Next() {
				identity, err := identityFromStorageKey(workspace, key)
				if err == nil && identity.EntityType == EntityTypeAsset && identity.ConvID == convID {
					if err := cursor.Delete(); err != nil {
						return err
					}
				}
			}
		}

		return nil
	})
}

func (s *Storage) PeekQueueEntry(workspace string) (assetID uint64, entry QueueEntry, ok bool, err error) {
	err = s.db.View(func(tx *bbolt.Tx) error {
		b := s.workspaceBucketRead(tx, bucketQueue, workspace)
		if b == nil {
			return nil
		}
		c := b.Cursor()
		k, v := c.First()
		if k == nil {
			return nil
		}
		assetID = keyToUint64(k)
		if err := gobDecode(v, &entry); err != nil {
			return fmt.Errorf("decode queue entry: %w", err)
		}
		ok = true
		return nil
	})
	return
}

func (s *Storage) PeekEntityQueueEntry(workspace string) (identity EntityIdentity, entry QueueEntry, ok bool, err error) {
	err = s.db.View(func(tx *bbolt.Tx) error {
		bucket := s.workspaceBucketRead(tx, bucketEntityQueue, workspace)
		if bucket == nil {
			return nil
		}
		key, value := bucket.Cursor().First()
		if key == nil {
			return nil
		}
		var decodeErr error
		identity, decodeErr = identityFromStorageKey(workspace, key)
		if decodeErr != nil {
			return fmt.Errorf("decode entity queue key: %w", decodeErr)
		}
		if err := gobDecode(value, &entry); err != nil {
			return fmt.Errorf("decode entity queue entry: %w", err)
		}
		ok = true
		return nil
	})
	return
}

func (s *Storage) GetEntityQueueEntry(identity EntityIdentity) (entry QueueEntry, ok bool, err error) {
	if err := identity.Validate(); err != nil {
		return entry, false, err
	}
	key, err := entityStorageKey(identity)
	if err != nil {
		return entry, false, err
	}
	err = s.db.View(func(tx *bbolt.Tx) error {
		bucket := s.workspaceBucketRead(tx, bucketEntityQueue, identity.Workspace)
		if bucket == nil {
			return nil
		}
		value := bucket.Get(key)
		if value == nil {
			return nil
		}
		if err := gobDecode(value, &entry); err != nil {
			return fmt.Errorf("decode entity queue entry: %w", err)
		}
		ok = true
		return nil
	})
	return
}

func (s *Storage) EntityQueueIdentities(workspace string, entityType EntityType, convID uint64) ([]EntityIdentity, error) {
	var identities []EntityIdentity
	err := s.db.View(func(tx *bbolt.Tx) error {
		bucket := s.workspaceBucketRead(tx, bucketEntityQueue, workspace)
		if bucket == nil {
			return nil
		}
		return bucket.ForEach(func(key, value []byte) error {
			if value == nil {
				return nil
			}
			identity, err := identityFromStorageKey(workspace, key)
			if err != nil {
				return err
			}
			if identity.EntityType == entityType && identity.ConvID == convID {
				identities = append(identities, identity)
			}
			return nil
		})
	})
	return identities, err
}

func (s *Storage) DeleteEntityQueueEntry(identity EntityIdentity) error {
	if err := identity.Validate(); err != nil {
		return err
	}
	key, err := entityStorageKey(identity)
	if err != nil {
		return err
	}
	return s.db.Update(func(tx *bbolt.Tx) error {
		bucket := s.workspaceBucketRead(tx, bucketEntityQueue, identity.Workspace)
		if bucket == nil {
			return nil
		}
		return bucket.Delete(key)
	})
}

func (s *Storage) DeleteEntityQueueEntryIfCurrent(identity EntityIdentity, entry QueueEntry) (bool, error) {
	if err := identity.Validate(); err != nil {
		return false, err
	}
	key, err := entityStorageKey(identity)
	if err != nil {
		return false, err
	}
	value, err := gobEncode(entry)
	if err != nil {
		return false, err
	}
	deleted := false
	err = s.db.Update(func(tx *bbolt.Tx) error {
		bucket := s.workspaceBucketRead(tx, bucketEntityQueue, identity.Workspace)
		if bucket == nil || !bytes.Equal(bucket.Get(key), value) {
			return nil
		}
		deleted = true
		return bucket.Delete(key)
	})
	return deleted, err
}

func (s *Storage) DeleteQueueEntry(workspace string, assetID uint64) error {
	return s.db.Update(func(tx *bbolt.Tx) error {
		b, err := s.workspaceBucket(tx, bucketQueue, workspace)
		if err != nil {
			return err
		}
		return b.Delete(uint64ToKey(assetID))
	})
}

func (s *Storage) QueueSize(workspace string) (int, error) {
	var count int

	err := s.db.View(func(tx *bbolt.Tx) error {
		b := s.workspaceBucketRead(tx, bucketQueue, workspace)
		if b == nil {
			return nil
		}
		count = b.Stats().KeyN
		return nil
	})

	return count, err
}
