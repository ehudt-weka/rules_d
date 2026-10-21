// Calls the hooked functions the way a compiler might, for probe_log_test.sh: each lookup names a path the test then
// expects in the probe log. Run in a directory with a file "present" and a directory "dir".
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

int main(void) {
    struct stat st;
    stat("present", &st);
    lstat("lmissing", &st);
    int dir = open("dir", O_RDONLY | O_DIRECTORY);
    fstatat(dir, "atmissing", &st, 0);
    int fd = openat(dir, "atopen", O_WRONLY | O_CREAT, 0644);
    if (fd >= 0) {
        close(fd);
    }
    access("amissing", F_OK);
    // A component that is a file: ENOTDIR, logged as missing.
    stat("present/sub", &st);
    FILE *f = fopen("fmissing", "r");
    if (f) {
        fclose(f);
    }
    return 0;
}
