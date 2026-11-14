#include <stdint.h>
#include <stddef.h>
typedef struct { uint64_t dev, ino, nlink; uint32_t flags, mode; int32_t fsid0, fsid1; int local; int64_t mtime_sec, mtime_nsec, ctime_sec, ctime_nsec; } B06Identity;
uint32_t b06_common_mask(void);
uint32_t b06_directory_mask(void);
uint32_t b06_file_mask(void);
int b06_policy_get(void);
int b06_policy_off(void);
int b06_policy_restore(int);
int b06_open_root(const char *);
int b06_open_directory(int, const char *);
int b06_identity(int, B06Identity *);
int b06_identity_at(int, const char *, B06Identity *);
int b06_bulk(int, void *, size_t);
int b06_metadata(int, const char *, void *, size_t);
void b06_sha256(const void *, size_t, uint8_t *);
void b06_install_cancellation(void);
int b06_cancelled(void);
int b06_set_utility_qos(void);
typedef struct { uint64_t current_rss, peak_rss, user_ns, system_ns; } B06Resources;
int b06_resources(B06Resources *);

int b06_root_path(int, char *, size_t);
