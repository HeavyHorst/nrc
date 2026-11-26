// Test-only interposer: stop the real server immediately before or after its
// next armed SQLite COMMIT. Never linked into the application or container.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int sqlite3_exec(sqlite3 *db, const char *sql,
                 int (*callback)(void *, int, char **, char **),
                 void *arg, char **error) {
    int (*real_exec)(sqlite3 *, const char *,
                     int (*)(void *, int, char **, char **), void *, char **) =
        dlsym(RTLD_NEXT, "sqlite3_exec");
    const char *arm = getenv("NRC_TEST_COMMIT_ARM");
    const char *target = getenv("NRC_TEST_COMMIT_DB");
    const char *reached = getenv("NRC_TEST_COMMIT_REACHED");
    const char *kind = getenv("NRC_TEST_COMMIT_KIND");
    const char *filename = sqlite3_db_filename(db, "main");
    char phase[8] = {0};
    if (arm && target && reached && filename && strcmp(filename, target) == 0 &&
        strcmp(sql, "COMMIT") == 0) {
        int fd = open(arm, O_RDONLY);
        if (fd >= 0) {
            // Ignore maintenance/read commits on the same shard: arm only
            // the transaction containing the intended canonical/result write.
            sqlite3_stmt *s = NULL;
            const char *check = kind && strcmp(kind, "capture") == 0
                ? "SELECT count(*)=2 FROM assets"
                : kind && strcmp(kind, "task") == 0
                ? "SELECT EXISTS(SELECT 1 FROM tasks WHERE title=CAST('commit candidate' AS BLOB))"
                : kind && strcmp(kind, "asset-delete") == 0
                ? "SELECT NOT EXISTS(SELECT 1 FROM assets WHERE preview=CAST('cascade-root' AS BLOB))"
                : "SELECT count(*)=1 FROM chronicle_jobs WHERE state=1";
            int matches = sqlite3_prepare_v2(db, check, -1, &s, NULL) == SQLITE_OK &&
                sqlite3_step(s) == SQLITE_ROW && sqlite3_column_int(s, 0) == 1;
            sqlite3_finalize(s);
            ssize_t n = matches ? read(fd, phase, sizeof(phase) - 1) : 0;
            close(fd);
            if (n <= 0 || unlink(arm) != 0) phase[0] = 0;
        }
    }
    int before = strcmp(phase, "before") == 0;
    int after = strcmp(phase, "after") == 0;
    int rc = before ? SQLITE_OK : real_exec(db, sql, callback, arg, error);
    if (before || after) {
        FILE *f = fopen(reached, "w");
        if (!f) _exit(91);
        fprintf(f, "%s:%d", phase, rc);
        fclose(f);
        raise(SIGSTOP);
    }
    return before ? real_exec(db, sql, callback, arg, error) : rc;
}
