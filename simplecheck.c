#define _POSIX_C_SOURCE 200809L
#include <ncurses.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <limits.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define REPO_COUNT 3
#define MAX_OUTPUT 65536
#define MAX_FILES 256
#define MAX_FILE_LINE 512
#define MAX_STATUS 256
#define LOCAL_COMMAND_TIMEOUT_MS 10000
#define COMMAND_TIMEOUT_MS 45000
#define UI_POLL_MS 25
#define TERMINATE_GRACE_MS 20
#define ESCAPE_DELAY_MS 25
#define FOOTER_NOTICE_MS 1500

#define RUN_FAILED 0
#define RUN_OK 1
#define RUN_CANCELLED -1

typedef struct {
    const char *name;
    char path[PATH_MAX];
    char branch[256];
    char files[MAX_FILES][MAX_FILE_LINE];
    int file_count;
    int exists;
    int is_repo;
    int dirty;
    int ahead;
    int behind;
    int upstream_ok;
    int push_ok;
    char result[MAX_STATUS];
    char last_action[MAX_STATUS];
} Repo;

typedef struct {
    pid_t pid;
    int fd;
    char *out;
    size_t out_sz;
    size_t used;
    int result;
    int child_active;
    int pipe_open;
    int truncated;
    int64_t deadline_ms;
} CaptureJob;

static Repo repos[REPO_COUNT];
static int button_y, button_x, button_w;
static int scroll_offset;
static int footer_notice_active;
static struct timespec footer_notice_deadline;
static char footer[MAX_STATUS] = "P: push   L: pull   C: check remotes   R: refresh   Q: quit";
static pid_t *deferred_children;
static size_t deferred_child_count;
static size_t deferred_child_capacity;

static void draw(void);

static void set_footer(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(footer, sizeof(footer), fmt, ap);
    va_end(ap);
}

static int64_t monotonic_ms(void)
{
    struct timespec now;

    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
        return 0;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static void reap_deferred_children(void)
{
    size_t out = 0;

    for (size_t i = 0; i < deferred_child_count; i++) {
        pid_t waited;

        do {
            waited = waitpid(deferred_children[i], NULL, WNOHANG);
        } while (waited < 0 && errno == EINTR);
        if (waited == 0)
            deferred_children[out++] = deferred_children[i];
    }
    deferred_child_count = out;
}

static void defer_child_reap(pid_t pid)
{
    pid_t *grown;
    size_t next;

    if (pid <= 0)
        return;
    reap_deferred_children();
    if (deferred_child_count == deferred_child_capacity) {
        next = deferred_child_capacity ? deferred_child_capacity * 2 : 8;
        grown = realloc(deferred_children, next * sizeof(*grown));
        if (!grown)
            return;
        deferred_children = grown;
        deferred_child_capacity = next;
    }
    deferred_children[deferred_child_count++] = pid;
}

static int reap_child_until(pid_t pid, int64_t deadline_ms)
{
    for (;;) {
        pid_t waited;

        do {
            waited = waitpid(pid, NULL, WNOHANG);
        } while (waited < 0 && errno == EINTR);
        if (waited == pid || (waited < 0 && errno == ECHILD))
            return 1;
        if (waited < 0 || monotonic_ms() >= deadline_ms)
            return 0;
        (void)poll(NULL, 0, 1);
    }
}

/* Cancellation must not inherit a child process's shutdown latency. Give Git
 * a very small graceful window, then kill the whole command group and defer a
 * stubborn reap instead of blocking the curses loop. */
static void stop_child(pid_t pid)
{
    int64_t deadline;

    if (pid <= 0)
        return;
    if (kill(-pid, SIGTERM) != 0)
        (void)kill(pid, SIGTERM);
    deadline = monotonic_ms() + TERMINATE_GRACE_MS;
    if (reap_child_until(pid, deadline))
        return;

    if (kill(-pid, SIGKILL) != 0)
        (void)kill(pid, SIGKILL);
    deadline = monotonic_ms() + TERMINATE_GRACE_MS;
    if (!reap_child_until(pid, deadline))
        defer_child_reap(pid);
}

static void capture_job_init(CaptureJob *job, char *out, size_t out_sz)
{
    memset(job, 0, sizeof(*job));
    job->pid = -1;
    job->fd = -1;
    job->out = out;
    job->out_sz = out_sz;
    job->result = -1;
    if (out_sz)
        out[0] = '\0';
}

static int capture_job_start(CaptureJob *job, const char *cwd,
                             char *const argv[], char *out, size_t out_sz,
                             int timeout_ms)
{
    int pipefd[2];
    pid_t pid;

    capture_job_init(job, out, out_sz);
    if (pipe(pipefd) < 0)
        return 0;

    pid = fork();
    if (pid < 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        return 0;
    }
    if (pid == 0) {
        int nullfd;

        (void)setpgid(0, 0);
        if (cwd && chdir(cwd) < 0)
            _exit(126);
        /* Close the read side first: it may occupy a standard descriptor when
         * SimpleCheck was launched with that descriptor closed. */
        close(pipefd[0]);
        nullfd = open("/dev/null", O_RDONLY);
        if (nullfd < 0 || dup2(nullfd, STDIN_FILENO) < 0)
            _exit(126);
        if (nullfd > STDERR_FILENO)
            close(nullfd);

        if (dup2(pipefd[1], STDOUT_FILENO) < 0 ||
            dup2(pipefd[1], STDERR_FILENO) < 0)
            _exit(126);
        if (pipefd[1] > STDERR_FILENO)
            close(pipefd[1]);
        setenv("GIT_TERMINAL_PROMPT", "0", 1);
        setenv("GCM_INTERACTIVE", "Never", 1);
        execvp(argv[0], argv);
        _exit(127);
    }

    (void)setpgid(pid, pid);
    close(pipefd[1]);
    int flags = fcntl(pipefd[0], F_GETFL, 0);
    int fd_flags = fcntl(pipefd[0], F_GETFD, 0);
    if (flags < 0 || fd_flags < 0 ||
        fcntl(pipefd[0], F_SETFL, flags | O_NONBLOCK) != 0 ||
        fcntl(pipefd[0], F_SETFD, fd_flags | FD_CLOEXEC) != 0) {
        close(pipefd[0]);
        stop_child(pid);
        return 0;
    }

    job->pid = pid;
    job->fd = pipefd[0];
    job->child_active = 1;
    job->pipe_open = 1;
    job->deadline_ms = monotonic_ms() + timeout_ms;
    return 1;
}

static void capture_job_drain(CaptureJob *job)
{
    char chunk[4096];
    int reads = 0;

    /* A noisy child must yield back to input and deadline checks even if it
     * can keep its pipe permanently readable. */
    while (job->pipe_open && reads++ < 16) {
        ssize_t count = read(job->fd, chunk, sizeof(chunk));

        if (count > 0) {
            size_t available = job->used + 1 < job->out_sz
                                   ? job->out_sz - job->used - 1 : 0;
            size_t copy = (size_t)count < available
                              ? (size_t)count : available;
            if (copy) {
                memcpy(job->out + job->used, chunk, copy);
                job->used += copy;
                job->out[job->used] = '\0';
            }
            if (copy < (size_t)count)
                job->truncated = 1;
            continue;
        }
        if (count < 0 && errno == EINTR)
            continue;
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
            return;
        close(job->fd);
        job->fd = -1;
        job->pipe_open = 0;
    }
}

static void capture_job_reap(CaptureJob *job)
{
    int status = 0;
    pid_t waited;

    if (!job->child_active)
        return;
    do {
        waited = waitpid(job->pid, &status, WNOHANG);
    } while (waited < 0 && errno == EINTR);
    if (waited == 0)
        return;
    job->child_active = 0;
    if (waited == job->pid && WIFEXITED(status))
        job->result = WEXITSTATUS(status);
    else
        job->result = -1;

    /* Once the direct command exits, no descendant is allowed to hold the UI
     * open merely by retaining its inherited stdout descriptor. */
    capture_job_drain(job);
    if (job->pipe_open) {
        close(job->fd);
        job->fd = -1;
        job->pipe_open = 0;
    }
}

static void capture_job_stop(CaptureJob *job, int result)
{
    if (job->pipe_open) {
        close(job->fd);
        job->fd = -1;
        job->pipe_open = 0;
    }
    if (job->child_active)
        stop_child(job->pid);
    job->child_active = 0;
    job->result = result;
}

/* Pump all repository jobs together. Network checks therefore cost roughly
 * the slowest remote, not the sum of all three, while Esc/Q and resize remain
 * responsive throughout. Tests use interactive=0 without initializing curses. */
static int wait_capture_jobs(CaptureJob jobs[], size_t count, int interactive)
{
    int cancelled = 0;

    if (interactive)
        timeout(0);
    for (;;) {
        struct pollfd pollfds[REPO_COUNT + 1];
        nfds_t poll_count = 0;
        int active = 0;
        int wait_ms = UI_POLL_MS;
        int64_t now = monotonic_ms();

        reap_deferred_children();
        for (size_t i = 0; i < count; i++) {
            if (!jobs[i].child_active)
                continue;
            capture_job_drain(&jobs[i]);
            capture_job_reap(&jobs[i]);
            if (!jobs[i].child_active)
                continue;
            if (now >= jobs[i].deadline_ms) {
                capture_job_stop(&jobs[i], -3);
                continue;
            }
            active++;
            int64_t remaining = jobs[i].deadline_ms - now;
            if (remaining < wait_ms)
                wait_ms = remaining > 0 ? (int)remaining : 0;
        }

        if (!active)
            break;

        if (interactive) {
            int ch = getch();
            if (ch == 'q' || ch == 'Q' || ch == 27 || ch == 3) {
                cancelled = 1;
                for (size_t i = 0; i < count; i++) {
                    if (jobs[i].child_active)
                        capture_job_stop(&jobs[i], -2);
                }
                break;
            }
            if (ch == KEY_RESIZE)
                draw();
            pollfds[poll_count++] = (struct pollfd) {
                .fd = STDIN_FILENO,
                .events = POLLIN
            };
        }

        for (size_t i = 0; i < count; i++) {
            if (jobs[i].child_active && jobs[i].pipe_open) {
                pollfds[poll_count++] = (struct pollfd) {
                    .fd = jobs[i].fd,
                    .events = POLLIN | POLLHUP
                };
            }
        }

        int ready;
        do {
            ready = poll(pollfds, poll_count, wait_ms);
        } while (ready < 0 && errno == EINTR);
    }
    if (interactive)
        timeout(-1);
    return cancelled;
}

static int run_capture_timeout(const char *cwd, char *const argv[], char *out,
                               size_t out_sz, int timeout_ms)
{
    CaptureJob job;

    if (!capture_job_start(&job, cwd, argv, out, out_sz, timeout_ms))
        return -1;
    (void)wait_capture_jobs(&job, 1, 1);
    return job.result;
}

static void trim_newline(char *s)
{
    size_t n = strlen(s);
    while (n && (s[n - 1] == '\n' || s[n - 1] == '\r')) s[--n] = '\0';
}

static void init_repos(void)
{
    const char *home = getenv("HOME");
    if (!home) home = ".";
    repos[0].name = "writing";
    repos[1].name = "scriptorium";
    repos[2].name = "simplesuite";
    for (int i = 0; i < REPO_COUNT; i++)
        snprintf(repos[i].path, sizeof(repos[i].path), "%s/%s", home, repos[i].name);
}

static const char *skip_porcelain_fields(const char *text, int fields)
{
    for (int i = 0; i < fields; i++) {
        while (*text == ' ')
            text++;
        while (*text && *text != ' ')
            text++;
        if (!*text)
            return text;
    }
    while (*text == ' ')
        text++;
    return text;
}

static void add_changed_file(Repo *r, const char *status, const char *path)
{
    if (r->file_count < MAX_FILES) {
        snprintf(r->files[r->file_count], MAX_FILE_LINE,
                 "%.2s %s", status, path);
        r->file_count++;
    }
    r->dirty = 1;
}

/* One porcelain-v2 status replaces four serial Git invocations per repo.
 * Besides being faster, this gives branch, upstream, ahead/behind, and file
 * state from the same index snapshot. */
static void parse_porcelain_v2(Repo *r, char *text, int truncated)
{
    char *save = NULL;
    char *line = strtok_r(text, "\n", &save);

    r->is_repo = 1;
    r->file_count = 0;
    r->dirty = 0;
    r->ahead = 0;
    r->behind = 0;
    r->upstream_ok = 0;
    r->branch[0] = '\0';

    while (line) {
        if (strncmp(line, "# branch.head ", 14) == 0) {
            const char *head = line + 14;
            snprintf(r->branch, sizeof(r->branch), "%s",
                     strcmp(head, "(detached)") == 0
                         ? "detached HEAD" : head);
        } else if (strncmp(line, "# branch.ab +", 13) == 0) {
            if (sscanf(line + 12, "+%d -%d", &r->ahead, &r->behind) == 2)
                r->upstream_ok = 1;
        } else if ((line[0] == '1' || line[0] == '2' || line[0] == 'u') &&
                   line[1] == ' ' && line[2] && line[3]) {
            int fields = line[0] == '1' ? 7 : line[0] == '2' ? 8 : 9;
            const char *path = skip_porcelain_fields(line + 2, fields);
            char status[3] = {
                line[2] == '.' ? ' ' : line[2],
                line[3] == '.' ? ' ' : line[3],
                '\0'
            };
            if (*path)
                add_changed_file(r, status, path);
        } else if (line[0] == '?' && line[1] == ' ') {
            add_changed_file(r, "??", line + 2);
        }
        line = strtok_r(NULL, "\n", &save);
    }

    if (!r->branch[0])
        snprintf(r->branch, sizeof(r->branch), "detached HEAD");
    if (truncated && r->file_count < MAX_FILES) {
        snprintf(r->files[r->file_count++], MAX_FILE_LINE,
                 ".. additional status output omitted");
        r->dirty = 1;
    } else if (r->dirty && r->file_count == MAX_FILES) {
        snprintf(r->files[MAX_FILES - 1], MAX_FILE_LINE,
                 ".. additional changed files omitted");
    }
}

static const char *last_output_line(char *out)
{
    char *last;

    trim_newline(out);
    last = strrchr(out, '\n');
    return last && last[1] ? last + 1 : out;
}

static void reset_repo_snapshot(Repo *r)
{
    r->exists = access(r->path, F_OK) == 0;
    r->is_repo = 0;
    r->dirty = 0;
    r->ahead = 0;
    r->behind = 0;
    r->upstream_ok = 0;
    r->file_count = 0;
    r->branch[0] = '\0';
    r->result[0] = '\0';
    if (!r->exists)
        snprintf(r->result, sizeof(r->result), "directory missing");
    else
        snprintf(r->result, sizeof(r->result), "refreshing local status...");
}

static int refresh_all(void)
{
    CaptureJob jobs[REPO_COUNT];
    char outputs[REPO_COUNT][MAX_OUTPUT];
    char *status[] = {
        "git", "--no-optional-locks", "status", "--porcelain=v2",
        "--branch", "--ahead-behind", "--untracked-files=all", NULL
    };
    int all_ok = 1;
    int cancelled;

    for (int i = 0; i < REPO_COUNT; i++) {
        Repo *r = &repos[i];
        reset_repo_snapshot(r);
        capture_job_init(&jobs[i], outputs[i], sizeof(outputs[i]));
        if (r->exists &&
            !capture_job_start(&jobs[i], r->path, status, outputs[i],
                               sizeof(outputs[i]), LOCAL_COMMAND_TIMEOUT_MS)) {
            snprintf(r->result, sizeof(r->result),
                     "could not start local Git status");
            all_ok = 0;
        }
    }

    set_footer("Refreshing local status... Q, Esc, or Ctrl-C cancels");
    draw();
    cancelled = wait_capture_jobs(jobs, REPO_COUNT, 1);

    for (int i = 0; i < REPO_COUNT; i++) {
        Repo *r = &repos[i];
        const char *error;

        if (!r->exists)
            continue;
        if (jobs[i].result == 0) {
            parse_porcelain_v2(r, outputs[i], jobs[i].truncated);
            r->result[0] = '\0';
            continue;
        }

        all_ok = 0;
        if (jobs[i].result == -2) {
            snprintf(r->result, sizeof(r->result), "local refresh cancelled");
        } else if (jobs[i].result == -3) {
            snprintf(r->result, sizeof(r->result),
                     "local status stopped after %d-second timeout",
                     LOCAL_COMMAND_TIMEOUT_MS / 1000);
        } else {
            error = last_output_line(outputs[i]);
            snprintf(r->result, sizeof(r->result), "Git status failed: %.210s",
                     error[0] ? error : "not a Git repository");
        }
    }

    scroll_offset = 0;
    if (cancelled)
        set_footer("Refresh cancelled. P: push   L: pull   C: check remotes   R: refresh   Q: quit");
    else
        set_footer("Refreshed. P: push   L: pull   C: check remotes   R: refresh   Q: quit");
    return cancelled ? RUN_CANCELLED : all_ok ? RUN_OK : RUN_FAILED;
}

static int prompt_line(const char *label, char *buf, size_t size)
{
    size_t len = 0;
    size_t cursor = 0;
    size_t view = 0;

    if (!buf || size < 2)
        return 0;

    buf[0] = '\0';
    noecho();
    curs_set(1);
    timeout(-1);

    for (;;) {
        int h, w;
        size_t label_len = strlen(label);
        size_t field_width;
        getmaxyx(stdscr, h, w);

        field_width = w > (int)label_len ? (size_t)w - label_len : 1;
        if (cursor < view)
            view = cursor;
        else if (cursor >= view + field_width)
            view = cursor - field_width + 1;

        move(h - 2, 0);
        clrtoeol();
        mvaddnstr(h - 2, 0, label, w);
        if (w > (int)label_len)
            addnstr(buf + view, (int)field_width);

        move(h - 1, 0);
        clrtoeol();
        mvaddstr(h - 1, 1, "Enter: accept   Esc/Ctrl-C: cancel");

        int cursor_x = (int)label_len + (int)(cursor - view);
        if (cursor_x >= w)
            cursor_x = w - 1;
        move(h - 2, cursor_x);

        refresh();

        int ch = getch();

        if (ch == 27 || ch == 3) {
            buf[0] = '\0';
            curs_set(0);
            return -1;
        }

        if (ch == '\n' || ch == '\r' || ch == KEY_ENTER) {
            buf[len] = '\0';
            curs_set(0);
            return 1;
        }

        if (ch == KEY_BACKSPACE || ch == 127 || ch == 8) {
            if (cursor > 0) {
                memmove(buf + cursor - 1, buf + cursor, len - cursor + 1);
                cursor--;
                len--;
            }
            continue;
        }

        if (ch == KEY_DC) {
            if (cursor < len) {
                memmove(buf + cursor, buf + cursor + 1, len - cursor);
                len--;
            }
            continue;
        }

        if (ch == KEY_LEFT) {
            if (cursor > 0)
                cursor--;
            continue;
        }

        if (ch == KEY_RIGHT) {
            if (cursor < len)
                cursor++;
            continue;
        }

        if (ch == KEY_HOME) {
            cursor = 0;
            continue;
        }

        if (ch == KEY_END) {
            cursor = len;
            continue;
        }

        if (ch == KEY_RESIZE)
            continue;

        if (ch >= 32 && ch <= 126 && len + 1 < size) {
            memmove(buf + cursor + 1, buf + cursor, len - cursor + 1);
            buf[cursor++] = (char)ch;
            len++;
            buf[len] = '\0';
        }
    }
}

static int store_git_result(Repo *r, int rc, char *out, const char *verb)
{
    trim_newline(out);
    if (rc == 0) {
        snprintf(r->last_action, sizeof(r->last_action), "%s complete", verb);
        return RUN_OK;
    }
    if (rc == -2) {
        snprintf(r->last_action, sizeof(r->last_action), "%s cancelled", verb);
        return RUN_CANCELLED;
    }
    if (rc == -3) {
        snprintf(r->last_action, sizeof(r->last_action),
                 "%s stopped after %d-second timeout", verb,
                 COMMAND_TIMEOUT_MS / 1000);
        return RUN_FAILED;
    }
    const char *last = last_output_line(out);
    snprintf(r->last_action, sizeof(r->last_action), "%s failed: %.190s",
             verb, last[0] ? last : "unknown Git error");
    return RUN_FAILED;
}

static int run_git(Repo *r, char *const argv[], const char *verb)
{
    char out[MAX_OUTPUT];
    set_footer("%s: %s in progress... Q, Esc, or Ctrl-C cancels",
               r->name, verb);
    draw();
    int rc = run_capture_timeout(r->path, argv, out, sizeof(out),
                                 COMMAND_TIMEOUT_MS);
    return store_git_result(r, rc, out, verb);
}

static int run_git_batch(const int selected[REPO_COUNT], char *const argv[],
                         const char *verb, int results[REPO_COUNT])
{
    CaptureJob jobs[REPO_COUNT];
    char outputs[REPO_COUNT][MAX_OUTPUT];
    int selected_count = 0;
    int all_ok = 1;

    for (int i = 0; i < REPO_COUNT; i++) {
        capture_job_init(&jobs[i], outputs[i], sizeof(outputs[i]));
        results[i] = RUN_FAILED;
        if (!selected[i])
            continue;
        selected_count++;
        if (!capture_job_start(&jobs[i], repos[i].path, argv, outputs[i],
                               sizeof(outputs[i]), COMMAND_TIMEOUT_MS))
            all_ok = 0;
    }
    if (selected_count == 0)
        return RUN_OK;

    set_footer("%s running in %d %s... Q, Esc, or Ctrl-C cancels",
               verb, selected_count,
               selected_count == 1 ? "repository" : "repositories");
    draw();
    int cancelled = wait_capture_jobs(jobs, REPO_COUNT, 1);

    for (int i = 0; i < REPO_COUNT; i++) {
        if (!selected[i])
            continue;
        results[i] = store_git_result(&repos[i], jobs[i].result,
                                      outputs[i], verb);
        if (results[i] != RUN_OK)
            all_ok = 0;
    }
    return cancelled ? RUN_CANCELLED : all_ok ? RUN_OK : RUN_FAILED;
}

static int check_remotes(void)
{
    CaptureJob jobs[REPO_COUNT];
    char outputs[REPO_COUNT][MAX_OUTPUT];
    char errors[REPO_COUNT][MAX_STATUS];
    char *fetch[] = { "git", "fetch", "--quiet", "--prune", NULL };
    int all_ok = 1;
    int cancelled;

    memset(errors, 0, sizeof(errors));

    for (int i = 0; i < REPO_COUNT; i++) {
        Repo *r = &repos[i];

        capture_job_init(&jobs[i], outputs[i], sizeof(outputs[i]));
        if (r->is_repo &&
            !capture_job_start(&jobs[i], r->path, fetch, outputs[i],
                               sizeof(outputs[i]), COMMAND_TIMEOUT_MS)) {
            snprintf(errors[i], sizeof(errors[i]),
                     "remote check failed: could not start git fetch");
            all_ok = 0;
        }
    }

    set_footer("Checking all remotes concurrently... Q, Esc, or Ctrl-C cancels");
    draw();
    cancelled = wait_capture_jobs(jobs, REPO_COUNT, 1);

    for (int i = 0; i < REPO_COUNT; i++) {
        if (!repos[i].is_repo || jobs[i].result == 0 || errors[i][0])
            continue;
        if (jobs[i].result == -2) {
            snprintf(errors[i], sizeof(errors[i]), "remote check cancelled");
        } else if (jobs[i].result == -3) {
            snprintf(errors[i], sizeof(errors[i]),
                     "remote check stopped after %d-second timeout",
                     COMMAND_TIMEOUT_MS / 1000);
        } else {
            const char *error = last_output_line(outputs[i]);
            snprintf(errors[i], sizeof(errors[i]),
                     "remote check failed: %.180s",
                     error[0] ? error : "unknown Git error");
        }
        all_ok = 0;
    }

    if (cancelled) {
        for (int i = 0; i < REPO_COUNT; i++) {
            if (errors[i][0])
                snprintf(repos[i].last_action,
                         sizeof(repos[i].last_action), "%.255s", errors[i]);
        }
        return RUN_CANCELLED;
    }

    /*
     * Fetch updated the remote-tracking refs. This second pass is local
     * and recalculates ahead/behind without touching the network.
     */
    int refresh_rc = refresh_all();

    /*
     * Restore fetch failures after repainting the local snapshots so a failed
     * remote can never look current merely because its stale refs parsed.
     */
    for (int i = 0; i < REPO_COUNT; i++) {
        if (errors[i][0])
            snprintf(repos[i].last_action, sizeof(repos[i].last_action),
                     "%.255s", errors[i]);
    }

    if (refresh_rc == RUN_CANCELLED)
        return RUN_CANCELLED;
    return all_ok && refresh_rc == RUN_OK ? RUN_OK : RUN_FAILED;
}

static int any_repo_behind(void)
{
    for (int i = 0; i < REPO_COUNT; i++) {
        if (repos[i].is_repo && repos[i].behind > 0)
            return 1;
    }
    return 0;
}

static int any_repo_without_upstream(void)
{
    for (int i = 0; i < REPO_COUNT; i++) {
        if (repos[i].is_repo && !repos[i].upstream_ok)
            return 1;
    }
    return 0;
}

static void restore_normal_footer(void)
{
    footer_notice_active = 0;
    set_footer("P: push   L: pull   C: check remotes   R: refresh   Q: quit");
}

static void show_temporary_footer(const char *message)
{
    set_footer("%s", message);
    clock_gettime(CLOCK_MONOTONIC, &footer_notice_deadline);
    footer_notice_deadline.tv_sec += FOOTER_NOTICE_MS / 1000;
    footer_notice_deadline.tv_nsec +=
        (long)(FOOTER_NOTICE_MS % 1000) * 1000000L;
    if (footer_notice_deadline.tv_nsec >= 1000000000L) {
        footer_notice_deadline.tv_sec++;
        footer_notice_deadline.tv_nsec -= 1000000000L;
    }
    footer_notice_active = 1;
    draw();
}

static int footer_notice_remaining_ms(void)
{
    struct timespec now;
    long long remaining_ns;

    if (!footer_notice_active)
        return -1;

    clock_gettime(CLOCK_MONOTONIC, &now);
    remaining_ns =
        (long long)(footer_notice_deadline.tv_sec - now.tv_sec) * 1000000000LL +
        (long long)footer_notice_deadline.tv_nsec - now.tv_nsec;
    if (remaining_ns <= 0)
        return 0;

    return (int)((remaining_ns + 999999LL) / 1000000LL);
}

static void pull_all(void)
{
    int found = 0;
    int selected[REPO_COUNT] = {0};
    int results[REPO_COUNT];

    /*
     * Network access happens only after the user explicitly presses L.
     */
    int remote_rc = check_remotes();
    if (remote_rc == RUN_CANCELLED) {
        show_temporary_footer("Pull cancelled.");
        return;
    }
    if (remote_rc != RUN_OK) {
        show_temporary_footer("Pull aborted: at least one remote check failed.");
        return;
    }

    if (any_repo_without_upstream()) {
        show_temporary_footer("Pull aborted: at least one repository has no usable upstream.");
        return;
    }

    for (int i = 0; i < REPO_COUNT; i++) {
        Repo *r = &repos[i];

        if (!r->is_repo || r->behind <= 0)
            continue;

        found = 1;
        selected[i] = 1;
        r->last_action[0] = '\0';
    }

    if (!found) {
        show_temporary_footer("Everything is already up to date.");
        return;
    }

    /* check_remotes() already fetched each upstream. Rebase directly onto
     * those refs so pull does not perform the same network request twice. The
     * repositories are independent, so their rebases can run concurrently. */
    char *rebase[] = {
        "git", "rebase", "--autostash", "@{upstream}", NULL
    };
    int batch_rc = run_git_batch(selected, rebase, "pull", results);
    (void)refresh_all();

    if (batch_rc == RUN_CANCELLED)
        show_temporary_footer("Pull cancelled.");
    else if (batch_rc != RUN_OK)
        show_temporary_footer("Pull finished with errors. Review the repository messages above.");
    else
        show_temporary_footer("Pull complete. All available updates were applied.");
}

static void push_all(void)
{
    /*
     * Startup and ordinary refreshes remain instant. Network access
     * occurs here only because the user explicitly requested a push.
     */
    int remote_rc = check_remotes();
    if (remote_rc == RUN_CANCELLED) {
        show_temporary_footer("Push cancelled.");
        return;
    }
    if (remote_rc != RUN_OK) {
        show_temporary_footer("Push aborted: at least one remote check failed.");
        return;
    }

    if (any_repo_without_upstream()) {
        show_temporary_footer("Push aborted: at least one repository has no usable upstream.");
        return;
    }

    if (any_repo_behind()) {
        show_temporary_footer("Push blocked: pull the available updates first with L.");
        return;
    }

    int dirty_count = 0;
    char message[512] = {0};
    for (int i = 0; i < REPO_COUNT; i++) if (repos[i].is_repo && repos[i].dirty) dirty_count++;

    if (dirty_count) {
        int prompt_rc = prompt_line("Commit message: ", message, sizeof(message));

        if (prompt_rc < 0) {
            show_temporary_footer("Push cancelled.");
            return;
        }

        if (!message[0]) {
            show_temporary_footer("Push cancelled: no commit message.");
            return;
        }
    }

    int cancelled = 0;
    int ready[REPO_COUNT] = {0};
    int push_results[REPO_COUNT];
    for (int i = 0; i < REPO_COUNT && !cancelled; i++) {
        Repo *r = &repos[i];
        r->push_ok = 0;
        r->last_action[0] = '\0';
        if (!r->is_repo) continue;
        if (r->dirty) {
            char *add[] = {"git", "add", "-A", NULL};
            char *commit[] = {"git", "commit", "-m", message, NULL};
            int rc = run_git(r, add, "stage");
            if (rc == RUN_CANCELLED) { cancelled = 1; break; }
            if (rc != RUN_OK) continue;
            rc = run_git(r, commit, "commit");
            if (rc == RUN_CANCELLED) { cancelled = 1; break; }
            if (rc != RUN_OK) continue;
        }
        ready[i] = 1;
    }

    if (!cancelled) {
        char *push[] = {"git", "push", NULL};
        int batch_rc = run_git_batch(ready, push, "push", push_results);
        if (batch_rc == RUN_CANCELLED)
            cancelled = 1;
        for (int i = 0; i < REPO_COUNT; i++) {
            if (ready[i] && push_results[i] == RUN_OK)
                repos[i].push_ok = 1;
        }
    }

    refresh_all();
    if (cancelled) {
        show_temporary_footer("Operation cancelled. You are back in SimpleCheck.");
        return;
    }
    int ok = 0;
    for (int i = 0; i < REPO_COUNT; i++) if (repos[i].push_ok) ok++;
    if (ok == REPO_COUNT)
        show_temporary_footer("All three repositories pushed successfully.");
    else
        show_temporary_footer("Push finished. Review repository messages above.");
}

static int total_content_lines(void)
{
    int n = 2;
    for (int i = 0; i < REPO_COUNT; i++) n += 3 + (repos[i].last_action[0] ? 1 : 0) + (repos[i].file_count ? repos[i].file_count : 1);
    return n;
}

static void draw(void)
{
    int h, w;
    getmaxyx(stdscr, h, w);
    erase();
    attron(A_BOLD);
    mvaddstr(0, 2, "SimpleCheck");
    attroff(A_BOLD);
    mvaddstr(1, 2, "~/writing   ~/scriptorium   ~/simplesuite");

    int logical = 0;
    int y = 3;
    for (int i = 0; i < REPO_COUNT; i++) {
        Repo *r = &repos[i];
        if (logical++ >= scroll_offset && y < h - 4) {
            attron(A_BOLD);
            mvprintw(y++, 2, "%s", r->name);
            attroff(A_BOLD);
        }
        if (logical++ >= scroll_offset && y < h - 4) {
            if (!r->is_repo) mvprintw(y++, 4, "%s", r->result);
            else if (!r->upstream_ok)
                mvprintw(y++, 4, "%s  branch: %s  upstream unknown",
                    r->dirty ? "DIRTY" : "clean", r->branch);
            else
                mvprintw(y++, 4, "%s  branch: %s  %s%s%s",
                    r->dirty ? "DIRTY" : "clean", r->branch,
                    r->ahead ? "ahead " : "", r->ahead ? "" : "",
                    r->behind ? "behind" : "");
        }
        if (r->is_repo && r->upstream_ok && (r->ahead || r->behind) && logical - 1 >= scroll_offset && y < h - 4)
            mvprintw(y - 1, w > 42 ? w - 28 : 4, "ahead %d / behind %d", r->ahead, r->behind);

        if (r->last_action[0]) {
            if (logical++ >= scroll_offset && y < h - 4)
                mvprintw(y++, 6, "%.*s", w - 8, r->last_action);
        }
        if (!r->is_repo || !r->file_count) {
            if (logical++ >= scroll_offset && y < h - 4)
                mvaddstr(y++, 6, r->is_repo ? "no changed files" : "unavailable");
        } else {
            for (int f = 0; f < r->file_count; f++) {
                if (logical++ >= scroll_offset && y < h - 4)
                    mvprintw(y++, 6, "%.*s", w - 8, r->files[f]);
            }
        }
        if (logical++ >= scroll_offset && y < h - 4) y++;
    }

    const char *label = "[ P  PUSH ALL THREE ]";
    button_w = (int)strlen(label);
    button_y = h - 3;
    button_x = (w - button_w) / 2;
    if (button_x < 0) button_x = 0;
    attron(A_REVERSE | A_BOLD);
    mvaddnstr(button_y, button_x, label, w - button_x);
    attroff(A_REVERSE | A_BOLD);
    mvaddnstr(h - 1, 1, footer, w - 2);
    refresh();
}

int main(void)
{
    init_repos();
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) {
        fprintf(stderr,
                "simplecheck: refusing to run without a terminal on stdin and stdout\n");
        return 1;
    }
    setenv("ESCDELAY", "25", 1);
    initscr();
    set_escdelay(ESCAPE_DELAY_MS);
    raw();
    noecho();
    keypad(stdscr, TRUE);
    notimeout(stdscr, FALSE);
    curs_set(0);
    mousemask(BUTTON1_CLICKED, NULL);
    refresh_all();

    for (;;) {
        draw();
        int wait_ms = footer_notice_remaining_ms();
        if (wait_ms == 0) {
            restore_normal_footer();
            continue;
        }
        timeout(wait_ms);
        int ch = getch();
        timeout(-1);

        if (ch == ERR) {
            if (footer_notice_active)
                restore_normal_footer();
            continue;
        }

        /* A notice never consumes the user's next command. */
        if (footer_notice_active)
            restore_normal_footer();

        if (ch == 'q' || ch == 'Q' || ch == 3) break;
        if (ch == 'r' || ch == 'R') refresh_all();
        else if (ch == 'c' || ch == 'C') {
            int rc = check_remotes();
            if (rc == RUN_OK)
                show_temporary_footer("Remote check complete.");
            else if (rc == RUN_CANCELLED)
                show_temporary_footer("Remote check cancelled.");
            else
                show_temporary_footer("Remote check finished with errors. Review repository messages.");
        }
        else if (ch == 'l' || ch == 'L') pull_all();
        else if (ch == 'p' || ch == 'P') push_all();
        else if (ch == KEY_UP || ch == 'k') { if (scroll_offset > 0) scroll_offset--; }
        else if (ch == KEY_DOWN || ch == 'j') {
            int max = total_content_lines() - (LINES - 7);
            if (max > 0 && scroll_offset < max) scroll_offset++;
        } else if (ch == KEY_MOUSE) {
            MEVENT ev;
            if (getmouse(&ev) == OK && ev.y == button_y && ev.x >= button_x && ev.x < button_x + button_w)
                push_all();
        }
    }
    endwin();
    reap_deferred_children();
    free(deferred_children);
    return 0;
}
