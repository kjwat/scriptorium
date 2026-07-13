#ifndef SCRIPTORIUM_MACOS_COMPAT_H
#define SCRIPTORIUM_MACOS_COMPAT_H

/*
 * SimpleSuite is developed primarily on Linux and enables strict POSIX feature
 * levels in several translation units.  On Darwin that hides useful BSD
 * interfaces such as flock(2), strcasestr(3), MAP_ANON, and the nanosecond
 * members of struct stat.  This header is force-included by Scriptorium's
 * macOS build path before any SimpleSuite source header.
 */
#ifdef __APPLE__
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE 1
#endif

#include <sys/mman.h>
#include <time.h>

#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS MAP_ANON
#endif

/* Apple libc has nanosleep(2) and clock_gettime(3), but not the POSIX
 * clock_nanosleep(3) interface used by SimpleVis. */
#ifndef TIMER_ABSTIME
#define TIMER_ABSTIME 1
#define SCRIPTORIUM_NEEDS_CLOCK_NANOSLEEP 1
int scriptorium_clock_nanosleep(clockid_t clock_id, int flags,
                                const struct timespec *request,
                                struct timespec *remaining);
#define clock_nanosleep scriptorium_clock_nanosleep
#endif
#endif

#endif
