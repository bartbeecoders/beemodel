# =============================================================================
#  BeeModel - shared macros
# =============================================================================

# ---- Operator record (the "operator spine") ---------------------------------
#  Every user-visible action is one 64-byte record in the `bee_ops` linker
#  section. Any module can declare operators; ld concatenates them and exposes
#  the table as [__start_bee_ops, __stop_bee_ops). Menus, tool buttons, the
#  keymap, --list-ops and (later) the command palette, BeeScript and MCP are
#  all driven from this one table.
.equ OP_NAME,   0       # ptr  asciz  stable id, e.g. "view.toggle_grid"
.equ OP_LABEL,  8       # ptr  asciz  human label, e.g. "Ground Grid"
.equ OP_EXEC,   16      # ptr  fn(rdi=arg, rsi=op)
.equ OP_CHECK,  24      # ptr  fn(rdi=arg) -> eax 0/1, or 0 = not a toggle
.equ OP_DOC,    32      # ptr  asciz  one-line description
.equ OP_ARG,    40      # u64  argument passed to exec/check
.equ OP_KEY,    48      # u32  key binding: evdev code | (modifiers << 16)
.equ OP_FLAGS,  52      # u32  OPF_*
.equ OP_SIZE,   64

.equ OPF_QUIET,   1     # don't echo to the console when run
.equ OPF_AI_SAFE, 2     # may be exposed to automation without confirmation
.equ OPF_UNDO,    4     # records an undo step (once undo exists)

# key binding modifiers (pre-shifted into the high half of OP_KEY)
.equ KM_SHIFT,  MOD_SHIFT << 16
.equ KM_CTRL,   MOD_CTRL << 16
.equ KM_ALT,    MOD_ALT << 16

#  OPERATOR sym, "id", "Label", exec [, check, arg, key, flags, "doc"]
.macro OPERATOR sym, name, label, exec, check=0, arg=0, key=0, flags=OPF_AI_SAFE, doc
    .pushsection .rodata
.Lop_name\@:  .asciz "\name"
.Lop_label\@: .asciz "\label"
.Lop_doc\@:   .asciz "\doc"
    .popsection
    .pushsection bee_ops, "a"
    .balign 8
    .globl \sym
\sym:
    .quad .Lop_name\@, .Lop_label\@, \exec, \check, .Lop_doc\@, \arg
    .long \key, \flags
    .quad 0
    .popsection
.endm
