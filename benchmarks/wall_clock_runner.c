#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static void usage(const char *program) {
  fprintf(stderr, "usage: %s STDOUT_FILE STDERR_FILE -- PROGRAM [ARG ...]\n",
          program);
}

static int write_errno(int fd, int error) {
  const unsigned char *cursor = (const unsigned char *)&error;
  size_t remaining = sizeof(error);

  while (remaining != 0) {
    ssize_t written = write(fd, cursor, remaining);
    if (written < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    cursor += (size_t)written;
    remaining -= (size_t)written;
  }
  return 0;
}

static void child_fail(int error_fd, int error) {
  (void)write_errno(error_fd, error);
  _exit(127);
}

static int monotonic_now(struct timespec *value) {
  if (clock_gettime(CLOCK_MONOTONIC, value) != 0) {
    fprintf(stderr, "clock_gettime(CLOCK_MONOTONIC): %s\n", strerror(errno));
    return -1;
  }
  return 0;
}

int main(int argc, char **argv) {
  int error_pipe[2];
  struct timespec start;
  struct timespec end;
  pid_t child;
  int wait_status;
  int launch_error = 0;
  size_t launch_error_bytes = 0;
  int exit_status = -1;
  int signal_number = 0;

  if (argc < 5 || strcmp(argv[3], "--") != 0) {
    usage(argv[0]);
    return 2;
  }
  if (pipe(error_pipe) != 0) {
    fprintf(stderr, "pipe: %s\n", strerror(errno));
    return 1;
  }
  if (fcntl(error_pipe[1], F_SETFD, FD_CLOEXEC) != 0) {
    fprintf(stderr, "fcntl(FD_CLOEXEC): %s\n", strerror(errno));
    close(error_pipe[0]);
    close(error_pipe[1]);
    return 1;
  }
  if (monotonic_now(&start) != 0) {
    close(error_pipe[0]);
    close(error_pipe[1]);
    return 1;
  }

  child = fork();
  if (child < 0) {
    fprintf(stderr, "fork: %s\n", strerror(errno));
    close(error_pipe[0]);
    close(error_pipe[1]);
    return 1;
  }
  if (child == 0) {
    int stdout_fd;
    int stderr_fd;

    close(error_pipe[0]);
    stdout_fd = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (stdout_fd < 0) {
      child_fail(error_pipe[1], errno);
    }
    stderr_fd = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (stderr_fd < 0) {
      child_fail(error_pipe[1], errno);
    }
    if (dup2(stdout_fd, STDOUT_FILENO) < 0 ||
        dup2(stderr_fd, STDERR_FILENO) < 0) {
      child_fail(error_pipe[1], errno);
    }
    close(stdout_fd);
    close(stderr_fd);
    execvp(argv[4], &argv[4]);
    child_fail(error_pipe[1], errno);
  }

  close(error_pipe[1]);
  while (launch_error_bytes < sizeof(launch_error)) {
    ssize_t count =
        read(error_pipe[0], (unsigned char *)&launch_error + launch_error_bytes,
             sizeof(launch_error) - launch_error_bytes);
    if (count == 0) {
      break;
    }
    if (count < 0) {
      if (errno == EINTR) {
        continue;
      }
      fprintf(stderr, "read launch status: %s\n", strerror(errno));
      close(error_pipe[0]);
      return 1;
    }
    launch_error_bytes += (size_t)count;
  }
  close(error_pipe[0]);

  while (waitpid(child, &wait_status, 0) < 0) {
    if (errno == EINTR) {
      continue;
    }
    fprintf(stderr, "waitpid: %s\n", strerror(errno));
    return 1;
  }
  if (monotonic_now(&end) != 0) {
    return 1;
  }
  if (launch_error_bytes != 0 && launch_error_bytes != sizeof(launch_error)) {
    fprintf(stderr, "incomplete child launch status\n");
    return 1;
  }
  if (WIFEXITED(wait_status)) {
    exit_status = WEXITSTATUS(wait_status);
  } else if (WIFSIGNALED(wait_status)) {
    signal_number = WTERMSIG(wait_status);
  } else {
    fprintf(stderr, "child stopped without exiting or receiving a signal\n");
    return 1;
  }

  printf("%.9f\t%d\t%d\t%d\n",
         (double)(end.tv_sec - start.tv_sec) +
             (double)(end.tv_nsec - start.tv_nsec) / 1000000000.0,
         exit_status, signal_number, launch_error);
  return 0;
}
