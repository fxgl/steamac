/* util_queue_finish with several threads, over and over, on macOS: Mesa's mutex/condvar barrier
 * fallback (no pthread barriers here) is what every queue finish waits on. Before KK 0077 every thread
 * leaving the barrier destroyed it, so the first one out destroyed the mutex and condvar under the
 * others and the finishing thread waited forever: disk_cache_destroy in kk_physical_device_destroy
 * hung the repro `compilers` test (and a VM process tearing down a Vulkan instance).
 * Built and run by host/kosmickrisp/build.sh against the driver build's libmesa_util.a. */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "util/u_queue.h"

#define QUEUES 40
#define FINISHES 250
#define JOBS 8

static volatile unsigned finishes;

static void
on_alarm(int sig)
{
   (void)sig;
   char msg[96];
   int n = snprintf(msg, sizeof msg, "FAIL: util_queue_finish hung after %u finishes\n", finishes);
   write(2, msg, n);
   _exit(1);
}

static void
job(void *data, void *gdata, int thread_index)
{
   (void)data; (void)gdata; (void)thread_index;
}

int
main(void)
{
   signal(SIGALRM, on_alarm);
   alarm(60);
   for (unsigned q = 0; q < QUEUES; q++) {
      struct util_queue queue;
      if (!util_queue_init(&queue, "finish", 64, 4, 0, NULL)) {
         fprintf(stderr, "FAIL: util_queue_init\n");
         return 1;
      }
      for (unsigned i = 0; i < FINISHES; i++) {
         struct util_queue_fence fences[JOBS];
         for (unsigned j = 0; j < JOBS; j++) {
            util_queue_fence_init(&fences[j]);
            /* a NULL job is skipped without signalling its fence */
            util_queue_add_job(&queue, &fences[j], &fences[j], job, NULL, 0);
         }
         util_queue_finish(&queue);
         for (unsigned j = 0; j < JOBS; j++) {
            if (!util_queue_fence_is_signalled(&fences[j])) {
               fprintf(stderr, "FAIL: a job queued before util_queue_finish is still pending\n");
               return 1;
            }
            util_queue_fence_destroy(&fences[j]);
         }
         finishes++;
      }
      util_queue_destroy(&queue);
   }
   printf("util_queue_finish: %u finishes of 4-thread queues passed\n", finishes);
   return 0;
}
