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

#ifndef INTERNAL_HELPERS_H
#define INTERNAL_HELPERS_H
#include <signal.h>

static int positive_int_parse(const char *str) {
    int out = 0;
    char c = 0;

    while ((c = *str++) != 0) {
        out *= 10;
        if (c >= '0' && c <= '9') {
            out += c - '0';
        } else {
            return -1;
        }
    }
    return out;
}

static int highest_possibly_open_fd_dir(const char *fd_dir) {
    int highest_fd_so_far = 0;
    DIR *dir_ptr = opendir(fd_dir);
    if (dir_ptr == NULL) {
        return -1;
    }

    struct dirent *dir_entry = NULL;
    while ((dir_entry = readdir(dir_ptr)) != NULL) {
        char *entry_name = dir_entry->d_name;
        int number = positive_int_parse(entry_name);
        if (number > (long)highest_fd_so_far) {
            highest_fd_so_far = number;
        }
     }

    closedir(dir_ptr);
    return highest_fd_so_far;
}

static int highest_possibly_open_fd(void) {
#if defined(__APPLE__)
    int hi = highest_possibly_open_fd_dir("/dev/fd");
    if (hi < 0) {
        hi = getdtablesize();
    }
#elif defined(__linux__)
    int hi = highest_possibly_open_fd_dir("/proc/self/fd");
    if (hi < 0) {
        hi = getdtablesize();
    }
#else
    int hi = 1024;
#endif

    return hi;
}

static int block_everything_but_something_went_seriously_wrong_signals(sigset_t *old_mask) {
    sigset_t mask;
    int r = 0;
    r |= sigfillset(&mask);
    r |= sigdelset(&mask, SIGABRT);
    r |= sigdelset(&mask, SIGBUS);
    r |= sigdelset(&mask, SIGFPE);
    r |= sigdelset(&mask, SIGILL);
    r |= sigdelset(&mask, SIGKILL);
    r |= sigdelset(&mask, SIGSEGV);
    r |= sigdelset(&mask, SIGSTOP);
    r |= sigdelset(&mask, SIGSYS);
    r |= sigdelset(&mask, SIGTRAP);

    r |= pthread_sigmask(SIG_BLOCK, &mask, old_mask);
    return r;
}
#endif
