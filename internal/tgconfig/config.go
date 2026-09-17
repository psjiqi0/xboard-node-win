package tgconfig

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
)

type Config struct {
	mu           sync.RWMutex
	path         string
	BotToken     string   `json:"bot_token"`
	ChatID       int64    `json:"chat_id"`
	AllowedUsers []int64  `json:"allowed_users"`
	MonitorOn    bool     `json:"monitor_on"`
}

func DefaultPath() string {
	if p := os.Getenv("TG_MONBOT_CONFIG"); p != "" {
		return p
	}
	for _, d := range []string{"/etc/tg-monbot", "/tmp/tg-monbot"} {
		if _, err := os.Stat(d); err == nil {
			return filepath.Join(d, "config.json")
		}
	}
	return "/etc/tg-monbot/config.json"
}

func Load(path string) (*Config, error) {
	cfg := &Config{
		path:      path,
		MonitorOn: true,
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return cfg, cfg.Save()
		}
		return nil, err
	}
	if err := json.Unmarshal(data, cfg); err != nil {
		return nil, err
	}
	cfg.path = path
	return cfg, nil
}

func (c *Config) Save() error {
	c.mu.RLock()
	defer c.mu.RUnlock()
	dir := filepath.Dir(c.path)
	os.MkdirAll(dir, 0755)
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(c.path, data, 0600)
}

func (c *Config) IsAllowed(userID int64) bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	for _, id := range c.AllowedUsers {
		if id == userID {
			return true
		}
	}
	return false
}

func (c *Config) IsEnabled() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.ChatID != 0 && len(c.AllowedUsers) > 0
}

func (c *Config) AddAllowed(userID int64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, id := range c.AllowedUsers {
		if id == userID {
			return
		}
	}
	c.AllowedUsers = append(c.AllowedUsers, userID)
}