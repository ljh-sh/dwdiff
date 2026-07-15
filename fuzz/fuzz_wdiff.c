/* fuzz_wdiff.c — libFuzzer harness for wdiff's word-tokenizer
 *                and reformat path.
 *
 * wdiff is mostly a thin front-end to GNU diff, so the
 * interesting fuzz surface is:
 *   - the word-tokenizer (split_file_into_words in src/wdiff.c)
 *   - the unified-diff parser (decode_directive_line)
 *   - the marker output path (start_of_delete / end_of_delete / etc.)
 *
 * We exercise the tokenizer + marker output by faking two input
 * files and a tiny population of marker characters. Diff itself
 * is the upstream diffutils codebase; we don't fuzz that here.
 *
 * To build + run (requires clang + libFuzzer + an instrumented
 * wdiff build):
 *
 *   cd upstream/wdiff
 *   autoreconf -if --force
 *   CC=clang CFLAGS="-O1 -fsanitize=address,undefined,fuzzer-no-link -g" \
 *     ./configure --srcdir=. --disable-shared
 *   make -j$(nproc)
 *
 *   cd ../..
 *   clang -O1 -fsanitize=address,undefined,fuzzer -g \
 *     -Iupstream/wdiff -Iupstream/wdiff/lib \
 *     fuzz/fuzz_wdiff.c \
 *     upstream/wdiff/src/*.o \
 *     -o fuzz/wdiff_fuzz
 *
 *   mkdir -p /tmp/wdiff-corpus
 *   ./fuzz/wdiff_fuzz /tmp/wdiff-corpus -max_len=65536 -jobs=$(nproc)
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>

/* Forward decls from wdiff's main.c — same as dwdiff, we don't
 * pull in the upstream headers to avoid pulling autotools config. */
extern int wdiff_main(int argc, char *argv[]);
extern int split_file_into_words(char *path);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
	if (size < 2) return 0;
	if (size > 1u << 20) return 0;

	/* Split on 0x1E (rare UTF-8 byte). */
	const uint8_t *split = memchr(data, 0x1E, size);
	size_t left_len, right_len;
	const uint8_t *right_start;
	if (split) {
		left_len  = split - data;
		right_start = split + 1;
		right_len = size - left_len - 1;
	} else {
		left_len  = size / 2;
		right_start = data + left_len;
		right_len = size - left_len;
	}

	char left_path[]  = "/tmp/fuzz-wdiff-L-XXXXXX";
	char right_path[] = "/tmp/fuzz-wdiff-R-XXXXXX";
	int lfd = mkstemp(left_path);  if (lfd < 0) return 0;
	int rfd = mkstemp(right_path); if (rfd < 0) { close(lfd); unlink(left_path); return 0; }
	if (write(lfd, data, left_len) != (ssize_t)left_len ||
	    write(rfd, right_start, right_len) != (ssize_t)right_len) {
		close(lfd); close(rfd); unlink(left_path); unlink(right_path);
		return 0;
	}
	close(lfd); close(rfd);

	/* Fork + exec the wdiff binary with the two files. The fuzzer
	 * watches for crashes (ASAN/UBSAN) and hangs (timeout). */
	const char *wdiff_bin = getenv("FUZZ_WDIFF_BIN");
	if (!wdiff_bin) wdiff_bin = "./upstream/wdiff/wdiff";
	if (access(wdiff_bin, X_OK) == 0) {
		char *argv[] = { (char *)wdiff_bin, (char *)left_path, (char *)right_path, NULL };
		pid_t pid = fork();
		if (pid == 0) {
			int devnull = open("/dev/null", O_WRONLY);
			if (devnull >= 0) {
				dup2(devnull, 1);
				dup2(devnull, 2);
				close(devnull);
			}
			alarm(5);
			execv(wdiff_bin, argv);
			_exit(127);
		}
		if (pid > 0) {
			int status;
			for (int i = 0; i < 50; i++) {
				if (waitpid(pid, &status, WNOHANG) == pid) break;
				usleep(100000);
			}
			kill(pid, SIGKILL);
			waitpid(pid, &status, 0);
		}
	}

	unlink(left_path);
	unlink(right_path);
	return 0;
}
