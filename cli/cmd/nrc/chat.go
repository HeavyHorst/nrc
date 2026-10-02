package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"

	conn "github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

type chatMessageEvent struct {
	Event       string `json:"event"`
	RoomID      int64  `json:"room_id"`
	Sequence    int64  `json:"sequence"`
	Username    string `json:"username"`
	Timestamp   int64  `json:"timestamp"`
	ContentType uint8  `json:"content_type"`
	Content     string `json:"content"`
}

const chatSendCorrelationID uint32 = 1

func parseClientMessageID(value string) (protocol.ClientMessageID, error) {
	var id protocol.ClientMessageID
	compact := strings.ReplaceAll(value, "-", "")
	if len(compact) != hex.EncodedLen(len(id)) {
		return id, fmt.Errorf("client message ID must contain 32 hexadecimal characters")
	}
	decoded, err := hex.DecodeString(compact)
	if err != nil {
		return id, fmt.Errorf("client message ID must contain only hexadecimal characters")
	}
	copy(id[:], decoded)
	if id == (protocol.ClientMessageID{}) {
		return id, fmt.Errorf("client message ID must not be zero")
	}
	return id, nil
}

func buildChatSendMessage(roomID int64, message string, contentType uint8, retained bool, clientMessageID protocol.ClientMessageID) (*protocol.Message, error) {
	if !retained {
		return &protocol.Message{Opcode: protocol.C_SendMessage, Data: protocol.EncodeChatMessage(roomID, message, contentType)}, nil
	}
	data, err := protocol.EncodeSendMessageV2(uint64(roomID), clientMessageID, chatSendCorrelationID, contentType, message)
	if err != nil {
		return nil, err
	}
	return &protocol.Message{Opcode: protocol.C_SendMessageV2, Data: data}, nil
}

func validateRetainedChatAck(resp *protocol.Message) (*protocol.AckSendMessage, error) {
	if resp.Opcode != protocol.S_AckSendMessage {
		return nil, fmt.Errorf("unexpected response: %d (expected %d for S_AckSendMessage)", resp.Opcode, protocol.S_AckSendMessage)
	}
	ack, err := protocol.DecodeAckSendMessage(resp.Data)
	if err != nil {
		return nil, fmt.Errorf("decoding retained message acknowledgement: %w", err)
	}
	if ack.ClientReqID != chatSendCorrelationID {
		return nil, fmt.Errorf("unexpected retained message correlation ID: %d", ack.ClientReqID)
	}
	if ack.AssignedSeq == 0 {
		return nil, fmt.Errorf("retained message acknowledgement has zero sequence")
	}
	return ack, nil
}

func outputRetainedChatSuccess(ack *protocol.AckSendMessage, clientMessageID string) {
	message := fmt.Sprintf("Retained message sent (sequence %d, timestamp %d Unix ns, client message ID %s)", ack.AssignedSeq, ack.Timestamp, clientMessageID)
	output.Mutation("sent", "message", ack.AssignedSeq, message, nil, map[string]any{"retained": true, "sequence": ack.AssignedSeq, "timestamp": ack.Timestamp, "client_message_id": clientMessageID})
}

func retainedSendUnknownMessage(clientMessageID string, err error) string {
	return fmt.Sprintf("Retained message outcome is unknown (client_message_id=%s); retry with --retained --client-message-id %s: %v", clientMessageID, clientMessageID, err)
}

// receiveChan wraps client.Recv to work with select
func receiveChan(s *conn.Session) <-chan *protocol.Message {
	ch := make(chan *protocol.Message, 1)
	go func() {
		msg, ok := s.Client.Recv()
		if ok {
			ch <- msg
		}
		close(ch)
	}()
	return ch
}

var chatCmd = &cobra.Command{
	Use:   "chat",
	Short: "Send/watch messages",
}

var chatSendCmd = &cobra.Command{
	Use:   "send <message>",
	Short: "Send message to room",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		markdown, _ := cmd.Flags().GetBool("markdown")
		retained, _ := cmd.Flags().GetBool("retained")
		clientMessageIDFlag, _ := cmd.Flags().GetString("client-message-id")
		message := args[0]
		if !retained && clientMessageIDFlag != "" {
			conn.FatalInvalid("--client-message-id requires --retained")
		}

		var clientMessageID protocol.ClientMessageID
		if retained {
			if clientMessageIDFlag != "" {
				var err error
				clientMessageID, err = parseClientMessageID(clientMessageIDFlag)
				if err != nil {
					conn.FatalInvalid("Invalid --client-message-id: %v", err)
				}
			} else if _, err := rand.Read(clientMessageID[:]); err != nil {
				conn.Fatal("Error generating client message ID: %v", err)
			} else if clientMessageID == (protocol.ClientMessageID{}) {
				clientMessageID[len(clientMessageID)-1] = 1
			}
		}
		clientMessageIDText := hex.EncodeToString(clientMessageID[:])

		s, err := conn.DialChat(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		contentType := uint8(protocol.ContentTypePlainText)
		if markdown {
			contentType = uint8(protocol.ContentTypeMarkdown)
		}

		msg, err := buildChatSendMessage(s.RoomID, message, contentType, retained, clientMessageID)
		if err != nil {
			conn.FatalInvalid("Invalid message: %v", err)
		}

		resp, err := s.SendAndRecv(msg)
		if err != nil {
			if retained && conn.Classify(err).Retryable {
				classification := conn.Classify(err)
				output.Error(classification.Code, retainedSendUnknownMessage(clientMessageIDText, err), classification.Retryable)
			}
			conn.Fatal("Error: %v", err)
		}

		if !retained {
			output.Mutation("sent", "message", 0, "Message sent", nil, map[string]any{"retained": false})
			return
		}
		ack, err := validateRetainedChatAck(resp)
		if err != nil {
			output.Error("unexpected_response", retainedSendUnknownMessage(clientMessageIDText, err), true)
		}
		outputRetainedChatSuccess(ack, clientMessageIDText)
	},
}

var chatWatchCmd = &cobra.Command{
	Use:   "watch",
	Short: "Watch messages in real-time (Ctrl+C to exit)",
	Args:  cobra.NoArgs,
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")

		s, err := conn.DialLongRunning(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		// Subscribe to room
		msg := &protocol.Message{
			Opcode: protocol.C_SubscribeConvs,
			Data:   protocol.EncodeSubscribeConvs(s.RoomID),
		}
		if err := s.Client.Send(msg); err != nil {
			conn.Fatal("Error subscribing: %v", err)
		}

		// Skip S_ServerReady if present (sends S_RoomPresenceUpdate after subscribing)
		resp, ok := s.Client.RecvSkipServerReady(protocol.S_RoomPresenceUpdate)
		if !ok {
			conn.Fatal("Connection closed")
		}
		if resp.Opcode == protocol.S_ErrorResponse {
			conn.Fatal("Error: %v", conn.DecodeServerError(resp.Data))
		}

		// Setup signal handler for graceful exit
		sigChan := make(chan os.Signal, 1)
		signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

		if output.Human() {
			output.PrintSuccess("Watching room %d (Ctrl+C to exit)...", s.RoomID)
		} else {
			output.OutputJSONLine(map[string]any{"event": "watch_started", "room_id": s.RoomID})
		}

		// Enter message loop
		for {
			select {
			case <-sigChan:
				if output.Human() {
					fmt.Println("\nExiting...")
				} else {
					output.OutputJSONLine(map[string]any{"event": "watch_stopped", "room_id": s.RoomID})
				}
				return
			case resp, ok := <-receiveChan(s):
				if !ok {
					if output.Human() {
						fmt.Println("Connection closed")
					} else {
						output.OutputJSONLine(map[string]any{"event": "connection_closed", "room_id": s.RoomID})
					}
					return
				}

				if resp.Opcode == protocol.S_NewMessage {
					chatMsg, err := protocol.DecodeChatMessage(resp.Data)
					if err != nil {
						if output.Human() {
							fmt.Printf("[error] %v\n", err)
						} else {
							output.OutputJSONLine(map[string]any{"event": "decode_error", "message": err.Error()})
						}
					} else {
						if output.Human() {
							fmt.Printf("%-15s: %s\n", chatMsg.Username, chatMsg.Content)
						} else {
							output.OutputJSONLine(chatMessageEvent{Event: "message", RoomID: int64(chatMsg.ConvID), Sequence: chatMsg.Sequence, Username: chatMsg.Username, Timestamp: chatMsg.Timestamp, ContentType: uint8(chatMsg.ContentType), Content: chatMsg.Content})
						}
					}
				}
			}
		}
	},
}

func init() {
	chatCmd.PersistentFlags().String("room", "", "Room name or ID (default: configured room)")

	chatSendCmd.Flags().Bool("markdown", false, "Send as markdown")
	chatSendCmd.Flags().Bool("retained", false, "Store the room message for the server's configured retention window")
	chatSendCmd.Flags().String("client-message-id", "", "Reuse a retained message ID for a safe retry (32 hex characters; hyphens allowed)")

	chatCmd.AddCommand(chatSendCmd)
	chatCmd.AddCommand(chatWatchCmd)

	rootCmd.AddCommand(chatCmd)
}
