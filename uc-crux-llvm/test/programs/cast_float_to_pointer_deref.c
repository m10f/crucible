#include <stdint.h>
uintptr_t cast_float_to_uintptr_t(float f) __attribute__((noinline)) {
  return (uintptr_t)f;
}
int cast_float_to_pointer_deref(float x) {
  return *(int *)(void *)cast_float_to_uintptr_t(x);
}
