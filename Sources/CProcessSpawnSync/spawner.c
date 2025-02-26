//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#include <unistd.h>
#include <stdlib.h>
#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <assert.h>
#include <stdio.h>
#include <dirent.h>
#include <inttypes.h>
#include <limits.h>

#include <ps-api.h>

#include "internal-helpers.h"

#define MAKE_PS_ERROR_FROM_ERRNO(__kind) \
(ps_error){ \
    .pse_kind = (__kind), \
    .pse_code = errno, \
    .pse_file = __FILE__, \
    .pse_line = __LINE__ \
}

#if __apple__
#  define PS_SIG_MAX __DARWIN_NSIG
#else
#  define PS_SIG_MAX 32
#endif

#define ps_precondition(__cond) do { \
    int eval = (__cond); \
    if (!eval) { \
        __builtin_trap(); \
    } \
} while(0)

struct child_scratch {
    int duplicated_fd;
};

static void setup_and_execve_child(ps_process_configuration *config, int error_pipe, struct child_scratch *scratch) {
    ps_error error = { 0 };
    sigset_t sigset = { 0 };
    int err = -1;

    /* reset signal handlers */
    for (int signo = 1; signo < PS_SIG_MAX; signo++) {
        if (signo == SIGKILL || signo == SIGSTOP) {
            continue;
        }
        void (*err_ptr)(int) = signal(signo, SIG_DFL);
        if (err_ptr != SIG_ERR) {
            continue;
        }

        if (errno == EINVAL) {
            break; // probably too high of a signal
        }

        error = MAKE_PS_ERROR_FROM_ERRNO(PS_ERROR_KIND_SIGNAL);
        error.pse_extra_info = signo;
        goto write_fail;
    }

    /* reset signal mask */
    sigemptyset(&sigset);
    err = sigprocmask(SIG_SETMASK, &sigset, NULL) != 0;
    if (err) {
        error = MAKE_PS_ERROR_FROM_ERRNO(PS_ERROR_KIND_SIGPROC_MASK);
        goto write_fail;
    }

    if (config->psc_new_session) {
        err = setsid();
        if (err) {
            error = MAKE_PS_ERROR_FROM_ERRNO(PS_ERROR_KIND_SETSID);
            goto write_fail;
        }
    }

    for (int child_fd=0; child_fd<config->psc_fd_setup_count; child_fd++) {
        ps_fd_setup setup = config->psc_fd_setup_instructions[child_fd];

        switch (setup.psfd_kind) {
            case PS_MAP_FD:
                scratch[child_fd].duplicated_fd = fcntl(setup.psfd_parent_fd, F_DUPFD_CLOEXEC, config->psc_fd_setup_count);
                if (scratch[child_fd].duplicated_fd == -1) {
                    error = MAKE_PS_ERROR_FROM_ERRNO(PS_ERROR_KIND_DUP);
                    error.pse_extra_info = child_fd;
                    goto write_fail;
                }
                break;
            case PS_CLOSE_FD:
                scratch[child_fd].duplicated_fd = -1;
                break;
            default:
                ps_precondition(0);
        }
    }

    for (int child_fd=0; child_fd<config->psc_fd_setup_count; child_fd++) {
        ps_fd_setup setup = config->psc_fd_setup_instructions[child_fd];
        switch (setup.psfd_kind) {
            case PS_MAP_FD:
                ps_precondition(scratch[child_fd].duplicated_fd > child_fd);
                err = dup2(scratch[child_fd].duplicated_fd, child_fd);
                if (err == -1) {
                    error = MAKE_PS_ERROR_FROM_ERRNO(PS_ERROR_KIND_DUP2);
                    error.pse_extra_info = child_fd;
                    goto write_fail;
                }
                break;
            case PS_CLOSE_FD:
                ps_precondition(scratch[child_fd].duplicated_fd == -1);
                close(child_fd);
                break;
            default:
                ps_precondition(0);
        }
    }

    if (config->psc_close_other_fds) {
        for (int i=config->psc_fd_setup_count; i<highest_possibly_open_fd(); i++) {
            if (i != error_pipe) {
                close(i);
            }
        }
    }

    if (config->psc_cwd) {
        err = chdir(config->psc_cwd);
        if (err) {
            error = MAKE_PS_ERROR_FROM_ERRNO(PS_ERROR_KIND_CHDIR);
            goto write_fail;
        }
    }

    /* finally, exec */
    err = execve(config->psc_path, config->psc_argv, config->psc_env);
    if (err) {
        error = MAKE_PS_ERROR_FROM_ERRNO(PS_ERROR_KIND_EXECVE);
        goto write_fail;
    }

    __builtin_unreachable();

    write_fail:
    write(error_pipe, &error, sizeof(error));
    close(error_pipe);
}

pid_t ps_spawn_process(ps_process_configuration *config, ps_error *out_error) {
    pid_t pid = -1;
    sigset_t old_sigmask;
    struct child_scratch *scratch = NULL;
    int error_pid_fd[2] = { -1, -1 };
    int err = pipe(error_pid_fd);
    if (err) {
        ps_error error = MAKE_PS_ERROR_FROM_ERRNO(PS_ERROR_KIND_PIPE);
        if (out_error) {
            *out_error = error;
        }
        goto error_cleanup;
    }

    err = fcntl(error_pid_fd[1], F_SETFD, FD_CLOEXEC);
    if (err) {
        ps_error error = MAKE_PS_ERROR_FROM_ERRNO(PS_ERROR_KIND_FCNTL);
        if (out_error) {
            *out_error = error;
        }
        goto error_cleanup;
    }

    scratch = calloc(config->psc_fd_setup_count, sizeof(*scratch));

    /* block all signals on this thread, don't want things to go wrong post-fork, pre-execve */
    err = block_everything_but_something_went_seriously_wrong_signals(&old_sigmask);
    if (err) {
        ps_error error = MAKE_PS_ERROR_FROM_ERRNO(PS_ERROR_KIND_SIGMASK_THREAD);
        if (out_error) {
            *out_error = error;
        }
        goto error_cleanup;
    }

    if ((pid = fork()) == 0) {
        /* child */
        close(error_pid_fd[0]);
        error_pid_fd[0] = -1;
        setup_and_execve_child(config, error_pid_fd[1], scratch);
        abort();
    } else {
        /* parent */
        err = pthread_sigmask(SIG_SETMASK, &old_sigmask, NULL); /* restore old sigmask */
        if (err) {
            ps_error error = MAKE_PS_ERROR_FROM_ERRNO(PS_ERROR_KIND_SIGMASK_THREAD);
            if (out_error) {
                *out_error = error;
            }
            goto error_cleanup;
        }

        if (pid > 0) {
            ps_error child_error = { 0 };
            close(error_pid_fd[1]);
            error_pid_fd[1] = -1;

            free(scratch);
            scratch = NULL;

            while (true) {
                ssize_t read_res = read(error_pid_fd[0], &child_error, sizeof(child_error));
                if (read_res == 0) {
                    /* EOF, that's good, execve worked. */
                    close(error_pid_fd[0]);
                    error_pid_fd[0] = -1;
                    return pid;
                } else if (read_res > 0) {
                    ps_precondition(read_res == sizeof(child_error));
                    if (out_error) {
                        *out_error = child_error;
                    }
                    goto error_cleanup;
                } else {
                    if (errno == EINTR) {
                        continue;
                    } else {
                        ps_error error = MAKE_PS_ERROR_FROM_ERRNO(PS_ERROR_KIND_READ_FROM_CHILD);
                        if (out_error) {
                            *out_error = error;
                        }
                        goto error_cleanup;
                    }
                }
            }
        } else {
            ps_error error = MAKE_PS_ERROR_FROM_ERRNO(PS_ERROR_KIND_FCNTL);
            if (out_error) {
                *out_error = error;
            }
            goto error_cleanup;
        }
    }

error_cleanup:
    if (error_pid_fd[0] != -1) {
        close(error_pid_fd[0]);
    }
    if (error_pid_fd[1] != -1) {
        close(error_pid_fd[1]);
    }
    free(scratch);
    ps_precondition((!out_error) || (out_error->pse_kind != 0));
    return 0;
}

void ps_convert_exit_status(int in_status, bool *out_has_exited, bool *out_is_exit_code, int *out_code) {
    if (WIFEXITED(in_status)) {
        *out_has_exited = true;
        *out_is_exit_code = true;
        *out_code = WEXITSTATUS(in_status);
    } else if (WIFSIGNALED(in_status)) {
        *out_has_exited = true;
        *out_is_exit_code = false;
        *out_code = WTERMSIG(in_status);
    } else {
        *out_has_exited = false;
        *out_is_exit_code = false;
        *out_code = -1;
    }
}
