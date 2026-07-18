#define main simplecheck_program_main
#include "../simplecheck.c"
#undef main

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

    test_porcelain_parser();
    test_capture_output(argv[0]);
    test_jobs_are_concurrent(argv[0]);
    test_timeout_is_bounded(argv[0]);
    test_noisy_child_yields(argv[0]);
    free(deferred_children);
    puts("OK SimpleCheck status and subprocess latency regressions");
    return 0;
}
