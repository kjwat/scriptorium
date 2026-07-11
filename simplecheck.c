#define _POSIX_C_SOURCE 200809L
#include <ncurses.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
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
static char footer[MAX_STATUS] = "P: push all three   R: refresh   Q: quit";

static void set_footer(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(footer, sizeof(footer), fmt, ap);
    va_end(ap);
}

static int run_capture(const char *cwd, char *const argv[], char *out, size_t out_sz)
{
    int pipefd[2];
    pid_t pid;
    size_t used = 0;
    int status = -1;

    if (out_sz) out[0] = '\0';
    if (pipe(pipefd) < 0) return -1;

    pid = fork();
    if (pid < 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        return -1;
    }
    if (pid == 0) {
        if (cwd && chdir(cwd) < 0) _exit(126);
        dup2(pipefd[1], STDOUT_FILENO);
        dup2(pipefd[1], STDERR_FILENO);
        close(pipefd[0]);
        close(pipefd[1]);
        execvp(argv[0], argv);
        _exit(127);
    }

    close(pipefd[1]);
    while (used + 1 < out_sz) {
        ssize_t n = read(pipefd[0], out + used, out_sz - used - 1);
        if (n > 0) used += (size_t)n;
        else if (n == 0) break;
        else if (errno != EINTR) break;
    }
    if (out_sz) out[used] = '\0';
    close(pipefd[0]);
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
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
    set_footer("Refreshed. P: push all three   R: refresh   Q: quit");
}

static int prompt_line(const char *label, char *buf, size_t size)
{
    int h = getmaxy(stdscr);
    echo();
    curs_set(1);
    timeout(-1);
    move(h - 2, 0);
    clrtoeol();
    mvprintw(h - 2, 0, "%s", label);
    refresh();
    int rc = getnstr(buf, (int)size - 1);
    noecho();
    curs_set(0);
    return rc == OK;
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
    int rc = run_capture(r->path, argv, out, sizeof(out));
    trim_newline(out);
    if (rc == 0) {
        snprintf(r->last_action, sizeof(r->last_action), "%s complete", verb);
        return 1;
    }
    const char *last = strrchr(out, '\n');
    if (last && last[1]) last++;
    else last = out;
    snprintf(r->last_action, sizeof(r->last_action), "%s failed: %.190s", verb, last[0] ? last : "unknown Git error");
    return 0;
}

static void push_all(void)
{
    int dirty_count = 0;
    char message[512] = {0};
    for (int i = 0; i < REPO_COUNT; i++) if (repos[i].is_repo && repos[i].dirty) dirty_count++;

    if (!confirm_push()) {
        set_footer("Push cancelled.");
        return;
    }
    if (dirty_count) {
        if (!prompt_line("Commit message for dirty repos: ", message, sizeof(message)) || !message[0]) {
            set_footer("Push cancelled: no commit message.");
            return;
        }
    }

    for (int i = 0; i < REPO_COUNT; i++) {
        Repo *r = &repos[i];
        r->push_ok = 0;
        r->last_action[0] = '\0';
        if (!r->is_repo) continue;
        if (r->dirty) {
            char *add[] = {"git", "add", "-A", NULL};
            char *commit[] = {"git", "commit", "-m", message, NULL};
            if (!run_git(r, add, "stage")) continue;
            if (!run_git(r, commit, "commit")) continue;
        }
        char *push[] = {"git", "push", NULL};
        if (run_git(r, push, "push")) r->push_ok = 1;
    }

    refresh_all();
    int ok = 0;
    for (int i = 0; i < REPO_COUNT; i++) if (repos[i].push_ok) ok++;
    if (ok == REPO_COUNT) set_footer("All three repositories pushed successfully.");
    else set_footer("Push finished. Review repository messages above.");
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
