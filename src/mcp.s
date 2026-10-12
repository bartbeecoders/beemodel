# =============================================================================
#  BeeModel - MCP server (Model Context Protocol) for AI agents.
#
#  The running app listens on a unix socket ($XDG_RUNTIME_DIR/beemodel.sock
#  -> beemodel-<pid>.sock). Messages are newline-delimited JSON-RPC 2.0, the
#  same framing as the MCP stdio transport, so `beemodel --mcp-bridge` only
#  relays bytes between stdin/stdout and the socket. Requests run on the UI
#  thread from the main poll loop: no locking, and every change goes through
#  the operator spine and the undo history like a user action.
#
#  Tools: curated scene tools + every operator flagged OPF_AI_SAFE
#  (op_<id with dots as underscores>). Resource: bee://scene.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl mcp_init
.globl mcp_shutdown
.globl mcp_pollfds
.globl mcp_handle
.globl mcp_bridge
.globl mcp_clients

.equ MAX_CLIENTS,   4
.equ CIN_CAP,       0x40000             # 256 KiB per client request buffer
.equ SYS_ACCEPT4,   288
.equ SYS_BIND,      49
.equ SYS_LISTEN,    50
.equ SYS_UNLINK,    87
.equ SYS_SYMLINK,   88
.equ SYS_GETPID,    39
.equ SYS_NANOSLEEP, 35
.equ SOCK_SERVER,   0x80801             # STREAM | NONBLOCK | CLOEXEC
.equ SOCK_CLIENT,   0x80001             # STREAM | CLOEXEC

.section .data
.align 4
lsock:          .long -1
cl_fd:          .long -1, -1, -1, -1

.section .bss
.align 8
out_state:      .skip 24                # response buffer (swapped with wb)
txt_state:      .skip 24                # tool text buffer
img_state:      .skip 24                # PNG of a capture
tool_op:        .skip 8
agent_label:    .skip 112
has_image:      .skip 4
cl_len:         .skip 8*MAX_CLIENTS
cl_buf:         .skip CIN_CAP*MAX_CLIENTS
addr:           .skip 112
sock_path:      .skip 120
link_path:      .skip 120
method:         .skip 64
tool:           .skip 96
sbuf1:          .skip 512
sbuf2:          .skip 512
id_ptr:         .skip 8
id_len:         .skip 8
msg_start:      .skip 8
params:         .skip 8
targs:          .skip 8
log_mark:       .skip 4
is_error:       .skip 4
cur_client:     .skip 4
vec:            .skip 12
iobuf:          .skip 65536
bpoll:          .skip 16

.section .rodata
s_xdg:          .asciz "XDG_RUNTIME_DIR="
s_tmp:          .asciz "/tmp"
s_sock_pfx:     .asciz "/beemodel-"
s_sock_sfx:     .asciz ".sock"
s_link:         .asciz "/beemodel.sock"
s_env_sock:     .asciz "BEEMODEL_SOCKET="
s_env_off:      .asciz "BEEMODEL_NO_MCP="
s_listening:    .asciz "MCP server ready: connect agents with beemodel --mcp-bridge"
s_mcp_call:     .asciz "  mcp: "
s_bridge_err:   .asciz "beemodel: no running BeeModel to bridge to (start it first)\n"
# JSON keys / values
k_method:       .asciz "method"
k_id:           .asciz "id"
k_params:       .asciz "params"
k_name:         .asciz "name"
k_arguments:    .asciz "arguments"
k_pv:           .asciz "protocolVersion"
k_uri:          .asciz "uri"
k_type:         .asciz "type"
k_location:     .asciz "location"
k_rotation:     .asciz "rotation_deg"
k_scale:        .asciz "scale"
k_names:        .asciz "names"
k_extend:       .asciz "extend"
k_arg:          .asciz "arg"
m_initialize:   .asciz "initialize"
m_ping:         .asciz "ping"
m_tools_list:   .asciz "tools/list"
m_tools_call:   .asciz "tools/call"
m_res_list:     .asciz "resources/list"
m_res_read:     .asciz "resources/read"
s_pv_default:   .asciz "2025-06-18"
s_uri_scene:    .asciz "bee://scene"
r_head:         .asciz "{\"jsonrpc\":\"2.0\",\"id\":"
r_result:       .asciz ",\"result\":"
r_tail:         .asciz "}\n"
r_err_parse:    .asciz ",\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}\n"
r_err_invalid:  .asciz ",\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"}}\n"
r_null:         .asciz "null"
k_result:       .asciz "result"
k_error:        .asciz "error"
r_err_method:   .asciz ",\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}\n"
r_empty:        .asciz "{}"
r_init_a:       .asciz "{\"protocolVersion\":"
r_init_b:       .asciz ",\"capabilities\":{\"tools\":{},\"resources\":{}},\"serverInfo\":{\"name\":\"beemodel\",\"version\":"
r_init_c:       .asciz "},\"instructions\":\"BeeModel is a 3D modeler. Units are meters, Y is up, rotations are Euler XYZ in degrees (rotation_deg). Every change is undoable (undo tool). Start with scene_summary; create objects with create_primitive, place them with set_transform; use script_eval (BeeScript) for loops and bulk edits; look at the result with viewport_capture.\"}"
r_tools_a:      .asciz "{\"tools\":["
r_tools_b:      .asciz "]}"
r_content_a:    .asciz "{\"content\":[{\"type\":\"text\",\"text\":"
r_content_b:    .asciz "}"
r_content_c:    .asciz "],\"isError\":"
r_true:         .asciz "true"
r_false:        .asciz "false"
r_res_list:     .asciz "{\"resources\":[{\"uri\":\"bee://scene\",\"name\":\"Scene\",\"description\":\"Objects, transforms and mesh sizes as JSON\",\"mimeType\":\"application/json\"}]}"
r_res_a:        .asciz "{\"contents\":[{\"uri\":\"bee://scene\",\"mimeType\":\"application/json\",\"text\":"
r_res_b:        .asciz "}]}"
t_op_a:         .asciz "{\"name\":"
t_op_b:         .asciz ",\"description\":"
t_op_c:         .asciz ",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"arg\":{\"type\":\"string\",\"description\":\"optional argument, e.g. a file path\"}}}}"
s_op_prefix:    .asciz "op_"
s_dash:         .asciz " - "
# curated tools (schemas are static JSON)
curated_tools:
    .ascii "{\"name\":\"scene_summary\",\"description\":\"List every object: name, type, location, rotation_deg, scale, selection and mesh size.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},"
    .ascii "{\"name\":\"create_primitive\",\"description\":\"Add an object. type: cube, sphere, cylinder, cone, torus, plane, grid, light or camera. Default size: 2 m cube / 1 m radius. Optional name, location, rotation_deg, scale (3 numbers each).\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"type\":{\"type\":\"string\",\"enum\":[\"cube\",\"sphere\",\"cylinder\",\"cone\",\"torus\",\"plane\",\"grid\",\"light\",\"camera\"]},\"name\":{\"type\":\"string\"},\"location\":{\"type\":\"array\",\"items\":{\"type\":\"number\"}},\"rotation_deg\":{\"type\":\"array\",\"items\":{\"type\":\"number\"}},\"scale\":{\"type\":\"array\",\"items\":{\"type\":\"number\"}}},\"required\":[\"type\"]}},"
    .ascii "{\"name\":\"set_transform\",\"description\":\"Change an object's location, rotation_deg and/or scale (3 numbers each), or rename it with new_name.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"new_name\":{\"type\":\"string\"},\"location\":{\"type\":\"array\",\"items\":{\"type\":\"number\"}},\"rotation_deg\":{\"type\":\"array\",\"items\":{\"type\":\"number\"}},\"scale\":{\"type\":\"array\",\"items\":{\"type\":\"number\"}}},\"required\":[\"name\"]}},"
    .ascii "{\"name\":\"select\",\"description\":\"Select objects by name (the last one becomes active). extend keeps the current selection.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"names\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"extend\":{\"type\":\"boolean\"}},\"required\":[\"names\"]}},"
    .ascii "{\"name\":\"delete\",\"description\":\"Delete objects by name.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"names\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},\"required\":[\"names\"]}},"
    .ascii "{\"name\":\"run_operator\",\"description\":\"Run any BeeModel operator by id (see console.list_ops), with an optional text argument such as a file path.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"arg\":{\"type\":\"string\"}},\"required\":[\"id\"]}},"
    .ascii "{\"name\":\"viewport_capture\",\"description\":\"Look at the scene: a PNG image of the 3D viewport as it is now (area: viewport or window).\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"area\":{\"type\":\"string\",\"enum\":[\"viewport\",\"window\"]}}}},"
    .ascii "{\"name\":\"script_eval\",\"description\":\"Run BeeScript, BeeModel's scripting language, as one undo step; returns what it prints plus the last value. Best for bulk or procedural edits. Syntax: x = 2m; for i in 0..10 { add(\\\"cube\\\", \\\"C\\\" + i, i * 2, 0, 0) }; if a > 1 and b { } else { }; while c { }; fn f(a) { return a * 2 }. Units: m cm mm km deg rad (angles are radians, 45deg works). Scene: add(type, [name], [x, y, z]) -> name; move / rotate / scale(name, x, y, z); scale(name, s); get(name, prop) and set(name, prop, v) with prop x y z rx ry rz sx sy sz; select(names...); delete(names...); rename(old, new); exists(name); count(); name(i); active(); op(id, [arg]). Also print(...), str, num, len, sin, cos, tan, sqrt, abs, floor, round, min, max, pow, atan2, deg, rad, rand, seed, pi.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"code\":{\"type\":\"string\",\"description\":\"BeeScript source\"}},\"required\":[\"code\"]}},"
    .ascii "{\"name\":\"undo\",\"description\":\"Undo the last change.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},"
    .asciz "{\"name\":\"redo\",\"description\":\"Redo the last undone change.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}"
c_scene:        .asciz "scene_summary"
c_create:       .asciz "create_primitive"
c_xform:        .asciz "set_transform"
c_select:       .asciz "select"
c_delete:       .asciz "delete"
c_run:          .asciz "run_operator"
c_undo:         .asciz "undo"
c_capture:      .asciz "viewport_capture"
c_script:       .asciz "script_eval"
s_agent_pfx:    .asciz "Agent: "
e_perm_a:       .asciz "permission denied: "
e_perm_b:       .asciz " needs the '"
e_perm_c:       .asciz "' permission and agents are set to '"
e_perm_d:       .asciz "'. The user can change this in BeeModel's AI menu."
k_code:         .asciz "code"
k_area:         .asciz "area"
s_window:       .asciz "window"
s_capture:      .asciz "PNG capture "
s_x_:           .asciz " x "
s_px:           .asciz " px"
r_img_a:        .asciz ",{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\""
r_img_b:        .asciz "\"}"
b64:            .ascii "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
c_redo:         .asciz "redo"
k_new_name:     .asciz "new_name"
k_idkey:        .asciz "id"
s_create_pfx:   .asciz "create."
s_edit_undo:    .asciz "edit.undo"
s_edit_redo:    .asciz "edit.redo"
s_set_xform:    .asciz "Set Transform"
e_unknown_tool: .asciz "unknown tool: "
e_no_object:    .asciz "no object named "
e_bad_type:     .asciz "unknown primitive type: "
e_no_op:        .asciz "unknown or not agent-safe operator: "
e_missing:      .asciz "missing argument"
s_ok:           .asciz "ok"
# scene summary JSON pieces
j_objs_a:       .asciz "{\"units\":\"meters, Y up, rotation_deg = Euler XYZ\",\"objects\":["
j_objs_b:       .asciz "]}"
j_type_names:   .asciz "mesh"
                .asciz "light"
                .asciz "camera"
j_selected:     .asciz ",\"selected\":"
j_active:       .asciz ",\"active\":"
j_verts:        .asciz ",\"vertices\":"
j_faces:        .asciz ",\"faces\":"
j_mods:         .asciz ",\"modifiers\":["
.align 4
f_deg2rad:      .float 0.017453293
f_rad2deg_:     .float 57.29578
.align 8
type_name_ptrs: .quad j_type_names, j_type_names+5, j_type_names+11
nanos:          .quad 0, 100000000      # 100 ms

.text

# cat(rdi=dest cursor, rsi=asciz) -> rdi after the copied text (terminated)
cat:
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rdi
    inc     rsi
    jmp     1b
2:  ret

# runtime_dir(rdi=dest) -> rdi at the end of "$XDG_RUNTIME_DIR"
runtime_dir:
    push    rdi
    lea     rdi, [rip+s_xdg]
    call    getenv
    pop     rdi
    test    rax, rax
    jz      1f
    cmp     byte ptr [rax], 0
    jne     2f
1:  lea     rax, [rip+s_tmp]
2:  mov     rsi, rax
    jmp     cat

# sockaddr(rsi=path) -> addr filled (AF_UNIX + path)
sockaddr:
    lea     rdi, [rip+addr]
    mov     word ptr [rdi], AF_UNIX
    add     rdi, 2
    jmp     cat

# -----------------------------------------------------------------------------
# mcp_init - start listening (BEEMODEL_NO_MCP=1 disables)
# -----------------------------------------------------------------------------
mcp_init:
    push    rbx
    call    agent_init
    lea     rdi, [rip+s_env_off]
    call    getenv
    test    rax, rax
    jz      1f
    cmp     byte ptr [rax], '1'
    je      9f
1:  lea     rdi, [rip+sock_path]        # $XDG_RUNTIME_DIR/beemodel-<pid>.sock
    call    runtime_dir
    lea     rsi, [rip+s_sock_pfx]
    call    cat
    push    rdi
    mov     eax, SYS_GETPID
    syscall
    pop     rdi
    sub     rsp, 16                     # pid digits
    xor     ecx, ecx
    mov     r8d, 10
2:  xor     edx, edx
    div     r8d
    add     dl, '0'
    mov     [rsp+rcx], dl
    inc     ecx
    test    eax, eax
    jnz     2b
3:  dec     ecx
    mov     al, [rsp+rcx]
    mov     [rdi], al
    inc     rdi
    test    ecx, ecx
    jnz     3b
    add     rsp, 16
    lea     rsi, [rip+s_sock_sfx]
    call    cat
    lea     rdi, [rip+link_path]
    call    runtime_dir
    lea     rsi, [rip+s_link]
    call    cat
    lea     rdi, [rip+sock_path]        # stale socket of a crashed run
    mov     eax, SYS_UNLINK
    syscall
    mov     edi, AF_UNIX
    mov     esi, SOCK_SERVER
    xor     edx, edx
    mov     eax, SYS_SOCKET
    syscall
    test    eax, eax
    js      9f
    mov     ebx, eax
    lea     rsi, [rip+sock_path]
    call    sockaddr
    mov     edi, ebx
    lea     rsi, [rip+addr]
    mov     edx, 110
    mov     eax, SYS_BIND
    syscall
    test    eax, eax
    jnz     8f
    mov     edi, ebx
    mov     esi, MAX_CLIENTS
    mov     eax, SYS_LISTEN
    syscall
    test    eax, eax
    jnz     8f
    mov     [rip+lsock], ebx
    lea     rdi, [rip+link_path]        # the newest instance owns beemodel.sock
    mov     eax, SYS_UNLINK
    syscall
    lea     rdi, [rip+sock_path]
    lea     rsi, [rip+link_path]
    mov     eax, SYS_SYMLINK
    syscall
    lea     rdi, [rip+s_listening]      # (path in the README; keeps output stable)
    call    log_line
    jmp     9f
8:  mov     edi, ebx
    mov     eax, SYS_CLOSE
    syscall
9:  pop     rbx
    ret

mcp_shutdown:
    cmp     dword ptr [rip+lsock], 0
    jl      9f
    lea     rdi, [rip+link_path]
    mov     eax, SYS_UNLINK
    syscall
    lea     rdi, [rip+sock_path]
    mov     eax, SYS_UNLINK
    syscall
9:  ret

# mcp_pollfds(rdi=pollfd array) -> eax = entries written (listen + clients)
mcp_pollfds:
    xor     eax, eax
    mov     ecx, [rip+lsock]
    test    ecx, ecx
    js      9f
    mov     [rdi], ecx
    mov     dword ptr [rdi+4], POLLIN
    inc     eax
    xor     edx, edx
1:  lea     rcx, [rip+cl_fd]
    mov     ecx, [rcx+rdx*4]
    test    ecx, ecx
    js      2f
    mov     [rdi+rax*8], ecx
    mov     dword ptr [rdi+rax*8+4], POLLIN
    inc     eax
2:  inc     edx
    cmp     edx, MAX_CLIENTS
    jb      1b
9:  ret

# mcp_handle(rdi=pollfd array as filled by mcp_pollfds)
mcp_handle:
    push    rbx
    push    r12
    push    r13
    cmp     dword ptr [rip+lsock], 0
    jl      9f
    mov     r12, rdi
    test    word ptr [r12+6], POLLIN    # new connection
    jz      2f
    mov     edi, [rip+lsock]
    xor     esi, esi
    xor     edx, edx
    mov     r10d, 0x80000               # SOCK_CLOEXEC
    mov     eax, SYS_ACCEPT4
    syscall
    test    eax, eax
    js      2f
    xor     ecx, ecx
1:  lea     rdx, [rip+cl_fd]
    cmp     dword ptr [rdx+rcx*4], 0
    jl      11f
    inc     ecx
    cmp     ecx, MAX_CLIENTS
    jb      1b
    mov     edi, eax                    # full
    mov     eax, SYS_CLOSE
    syscall
    jmp     2f
11: mov     [rdx+rcx*4], eax
    lea     rdx, [rip+cl_len]
    mov     qword ptr [rdx+rcx*8], 0
2:  mov     r13d, 1                     # client entries follow in slot order
    xor     ebx, ebx
3:  cmp     ebx, MAX_CLIENTS
    jae     9f
    lea     rax, [rip+cl_fd]
    mov     eax, [rax+rbx*4]
    test    eax, eax
    js      5f
    cmp     [r12+r13*8], eax            # (only slots polled this round)
    jne     5f
    test    word ptr [r12+r13*8+6], POLLIN|POLLERR|POLLHUP
    jz      4f
    mov     edi, ebx
    call    client_read
4:  inc     r13d
5:  inc     ebx
    jmp     3b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# client_read(edi=slot) - read, then run every complete line
client_read:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    mov     r12, rbx
    imul    r12, r12, CIN_CAP
    lea     rax, [rip+cl_buf]
    add     r12, rax                    # buffer
    lea     r13, [rip+cl_len]
    lea     r13, [r13+rbx*8]            # &length
    lea     rax, [rip+cl_fd]
    mov     edi, [rax+rbx*4]
    mov     rsi, r12
    add     rsi, [r13]
    mov     edx, CIN_CAP
    sub     rdx, [r13]
    jz      7f                          # a line larger than the buffer
    xor     eax, eax                    # SYS_READ
    syscall
    test    rax, rax
    jle     7f
    add     [r13], rax
1:  mov     rcx, [r13]                  # complete lines
    xor     edx, edx
2:  cmp     rdx, rcx
    jae     6f
    cmp     byte ptr [r12+rdx], 10
    je      3f
    inc     rdx
    jmp     2b
3:  mov     r14, rdx                    # line [0, rdx)
    mov     [rip+cur_client], ebx
    mov     rdi, r12
    mov     rsi, rdx
    call    handle_message
    lea     rsi, [r12+r14+1]            # drop it
    mov     rcx, [r13]
    sub     rcx, r14
    dec     rcx
    mov     [r13], rcx
    mov     rdi, r12
    rep     movsb
    jmp     1b
6:  jmp     9f
7:  lea     rax, [rip+cl_fd]            # closed or broken: forget the client
    mov     edi, [rax+rbx*4]
    mov     dword ptr [rax+rbx*4], -1
    mov     eax, SYS_CLOSE
    syscall
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# send_out - write the response buffer to the current client
send_out:
    push    rbx
    push    r12
    mov     ecx, [rip+cur_client]
    lea     rax, [rip+cl_fd]
    mov     ebx, [rax+rcx*4]
    mov     r12, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
1:  test    rdx, rdx
    jz      9f
    push    rdx
    mov     edi, ebx
    mov     rsi, r12
    mov     eax, SYS_WRITE
    syscall
    pop     rdx
    cmp     rax, -4
    je      1b
    test    rax, rax
    jle     9f
    add     r12, rax
    sub     rdx, rax
    jmp     1b
9:  pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# handle_message(rdi=text, rsi=length) - one JSON-RPC message
# -----------------------------------------------------------------------------
handle_message:
    push    rbx
    push    r12
    mov     [rip+msg_start], rdi
    lea     rax, [rdi+rsi]
    mov     [rip+j_end], rax
    mov     qword ptr [rip+id_ptr], 0
    mov     rsi, rdi                    # strict syntax check first
    mov     rdx, rax
    call    j_valid
    test    eax, eax
    jz      .Lhm_parse
    mov     rsi, [rip+msg_start]        # a single object (no batches)
    call    j_ws
    cmp     byte ptr [rsi], '{'
    jne     .Lhm_invalid
    mov     byte ptr [rip+method], 0
    mov     qword ptr [rip+id_ptr], 0
    mov     qword ptr [rip+params], 0
    mov     rsi, [rip+msg_start]
    lea     rdi, [rip+k_method]
    call    j_find
    test    rax, rax
    jz      1f
    mov     rsi, rax
    lea     rdi, [rip+method]
    mov     edx, 64
    call    j_str
1:  mov     rsi, [rip+msg_start]
    lea     rdi, [rip+k_id]
    call    j_find
    test    rax, rax
    jz      2f
    mov     [rip+id_ptr], rax           # raw id text, echoed back verbatim
    mov     rsi, rax
    call    j_skip
    sub     rsi, [rip+id_ptr]
    mov     [rip+id_len], rsi
2:  mov     rsi, [rip+msg_start]
    lea     rdi, [rip+k_params]
    call    j_find
    mov     [rip+params], rax
    cmp     qword ptr [rip+id_ptr], 0
    je      9f                          # notifications get no answer
    cmp     byte ptr [rip+method], 0
    jne     3f
    mov     rsi, [rip+msg_start]        # no method: a response to us is fine,
    lea     rdi, [rip+k_result]         # anything else is an invalid request
    call    j_find
    test    rax, rax
    jnz     9f
    mov     rsi, [rip+msg_start]
    lea     rdi, [rip+k_error]
    call    j_find
    test    rax, rax
    jnz     9f
    jmp     .Lhm_invalid
3:
    lea     rdi, [rip+out_state]        # build the response in our buffer
    call    buf_swap
    call    wb_reset
    lea     rsi, [rip+r_head]
    call    wb_str
    mov     rsi, [rip+id_ptr]
    mov     rdx, [rip+id_len]
    call    wb_bytes
    lea     rdi, [rip+method]
    lea     rsi, [rip+m_initialize]
    call    str_eq
    test    eax, eax
    jnz     .Lhm_init
    lea     rdi, [rip+method]
    lea     rsi, [rip+m_ping]
    call    str_eq
    test    eax, eax
    jnz     .Lhm_ping
    lea     rdi, [rip+method]
    lea     rsi, [rip+m_tools_list]
    call    str_eq
    test    eax, eax
    jnz     .Lhm_tlist
    lea     rdi, [rip+method]
    lea     rsi, [rip+m_tools_call]
    call    str_eq
    test    eax, eax
    jnz     .Lhm_tcall
    lea     rdi, [rip+method]
    lea     rsi, [rip+m_res_list]
    call    str_eq
    test    eax, eax
    jnz     .Lhm_rlist
    lea     rdi, [rip+method]
    lea     rsi, [rip+m_res_read]
    call    str_eq
    test    eax, eax
    jnz     .Lhm_rread
    lea     rsi, [rip+r_err_method]
    call    wb_str
    jmp     .Lhm_send

.Lhm_init:
    lea     rsi, [rip+r_result]
    call    wb_str
    lea     rsi, [rip+r_init_a]
    call    wb_str
    lea     rsi, [rip+s_pv_default]     # echo the client's protocol version
    mov     rax, [rip+params]
    test    rax, rax
    jz      1f
    mov     rsi, rax
    lea     rdi, [rip+k_pv]
    call    j_find
    test    rax, rax
    jz      11f
    mov     rsi, rax
    lea     rdi, [rip+sbuf1]
    mov     edx, 64
    call    j_str
    test    eax, eax
    jle     11f
    lea     rsi, [rip+sbuf1]
    jmp     1f
11: lea     rsi, [rip+s_pv_default]
1:  call    jb_q
    lea     rsi, [rip+r_init_b]
    call    wb_str
    lea     rsi, [rip+s_version]
    call    jb_q
    lea     rsi, [rip+r_init_c]
    call    wb_str
    jmp     .Lhm_end
.Lhm_ping:
    lea     rsi, [rip+r_result]
    call    wb_str
    lea     rsi, [rip+r_empty]
    call    wb_str
    jmp     .Lhm_end
.Lhm_tlist:
    lea     rsi, [rip+r_result]
    call    wb_str
    call    tools_list
    jmp     .Lhm_end
.Lhm_tcall:
    lea     rsi, [rip+r_result]
    call    wb_str
    call    tools_call
    jmp     .Lhm_end
.Lhm_rlist:
    lea     rsi, [rip+r_result]
    call    wb_str
    lea     rsi, [rip+r_res_list]
    call    wb_str
    jmp     .Lhm_end
.Lhm_rread:
    lea     rsi, [rip+r_result]
    call    wb_str
    lea     rdi, [rip+txt_state]        # summary into the text buffer
    call    buf_swap
    call    wb_reset
    call    scene_json
    xor     edi, edi
    call    wb_char
    lea     rdi, [rip+txt_state]        # back to the response
    call    buf_swap
    lea     rsi, [rip+r_res_a]
    call    wb_str
    mov     rsi, [rip+txt_state]
    call    jb_q
    lea     rsi, [rip+r_res_b]
    call    wb_str
.Lhm_end:
    lea     rsi, [rip+r_tail]
    call    wb_str
    jmp     .Lhm_send
.Lhm_parse:                             # -32700, id null
    lea     rdi, [rip+r_err_parse]
    jmp     1f
.Lhm_invalid:                           # -32600, with the id if there is one
    lea     rdi, [rip+r_err_invalid]
1:  push    rdi
    lea     rdi, [rip+out_state]
    call    buf_swap
    call    wb_reset
    lea     rsi, [rip+r_head]
    call    wb_str
    mov     rsi, [rip+id_ptr]
    test    rsi, rsi
    jz      2f
    mov     rdx, [rip+id_len]
    call    wb_bytes
    jmp     3f
2:  lea     rsi, [rip+r_null]
    call    wb_str
3:  pop     rsi
    call    wb_str
.Lhm_send:
    call    send_out
    lea     rdi, [rip+out_state]
    call    buf_swap
    mov     dword ptr [rip+dirty], 1
9:  pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# tools/list
# -----------------------------------------------------------------------------
# tool_name(rdi=op, rsi=dest) - "op_" + id with '.' -> '_'
tool_name:
    mov     rdx, rsi
    mov     dword ptr [rdx], 0x5f706f   # "op_"
    add     rdx, 3
    mov     rsi, [rdi+OP_NAME]
1:  mov     al, [rsi]
    cmp     al, '.'
    jne     2f
    mov     al, '_'
2:  mov     [rdx], al
    test    al, al
    jz      3f
    inc     rsi
    inc     rdx
    jmp     1b
3:  ret

tools_list:
    push    rbx
    lea     rsi, [rip+r_tools_a]
    call    wb_str
    lea     rsi, [rip+curated_tools]
    call    wb_str
    lea     rbx, [rip+__start_bee_ops]
1:  lea     rax, [rip+__stop_bee_ops]
    cmp     rbx, rax
    jae     9f
    mov     eax, [rbx+OP_FLAGS]
    test    eax, OPF_AI_SAFE
    jz      2f
    test    eax, OPF_HIDDEN
    jnz     2f
    mov     edi, ','
    call    wb_char
    lea     rsi, [rip+t_op_a]
    call    wb_str
    mov     rdi, rbx
    lea     rsi, [rip+tool]
    call    tool_name
    lea     rsi, [rip+tool]
    call    jb_q
    lea     rsi, [rip+t_op_b]
    call    wb_str
    lea     rdi, [rip+sbuf1]            # "Label - doc"
    mov     rsi, [rbx+OP_LABEL]
    call    cat
    lea     rsi, [rip+s_dash]
    call    cat
    mov     rsi, [rbx+OP_DOC]
    call    cat
    lea     rsi, [rip+sbuf1]
    call    jb_q
    lea     rsi, [rip+t_op_c]
    call    wb_str
2:  add     rbx, OP_SIZE
    jmp     1b
9:  lea     rsi, [rip+r_tools_b]
    call    wb_str
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# tools/call: run the tool (its text goes to txt_state), then
#   {"content":[{"type":"text","text":<text + console lines>}],"isError":..}
# -----------------------------------------------------------------------------
tools_call:
    push    rbx
    push    r12
    push    r13
    lea     rdi, [rip+out_state]        # park the response, open the text
    call    buf_swap
    lea     rdi, [rip+txt_state]
    call    buf_swap
    call    wb_reset
    mov     dword ptr [rip+is_error], 0
    mov     dword ptr [rip+has_image], 0
    mov     byte ptr [rip+tool], 0
    mov     qword ptr [rip+targs], 0
    mov     rsi, [rip+params]
    test    rsi, rsi
    jz      1f
    lea     rdi, [rip+k_name]
    call    j_find
    test    rax, rax
    jz      1f
    mov     rsi, rax
    lea     rdi, [rip+tool]
    mov     edx, 96
    call    j_str
    mov     rsi, [rip+params]
    lea     rdi, [rip+k_arguments]
    call    j_find
    mov     [rip+targs], rax
1:  lea     rdi, [rip+s_mcp_call]       # visible in the console
    lea     rsi, [rip+tool]
    call    log_pair
    mov     eax, [rip+log_head]
    mov     [rip+log_mark], eax
    xor     r12d, r12d                  # made an undo step?
    xor     r13d, r13d                  # 2 = refused
    call    tool_tier                   # permission
    cmp     eax, [rip+agent_tier]
    jbe     11f
    mov     edi, eax
    call    deny
    mov     r13d, 2
    jmp     13f
11: mov     ebx, eax
    test    ebx, ebx                    # read-only tools change nothing
    jz      12f
    call    is_undo_tool                # undo / redo work on change sets
    test    eax, eax
    jnz     12f
    lea     rdi, [rip+agent_label]      # one undo step per request
    lea     rsi, [rip+s_agent_pfx]
    call    cat
    lea     rsi, [rip+tool]
    call    cat
    lea     rdi, [rip+agent_label]
    call    undo_group_begin
    call    dispatch_tool
    call    undo_group_end
    mov     r12d, eax
    jmp     13f
12: call    dispatch_tool
13:
    # append what the tool printed to the console
    mov     ebx, [rip+log_mark]
2:  cmp     ebx, [rip+log_head]
    jae     3f
    mov     edi, 10
    call    wb_char
    mov     eax, ebx
    and     eax, LOG_LINES-1
    imul    eax, LOG_LINE_LEN
    lea     rsi, [rip+log_buf]
    add     rsi, rax
    call    wb_str
    inc     ebx
    jmp     2b
3:  xor     edi, edi
    call    wb_char
    lea     rdi, [rip+tool]             # AI Activity
    mov     esi, r13d
    test    esi, esi
    jnz     32f
    mov     esi, [rip+is_error]
32: mov     edx, r12d
    mov     rcx, [rip+wb_ptr]
    call    act_record
    lea     rdi, [rip+txt_state]        # back to the response
    call    buf_swap
    lea     rdi, [rip+out_state]
    call    buf_swap
    lea     rsi, [rip+r_content_a]
    call    wb_str
    mov     rsi, [rip+txt_state]
    call    jb_q
    lea     rsi, [rip+r_content_b]
    call    wb_str
    cmp     dword ptr [rip+has_image], 0
    je      31f
    lea     rsi, [rip+r_img_a]          # image content: base64 PNG
    call    wb_str
    mov     rsi, [rip+img_state]
    mov     rdx, [rip+img_state+8]
    call    base64
    lea     rsi, [rip+r_img_b]
    call    wb_str
31: lea     rsi, [rip+r_content_c]
    call    wb_str
    lea     rsi, [rip+r_false]
    cmp     dword ptr [rip+is_error], 0
    je      4f
    lea     rsi, [rip+r_true]
4:  call    wb_str
    mov     edi, '}'
    call    wb_char
    pop     r13
    pop     r12
    pop     rbx
    ret

# tool_tier -> eax = permission the requested tool needs (0 read, 1 edit,
#   2 files); tool_op = the operator it runs, if any
tool_tier:
    push    rbx
    mov     qword ptr [rip+tool_op], 0
    lea     rdi, [rip+tool]
    lea     rsi, [rip+c_scene]
    call    str_eq
    test    eax, eax
    jnz     .Ltt_read
    lea     rdi, [rip+tool]
    lea     rsi, [rip+c_capture]
    call    str_eq
    test    eax, eax
    jnz     .Ltt_read
    lea     rdi, [rip+tool]
    lea     rsi, [rip+c_run]
    call    str_eq
    test    eax, eax
    jz      2f
    lea     rdi, [rip+k_idkey]          # run_operator: its operator decides
    lea     rsi, [rip+sbuf2]
    mov     edx, 64
    call    arg_str
    lea     rdi, [rip+sbuf2]
    call    find_op_by_name
    test    rax, rax
    jz      .Ltt_edit
    jmp     .Ltt_op
2:  lea     rbx, [rip+__start_bee_ops]  # op_<id>
3:  lea     rax, [rip+__stop_bee_ops]
    cmp     rbx, rax
    jae     .Ltt_edit
    mov     rdi, rbx
    lea     rsi, [rip+sbuf2]
    call    tool_name
    lea     rdi, [rip+tool]
    lea     rsi, [rip+sbuf2]
    call    str_eq
    test    eax, eax
    jnz     4f
    add     rbx, OP_SIZE
    jmp     3b
4:  mov     rax, rbx
.Ltt_op:
    mov     [rip+tool_op], rax
    mov     rdi, rax
    call    op_tier
    pop     rbx
    ret
.Ltt_read:
    xor     eax, eax
    pop     rbx
    ret
.Ltt_edit:
    mov     eax, 1
    pop     rbx
    ret

# is_undo_tool -> eax = 1 for undo / redo (tools or operators)
is_undo_tool:
    lea     rdi, [rip+tool]
    lea     rsi, [rip+c_undo]
    call    str_eq
    test    eax, eax
    jnz     1f
    lea     rdi, [rip+tool]
    lea     rsi, [rip+c_redo]
    call    str_eq
    test    eax, eax
    jnz     1f
    mov     rax, [rip+tool_op]
    lea     rcx, [rip+op_edit_undo]
    cmp     rax, rcx
    je      2f
    lea     rcx, [rip+op_edit_redo]
    cmp     rax, rcx
    je      2f
    lea     rcx, [rip+op_agent_revert]
    cmp     rax, rcx
    je      2f
    lea     rcx, [rip+op_redo_last]     # adjusting the last operation re-runs it
    cmp     rax, rcx                    # from its own undo step
    je      2f
    xor     eax, eax
1:  ret
2:  mov     eax, 1
    ret

# deny(edi=tier needed) - the permission error for the agent
deny:
    push    rbx
    mov     ebx, edi
    mov     dword ptr [rip+is_error], 1
    lea     rsi, [rip+e_perm_a]
    call    wb_str
    lea     rsi, [rip+tool]
    call    wb_str
    lea     rsi, [rip+e_perm_b]
    call    wb_str
    mov     edi, ebx
    call    agent_tier_name
    mov     rsi, rax
    call    wb_str
    lea     rsi, [rip+e_perm_c]
    call    wb_str
    mov     edi, [rip+agent_tier]
    call    agent_tier_name
    mov     rsi, rax
    call    wb_str
    lea     rsi, [rip+e_perm_d]
    call    wb_str
    pop     rbx
    ret

# mcp_clients -> eax = connected agents
mcp_clients:
    xor     eax, eax
    xor     ecx, ecx
    lea     rdx, [rip+cl_fd]
1:  cmp     dword ptr [rdx+rcx*4], -1
    je      2f
    inc     eax
2:  inc     ecx
    cmp     ecx, MAX_CLIENTS
    jb      1b
    ret

# fail(rdi=message, rsi=detail or 0)
fail:
    mov     dword ptr [rip+is_error], 1
    push    rsi
    mov     rsi, rdi
    call    wb_str
    pop     rsi
    test    rsi, rsi
    jz      1f
    call    wb_str
1:  ret

# arg_str(rdi=key, rsi=dest, edx=cap) -> eax = length (-1 if missing)
arg_str:
    push    rsi
    push    rdx
    mov     rsi, [rip+targs]
    mov     eax, -1
    test    rsi, rsi
    jz      8f
    call    j_find
    test    rax, rax
    jz      7f
    mov     rsi, rax
    pop     rdx
    pop     rdi
    jmp     j_str
7:  mov     eax, -1
8:  pop     rdx
    pop     rsi
    ret

# arg_vec(rdi=key) -> eax = 1 and vec[0..2] filled when present
arg_vec:
    push    rbx
    mov     rsi, [rip+targs]
    xor     eax, eax
    test    rsi, rsi
    jz      9f
    call    j_find
    test    rax, rax
    jz      9f
    mov     rsi, rax
    call    j_first
    xor     ebx, ebx
1:  test    rax, rax
    jz      8f
    cmp     ebx, 3
    jae     8f
    push    rax
    mov     rsi, rax
    call    j_num
    lea     rax, [rip+vec]
    movss   [rax+rbx*4], xmm0
    pop     rsi
    inc     ebx
    call    j_next
    jmp     1b
8:  xor     eax, eax
    cmp     ebx, 3
    sete    al
9:  pop     rbx
    ret

# apply_xform(rdi=object) - location / rotation_deg / scale arguments
apply_xform:
    push    rbx
    mov     rbx, rdi
    lea     rdi, [rip+k_location]
    call    arg_vec
    test    eax, eax
    jz      1f
    mov     rax, [rip+vec]
    mov     [rbx+OB_LOC], rax
    mov     eax, [rip+vec+8]
    mov     [rbx+OB_LOC+8], eax
1:  lea     rdi, [rip+k_rotation]
    call    arg_vec
    test    eax, eax
    jz      2f
    xor     ecx, ecx
11: lea     rax, [rip+vec]
    movss   xmm0, [rax+rcx*4]
    mulss   xmm0, [rip+f_deg2rad]
    movss   [rbx+OB_ROT+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      11b
2:  lea     rdi, [rip+k_scale]
    call    arg_vec
    test    eax, eax
    jz      3f
    mov     rax, [rip+vec]
    mov     [rbx+OB_SCALE], rax
    mov     eax, [rip+vec+8]
    mov     [rbx+OB_SCALE+8], eax
3:  pop     rbx
    ret

# run_named(rdi=operator id, rsi=argument or 0) -> eax = 1 if it ran
run_named:
    push    rbx
    mov     rbx, rsi
    call    find_op_by_name
    test    rax, rax
    jz      9f
    mov     [rip+op_arg], rbx
    mov     rdi, rax
    call    run_op
    mov     qword ptr [rip+op_arg], 0
    mov     eax, 1
9:  pop     rbx
    ret

dispatch_tool:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     rdi, [rip+tool]
    lea     rsi, [rip+c_scene]
    call    str_eq
    test    eax, eax
    jnz     .Ldt_scene
    lea     rdi, [rip+tool]
    lea     rsi, [rip+c_create]
    call    str_eq
    test    eax, eax
    jnz     .Ldt_create
    lea     rdi, [rip+tool]
    lea     rsi, [rip+c_xform]
    call    str_eq
    test    eax, eax
    jnz     .Ldt_xform
    lea     rdi, [rip+tool]
    lea     rsi, [rip+c_select]
    call    str_eq
    test    eax, eax
    jnz     .Ldt_select
    lea     rdi, [rip+tool]
    lea     rsi, [rip+c_delete]
    call    str_eq
    test    eax, eax
    jnz     .Ldt_delete
    lea     rdi, [rip+tool]
    lea     rsi, [rip+c_run]
    call    str_eq
    test    eax, eax
    jnz     .Ldt_run
    lea     rdi, [rip+tool]
    lea     rsi, [rip+c_undo]
    call    str_eq
    test    eax, eax
    jnz     .Ldt_undo
    lea     rdi, [rip+tool]
    lea     rsi, [rip+c_capture]
    call    str_eq
    test    eax, eax
    jnz     .Ldt_capture
    lea     rdi, [rip+tool]
    lea     rsi, [rip+c_script]
    call    str_eq
    test    eax, eax
    jnz     .Ldt_script
    lea     rdi, [rip+tool]
    lea     rsi, [rip+c_redo]
    call    str_eq
    test    eax, eax
    jnz     .Ldt_redo
    # op_<id>: compare against every agent-safe operator's tool name
    lea     rbx, [rip+__start_bee_ops]
1:  lea     rax, [rip+__stop_bee_ops]
    cmp     rbx, rax
    jae     .Ldt_unknown
    test    dword ptr [rbx+OP_FLAGS], OPF_AI_SAFE
    jz      2f
    mov     rdi, rbx
    lea     rsi, [rip+sbuf2]
    call    tool_name
    lea     rdi, [rip+tool]
    lea     rsi, [rip+sbuf2]
    call    str_eq
    test    eax, eax
    jnz     3f
2:  add     rbx, OP_SIZE
    jmp     1b
3:  lea     rdi, [rip+k_arg]
    lea     rsi, [rip+sbuf1]
    mov     edx, 512
    call    arg_str
    lea     rax, [rip+sbuf1]
    mov     [rip+op_arg], rax
    mov     rdi, rbx
    call    run_op
    mov     qword ptr [rip+op_arg], 0
    lea     rsi, [rip+s_ok]
    call    wb_str
    jmp     .Ldt_out
.Ldt_unknown:
    lea     rdi, [rip+e_unknown_tool]
    lea     rsi, [rip+tool]
    call    fail
    jmp     .Ldt_out

.Ldt_scene:
    call    scene_json
    jmp     .Ldt_out

.Ldt_create:
    lea     rdi, [rip+k_type]
    lea     rsi, [rip+sbuf2]
    mov     edx, 32
    call    arg_str
    test    eax, eax
    jle     .Ldt_missing
    lea     rdi, [rip+sbuf1]            # "create." + type
    lea     rsi, [rip+s_create_pfx]
    call    cat
    lea     rsi, [rip+sbuf2]
    call    cat
    lea     rdi, [rip+sbuf1]
    xor     esi, esi
    call    run_named
    test    eax, eax
    jnz     1f
    lea     rdi, [rip+e_bad_type]
    lea     rsi, [rip+sbuf2]
    call    fail
    jmp     .Ldt_out
1:  mov     edi, [rip+active_obj]       # the new object is active
    call    obj_get
    test    rax, rax
    jz      .Ldt_out
    mov     rdi, rax
    call    apply_xform
    lea     rdi, [rip+k_name]
    lea     rsi, [rip+sbuf2]
    mov     edx, 32
    call    arg_str
    test    eax, eax
    jle     2f
    mov     edi, [rip+active_obj]
    lea     rsi, [rip+sbuf2]
    call    obj_rename
2:  mov     edi, [rip+active_obj]
    call    obj_get
    mov     rsi, rax
    call    wb_str                      # the object's final name
    jmp     .Ldt_out

.Ldt_xform:
    lea     rdi, [rip+k_name]
    lea     rsi, [rip+sbuf2]
    mov     edx, 32
    call    arg_str
    test    eax, eax
    jle     .Ldt_missing
    lea     rdi, [rip+sbuf2]
    call    obj_find
    test    eax, eax
    jnz     1f
    lea     rdi, [rip+e_no_object]
    lea     rsi, [rip+sbuf2]
    call    fail
    jmp     .Ldt_out
1:  mov     ebx, eax
    lea     rdi, [rip+s_set_xform]      # undoable like any edit
    call    undo_push
    mov     edi, ebx
    call    obj_get
    mov     rdi, rax
    call    apply_xform
    lea     rdi, [rip+k_new_name]
    lea     rsi, [rip+sbuf1]
    mov     edx, 32
    call    arg_str
    test    eax, eax
    jle     2f
    mov     edi, ebx
    lea     rsi, [rip+sbuf1]
    call    obj_rename
2:  mov     edi, ebx
    call    obj_get
    mov     rsi, rax
    call    wb_str
    jmp     .Ldt_out

.Ldt_select:
    lea     rdi, [rip+k_extend]
    mov     rsi, [rip+targs]
    xor     r12d, r12d
    test    rsi, rsi
    jz      1f
    call    j_find
    test    rax, rax
    jz      1f
    mov     rsi, rax
    call    j_bool
    mov     r12d, eax
1:  test    r12d, r12d
    jnz     2f
    call    select_none
    mov     dword ptr [rip+active_obj], 0
2:  call    select_names
    lea     rsi, [rip+s_ok]
    call    wb_str
    jmp     .Ldt_out

.Ldt_delete:
    call    select_none
    call    select_names
    lea     rdi, [rip+s_del_op]
    xor     esi, esi
    call    run_named
    lea     rsi, [rip+s_ok]
    call    wb_str
    jmp     .Ldt_out

.Ldt_run:
    lea     rdi, [rip+k_idkey]
    lea     rsi, [rip+sbuf2]
    mov     edx, 64
    call    arg_str
    test    eax, eax
    jle     .Ldt_missing
    lea     rdi, [rip+sbuf2]
    call    find_op_by_name
    test    rax, rax
    jz      1f
    test    dword ptr [rax+OP_FLAGS], OPF_AI_SAFE
    jz      1f
    mov     rbx, rax
    lea     rdi, [rip+k_arg]
    lea     rsi, [rip+sbuf1]
    mov     edx, 512
    call    arg_str
    lea     rax, [rip+sbuf1]
    mov     [rip+op_arg], rax
    mov     rdi, rbx
    call    run_op
    mov     qword ptr [rip+op_arg], 0
    lea     rsi, [rip+s_ok]
    call    wb_str
    jmp     .Ldt_out
1:  lea     rdi, [rip+e_no_op]
    lea     rsi, [rip+sbuf2]
    call    fail
    jmp     .Ldt_out

.Ldt_script:
    lea     rdi, [rip+k_code]
    lea     rsi, [rip+script_src_buf]
    mov     edx, 65536
    call    arg_str
    test    eax, eax
    jle     .Ldt_missing
    lea     rdi, [rip+script_src_buf]
    mov     esi, 1                      # agent: only agent-safe operators
    call    script_eval
    mov     ebx, eax
    lea     rsi, [rip+script_out]       # its output, not the console copy
    mov     edx, [rip+script_out_len]
    call    wb_bytes
    mov     eax, [rip+log_head]
    mov     [rip+log_mark], eax
    test    ebx, ebx
    jz      1f
    mov     dword ptr [rip+is_error], 1
    jmp     .Ldt_out
1:  cmp     dword ptr [rip+script_out_len], 0
    jne     .Ldt_out
    lea     rsi, [rip+s_ok]
    call    wb_str
    jmp     .Ldt_out

.Ldt_capture:
    lea     rdi, [rip+k_area]
    lea     rsi, [rip+sbuf2]
    mov     edx, 16
    call    arg_str
    xor     edi, edi
    test    eax, eax
    jle     1f
    lea     rdi, [rip+sbuf2]
    lea     rsi, [rip+s_window]
    call    str_eq
    mov     edi, eax
1:  call    capture
    jmp     .Ldt_out

.Ldt_undo:
    lea     rdi, [rip+s_edit_undo]
    xor     esi, esi
    call    run_named
    lea     rsi, [rip+s_ok]
    call    wb_str
    jmp     .Ldt_out
.Ldt_redo:
    lea     rdi, [rip+s_edit_redo]
    xor     esi, esi
    call    run_named
    lea     rsi, [rip+s_ok]
    call    wb_str
    jmp     .Ldt_out
.Ldt_missing:
    lea     rdi, [rip+e_missing]
    xor     esi, esi
    call    fail
.Ldt_out:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# capture(edi=1 for the whole window) - render the UI off screen, crop and
# encode as PNG into img_state; describes it in the text buffer
capture:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40
    mov     [rsp+32], edi
    mov     edi, [rip+win_w]            # physical size of the window
    call    to_px
    mov     r12d, eax
    mov     edi, [rip+win_h]
    call    to_px
    mov     r13d, eax
    lea     rdi, [rip+frame_arena]
    mov     esi, r12d
    imul    esi, r13d
    shl     esi, 2
    call    arena_alloc
    test    rax, rax
    jz      .Lcap_fail
    mov     r14, rax
    mov     rax, [rip+fb_ptr]           # draw into the off-screen buffer
    mov     [rsp], rax
    mov     eax, [rip+fb_w]
    mov     [rsp+8], eax
    mov     eax, [rip+fb_h]
    mov     [rsp+12], eax
    mov     [rip+fb_ptr], r14
    mov     [rip+fb_w], r12d
    mov     [rip+fb_h], r13d
    call    ui_draw
    mov     rax, [rsp]
    mov     [rip+fb_ptr], rax
    mov     eax, [rsp+8]
    mov     [rip+fb_w], eax
    mov     eax, [rsp+12]
    mov     [rip+fb_h], eax
    xor     ebx, ebx                    # crop rectangle (physical)
    xor     ebp, ebp
    mov     r15d, r12d
    mov     eax, r13d
    mov     [rsp+16], eax
    cmp     dword ptr [rsp+32], 0
    jne     2f
    mov     edi, [rip+vp_area]          # the viewport body
    test    edi, edi
    js      2f
    call    area_node_rect
    mov     [rsp+24], rax
    mov     edi, [rax+12]
    call    to_px
    mov     ebx, eax
    mov     rax, [rsp+24]
    mov     edi, [rax+16]
    add     edi, PANE_HDR_H
    call    to_px
    mov     ebp, eax
    mov     rax, [rsp+24]
    mov     edi, [rax+12]
    add     edi, [rax+20]
    call    to_px
    mov     r15d, eax
    mov     rax, [rsp+24]
    mov     edi, [rax+16]
    add     edi, [rax+24]
    call    to_px
    mov     [rsp+16], eax
2:  sub     r15d, ebx                   # width
    jle     .Lcap_fail
    mov     eax, [rsp+16]
    sub     eax, ebp                    # height
    jle     .Lcap_fail
    mov     [rsp+16], eax
    lea     rdi, [rip+img_state]        # encode into the image buffer
    call    buf_swap
    call    wb_reset
    mov     eax, ebp
    imul    eax, r12d
    add     eax, ebx
    lea     rsi, [r14+rax*4]
    mov     edx, r15d
    mov     ecx, [rsp+16]
    mov     r8d, r12d
    call    png_encode
    mov     ebx, eax
    lea     rdi, [rip+img_state]
    call    buf_swap
    test    ebx, ebx
    jz      .Lcap_fail
    mov     dword ptr [rip+has_image], 1
    lea     rsi, [rip+s_capture]        # "PNG capture W x H px"
    call    wb_str
    mov     edi, r15d
    call    wb_int
    lea     rsi, [rip+s_x_]
    call    wb_str
    mov     edi, [rsp+16]
    call    wb_int
    lea     rsi, [rip+s_px]
    call    wb_str
    jmp     .Lcap_out
.Lcap_fail:
    lea     rdi, [rip+e_missing]
    xor     esi, esi
    call    fail
.Lcap_out:
    add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# base64(rsi=data, rdx=bytes) - appended to wb
base64:
    push    rbx
    push    r12
    push    r13
    mov     r12, rsi
    mov     r13, rdx
    mov     rax, rdx                    # output size = 4 * ceil(n / 3)
    add     rax, 2
    xor     edx, edx
    mov     ecx, 3
    div     rcx
    shl     rax, 2
    mov     rdi, rax
    push    rax
    call    wb_reserve
    pop     rcx
    test    rax, rax
    jz      9f
    add     [rip+wb_len], rcx
    mov     rdi, rax
    lea     r8, [rip+b64]
1:  cmp     r13, 3
    jb      2f
    movzx   eax, byte ptr [r12]
    shl     eax, 16
    movzx   ecx, byte ptr [r12+1]
    shl     ecx, 8
    or      eax, ecx
    movzx   ecx, byte ptr [r12+2]
    or      eax, ecx
    mov     ecx, eax
    shr     ecx, 18
    mov     cl, [r8+rcx]
    mov     [rdi], cl
    mov     ecx, eax
    shr     ecx, 12
    and     ecx, 63
    mov     cl, [r8+rcx]
    mov     [rdi+1], cl
    mov     ecx, eax
    shr     ecx, 6
    and     ecx, 63
    mov     cl, [r8+rcx]
    mov     [rdi+2], cl
    and     eax, 63
    mov     al, [r8+rax]
    mov     [rdi+3], al
    add     r12, 3
    sub     r13, 3
    add     rdi, 4
    jmp     1b
2:  test    r13, r13                    # 1 or 2 bytes left: pad with '='
    jz      9f
    movzx   eax, byte ptr [r12]
    shl     eax, 16
    cmp     r13, 2
    jb      3f
    movzx   ecx, byte ptr [r12+1]
    shl     ecx, 8
    or      eax, ecx
3:  mov     ecx, eax
    shr     ecx, 18
    mov     cl, [r8+rcx]
    mov     [rdi], cl
    mov     ecx, eax
    shr     ecx, 12
    and     ecx, 63
    mov     cl, [r8+rcx]
    mov     [rdi+1], cl
    mov     byte ptr [rdi+2], '='
    mov     byte ptr [rdi+3], '='
    cmp     r13, 2
    jb      9f
    mov     ecx, eax
    shr     ecx, 6
    and     ecx, 63
    mov     cl, [r8+rcx]
    mov     [rdi+2], cl
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# select_names - select every object listed in arguments.names; the last
# found becomes active
select_names:
    push    rbx
    mov     rsi, [rip+targs]
    test    rsi, rsi
    jz      9f
    lea     rdi, [rip+k_names]
    call    j_find
    test    rax, rax
    jz      9f
    mov     rsi, rax
    call    j_first
1:  test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rsi, rax
    lea     rdi, [rip+sbuf2]
    mov     edx, 32
    call    j_str
    lea     rdi, [rip+sbuf2]
    call    obj_find
    test    eax, eax
    jz      2f
    push    rax
    mov     edi, eax
    call    obj_get
    or      dword ptr [rax+OB_FLAGS], OBF_SELECTED
    pop     rax
    mov     [rip+active_obj], eax
2:  mov     rsi, rbx
    call    j_next
    jmp     1b
9:  mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

# scene_json - the scene as JSON (appended to wb)
scene_json:
    push    rbx
    push    r12
    lea     rsi, [rip+j_objs_a]
    call    wb_str
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    test    ebx, ebx
    jz      2f
    mov     edi, ','
    call    wb_char
2:  mov     edi, ebx
    call    obj_at
    mov     r12, rax
    mov     edi, '{'
    call    wb_char
    lea     rsi, [rip+k_name]
    call    jb_key
    mov     rsi, r12
    call    jb_q
    mov     edi, ','
    call    wb_char
    lea     rsi, [rip+k_type]
    call    jb_key
    mov     eax, [r12+OB_TYPE]
    lea     rcx, [rip+type_name_ptrs]
    mov     rsi, [rcx+rax*8]
    call    jb_q
    mov     edi, ','
    call    wb_char
    lea     rsi, [rip+k_location]
    lea     rdi, [r12+OB_LOC]
    xor     edx, edx
    call    vec_json
    mov     edi, ','
    call    wb_char
    lea     rsi, [rip+k_rotation]
    lea     rdi, [r12+OB_ROT]
    mov     edx, 1
    call    vec_json
    mov     edi, ','
    call    wb_char
    lea     rsi, [rip+k_scale]
    lea     rdi, [r12+OB_SCALE]
    xor     edx, edx
    call    vec_json
    lea     rsi, [rip+j_selected]
    call    wb_str
    lea     rsi, [rip+r_false]
    test    dword ptr [r12+OB_FLAGS], OBF_SELECTED
    jz      3f
    lea     rsi, [rip+r_true]
3:  call    wb_str
    lea     rsi, [rip+j_active]
    call    wb_str
    lea     rax, [rip+obj_list]
    mov     eax, [rax+rbx*4]
    lea     rsi, [rip+r_false]
    cmp     eax, [rip+active_obj]
    jne     4f
    lea     rsi, [rip+r_true]
4:  call    wb_str
    lea     rsi, [rip+j_verts]
    call    wb_str
    mov     rax, [r12+OB_MESH]
    mov     edi, [rax+ME_NVERTS]
    call    wb_int
    lea     rsi, [rip+j_faces]
    call    wb_str
    mov     rax, [r12+OB_MESH]
    mov     edi, [rax+ME_NPOLYS]
    call    wb_int
    mov     rax, [r12+OB_MODS]          # "modifiers":["subsurf", ...]
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+4], 0
    je      8f
    lea     rsi, [rip+j_mods]
    call    wb_str
    xor     ecx, ecx
5:  mov     rax, [r12+OB_MODS]
    cmp     ecx, [rax+4]
    jae     7f
    push    rcx
    test    ecx, ecx
    jz      6f
    mov     edi, ','
    call    wb_char
6:  mov     rax, [r12+OB_MODS]
    mov     ecx, [rsp]
    imul    ecx, ecx, 48
    mov     eax, [rax+16+rcx]           # type
    lea     rcx, [rip+mod_keys]
    mov     rsi, [rcx+rax*8]
    call    jb_q
    pop     rcx
    inc     ecx
    jmp     5b
7:  mov     edi, ']'
    call    wb_char
8:  mov     edi, '}'
    call    wb_char
    inc     ebx
    jmp     1b
9:  lea     rsi, [rip+j_objs_b]
    call    wb_str
    pop     r12
    pop     rbx
    ret

# vec_json(rsi=key, rdi=float[3], edx=1 for radians -> degrees)
vec_json:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, edx
    call    jb_key
    mov     edi, '['
    call    wb_char
    xor     r13d, r13d
1:  test    r13d, r13d
    jz      2f
    mov     edi, ','
    call    wb_char
2:  movss   xmm0, [rbx+r13*4]
    test    r12d, r12d
    jz      3f
    mulss   xmm0, [rip+f_rad2deg_]
3:  call    jb_num
    inc     r13d
    cmp     r13d, 3
    jb      1b
    mov     edi, ']'
    call    wb_char
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# mcp_bridge - beemodel --mcp-bridge: stdin/stdout <-> the app's socket
# -----------------------------------------------------------------------------
mcp_bridge:
    push    rbx
    push    r12
    lea     rdi, [rip+s_env_sock]
    call    getenv
    test    rax, rax
    jz      1f
    cmp     byte ptr [rax], 0
    je      1f
    mov     rsi, rax
    lea     rdi, [rip+link_path]
    call    cat
    jmp     2f
1:  lea     rdi, [rip+link_path]
    call    runtime_dir
    lea     rsi, [rip+s_link]
    call    cat
2:  mov     r12d, 50                    # wait up to 5 s for the app
3:  mov     edi, AF_UNIX
    mov     esi, SOCK_CLIENT
    xor     edx, edx
    mov     eax, SYS_SOCKET
    syscall
    mov     ebx, eax
    lea     rsi, [rip+link_path]
    call    sockaddr
    mov     edi, ebx
    lea     rsi, [rip+addr]
    mov     edx, 110
    mov     eax, SYS_CONNECT
    syscall
    test    eax, eax
    jz      5f
    mov     edi, ebx
    mov     eax, SYS_CLOSE
    syscall
    dec     r12d
    jz      4f
    lea     rdi, [rip+nanos]
    xor     esi, esi
    mov     eax, SYS_NANOSLEEP
    syscall
    jmp     3b
4:  lea     rdi, [rip+s_bridge_err]
    call    write_err
    mov     eax, 1
    jmp     9f
5:  lea     rdi, [rip+bpoll]            # relay until either side closes
    mov     dword ptr [rdi], 0          # stdin
    mov     dword ptr [rdi+4], POLLIN
    mov     [rdi+8], ebx
    mov     dword ptr [rdi+12], POLLIN
    mov     esi, 2
    mov     edx, -1
    mov     eax, SYS_POLL
    syscall
    cmp     rax, -4
    je      5b
    test    word ptr [rip+bpoll+6], POLLIN|POLLHUP|POLLERR
    jz      6f
    xor     edi, edi
    mov     esi, ebx
    call    relay
    test    eax, eax
    jz      8f
6:  test    word ptr [rip+bpoll+14], POLLIN|POLLHUP|POLLERR
    jz      5b
    mov     edi, ebx
    mov     esi, 1
    call    relay
    test    eax, eax
    jnz     5b
8:  xor     eax, eax
9:  pop     r12
    pop     rbx
    ret

# relay(edi=from fd, esi=to fd) -> eax = 0 at end of stream
relay:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    lea     rsi, [rip+iobuf]
    mov     edx, 65536
    xor     eax, eax                    # SYS_READ
    syscall
    test    rax, rax
    jle     8f
    mov     r13, rax
    lea     rbx, [rip+iobuf]
1:  test    r13, r13
    jz      2f
    mov     edi, r12d
    mov     rsi, rbx
    mov     rdx, r13
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      1b
    test    rax, rax
    jle     8f
    add     rbx, rax
    sub     r13, rax
    jmp     1b
2:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
s_del_op:       .asciz "object.delete"

.section .note.GNU-stack,"",@progbits
