#include "macos-compat.h"

#ifdef SCRIPTORIUM_NEEDS_CLOCK_NANOSLEEP
#include <errno.h>

static int valid_timespec(const struct timespec *value)
{
    return value && value->tv_sec >= 0 &&
           value->tv_nsec >= 0 && value->tv_nsec < 1000000000L;
}

int scriptorium_clock_nanosleep(clockid_t clock_id, int flags,
                                const struct timespec *request,
                                struct timespec *remaining)
{
    struct timespec now;
    struct timespec delay;

    if (!valid_timespec(request) || (flags != 0 && flags != TIMER_ABSTIME))
        return EINVAL;

    if (flags == 0) {
        if (nanosleep(request, remaining) == 0)
            return 0;
        return errno;
    }

    if (clock_gettime(clock_id, &now) != 0)
        return errno;

    delay.tv_sec = request->tv_sec - now.tv_sec;
    delay.tv_nsec = request->tv_nsec - now.tv_nsec;
    if (delay.tv_nsec < 0) {
        delay.tv_sec--;
        delay.tv_nsec += 1000000000L;
    }
    if (delay.tv_sec < 0)
        return 0;

    if (nanosleep(&delay, remaining) == 0)
        return 0;
    return errno;
}
#else
/* Keep the file a valid translation unit if a future Apple SDK supplies the
 * native interface and the compatibility function is no longer needed. */
const int scriptorium_macos_compat_unused = 0;
#endif
