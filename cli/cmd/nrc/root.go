package main

import (
	"fmt"

	"github.com/heavyhorst/nrc/cli/pkg/output"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

var version = "dev"

var rootCmd = &cobra.Command{
	Use:   "nrc",
	Short: "NRC - No Relay Chat CLI",
	Long:  "NRC - No Relay Chat CLI\n\nA command-line interface for NRC real-time collaboration.",
	PersistentPreRun: func(cmd *cobra.Command, args []string) {
		h, _ := cmd.Flags().GetBool("human")
		j, _ := cmd.Flags().GetBool("json")
		p, _ := cmd.Flags().GetBool("pretty")
		f, _ := cmd.Flags().GetString("fields")
		if err := output.Configure(h && !j, p, f); err != nil {
			output.Error("invalid_argument", err.Error(), false)
		}
		if f != "" && cmd.Annotations != nil && cmd.Annotations["mutation"] == "true" {
			output.Error("invalid_argument", "--fields is not supported for mutation commands", false)
		}
	},
	SilenceUsage:  true,
	SilenceErrors: true,
}

func useJSONOutput(cmd *cobra.Command) bool {
	jsonOutput, _ := cmd.Flags().GetBool("json")
	if jsonOutput {
		return true
	}
	humanOutput, _ := cmd.Flags().GetBool("human")
	return !humanOutput
}

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "Show version",
	Run: func(cmd *cobra.Command, args []string) {
		if useJSONOutput(cmd) {
			output.OutputJSON(map[string]any{"version": version})
		} else {
			fmt.Println("nrc", version)
		}
	},
}

func capabilities() map[string]any {
	var walk func(*cobra.Command) map[string]any
	walk = func(c *cobra.Command) map[string]any {
		entry := map[string]any{"name": c.Name(), "usage": c.Use, "commands": []any{}, "flags": []any{}, "mutation": c.Annotations != nil && c.Annotations["mutation"] == "true"}
		flags := []any{}
		_ = c.InheritedFlags()
		c.Flags().VisitAll(func(f *pflag.Flag) {
			if !f.Hidden {
				flags = append(flags, map[string]any{"name": f.Name, "usage": f.Usage, "type": f.Value.Type(), "default": f.DefValue, "required": f.Annotations[cobra.BashCompOneRequiredFlag] != nil, "repeatable": f.Value.Type() == "stringSlice" || f.Value.Type() == "stringArray", "comma_separated": f.Value.Type() == "stringSlice"})
			}
		})
		entry["flags"] = flags
		children := []any{}
		for _, child := range c.Commands() {
			if !child.Hidden && child.Name() != "help" {
				children = append(children, walk(child))
			}
		}
		entry["commands"] = children
		return entry
	}
	contract := map[string]any{"default": "json", "success": "one JSON document per command", "errors": map[string]any{"stream": "stderr", "shape": map[string]any{"error": map[string]any{"code": "string", "message": "string", "retryable": "boolean"}}}, "human_precedence": "--json overrides --human", "pretty": "indents JSON documents; JSONL remains compact", "fields": "comma-separated DTO resource projection; conflicts with --human and mutations", "chat_watch": "compact JSONL events"}
	return map[string]any{"cli_version": version, "output_contract_version": "1", "output_contract": contract, "command_tree": walk(rootCmd)}
}

var capabilitiesCmd = &cobra.Command{Use: "capabilities", Short: "Describe the machine-facing CLI contract", Args: cobra.NoArgs, Run: func(cmd *cobra.Command, args []string) { output.OutputJSON(capabilities()) }}

func init() {
	rootCmd.PersistentFlags().Bool("human", false, "Output in human-readable form")
	rootCmd.PersistentFlags().Bool("json", false, "Output as JSON (compatibility alias)")
	_ = rootCmd.PersistentFlags().MarkHidden("json")
	rootCmd.PersistentFlags().Bool("pretty", false, "Indent JSON output (not JSONL streams)")
	rootCmd.PersistentFlags().String("fields", "", "Comma-separated resource fields to select")
	rootCmd.AddCommand(versionCmd, capabilitiesCmd)
	for _, command := range []*cobra.Command{
		batchApplyCmd, taskCreateCmd, taskUpdateCmd, taskDeleteCmd, taskAttachCmd,
		assetCreateCmd, assetUpdateCmd, assetDeleteCmd, edgeCreateCmd, edgeDeleteCmd,
		reminderCreateCmd, reminderUpdateCmd, reminderDeleteCmd, agendaSetCmd,
		appointmentCreateCmd, appointmentUpdateCmd, appointmentDeleteCmd,
		dmStartCmd, dmLeaveCmd, chatSendCmd, configSetCmd, noteCreateCmd, noteUpdateCmd, noteAttachCmd,
		noteReplaceAttachmentCmd, noteRemoveAttachmentCmd, notePatchCmd, noteRevertCmd, noteDeleteCmd,
		noteDownloadAttachmentCmd,
	} {
		command.Annotations = map[string]string{"mutation": "true"}
	}
}
