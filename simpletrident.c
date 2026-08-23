#define _POSIX_C_SOURCE 200809L

#include <ncurses.h>

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#define CATEGORY_COUNT 4
#define DETAIL_SIZE 16384
#define FIX_SIZE 4096
#define OUTPUT_SIZE 16384
#define SUMMARY_SIZE 256
#define COMMAND_TIMEOUT_MS 5000
#define WEBSITE_TIMEOUT_MS 20000
#define POLL_MS 25

enum check_state {
    STATE_CHECKING,
    STATE_OK,
    STATE_PARTIAL,
    STATE_DOWN,
    STATE_UNKNOWN
};

enum simpleserve_mode {
    MODE_UNKNOWN,
    MODE_SERVER,
    MODE_CLIENT
};

typedef struct {
    const char *name;
    const char *subtitle;
    enum check_state state;
    char summary[SUMMARY_SIZE];
    char details[DETAIL_SIZE];
    char fix[FIX_SIZE];
} Category;

typedef struct {
    const char *name;
    const char *value;
} EnvPair;

typedef struct {
    int shares_section;
    int local_shares;
    int unavailable_shares;
    int mounts_section;
    int managed_mounts;
    int mounted;
    int unmounted;
    int remembered;
    int lan_routes;
    int tailscale_routes;
    int tailscale_nfs_reported;
    int tailscale_nfs_ready;
} SimpleServeEvidence;

static Category categories[CATEGORY_COUNT] = {
    {"SimpleServe", "intranet", STATE_CHECKING, "Waiting to check...", "", ""},
    {"Tailscale", "encrypted extranet", STATE_CHECKING, "Waiting to check...", "", ""},
    {"OpenSSH", "client + daemon", STATE_CHECKING, "Waiting to check...", "", ""},
    {"Caddy website", "local web origin", STATE_CHECKING, "Waiting to check...", "", ""}
};

static int ui_active;
static int selected_category;
static int detail_mode;
static int detail_scroll;
static int detail_line_count;
static char footer[SUMMARY_SIZE] = "Checking the Trident...";
static char home_dir[PATH_MAX];
static char service_manager[32];
static char simpleserve_status[OUTPUT_SIZE];
static int simpleserve_status_ok;
static enum simpleserve_mode simpleserve_mode = MODE_UNKNOWN;
static SimpleServeEvidence simpleserve_evidence;
static char last_checked[64];

static int visible_category_count(void)
{
    return simpleserve_mode == MODE_CLIENT ? CATEGORY_COUNT - 1 : CATEGORY_COUNT;
}

static int64_t monotonic_ms(void)
{
    struct timespec now;

    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
        return 0;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static void copy_string(char *destination, size_t size, const char *source)
{
    size_t length;

    if (!size)
        return;
    if (!source)
        source = "";
    length = strnlen(source, size - 1);
    memcpy(destination, source, length);
    destination[length] = '\0';
}

static int join_path(char *destination, size_t size, const char *base,
                     const char *suffix)
{
    size_t base_length = strlen(base);
    size_t suffix_length = strlen(suffix);

    if (!size || base_length >= size || suffix_length >= size - base_length)
        return 0;
    memcpy(destination, base, base_length);
    memcpy(destination + base_length, suffix, suffix_length + 1);
    return 1;
}

static void append_text(char *destination, size_t size, const char *format, ...)
{
    size_t used;
    va_list arguments;

    if (!size)
        return;
    used = strlen(destination);
    if (used >= size - 1)
        return;
    va_start(arguments, format);
    (void)vsnprintf(destination + used, size - used, format, arguments);
    va_end(arguments);
}

static void trim_whitespace(char *text)
{
    char *start = text;
    size_t length;

    while (*start == ' ' || *start == '\t' || *start == '\n' ||
           *start == '\r')
        start++;
    if (start != text)
        memmove(text, start, strlen(start) + 1);
    length = strlen(text);
    while (length &&
           (text[length - 1] == ' ' || text[length - 1] == '\t' ||
            text[length - 1] == '\n' || text[length - 1] == '\r'))
        text[--length] = '\0';
}

static void one_line(char *text)
{
    for (char *cursor = text; *cursor; cursor++) {
        if (*cursor == '\n' || *cursor == '\r' || *cursor == '\t')
            *cursor = ' ';
    }
    trim_whitespace(text);
}

static void category_reset(Category *category)
{
    category->state = STATE_CHECKING;
    copy_string(category->summary, sizeof(category->summary), "Checking...");
    category->details[0] = '\0';
    category->fix[0] = '\0';
}

static void category_ok(Category *category, const char *format, ...)
{
    size_t used = strlen(category->details);
    va_list arguments;

    append_text(category->details, sizeof(category->details), "[ok] ");
    used = strlen(category->details);
    va_start(arguments, format);
    (void)vsnprintf(category->details + used,
                    sizeof(category->details) - used, format, arguments);
    va_end(arguments);
    append_text(category->details, sizeof(category->details), "\n");
}

static int state_priority(enum check_state state)
{
    switch (state) {
    case STATE_DOWN: return 3;
    case STATE_UNKNOWN: return 2;
    case STATE_PARTIAL: return 1;
    case STATE_OK:
    case STATE_CHECKING: return 0;
    }
    return 0;
}

static void category_set_state(Category *category, enum check_state state,
                               const char *summary)
{
    if (category->state == STATE_CHECKING && summary)
        copy_string(category->summary, sizeof(category->summary), summary);
    if (state_priority(state) > state_priority(category->state))
        category->state = state;
}

static void category_issue(Category *category, enum check_state state,
                           const char *label, const char *format,
                           va_list arguments)
{
    char message[SUMMARY_SIZE];

    (void)vsnprintf(message, sizeof(message), format, arguments);
    category_set_state(category, state, message);
    append_text(category->details, sizeof(category->details),
                "[%s] %s\n", label, message);
}

static void category_partial(Category *category, const char *format, ...)
{
    va_list arguments;

    va_start(arguments, format);
    category_issue(category, STATE_PARTIAL, "partial", format, arguments);
    va_end(arguments);
}

static void category_down(Category *category, const char *format, ...)
{
    va_list arguments;

    va_start(arguments, format);
    category_issue(category, STATE_DOWN, "down", format, arguments);
    va_end(arguments);
}

static void category_unknown(Category *category, const char *format, ...)
{
    va_list arguments;

    va_start(arguments, format);
    category_issue(category, STATE_UNKNOWN, "unknown", format, arguments);
    va_end(arguments);
}

static void category_blocked(Category *category, const char *format, ...)
{
    size_t used;
    va_list arguments;

    append_text(category->details, sizeof(category->details), "[blocked] ");
    used = strlen(category->details);
    va_start(arguments, format);
    (void)vsnprintf(category->details + used,
                    sizeof(category->details) - used, format, arguments);
    va_end(arguments);
    append_text(category->details, sizeof(category->details), "\n");
}

static void parse_simpleserve_evidence(const char *status,
                                       SimpleServeEvidence *evidence)
{
    char copy[OUTPUT_SIZE];
    char *line;
    char *save = NULL;
    int section = 0;

    memset(evidence, 0, sizeof(*evidence));
    copy_string(copy, sizeof(copy), status);
    for (line = strtok_r(copy, "\n\r", &save); line;
         line = strtok_r(NULL, "\n\r", &save)) {
        trim_whitespace(line);
        if (strcmp(line, "Local shares:") == 0) {
            section = 1;
            evidence->shares_section = 1;
            continue;
        }
        if (strcmp(line, "Managed mounts:") == 0) {
            section = 2;
            evidence->mounts_section = 1;
            continue;
        }
        if (!line[0] || strcmp(line, "(none)") == 0)
            continue;
        if (section == 1) {
            evidence->local_shares++;
            if (strstr(line, "(drive unavailable)"))
                evidence->unavailable_shares++;
        } else if (section == 2) {
            int remembered;

            evidence->managed_mounts++;
            if (strstr(line, "not mounted"))
                evidence->unmounted++;
            else if (strstr(line, "mounted"))
                evidence->mounted++;
            remembered = strstr(line, ", remembered") != NULL;
            if (remembered)
                evidence->remembered++;
            if (strstr(line, "route: LAN"))
                evidence->lan_routes++;
            else if (strstr(line, "route: Tailscale"))
                evidence->tailscale_routes++;
            if (remembered && strstr(line, "Tailscale NFS:")) {
                evidence->tailscale_nfs_reported++;
                if (strstr(line, "Tailscale NFS: ready"))
                    evidence->tailscale_nfs_ready++;
            }
        }
    }
}

static void report_simpleserve_evidence(Category *category, const char *role)
{
    int active_shares = simpleserve_evidence.local_shares -
                        simpleserve_evidence.unavailable_shares;

    if (strcmp(role, "server") == 0) {
        if (!simpleserve_evidence.shares_section) {
            category_unknown(category,
                             "Local publishing state is unavailable from daemon status");
        } else if (simpleserve_evidence.local_shares == 0) {
            category_partial(category,
                             "Server mode is ready, but no local shares are configured");
        } else if (active_shares == 0) {
            category_down(category,
                          "All %d configured local share%s %s unavailable",
                          simpleserve_evidence.local_shares,
                          simpleserve_evidence.local_shares == 1 ? "" : "s",
                          simpleserve_evidence.local_shares == 1 ? "is" : "are");
        } else if (simpleserve_evidence.unavailable_shares > 0) {
            category_partial(category,
                             "%d of %d configured local shares are unavailable",
                             simpleserve_evidence.unavailable_shares,
                             simpleserve_evidence.local_shares);
        } else {
            category_ok(category,
                        "%d local share%s active for NFS and SMB publishing",
                        active_shares, active_shares == 1 ? " is" : "s are");
        }
        category_ok(category,
                    "Server publishing reconciles UUID persistence, removable-drive availability, NFS, SMB, and mDNS");
    } else {
        category_ok(category,
                    "Client role permits discovery, NFS mounting, and remembered reconnects without publishing shares");
    }

    if (!simpleserve_evidence.mounts_section) {
        category_unknown(category,
                         "Managed NFS mount state is unavailable from daemon status");
    } else if (simpleserve_evidence.managed_mounts == 0) {
        category_ok(category, "No remote NFS shares are currently remembered");
    } else {
        if (simpleserve_evidence.mounted > 0) {
            category_ok(category,
                        "%d managed NFS mount%s active (%d LAN, %d Tailscale)",
                        simpleserve_evidence.mounted,
                        simpleserve_evidence.mounted == 1 ? " is" : "s are",
                        simpleserve_evidence.lan_routes,
                        simpleserve_evidence.tailscale_routes);
        }
        if (simpleserve_evidence.remembered > 0) {
            category_ok(category,
                        "%d managed mount%s remembered for reconnect after reboot",
                        simpleserve_evidence.remembered,
                        simpleserve_evidence.remembered == 1 ? " is" : "s are");
        }
        if (simpleserve_evidence.unmounted > 0) {
            category_partial(category,
                             "%d managed NFS mount%s currently not mounted",
                             simpleserve_evidence.unmounted,
                             simpleserve_evidence.unmounted == 1 ? " is" : "s are");
        }
    }
}

static int executable_file(const char *path)
{
    struct stat status;

    return path && path[0] && stat(path, &status) == 0 &&
           S_ISREG(status.st_mode) && access(path, X_OK) == 0;
}

static int files_equal(const char *left_path, const char *right_path)
{
    unsigned char left_buffer[8192];
    unsigned char right_buffer[8192];
    FILE *left = fopen(left_path, "rb");
    FILE *right = fopen(right_path, "rb");
    int equal = 0;

    if (!left || !right)
        goto done;
    for (;;) {
        size_t left_count = fread(left_buffer, 1, sizeof(left_buffer), left);
        size_t right_count = fread(right_buffer, 1, sizeof(right_buffer), right);

        if (left_count != right_count ||
            memcmp(left_buffer, right_buffer, left_count) != 0)
            goto done;
        if (left_count < sizeof(left_buffer)) {
            if (ferror(left) || ferror(right))
                goto done;
            equal = 1;
            goto done;
        }
    }

done:
    if (left)
        fclose(left);
    if (right)
        fclose(right);
    return equal;
}

static int assignment_has_value(const char *line, const char *name)
{
    const char *cursor = line;
    const char *end;
    size_t name_length = strlen(name);

    while (*cursor == ' ' || *cursor == '\t')
        cursor++;
    if (strncmp(cursor, name, name_length) != 0 ||
        cursor[name_length] != '=')
        return 0;
    cursor += name_length + 1;
    while (*cursor == ' ' || *cursor == '\t')
        cursor++;
    end = cursor + strlen(cursor);
    while (end > cursor &&
           (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\n' ||
            end[-1] == '\r'))
        end--;
    if (end == cursor)
        return 0;
    return !((end - cursor == 2) &&
             ((cursor[0] == '\'' && cursor[1] == '\'') ||
              (cursor[0] == '"' && cursor[1] == '"')));
}

/* Return 1 when configured, 0 when absent/incomplete, and -1 when unreadable. */
static int store_recovery_mail_status(const char *path)
{
    FILE *stream;
    char *line = NULL;
    size_t capacity = 0;
    int host = 0;
    int sender = 0;
    int result;

    stream = fopen(path, "r");
    if (!stream)
        return errno == ENOENT ? 0 : -1;
    while (getline(&line, &capacity, stream) >= 0) {
        if (assignment_has_value(line, "STORE_SMTP_HOST"))
            host = 1;
        else if (assignment_has_value(line, "STORE_EMAIL_FROM"))
            sender = 1;
    }
    result = ferror(stream) ? -1 : (host && sender);
    free(line);
    fclose(stream);
    return result;
}

static int find_on_path(const char *name, char *result, size_t result_size)
{
    const char *path_value = getenv("PATH");
    char *paths;
    char *save = NULL;
    char *directory;

    if (!name || !name[0])
        return 0;
    if (strchr(name, '/')) {
        if (!executable_file(name))
            return 0;
        copy_string(result, result_size, name);
        return 1;
    }
    if (!path_value)
        path_value = "/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin";
    paths = strdup(path_value);
    if (!paths)
        return 0;
    for (directory = strtok_r(paths, ":", &save); directory;
         directory = strtok_r(NULL, ":", &save)) {
        char candidate[PATH_MAX];

        if (!directory[0])
            directory = ".";
        if (snprintf(candidate, sizeof(candidate), "%s/%s", directory, name) >=
            (int)sizeof(candidate))
            continue;
        if (executable_file(candidate)) {
            copy_string(result, result_size, candidate);
            free(paths);
            return 1;
        }
    }
    free(paths);
    return 0;
}

static int find_program(const char *override_name, const char *name,
                        const char *const known[], char *result,
                        size_t result_size)
{
    const char *override = getenv(override_name);
    char local[PATH_MAX];

    result[0] = '\0';
    if (override && override[0])
        return find_on_path(override, result, result_size);
    if (find_on_path(name, result, result_size))
        return 1;
    if (snprintf(local, sizeof(local), "%s/.local/bin/%s", home_dir, name) <
            (int)sizeof(local) &&
        executable_file(local)) {
        copy_string(result, result_size, local);
        return 1;
    }
    if (known) {
        for (size_t index = 0; known[index]; index++) {
            if (executable_file(known[index])) {
                copy_string(result, result_size, known[index]);
                return 1;
            }
        }
    }
    return 0;
}

static void stop_child(pid_t child)
{
    int status;
    int64_t deadline;

    if (child <= 0)
        return;
    if (kill(-child, SIGTERM) != 0)
        (void)kill(child, SIGTERM);
    deadline = monotonic_ms() + 100;
    while (monotonic_ms() < deadline) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child || (waited < 0 && errno == ECHILD))
            return;
        (void)poll(NULL, 0, 5);
    }
    if (kill(-child, SIGKILL) != 0)
        (void)kill(child, SIGKILL);
    while (waitpid(child, &status, 0) < 0 && errno == EINTR)
        ;
}

/* Return the child's exit code, -1 when it could not start, or -2 on timeout. */
static int run_capture(const char *const arguments[], const EnvPair environment[],
                       int timeout_ms, char *output, size_t output_size)
{
    int descriptors[2];
    int status = 0;
    int child_done = 0;
    int pipe_open = 1;
    int truncated = 0;
    size_t used = 0;
    pid_t child;
    int64_t deadline;

    if (output_size)
        output[0] = '\0';
    if (pipe(descriptors) != 0)
        return -1;
    child = fork();
    if (child < 0) {
        close(descriptors[0]);
        close(descriptors[1]);
        return -1;
    }
    if (child == 0) {
        int null_descriptor;

        (void)setpgid(0, 0);
        close(descriptors[0]);
        null_descriptor = open("/dev/null", O_RDONLY);
        if (null_descriptor < 0 ||
            dup2(null_descriptor, STDIN_FILENO) < 0 ||
            dup2(descriptors[1], STDOUT_FILENO) < 0 ||
            dup2(descriptors[1], STDERR_FILENO) < 0)
            _exit(126);
        if (null_descriptor > STDERR_FILENO)
            close(null_descriptor);
        if (descriptors[1] > STDERR_FILENO)
            close(descriptors[1]);
        if (environment) {
            for (size_t index = 0; environment[index].name; index++)
                (void)setenv(environment[index].name,
                             environment[index].value, 1);
        }
        execvp(arguments[0], (char *const *)arguments);
        _exit(127);
    }

    (void)setpgid(child, child);
    close(descriptors[1]);
    {
        int flags = fcntl(descriptors[0], F_GETFL, 0);
        int descriptor_flags = fcntl(descriptors[0], F_GETFD, 0);

        if (flags < 0 || descriptor_flags < 0 ||
            fcntl(descriptors[0], F_SETFL, flags | O_NONBLOCK) != 0 ||
            fcntl(descriptors[0], F_SETFD,
                  descriptor_flags | FD_CLOEXEC) != 0) {
            close(descriptors[0]);
            stop_child(child);
            return -1;
        }
    }
    deadline = monotonic_ms() + timeout_ms;

    while (!child_done) {
        char chunk[2048];
        ssize_t count;
        pid_t waited;

        while (pipe_open) {
            count = read(descriptors[0], chunk, sizeof(chunk));
            if (count > 0) {
                size_t available = output_size && used + 1 < output_size
                                       ? output_size - used - 1 : 0;
                size_t copied = (size_t)count < available
                                    ? (size_t)count : available;
                if (copied) {
                    memcpy(output + used, chunk, copied);
                    used += copied;
                    output[used] = '\0';
                }
                if (copied < (size_t)count)
                    truncated = 1;
                continue;
            }
            if (count < 0 && errno == EINTR)
                continue;
            if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
                break;
            close(descriptors[0]);
            pipe_open = 0;
            break;
        }

        do {
            waited = waitpid(child, &status, WNOHANG);
        } while (waited < 0 && errno == EINTR);
        if (waited == child || (waited < 0 && errno == ECHILD)) {
            child_done = 1;
            break;
        }
        if (monotonic_ms() >= deadline) {
            if (pipe_open)
                close(descriptors[0]);
            stop_child(child);
            if (output_size && truncated)
                append_text(output, output_size, "\n[output truncated]");
            return -2;
        }
        if (pipe_open) {
            struct pollfd descriptor = {
                .fd = descriptors[0],
                .events = POLLIN | POLLHUP
            };
            (void)poll(&descriptor, 1, POLL_MS);
        } else {
            (void)poll(NULL, 0, POLL_MS);
        }
    }

    /* Drain output already written by the direct child, but do not wait for a
     * descendant which accidentally retained the pipe. */
    if (pipe_open) {
        for (;;) {
            char chunk[2048];
            ssize_t count = read(descriptors[0], chunk, sizeof(chunk));
            if (count <= 0)
                break;
            size_t available = output_size && used + 1 < output_size
                                   ? output_size - used - 1 : 0;
            size_t copied = (size_t)count < available ? (size_t)count : available;
            if (copied) {
                memcpy(output + used, chunk, copied);
                used += copied;
                output[used] = '\0';
            }
            if (copied < (size_t)count)
                truncated = 1;
        }
        close(descriptors[0]);
    }
    if (output_size && truncated)
        append_text(output, output_size, "\n[output truncated]");
    if (WIFEXITED(status))
        return WEXITSTATUS(status);
    return WIFSIGNALED(status) ? 128 + WTERMSIG(status) : -1;
}

static int read_small_file(const char *path, char *output, size_t output_size)
{
    FILE *file;
    size_t count;

    if (!output_size)
        return 0;
    output[0] = '\0';
    file = fopen(path, "r");
    if (!file)
        return 0;
    count = fread(output, 1, output_size - 1, file);
    output[count] = '\0';
    if (ferror(file)) {
        fclose(file);
        output[0] = '\0';
        return 0;
    }
    fclose(file);
    trim_whitespace(output);
    return 1;
}

static void system_path(const char *path, char *output, size_t output_size)
{
    const char *root = getenv("SIMPLETRIDENT_SYSTEM_ROOT");

    if (!root || !root[0])
        copy_string(output, output_size, path);
    else
        (void)snprintf(output, output_size, "%s%s", root, path);
}

static int output_has_word(const char *output, const char *word)
{
    size_t length = strlen(word);

    for (const char *match = strstr(output, word); match;
         match = strstr(match + length, word)) {
        int left_ok = match == output || match[-1] == ' ' || match[-1] == '\t' ||
                      match[-1] == '\n' || match[-1] == '\r';
        char right = match[length];
        int right_ok = right == '\0' || right == ' ' || right == '\t' ||
                       right == '\n' || right == '\r';
        if (left_ok && right_ok)
            return 1;
    }
    return 0;
}

static int run_service_command(const char *const arguments[], char *output,
                               size_t output_size)
{
    return run_capture(arguments, NULL, COMMAND_TIMEOUT_MS, output, output_size);
}

static void service_failure_detail(Category *category, const char *label,
                                   const char *output)
{
    char clean[512];

    copy_string(clean, sizeof(clean), output);
    one_line(clean);
    if (clean[0])
        append_text(category->details, sizeof(category->details),
                    "          %s: %s\n", label, clean);
}

static void check_managed_service(Category *category, const char *display,
                                  const char *systemd_name,
                                  const char *openrc_name,
                                  const char *runit_name,
                                  const char *freebsd_name,
                                  const char *launchd_label)
{
    char output[2048];
    int enabled_ok = 1;
    int active_ok = 0;

    if (strcmp(service_manager, "systemd") == 0) {
        const char *enabled[] = {"systemctl", "is-enabled", "--quiet",
                                 systemd_name, NULL};
        const char *active[] = {"systemctl", "is-active", "--quiet",
                                systemd_name, NULL};
        enabled_ok = run_service_command(enabled, output, sizeof(output)) == 0;
        if (!enabled_ok)
            service_failure_detail(category, "is-enabled", output);
        active_ok = run_service_command(active, output, sizeof(output)) == 0;
        if (!active_ok)
            service_failure_detail(category, "is-active", output);
    } else if (strcmp(service_manager, "openrc") == 0) {
        const char *enabled[] = {"rc-update", "show", "default", NULL};
        const char *active[] = {"rc-service", openrc_name, "status", NULL};
        enabled_ok = run_service_command(enabled, output, sizeof(output)) == 0 &&
                     output_has_word(output, openrc_name);
        active_ok = run_service_command(active, output, sizeof(output)) == 0;
        if (!active_ok)
            service_failure_detail(category, "service status", output);
    } else if (strcmp(service_manager, "runit") == 0) {
        char link_path[PATH_MAX];
        char relative[PATH_MAX];
        char expected[PATH_MAX];
        char target[PATH_MAX];
        ssize_t target_length;
        const char *active[] = {"sv", "status", runit_name, NULL};

        (void)snprintf(relative, sizeof(relative), "/var/service/%s", runit_name);
        system_path(relative, link_path, sizeof(link_path));
        (void)snprintf(expected, sizeof(expected), "/etc/sv/%s", runit_name);
        target_length = readlink(link_path, target, sizeof(target) - 1);
        if (target_length >= 0)
            target[target_length] = '\0';
        enabled_ok = target_length >= 0 && strcmp(target, expected) == 0;
        active_ok = run_service_command(active, output, sizeof(output)) == 0;
        if (!active_ok)
            service_failure_detail(category, "service status", output);
    } else if (strcmp(service_manager, "freebsd") == 0) {
        char setting[128];
        const char *active[] = {"service", freebsd_name, "onestatus", NULL};
        const char *enabled[4];

        (void)snprintf(setting, sizeof(setting), "%s_enable", freebsd_name);
        enabled[0] = "sysrc";
        enabled[1] = "-n";
        enabled[2] = setting;
        enabled[3] = NULL;
        enabled_ok = run_service_command(enabled, output, sizeof(output)) == 0 &&
                     strstr(output, "YES") != NULL;
        active_ok = run_service_command(active, output, sizeof(output)) == 0;
        if (!active_ok)
            service_failure_detail(category, "service status", output);
    } else if (strcmp(service_manager, "launchd") == 0) {
        char domain[256];
        const char *active[4];

        (void)snprintf(domain, sizeof(domain), "system/%s", launchd_label);
        active[0] = "launchctl";
        active[1] = "print";
        active[2] = domain;
        active[3] = NULL;
        active_ok = run_service_command(active, output, sizeof(output)) == 0;
        enabled_ok = active_ok;
        if (!active_ok)
            service_failure_detail(category, "launchd", output);
    } else {
        category_unknown(category,
                         "No supported service manager was detected for %s",
                         display);
        return;
    }

    if (!active_ok)
        category_down(category, "%s is not running", display);
    if (!enabled_ok)
        category_partial(category, "%s is not enabled at boot", display);
    if (enabled_ok && active_ok)
        category_ok(category, "%s is enabled and running via %s", display,
                    service_manager);
}

static void detect_service_manager(void)
{
    const char *override = getenv("SIMPLETRIDENT_SERVICE_MANAGER");
    struct utsname identity;
    char ignored[PATH_MAX];

    if (override && override[0]) {
        copy_string(service_manager, sizeof(service_manager), override);
        return;
    }
    if (uname(&identity) != 0) {
        copy_string(service_manager, sizeof(service_manager), "unsupported");
        return;
    }
    if (strcmp(identity.sysname, "Darwin") == 0) {
        copy_string(service_manager, sizeof(service_manager), "launchd");
    } else if (strcmp(identity.sysname, "FreeBSD") == 0) {
        copy_string(service_manager, sizeof(service_manager), "freebsd");
    } else if (strcmp(identity.sysname, "Linux") == 0 &&
               access("/run/systemd/system", F_OK) == 0 &&
               find_on_path("systemctl", ignored, sizeof(ignored))) {
        copy_string(service_manager, sizeof(service_manager), "systemd");
    } else if (strcmp(identity.sysname, "Linux") == 0 &&
               find_on_path("rc-service", ignored, sizeof(ignored)) &&
               find_on_path("rc-update", ignored, sizeof(ignored))) {
        copy_string(service_manager, sizeof(service_manager), "openrc");
    } else if (strcmp(identity.sysname, "Linux") == 0 &&
               find_on_path("sv", ignored, sizeof(ignored))) {
        copy_string(service_manager, sizeof(service_manager), "runit");
    } else {
        copy_string(service_manager, sizeof(service_manager), "unsupported");
    }
}

static void check_phone_nfs_exports(Category *category)
{
    const char *override = getenv("SIMPLETRIDENT_EXPORTS");
    char path[PATH_MAX];
    char contents[OUTPUT_SIZE];
    char *cursor;
    int export_lines = 0;
    int phone_compatible_lines = 0;

    if (strcmp(service_manager, "systemd") != 0 &&
        strcmp(service_manager, "openrc") != 0 &&
        strcmp(service_manager, "runit") != 0)
        return;
    if (simpleserve_evidence.local_shares <=
        simpleserve_evidence.unavailable_shares)
        return;
    if (override && override[0])
        copy_string(path, sizeof(path), override);
    else
        system_path("/etc/exports.d/simpleserve.exports", path, sizeof(path));
    if (!read_small_file(path, contents, sizeof(contents))) {
        category_unknown(category,
                         "Managed NFS export policy is missing or unreadable");
        append_text(category->details, sizeof(category->details),
                    "          expected: %s\n", path);
        return;
    }

    cursor = contents;
    while (*cursor) {
        char *newline = strchr(cursor, '\n');
        char *line = cursor;

        if (newline)
            *newline = '\0';
        while (*line == ' ' || *line == '\t')
            line++;
        if (*line && *line != '#') {
            export_lines++;
            if (strstr(line, ",insecure,") ||
                strstr(line, "(insecure,") ||
                strstr(line, ",insecure)"))
                phone_compatible_lines++;
        }
        if (!newline)
            break;
        cursor = newline + 1;
    }

    if (export_lines == 0) {
        category_down(category,
                      "Managed NFS exports are empty despite active shares");
    } else if (phone_compatible_lines != export_lines) {
        category_partial(category,
                         "%d of %d managed NFS export entries do not accept phone source ports",
                         export_lines - phone_compatible_lines, export_lines);
    } else {
        category_ok(category,
                    "All managed NFS exports accept phone source ports");
    }
}

static void set_simpleserve_fix(Category *category, const char *role)
{
    if (role && strcmp(role, "server") == 0 &&
        simpleserve_evidence.shares_section &&
        simpleserve_evidence.local_shares == 0) {
        append_text(category->fix, sizeof(category->fix),
                    "To publish this server's first mounted drive:\n"
                    "  simpleserve share /mounted/path --name NAME\n\n");
    } else if (role && strcmp(role, "server") == 0 &&
               simpleserve_evidence.unavailable_shares > 0) {
        append_text(category->fix, sizeof(category->fix),
                    "Reconnect the drive with the UUID originally registered for the share, then run:\n"
                    "  simpleserve refresh\n"
                    "  simpleserve status\n\n");
    }
    if (simpleserve_evidence.unmounted > 0) {
        append_text(category->fix, sizeof(category->fix),
                    "Refresh discovery and retry each remembered mount that should be online:\n"
                    "  simpleserve refresh\n"
                    "  simpleserve discover\n"
                    "  simpleserve mount SERVER:SHARE --remember\n\n");
    }
    append_text(category->fix, sizeof(category->fix),
                "Reconcile the installed client, daemon, role, and boot service:\n"
                "  cd ~/scriptorium && ./install.sh\n\n");
    if (role && strcmp(role, "server") == 0) {
        append_text(category->fix, sizeof(category->fix),
                    "On the website host, server promotion can also be repaired with:\n"
                    "  setup-server\n\n");
    }
    append_text(category->fix, sizeof(category->fix),
                "Then confirm the control socket and configured role:\n"
                "  simpleserve status\n");
    if (strcmp(service_manager, "systemd") == 0) {
        append_text(category->fix, sizeof(category->fix),
                    "\nInspect service errors with:\n"
                    "  systemctl status simpleserved.service --no-pager\n"
                    "  journalctl -u simpleserved.service -n 50 --no-pager\n");
    }
}

static void check_simpleserve(Category *category)
{
    static const char *const no_known_paths[] = {NULL};
    char client[PATH_MAX];
    char daemon[PATH_MAX];
    char role_path[PATH_MAX];
    char suite[PATH_MAX];
    char verifier[PATH_MAX];
    char role[64] = "";
    char output[OUTPUT_SIZE];
    const char *role_override = getenv("SIMPLETRIDENT_ROLE_FILE");
    const char *suite_override = getenv("SIMPLESUITE_DIR");
    const char *verifier_override = getenv("SIMPLETRIDENT_SIMPLESERVE_VERIFY");
    int client_found;
    int daemon_found;
    int role_valid = 0;

    category_reset(category);
    simpleserve_status[0] = '\0';
    simpleserve_status_ok = 0;
    simpleserve_mode = MODE_UNKNOWN;
    memset(&simpleserve_evidence, 0, sizeof(simpleserve_evidence));
    client_found = find_program("SIMPLETRIDENT_SIMPLESERVE", "simpleserve",
                                no_known_paths, client, sizeof(client));
    daemon_found = find_program("SIMPLETRIDENT_SIMPLESERVED", "simpleserved",
                                no_known_paths, daemon, sizeof(daemon));
    if (role_override && role_override[0])
        copy_string(role_path, sizeof(role_path), role_override);
    else
        system_path("/etc/simpleserve-role", role_path, sizeof(role_path));
    if (suite_override && suite_override[0])
        copy_string(suite, sizeof(suite), suite_override);
    else if (!join_path(suite, sizeof(suite), home_dir, "/simplesuite"))
        suite[0] = '\0';
    if (verifier_override && verifier_override[0])
        copy_string(verifier, sizeof(verifier), verifier_override);
    else if (!join_path(verifier, sizeof(verifier), suite,
                        "/verify-simpleserve-system.sh"))
        verifier[0] = '\0';

    if (client_found)
        category_ok(category, "SimpleServe client is installed at %s", client);
    else
        category_down(category, "The SimpleServe client is not installed");
    if (daemon_found)
        category_ok(category, "SimpleServe daemon is installed at %s", daemon);
    else
        category_down(category, "The SimpleServe daemon is not installed");

    if (!read_small_file(role_path, role, sizeof(role))) {
        category_unknown(category,
                         "The SimpleServe role file is missing or unreadable");
        append_text(category->details, sizeof(category->details),
                    "          expected: %s\n", role_path);
        role[0] = '\0';
    } else if (strcmp(role, "client") != 0 && strcmp(role, "server") != 0) {
        category_unknown(category, "The SimpleServe role is invalid: %s", role);
    } else {
        role_valid = 1;
        simpleserve_mode = strcmp(role, "server") == 0
                               ? MODE_SERVER : MODE_CLIENT;
        category_ok(category, "Configured role is %s", role);
    }

    if (client_found && daemon_found) {
        const char *arguments[] = {client, "status", NULL};
        int result = run_capture(arguments, NULL, COMMAND_TIMEOUT_MS,
                                 output, sizeof(output));

        copy_string(simpleserve_status, sizeof(simpleserve_status), output);
        if (result == -2) {
            category_down(category,
                          "SimpleServe did not answer within %d seconds",
                          COMMAND_TIMEOUT_MS / 1000);
            if (role_valid)
                category_blocked(category,
                                 "Running daemon role check requires a working control socket");
        } else if (result != 0) {
            category_down(category,
                          "The SimpleServe control socket is not responding");
            service_failure_detail(category, "simpleserve status", output);
            if (role_valid)
                category_blocked(category,
                                 "Running daemon role check requires a working control socket");
        } else {
            simpleserve_status_ok = 1;
            parse_simpleserve_evidence(output, &simpleserve_evidence);
            category_ok(category, "The daemon control socket answered successfully");
            if (role_valid) {
                char expected[96];
                (void)snprintf(expected, sizeof(expected), "Role: %s", role);
                if (strstr(output, expected)) {
                    category_ok(category, "The running daemon reports the %s role", role);
                    report_simpleserve_evidence(category, role);
                    if (strcmp(role, "server") == 0)
                        check_phone_nfs_exports(category);
                } else if (strcmp(role, "server") == 0 &&
                           strstr(output, "Role: client")) {
                    category_down(category,
                                  "The running daemon does not report the configured %s role",
                                  role);
                    category_blocked(category,
                                     "Role-specific share and mount checks require the configured and running roles to agree");
                } else if (strcmp(role, "client") == 0 &&
                           strstr(output, "Role: server")) {
                    category_partial(category,
                                     "The running daemon does not report the configured %s role",
                                     role);
                    category_blocked(category,
                                     "Role-specific share and mount checks require the configured and running roles to agree");
                } else {
                    category_unknown(category,
                                     "The running daemon role could not be determined");
                    category_blocked(category,
                                     "Role-specific share and mount checks require a reliable running role");
                }
            } else {
                category_blocked(category,
                                 "Running daemon role check requires a valid configured role");
                category_blocked(category,
                                 "Role-specific share and mount checks require a valid configured role");
            }
        }
    } else {
        category_blocked(category,
                         "Daemon control socket check requires the SimpleServe client and daemon");
        if (role_valid)
            category_blocked(category,
                             "Running daemon role check requires a working control socket");
    }

    if (access(verifier, R_OK) != 0) {
        category_unknown(category,
                         "The SimpleServe system verifier is missing");
        append_text(category->details, sizeof(category->details),
                    "          expected: %s\n", verifier);
        category_blocked(category,
                         "Full SimpleServe system verification requires the verifier");
    } else if (client_found && daemon_found &&
               role_valid &&
               simpleserve_status_ok) {
        const char *arguments[] = {"sh", verifier, daemon, client, NULL};
        const EnvPair environment[] = {
            {"SIMPLESUITE_NETWORK_ROLE", role},
            {NULL, NULL}
        };
        int result = run_capture(arguments, environment, WEBSITE_TIMEOUT_MS,
                                 output, sizeof(output));

        if (result == -2) {
            category_unknown(category,
                             "Full SimpleServe system verification timed out");
        } else if (result != 0) {
            category_down(category,
                          "The SimpleServe system installation is incomplete or stale");
            append_text(category->details, sizeof(category->details),
                        "\nSystem-verifier output:\n%s%s", output,
                        output[0] && output[strlen(output) - 1] != '\n' ? "\n" : "");
        } else {
            category_ok(category,
                        "Installed service files and runtime prerequisites match the %s role",
                        role);
        }
    } else {
        category_blocked(category,
                         "Full SimpleServe system verification requires installed binaries, a valid role, and a working control socket");
    }

    if (daemon_found) {
        check_managed_service(category, "SimpleServe", "simpleserved.service",
                              "simpleserved", "simpleserved", "simpleserved",
                              "org.simplesuite.simpleserved");
    } else {
        category_blocked(category,
                         "Managed service health check requires the SimpleServe daemon");
    }

    if (category->state == STATE_CHECKING) {
        category->state = STATE_OK;
        if (simpleserve_mode == MODE_SERVER &&
            simpleserve_evidence.local_shares > 0) {
            int active_shares = simpleserve_evidence.local_shares -
                                simpleserve_evidence.unavailable_shares;

            (void)snprintf(category->summary, sizeof(category->summary),
                           "server role; %d NFS/SMB share%s active; service ready",
                           active_shares, active_shares == 1 ? "" : "s");
        } else if (simpleserve_mode == MODE_CLIENT &&
                   simpleserve_evidence.mounted > 0) {
            (void)snprintf(category->summary, sizeof(category->summary),
                           "client role; %d managed NFS mount%s active",
                           simpleserve_evidence.mounted,
                           simpleserve_evidence.mounted == 1 ? "" : "s");
        } else if (simpleserve_mode == MODE_CLIENT) {
            copy_string(category->summary, sizeof(category->summary),
                        "client role; ready to discover and mount NFS shares");
        } else {
            (void)snprintf(category->summary, sizeof(category->summary),
                           "%s role; daemon and service are ready",
                           role[0] ? role : "configured");
        }
    } else {
        set_simpleserve_fix(category, role);
    }
}

static void set_openssh_fix(Category *category)
{
    append_text(category->fix, sizeof(category->fix),
                "Install both OpenSSH programs through Scriptorium's Trident package set:\n"
                "  cd ~/scriptorium && ./install.sh\n\n"
                "Then confirm that both programs are available:\n"
                "  command -v ssh\n"
                "  command -v sshd\n");
}

static void check_openssh(Category *category)
{
    static const char *const known_clients[] = {
        "/usr/bin/ssh",
        "/usr/local/bin/ssh",
        NULL
    };
    static const char *const known_daemons[] = {
        "/usr/sbin/sshd",
        "/usr/bin/sshd",
        "/usr/local/sbin/sshd",
        "/usr/local/bin/sshd",
        NULL
    };
    char client[PATH_MAX];
    char daemon[PATH_MAX];
    int client_found;
    int daemon_found;

    category_reset(category);
    client_found = find_program("SIMPLETRIDENT_SSH", "ssh", known_clients,
                                client, sizeof(client));
    daemon_found = find_program("SIMPLETRIDENT_SSHD", "sshd", known_daemons,
                                daemon, sizeof(daemon));

    if (client_found)
        category_ok(category, "OpenSSH client is installed at %s", client);
    else
        category_down(category, "The OpenSSH client is not installed");
    if (daemon_found)
        category_ok(category, "OpenSSH daemon is installed at %s", daemon);
    else
        category_down(category, "The OpenSSH daemon is not installed");

    if (category->state == STATE_CHECKING) {
        category->state = STATE_OK;
        copy_string(category->summary, sizeof(category->summary),
                    "client and daemon are installed");
    } else {
        set_openssh_fix(category);
    }
}

static int tailscale_ipv4(const char *text, char *address, size_t address_size)
{
    char copy[256];
    char *line;
    char *save = NULL;

    copy_string(copy, sizeof(copy), text);
    for (line = strtok_r(copy, "\n\r", &save); line;
         line = strtok_r(NULL, "\n\r", &save)) {
        struct in_addr parsed;
        uint32_t host_address;

        trim_whitespace(line);
        if (inet_pton(AF_INET, line, &parsed) != 1)
            continue;
        host_address = ntohl(parsed.s_addr);
        if (host_address >= 0x64400000U && host_address <= 0x647fffffU) {
            copy_string(address, address_size, line);
            return 1;
        }
    }
    return 0;
}

static int json_string_field(const char *json, const char *field,
                             char *value, size_t value_size)
{
    char wanted[128];
    const char *cursor;
    size_t used = 0;

    if (snprintf(wanted, sizeof(wanted), "\"%s\"", field) >=
        (int)sizeof(wanted))
        return 0;
    cursor = strstr(json, wanted);
    if (!cursor)
        return 0;
    cursor += strlen(wanted);
    while (*cursor == ' ' || *cursor == '\t' || *cursor == '\n' ||
           *cursor == '\r')
        cursor++;
    if (*cursor++ != ':')
        return 0;
    while (*cursor == ' ' || *cursor == '\t' || *cursor == '\n' ||
           *cursor == '\r')
        cursor++;
    if (*cursor++ != '"')
        return 0;
    while (*cursor && *cursor != '"') {
        if (*cursor == '\\')
            return 0;
        if (used + 1 >= value_size)
            return 0;
        value[used++] = *cursor++;
    }
    if (*cursor != '"')
        return 0;
    value[used] = '\0';
    return 1;
}

static void check_tailscale_service(Category *category, const char *binary)
{
    if (strcmp(service_manager, "launchd") == 0) {
        if (strstr(binary, "/Applications/Tailscale.app/"))
            category_ok(category,
                        "The Tailscale app backend answered the local CLI");
        else
            category_ok(category,
                        "The Homebrew Tailscale backend answered the local CLI");
        return;
    }
    check_managed_service(category, "Tailscale", "tailscaled.service",
                          "tailscale", "tailscaled", "tailscaled", "");
}

static void set_tailscale_fix(Category *category, int transport_ready)
{
    if (transport_ready) {
        append_text(category->fix, sizeof(category->fix),
                    "Tailscale itself is connected. Reconcile the SimpleServe bridge:\n"
                    "  simpleserve refresh\n"
                    "  simpleserve status\n\n"
                    "If a remembered NFS fallback is unreachable, verify the publishing host there:\n"
                    "  setup-server --verify-only --no-public-check\n"
                    "Then explicitly retry the remembered mount on this client:\n"
                    "  simpleserve mount SERVER:SHARE --remember\n\n"
                    "If the SimpleServe control socket is unavailable, repair its role and service:\n"
                    "  cd ~/scriptorium && ./install.sh\n");
    } else {
        append_text(category->fix, sizeof(category->fix),
                    "Reinstall or reconnect the Trident's encrypted transport:\n"
                    "  ~/scriptorium/scripts/setup-tailscale.sh\n\n"
                    "If Tailscale asks for authentication, open the login URL it prints.\n"
                    "Do not put an auth key on a command line. For unattended repair, use\n"
                    "TAILSCALE_AUTH_KEY_FILE as described in ~/scriptorium/README.md.\n\n"
                    "After Tailscale is connected, refresh the bridge:\n"
                    "  simpleserve refresh\n"
                    "  simpleserve status\n");
    }
    if (strcmp(service_manager, "systemd") == 0) {
        if (transport_ready) {
            append_text(category->fix, sizeof(category->fix),
                        "\nInspect bridge errors with:\n"
                        "  systemctl status simpleserved.service --no-pager\n"
                        "  journalctl -u simpleserved.service -n 50 --no-pager\n");
        } else {
            append_text(category->fix, sizeof(category->fix),
                        "\nInspect daemon errors with:\n"
                        "  systemctl status tailscaled.service --no-pager\n"
                        "  journalctl -u tailscaled.service -n 50 --no-pager\n");
        }
    }
}

static void check_tailscale(Category *category)
{
    static const char *const known_paths[] = {
        "/usr/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/sbin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        NULL
    };
    char binary[PATH_MAX];
    char output[OUTPUT_SIZE];
    char address[64] = "";
    char backend_state[64] = "";
    int binary_found;
    int connected = 0;
    int backend_running = 0;
    int transport_ready;

    category_reset(category);
    binary_found = find_program("SIMPLETRIDENT_TAILSCALE", "tailscale",
                                known_paths, binary, sizeof(binary));
    if (!binary_found) {
        category_down(category, "The Tailscale client is not installed");
        category_blocked(category,
                         "Backend and tailnet address checks require the Tailscale client");
        category_blocked(category,
                         "Managed service health check requires the Tailscale client");
    } else {
        const char *status_arguments[] = {binary, "status", "--json", NULL};
        const EnvPair environment[] = {
            {"TAILSCALE_BE_CLI", "1"},
            {NULL, NULL}
        };
        int result;

        category_ok(category, "Tailscale client is installed at %s", binary);
        result = run_capture(status_arguments, environment, COMMAND_TIMEOUT_MS,
                             output, sizeof(output));
        if (result == -2) {
            category_down(category,
                          "Tailscale did not answer within %d seconds",
                          COMMAND_TIMEOUT_MS / 1000);
        } else if (result != 0) {
            category_down(category, "The Tailscale backend is unavailable");
            service_failure_detail(category, "tailscale status --json", output);
        } else if (!json_string_field(output, "BackendState", backend_state,
                                      sizeof(backend_state))) {
            category_unknown(category,
                             "Tailscale returned an unreadable backend state");
        } else if (strcmp(backend_state, "Running") != 0) {
            if (strcmp(backend_state, "NeedsLogin") == 0)
                category_down(category, "Tailscale is not authenticated");
            else
                category_down(category, "Tailscale backend state is %s",
                              backend_state);
        } else {
            backend_running = 1;
            category_ok(category, "Tailscale backend state is Running");
        }

        if (backend_running) {
            const char *ip_arguments[] = {binary, "ip", "-4", NULL};

            result = run_capture(ip_arguments, environment, COMMAND_TIMEOUT_MS,
                                 output, sizeof(output));
            if (result == -2) {
                category_down(category,
                              "Tailscale address lookup timed out after %d seconds",
                              COMMAND_TIMEOUT_MS / 1000);
            } else if (result != 0) {
                char clean[512];
                copy_string(clean, sizeof(clean), output);
                one_line(clean);
                if (strstr(clean, "login") || strstr(clean, "Login") ||
                    strstr(clean, "auth"))
                    category_down(category, "Tailscale is not authenticated");
                else
                    category_down(category, "Tailscale is not connected");
                service_failure_detail(category, "tailscale ip -4", output);
            } else if (!tailscale_ipv4(output, address, sizeof(address))) {
                category_down(category,
                              "Tailscale did not report a valid 100.64.0.0/10 address");
                service_failure_detail(category, "tailscale ip -4", output);
            } else {
                connected = 1;
                category_ok(category, "Tailnet address is %s", address);
            }
        } else {
            category_blocked(category,
                             "Tailnet address check requires a running Tailscale backend");
        }
        check_tailscale_service(category, binary);
    }

    transport_ready = connected && category->state == STATE_CHECKING;

    if (!connected) {
        category_blocked(category,
                         "SimpleServe bridge check requires a usable tailnet connection");
    } else if (!simpleserve_status_ok) {
        category_set_state(category, STATE_UNKNOWN,
                           "The SimpleServe-to-Tailscale bridge could not be verified");
        category_blocked(category,
                         "SimpleServe bridge check requires a working SimpleServe control socket");
    } else if (!strstr(simpleserve_status, "Tailscale: active (")) {
        category_partial(category,
                         "SimpleServe does not report an active Tailscale bridge");
    } else if (!strstr(simpleserve_status, address)) {
        category_partial(category,
                         "SimpleServe reports a different Tailscale address");
    } else {
        category_ok(category,
                    "SimpleServe reports the Tailscale transport as active");
        if (simpleserve_mode == MODE_CLIENT) {
            if (simpleserve_evidence.remembered == 0) {
                category_ok(category,
                            "The client is ready to learn a Tailscale route when an NFS share is remembered");
            } else if (simpleserve_evidence.tailscale_nfs_reported <
                       simpleserve_evidence.remembered) {
                category_unknown(category,
                                 "Tailscale NFS readiness is missing for %d remembered mount%s",
                                 simpleserve_evidence.remembered -
                                     simpleserve_evidence.tailscale_nfs_reported,
                                 simpleserve_evidence.remembered -
                                     simpleserve_evidence.tailscale_nfs_reported == 1 ?
                                     "" : "s");
            } else if (simpleserve_evidence.tailscale_nfs_ready ==
                       simpleserve_evidence.remembered) {
                category_ok(category,
                            "%d remembered NFS mount%s %s reachable over Tailscale",
                            simpleserve_evidence.remembered,
                            simpleserve_evidence.remembered == 1 ? "" : "s",
                            simpleserve_evidence.remembered == 1 ? "is" : "are");
            } else if (simpleserve_evidence.tailscale_nfs_ready == 0) {
                category_down(category,
                              "No remembered NFS mount is reachable over Tailscale");
            } else {
                category_partial(category,
                                 "%d of %d remembered NFS mounts are reachable over Tailscale",
                                 simpleserve_evidence.tailscale_nfs_ready,
                                 simpleserve_evidence.remembered);
            }
        } else if (simpleserve_mode == MODE_SERVER) {
            category_ok(category,
                        "The active bridge makes server NFS and SMB shares available to tailnet clients");
        }
    }

    if (category->state == STATE_CHECKING) {
        category->state = STATE_OK;
        if (simpleserve_mode == MODE_CLIENT) {
            if (simpleserve_evidence.remembered > 0) {
                (void)snprintf(category->summary, sizeof(category->summary),
                               "connected at %s; %d NFS fallback%s ready",
                               address, simpleserve_evidence.remembered,
                               simpleserve_evidence.remembered == 1 ? "" : "s");
            } else {
                (void)snprintf(category->summary, sizeof(category->summary),
                               "connected at %s; ready for future NFS mounts",
                               address);
            }
        } else if (simpleserve_mode == MODE_SERVER) {
            (void)snprintf(category->summary, sizeof(category->summary),
                           "connected at %s; NFS/SMB publishing bridge is active",
                           address);
        } else {
            (void)snprintf(category->summary, sizeof(category->summary),
                           "connected at %s; SimpleServe bridge is active", address);
        }
    } else {
        set_tailscale_fix(category, transport_ready);
    }
}

static void set_website_fix(Category *category, const char *website)
{
    append_text(category->fix, sizeof(category->fix),
                "Reconcile the checkout, Caddy configuration, and local services:\n"
                "  setup-server\n\n"
                "Run a read-only local verification afterward:\n"
                "  setup-server --verify-only --no-public-check\n\n"
                "The lower-level local check is:\n"
                "  CHECK_BLOG_TIMER=0 CHECK_CLOUDFLARED=0 %s/tools/check_server.sh\n",
                website);
    if (strcmp(service_manager, "systemd") == 0) {
        append_text(category->fix, sizeof(category->fix),
                    "\nInspect the two required services with:\n"
                    "  systemctl status caddy.service keelanwatlington-store.service --no-pager\n"
                    "  journalctl -u caddy.service -u keelanwatlington-store.service -n 50 --no-pager\n");
    }
}

static int extract_assignment(const char *text, const char *name,
                              char *value, size_t value_size)
{
    size_t name_length = strlen(name);

    for (const char *match = strstr(text, name); match;
         match = strstr(match + name_length, name)) {
        const char *cursor;
        size_t used = 0;

        if (match != text && match[-1] != ' ' && match[-1] != '\t' &&
            match[-1] != '\'' && match[-1] != '"')
            continue;
        cursor = match + name_length;
        if (*cursor++ != '=')
            continue;
        while (*cursor && *cursor != ' ' && *cursor != '\t' &&
               *cursor != '\n' && *cursor != '\r' && *cursor != '\'' &&
               *cursor != '"') {
            if (used + 1 >= value_size)
                return 0;
            value[used++] = *cursor++;
        }
        value[used] = '\0';
        return used > 0;
    }
    return 0;
}

static void discover_site_address(char *address, size_t address_size)
{
    const char *override = getenv("SIMPLETRIDENT_SITE_ADDRESS");
    char output[4096];

    if (override && override[0]) {
        copy_string(address, address_size, override);
        return;
    }
    address[0] = '\0';
    if (strcmp(service_manager, "systemd") == 0) {
        const char *arguments[] = {
            "systemctl", "show", "caddy.service", "--property=Environment",
            "--value", NULL
        };
        if (run_capture(arguments, NULL, COMMAND_TIMEOUT_MS,
                        output, sizeof(output)) == 0)
            (void)extract_assignment(output, "SITE_ADDRESS", address,
                                     address_size);
    } else {
        char launcher[PATH_MAX];

        system_path("/usr/local/libexec/keelanwatlington/caddy", launcher,
                    sizeof(launcher));
        if (read_small_file(launcher, output, sizeof(output)))
            (void)extract_assignment(output, "SITE_ADDRESS", address,
                                     address_size);
    }
    if (address[0] != ':' || strpbrk(address, " \t\n\r"))
        copy_string(address, address_size, ":8080");
}

static int run_website_health(const char *checker, const char *origin,
                              int supporting_services, char *output,
                              size_t output_size)
{
    const char *arguments[] = {"sh", checker, NULL};
    const EnvPair environment[] = {
        {"CHECK_BLOG_TIMER", supporting_services ? "1" : "0"},
        {"CHECK_CLOUDFLARED", supporting_services ? "1" : "0"},
        {"CADDY_CHECK_ORIGIN", origin},
        {"WEBSITE_SERVICE_MANAGER", service_manager},
        {NULL, NULL}
    };

    return run_capture(arguments, environment, WEBSITE_TIMEOUT_MS,
                       output, output_size);
}

static void check_website(Category *category)
{
    static const char *const known_caddy[] = {
        "/usr/bin/caddy", "/usr/local/bin/caddy", "/opt/homebrew/bin/caddy",
        NULL
    };
    char website[PATH_MAX];
    char checker[PATH_MAX];
    char source_config[PATH_MAX];
    char installed_config[PATH_MAX];
    char store_environment[PATH_MAX];
    char caddy[PATH_MAX];
    char origin_buffer[256];
    char site_address_buffer[128];
    char output[OUTPUT_SIZE];
    const char *website_override = getenv("SIMPLETRIDENT_WEBSITE_DIR");
    const char *checker_override = getenv("SIMPLETRIDENT_WEBSITE_CHECK");
    const char *config_override = getenv("SIMPLETRIDENT_CADDYFILE");
    const char *store_environment_override =
        getenv("SIMPLETRIDENT_STORE_ENV");
    const char *origin = getenv("SIMPLETRIDENT_WEBSITE_ORIGIN");
    const char *site_address;
    struct stat status;
    int caddy_found;
    int website_present;
    int source_config_present;
    int installed_config_present;
    int checker_present;
    int store_environment_path_ready;

    category_reset(category);
    if (simpleserve_mode == MODE_CLIENT) {
        category_ok(category,
                    "Client mode does not require Caddy, the website checkout, or server web services");
        category->state = STATE_OK;
        copy_string(category->summary, sizeof(category->summary),
                    "server-only website origin is not required in client mode");
        return;
    }
    if (simpleserve_mode == MODE_UNKNOWN) {
        category_unknown(category,
                         "The website requirement cannot be determined until the SimpleServe mode is known");
        category_blocked(category,
                         "Caddy and website checks require a reliable SimpleServe mode");
        append_text(category->fix, sizeof(category->fix),
                    "Repair the SimpleServe installation and explicit role first:\n"
                    "  cd ~/scriptorium && ./install.sh\n\n"
                    "Then confirm whether this machine is a client or server:\n"
                    "  simpleserve status\n");
        return;
    }
    if (website_override && website_override[0])
        copy_string(website, sizeof(website), website_override);
    else if (!join_path(website, sizeof(website), home_dir, "/website"))
        copy_string(website, sizeof(website), "(home path is too long)");
    if (checker_override && checker_override[0])
        copy_string(checker, sizeof(checker), checker_override);
    else if (!join_path(checker, sizeof(checker), website,
                        "/tools/check_server.sh"))
        checker[0] = '\0';
    if (!join_path(source_config, sizeof(source_config), website,
                   "/tools/Caddyfile.production"))
        source_config[0] = '\0';
    if (config_override && config_override[0])
        copy_string(installed_config, sizeof(installed_config), config_override);
    else
        system_path("/etc/caddy/Caddyfile", installed_config,
                    sizeof(installed_config));
    if (store_environment_override && store_environment_override[0]) {
        copy_string(store_environment, sizeof(store_environment),
                    store_environment_override);
        store_environment_path_ready = 1;
    } else {
        store_environment_path_ready = join_path(
            store_environment, sizeof(store_environment), home_dir,
            "/.config/keelanwatlington/store.env");
    }
    if (!origin || !origin[0])
        origin = origin_buffer;
    discover_site_address(site_address_buffer, sizeof(site_address_buffer));
    site_address = site_address_buffer;
    if (origin == origin_buffer) {
        if (snprintf(origin_buffer, sizeof(origin_buffer),
                     "http://127.0.0.1%s", site_address) >=
            (int)sizeof(origin_buffer))
            copy_string(origin_buffer, sizeof(origin_buffer),
                        "http://127.0.0.1:8080");
    }

    caddy_found = find_program("SIMPLETRIDENT_CADDY", "caddy", known_caddy,
                               caddy, sizeof(caddy));
    if (!caddy_found)
        category_down(category, "Caddy is not installed");
    else
        category_ok(category, "Caddy is installed at %s", caddy);

    website_present = stat(website, &status) == 0 && S_ISDIR(status.st_mode);
    if (!website_present) {
        category_down(category, "The website checkout is not installed");
        append_text(category->details, sizeof(category->details),
                    "          expected: %s\n", website);
    } else {
        category_ok(category, "Website checkout is present at %s", website);
    }
    category_ok(category, "Local Caddy origin is %s", origin);

    source_config_present = website_present && access(source_config, R_OK) == 0;
    installed_config_present = access(installed_config, R_OK) == 0;
    if (!caddy_found) {
        category_blocked(category,
                         "Installed Caddy config validation requires Caddy");
    } else if (!installed_config_present) {
        category_down(category,
                      "The installed Caddy config is missing or unreadable");
        append_text(category->details, sizeof(category->details),
                    "          expected: %s\n", installed_config);
        category_blocked(category,
                         "Caddy config validation requires a readable installed config");
    } else {
        const char *arguments[] = {caddy, "validate", "--config",
                                   installed_config, NULL};
        const EnvPair environment[] = {
            {"SITE_ROOT", website},
            {"SITE_ADDRESS", site_address},
            {NULL, NULL}
        };
        int result = run_capture(arguments, environment, COMMAND_TIMEOUT_MS,
                                 output, sizeof(output));

        if (result == -2) {
            category_unknown(category, "Caddy config validation timed out");
        } else if (result != 0) {
            category_partial(category, "The installed Caddy config is invalid");
            service_failure_detail(category, "caddy validate", output);
        } else {
            category_ok(category, "Installed Caddy config validates successfully");
        }
    }

    if (!website_present) {
        category_blocked(category,
                         "Production Caddy source config check requires the website checkout");
    } else if (!source_config_present) {
        category_partial(category,
                         "The production Caddy source config is missing");
    } else {
        category_ok(category, "Production Caddy source config is present");
    }

    if (!installed_config_present) {
        category_blocked(category,
                         "Installed Caddy config comparison requires a readable installed config");
    } else if (!source_config_present) {
        category_blocked(category,
                         "Installed Caddy config comparison requires the production source config");
    } else if (!files_equal(source_config, installed_config)) {
        category_partial(category,
                         "The installed Caddy config is stale relative to the website checkout");
    } else {
        category_ok(category,
                    "Installed Caddy config matches the website checkout");
    }

    checker_present = website_present && access(checker, R_OK) == 0;
    if (!website_present) {
        category_blocked(category,
                         "Website health checker check requires the website checkout");
    } else if (!checker_present) {
        category_unknown(category, "The website health checker is missing");
        append_text(category->details, sizeof(category->details),
                    "          expected: %s\n", checker);
        category_blocked(category,
                         "Local website health check requires the website health checker");
    }

    if (!caddy_found) {
        category_blocked(category,
                         "Local website health check requires Caddy");
    } else if (!website_present) {
        category_blocked(category,
                         "Local website health check requires the website checkout");
    } else if (!installed_config_present) {
        category_blocked(category,
                         "Local website health check requires a readable installed Caddy config");
    } else if (!checker_present) {
        /* The missing checker and blocked health check were recorded above. */
    } else {
        int result = run_website_health(checker, origin, 1,
                                        output, sizeof(output));

        if (result == 0) {
            int recovery_mail = store_environment_path_ready ?
                store_recovery_mail_status(store_environment) : -1;

            category_ok(category,
                        "Caddy, the local site, private-path rules, store, blog sync, and Cloudflare tunnel passed");
            if (recovery_mail > 0) {
                category_ok(category,
                            "Local purchase fulfillment and recovery email are configured");
            } else if (recovery_mail == 0) {
                category_partial(category,
                                 "Purchase-recovery email is not configured");
                category_ok(category,
                            "Paid-order recording and signed browser downloads remain available");
                append_text(category->fix, sizeof(category->fix),
                            "Configure the local fulfillment worker's documented STORE_SMTP_* and STORE_EMAIL_* settings, then reconcile it:\n"
                            "  less %s/README.md\n"
                            "  setup-server\n\n",
                            website);
            } else {
                category_unknown(category,
                                 "Purchase-recovery email configuration could not be read");
                append_text(category->details, sizeof(category->details),
                            "          expected protected configuration: %s\n",
                            store_environment);
                append_text(category->fix, sizeof(category->fix),
                            "Check ownership and mode 0600 on the protected store configuration:\n"
                            "  ls -l %s\n\n",
                            store_environment);
            }
            if (output[0]) {
                char clean[512];
                copy_string(clean, sizeof(clean), output);
                one_line(clean);
                append_text(category->details, sizeof(category->details),
                            "          %s\n", clean);
            }
        } else {
            char full_output[OUTPUT_SIZE];
            int core_result;

            copy_string(full_output, sizeof(full_output), output);
            core_result = run_website_health(checker, origin, 0,
                                             output, sizeof(output));
            if (core_result == 0) {
                if (result == -2) {
                    category_unknown(category,
                                     "Supporting website service verification timed out");
                } else {
                    category_partial(category,
                                     "The local web origin works, but a supporting website service failed");
                }
                append_text(category->details, sizeof(category->details),
                            "\nFull server health-check output:\n%s%s",
                            full_output,
                            full_output[0] &&
                            full_output[strlen(full_output) - 1] != '\n' ? "\n" : "");
                category_ok(category,
                            "Caddy, private-path rules, and store health still pass locally");
            } else if (core_result == -2) {
                category_down(category,
                              "The local website health check timed out after %d seconds",
                              WEBSITE_TIMEOUT_MS / 1000);
            } else {
                category_down(category,
                              "The local Caddy website health check failed");
                append_text(category->details, sizeof(category->details),
                            "\nLocal health-check output:\n%s%s", output,
                            output[0] && output[strlen(output) - 1] != '\n' ? "\n" : "");
            }
        }
    }

    if (category->state == STATE_CHECKING) {
        category->state = STATE_OK;
        copy_string(category->summary, sizeof(category->summary),
                    "Caddy, fulfillment mail, blog sync, and tunnel are healthy");
    } else {
        set_website_fix(category, website);
    }
}

static const char *state_label(enum check_state state)
{
    switch (state) {
    case STATE_OK: return "OK";
    case STATE_PARTIAL: return "PARTIAL";
    case STATE_DOWN: return "DOWN";
    case STATE_UNKNOWN: return "UNKNOWN";
    case STATE_CHECKING: return "...";
    }
    return "?";
}

static const char *mode_label(enum simpleserve_mode mode)
{
    switch (mode) {
    case MODE_SERVER: return "SERVER";
    case MODE_CLIENT: return "CLIENT";
    case MODE_UNKNOWN: return "UNKNOWN";
    }
    return "UNKNOWN";
}

static int category_color(const Category *category)
{
    if (!has_colors())
        return 0;
    if (category->state == STATE_OK)
        return COLOR_PAIR(1) | A_BOLD;
    if (category->state == STATE_DOWN)
        return COLOR_PAIR(2) | A_BOLD;
    return COLOR_PAIR(3) | A_BOLD;
}

static void draw_clipped(int row, int column, int attributes,
                         const char *text, int maximum)
{
    int height;
    int width;

    getmaxyx(stdscr, height, width);
    if (row < 0 || row >= height || column < 0 || column >= width || maximum <= 0)
        return;
    if (maximum > width - column)
        maximum = width - column;
    if (attributes)
        attron(attributes);
    mvaddnstr(row, column, text, maximum);
    if (attributes)
        attroff(attributes);
}

static void draw_dashboard(void)
{
    int height;
    int width;

    getmaxyx(stdscr, height, width);
    erase();
    if (height < 20 || width < 48) {
        draw_clipped(1, 2, A_BOLD, "simpletrident", width - 4);
        draw_clipped(3, 2, 0,
                     "Terminal is too small (need at least 48 x 20).",
                     width - 4);
        draw_clipped(height - 1, 1, A_REVERSE, " Q: quit ", width - 2);
        refresh();
        return;
    }

    draw_clipped(1, 2, A_BOLD, "simpletrident", width - 4);
    draw_clipped(2, 2, 0, "-------------", width - 4);
    draw_clipped(3, 2, A_DIM,
                 "Keelan's Networking Trident installation check",
                 width - 4);
    {
        char mode[32];

        (void)snprintf(mode, sizeof(mode), "Mode: %s",
                       mode_label(simpleserve_mode));
        draw_clipped(4, 2, A_BOLD, mode, width - 4);
    }

    for (int index = 0; index < visible_category_count(); index++) {
        Category *category = &categories[index];
        int row = 6 + index * 3;
        char heading[256];
        int selection = index == selected_category ? A_REVERSE : 0;

        (void)snprintf(heading, sizeof(heading), "%c [%-7s]  %s / %s",
                       index == selected_category ? '>' : ' ',
                       state_label(category->state), category->name,
                       category->subtitle);
        draw_clipped(row, 2, selection | category_color(category),
                     heading, width - 4);
        draw_clipped(row + 1, 7, selection,
                     category->summary, width - 9);
    }

    if (last_checked[0]) {
        char checked[128];
        (void)snprintf(checked, sizeof(checked), "Last checked: %s", last_checked);
        draw_clipped(height - 3, 2, A_DIM, checked, width - 4);
    }
    draw_clipped(height - 1, 0, A_REVERSE, footer, width);
    refresh();
}

static void emit_detail_line(const char *line, size_t length, int attributes,
                             int content_top, int content_bottom,
                             int *virtual_line)
{
    int screen_row = content_top + *virtual_line - detail_scroll;
    int width = getmaxx(stdscr) - 4;

    if (screen_row >= content_top && screen_row <= content_bottom) {
        char buffer[1024];
        size_t copied = length < sizeof(buffer) - 1 ? length : sizeof(buffer) - 1;
        memcpy(buffer, line, copied);
        buffer[copied] = '\0';
        draw_clipped(screen_row, 2, attributes, buffer, width);
    }
    (*virtual_line)++;
}

static void emit_wrapped(const char *text, int attributes, int content_top,
                         int content_bottom, int *virtual_line)
{
    int width = getmaxx(stdscr) - 4;
    const char *cursor = text;

    if (width < 1)
        width = 1;
    while (*cursor) {
        const char *newline = strchr(cursor, '\n');
        size_t remaining = newline ? (size_t)(newline - cursor) : strlen(cursor);

        if (remaining == 0) {
            emit_detail_line("", 0, attributes, content_top, content_bottom,
                             virtual_line);
        }
        while (remaining > 0) {
            size_t take = remaining < (size_t)width ? remaining : (size_t)width;
            if (take < remaining) {
                size_t split = take;
                while (split > 0 && cursor[split] != ' ' && cursor[split] != '\t')
                    split--;
                if (split > 0)
                    take = split;
            }
            emit_detail_line(cursor, take, attributes, content_top,
                             content_bottom, virtual_line);
            cursor += take;
            remaining -= take;
            while (remaining && (*cursor == ' ' || *cursor == '\t')) {
                cursor++;
                remaining--;
            }
        }
        if (!newline)
            break;
        cursor = newline + 1;
    }
}

static void draw_detail(void)
{
    Category *category = &categories[selected_category];
    int height;
    int width;
    int virtual_line = 0;
    int content_top = 5;
    int content_bottom;
    char heading[256];

    getmaxyx(stdscr, height, width);
    content_bottom = height - 3;
    erase();
    if (height < 10 || width < 36) {
        draw_clipped(1, 2, A_BOLD, "simpletrident", width - 4);
        draw_clipped(3, 2, 0, "Terminal is too small.", width - 4);
        draw_clipped(height - 1, 0, A_REVERSE,
                     " Esc/Enter: back   Q: quit ", width);
        refresh();
        return;
    }

    (void)snprintf(heading, sizeof(heading), "simpletrident / %s",
                   category->name);
    draw_clipped(1, 2, A_BOLD, heading, width - 4);
    draw_clipped(2, 2, 0, "----------------------------------------", width - 4);
    (void)snprintf(heading, sizeof(heading), "Status: %s - %s",
                   state_label(category->state), category->summary);
    draw_clipped(3, 2, category_color(category), heading, width - 4);

    emit_wrapped("Checks", A_BOLD | A_UNDERLINE, content_top, content_bottom,
                 &virtual_line);
    emit_wrapped(category->details[0] ? category->details : "No details available.\n",
                 0, content_top, content_bottom, &virtual_line);
    if (category->state != STATE_OK && category->state != STATE_CHECKING) {
        emit_wrapped("\nHow to fix", A_BOLD | A_UNDERLINE, content_top,
                     content_bottom, &virtual_line);
        emit_wrapped(category->fix, 0, content_top, content_bottom,
                     &virtual_line);
    }
    detail_line_count = virtual_line;

    if (detail_scroll > 0)
        draw_clipped(content_top, width - 12, A_REVERSE, " more above ", 12);
    if (detail_scroll + (content_bottom - content_top + 1) < detail_line_count)
        draw_clipped(content_bottom, width - 12, A_REVERSE, " more below ", 12);
    draw_clipped(height - 1, 0, A_REVERSE,
                 " Up/Down: scroll   Esc/Enter: back   R: recheck   Q: quit ",
                 width);
    refresh();
}

static void draw(void)
{
    if (!ui_active)
        return;
    if (detail_mode)
        draw_detail();
    else
        draw_dashboard();
}

static void refresh_checks(void)
{
    time_t now;
    struct tm local;

    for (int index = 0; index < CATEGORY_COUNT; index++)
        category_reset(&categories[index]);
    simpleserve_mode = MODE_UNKNOWN;
    copy_string(footer, sizeof(footer), "Checking SimpleServe...");
    detail_mode = 0;
    detail_scroll = 0;
    draw();
    check_simpleserve(&categories[0]);

    copy_string(footer, sizeof(footer), "Checking Tailscale...");
    draw();
    check_tailscale(&categories[1]);

    copy_string(footer, sizeof(footer), "Checking OpenSSH...");
    draw();
    check_openssh(&categories[2]);

    if (simpleserve_mode != MODE_CLIENT) {
        copy_string(footer, sizeof(footer),
                    "Checking the local Caddy website...");
        draw();
        check_website(&categories[3]);
    }

    selected_category = 0;
    for (int index = 0; index < visible_category_count(); index++) {
        if (categories[index].state != STATE_OK) {
            selected_category = index;
            break;
        }
    }
    now = time(NULL);
    if (localtime_r(&now, &local))
        (void)strftime(last_checked, sizeof(last_checked), "%Y-%m-%d %H:%M:%S",
                       &local);
    copy_string(footer, sizeof(footer),
                "Up/Down: select   Enter/D: details & fixes   R: recheck   Q: quit");
    draw();
}

static void print_indented(const char *text, const char *indent)
{
    const char *cursor = text;

    while (*cursor) {
        const char *newline = strchr(cursor, '\n');
        size_t length = newline ? (size_t)(newline - cursor) : strlen(cursor);
        printf("%s%.*s\n", indent, (int)length, cursor);
        if (!newline)
            break;
        cursor = newline + 1;
    }
}

static int print_plain(void)
{
    int unhealthy = 0;

    puts("simpletrident");
    puts("=============");
    printf("Mode: %s\n", mode_label(simpleserve_mode));
    for (int index = 0; index < visible_category_count(); index++) {
        Category *category = &categories[index];

        printf("\n[%-7s] %s / %s\n", state_label(category->state), category->name,
               category->subtitle);
        printf("          %s\n", category->summary);
        if (category->state != STATE_OK) {
            unhealthy++;
            puts("\n  Details:");
            print_indented(category->details, "    ");
            if (category->fix[0]) {
                puts("\n  How to fix:");
                print_indented(category->fix, "    ");
            }
        }
    }
    return unhealthy ? 1 : 0;
}

static void usage(FILE *stream)
{
    fprintf(stream,
            "Usage: simpletrident [--check]\n\n"
            "Verify the Trident network programs and, in server mode, the "
            "local Caddy website.\n\n"
            "  --check   print all results without ncurses and return nonzero\n"
            "            when any Trident category is not OK\n"
            "  -h, --help  show this help\n");
}

int main(int argc, char **argv)
{
    int plain = 0;
    const char *home = getenv("HOME");

    if (!home || !home[0])
        home = ".";
    copy_string(home_dir, sizeof(home_dir), home);
    detect_service_manager();

    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], "--check") == 0) {
            plain = 1;
        } else if (strcmp(argv[index], "-h") == 0 ||
                   strcmp(argv[index], "--help") == 0) {
            usage(stdout);
            return 0;
        } else {
            fprintf(stderr, "simpletrident: unknown option: %s\n", argv[index]);
            usage(stderr);
            return 2;
        }
    }
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO))
        plain = 1;
    if (plain) {
        refresh_checks();
        return print_plain();
    }

    initscr();
    cbreak();
    noecho();
    keypad(stdscr, TRUE);
    curs_set(0);
    if (has_colors()) {
        start_color();
        use_default_colors();
        init_pair(1, COLOR_GREEN, -1);
        init_pair(2, COLOR_RED, -1);
        init_pair(3, COLOR_YELLOW, -1);
    }
    ui_active = 1;
    refresh_checks();

    for (;;) {
        int input = getch();

        if (input == 'q' || input == 'Q')
            break;
        if (input == KEY_RESIZE) {
            draw();
            continue;
        }
        if (input == 'r' || input == 'R') {
            refresh_checks();
            continue;
        }
        if (detail_mode) {
            int visible = getmaxy(stdscr) - 7;
            int maximum = detail_line_count > visible
                              ? detail_line_count - visible : 0;
            if (input == 27 || input == '\n' || input == '\r' ||
                input == KEY_ENTER || input == 'b' || input == 'B') {
                detail_mode = 0;
                detail_scroll = 0;
            } else if (input == KEY_DOWN || input == 'j') {
                if (detail_scroll < maximum)
                    detail_scroll++;
            } else if (input == KEY_UP || input == 'k') {
                if (detail_scroll > 0)
                    detail_scroll--;
            } else if (input == KEY_NPAGE) {
                detail_scroll += visible > 1 ? visible - 1 : 1;
                if (detail_scroll > maximum)
                    detail_scroll = maximum;
            } else if (input == KEY_PPAGE) {
                detail_scroll -= visible > 1 ? visible - 1 : 1;
                if (detail_scroll < 0)
                    detail_scroll = 0;
            } else if (input == KEY_HOME) {
                detail_scroll = 0;
            } else if (input == KEY_END) {
                detail_scroll = maximum;
            }
        } else if (input == KEY_DOWN || input == 'j' || input == '\t') {
            selected_category =
                (selected_category + 1) % visible_category_count();
        } else if (input == KEY_UP || input == 'k') {
            selected_category =
                (selected_category + visible_category_count() - 1) %
                visible_category_count();
        } else if (input == '\n' || input == '\r' || input == KEY_ENTER ||
                   input == 'd' || input == 'D') {
            detail_mode = 1;
            detail_scroll = 0;
        }
        draw();
    }

    ui_active = 0;
    endwin();
    return 0;
}
