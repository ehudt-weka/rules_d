// LD_PRELOAD library for exact deps: appends one line per path the compiler looks up to $D_EXACT_DEPS_PROBES, found
// or not, so that ldc_wrapper.sh can tell whether a file added to a dependency could change what a compile reads.
//
// Line format: "<kind>\t<path>\n". kind: S found by a stat or access call (not a directory), D found directory (stat),
// F opened, M missing (ENOENT, ENOTDIR), E another error, L directory listed, ? a lookup whose path could not be
// logged (path given with a directory fd that cannot be read back, or too long). A relative path given with a
// directory fd is logged as that directory's path joined with it.
//
// The stat, open and access families make the system call themselves rather than call libc's through dlsym: dlsym
// allocates, and ldc2's allocator (mimalloc) opens files when it starts, which would re-enter the hooks. 64-bit
// Linux only, where struct stat is the kernel's; elsewhere the library is empty, the log stays empty and the compile
// keeps its dependency lists.
#if defined(__linux__)
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#if !defined(__LP64__)
#error "probe_log.c assumes a 64-bit Linux struct stat"
#endif

static int log_fd = -1;

__attribute__((constructor)) static void probe_log_init(void) {
    const char *path = getenv("D_EXACT_DEPS_PROBES");
    if (path && *path) {
        log_fd = (int)syscall(SYS_openat, AT_FDCWD, path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    }
}

static void log_probe(int dirfd, const char *path, char kind) {
    if (log_fd < 0 || !path) {
        return;
    }
    char line[2 * PATH_MAX + 8];
    size_t n = 0;
    line[n++] = kind;
    line[n++] = '\t';
    size_t len = strlen(path);
    if (path[0] != '/' && dirfd != AT_FDCWD) {
        char fd_link[64];
        snprintf(fd_link, sizeof fd_link, "/proc/self/fd/%d", dirfd);
        ssize_t dir_len = readlink(fd_link, line + n, PATH_MAX);
        if (dir_len <= 0) {
            static const char unlogged[] = "?\t-\n";
            (void)!write(log_fd, unlogged, sizeof unlogged - 1);
            return;
        }
        n += (size_t)dir_len;
        line[n++] = '/';
    }
    if (len > PATH_MAX) {
        static const char unlogged[] = "?\t-\n";
        (void)!write(log_fd, unlogged, sizeof unlogged - 1);
        return;
    }
    memcpy(line + n, path, len);
    n += len;
    line[n++] = '\n';
    // One write per line: O_APPEND keeps lines whole across threads.
    (void)!write(log_fd, line, n);
}

static char result_kind(int ok, int saved_errno, char found) {
    if (ok) {
        return found;
    }
    return saved_errno == ENOENT || saved_errno == ENOTDIR ? 'M' : 'E';
}

static int do_stat(int dirfd, const char *path, void *buf, int flags) {
    int rc = (int)syscall(SYS_newfstatat, dirfd, path, buf, flags);
    int saved = errno;
    log_probe(dirfd, path, rc == 0 && S_ISDIR(((struct stat *)buf)->st_mode) ? 'D' : result_kind(rc == 0, saved, 'S'));
    errno = saved;
    return rc;
}

int stat(const char *path, struct stat *buf) { return do_stat(AT_FDCWD, path, buf, 0); }
int stat64(const char *path, struct stat64 *buf) { return do_stat(AT_FDCWD, path, buf, 0); }
int lstat(const char *path, struct stat *buf) { return do_stat(AT_FDCWD, path, buf, AT_SYMLINK_NOFOLLOW); }
int lstat64(const char *path, struct stat64 *buf) { return do_stat(AT_FDCWD, path, buf, AT_SYMLINK_NOFOLLOW); }
int fstatat(int dirfd, const char *path, struct stat *buf, int flags) { return do_stat(dirfd, path, buf, flags); }
int fstatat64(int dirfd, const char *path, struct stat64 *buf, int flags) { return do_stat(dirfd, path, buf, flags); }

// glibc before 2.33 exports stat() and friends as these versioned wrappers; binaries built against it import them.
int __xstat(int ver, const char *path, struct stat *buf);
int __xstat64(int ver, const char *path, struct stat64 *buf);
int __lxstat(int ver, const char *path, struct stat *buf);
int __lxstat64(int ver, const char *path, struct stat64 *buf);
int __fxstatat(int ver, int dirfd, const char *path, struct stat *buf, int flags);
int __fxstatat64(int ver, int dirfd, const char *path, struct stat64 *buf, int flags);
int __open_2(const char *path, int flags);
int __open64_2(const char *path, int flags);

int __xstat(int ver, const char *path, struct stat *buf) { (void)ver; return do_stat(AT_FDCWD, path, buf, 0); }
int __xstat64(int ver, const char *path, struct stat64 *buf) { (void)ver; return do_stat(AT_FDCWD, path, buf, 0); }
int __lxstat(int ver, const char *path, struct stat *buf) {
    (void)ver;
    return do_stat(AT_FDCWD, path, buf, AT_SYMLINK_NOFOLLOW);
}
int __lxstat64(int ver, const char *path, struct stat64 *buf) {
    (void)ver;
    return do_stat(AT_FDCWD, path, buf, AT_SYMLINK_NOFOLLOW);
}
int __fxstatat(int ver, int dirfd, const char *path, struct stat *buf, int flags) {
    (void)ver;
    return do_stat(dirfd, path, buf, flags);
}
int __fxstatat64(int ver, int dirfd, const char *path, struct stat64 *buf, int flags) {
    (void)ver;
    return do_stat(dirfd, path, buf, flags);
}

int statx(int dirfd, const char *path, int flags, unsigned int mask, struct statx *buf) {
    int rc = (int)syscall(SYS_statx, dirfd, path, flags, mask, buf);
    int saved = errno;
    log_probe(dirfd, path, rc == 0 && S_ISDIR(buf->stx_mode) ? 'D' : result_kind(rc == 0, saved, 'S'));
    errno = saved;
    return rc;
}

static int do_open(int dirfd, const char *path, int flags, mode_t mode) {
    int fd = (int)syscall(SYS_openat, dirfd, path, flags, mode);
    int saved = errno;
    log_probe(dirfd, path, result_kind(fd >= 0, saved, 'F'));
    errno = saved;
    return fd;
}

static mode_t open_mode(int flags, va_list ap) {
    return (flags & O_CREAT) || (flags & O_TMPFILE) == O_TMPFILE ? va_arg(ap, mode_t) : 0;
}

#define OPEN_WRAPPER(name) \
    int name(const char *path, int flags, ...) { \
        va_list ap; \
        va_start(ap, flags); \
        mode_t mode = open_mode(flags, ap); \
        va_end(ap); \
        return do_open(AT_FDCWD, path, flags, mode); \
    }

#define OPENAT_WRAPPER(name) \
    int name(int dirfd, const char *path, int flags, ...) { \
        va_list ap; \
        va_start(ap, flags); \
        mode_t mode = open_mode(flags, ap); \
        va_end(ap); \
        return do_open(dirfd, path, flags, mode); \
    }

OPEN_WRAPPER(open)
OPEN_WRAPPER(open64)
OPENAT_WRAPPER(openat)
OPENAT_WRAPPER(openat64)

int __open_2(const char *path, int flags) { return do_open(AT_FDCWD, path, flags, 0); }
int __open64_2(const char *path, int flags) { return do_open(AT_FDCWD, path, flags, 0); }

static int do_access(int dirfd, const char *path, int mode) {
    int rc = (int)syscall(SYS_faccessat, dirfd, path, mode);
    int saved = errno;
    log_probe(dirfd, path, result_kind(rc == 0, saved, 'S'));
    errno = saved;
    return rc;
}

int access(const char *path, int mode) { return do_access(AT_FDCWD, path, mode); }

int faccessat(int dirfd, const char *path, int mode, int flags) {
    if (flags == 0) {
        return do_access(dirfd, path, mode);
    }
    static __typeof__(faccessat) *real;
    if (!real && !(real = (__typeof__(faccessat) *)dlsym(RTLD_NEXT, "faccessat"))) {
        errno = ENOSYS;
        return -1;
    }
    int rc = real(dirfd, path, mode, flags);
    int saved = errno;
    log_probe(dirfd, path, result_kind(rc == 0, saved, 'S'));
    errno = saved;
    return rc;
}

// These need libc's own; by the time the compiler calls them its allocator has started, so dlsym's allocation does
// not re-enter the hooks.
#define REAL_PTR(name) \
    static __typeof__(name) *real_##name; \
    if (!real_##name && !(real_##name = (__typeof__(name) *)dlsym(RTLD_NEXT, #name))) { \
        errno = ENOSYS; \
        return NULL; \
    }

#define FOPEN_WRAPPER(name) \
    FILE *name(const char *path, const char *mode) { \
        REAL_PTR(name); \
        FILE *f = real_##name(path, mode); \
        int saved = errno; \
        log_probe(AT_FDCWD, path, result_kind(f != NULL, saved, 'F')); \
        errno = saved; \
        return f; \
    }

FOPEN_WRAPPER(fopen)
FOPEN_WRAPPER(fopen64)

char *realpath(const char *path, char *resolved) {
    REAL_PTR(realpath);
    char *r = real_realpath(path, resolved);
    int saved = errno;
    log_probe(AT_FDCWD, path, result_kind(r != NULL, saved, 'F'));
    errno = saved;
    return r;
}

DIR *opendir(const char *path) {
    REAL_PTR(opendir);
    DIR *d = real_opendir(path);
    int saved = errno;
    log_probe(AT_FDCWD, path, d ? 'L' : result_kind(0, saved, 'F'));
    errno = saved;
    return d;
}

#else
typedef int probe_log_not_linux;  // ISO C wants a translation unit to declare something
#endif
