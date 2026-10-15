#ifndef HARBOR_PTY_H
#define HARBOR_PTY_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Spawns `path` as a session leader whose controlling terminal is a new pseudo-terminal.
///
/// The child runs only async-signal-safe calls between fork and execve: setsid,
/// TIOCSCTTY, dup2, close (every inherited descriptor above 2), signal reset, chdir.
/// The returned master descriptor is non-blocking and close-on-exec.
///
/// Returns 0 on success or an errno value.
int harbor_pty_spawn(const char *path,
                     char *const argv[],
                     char *const envp[],
                     const char *working_directory,
                     unsigned short rows,
                     unsigned short columns,
                     int *master_fd_out,
                     pid_t *pid_out);

/// Updates the window size; the kernel delivers SIGWINCH to the foreground process group.
int harbor_pty_set_size(int master_fd, unsigned short rows, unsigned short columns,
                        unsigned short pixel_width, unsigned short pixel_height);

/// The foreground process group of the terminal, or -1.
pid_t harbor_pty_foreground_pgid(int master_fd);

/// Writes the executable name of `pid` into `buffer`. Returns its length, or 0.
int harbor_process_name(pid_t pid, char *buffer, int buffer_size);

/// Writes the current working directory of `pid` into `buffer`. Returns its length, or 0.
int harbor_process_cwd(pid_t pid, char *buffer, int buffer_size);

#ifdef __cplusplus
}
#endif

#endif
