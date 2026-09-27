#ifndef RUNNER_WINDOWS_PROCESS_MEMORY_H_
#define RUNNER_WINDOWS_PROCESS_MEMORY_H_

#include <cstdint>

// Память и ресурсы процесса для слепков в app.log (MemoryWatch в Dart).
//
// private_bytes — выделенная память (commit): её Windows и считает занятой, и
// её же называет событие 2004 при нехватке памяти. Рабочий набор бывает много
// меньше: после сна страницы уходят в файл подкачки, а commit остаётся.
struct ProcessResources {
  bool ok = false;
  uint64_t private_bytes = 0;
  uint64_t working_set = 0;
  uint64_t peak_working_set = 0;
  uint32_t handles = 0;
  uint32_t threads = 0;
  uint32_t gdi_objects = 0;
  uint32_t user_objects = 0;
};

// pid 0 — сам keqdroid.exe.
ProcessResources QueryProcessResources(uint32_t pid);

#endif  // RUNNER_WINDOWS_PROCESS_MEMORY_H_
