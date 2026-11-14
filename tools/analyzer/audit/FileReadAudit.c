// Development-only, process-local dyld interposition. No production linkage.
// Hooks inspect only descriptor metadata and a kernel-reported path, never bodies.
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/uio.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

#define INTERPOSE(replacement, original) \
    __attribute__((used)) static const struct { const void *new_function; const void *old_function; } \
    interpose_##replacement __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(uintptr_t)&replacement, (const void *)(uintptr_t)&original }

static char scope_root[PATH_MAX];
static size_t scope_length;
static _Atomic int ready;
static _Thread_local unsigned int in_hook;
static _Atomic uint64_t regular_opens, read_calls, read_bytes, pread_calls, pread_bytes;
static _Atomic uint64_t readv_calls, readv_bytes, mmap_calls, mmap_bytes, io_failures;
static _Atomic uint64_t classification_failures;
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Audit counters must be lock-free");

// Only successful F_GETPATH observations under the exact path boundary qualify.
// A descriptor may be renamed/reused concurrently; this is bounded evidence for
// immutable generated fixtures, not an access-control or kernel auditing layer.
static int scoped_regular(int fd) {
    if (!atomic_load_explicit(&ready, memory_order_acquire) || fd < 0) return 0;
    struct stat observed;
    if (fstat(fd, &observed) != 0) {
        atomic_fetch_add_explicit(&classification_failures, 1, memory_order_relaxed); return 0;
    }
    if (!S_ISREG(observed.st_mode)) return 0;
    char path[PATH_MAX];
    if (fcntl(fd, F_GETPATH, path) != 0) {
        atomic_fetch_add_explicit(&classification_failures, 1, memory_order_relaxed); return 0;
    }
    return strncmp(path, scope_root, scope_length) == 0 && path[scope_length] == '/';
}
static void opened(int fd) {
    if (scoped_regular(fd)) atomic_fetch_add_explicit(&regular_opens, 1, memory_order_relaxed);
}
static void read_result(int scoped, ssize_t count, _Atomic uint64_t *calls, _Atomic uint64_t *bytes) {
    if (!scoped) return;
    atomic_fetch_add_explicit(calls, 1, memory_order_relaxed);
    if (count > 0) atomic_fetch_add_explicit(bytes, (uint64_t)count, memory_order_relaxed);
    if (count < 0) atomic_fetch_add_explicit(&io_failures, 1, memory_order_relaxed);
}
#define OPEN_WRAPPER(name, original) \
    static int name(const char *path, int flags, ...) { \
        mode_t mode = 0; \
        if (flags & O_CREAT) { va_list args; va_start(args, flags); mode = (mode_t)va_arg(args, int); va_end(args); } \
        if (!atomic_load_explicit(&ready, memory_order_acquire)) return original(path, flags, mode); \
        if (in_hook++) { int result = original(path, flags, mode); --in_hook; return result; } \
        int result = original(path, flags, mode); int saved = errno; opened(result); --in_hook; errno = saved; return result; \
    }
#define OPENAT_WRAPPER(name, original) \
    static int name(int directory, const char *path, int flags, ...) { \
        mode_t mode = 0; \
        if (flags & O_CREAT) { va_list args; va_start(args, flags); mode = (mode_t)va_arg(args, int); va_end(args); } \
        if (!atomic_load_explicit(&ready, memory_order_acquire)) return original(directory, path, flags, mode); \
        if (in_hook++) { int result = original(directory, path, flags, mode); --in_hook; return result; } \
        int result = original(directory, path, flags, mode); int saved = errno; opened(result); --in_hook; errno = saved; return result; \
    }
#define READ_WRAPPER(name, original) \
    static ssize_t name(int fd, void *buffer, size_t size) { \
        if (!atomic_load_explicit(&ready, memory_order_acquire)) return original(fd, buffer, size); \
        int incoming = errno; int scoped = scoped_regular(fd); errno = incoming; \
        if (!scoped) return original(fd, buffer, size); \
        if (in_hook++) { ssize_t result = original(fd, buffer, size); --in_hook; return result; } \
        ssize_t result = original(fd, buffer, size); int saved = errno; \
        read_result(scoped, result, &read_calls, &read_bytes); --in_hook; errno = saved; return result; \
    }
#define PREAD_WRAPPER(name, original) \
    static ssize_t name(int fd, void *buffer, size_t size, off_t offset) { \
        if (!atomic_load_explicit(&ready, memory_order_acquire)) return original(fd, buffer, size, offset); \
        int incoming = errno; int scoped = scoped_regular(fd); errno = incoming; \
        if (!scoped) return original(fd, buffer, size, offset); \
        if (in_hook++) { ssize_t result = original(fd, buffer, size, offset); --in_hook; return result; } \
        ssize_t result = original(fd, buffer, size, offset); int saved = errno; \
        read_result(scoped, result, &pread_calls, &pread_bytes); --in_hook; errno = saved; return result; \
    }
#define READV_WRAPPER(name, original) \
    static ssize_t name(int fd, const struct iovec *vectors, int count) { \
        if (!atomic_load_explicit(&ready, memory_order_acquire)) return original(fd, vectors, count); \
        int incoming = errno; int scoped = scoped_regular(fd); errno = incoming; \
        if (!scoped) return original(fd, vectors, count); \
        if (in_hook++) { ssize_t result = original(fd, vectors, count); --in_hook; return result; } \
        ssize_t result = original(fd, vectors, count); int saved = errno; \
        read_result(scoped, result, &readv_calls, &readv_bytes); --in_hook; errno = saved; return result; \
    }

// Darwin exports these aliases on the qualified host. No private ABI calls or
// dlsym resolution occur inside hooks. Aliases with the same address need only
// one tuple; exact symbol inventory is retained by the runner.
extern int nocancel_open(const char *, int, ...) __asm("_open$NOCANCEL");
extern int nocancel_openat(int, const char *, int, ...) __asm("_openat$NOCANCEL");
extern ssize_t nocancel_read(int, void *, size_t) __asm("_read$NOCANCEL");
extern ssize_t nocancel_pread(int, void *, size_t, off_t) __asm("_pread$NOCANCEL");
extern ssize_t nocancel_readv(int, const struct iovec *, int) __asm("_readv$NOCANCEL");
OPEN_WRAPPER(audit_open, open)
OPENAT_WRAPPER(audit_openat, openat)
READ_WRAPPER(audit_read, read)
PREAD_WRAPPER(audit_pread, pread)
READV_WRAPPER(audit_readv, readv)
OPEN_WRAPPER(audit_nocancel_open, nocancel_open)
OPENAT_WRAPPER(audit_nocancel_openat, nocancel_openat)
READ_WRAPPER(audit_nocancel_read, nocancel_read)
PREAD_WRAPPER(audit_nocancel_pread, nocancel_pread)
READV_WRAPPER(audit_nocancel_readv, nocancel_readv)
static void *audit_mmap(void *address, size_t size, int protection, int flags, int fd, off_t offset) {
    if (!atomic_load_explicit(&ready, memory_order_acquire)) return mmap(address, size, protection, flags, fd, offset);
    int incoming = errno; int scoped = scoped_regular(fd); errno = incoming;
    // Anonymous/out-of-scope runtime mappings never touch TLS, including during
    // first use of a thread's compiler-managed TLS storage.
    if (!scoped) return mmap(address, size, protection, flags, fd, offset);
    if (in_hook++) { void *result = mmap(address, size, protection, flags, fd, offset); --in_hook; return result; }
    void *result = mmap(address, size, protection, flags, fd, offset); int saved = errno;
    if (scoped) {
        atomic_fetch_add_explicit(&mmap_calls, 1, memory_order_relaxed);
        if (result == MAP_FAILED) atomic_fetch_add_explicit(&io_failures, 1, memory_order_relaxed);
        else atomic_fetch_add_explicit(&mmap_bytes, size, memory_order_relaxed);
    }
    --in_hook; errno = saved; return result;
}
INTERPOSE(audit_open, open);
INTERPOSE(audit_openat, openat);
INTERPOSE(audit_read, read);
INTERPOSE(audit_pread, pread);
INTERPOSE(audit_readv, readv);
INTERPOSE(audit_mmap, mmap);
INTERPOSE(audit_nocancel_open, nocancel_open);
INTERPOSE(audit_nocancel_openat, nocancel_openat);
INTERPOSE(audit_nocancel_read, nocancel_read);
INTERPOSE(audit_nocancel_pread, nocancel_pread);
INTERPOSE(audit_nocancel_readv, nocancel_readv);

__attribute__((constructor)) static void configure(void) {
    ++in_hook;
    const char *root = getenv("B06_AUDIT_ROOT");
    const char *dev = getenv("B06_AUDIT_DEV"), *ino = getenv("B06_AUDIT_INO");
    if (root && dev && ino) {
        size_t length = strnlen(root, sizeof(scope_root));
        if (length > 1 && length < sizeof(scope_root) && root[0] == '/' && root[length - 1] != '/') {
            struct stat observed;
            // Runner also validates every ancestor and the ownership receipt.
            if (lstat(root, &observed) == 0 && S_ISDIR(observed.st_mode)
                && (uint64_t)observed.st_dev == strtoull(dev, NULL, 10)
                && (uint64_t)observed.st_ino == strtoull(ino, NULL, 10)) {
                memcpy(scope_root, root, length + 1); scope_length = length;
                atomic_store_explicit(&ready, 1, memory_order_release);
            }
        }
    }
    --in_hook;
}

// Fixed-stack JSON assembly avoids stdio allocation/locking during teardown.
static char *append_text(char *output, const char *text) { while (*text) *output++ = *text++; return output; }
static char *append_number(char *output, uint64_t number) {
    char digits[20]; size_t count = 0;
    do { digits[count++] = (char)('0' + number % 10); number /= 10; } while (number);
    while (count) *output++ = digits[--count]; return output;
}
__attribute__((destructor)) static void report(void) {
    ++in_hook;
    char buffer[1024], *output = buffer;
    output = append_text(output, "{\"b06_file_read_audit\":1,\"configured\":");
    output = append_number(output, (uint64_t)atomic_load_explicit(&ready, memory_order_acquire));
#define FIELD(name) output = append_text(output, ",\"" #name "\":"); output = append_number(output, atomic_load_explicit(&name, memory_order_relaxed))
    FIELD(regular_opens); FIELD(read_calls); FIELD(read_bytes); FIELD(pread_calls); FIELD(pread_bytes);
    FIELD(readv_calls); FIELD(readv_bytes); FIELD(mmap_calls); FIELD(mmap_bytes); FIELD(io_failures); FIELD(classification_failures);
#undef FIELD
    output = append_text(output, "}\n");
    size_t pending = (size_t)(output - buffer), offset = 0;
    while (offset < pending) {
        ssize_t count = write(STDERR_FILENO, buffer + offset, pending - offset);
        if (count > 0) offset += (size_t)count;
        else if (count < 0 && errno == EINTR) continue;
        else break;
    }
    --in_hook;
}
