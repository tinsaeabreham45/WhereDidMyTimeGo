/*
 * wdmtg-idle: minimal ext-idle-notify-v1 helper for WhereDidMyTimeGo.
 *
 * KWin Wayland does not expose idle time through a supported D-Bus API.
 * This helper subscribes to the compositor's idle notifier and sends
 * SIGUSR1 (idle) or SIGUSR2 (resumed) to the Bash tracker process.
 *
 * It sends no data and reads no input. The only dependency is wayland-client.
 */
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>
#include <wayland-client.h>

#include "ext-idle-notify-v1-client-protocol.h"

static volatile sig_atomic_t running = 1;
static pid_t parent_pid = 0;
static struct wl_display *display = NULL;
static struct wl_registry *registry = NULL;
static struct wl_seat *seat = NULL;
static struct ext_idle_notifier_v1 *notifier = NULL;
static struct ext_idle_notification_v1 *notification = NULL;

static void handle_signal(int signo)
{
    (void)signo;
    running = 0;
}

static void send_parent_signal(int signo)
{
    if (parent_pid > 0 && kill(parent_pid, signo) != 0 && errno == ESRCH) {
        running = 0;
    }
}

static void on_idled(void *data, struct ext_idle_notification_v1 *note)
{
    (void)data;
    (void)note;
    send_parent_signal(SIGUSR1);
}

static void on_resumed(void *data, struct ext_idle_notification_v1 *note)
{
    (void)data;
    (void)note;
    send_parent_signal(SIGUSR2);
}

static const struct ext_idle_notification_v1_listener notification_listener = {
    .idled = on_idled,
    .resumed = on_resumed,
};

static void on_global(void *data, struct wl_registry *reg, uint32_t name,
                      const char *interface, uint32_t version)
{
    (void)data;

    if (strcmp(interface, ext_idle_notifier_v1_interface.name) == 0) {
        notifier = wl_registry_bind(reg, name, &ext_idle_notifier_v1_interface, 1);
    } else if (strcmp(interface, wl_seat_interface.name) == 0) {
        uint32_t bind_version = version < 5 ? version : 5;
        seat = wl_registry_bind(reg, name, &wl_seat_interface, bind_version);
    }
}

static void on_global_remove(void *data, struct wl_registry *reg, uint32_t name)
{
    (void)data;
    (void)reg;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = on_global,
    .global_remove = on_global_remove,
};

static void usage(const char *program)
{
    fprintf(stderr,
            "usage: %s --timeout-ms MS --parent PID\n"
            "  Sends SIGUSR1/SIGUSR2 to the parent on idle/resume.\n",
            program);
}

static int parse_args(int argc, char **argv, uint32_t *timeout_ms)
{
    int i;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--timeout-ms") == 0 && i + 1 < argc) {
            char *end = NULL;
            unsigned long value = strtoul(argv[++i], &end, 10);
            if (end == argv[i] || *end != '\0' || value == 0 || value > UINT32_MAX) {
                fprintf(stderr, "invalid timeout: %s\n", argv[i]);
                return -1;
            }
            *timeout_ms = (uint32_t)value;
        } else if (strcmp(argv[i], "--parent") == 0 && i + 1 < argc) {
            char *end = NULL;
            long value = strtol(argv[++i], &end, 10);
            if (end == argv[i] || *end != '\0' || value <= 0) {
                fprintf(stderr, "invalid parent PID: %s\n", argv[i]);
                return -1;
            }
            parent_pid = (pid_t)value;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
            exit(0);
        } else {
            fprintf(stderr, "unknown argument: %s\n", argv[i]);
            return -1;
        }
    }

    if (*timeout_ms == 0 || parent_pid <= 0) {
        usage(argv[0]);
        return -1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    uint32_t timeout_ms = 0;
    struct sigaction action;

    if (parse_args(argc, argv, &timeout_ms) != 0) {
        return 2;
    }

    memset(&action, 0, sizeof(action));
    action.sa_handler = handle_signal;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGHUP, &action, NULL);

    /*
     * Do not outlive the Bash daemon, even if it is killed with SIGKILL.
     * SIGKILL is intentional: SIGTERM can leave a helper blocked in the
     * Wayland event loop after its parent has already gone away.
     */
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0) {
        perror("prctl");
        return 1;
    }
    if (getppid() != parent_pid) {
        fprintf(stderr, "parent changed before startup\n");
        return 1;
    }

    display = wl_display_connect(NULL);
    if (display == NULL) {
        fprintf(stderr, "cannot connect to the Wayland display\n");
        return 1;
    }

    registry = wl_display_get_registry(display);
    if (registry == NULL) {
        fprintf(stderr, "cannot get the Wayland registry\n");
        wl_display_disconnect(display);
        return 1;
    }
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0) {
        fprintf(stderr, "Wayland registry roundtrip failed\n");
        wl_display_disconnect(display);
        return 1;
    }
    if (notifier == NULL || seat == NULL) {
        fprintf(stderr, "ext-idle-notify-v1 or wl_seat is unavailable\n");
        wl_display_disconnect(display);
        return 2;
    }

    notification = ext_idle_notifier_v1_get_idle_notification(notifier, timeout_ms, seat);
    if (notification == NULL) {
        fprintf(stderr, "cannot create idle notification\n");
        wl_display_disconnect(display);
        return 1;
    }
    ext_idle_notification_v1_add_listener(notification, &notification_listener, NULL);
    if (wl_display_roundtrip(display) < 0) {
        fprintf(stderr, "idle notification roundtrip failed\n");
        wl_display_disconnect(display);
        return 1;
    }

    printf("ready timeout=%ums\n", timeout_ms);
    fflush(stdout);

    while (running && wl_display_dispatch(display) != -1) {
        /* dispatch */
    }

    ext_idle_notification_v1_destroy(notification);
    wl_display_disconnect(display);
    return 0;
}
