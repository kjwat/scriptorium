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
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define REPO_COUNT 3
#define MAX_OUTPUT 65536
#define MAX_FILES 256
#define MAX_FILE_LINE 512
#define MAX_STATUS 256
#define COMMAND_TIMEOUT_SECONDS 45

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
    int push_ok;
    char result[MAX_STATUS];
    char last_action[MAX_STATUS];
} Repo;

static Repo repos[REPO_COUNT];
static int button_y, button_x, button_w;
static int scroll_offset;
static char footer[MAX_STATUS] = "P: push   L: pull   C: check remotes   R: refresh   Q: quit";

static void draw(void);

static void set_footer(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(footer, sizeof(footer), fmt, ap);
    va_end(ap);
}

static void stop_child(pid_t pid)
{
    if (pid <= 0) return;
    kill(-pid, SIGTERM);
    napms(150);
    kill(-pid, SIGKILL);
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
}

static int run_capture(const char *cwd, char *const argv[], char *out, size_t out_sz)
{
    int pipefd[2];
    pid_t pid;
    size_t used = 0;
    int status = -1;
    struct timespec started;

    if (out_sz) out[0] = '\0';
    if (pipe(pipefd) < 0) return -1;

    pid = fork();
    if (pid < 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        return -1;
    }
    if (pid == 0) {
        int nullfd;
        setpgid(0, 0);
        if (cwd && chdir(cwd) < 0) _exit(126);
        nullfd = open("/dev/null", O_RDONLY);
        if (nullfd >= 0) {
            dup2(nullfd, STDIN_FILENO);
            if (nullfd > STDERR_FILENO) close(nullfd);
        }
        dup2(pipefd[1], STDOUT_FILENO);
        dup2(pipefd[1], STDERR_FILENO);
        close(pipefd[0]);
        close(pipefd[1]);
        setenv("GIT_TERMINAL_PROMPT", "0", 1);
        setenv("GCM_INTERACTIVE", "Never", 1);
        execvp(argv[0], argv);
        _exit(127);
    }

    setpgid(pid, pid);
    close(pipefd[1]);
    fcntl(pipefd[0], F_SETFL, fcntl(pipefd[0], F_GETFL) | O_NONBLOCK);
    clock_gettime(CLOCK_MONOTONIC, &started);

    for (;;) {
        char discard[1024];
        char *dst = used + 1 < out_sz ? out + used : discard;
        size_t room = used + 1 < out_sz ? out_sz - used - 1 : sizeof(discard);
        ssize_t n = read(pipefd[0], dst, room);
        if (n > 0 && dst != discard) used += (size_t)n;

        pid_t done = waitpid(pid, &status, WNOHANG);
        if (done == pid) break;
        if (done < 0 && errno != EINTR) break;

        nodelay(stdscr, TRUE);
        int ch = getch();
        nodelay(stdscr, FALSE);
        if (ch == 'q' || ch == 'Q' || ch == 27) {
            close(pipefd[0]);
            stop_child(pid);
            if (out_sz) out[used] = '\0';
            return -2;
        }

        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - started.tv_sec >= COMMAND_TIMEOUT_SECONDS) {
            close(pipefd[0]);
            stop_child(pid);
            if (out_sz) out[used] = '\0';
            return -3;
        }

        struct pollfd pfd = { .fd = pipefd[0], .events = POLLIN | POLLHUP };
        poll(&pfd, 1, 75);
    }

    while (used + 1 < out_sz) {
        ssize_t n = read(pipefd[0], out + used, out_sz - used - 1);
        if (n > 0) used += (size_t)n;
        else break;
    }
    if (out_sz) out[used] = '\0';
    close(pipefd[0]);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
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

static void parse_porcelain(Repo *r, char *text)
{
    char *save = NULL;
    char *line = strtok_r(text, "\n", &save);
    r->file_count = 0;
    r->dirty = 0;
    while (line && r->file_count < MAX_FILES) {
        if (line[0]) {
            snprintf(r->files[r->file_count], MAX_FILE_LINE, "%s", line);
            r->file_count++;
            r->dirty = 1;
        }
        line = strtok_r(NULL, "\n", &save);
    }
}

static void refresh_repo(Repo *r)
{
    char out[MAX_OUTPUT];
    char *git_check[] = {"git", "rev-parse", "--is-inside-work-tree", NULL};
    char *branch[] = {"git", "branch", "--show-current", NULL};
    char *status[] = {"git", "status", "--short", "--untracked-files=all", NULL};
    char *counts[] = {"git", "rev-list", "--left-right", "--count", "HEAD...@{upstream}", NULL};

    r->exists = access(r->path, F_OK) == 0;
    r->is_repo = r->dirty = r->ahead = r->behind = r->file_count = 0;
    r->branch[0] = '\0';
    r->result[0] = '\0';
    if (!r->exists) {
        snprintf(r->result, sizeof(r->result), "directory missing");
        return;
    }
    if (run_capture(r->path, git_check, out, sizeof(out)) != 0 || strncmp(out, "true", 4) != 0) {
        snprintf(r->result, sizeof(r->result), "not a Git repository");
        return;
    }
    r->is_repo = 1;
    if (run_capture(r->path, branch, out, sizeof(out)) == 0) {
        trim_newline(out);
        snprintf(r->branch, sizeof(r->branch), "%s", out[0] ? out : "detached HEAD");
    }
    if (run_capture(r->path, status, out, sizeof(out)) == 0)
        parse_porcelain(r, out);

    if (run_capture(r->path, counts, out, sizeof(out)) == 0)
        sscanf(out, "%d\t%d", &r->behind, &r->ahead);
}

static void refresh_all(void)
{
    for (int i = 0; i < REPO_COUNT; i++) refresh_repo(&repos[i]);
    scroll_offset = 0;
    set_footer("Refreshed. P: push   L: pull   C: check remotes   R: refresh   Q: quit");
}

static int prompt_line(const char *label, char *buf, size_t size)
{
    size_t len = 0;

    if (!buf || size < 2)
        return 0;

    buf[0] = '\0';
    noecho();
    curs_set(1);
    timeout(-1);

    for (;;) {
        int h, w;
        getmaxyx(stdscr, h, w);

        move(h - 2, 0);
        clrtoeol();
        mvprintw(h - 2, 0, "%s%s", label, buf);

        move(h - 1, 0);
        clrtoeol();
        mvaddstr(h - 1, 1, "Enter: accept   Esc/Ctrl-C: cancel");

        int cursor_x = (int)strlen(label) + (int)len;
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
            if (len > 0)
                buf[--len] = '\0';
            continue;
        }

        if (ch == KEY_RESIZE)
            continue;

        if (ch >= 32 && ch <= 126 && len + 1 < size) {
            buf[len++] = (char)ch;
            buf[len] = '\0';
        }
    }
}

static int confirm_push(void)
{
    int h = getmaxy(stdscr);
    move(h - 2, 0);
    clrtoeol();
    attron(A_BOLD);
    mvprintw(h - 2, 0, "Commit dirty repos and push writing, scriptorium, and simplesuite? [y/N]");
    attroff(A_BOLD);
    refresh();
    int ch = getch();
    return ch == 'y' || ch == 'Y';
}

static int run_git(Repo *r, char *const argv[], const char *verb)
{
    char out[MAX_OUTPUT];
    set_footer("%s: %s in progress... Q or Esc cancels", r->name, verb);
    draw();
    int rc = run_capture(r->path, argv, out, sizeof(out));
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
        snprintf(r->last_action, sizeof(r->last_action), "%s stopped after %d-second timeout", verb, COMMAND_TIMEOUT_SECONDS);
        return RUN_FAILED;
    }
    const char *last = strrchr(out, '\n');
    if (last && last[1]) last++;
    else last = out;
    snprintf(r->last_action, sizeof(r->last_action), "%s failed: %.190s", verb, last[0] ? last : "unknown Git error");
    return RUN_FAILED;
}

static void check_remotes(void)
{
    char out[MAX_OUTPUT];

    set_footer("Checking remotes...");
    draw();

    for (int i = 0; i < REPO_COUNT; i++) {
        Repo *r = &repos[i];

        if (!r->is_repo)
            continue;

        char *fetch[] = {
            "git", "fetch", "--quiet", "--prune", NULL
        };

        int rc = run_capture(r->path, fetch, out, sizeof(out));

        if (rc != 0) {
            trim_newline(out);
            snprintf(r->last_action, sizeof(r->last_action),
                     "remote check failed: %.180s",
                     out[0] ? out : "unknown Git error");
        }
    }

    /*
     * Fetch updated the remote-tracking refs. This second pass is local
     * and recalculates ahead/behind without touching the network.
     */
    refresh_all();
}

static int any_repo_behind(void)
{
    for (int i = 0; i < REPO_COUNT; i++) {
        if (repos[i].is_repo && repos[i].behind > 0)
            return 1;
    }
    return 0;
}

static void restore_normal_footer(void)
{
    set_footer("P: push   L: pull   C: check remotes   R: refresh   Q: quit");
}

static void show_temporary_footer(const char *message)
{
    set_footer("%s", message);
    draw();
    napms(5000);
    restore_normal_footer();
}

static void pull_all(void)
{
    int found = 0;
    int failed = 0;
    int cancelled = 0;

    /*
     * Network access happens only after the user explicitly presses L.
     */
    check_remotes();

    for (int i = 0; i < REPO_COUNT; i++) {
        Repo *r = &repos[i];

        if (!r->is_repo || r->behind <= 0)
            continue;

        found = 1;
        r->last_action[0] = '\0';

        /*
         * Autostash protects local working changes while rebasing the
         * incoming commits. Git restores them afterward.
         */
        char *pull[] = {
            "git", "pull", "--rebase", "--autostash", NULL
        };

        int rc = run_git(r, pull, "pull");

        if (rc == RUN_CANCELLED) {
            cancelled = 1;
            break;
        }

        if (rc != RUN_OK)
            failed = 1;
    }

    refresh_all();

    if (cancelled) {
        show_temporary_footer("Pull cancelled.");
        return;
    }

    if (!found) {
        show_temporary_footer("Everything is already up to date.");
        return;
    }

    if (failed)
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
    check_remotes();

    if (any_repo_behind()) {
        show_temporary_footer("Push blocked: pull the available updates first with L.");
        return;
    }

    int dirty_count = 0;
    char message[512] = {0};
    for (int i = 0; i < REPO_COUNT; i++) if (repos[i].is_repo && repos[i].dirty) dirty_count++;

    if (!confirm_push()) {
        set_footer("Push cancelled.");
        return;
    }
    if (dirty_count) {
        int prompt_rc = prompt_line("Commit message: ", message, sizeof(message));

        if (prompt_rc < 0) {
            set_footer("Push cancelled.");
            draw();
            napms(5000);
            set_footer("P: push   L: pull   C: check remotes   R: refresh   Q: quit");
            return;
        }

        if (!message[0]) {
            set_footer("Push cancelled: no commit message.");
            return;
        }
    }

    int cancelled = 0;
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
        char *push[] = {"git", "push", NULL};
        int rc = run_git(r, push, "push");
        if (rc == RUN_CANCELLED) { cancelled = 1; break; }
        if (rc == RUN_OK) r->push_ok = 1;
    }

    refresh_all();
    if (cancelled) {
        set_footer("Operation cancelled. You are back in SimpleCheck.");
        return;
    }
    int ok = 0;
    for (int i = 0; i < REPO_COUNT; i++) if (repos[i].push_ok) ok++;
    if (ok == REPO_COUNT)
        set_footer("All three repositories pushed successfully.");
    else
        set_footer("Push finished. Review repository messages above.");

    draw();
    napms(5000);
    set_footer("P: push   L: pull   C: check remotes   R: refresh   Q: quit");
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
            else mvprintw(y++, 4, "%s  branch: %s  %s%s%s",
                r->dirty ? "DIRTY" : "clean", r->branch,
                r->ahead ? "ahead " : "", r->ahead ? "" : "",
                r->behind ? "behind" : "");
        }
        if (r->is_repo && (r->ahead || r->behind) && logical - 1 >= scroll_offset && y < h - 4)
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
    initscr();
    cbreak();
    noecho();
    keypad(stdscr, TRUE);
    curs_set(0);
    mousemask(BUTTON1_CLICKED, NULL);
    refresh_all();

    for (;;) {
        draw();
        int ch = getch();
        if (ch == 'q' || ch == 'Q') break;
        if (ch == 'r' || ch == 'R') refresh_all();
        else if (ch == 'c' || ch == 'C') {
            check_remotes();
            set_footer("Remote check complete.");
            draw();
            napms(5000);
            set_footer("P: push   L: pull   C: check remotes   R: refresh   Q: quit");
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
    return 0;
}
