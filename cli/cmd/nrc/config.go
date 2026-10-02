package main

import (
	"fmt"
	"strconv"

	"github.com/heavyhorst/nrc/cli/pkg/config"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	"github.com/spf13/cobra"
)

var configCmd = &cobra.Command{
	Use:   "config",
	Short: "Manage configuration",
}

var configShowCmd = &cobra.Command{
	Use:   "show",
	Short: "Show current configuration",
	Run: func(cmd *cobra.Command, args []string) {
		cfg, err := config.Load()
		if err != nil {
			output.Error("command_failed", fmt.Sprintf("Error loading config: %v", err), false)
		}

		if !output.Human() {
			output.OutputJSON(map[string]any{"server": cfg.Server, "workspace": cfg.WorkspaceID, "room": cfg.RoomID, "proxy": cfg.GetProxyURL()})
			return
		}
		fmt.Println("Current configuration:")
		fmt.Printf("  server:    %s\n", cfg.Server)
		fmt.Printf("  workspace: %s\n", cfg.WorkspaceID)
		fmt.Printf("  room:      %d\n", cfg.RoomID)
		if cfg.ProxyURL != "" {
			fmt.Printf("  proxy:     %s\n", cfg.ProxyURL)
		} else if proxyURL := cfg.GetProxyURL(); proxyURL != "" {
			fmt.Printf("  proxy:     %s (derived)\n", proxyURL)
		} else {
			fmt.Printf("  proxy:     (unset)\n")
		}
	},
}

var configSetCmd = &cobra.Command{
	Use:   "set <key> <value>",
	Short: "Set configuration value",
	Long:  "Set configuration value\n\nKeys: server, workspace, room, proxy",
	Args:  cobra.ExactArgs(2),
	Run: func(cmd *cobra.Command, args []string) {
		key := args[0]
		value := args[1]

		cfg, err := config.Load()
		if err != nil {
			output.Error("command_failed", fmt.Sprintf("Error loading config: %v", err), false)
		}

		switch key {
		case "server":
			if err := cfg.SetServer(value); err != nil {
				output.Error("command_failed", fmt.Sprintf("Error setting server: %v", err), false)
			}
			if output.Human() {
				fmt.Printf("Server set to: %s\n", value)
			}

		case "workspace":
			if err := cfg.SetWorkspaceID(value); err != nil {
				output.Error("command_failed", fmt.Sprintf("Error setting workspace: %v", err), false)
			}
			if output.Human() {
				fmt.Printf("Workspace set to: %s\n", value)
			}

		case "room":
			roomID, err := strconv.ParseInt(value, 10, 64)
			if err != nil {
				output.Error("invalid_argument", fmt.Sprintf("Invalid room ID: %v", err), false)
			}
			if err := cfg.SetRoomID(roomID); err != nil {
				output.Error("command_failed", fmt.Sprintf("Error setting room: %v", err), false)
			}
			if output.Human() {
				fmt.Printf("Room set to: %d\n", roomID)
			}

		case "proxy", "proxy-url":
			proxyURL := value
			if value == "auto" {
				proxyURL = ""
			}
			if err := cfg.SetProxyURL(proxyURL); err != nil {
				output.Error("command_failed", fmt.Sprintf("Error setting proxy: %v", err), false)
			}
			if output.Human() && proxyURL == "" {
				fmt.Printf("Proxy URL cleared; using derived value: %s\n", cfg.GetProxyURL())
			} else if output.Human() {
				fmt.Printf("Proxy URL set to: %s\n", proxyURL)
			}

		default:
			output.Error("invalid_argument", fmt.Sprintf("Unknown key: %s", key), false)
		}
		if !output.Human() {
			output.Mutation("set", "config", 0, "", nil, map[string]any{"key": key, "value": value})
		}
	},
}

func init() {
	configCmd.AddCommand(configShowCmd)
	configCmd.AddCommand(configSetCmd)
	rootCmd.AddCommand(configCmd)
}
