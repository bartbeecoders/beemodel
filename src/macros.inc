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
.equ OP_PARAMS, 56      # ptr  parameter list for the redo panel (redo.s), or 0
.equ OP_SIZE,   64

.equ OPF_QUIET,   1     # don't echo to the console when run
.equ OPF_AI_SAFE, 2     # may be exposed to automation without confirmation
.equ OPF_UNDO,    4     # records an undo step (once undo exists)
.equ OPF_HIDDEN,  8     # alias binding: not listed in the palette
.equ OPF_EDIT,    16    # its key only works in edit mode
.equ OPF_OBJECT,  32    # its key only works in object mode
.equ OPF_SKETCH,  64    # its key only works in sketch mode (and wins there)
.equ OPF_SCULPT,  128   # its key only works in sculpt mode (and wins there)
.equ OPF_UV,      256   # its key only works over a UV editor (and wins there)
.equ OPF_PAINT,   512   # its key only works in texture paint (and wins there)
.equ OPF_NODE,    1024  # its key only works over a node editor (and wins there)
.equ OPF_CURVE,   2048  # its key only works in curve edit mode (and wins there)

# key binding modifiers (pre-shifted into the high half of OP_KEY)
.equ KM_SHIFT,  MOD_SHIFT << 16
.equ KM_CTRL,   MOD_CTRL << 16
.equ KM_ALT,    MOD_ALT << 16

#  OPERATOR sym, "id", "Label", exec [, check, arg, key, flags, "doc"]
.macro OPERATOR sym, name, label, exec, check=0, arg=0, key=0, flags=OPF_AI_SAFE, doc, params=0
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
    .quad \params
    .popsection
.endm
