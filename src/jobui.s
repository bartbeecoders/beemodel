# =============================================================================
#  BeeModel - long jobs in the status bar: a bake (maps, light probes, a
#  lightmap, a simulation) or an import runs on the UI thread, so the window
#  would freeze until it ends. job_begin / job_end bracket one; while it
#  runs, the UI thread presents a frame at most every 100 ms (from
#  parallel_for between chunks, or job_set), with a chip showing the job and
#  how far it is. Input is ignored meanwhile, but for Esc, which sets
#  job_stop for a job that can stop (a render of an animation); nothing
#  else (MCP, timers) runs. A job asked for by a key or a
#  click (inside the Wayland event dispatch, which its frames need) is run
#  from the main loop instead (job_defer / job_pending).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl job_on
.globl job_label
.globl job_frac
.globl job_begin
.globl job_end
.globl job_stage
.globl job_set
.globl job_pf
.globl job_ignore
.globl job_key
.globl job_stop
.globl job_defer
.globl job_pending
.globl wl_dispatching


.section .data
.align 4
job_on:         .long 0
job_stop:       .long 0                 # Esc during the job
job_frac:       .float -1.0             # 0..1, or < 0: unknown
job_base:       .float 0.0              # the stage running: where it starts
job_span:       .float 1.0              #  and how much of the job it is
.align 8
job_label:      .quad 0
job_t:          .quad 0
wl_dispatching: .long 0                 # (main.s: Wayland events being dispatched)
.section .bss
.align 8
job_q_op:       .skip 8                 # a job asked for during the dispatch
job_q_hasarg:   .skip 8
job_q_arg:      .skip 512
.section .rodata
.align 4
jf_zero:        .float 0.0
jf_one:         .float 1.0
jf_unknown:     .float -1.0

.text
# job_ignore - (input handlers while a job runs) nothing
job_ignore:
    ret

# job_key(edi=evdev) - (a key while a job runs) Esc asks it to stop
job_key:
    cmp     edi, KEY_ESC
    jne     9f
    mov     dword ptr [rip+job_stop], 1
9:  ret

# job_begin(rdi=label) - a job starts: its chip, at once
job_begin:
    sub     rsp, 8
    mov     [rip+job_label], rdi
    mov     dword ptr [rip+job_on], 1
    mov     dword ptr [rip+job_stop], 0
    mov     eax, [rip+jf_zero]
    mov     [rip+job_base], eax
    mov     eax, [rip+jf_one]
    mov     [rip+job_span], eax
    mov     eax, [rip+jf_unknown]
    mov     [rip+job_frac], eax
    mov     qword ptr [rip+job_t], 0
    call    job_tick
    add     rsp, 8
    ret

# job_end - it is over: the chip goes, the window draws again
job_end:
    mov     dword ptr [rip+job_on], 0
    mov     dword ptr [rip+job_stop], 0
    mov     dword ptr [rip+dirty], 1
    ret

# job_stage(xmm0=start, xmm1=share) - the next stage of the job (0..1)
job_stage:
    movss   [rip+job_base], xmm0
    movss   [rip+job_span], xmm1
    movss   [rip+job_frac], xmm0
    jmp     job_tick

# job_set(xmm0=0..1 of the stage) - how far the stage is
job_set:
    cmp     dword ptr [rip+job_on], 0
    je      9f
    minss   xmm0, [rip+jf_one]
    maxss   xmm0, [rip+jf_zero]
    mulss   xmm0, [rip+job_span]
    addss   xmm0, [rip+job_base]
    movss   [rip+job_frac], xmm0
    jmp     job_tick
9:  ret

# job_pf(edi=done, esi=count) - (parallel_for, between chunks) the stage's
#   share done
job_pf:
    cmp     dword ptr [rip+job_on], 0
    je      9f
    test    esi, esi
    jz      9f
    cvtsi2ss xmm0, edi
    cvtsi2ss xmm1, esi
    divss   xmm0, xmm1
    jmp     job_set
9:  ret

# job_defer(rdi=the operator's exec) - (inside the event dispatch) run it
#   from the main loop, with this argument
job_defer:
    push    rbx
    lea     rbx, [rip+__start_bee_ops]  # which operator
1:  lea     rax, [rip+__stop_bee_ops]
    cmp     rbx, rax
    jae     9f
    cmp     [rbx+OP_EXEC], rdi
    je      2f
    add     rbx, OP_SIZE
    jmp     1b
2:  mov     [rip+job_q_op], rbx
    mov     qword ptr [rip+job_q_hasarg], 0
    mov     rsi, [rip+op_arg]           # its argument, kept
    test    rsi, rsi
    jz      4f
    mov     qword ptr [rip+job_q_hasarg], 1
    lea     rdi, [rip+job_q_arg]
    xor     ecx, ecx
3:  mov     al, [rsi+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      4f
    inc     ecx
    cmp     ecx, 511
    jb      3b
    mov     byte ptr [rdi+rcx], 0
4:  test    dword ptr [rbx+OP_FLAGS], OPF_UNDO  # (its undo step comes then)
    jz      9f
    call    undo_drop_last
9:  mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

# job_pending - (the main loop) a deferred job runs now
job_pending:
    mov     rdi, [rip+job_q_op]
    test    rdi, rdi
    jz      9f
    mov     qword ptr [rip+job_q_op], 0
    push    qword ptr [rip+op_arg]
    xor     eax, eax
    cmp     qword ptr [rip+job_q_hasarg], 0
    je      1f
    lea     rax, [rip+job_q_arg]
1:  mov     [rip+op_arg], rax
    call    run_op
    pop     qword ptr [rip+op_arg]
    mov     dword ptr [rip+dirty], 1
9:  ret

# job_tick - a frame, when 100 ms have passed (the UI thread only)
job_tick:
    cmp     dword ptr [rip+job_on], 0
    je      9f
    push    rbx
    call    mono_ns
    mov     rbx, rax
    sub     rax, [rip+job_t]
    cmp     rax, 100000000
    jb      8f
    call    plat_gettid
    cmp     eax, [rip+main_tid]
    jne     8f
    mov     [rip+job_t], rbx
    call    job_present
8:  pop     rbx
9:  ret

# job_present - the compositor's news (frame callbacks, released buffers;
#   input is dropped), then a frame if it may draw one
job_present:
    sub     rsp, 8
    cmp     dword ptr [rip+configured], 0
    je      9f
    call    wnd_pump                    # (no waiting)
    mov     dword ptr [rip+dirty], 1
    call    render
    call    wnd_flush
9:  add     rsp, 8
    ret

.section .note.GNU-stack,"",@progbits
