#define main simplecheck_program_main
#include "../simplecheck.c"
#undef main
#include <sys/stat.h>

static void test_fail(const char *message)
{
    fprintf(stderr, "simplecheck-latency-check: %s\n", message);
    exit(1);
}

static void test_expect(int condition, const char *message)
{
    if (!condition)
        test_fail(message);
}

static int helper_mode(int argc, char **argv)
{
    if (argc < 2)
        return -1;
    if (strcmp(argv[1], "--helper-output") == 0) {
        fputs("captured output\n", stdout);
        return 0;
    }
    if (strcmp(argv[1], "--helper-sleep") == 0) {
        int delay = argc > 2 ? atoi(argv[2]) : 400;
        (void)poll(NULL, 0, delay);
        return 0;
    }
    if (strcmp(argv[1], "--helper-stubborn") == 0) {
        signal(SIGTERM, SIG_IGN);
        (void)poll(NULL, 0, 5000);
        return 0;
    }
    if (strcmp(argv[1], "--helper-noisy") == 0) {
        char chunk[4096];
        int64_t deadline = monotonic_ms() + 5000;

        memset(chunk, 'x', sizeof(chunk));
        signal(SIGTERM, SIG_IGN);
        signal(SIGPIPE, SIG_IGN);
        while (monotonic_ms() < deadline) {
            if (write(STDOUT_FILENO, chunk, sizeof(chunk)) < 0)
                (void)poll(NULL, 0, 1);
        }
        return 0;
    }
    return -1;
}

static void test_porcelain_parser(void)
{
    Repo repo = {0};
    char status[] =
        "# branch.oid 0123456789abcdef\n"
        "# branch.head main\n"
        "# branch.upstream origin/main\n"
        "# branch.ab +2 -1\n"
        "1 .M N... 100644 100644 100644 aaaaa bbbbb notes with spaces.txt\n"
        "2 R. N... 100644 100644 100644 aaaaa bbbbb R100 new name.txt\told name.txt\n"
        "u UU N... 100644 100644 100644 100644 aaaaa bbbbb ccccc conflict.txt\n"
        "? untracked file.txt\n";

    parse_porcelain_v2(&repo, status, 0);
    test_expect(repo.is_repo, "porcelain status did not mark repository valid");
    test_expect(strcmp(repo.branch, "main") == 0,
                "porcelain branch parsing failed");
    test_expect(repo.upstream_ok && repo.ahead == 2 && repo.behind == 1,
                "porcelain ahead/behind parsing failed");
    test_expect(repo.dirty && repo.file_count == 4,
                "porcelain changed-file count failed");
    test_expect(strcmp(repo.files[0], " M notes with spaces.txt") == 0,
                "ordinary porcelain path parsing failed");
    test_expect(strcmp(repo.files[1], "R  new name.txt\told name.txt") == 0,
                "renamed porcelain path parsing failed");
    test_expect(strcmp(repo.files[2], "UU conflict.txt") == 0,
                "unmerged porcelain path parsing failed");
    test_expect(strcmp(repo.files[3], "?? untracked file.txt") == 0,
                "untracked porcelain path parsing failed");
}

static void test_repo_configuration(void)
{
    static const char *const expected[] = {
        "writing", "scriptorium", "simplesuite", "website", "notes"
    };

    test_expect(REPO_COUNT == 5, "SimpleCheck repository count is not five");
    init_repos();
    for (int i = 0; i < REPO_COUNT; i++) {
        test_expect(strcmp(repos[i].name, expected[i]) == 0,
                    "SimpleCheck repository configuration is incorrect");
    }
}

static void test_capture_output(const char *self)
{
    CaptureJob job;
    char output[128];
    char *command[] = { (char *)self, "--helper-output", NULL };

    test_expect(capture_job_start(&job, NULL, command, output, sizeof(output),
                                  1000),
                "could not start output helper");
    (void)wait_capture_jobs(&job, 1, 0);
    test_expect(job.result == 0, "output helper failed");
    test_expect(strcmp(output, "captured output\n") == 0,
                "output helper was not fully captured");
}

static void test_folder_scoped_status(void)
{
    char fixture[] = "/tmp/simplecheck-folder.XXXXXX";
    char writing[PATH_MAX], journal[PATH_MAX], notes[PATH_MAX];
    char inside[PATH_MAX], outside[PATH_MAX], output[MAX_OUTPUT];
    CaptureJob job;
    test_expect(mkdtemp(fixture) != NULL, "could not create folder fixture");
    snprintf(writing, sizeof(writing), "%s/writing", fixture);
    snprintf(journal, sizeof(journal), "%s/writing/journal", fixture);
    snprintf(notes, sizeof(notes), "%s/writing/notes", fixture);
    snprintf(inside, sizeof(inside), "%s/writing/notes/inside-note.txt", fixture);
    snprintf(outside, sizeof(outside), "%s/writing/journal/outside-journal.txt", fixture);
    test_expect(mkdir(writing, 0700) == 0 && mkdir(journal, 0700) == 0 &&
                mkdir(notes, 0700) == 0, "could not create fixture folders");
    FILE *file = fopen(inside, "w");
    test_expect(file != NULL, "could not create inside fixture");
    fclose(file);
    file = fopen(outside, "w");
    test_expect(file != NULL, "could not create outside fixture");
    fclose(file);
    char *initialize[] = {"git", "init", "--quiet", NULL};
    test_expect(capture_job_start(&job, writing, initialize, output,
                                  sizeof(output), 2000), "could not initialize fixture repository");
    (void)wait_capture_jobs(&job, 1, 0);
    test_expect(job.result == 0, "git init failed in fixture");

    FILE *screen_out = tmpfile(), *screen_in = tmpfile();
    test_expect(screen_out && screen_in, "could not create test terminal");
    SCREEN *screen = newterm("xterm-256color", screen_out, screen_in);
    test_expect(screen != NULL, "could not initialize test terminal");
    set_term(screen);
    resizeterm(40, 120);
    init_repos();
    for (int i = 0; i < REPO_COUNT; i++)
        snprintf(repos[i].path, sizeof(repos[i].path), "%s/%s", fixture,
                 i == 4 ? "writing/notes" : repos[i].name);
    test_expect(refresh_all() == RUN_OK, "fixture refresh failed");
    test_expect(repos[0].dirty && repos[0].file_count == 2,
                "writing did not include its own nested changes");
    test_expect(repos[4].dirty && repos[4].file_count == 1 &&
                strstr(repos[4].files[0], "inside-note.txt") != NULL,
                "notes status included files outside its folder");
    test_expect(unlink(inside) == 0, "could not remove inside fixture");
    test_expect(refresh_all() == RUN_OK && !repos[4].dirty &&
                repos[4].file_count == 0 && repos[0].dirty,
                "outside changes made an unchanged notes folder look dirty");
    endwin(); delscreen(screen); fclose(screen_in); fclose(screen_out);

    char *cleanup[] = {"rm", "-rf", "--", fixture, NULL};
    test_expect(capture_job_start(&job, NULL, cleanup, output, sizeof(output), 2000),
                "could not clean fixture");
    (void)wait_capture_jobs(&job, 1, 0);
    test_expect(job.result == 0, "fixture cleanup failed");
}

static void test_jobs_are_concurrent(const char *self)
{
    CaptureJob jobs[REPO_COUNT];
    char outputs[REPO_COUNT][16];
    char *command[] = { (char *)self, "--helper-sleep", "400", NULL };
    int64_t started = monotonic_ms();

    for (int i = 0; i < REPO_COUNT; i++) {
        test_expect(capture_job_start(&jobs[i], NULL, command, outputs[i],
                                      sizeof(outputs[i]), 2000),
                    "could not start concurrency helper");
    }
    (void)wait_capture_jobs(jobs, REPO_COUNT, 0);
    int64_t elapsed = monotonic_ms() - started;

    for (int i = 0; i < REPO_COUNT; i++)
        test_expect(jobs[i].result == 0, "concurrency helper failed");
    test_expect(elapsed < 900,
                "repository jobs ran serially instead of concurrently");
}

static void test_timeout_is_bounded(const char *self)
{
    CaptureJob job;
    char output[16];
    char *command[] = { (char *)self, "--helper-stubborn", NULL };
    int64_t started = monotonic_ms();

    test_expect(capture_job_start(&job, NULL, command, output, sizeof(output),
                                  60),
                "could not start timeout helper");
    (void)wait_capture_jobs(&job, 1, 0);
    int64_t elapsed = monotonic_ms() - started;

    test_expect(job.result == -3, "stalled helper did not time out");
    test_expect(elapsed < 500, "stalled helper held the caller too long");
    (void)poll(NULL, 0, 25);
    reap_deferred_children();
    test_expect(deferred_child_count == 0,
                "timed-out helper was not reaped");
}

static void test_noisy_child_yields(const char *self)
{
    CaptureJob job;
    char output[16];
    char *command[] = { (char *)self, "--helper-noisy", NULL };
    int64_t started = monotonic_ms();

    test_expect(capture_job_start(&job, NULL, command, output, sizeof(output),
                                  60),
                "could not start noisy helper");
    (void)wait_capture_jobs(&job, 1, 0);
    int64_t elapsed = monotonic_ms() - started;

    test_expect(job.result == -3, "noisy helper did not time out");
    test_expect(job.truncated, "noisy helper did not exercise bounded capture");
    test_expect(elapsed < 500,
                "continuous output starved subprocess deadline checks");
}

int main(int argc, char **argv)
{
    int helper = helper_mode(argc, argv);
    if (helper >= 0)
        return helper;

    test_repo_configuration();
    test_porcelain_parser();
    test_capture_output(argv[0]);
    test_jobs_are_concurrent(argv[0]);
    test_timeout_is_bounded(argv[0]);
    test_noisy_child_yields(argv[0]);
    test_folder_scoped_status();
    free(deferred_children);
    puts("OK SimpleCheck folder-scoped status and subprocess latency regressions");
    return 0;
}
