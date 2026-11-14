#include "ScannerNative.h"
/* Generated-store qualification only. Checks are boundary observations, not a
 * SQLite VFS or proof against every same-user race between SQLite path opens. */
int b06_store_check(const char *path, int parent_fd, int database_fd, int lease_fd);
int b06_paged_spawn(const char *binary, const char *store, const char *session,
                    uint64_t dev, uint64_t ino, int *pid, int *output, int *error);
int b06_paged_wait(int pid, int *exit_code, uint64_t *peak_bytes);
typedef struct {uint64_t statements,commits,profile_ns,commit_ns;} B06SQLStats;
int b06_sql_profile(void *database);
void b06_sql_stats(B06SQLStats *result);
