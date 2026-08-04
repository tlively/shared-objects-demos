#include <pthread.h>
#include <stdlib.h>
#include <emscripten.h>

// Internal Emscripten function to check if current thread supports atomics.wait
int _emscripten_thread_supports_atomics_wait(void);

// Console log helper provided in libruntime.js
void console_log(const char* str);

// Wasm GC entry points imported from the Wasm GC runtime layer (module "wat")
__attribute__((import_module("wat"))) void wasm_main(void);
__attribute__((import_module("wat"))) void wasm_thread_entry(void);

// Thread entry trampoline that invokes the Wasm GC thread entry point on workers.
static void* thread_start_routine(void* arg) {
  (void)arg;
  wasm_thread_entry();
  return NULL;
}

// Runtime helpers exported for Wasm GC consumption

EMSCRIPTEN_KEEPALIVE
void runtime_console_log(const char* str) {
  console_log(str);
}

EMSCRIPTEN_KEEPALIVE
int runtime_pthread_create(void) {
  pthread_t thread;
  if (pthread_create(&thread, NULL, thread_start_routine, NULL) != 0) {
    return 0;
  }
  return (int)thread;
}

EMSCRIPTEN_KEEPALIVE
int runtime_pthread_join(int thread) {
  return pthread_join((pthread_t)thread, NULL);
}

EMSCRIPTEN_KEEPALIVE
int runtime_thread_supports_wait(void) {
  return _emscripten_thread_supports_atomics_wait();
}

int main(void) {
  wasm_main();
  emscripten_exit_with_live_runtime();
  return 0;
}
