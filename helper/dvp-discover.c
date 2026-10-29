/*
 * dvp-discover: finds media servers on the local network.
 *
 * Jellyfin (D55): sends Jellyfin's discovery message ("who is
 * JellyfinServer?") as a UDP broadcast to port 7359, on every IPv4
 * interface that can broadcast and to 255.255.255.255, then prints each
 * answer (a JSON object with Address, Id and Name) on its own line until
 * the time is up.
 *
 *   dvp-discover [TIMEOUT_MS]           default 1500, at most 10000
 *
 * DLNA (D66): sends an SSDP M-SEARCH for UPnP media servers to
 * 239.255.255.250:1900 (twice, on every IPv4 multicast interface) and
 * prints one line per answer: the sender's address, then the LOCATION,
 * USN and SERVER headers, separated by tabs.
 *
 *   dvp-discover --ssdp [TIMEOUT_MS]    default 2500, at most 10000
 *
 * Answers are printed as received, with control characters replaced by
 * spaces, at most MAX_ANSWERS of them; the app parses and checks them
 * (dvp/jellyfin.lua, dvp/dlna.lua).
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <strings.h>
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

#define SSDP_PORT 1900
static const char SSDP_SEARCH[] =
    "M-SEARCH * HTTP/1.1\r\n"
    "HOST: 239.255.255.250:1900\r\n"
    "MAN: \"ssdp:discover\"\r\n"
    "MX: 2\r\n"
    "ST: urn:schemas-upnp-org:device:MediaServer:1\r\n"
    "\r\n";

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

/* Replaces control characters with spaces (output is line-based). */
static void sanitize(char *s, size_t n)
{
    for (size_t k = 0; k < n; k++)
        if ((unsigned char)s[k] < 0x20 || s[k] == 0x7f) s[k] = ' ';
}

/* Value of header `name` (case-insensitive) in an HTTP-style message, copied
 * to `out` (at most `size` - 1 bytes); "" if absent. */
static void header(const char *msg, const char *name, char *out, size_t size)
{
    size_t len = strlen(name);
    out[0] = '\0';
    for (const char *line = msg; line && *line; line = strchr(line, '\n')) {
        if (*line == '\n') line++;
        if (strncasecmp(line, name, len) == 0 && line[len] == ':') {
            const char *v = line + len + 1;
            while (*v == ' ' || *v == '\t') v++;
            size_t n = strcspn(v, "\r\n");
            if (n >= size) n = size - 1;
            memcpy(out, v, n);
            out[n] = '\0';
            sanitize(out, n);
            return;
        }
    }
}

static int ssdp(long timeout)
{
    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        perror("socket");
        return 1;
    }
    unsigned char ttl = 2;
    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof ttl);
    struct sockaddr_in group = {0};
    group.sin_family = AF_INET;
    group.sin_port = htons(SSDP_PORT);
    inet_pton(AF_INET, "239.255.255.250", &group.sin_addr);

    for (int round = 0; round < 2; round++) {
        /* The default route's interface, then each multicast interface. */
        sendto(fd, SSDP_SEARCH, sizeof SSDP_SEARCH - 1, 0, (struct sockaddr *)&group, sizeof group);
        struct ifaddrs *ifs = NULL;
        if (getifaddrs(&ifs) == 0) {
            for (struct ifaddrs *i = ifs; i; i = i->ifa_next) {
                if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET) continue;
                if (!(i->ifa_flags & IFF_UP) || !(i->ifa_flags & IFF_MULTICAST) || (i->ifa_flags & IFF_LOOPBACK))
                    continue;
                struct in_addr a = ((struct sockaddr_in *)i->ifa_addr)->sin_addr;
                if (setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &a, sizeof a) == 0)
                    sendto(fd, SSDP_SEARCH, sizeof SSDP_SEARCH - 1, 0, (struct sockaddr *)&group, sizeof group);
            }
            freeifaddrs(ifs);
        }
        if (round == 0) {
            struct timespec pause = {0, 200 * 1000000L}; /* UDP can be lost: ask twice */
            nanosleep(&pause, NULL);
        }
    }

    long end = now_ms() + timeout;
    char buf[4097], location[1024], usn[512], server[256], from[INET_ADDRSTRLEN];
    for (int answers = 0; answers < MAX_ANSWERS;) {
        long left = end - now_ms();
        if (left <= 0) break;
        struct pollfd p = {fd, POLLIN, 0};
        if (poll(&p, 1, (int)left) <= 0) continue;
        struct sockaddr_in src;
        socklen_t srclen = sizeof src;
        ssize_t n = recvfrom(fd, buf, sizeof buf - 1, 0, (struct sockaddr *)&src, &srclen);
        if (n <= 0) continue;
        buf[n] = '\0';
        if (strncmp(buf, "HTTP/1.", 7) != 0) continue;
        header(buf, "LOCATION", location, sizeof location);
        if (!location[0]) continue;
        header(buf, "USN", usn, sizeof usn);
        header(buf, "SERVER", server, sizeof server);
        inet_ntop(AF_INET, &src.sin_addr, from, sizeof from);
        printf("%s\t%s\t%s\t%s\n", from, location, usn, server);
        fflush(stdout);
        answers++;
    }
    close(fd);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc > 1 && strcmp(argv[1], "--ssdp") == 0) {
        long t = argc > 2 ? strtol(argv[2], NULL, 10) : 2500;
        return ssdp(t <= 0 || t > 10000 ? 2500 : t);
    }
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
        sanitize(buf, (size_t)n);
        buf[n] = '\0';
        printf("%s\n", buf);
        fflush(stdout);
        answers++;
    }
    close(fd);
    return 0;
}
