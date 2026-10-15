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
.equ OP_POLL,   64      # ptr  fn(rdi=arg) -> rax = 0 can run now, else why not (asciz), or 0
.equ OP_FORM,   72      # ptr  FORM record (forms.s): a dialog asks for the argument, or 0
.equ OP_SIZE,   80

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
.equ OPF_ANIMED,  4096  # its key only works over a dope sheet / graph editor (and wins there)
.equ OPF_ARM,     8192  # its key only works in armature edit / pose mode (and wins there)
.equ OPF_CONFIRM, 16384 # from the UI: asks "Save changes?" first when the scene has some
.equ OPF_FORMNEW, 32768 # its form only while the scene has no file yet (file.save)

# key binding modifiers (pre-shifted into the high half of OP_KEY)
.equ KM_SHIFT,  MOD_SHIFT << 16
.equ KM_CTRL,   MOD_CTRL << 16
.equ KM_ALT,    MOD_ALT << 16

#  OPERATOR sym, "id", "Label", exec [, check, arg, key, flags, "doc"]
.macro OPERATOR sym, name, label, exec, check=0, arg=0, key=0, flags=OPF_AI_SAFE, doc, params=0, poll=0, form=0
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
    .quad \poll
    .quad \form
    .popsection
.endm

# A submenu entry of a menu list (menus.s): tag 1, label, entries, count
.equ SUBTAG,    1
.equ SUB_LABEL, 8
.equ SUB_ITEMS, 16
.equ SUB_COUNT, 24
.macro SUBMENU sym, label, items, count
    .pushsection .rodata
.Lsl\@: .asciz "\label"
    .balign 8
    .globl \sym
\sym:   .quad SUBTAG, .Lsl\@, \items, \count
    .popsection
.endm

# Operator forms (dialog.s, forms.s): FORM sym, n then n FFIELDs - a field
# is a widget descriptor, the text before its value ("mass "), keywords for
# an enum, its default and flags (FF_CHANGED: only sent when not the default)
.equ FF_CHANGED, 1
.equ FK_ACTIVE,  1                     # a text field's kw: the active object's name
.equ FK_OTHER,   2                     #  ... another selected object's (else world)
.macro FORM sym, n
    .pushsection .rodata.forms, "a"
    .balign 8
    .globl \sym
\sym:   .quad 0, \sym\()_v
    .long \n, 0
    .popsection
    .pushsection .bss
    .balign 8
\sym\()_v: .skip 16*64+8
    .popsection
.endm
.macro FFIELD desc, prefix=0, kw=0, def=0.0, flags=0
    .pushsection .rodata.forms, "a"
    .quad \desc, \prefix, \kw
    .float \def
    .long \flags
    .popsection
.endm
