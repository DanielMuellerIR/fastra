#include <unistd.h>

__attribute__((constructor)) static void runtime_library_loaded(void) {
    static const char marker[] = "UNTRUSTED_RUNTIME_LIBRARY_LOADED\n";
    (void)write(STDERR_FILENO, marker, sizeof(marker) - 1);
}
