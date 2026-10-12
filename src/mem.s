# =============================================================================
#  BeeModel - memory: bump arenas and pools with generational handles.
#
#  Arena  : reserve address space once (MAP_NORESERVE), bump-allocate, reset in
#           O(1). Memory touched beyond the warm size is handed back to the
#           kernel on reset, so a one-off spike does not stay resident.
#  Pool   : fixed-size slots, free list threaded through free slots, and a
#           handle = (generation << 24) | index so stale handles are detected.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

# exports
.globl arena_init
.globl arena_alloc
.globl arena_reset
.globl pool_init
.globl pool_alloc
.globl pool_free
.globl pool_get
.globl frame_arena

.equ MAP_RESERVE,   0x4022              # private | anonymous | noreserve
.equ MADV_DONTNEED, 4
.equ ARENA_WARM,    0x100000            # always keep the first 1 MiB resident
.equ ARENA_DECAY,   120                 # resets of low use before shrinking

.section .bss
.align 8
frame_arena:    .skip ARENA_SZ          # reset at the start of every frame

.text

# reserve(rsi=bytes) -> rax = address or 0
reserve:
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_RESERVE
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jbe     1f
    xor     eax, eax
1:  ret

# arena_init(rdi=arena, rsi=capacity) -> eax = 1 on success
arena_init:
    push    rbx
    mov     rbx, rdi
    mov     [rbx+AR_CAP], rsi
    call    reserve
    mov     [rbx+AR_BASE], rax
    xor     ecx, ecx
    mov     [rbx+AR_USED], rcx
    mov     [rbx+AR_PEAK], rcx
    mov     qword ptr [rbx+AR_WARM], ARENA_WARM
    mov     [rbx+AR_LOW], rcx
    test    rax, rax
    setnz   al
    movzx   eax, al
    pop     rbx
    ret

# arena_alloc(rdi=arena, rsi=bytes) -> rax = 16-byte aligned block or 0
arena_alloc:
    mov     rax, [rdi+AR_USED]
    add     rax, 15
    and     rax, -16
    lea     rdx, [rax+rsi]
    cmp     rdx, [rdi+AR_CAP]
    ja      8f
    mov     [rdi+AR_USED], rdx
    cmp     rdx, [rdi+AR_PEAK]
    jbe     1f
    mov     [rdi+AR_PEAK], rdx
1:  add     rax, [rdi+AR_BASE]
    ret
8:  xor     eax, eax
    ret

# arena_reset(rdi=arena) - O(1) reset. Pages stay resident while they are
# being used (no page faults every frame); after ARENA_DECAY resets that used
# less than half, everything above max(peak, 1 MiB) goes back to the kernel.
arena_reset:
    mov     rax, [rdi+AR_PEAK]
    mov     qword ptr [rdi+AR_USED], 0
    mov     qword ptr [rdi+AR_PEAK], 0
    mov     rcx, [rdi+AR_WARM]
    cmp     rax, rcx
    jbe     1f
    mov     [rdi+AR_WARM], rax          # grew: keep it all warm
    mov     qword ptr [rdi+AR_LOW], 0
    ret
1:  shr     rcx, 1
    cmp     rax, rcx
    jae     2f
    inc     qword ptr [rdi+AR_LOW]
    cmp     qword ptr [rdi+AR_LOW], ARENA_DECAY
    jb      9f
    mov     rcx, ARENA_WARM             # shrink to max(peak, 1 MiB)
    cmp     rax, rcx
    cmovb   rax, rcx
    add     rax, 4095
    and     rax, -4096
    mov     rsi, [rdi+AR_WARM]
    mov     [rdi+AR_WARM], rax
    mov     qword ptr [rdi+AR_LOW], 0
    sub     rsi, rax
    jbe     9f
    push    rdi
    add     rax, [rdi+AR_BASE]
    mov     rdi, rax
    mov     edx, MADV_DONTNEED
    mov     eax, SYS_MADVISE
    syscall
    pop     rdi
    ret
2:  mov     qword ptr [rdi+AR_LOW], 0
9:  ret

# -----------------------------------------------------------------------------
# pool_init(rdi=pool, esi=element size, edx=capacity) -> eax = 1 on success
#   layout: [capacity * elem] slots, then [capacity] generation bytes
# -----------------------------------------------------------------------------
pool_init:
    push    rbx
    mov     rbx, rdi
    add     esi, 3
    and     esi, -4                     # slots hold a u32 free-list link
    cmp     esi, 4
    jae     1f
    mov     esi, 4
1:  mov     [rbx+PL_ELEM], esi
    mov     [rbx+PL_CAP], edx
    mov     dword ptr [rbx+PL_COUNT], 0
    mov     dword ptr [rbx+PL_FREE], -1
    mov     dword ptr [rbx+PL_NEXT], 0
    mov     eax, esi
    imul    rax, rdx
    mov     rcx, rax                    # slot bytes
    add     rax, rdx                    # + generation bytes
    mov     rsi, rax
    push    rcx
    call    reserve
    pop     rcx
    mov     [rbx+PL_BASE], rax
    test    rax, rax
    jz      9f
    add     rax, rcx
    mov     [rbx+PL_GENS], rax
    mov     eax, 1
9:  pop     rbx
    ret

# pool_alloc(rdi=pool) -> eax = handle (0 = full); slot memory is zeroed
pool_alloc:
    mov     eax, [rdi+PL_FREE]
    cmp     eax, -1
    je      1f
    mov     ecx, eax                    # pop the free list
    imul    ecx, [rdi+PL_ELEM]
    add     rcx, [rdi+PL_BASE]
    mov     edx, [rcx]
    mov     [rdi+PL_FREE], edx
    jmp     2f
1:  mov     eax, [rdi+PL_NEXT]          # never-used slot
    cmp     eax, [rdi+PL_CAP]
    jae     8f
    inc     dword ptr [rdi+PL_NEXT]
2:  inc     dword ptr [rdi+PL_COUNT]
    mov     r8d, eax                    # zero the slot
    mov     ecx, [rdi+PL_ELEM]
    imul    r8d, ecx
    add     r8, [rdi+PL_BASE]
    push    rax
    push    rdi
    mov     rdi, r8
    xor     eax, eax
    rep     stosb
    pop     rdi
    pop     rax
    mov     rcx, [rdi+PL_GENS]
    movzx   edx, byte ptr [rcx+rax]
    test    edx, edx
    jnz     3f
    inc     edx                         # generation 0 is reserved (handle 0)
    mov     [rcx+rax], dl
3:  shl     edx, 24
    or      eax, edx
    ret
8:  xor     eax, eax
    ret

# pool_get(rdi=pool, esi=handle) -> rax = slot or 0 if the handle is stale
pool_get:
    mov     eax, esi
    and     eax, 0xffffff
    cmp     eax, [rdi+PL_NEXT]
    jae     8f
    mov     rcx, [rdi+PL_GENS]
    movzx   edx, byte ptr [rcx+rax]
    mov     ecx, esi
    shr     ecx, 24
    cmp     ecx, edx
    jne     8f
    test    ecx, ecx
    jz      8f
    imul    eax, [rdi+PL_ELEM]
    add     rax, [rdi+PL_BASE]
    ret
8:  xor     eax, eax
    ret

# pool_free(rdi=pool, esi=handle) -> eax = 1 if freed
pool_free:
    push    rsi
    call    pool_get
    pop     rsi
    test    rax, rax
    jz      9f
    mov     edx, [rdi+PL_FREE]          # push on the free list
    mov     [rax], edx
    mov     eax, esi
    and     eax, 0xffffff
    mov     [rdi+PL_FREE], eax
    mov     rcx, [rdi+PL_GENS]
    mov     dl, [rcx+rax]               # bump the generation (skipping 0)
    inc     dl
    jnz     1f
    inc     dl
1:  mov     [rcx+rax], dl
    dec     dword ptr [rdi+PL_COUNT]
    mov     eax, 1
9:  ret

.section .note.GNU-stack,"",@progbits
