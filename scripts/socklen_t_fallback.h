/* socklen_t_fallback.h — local ljh-sh patch for the broken
 * Xcode 15.4 SDK's <sys/_types/_socklen_t.h> typedef.
 *
 * Background:
 *   The SDK does `typedef __darwin_socklen_t socklen_t;` which
 *   expands to `typedef unsigned int socklen_t;` and is rejected
 *   by clang 17+ with "type-name cannot be signed or unsigned".
 *
 * Strategy:
 *   1. -D_SOCKLEN_T in CFLAGS → SDK's <sys/_types/_socklen_t.h>
 *      typedef is skipped.
 *   2. The diffutils 3.10 Makefile inlines GL_CFLAG_GNULIB_WARNINGS
 *      (a giant block of system typedefs) on every compile line.
 *      We override it to empty in build.sh so the inlined block
 *      doesn't conflict.
 *   3. This header is -include'd BEFORE the .c file's system
 *      includes. It defines socklen_t from __darwin_socklen_t
 *      so <sys/socket.h> resolves socklen_t correctly.
 *
 * Pass via CFLAGS:
 *   -D_SOCKLEN_T -include <path-to-this-file>
 */
#ifndef _SOCKLEN_T_FALLBACK_LJHSH_DONE
#define _SOCKLEN_T_FALLBACK_LJHSH_DONE

#include <machine/types.h>
#ifndef socklen_t
typedef __darwin_socklen_t socklen_t;
#endif

#endif
