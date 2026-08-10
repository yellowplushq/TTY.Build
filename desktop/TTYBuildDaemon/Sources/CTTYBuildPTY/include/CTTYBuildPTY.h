#ifndef C_TTYBUILD_PTY_H
#define C_TTYBUILD_PTY_H

#include <sys/ioctl.h>
#include <sys/types.h>

/// Starts `executable` inside a real controlling pseudo-terminal.
///
/// Returns the child PID and writes the master fd to `master_fd`. If creating
/// the PTY, changing directory, or executing the child fails, returns -1 and
/// writes the underlying errno to `child_errno`.
pid_t ttybuild_forkpty_exec(
    int *master_fd,
    const struct winsize *window_size,
    const char *executable,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    int *child_errno
);

#endif
