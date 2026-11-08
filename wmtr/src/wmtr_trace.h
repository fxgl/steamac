/* Trace streams used by the guest client. stderr is captured by PROTON_LOG. */
#ifndef WMTR_TRACE_H
#define WMTR_TRACE_H
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static FILE *wmtr_open_trace(const char *target) {
  if (!target || !*target) return NULL;
  if (!strcmp(target, "/dev/stderr") || !strcmp(target, "stderr")) return stderr;
  char path[512];
  int n = snprintf(path, sizeof path, "%s.%d", target, (int)getpid());
  if (n < 0 || (size_t)n >= sizeof path) {
    fprintf(stderr, "wmtr: trace path too long\n");
    return NULL;
  }
  FILE *stream = fopen(path, "w");
  if (!stream) fprintf(stderr, "wmtr: cannot open trace %s: %s\n", path, strerror(errno));
  else setvbuf(stream, NULL, _IOLBF, 0);
  return stream;
}
#endif
