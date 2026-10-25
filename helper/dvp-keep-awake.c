/*
 * dvp-keep-awake: keeps the screen awake while a video plays (D43).
 *
 * SteamOS game mode dims and sleeps on its own idle timer, which ignores
 * mpv's screensaver handling but honours org.freedesktop.ScreenSaver
 * inhibitions (verified on a Steam Deck). This helper asks for one there,
 * and through the org.freedesktop.portal.Inhibit portal (desktop sessions),
 * then stays connected: both inhibitions last until it exits.
 *
 *   --status FILE   write the outcome to FILE ("request: …"), for the
 *                   app's info panel
 *
 * The app starts it when playback starts or resumes and kills it on pause
 * or stop; it also exits when its parent dies (PR_SET_PDEATHSIG).
 */
#define _GNU_SOURCE
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>
#include <systemd/sd-bus.h>

static const char *status_file;
static char portal_result[96] = "";
static char screensaver_result[96] = "";
static volatile sig_atomic_t stop;

static void write_status(void)
{
    if (!status_file) return;
    char tmp[4096];
    snprintf(tmp, sizeof tmp, "%s.tmp", status_file);
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fprintf(f, "request: portal %s, screensaver %s\n", portal_result, screensaver_result);
    if (fclose(f) == 0) rename(tmp, status_file);
}

static void on_signal(int sig)
{
    (void)sig;
    stop = 1;
}

static const char *short_error(const sd_bus_error *e, int r)
{
    if (e && e->name) {
        if (strcmp(e->name, SD_BUS_ERROR_SERVICE_UNKNOWN) == 0) return "not running";
        if (strcmp(e->name, SD_BUS_ERROR_UNKNOWN_METHOD) == 0 ||
            strcmp(e->name, SD_BUS_ERROR_UNKNOWN_INTERFACE) == 0 ||
            strcmp(e->name, SD_BUS_ERROR_UNKNOWN_OBJECT) == 0) return "not supported";
        if (strcmp(e->name, SD_BUS_ERROR_ACCESS_DENIED) == 0) return "access denied";
        return e->name;
    }
    return strerror(-r);
}

/* The portal answers through a Response signal on the request object if
 * the backend fails; 0 means the inhibition is in place. */
static int on_portal_response(sd_bus_message *m, void *data, sd_bus_error *err)
{
    (void)data; (void)err;
    uint32_t code = 0;
    if (sd_bus_message_read(m, "u", &code) >= 0) {
        snprintf(portal_result, sizeof portal_result, code == 0 ? "accepted" : "refused (%u)", code);
        write_status();
    }
    return 0;
}

static void request_inhibit(sd_bus *bus)
{
    sd_bus_error err = SD_BUS_ERROR_NULL;
    sd_bus_message *reply = NULL;
    int r;

    /* Portal: subscribe to the predictable request path first. */
    const char *unique = NULL;
    char sender[128] = "", path[256];
    if (sd_bus_get_unique_name(bus, &unique) >= 0 && unique) {
        size_t j = 0;
        for (const char *p = unique + 1; *p && j < sizeof sender - 1; p++) sender[j++] = (*p == '.') ? '_' : *p;
        sender[j] = 0;
    }
    snprintf(path, sizeof path, "/org/freedesktop/portal/desktop/request/%s/dvp_keep_awake", sender);
    sd_bus_match_signal(bus, NULL, "org.freedesktop.portal.Desktop", path,
                        "org.freedesktop.portal.Request", "Response", on_portal_response, NULL);
    /* flags: 4 = suspend, 8 = idle */
    r = sd_bus_call_method(bus, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                           "org.freedesktop.portal.Inhibit", "Inhibit", &err, &reply,
                           "sua{sv}", "", (uint32_t)(4 | 8), 2,
                           "handle_token", "s", "dvp_keep_awake",
                           "reason", "s", "Playing a video");
    snprintf(portal_result, sizeof portal_result, "%s", r < 0 ? short_error(&err, r) : "requested");
    sd_bus_error_free(&err);
    sd_bus_message_unref(reply);
    reply = NULL;

    /* The screensaver service directly: what SteamOS game mode honours. */
    uint32_t cookie = 0;
    r = sd_bus_call_method(bus, "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver",
                           "org.freedesktop.ScreenSaver", "Inhibit", &err, &reply,
                           "ss", "Deck Video Player", "Playing a video");
    if (r >= 0 && sd_bus_message_read(reply, "u", &cookie) >= 0)
        snprintf(screensaver_result, sizeof screensaver_result, "accepted");
    else
        snprintf(screensaver_result, sizeof screensaver_result, "%s", short_error(&err, r));
    sd_bus_error_free(&err);
    sd_bus_message_unref(reply);
    write_status();
}

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--status") == 0 && i + 1 < argc) status_file = argv[++i];
        else {
            fprintf(stderr, "usage: %s [--status FILE]\n", argv[0]);
            return 2;
        }
    }
    prctl(PR_SET_PDEATHSIG, SIGTERM);
    if (getppid() == 1) return 0;
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);

    sd_bus *bus = NULL;
    int r = sd_bus_open_user(&bus);
    if (r < 0) {
        snprintf(portal_result, sizeof portal_result, "no session bus");
        snprintf(screensaver_result, sizeof screensaver_result, "no session bus");
        write_status();
        return 1;
    }
    request_inhibit(bus);

    while (!stop) {
        while (sd_bus_process(bus, NULL) > 0) {}
        sd_bus_wait(bus, UINT64_MAX);   /* a signal interrupts it */
    }
    sd_bus_flush_close_unref(bus);   /* drops both inhibitions */
    return 0;
}
