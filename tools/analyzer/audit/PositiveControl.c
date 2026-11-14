// Reads only the runner's newly generated sentinel. No body/path output.
#include <sys/mman.h>
#include <sys/uio.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <pthread.h>
#include <stdlib.h>
extern int nocancel_open(const char *, int, ...) __asm("_open$NOCANCEL");
extern int nocancel_openat(int, const char *, int, ...) __asm("_openat$NOCANCEL");
extern ssize_t nocancel_read(int, void *, size_t) __asm("_read$NOCANCEL");
extern ssize_t nocancel_pread(int, void *, size_t, off_t) __asm("_pread$NOCANCEL");
extern ssize_t nocancel_readv(int, const struct iovec *, int) __asm("_readv$NOCANCEL");
static const char *sentinel;
static void *worker(void *unused) {
    (void)unused;
    for (int n = 0; n < 100; ++n) {
        int fd = open(sentinel, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        char value;
        if (fd < 0 || read(fd, &value, 1) != 1 || value != 'A' || close(fd)) return (void *)1;
    }
    return NULL;
}
int main(int argc, char **argv) {
    if (argc != 3) return 64;
    const char *mode = argv[1], *root = argv[2];
    char path[PATH_MAX];
    int length = snprintf(path, sizeof(path), "%s/sentinel", root);
    if (length < 0 || (size_t)length >= sizeof(path)) return 65;
    if (!strcmp(mode, "threads")) {
        sentinel = path; pthread_t threads[4];
        for (int n = 0; n < 4; ++n) if (pthread_create(&threads[n], NULL, worker, NULL)) return 70;
        for (int n = 0; n < 4; ++n) { void *result; if (pthread_join(threads[n], &result) || result) return 71; }
        return 0;
    }
    int directory = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) return 66;
    if (!strcmp(mode, "metadata")) { close(directory); return 0; }
    if (!strcmp(mode, "failure")) {
        int fd = openat(directory, "sentinel", O_WRONLY | O_NOFOLLOW | O_CLOEXEC);
        char value; errno = 0;
        if (fd < 0 || read(fd, &value, 1) != -1 || errno != EBADF) return 72;
        close(fd); close(directory); return 0;
    }
    int nocancel = !strcmp(mode, "nocancel");
    if (!nocancel && strcmp(mode, "public")) return 64;
    int fd = nocancel ? nocancel_open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        : open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return 67;
    char first[4], second[4], third[4];
    struct iovec vectors[2] = {{third, 2}, {third + 2, 2}};
    ssize_t a = nocancel ? nocancel_read(fd, first, sizeof(first)) : read(fd, first, sizeof(first));
    ssize_t b = nocancel ? nocancel_pread(fd, second, sizeof(second), 4) : pread(fd, second, sizeof(second), 4);
    ssize_t c = nocancel ? nocancel_readv(fd, vectors, 2) : readv(fd, vectors, 2);
    if (a != 4 || b != 4 || c != 4 || memcmp(first, "AAAA", 4) || memcmp(second, "AAAA", 4) || memcmp(third, "AAAA", 4)) return 68;
    void *mapped = mmap(NULL, 4096, PROT_READ, MAP_PRIVATE, fd, 0);
    if (mapped == MAP_FAILED) return 69;
    volatile const char *bytes = mapped;
    if (bytes[0] != 'A' || bytes[4095] != 'A') return 73;
    if (munmap(mapped, 4096) || close(fd)) return 74;
    int relative = nocancel ? nocancel_openat(directory, "sentinel", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        : openat(directory, "sentinel", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (relative < 0 || close(relative) || close(directory)) return 75;
    return 0;
}
