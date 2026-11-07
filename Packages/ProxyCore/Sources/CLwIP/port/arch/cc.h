#ifndef PASSAGE_ARCH_CC_H
#define PASSAGE_ARCH_CC_H

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <sys/time.h>

#define LWIP_TIMEVAL_PRIVATE 0
#define LWIP_RAND() ((u32_t)arc4random())
#define LWIP_PLATFORM_DIAG(x) do { printf x; } while (0)
#define LWIP_PLATFORM_ASSERT(x) do { fprintf(stderr, "lwIP assert: %s (%s:%d)\n", x, __FILE__, __LINE__); abort(); } while (0)
#ifdef NDEBUG
#define LWIP_NOASSERT 1
#endif

#endif
