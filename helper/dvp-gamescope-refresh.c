/*
 * dvp-gamescope-refresh: asks gamescope (SteamOS game mode) for a display
 * refresh rate, the way Steam's refresh-rate slider does, through
 * gamescope's private gamescope_control Wayland protocol.
 *
 *   dvp-gamescope-refresh info     prints the active display and the refresh
 *                                  rates gamescope can switch it to, e.g.
 *                                  "connector=eDP-1 internal=1 rates=45,47,48"
 *                                  (empty rates: the display can't switch)
 *   dvp-gamescope-refresh set HZ   requests HZ; 0 gives the display back to
 *                                  its native rate
 *
 * Why not the GAMESCOPE_DYNAMIC_REFRESH X property: since gamescope 3.13
 * the compositor recomputes that value from the protocol's request on every
 * frame, so writing the property has no lasting effect. See
 * docs/DECISIONS.md D31.
 *
 * Exit status: 0 ok, 1 usage, 2 gamescope or the protocol not available.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

#include "gamescope-control-client-protocol.h"

/* Version 2 has set_app_target_refresh_cycle and active_display_info; we
 * bind no higher so gamescope never sends events we don't handle. */
#define CONTROL_VERSION 2

struct state {
    struct gamescope_control *control;
    int only_refresh_supported;
    int have_info;
    char connector[64];
    uint32_t display_flags;
    uint32_t rates[64];
    size_t n_rates;
};

static void on_feature_support(void *data, struct gamescope_control *control,
                               uint32_t feature, uint32_t version, uint32_t flags)
{
    struct state *s = data;
    (void)control; (void)version; (void)flags;
    if (feature == GAMESCOPE_CONTROL_FEATURE_REFRESH_CYCLE_ONLY_CHANGE_REFRESH_RATE)
        s->only_refresh_supported = 1;
}

static void on_active_display_info(void *data, struct gamescope_control *control,
                                   const char *connector_name, const char *display_make,
                                   const char *display_model, uint32_t display_flags,
                                   struct wl_array *valid_refresh_rates)
{
    struct state *s = data;
    (void)control; (void)display_make; (void)display_model;
    s->have_info = 1;
    snprintf(s->connector, sizeof s->connector, "%s", connector_name ? connector_name : "");
    s->display_flags = display_flags;
    s->n_rates = 0;
    uint32_t *rate;
    wl_array_for_each(rate, valid_refresh_rates) {
        if (s->n_rates < sizeof s->rates / sizeof s->rates[0])
            s->rates[s->n_rates++] = *rate;
    }
}

static const struct gamescope_control_listener control_listener = {
    .feature_support = on_feature_support,
    .active_display_info = on_active_display_info,
};

static void on_global(void *data, struct wl_registry *registry, uint32_t name,
                      const char *interface, uint32_t version)
{
    struct state *s = data;
    if (strcmp(interface, gamescope_control_interface.name) == 0 && version >= CONTROL_VERSION) {
        s->control = wl_registry_bind(registry, name, &gamescope_control_interface, CONTROL_VERSION);
        gamescope_control_add_listener(s->control, &control_listener, s);
    }
}

static void on_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
    (void)data; (void)registry; (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = on_global,
    .global_remove = on_global_remove,
};

static int usage(void)
{
    fprintf(stderr, "usage: dvp-gamescope-refresh info | set HZ\n");
    return 1;
}

int main(int argc, char **argv)
{
    if (argc < 2) return usage();
    int set = strcmp(argv[1], "set") == 0;
    if (!set && strcmp(argv[1], "info") != 0) return usage();
    if (set && argc < 3) return usage();
    long hz = 0;
    if (set) {
        char *end = NULL;
        hz = strtol(argv[2], &end, 10);
        /* "abc" must not silently become 0 (= back to native). */
        if (argv[2][0] == '\0' || *end != '\0') return usage();
    }
    if (hz < 0 || hz > 1000) return usage();

    const char *socket = getenv("GAMESCOPE_WAYLAND_DISPLAY");
    if (!socket || !*socket) {
        fprintf(stderr, "not running under gamescope (GAMESCOPE_WAYLAND_DISPLAY unset)\n");
        return 2;
    }
    struct wl_display *display = wl_display_connect(socket);
    if (!display) {
        fprintf(stderr, "cannot connect to gamescope socket %s\n", socket);
        return 2;
    }

    struct state s = {0};
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, &s);
    wl_display_roundtrip(display);          /* globals */
    if (!s.control) {
        fprintf(stderr, "gamescope_control (version %d) not offered\n", CONTROL_VERSION);
        wl_display_disconnect(display);
        return 2;
    }
    wl_display_roundtrip(display);          /* feature_support + active_display_info */

    int internal = (s.display_flags & GAMESCOPE_CONTROL_DISPLAY_FLAG_INTERNAL_DISPLAY) != 0;
    if (set) {
        uint32_t flags = GAMESCOPE_CONTROL_TARGET_REFRESH_CYCLE_FLAG_ALLOW_REFRESH_SWITCHING;
        if (internal || !s.have_info)
            flags |= GAMESCOPE_CONTROL_TARGET_REFRESH_CYCLE_FLAG_INTERNAL_DISPLAY;
        /* Don't add a frame limiter: mpv paces video itself. */
        if (s.only_refresh_supported)
            flags |= GAMESCOPE_CONTROL_TARGET_REFRESH_CYCLE_FLAG_ONLY_CHANGE_REFRESH_RATE;
        gamescope_control_set_app_target_refresh_cycle(s.control, (uint32_t)hz, flags);
        wl_display_roundtrip(display);
    }

    printf("connector=%s internal=%d only_refresh=%d rates=", s.connector, internal,
           s.only_refresh_supported);
    for (size_t i = 0; i < s.n_rates; i++)
        printf(i ? ",%u" : "%u", s.rates[i]);
    printf("\n");

    gamescope_control_destroy(s.control);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return 0;
}
