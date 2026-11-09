/* Synthetische Runtime: ignoriert TERM und erzeugt einen setsid-Nachfahren. */
#include <arpa/inet.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int port = atoi(argv[1] + 6);
    signal(SIGTERM, SIG_IGN);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons((unsigned short)port);
    if (connect(fd, (void *)&address, sizeof(address))) return 3;
    pid_t child = fork();
    if (child == 0) setsid();
    for (;;) pause();
}
