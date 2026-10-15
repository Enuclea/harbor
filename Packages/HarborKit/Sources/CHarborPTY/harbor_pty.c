#include "harbor_pty.h"

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

int harbor_pty_spawn(const char *path,
                     char *const argv[],
                     char *const envp[],
                     const char *working_directory,
                     unsigned short rows,
                     unsigned short columns,
                     int *master_fd_out,
                     pid_t *pid_out) {
    int master = -1;
    int slave = -1;
    struct winsize size = {rows, columns, 0, 0};

    if (openpty(&master, &slave, NULL, NULL, &size) == -1) {
        return errno;
    }

    // Line discipline defaults plus IUTF8 so canonical-mode backspace erases whole characters.
    struct termios attributes;
    if (tcgetattr(slave, &attributes) == 0) {
        attributes.c_iflag |= IUTF8;
        tcsetattr(slave, TCSANOW, &attributes);
    }

    fcntl(master, F_SETFD, FD_CLOEXEC);

    // Everything the child needs is computed before fork.
    int max_fd = getdtablesize();
    if (max_fd < 0 || max_fd > 65536) {
        max_fd = 65536;
    }
    struct sigaction default_action;
    memset(&default_action, 0, sizeof(default_action));
    default_action.sa_handler = SIG_DFL;
    sigemptyset(&default_action.sa_mask);
    sigset_t empty_mask;
    sigemptyset(&empty_mask);

    // Block all signals across fork so no handler runs in the child before reset.
    sigset_t all_signals, previous_mask;
    sigfillset(&all_signals);
    pthread_sigmask(SIG_SETMASK, &all_signals, &previous_mask);

    pid_t pid = fork();
    if (pid == 0) {
        setsid();
        ioctl(slave, TIOCSCTTY, 0);
        dup2(slave, STDIN_FILENO);
        dup2(slave, STDOUT_FILENO);
        dup2(slave, STDERR_FILENO);
        for (int fd = STDERR_FILENO + 1; fd < max_fd; fd++) {
            close(fd);
        }
        for (int signal_number = 1; signal_number < NSIG; signal_number++) {
            if (signal_number != SIGKILL && signal_number != SIGSTOP) {
                sigaction(signal_number, &default_action, NULL);
            }
        }
        sigprocmask(SIG_SETMASK, &empty_mask, NULL);
        if (working_directory != NULL) {
            chdir(working_directory);
        }
        execve(path, argv, envp);
        _exit(127);
    }

    int fork_error = errno;
    pthread_sigmask(SIG_SETMASK, &previous_mask, NULL);
    close(slave);

    if (pid < 0) {
        close(master);
        return fork_error;
    }

    int flags = fcntl(master, F_GETFL);
    fcntl(master, F_SETFL, flags | O_NONBLOCK);

    *master_fd_out = master;
    *pid_out = pid;
    return 0;
}

int harbor_pty_set_size(int master_fd, unsigned short rows, unsigned short columns,
                        unsigned short pixel_width, unsigned short pixel_height) {
    struct winsize size = {rows, columns, pixel_width, pixel_height};
    return ioctl(master_fd, TIOCSWINSZ, &size) == -1 ? errno : 0;
}

pid_t harbor_pty_foreground_pgid(int master_fd) {
    return tcgetpgrp(master_fd);
}

int harbor_process_name(pid_t pid, char *buffer, int buffer_size) {
    if (pid <= 0 || buffer_size <= 0) {
        return 0;
    }
    int length = proc_name(pid, buffer, (uint32_t)buffer_size);
    return length > 0 ? length : 0;
}

int harbor_process_cwd(pid_t pid, char *buffer, int buffer_size) {
    if (pid <= 0 || buffer_size <= 0) {
        return 0;
    }
    struct proc_vnodepathinfo info;
    int result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info));
    if (result != sizeof(info)) {
        return 0;
    }
    size_t length = strnlen(info.pvi_cdir.vip_path, sizeof(info.pvi_cdir.vip_path));
    if (length >= (size_t)buffer_size) {
        return 0;
    }
    memcpy(buffer, info.pvi_cdir.vip_path, length);
    buffer[length] = '\0';
    return (int)length;
}
