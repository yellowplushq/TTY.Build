#include "CTTYBuildPTY.h"

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

static void report_child_error_and_exit(int fd, int error) {
    const uint8_t *bytes = (const uint8_t *)&error;
    size_t remaining = sizeof(error);
    while (remaining > 0) {
        ssize_t written = write(fd, bytes, remaining);
        if (written > 0) {
            bytes += written;
            remaining -= (size_t)written;
        } else if (written < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
    _exit(127);
}

pid_t ttybuild_forkpty_exec(
    int *master_fd,
    const struct winsize *window_size,
    const char *executable,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    int *child_errno
) {
    if (master_fd == NULL || executable == NULL || argv == NULL ||
        envp == NULL || working_directory == NULL) {
        errno = EINVAL;
        if (child_errno != NULL) *child_errno = errno;
        return -1;
    }

    int error_pipe[2];
    if (pipe(error_pipe) != 0) {
        if (child_errno != NULL) *child_errno = errno;
        return -1;
    }

    int descriptor_flags = fcntl(error_pipe[1], F_GETFD);
    if (descriptor_flags < 0 ||
        fcntl(error_pipe[1], F_SETFD, descriptor_flags | FD_CLOEXEC) != 0) {
        int error = errno;
        close(error_pipe[0]);
        close(error_pipe[1]);
        errno = error;
        if (child_errno != NULL) *child_errno = error;
        return -1;
    }

    struct rlimit descriptor_limit;
    rlim_t descriptor_count = 1024;
    if (getrlimit(RLIMIT_NOFILE, &descriptor_limit) == 0 &&
        descriptor_limit.rlim_cur != RLIM_INFINITY) {
        descriptor_count = descriptor_limit.rlim_cur;
    }

    pid_t pid = forkpty(
        master_fd,
        NULL,
        NULL,
        (struct winsize *)window_size
    );
    if (pid < 0) {
        int error = errno;
        close(error_pipe[0]);
        close(error_pipe[1]);
        errno = error;
        if (child_errno != NULL) *child_errno = error;
        return -1;
    }

    if (pid == 0) {
        close(error_pipe[0]);
        // Keep the exec error channel at one known descriptor, then discard
        // every other daemon descriptor inherited across fork. The shell must
        // inherit only its controlling terminal on stdin/stdout/stderr.
        const int child_error_fd = 3;
        if (error_pipe[1] != child_error_fd) {
            if (dup2(error_pipe[1], child_error_fd) < 0) {
                report_child_error_and_exit(error_pipe[1], errno);
            }
            close(error_pipe[1]);
        }
        descriptor_flags = fcntl(child_error_fd, F_GETFD);
        if (descriptor_flags < 0 ||
            fcntl(child_error_fd, F_SETFD, descriptor_flags | FD_CLOEXEC) != 0) {
            report_child_error_and_exit(child_error_fd, errno);
        }
        for (int fd = child_error_fd + 1; (rlim_t)fd < descriptor_count; fd++) {
            close(fd);
        }

        if (chdir(working_directory) != 0) {
            report_child_error_and_exit(child_error_fd, errno);
        }
        execve(executable, argv, envp);
        report_child_error_and_exit(child_error_fd, errno);
    }

    close(error_pipe[1]);
    int exec_error = 0;
    uint8_t *bytes = (uint8_t *)&exec_error;
    size_t received = 0;
    while (received < sizeof(exec_error)) {
        ssize_t count = read(
            error_pipe[0],
            bytes + received,
            sizeof(exec_error) - received
        );
        if (count > 0) {
            received += (size_t)count;
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
    close(error_pipe[0]);

    if (received == 0) {
        if (child_errno != NULL) *child_errno = 0;
        return pid;
    }

    if (received != sizeof(exec_error)) exec_error = EIO;
    close(*master_fd);
    *master_fd = -1;
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
    errno = exec_error;
    if (child_errno != NULL) *child_errno = exec_error;
    return -1;
}
