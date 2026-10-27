/*
 * dvp-discover: finds Jellyfin servers on the local network (D55).
 *
 * Sends Jellyfin's discovery message ("who is JellyfinServer?") as a UDP
 * broadcast to port 7359, on every IPv4 interface that can broadcast and
 * to 255.255.255.255, then prints each answer (a JSON object with Address,
 * Id and Name) on its own line until the time is up.
 *
 *   dvp-discover [TIMEOUT_MS]    default 1500, at most 10000
 *
 * Answers are printed as received, with control characters replaced by
 * spaces, at most MAX_ANSWERS of them; the app parses and checks them
 * (dvp/jellyfin.lua).
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define PORT 7359
#define MAX_ANSWERS 64
static const char MESSAGE[] = "who is JellyfinServer?";

static long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

static void send_to(int fd, struct in_addr addr)
{
    struct sockaddr_in to = {0};
    to.sin_family = AF_INET;
    to.sin_port = htons(PORT);
    to.sin_addr = addr;
    sendto(fd, MESSAGE, sizeof MESSAGE - 1, 0, (struct sockaddr *)&to, sizeof to);
}

int main(int argc, char **argv)
{
    long timeout = argc > 1 ? strtol(argv[1], NULL, 10) : 1500;
    if (timeout <= 0 || timeout > 10000) timeout = 1500;

    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        perror("socket");
        return 1;
    }
    int on = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, sizeof on) < 0) {
        perror("SO_BROADCAST");
        return 1;
    }

    struct in_addr all = {htonl(INADDR_BROADCAST)};
    send_to(fd, all);
    struct ifaddrs *ifs = NULL;
    if (getifaddrs(&ifs) == 0) {
        for (struct ifaddrs *i = ifs; i; i = i->ifa_next) {
            if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || !i->ifa_broadaddr) continue;
            if (!(i->ifa_flags & IFF_UP) || !(i->ifa_flags & IFF_BROADCAST) || (i->ifa_flags & IFF_LOOPBACK))
                continue;
            send_to(fd, ((struct sockaddr_in *)i->ifa_broadaddr)->sin_addr);
        }
        freeifaddrs(ifs);
    }

    long end = now_ms() + timeout;
    char buf[4097];
    for (int answers = 0; answers < MAX_ANSWERS;) {
        long left = end - now_ms();
        if (left <= 0) break;
        struct pollfd p = {fd, POLLIN, 0};
        if (poll(&p, 1, (int)left) <= 0) continue;
        ssize_t n = recv(fd, buf, sizeof buf - 1, 0);
        if (n <= 0) continue;
        for (ssize_t k = 0; k < n; k++)
            if ((unsigned char)buf[k] < 0x20 || buf[k] == 0x7f) buf[k] = ' ';
        buf[n] = '\0';
        printf("%s\n", buf);
        fflush(stdout);
        answers++;
    }
    close(fd);
    return 0;
}
