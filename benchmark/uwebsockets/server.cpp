#include <App.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <string_view>
#include <syncstream>
#include <thread>
#include <type_traits>
#include <unordered_set>
#include <vector>

struct Socket_Data {
    std::string workspace;
    std::string username;
    std::unordered_set<int64_t> subscriptions;
};

namespace {

constexpr uint16_t C_SendMessage = 1;
constexpr uint16_t C_SubscribeConvs = 2;
constexpr uint16_t C_Stats = 8;
constexpr uint16_t C_Ping = 19;

constexpr uint16_t S_ServerReady = 100;
constexpr uint16_t S_NewMessage = 102;
constexpr uint16_t S_AckSendMessage = 103;
constexpr uint16_t S_StatsResponse = 110;
constexpr uint16_t S_Pong = 126;

constexpr uint32_t PROTOCOL_VERSION = 2;

std::atomic<uint64_t> g_message_seq{0};
std::atomic<uint32_t> g_connection_count{0};
uint32_t g_server_threads = 1;

template <typename T>
void append_be(std::string &out, T value) {
    static_assert(std::is_integral_v<T>, "append_be only supports integral types");
    using U = std::make_unsigned_t<T>;
    U u = static_cast<U>(value);
    for (int shift = static_cast<int>(sizeof(T) * 8) - 8; shift >= 0; shift -= 8) {
        out.push_back(static_cast<char>((u >> static_cast<unsigned>(shift)) & static_cast<U>(0xFF)));
    }
}

template <typename T>
bool read_be(std::string_view input, size_t &offset, T &out) {
    static_assert(std::is_integral_v<T>, "read_be only supports integral types");
    if (input.size() < offset + sizeof(T)) {
        return false;
    }
    using U = std::make_unsigned_t<T>;
    U acc = 0;
    for (size_t i = 0; i < sizeof(T); ++i) {
        acc = static_cast<U>((acc << 8) | static_cast<unsigned char>(input[offset + i]));
    }
    out = static_cast<T>(acc);
    offset += sizeof(T);
    return true;
}

bool read_lp_string(std::string_view input, size_t &offset, std::string_view &out) {
    uint16_t len = 0;
    if (!read_be(input, offset, len)) {
        return false;
    }
    if (input.size() < offset + len) {
        return false;
    }
    out = input.substr(offset, len);
    offset += len;
    return true;
}

void append_lp_string(std::string &out, std::string_view value) {
    const auto len = static_cast<uint16_t>(value.size());
    append_be<uint16_t>(out, len);
    out.append(value.data(), value.size());
}

static std::string get_env_or_default(const char *name, const char *fallback) {
    const char *value = std::getenv(name);
    if (value == nullptr) {
        return std::string(fallback);
    }
    return std::string(value);
}

static int64_t now_unix_ns() {
    auto now = std::chrono::time_point_cast<std::chrono::nanoseconds>(
        std::chrono::system_clock::now());
    return now.time_since_epoch().count();
}

static std::string parse_workspace(std::string_view raw_path, std::string_view raw_query) {
    if (raw_path.size() > 1) {
        std::string_view path = raw_path;
        while (!path.empty() && path.front() == '/') {
            path.remove_prefix(1);
        }
        if (!path.empty()) {
            const size_t slash = path.find('/');
            if (slash == std::string_view::npos) {
                return std::string(path);
            }
            if (slash > 0) {
                return std::string(path.substr(0, slash));
            }
        }
    }

    if (!raw_query.empty()) {
        size_t start = 0;
        while (start <= raw_query.size()) {
            const size_t end = raw_query.find('&', start);
            const auto pair = raw_query.substr(start, end == std::string_view::npos ? raw_query.size() - start : end - start);
            const size_t eq = pair.find('=');
            if (eq != std::string_view::npos && pair.substr(0, eq) == "workspace") {
                auto value = pair.substr(eq + 1);
                if (!value.empty()) {
                    return std::string(value);
                }
            }
            if (end == std::string_view::npos) {
                break;
            }
            start = end + 1;
        }
    }

    return "ws-0";
}

std::string make_topic(const std::string &workspace, int64_t conv_id) {
    return workspace + ":" + std::to_string(conv_id);
}

void add_subscription(uWS::WebSocket<false, true, Socket_Data> *ws, int64_t conv_id) {
    auto *state = ws->getUserData();
    const std::string topic = make_topic(state->workspace, conv_id);
    ws->subscribe(topic);
    state->subscriptions.insert(conv_id);
}

void remove_all_subscriptions(uWS::WebSocket<false, true, Socket_Data> *ws) {
    auto *state = ws->getUserData();
    for (int64_t conv_id : state->subscriptions) {
        const std::string topic = make_topic(state->workspace, conv_id);
        ws->unsubscribe(topic);
    }
    state->subscriptions.clear();
}

std::string encode_server_ready(std::string_view username, bool is_authenticated) {
    constexpr std::string_view build_version = "uwebsockets-benchmark";
    constexpr std::string_view cpu_model = "n/a";

    std::string out;
    out.reserve(2 + 2 + build_version.size() + 4 + 2 + cpu_model.size() + 2 + username.size() + 1);
    append_be<uint16_t>(out, S_ServerReady);
    append_lp_string(out, build_version);
    append_be<uint32_t>(out, PROTOCOL_VERSION);
    append_lp_string(out, cpu_model);
    append_lp_string(out, username);
    out.push_back(is_authenticated ? 1 : 0);
    return out;
}

std::string encode_ack_send_message(uint32_t client_req_id, int64_t assigned_seq, int64_t timestamp_ns) {
    std::string out;
    out.reserve(2 + 4 + 8 + 8);
    append_be<uint16_t>(out, S_AckSendMessage);
    append_be<uint32_t>(out, client_req_id);
    append_be<int64_t>(out, assigned_seq);
    append_be<int64_t>(out, timestamp_ns);
    return out;
}

std::string encode_new_message(int64_t conv_id, int64_t assigned_seq, std::string_view username, int64_t timestamp_ns,
                               uint8_t content_type, std::string_view content) {
    std::string out;
    out.reserve(2 + 8 + 8 + 2 + username.size() + 8 + 1 + 2 + content.size());
    append_be<uint16_t>(out, S_NewMessage);
    append_be<int64_t>(out, conv_id);
    append_be<int64_t>(out, assigned_seq);
    append_lp_string(out, username);
    append_be<int64_t>(out, timestamp_ns);
    out.push_back(static_cast<char>(content_type));
    append_lp_string(out, content);
    return out;
}

std::string encode_pong(int64_t request_timestamp_us, uint32_t server_thread_id) {
    std::string out;
    out.reserve(145);
    append_be<uint16_t>(out, S_StatsResponse);
    append_be<int64_t>(out, request_timestamp_us);
    append_be<int64_t>(out, now_unix_ns());
    append_be<uint32_t>(out, server_thread_id);
    append_be<uint32_t>(out, g_server_threads);
    append_be<uint32_t>(out, g_connection_count.load());
    append_be<uint32_t>(out, 0); // memory_total_mb
    append_be<uint32_t>(out, 0); // buffer_pool_percent
    append_be<uint32_t>(out, 0); // io_pending
    append_be<uint32_t>(out, 0); // io_ring_depth
    append_be<uint32_t>(out, 0); // io_ring_available
    append_be<uint32_t>(out, 0); // io_sq_overflow
    append_be<uint64_t>(out, 0); // io_total_completions
    append_be<uint64_t>(out, 0); // io_total_latency_ns
    append_be<uint64_t>(out, 0); // io_latency_count
    append_be<uint32_t>(out, 0); // send_queue_depth
    append_be<uint32_t>(out, 0); // send_queue_limit
    out.push_back(0);            // send_backpressure
    append_be<uint32_t>(out, 0); // send_dropped
    append_be<uint64_t>(out, 0); // wal_file_size
    append_be<uint64_t>(out, 0); // wal_pending_bytes
    append_be<uint64_t>(out, 0); // wal_record_count
    append_be<uint64_t>(out, 0); // wal_fsync_count
    append_be<uint64_t>(out, 0); // wal_total_fsync_ns
    append_be<uint64_t>(out, 0); // wal_total_write_ns
    append_be<uint64_t>(out, 0); // wal_write_count
    return out;
}

} // namespace

static void run_server_loop(int port, bool auth_enabled, uint32_t server_thread_id) {
    uWS::App()
        .ws<Socket_Data>("/*", {
            .compression = uWS::SHARED_COMPRESSOR,
            .maxPayloadLength = 16 * 1024,
            .idleTimeout = 120,
            .upgrade = [auth_enabled](auto *res, auto *req, auto *context) {
                std::string_view auth_token = req->getHeader("x-nrc-auth");
                std::string_view username_header = req->getHeader("x-user");

                if (auth_enabled && auth_token.empty()) {
                    res->writeStatus("401 Unauthorized")->end("missing x-nrc-auth header");
                    return;
                }

                std::string workspace = parse_workspace(req->getUrl(), req->getQuery());
                std::string username = username_header.empty() ? "anon" : std::string(username_header);

                res->template upgrade<Socket_Data>(
                    {.workspace = workspace, .username = username, .subscriptions = {}},
                    req->getHeader("sec-websocket-key"),
                    req->getHeader("sec-websocket-protocol"),
                    req->getHeader("sec-websocket-extensions"),
                    context);
            },
            .open = [auth_enabled](auto *ws) {
                g_connection_count.fetch_add(1);
                auto *state = ws->getUserData();
                const std::string payload = encode_server_ready(state->username, auth_enabled);
                ws->send(payload, uWS::OpCode::BINARY);
            },
            .message = [server_thread_id](auto *ws, std::string_view message, uWS::OpCode op_code) {
                if (op_code != uWS::OpCode::BINARY || message.size() < 2) {
                    return;
                }

                size_t offset = 0;
                uint16_t opcode = 0;
                if (!read_be<uint16_t>(message, offset, opcode)) {
                    return;
                }

                auto *state = ws->getUserData();

                if (opcode == C_SubscribeConvs) {
                    uint16_t count = 0;
                    if (!read_be<uint16_t>(message, offset, count)) {
                        return;
                    }
                    for (uint16_t i = 0; i < count; ++i) {
                        int64_t conv_id = 0;
                        if (!read_be<int64_t>(message, offset, conv_id)) {
                            continue;
                        }
                        add_subscription(ws, conv_id);
                    }
                    return;
                }

                if (opcode == C_Stats) {
                    int64_t timestamp_us = 0;
                    if (!read_be<int64_t>(message, offset, timestamp_us)) {
                        return;
                    }
                    const std::string pong = encode_pong(timestamp_us, server_thread_id);
                    ws->send(pong, uWS::OpCode::BINARY);
                    return;
                }

                if (opcode == C_Ping) {
                    int64_t timestamp_ns = 0;
                    if (!read_be<int64_t>(message, offset, timestamp_ns)) {
                        return;
                    }

                    std::string pong;
                    pong.reserve(2 + 8 + 8);
                    append_be<uint16_t>(pong, S_Pong);
                    append_be<int64_t>(pong, timestamp_ns);
                    append_be<int64_t>(pong, now_unix_ns());
                    ws->send(pong, uWS::OpCode::BINARY);
                    return;
                }

                if (opcode == C_SendMessage) {
                    int64_t conv_id = 0;
                    uint32_t client_req_id = 0;
                    uint8_t content_type = 0;
                    std::string_view content;

                    if (!read_be<int64_t>(message, offset, conv_id)) {
                        return;
                    }
                    if (!read_be<uint32_t>(message, offset, client_req_id)) {
                        return;
                    }
                    if (!read_be<uint8_t>(message, offset, content_type)) {
                        return;
                    }
                    if (!read_lp_string(message, offset, content)) {
                        return;
                    }

                    const int64_t timestamp_ns = now_unix_ns();
                    const int64_t assigned_seq = static_cast<int64_t>(g_message_seq.fetch_add(1) + 1);

                    const std::string ack_payload =
                        encode_ack_send_message(client_req_id, assigned_seq, timestamp_ns);
                    ws->send(ack_payload, uWS::OpCode::BINARY);

                    const std::string publish_payload =
                        encode_new_message(conv_id, assigned_seq, state->username, timestamp_ns, content_type, content);
                    const std::string topic = make_topic(state->workspace, conv_id);
                    ws->publish(topic, publish_payload, uWS::OpCode::BINARY);
                }
            },
            .close = [](auto *ws, int, std::string_view) {
                remove_all_subscriptions(ws);
                g_connection_count.fetch_sub(1);
            },
        })
        .listen("127.0.0.1", port, [port, server_thread_id](auto *token) {
            if (token) {
                std::osyncstream(std::cout) << "uwebsockets (C++) benchmark server worker " << server_thread_id
                                            << " listening on :" << port << std::endl;
            } else {
                std::osyncstream(std::cerr) << "worker " << server_thread_id << " failed to listen on :" << port
                                            << std::endl;
                std::exit(EXIT_FAILURE);
            }
        })
        .run();
}

int main() {
    const int port = std::stoi(get_env_or_default("PORT", "8082"));
    const bool auth_enabled = get_env_or_default("AUTH_ENABLED", "0") == "1";
    const int configured_threads = std::stoi(get_env_or_default("UWS_THREAD_COUNT", "1"));
    if (configured_threads < 1) {
        std::cerr << "UWS_THREAD_COUNT must be a positive integer" << std::endl;
        return EXIT_FAILURE;
    }
    g_server_threads = static_cast<uint32_t>(configured_threads);

    std::vector<std::thread> threads;
    threads.reserve(static_cast<size_t>(configured_threads));
    for (int thread_id = 0; thread_id < configured_threads; ++thread_id) {
        threads.emplace_back(run_server_loop, port, auth_enabled, static_cast<uint32_t>(thread_id));
    }
    for (auto &thread : threads) {
        thread.join();
    }

    return EXIT_SUCCESS;
}
