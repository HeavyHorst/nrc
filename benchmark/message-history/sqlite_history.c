#define _GNU_SOURCE
#include <limits.h>
#include <pthread.h>
#include <sched.h>
#include <sqlite3.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum { LOGICAL_WRITERS = 4, PAGE_LIMIT = 100, PAGE_BYTE_BUDGET = 96 * 1024 };

typedef struct {
    const char *path;
    int records;
    int content_bytes;
    int rounds;
    int reader_count;
    int target_rate;
    int distractors_per_target;
    double duration_s;
    atomic_int ready;
    atomic_int start;
    atomic_int stop;
    atomic_int stop_readers;
    double started_at;
    pthread_barrier_t wave;
    pthread_barrier_t finished;
} Phase;

typedef struct {
    Phase *phase;
    int index;
    double *samples_us;
    int sample_capacity;
    uint64_t checksum;
    int messages;
    int rounds_completed;
} Reader;

typedef struct {
    Phase *phase;
    atomic_int submitted;
    double finished_at;
} Writer;

static double monotonic_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void die(sqlite3 *db, const char *operation) {
    fprintf(stderr, "%s: %s\n", operation, db == NULL ? "unknown error" : sqlite3_errmsg(db));
    exit(1);
}

static void execute(sqlite3 *db, const char *sql) {
    char *error = NULL;
    if (sqlite3_exec(db, sql, NULL, NULL, &error) != SQLITE_OK) {
        fprintf(stderr, "%s: %s\n", sql, error);
        sqlite3_free(error);
        exit(1);
    }
}

static sqlite3 *open_database(const char *path) {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK)
        die(db, "open database");
    sqlite3_busy_timeout(db, 30000);
    if (sqlite3_db_config(db, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, NULL) != SQLITE_OK)
        die(db, "disable close checkpoint");
    execute(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA wal_autocheckpoint=0; PRAGMA temp_store=MEMORY;");
    return db;
}

static void bind_message(sqlite3_stmt *statement, int64_t sequence, int conversation, int sender,
                         const void *content, int content_bytes) {
    sqlite3_bind_int64(statement, 1, sequence);
    sqlite3_bind_int(statement, 2, conversation);
    sqlite3_bind_int(statement, 3, sender);
    sqlite3_bind_int64(statement, 4, sequence);
    sqlite3_bind_text(statement, 5, "alice", -1, SQLITE_STATIC);
    sqlite3_bind_int64(statement, 6, 1700000000000000000LL + sequence);
    sqlite3_bind_int(statement, 7, 0);
    sqlite3_bind_blob(statement, 8, content, content_bytes, SQLITE_STATIC);
    if (sqlite3_step(statement) != SQLITE_DONE)
        die(sqlite3_db_handle(statement), "insert message");
    sqlite3_reset(statement);
    sqlite3_clear_bindings(statement);
}

static void unlink_database(const char *path) {
    unlink(path);
    char sidecar[4096];
    snprintf(sidecar, sizeof(sidecar), "%s-wal", path);
    unlink(sidecar);
    snprintf(sidecar, sizeof(sidecar), "%s-shm", path);
    unlink(sidecar);
}

static void seed_database(const char *path, int records, int content_bytes, int distractors_per_target) {
    sqlite3 *db = open_database(path);
    execute(db,
        "CREATE TABLE messages("
        "sequence INTEGER PRIMARY KEY, conversation_id INTEGER NOT NULL, sender_id INTEGER NOT NULL,"
        "client_message_id INTEGER NOT NULL, author_username TEXT NOT NULL, accepted_at INTEGER NOT NULL,"
        "content_type INTEGER NOT NULL, content BLOB NOT NULL,"
        "UNIQUE(sender_id,client_message_id));"
        "CREATE INDEX history_idx ON messages(conversation_id,sequence);");
    sqlite3_stmt *insert = NULL;
    if (sqlite3_prepare_v2(db, "INSERT INTO messages VALUES(?,?,?,?,?,?,?,?)", -1, &insert, NULL) != SQLITE_OK)
        die(db, "prepare seed insert");
    char *content = malloc((size_t)content_bytes);
    memset(content, 's', (size_t)content_bytes);
    execute(db, "BEGIN IMMEDIATE");
    int64_t sequence = 1;
    for (int i = 0; i < records; i++) {
        bind_message(insert, sequence++, 42, i % 31 + 1, content, content_bytes);
        for (int distractor = 0; distractor < distractors_per_target; distractor++)
            bind_message(insert, sequence++, 43, distractor + 100, content, content_bytes);
    }
    execute(db, "COMMIT");
    sqlite3_finalize(insert);
    free(content);
    execute(db, "PRAGMA wal_checkpoint(TRUNCATE)");
    sqlite3_close(db);
}

static int compare_double(const void *left, const void *right) {
    double a = *(const double *)left;
    double b = *(const double *)right;
    return (a > b) - (a < b);
}

static double percentile(double *values, int count, double fraction) {
    qsort(values, (size_t)count, sizeof(*values), compare_double);
    int index = (int)(count * fraction);
    if (index >= count)
        index = count - 1;
    return values[index];
}

static void warm_statement(sqlite3_stmt *statement, int64_t cursor) {
    sqlite3_bind_int64(statement, 1, cursor);
    while (sqlite3_step(statement) == SQLITE_ROW) {}
    sqlite3_reset(statement);
    sqlite3_clear_bindings(statement);
}

static void *reader_main(void *raw) {
    Reader *reader = raw;
    Phase *phase = reader->phase;
    sqlite3 *db = open_database(phase->path);
    sqlite3_stmt *statements[2] = {NULL, NULL};
    if (sqlite3_prepare_v2(db, "SELECT conversation_id,sequence,client_message_id,author_username,accepted_at,content_type,content FROM messages WHERE conversation_id=42 AND sequence<? ORDER BY sequence DESC LIMIT 100", -1, &statements[0], NULL) != SQLITE_OK ||
        sqlite3_prepare_v2(db, "SELECT conversation_id,sequence,client_message_id,author_username,accepted_at,content_type,content FROM messages WHERE conversation_id=42 AND sequence>? ORDER BY sequence ASC LIMIT 100", -1, &statements[1], NULL) != SQLITE_OK)
        die(db, "prepare history queries");
    int64_t stride = phase->distractors_per_target + 1;
    warm_statement(statements[0], (phase->records - 1LL) * stride + 1);
    warm_statement(statements[1], 0);
    atomic_fetch_add_explicit(&phase->ready, 1, memory_order_release);
    while (!atomic_load_explicit(&phase->start, memory_order_acquire))
        sched_yield();
    int span = phase->records - 101;
    for (int round = 0; round < phase->rounds; round++) {
        pthread_barrier_wait(&phase->wave);
        int ascending = (reader->index + round) % 2;
        sqlite3_stmt *statement = statements[ascending];
        int64_t target_index = ascending
            ? (round * 991LL + reader->index * 313LL) % span
            : phase->records - ((round * 997LL + reader->index * 307LL) % span);
        int64_t cursor = ascending ? target_index * stride : (target_index - 1) * stride + 1;
        sqlite3_bind_int64(statement, 1, cursor);
        double started = monotonic_s();
        int rows = 0;
        int page_bytes = 0;
        for (;;) {
            int result = sqlite3_step(statement);
            if (result == SQLITE_DONE)
                break;
            if (result != SQLITE_ROW)
                die(db, "query history page");
            int message_bytes = 45 + sqlite3_column_bytes(statement, 3) + sqlite3_column_bytes(statement, 6);
            if (rows > 0 && page_bytes + message_bytes > PAGE_BYTE_BUDGET)
                break;
            page_bytes += message_bytes;
            reader->checksum += (uint64_t)sqlite3_column_int(statement, 0);
            reader->checksum += (uint64_t)sqlite3_column_int64(statement, 1);
            reader->checksum += (uint64_t)sqlite3_column_int64(statement, 2);
            reader->checksum += (uint64_t)sqlite3_column_bytes(statement, 3);
            reader->checksum += (uint64_t)sqlite3_column_int64(statement, 4);
            reader->checksum += (uint64_t)sqlite3_column_int(statement, 5);
            reader->checksum += (uint64_t)sqlite3_column_bytes(statement, 6);
            rows++;
        }
        if (round == reader->sample_capacity) {
            reader->sample_capacity *= 2;
            double *grown = realloc(reader->samples_us, (size_t)reader->sample_capacity * sizeof(double));
            if (grown == NULL)
                die(db, "grow latency samples");
            reader->samples_us = grown;
        }
        reader->samples_us[round] = (monotonic_s() - started) * 1e6;
        if (rows < 1 || rows > PAGE_LIMIT)
            die(db, "short history page");
        reader->messages += rows;
        sqlite3_reset(statement);
        sqlite3_clear_bindings(statement);
        pthread_barrier_wait(&phase->wave);
        if (reader->index == 0 && phase->duration_s > 0 && monotonic_s() - phase->started_at >= phase->duration_s)
            atomic_store_explicit(&phase->stop_readers, 1, memory_order_release);
        pthread_barrier_wait(&phase->wave);
        reader->rounds_completed = round + 1;
        if (atomic_load_explicit(&phase->stop_readers, memory_order_acquire))
            break;
    }
    pthread_barrier_wait(&phase->finished);
    sqlite3_finalize(statements[0]);
    sqlite3_finalize(statements[1]);
    sqlite3_close(db);
    return NULL;
}

static void *writer_main(void *raw) {
    Writer *writer = raw;
    Phase *phase = writer->phase;
    sqlite3 *db = open_database(phase->path);
    sqlite3_stmt *insert = NULL;
    if (sqlite3_prepare_v2(db, "INSERT INTO messages VALUES(?,?,?,?,?,?,?,?)", -1, &insert, NULL) != SQLITE_OK)
        die(db, "prepare live insert");
    char *content = malloc((size_t)phase->content_bytes);
    memset(content, 'w', (size_t)phase->content_bytes);
    atomic_fetch_add_explicit(&phase->ready, 1, memory_order_release);
    while (!atomic_load_explicit(&phase->start, memory_order_acquire))
        sched_yield();
    while (!atomic_load_explicit(&phase->stop, memory_order_acquire)) {
        int due = (int)((monotonic_s() - phase->started_at) * phase->target_rate);
        int submitted = atomic_load_explicit(&writer->submitted, memory_order_relaxed);
        if (submitted >= due) {
            struct timespec delay = {.tv_nsec = 50000};
            nanosleep(&delay, NULL);
            continue;
        }
        int burst = due - submitted;
        if (burst > 32)
            burst = 32;
        for (int i = 0; i < burst && !atomic_load_explicit(&phase->stop, memory_order_relaxed); i++) {
            int64_t sequence = (int64_t)phase->records * (phase->distractors_per_target + 1) + submitted + 1;
            int logical_writer = submitted % LOGICAL_WRITERS;
            execute(db, "BEGIN IMMEDIATE");
            bind_message(insert, sequence, 777, logical_writer + 1000, content, phase->content_bytes);
            execute(db, "COMMIT");
            submitted++;
            atomic_store_explicit(&writer->submitted, submitted, memory_order_relaxed);
        }
    }
    writer->finished_at = monotonic_s();
    sqlite3_finalize(insert);
    sqlite3_close(db);
    free(content);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 9) {
        fprintf(stderr, "usage: %s DB TARGET_RECORDS CONTENT_BYTES ROUNDS READERS TARGET_MSG_S DISTRACTORS_PER_TARGET DURATION_MS\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];
    int records = atoi(argv[2]);
    int content_bytes = atoi(argv[3]);
    int rounds = atoi(argv[4]);
    int reader_count = atoi(argv[5]);
    int target_rate = atoi(argv[6]);
    int distractors_per_target = atoi(argv[7]);
    int duration_ms = atoi(argv[8]);
    if (records < 200 || content_bytes <= 0 || rounds <= 0 || reader_count < 1 || reader_count > 8 || target_rate < 0 || distractors_per_target < 0 || distractors_per_target > 20 || duration_ms < 0)
        return 2;
    unlink_database(path);
    seed_database(path, records, content_bytes, distractors_per_target);

    Phase phase = {
        .path = path, .records = records, .content_bytes = content_bytes, .rounds = rounds,
        .reader_count = reader_count, .target_rate = target_rate,
        .distractors_per_target = distractors_per_target,
        .duration_s = duration_ms / 1000.0,
    };
    if (duration_ms > 0)
        phase.rounds = INT_MAX;
    pthread_barrier_init(&phase.wave, NULL, (unsigned)reader_count);
    pthread_barrier_init(&phase.finished, NULL, (unsigned)reader_count + 1);
    Reader readers[8] = {0};
    pthread_t reader_threads[8];
    Writer writer = {.phase = &phase};
    pthread_t writer_thread;
    for (int i = 0; i < reader_count; i++) {
        int sample_capacity = duration_ms > 0 ? 65536 : rounds;
        readers[i] = (Reader){
            .phase = &phase, .index = i, .samples_us = malloc((size_t)sample_capacity * sizeof(double)),
            .sample_capacity = sample_capacity,
        };
        if (readers[i].samples_us == NULL)
            die(NULL, "allocate latency samples");
        pthread_create(&reader_threads[i], NULL, reader_main, &readers[i]);
    }
    if (target_rate > 0)
        pthread_create(&writer_thread, NULL, writer_main, &writer);
    int participant_count = reader_count + (target_rate > 0 ? 1 : 0);
    while (atomic_load_explicit(&phase.ready, memory_order_acquire) != participant_count)
        sched_yield();
    phase.started_at = monotonic_s();
    atomic_store_explicit(&phase.start, 1, memory_order_release);
    pthread_barrier_wait(&phase.finished);
    double readers_finished_at = monotonic_s();
    atomic_store_explicit(&phase.stop, 1, memory_order_release);
    for (int i = 0; i < reader_count; i++)
        pthread_join(reader_threads[i], NULL);
    if (target_rate > 0)
        pthread_join(writer_thread, NULL);
    double finished_at = target_rate > 0 && writer.finished_at > readers_finished_at
        ? writer.finished_at : readers_finished_at;
    double elapsed = finished_at - phase.started_at;
    int submitted = atomic_load_explicit(&writer.submitted, memory_order_relaxed);

    int sample_capacity = 0;
    for (int i = 0; i < reader_count; i++)
        sample_capacity += readers[i].rounds_completed;
    double *ascending = malloc((size_t)sample_capacity * sizeof(double));
    double *descending = malloc((size_t)sample_capacity * sizeof(double));
    int ascending_count = 0, descending_count = 0;
    uint64_t checksum = 0;
    int total_messages = 0;
    int total_pages = 0;
    for (int i = 0; i < reader_count; i++) {
        for (int round = 0; round < readers[i].rounds_completed; round++) {
            if ((i + round) % 2)
                ascending[ascending_count++] = readers[i].samples_us[round];
            else
                descending[descending_count++] = readers[i].samples_us[round];
        }
        checksum += readers[i].checksum;
        total_messages += readers[i].messages;
        total_pages += readers[i].rounds_completed;
        free(readers[i].samples_us);
    }
    double ascending_total = 0, descending_total = 0;
    for (int i = 0; i < ascending_count; i++) ascending_total += ascending[i];
    for (int i = 0; i < descending_count; i++) descending_total += descending[i];
    cpu_set_t affinity;
    CPU_ZERO(&affinity);
    sched_getaffinity(0, sizeof(affinity), &affinity);
    printf("{\"backend\":\"sqlite\",\"affinity_cpus\":%d,\"readers\":%d,\"writer_threads\":%d,"
           "\"rounds\":%d,\"pages\":%d,\"duration_ms\":%d,\"messages_per_page\":%.3f,\"target_msg_s\":%d,\"achieved_msg_s\":%.3f,\"pages_s\":%.3f,\"elapsed_s\":%.9f,"
           "\"ascending_avg_us\":%.3f,\"ascending_p50_us\":%.3f,\"ascending_p95_us\":%.3f,"
           "\"descending_avg_us\":%.3f,\"descending_p50_us\":%.3f,\"descending_p95_us\":%.3f,\"checksum\":%llu}\n",
           CPU_COUNT(&affinity), reader_count, target_rate > 0 ? 1 : 0, readers[0].rounds_completed, total_pages, duration_ms,
           (double)total_messages / total_pages, target_rate,
           submitted / elapsed, total_pages / elapsed, elapsed,
           ascending_count ? ascending_total / ascending_count : 0,
           ascending_count ? percentile(ascending, ascending_count, .50) : 0,
           ascending_count ? percentile(ascending, ascending_count, .95) : 0,
           descending_count ? descending_total / descending_count : 0,
           descending_count ? percentile(descending, descending_count, .50) : 0,
           descending_count ? percentile(descending, descending_count, .95) : 0,
           (unsigned long long)checksum);
    free(ascending);
    free(descending);
    pthread_barrier_destroy(&phase.wave);
    pthread_barrier_destroy(&phase.finished);
    unlink_database(path);
    return 0;
}
