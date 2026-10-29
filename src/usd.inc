# =============================================================================
#  BeeModel - OpenUSD layers in memory (usdlayer.s), filled by the crate
#  reader (usdc.s) and the text reader (usda.s), composed by usd.s.
#
#  A layer is its paths (full path text, interned: "/", "/Root/Mesh",
#  "/Root/Mesh.points", variant selections "/Root{set=sel}"), its specs (one
#  per path that has one: prim, attribute, relationship ...) and each
#  spec's fields, a list of (name, value). Values are kept in a few plain
#  forms whatever the file said: integers, doubles, text, small vectors of
#  doubles, float or int arrays, lists of text, reference lists and
#  variant selections. Everything lives in the layer's arena and goes with
#  it (usd_free).
# =============================================================================

# ---- the layer --------------------------------------------------------------
.equ UL_ACUR,    0      # arena: where the next allocation goes
.equ UL_AEND,    8      #  the end of the current chunk
.equ UL_ACHUNK,  16     #  the chunks (each: next, bytes; freed with it)
.equ UL_PATHS,   24     # path records (UP_*)
.equ UL_NPATH,   32     #  (4) count
.equ UL_CPATH,   36     #  (4) capacity
.equ UL_HASH,    40     # path hash heads (int32, -1 = none)
.equ UL_HMASK,   48     #  (4) heads - 1
.equ UL_SPECS,   56     # spec records (US_*)
.equ UL_NSPEC,   64
.equ UL_CSPEC,   68
.equ UL_FLDS,    72     # field records (UF_*)
.equ UL_NFLD,    80
.equ UL_CFLD,    84
.equ UL_MAP,     88     # the file's mapping (crate arrays point into it)
.equ UL_MAPSZ,   96
.equ UL_FILE,    104    # the file's path (asciz, arena)
.equ UL_SZ,      128

# ---- a path -------------------------------------------------------------------
.equ UP_STR,     0      # full path text (asciz)
.equ UP_SPEC,    8      # (4) its spec, -1: none
.equ UP_NEXT,    12     # (4) hash chain
.equ UP_PARENT,  16     # (4) parent path, -1 for "/"
.equ UP_KIND,    20     # (4) UK_*
.equ UP_SZ,      24

.equ UK_ROOT,    0
.equ UK_PRIM,    1
.equ UK_PROP,    2
.equ UK_VARIANT, 3

# ---- a spec (SdfSpecType numbers) -------------------------------------------------
.equ US_PATH,    0      # (4)
.equ US_TYPE,    4      # (4) SPEC_*
.equ US_FIRST,   8      # (4) first field, -1: none
.equ US_LAST,    12     # (4) last field
.equ US_SZ,      16

.equ SPEC_ATTR,     1
.equ SPEC_CONN,     2
.equ SPEC_PRIM,     6
.equ SPEC_ROOT,     7
.equ SPEC_REL,      8
.equ SPEC_RELTGT,   9
.equ SPEC_VARIANT,  10
.equ SPEC_VARSET,   11

# ---- a field ------------------------------------------------------------------
.equ UF_NAME,    0      # name (asciz)
.equ UF_VAL,     8      # value (UV_*)
.equ UF_NEXT,    16     # (4) the spec's next field, -1: last
.equ UF_SZ,      24

# ---- a value ------------------------------------------------------------------
.equ UV_T,       0      # (4) UT_*
.equ UV_X,       4      # (4) arrays: components per element
.equ UV_N,       8      # count: vector components, array elements, list items
.equ UV_P,       16     # data: text, doubles, floats, int32s, pointers
.equ UV_D,       24     # a scalar: int64 (UT_INT) or double (UT_DBL)
.equ UV_SZ,      32

.equ UT_NONE,    0      # blocked, or a kind not kept (dictionaries ...)
.equ UT_INT,     1      # bool, ints, enums (specifier, variability)
.equ UT_DBL,     2      # half, float, double, time code
.equ UT_STR,     3      # token, string, asset path
.equ UT_VEC,     4      # N doubles: vectors, quaternions (x y z w), matrices
.equ UT_FARR,    5      # N elements of X floats (float32)
.equ UT_IARR,    6      # N elements of X int32s
.equ UT_SLIST,   7      # N texts: tokens, strings, paths, list ops of them
.equ UT_RLIST,   8      # N (asset, prim path) pairs: references, payloads
.equ UT_VSEL,    9      # N (variant set, selection) pairs
