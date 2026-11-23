// The boot ROM is linked without a C library, and newer compilers call memset for an array
// that is initialised to zero (sd.c has one).
#include <stddef.h>

__attribute__((optimize("no-tree-loop-distribute-patterns")))
void *memset(void *dst, int c, size_t n)
{
    unsigned char *d = dst;

    while (n--)
        *d++ = (unsigned char)c;
    return dst;
}
