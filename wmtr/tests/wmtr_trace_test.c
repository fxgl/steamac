#include <assert.h>
#include <stdlib.h>
#include "wmtr_trace.h"
int main(void) {
  assert(!wmtr_open_trace(NULL));
  assert(!wmtr_open_trace(""));
  assert(wmtr_open_trace("stderr") == stderr);
  assert(wmtr_open_trace("/dev/stderr") == stderr);
  char directory[] = "/tmp/wmtr-trace-XXXXXX";
  assert(mkdtemp(directory));
  char base[256], path[280];
  snprintf(base, sizeof base, "%s/calls", directory);
  snprintf(path, sizeof path, "%s.%d", base, (int)getpid());
  FILE *stream = wmtr_open_trace(base); assert(stream);
  fputs("> 42 7 0\n", stream);
  FILE *reader = fopen(path, "r"); assert(reader);
  char line[32]; assert(fgets(line, sizeof line, reader));
  assert(!strcmp(line, "> 42 7 0\n"));
  fclose(reader); fclose(stream); unlink(path); rmdir(directory);
  assert(!wmtr_open_trace("/nonexistent/wmtr/calls"));
  puts("wmtr_trace_test: passed");
}
