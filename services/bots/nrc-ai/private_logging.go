package main

import (
	"fmt"
	"log/slog"
)

// Provider errors, NRC errors and tool arguments can echo personal content.
// Apply this allowlist at the process sink, including background I/O goroutines
// without a request context. New attributes are private unless reviewed here.
func metadataLogAttr(groups []string, a slog.Attr) slog.Attr {
	if len(groups) != 0 {
		return slog.Attr{}
	}
	if a.Key == "error" {
		return slog.String("error_type", fmt.Sprintf("%T", a.Value.Any()))
	}
	switch a.Key {
	case slog.TimeKey, slog.LevelKey, slog.MessageKey,
		"request_id", "provider", "model", "phase", "duration_ms", "status", "cancelled",
		"attempt", "attempts", "max_attempts", "delay", "failed", "tool", "workspace", "conv_id",
		"input_tokens", "output_tokens", "reasoning_tokens", "cache_read_tokens", "cache_creation_tokens", "finish_reason",
		"count", "has_more", "origin_opcode", "correlation_id", "timeout", "new_client",
		"port", "llm_provider", "llm_model", "llm_max_output_tokens":
		return a
	}
	return slog.Attr{}
}
