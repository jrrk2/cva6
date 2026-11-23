# Coherence test for a device on the data cache's device port (see tb_dcache_dev_port.sv).
#define DEV    0x30000000
#define KICK   0x00
#define STATUS 0x08
#define CHECK  0x10
#define XADDR  0x18
#define PASS   0x20
#define FAIL   0x28
#define CHECKED 0x30
#define XBASE  0x80008000
#define YBASE  0x80040000
#define N      400
  .globl _start
_start:
  li   s0, DEV
  li   s1, 0                # i
  li   s5, 0x5a5a5a5a5a5a5a5a
# ---- A: the device writes a word the cache holds; after the device says done, the core reads
#         the new value
loopA:
  addi s1, s1, 1
  li   t0, 40
  mul  t0, s1, t0
  andi t0, t0, 0x3f8
  li   s2, XBASE
  add  s2, s2, t0           # X
  sd   s2, XADDR(s0)
  ld   t1, 0(s2)            # in the cache now
  sd   s1, KICK(s0)
pollA:
  ld   t1, 0(s2)            # old or new, either is fine here
  li   t3, 1
1:                          # nine more lines of the same set: X is evicted and read again
  slli t4, t3, 12
  add  t4, t4, s2
  ld   t5, 0(t4)
  ld   t1, 0(s2)
  ld   t6, STATUS(s0)
  fence i, r                # as Linux's readl() has: memory reads that follow come after this device read
  beq  t6, s1, doneA
  addi t3, t3, 1
  li   t4, 10
  bne  t3, t4, 1b
  j    pollA
doneA:
  ld   t1, 0(s2)
  xor  t2, s1, s5
  bne  t1, t2, failA
  ld   t1, 8(s2)            # the word after it, also rewritten
  not  t2, t2
  bne  t1, t2, failA
  li   t0, N
  bne  s1, t0, loopA
# ---- B: stores to memory followed by a store to a device register: when the device sees the
#         register written, it reads everything stored before
  li   s1, 0
  li   s3, YBASE
loopB:
  addi s1, s1, 1
  slli t0, s1, 4
  li   t3, 0
1:
  add  t1, t0, t3           # value: 16 i + k
  li   t2, 24
  mul  t2, t2, t3
  add  t2, t2, s3
  sd   t1, 0(t2)            # at Y + 24 k
  addi t3, t3, 1
  li   t4, 8
  bne  t3, t4, 1b
  sd   s1, CHECK(s0)
4:
  ld   t6, CHECKED(s0)      # the device has read the eight words back
  bne  t6, s1, 4b
  andi t4, s1, 7            # then a few more stores that the next round's check does not look at
  beqz t4, 3f
2:
  slli t2, t4, 6
  add  t2, t2, s3
  sd   s1, 1024(t2)
  addi t4, t4, -1
  bnez t4, 2b
3:
  li   t0, N
  bne  s1, t0, loopB
  sd   s1, PASS(s0)
8: j 8b
failA:
  sd   s1, FAIL(s0)
9: j 9b
