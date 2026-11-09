/* Nur isolierte Lesetests: zwei Fixture-Namen verweigern die Metadatenabfrage. */
#define _GNU_SOURCE
#include <sys/types.h>
#include <sys/xattr.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <dlfcn.h>
#include <stdlib.h>

ssize_t flistxattr(int fd, char *names, size_t capacity) {
    char descriptor_path[64];
    char resolved_path[4096];
    snprintf(descriptor_path, sizeof descriptor_path, "/proc/self/fd/%d", fd);
    ssize_t length = readlink(descriptor_path, resolved_path, sizeof resolved_path - 1);
    if (length >= 0 && length < (ssize_t)sizeof resolved_path - 1) {
        resolved_path[length] = 0;
        const char *basename = strrchr(resolved_path, '/');
        if (basename && (!strcmp(basename, "/readonly.md") || !strcmp(basename, "/alias.md"))) {
            if (getenv("FASTRA_TEST_XATTR_LIMIT")) {
                return 1024 * 1024 + 1;
            }
            errno = EACCES;
            return -1;
        }
    }
    typedef ssize_t (*ListAttributes)(int, char *, size_t);
    ListAttributes original = (ListAttributes)dlsym(RTLD_NEXT, "flistxattr");
    if (!original) {
        errno = ENOSYS;
        return -1;
    }
    return original(fd, names, capacity);
}
