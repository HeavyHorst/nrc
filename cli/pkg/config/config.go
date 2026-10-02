package config

import (
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Server      string `yaml:"server"`
	WorkspaceID string `yaml:"workspace_id"`
	RoomID      int64  `yaml:"room_id"`
	ProxyURL    string `yaml:"proxy_url"`
}

var defaultConfig = Config{
	Server:      "ws://localhost:8080",
	WorkspaceID: "workspace1",
	RoomID:      2,
	ProxyURL:    "",
}

func configPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	cfgDir := filepath.Join(home, ".config", "nrc")
	return filepath.Join(cfgDir, "config.yaml"), nil
}

func Load() (*Config, error) {
	path, err := configPath()
	if err != nil {
		return &defaultConfig, nil
	}

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return &defaultConfig, nil
		}
		return nil, err
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}

	// Fill missing fields with defaults
	if cfg.Server == "" {
		cfg.Server = defaultConfig.Server
	}
	if cfg.WorkspaceID == "" {
		cfg.WorkspaceID = defaultConfig.WorkspaceID
	}
	if cfg.RoomID == 0 {
		cfg.RoomID = defaultConfig.RoomID
	}
	if cfg.ProxyURL == "" {
		cfg.ProxyURL = defaultConfig.ProxyURL
	}

	return &cfg, nil
}

func (c *Config) Save() error {
	path, err := configPath()
	if err != nil {
		return err
	}

	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}

	data, err := yaml.Marshal(c)
	if err != nil {
		return err
	}

	return os.WriteFile(path, data, 0600)
}

func (c *Config) SetServer(server string) error {
	c.Server = server
	return c.Save()
}

func (c *Config) SetWorkspaceID(id string) error {
	c.WorkspaceID = id
	return c.Save()
}

func (c *Config) SetRoomID(id int64) error {
	c.RoomID = id
	return c.Save()
}

func (c *Config) SetProxyURL(proxyURL string) error {
	c.ProxyURL = proxyURL
	return c.Save()
}

// GetProxyURL returns the proxy URL, derived from server URL if not explicitly set
// Converts ws://host:port to http://host:port and wss://host:port to https://host:port
func (c *Config) GetProxyURL() string {
	if c.ProxyURL != "" {
		return c.ProxyURL
	}

	// Derive from server URL: ws://host:port -> http://host:port
	if strings.HasPrefix(c.Server, "wss://") {
		return "https://" + strings.TrimPrefix(c.Server, "wss://")
	} else if strings.HasPrefix(c.Server, "ws://") {
		return "http://" + strings.TrimPrefix(c.Server, "ws://")
	}

	return ""
}
