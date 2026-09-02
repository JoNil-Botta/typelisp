;# benchmarks/sccp_lattice/bench.tl - optimizer sparse conditional constant
;# propagation.
;#
;# Equivalent to benchmarks/sccp_lattice/baseline.c. The kernel is the TypeLisp
;# optimizer's `sccp` pass: the scalar lattice, the CFG-id-backed executable
;# flags, the fixpoint sweep, the integer constant folder and the counted
;# rewrite. It runs over real functions the compiler produced while compiling
;# itself, captured at `--dump-ir after-bounds_dom`, the dump point immediately
;# before the `sccp` pass in `optimize-function-once-with-summaries`.
;#
;# Mirrored compiler functions, all in src/compiler_optimize.tl unless noted:
;#   opt-sccp-blocks-with-context-result-raw / opt-sccp-analyze-with-frame
;#   opt-sccp-analyze-fixed        -- sweeps while something changed, bounded by
;#                                    nblocks + 8 + 2 * ninstr
;#   opt-sccp-initial-state-with-frame -- env sized by the function frame,
;#                                    parameters Overdefined, entry executable
;#   opt-sccp-env-make / -fill-unknown! / -lookup / -set / -any-const?
;#   opt-sccp-join, opt-sccp-value-eq, opt-sccp-state-bind
;#   opt-sccp-state-mark-executable, opt-cfg-index-id / -id-slot /
;#     -id-map-capacity / -fill-id-map!  (the label hash index)
;#   opt-sccp-process-blocks-from / -process-block / -process-instr-seq-from /
;#     -process-instr
;#   opt-sccp-value, opt-sccp-immediate, opt-normalize-const,
;#     opt-default-immediate-type
;#   opt-sccp-fold-binop-value / -fold-unop-value / -fold-cast-value
;#   opt-fold-binop, opt-binop-operand-type, opt-fold-int-char-binop,
;#     opt-fold-bool, opt-fold-compare, opt-fold-shift, opt-shift-count-valid?,
;#     opt-divmod-valid?, opt-fold-div-value / -mod-value / -shl-value /
;#     -shr-value, opt-normalize-int-to-i64, opt-normalize-scalar-to-i64,
;#     opt-typed-lt? / -le? / -gt? / -ge?, opt-unsigned-lt?, opt-int-width
;#   opt-fold-unop, opt-fold-cast (over compiler_float.tl's
;#     compiler-finite-cast-fold / -normalize-i64 integer arms)
;#   opt-sccp-phi-value / -phi-input-value
;#   opt-sccp-mark-branch-targets / -mark-switch-targets
;#   opt-sccp-rewrite-value, opt-sccp-instr-changes-successors?,
;#     opt-sccp-blocks-change-successors?, opt-sccp-bounds-check-in-range?
;#
;# KEPT: the lattice is a `defenum` with a payload held inline in a dense array
;# indexed by var id, exactly as `OptSccpValue` is held in `OptSccpEnv.Env`'s
;# `(__tl_dyn-array OptSccpValue)`; the array is sized by the function frame
;# (`vars N` in the dump is `bd-frame`, the value the pipeline hands
;# `opt-sccp-analyze-with-frame`) and refilled with Unknown per function, which
;# is what `opt-sccp-env-make` costs. The executable flags are a `bool` array
;# indexed by dense block id and every label goes through the compiler's own
;# open-addressed label index (`opt-cfg-index-id-slot`'s `(label ^ (label >> 5))
;# & mask` probe over a table of `id + 1` entries at the next power of two above
;# `2 * nblocks`). The sweep bound, the per-block executable gate, the
;# per-instruction dispatch and the whole integer folder are edge for edge the
;# compiler's, including the wrapping per result width, the signed/unsigned
;# compares, the shift-count validity rule, the divide/remainder refusals and
;# the bool ops.
;#
;# DROPPED, and why the kept part dominates: (1) float constants never enter the
;# lattice -- `opt-normalize-const` accepts F64/F32 values, but this corpus's
;# folder covers the integer semantics the packet names, so an `f64` literal is
;# NoConst and its instruction binds Overdefined, which is the same lattice
;# element the compiler reaches for every non-finite or unfoldable float and
;# costs one fold call either way; (2) the rewrite phase is COUNTED, not
;# materialised -- the kernel counts the operand substitutions, the branches
;# that become jumps and the bounds checks proven in range instead of building
;# replacement IR, exactly as gvn_table counts its rewrites; (3) a call's
;# argument list is not modelled, because the tape's fixed-width row carries at
;# most two operands, so `opt-sccp-rewrite-call-args` substitutions are not
;# counted (the analysis never reads call arguments: a Call binds Overdefined);
;# (4) `OptSccpState` is a module-global triple (label index, executable flags,
;# lattice) plus a changed flag rather than a threaded five-field enum -- the
;# arrays are the same objects either way; (5) `opt-cfg-context-build`'s
;# successor/predecessor CSR, dominators and loops are the exporter's job here,
;# because SCCP only ever asks the context for `opt-cfg-index-id` and the
;# terminator's successor labels; (6) the dump does not print a shift's
;# independently typed RHS, so the count type is `i64`, which is what the
;# lowerer emits.
;#
;# SELF-CHECK: the corpus header carries the exporter's own independent SCCP
;# result -- vars that end Const, blocks that end non-executable, operand
;# substitutions, folded branches and dropped bounds checks. The kernel
;# recomputes all five and `main` returns 1 if any disagrees.
;#
;# The corpus path and the round count are runtime arguments, so nothing can be
;# constant folded. Each round rotates the starting function by one, so no round
;# repeats an earlier round's accumulator. The checksum is a wrapping 64-bit
;# FNV-1a fold with no division on loop-carried values, so the printed decimal
;# matches the C baseline's `%lld` bit for bit.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

;; --- the lattice ------------------------------------------------------------
;; OptSccpValue. The Const payload is the compiler's (ir.CompilerIrValue,
;; ast.AstType) pair flattened to (value kind, value bits, dense type id): the
;; corpus interns every AstType spelling, so opt-type-eq is an id compare and
;; opt-value-eq is a (kind, bits) compare.
(defenum SccpValue
  (Unknown)
  (Const i64 i64 i64)
  (Overdefined))

;; OptSccpEnv.Env: a capacity and a dense array indexed by var id.
(defstruct SccpEnv
  (slots (__tl_dyn-array SccpValue))
  (cap i64))

;; The executable flags of OptSccpState, a bool array indexed by dense block id.
(defstruct SccpFlags
  (slots (__tl_dyn-array bool))
  (cap i64))

(define (sccp-zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define (sccp-vec-ref [items : (& items i64vec.Vec)] [index : i64]) : i64
  (array-ref (i64vec.slots items) index))

(define (sccp-vec-set!
  [items : (&mut items i64vec.Vec)]
  [index : i64]
  [value : i64]) : unit
  (set! (array-ref (i64vec.slots-mut items) index) value))

(defmacro (sccp-ref [items : Expr] [index : Expr]) : Expr
  `(sccp-vec-ref (& ,items) ,index))

(defmacro (sccp-set! [items : Expr] [index : Expr] [value : Expr]) : Expr
  `(sccp-vec-set! (&mut ,items) ,index ,value))

(define sccp-hash-basis : i64
  1469598103934665603)
(define sccp-hash-prime : i64
  1099511628211)

;; Type classes in the corpus type table.
(define sccp-class-other : i64
  0)
(define sccp-class-sint : i64
  1)
(define sccp-class-uint : i64
  2)
(define sccp-class-char : i64
  3)
(define sccp-class-bool : i64
  4)

;; Pre-interned type ids (see tools/export_sccp_tape.py).
(define sccp-ty-i64 : i64
  0)
(define sccp-ty-bool : i64
  1)
(define sccp-ty-char : i64
  2)
(define sccp-ty-f64 : i64
  3)
(define sccp-ty-f32 : i64
  4)

;; Operand kinds.
(define sccp-vk-none : i64
  0)
(define sccp-vk-var : i64
  1)
(define sccp-vk-int : i64
  2)
(define sccp-vk-bool : i64
  3)

;; Opcodes.
(define sccp-op-other : i64
  0)
(define sccp-op-overdef : i64
  1)
(define sccp-op-mov : i64
  2)
(define sccp-op-cast : i64
  3)
(define sccp-op-phi : i64
  4)
(define sccp-op-jump : i64
  5)
(define sccp-op-branch : i64
  6)
(define sccp-op-switch : i64
  7)
(define sccp-op-bounds : i64
  8)
(define sccp-op-neg : i64
  9)
(define sccp-op-not : i64
  10)
(define sccp-op-bitnot : i64
  11)
(define sccp-op-sqrt : i64
  12)
(define sccp-op-add : i64
  16)
(define sccp-op-sub : i64
  17)
(define sccp-op-mul : i64
  18)
(define sccp-op-div : i64
  19)
(define sccp-op-mod : i64
  20)
(define sccp-op-safe-div : i64
  21)
(define sccp-op-safe-mod : i64
  22)
(define sccp-op-eq : i64
  23)
(define sccp-op-ne : i64
  24)
(define sccp-op-lt : i64
  25)
(define sccp-op-le : i64
  26)
(define sccp-op-gt : i64
  27)
(define sccp-op-ge : i64
  28)
(define sccp-op-bit-test-eq : i64
  29)
(define sccp-op-bit-test-ne : i64
  30)
(define sccp-op-and : i64
  31)
(define sccp-op-or : i64
  32)
(define sccp-op-bit-and : i64
  33)
(define sccp-op-bit-or : i64
  34)
(define sccp-op-bit-xor : i64
  35)
(define sccp-op-shl : i64
  36)
(define sccp-op-shr : i64
  37)

;; Parsed corpus tokens plus the workspaces every per-function analysis reuses.
;; Module globals keep the analysis functions parameterless, matching how the
;; compiler threads one OptSccpState through the pass.
(define sccp-tokens : i64vec.Vec
  (sccp-zero-vec 1))
(define sccp-offsets : i64vec.Vec
  (sccp-zero-vec 1))
(define sccp-type-class : i64vec.Vec
  (sccp-zero-vec 1))
(define sccp-type-width : i64vec.Vec
  (sccp-zero-vec 1))
(define sccp-labels : i64vec.Vec
  (sccp-zero-vec 1))
(define sccp-idmap : i64vec.Vec
  (sccp-zero-vec 1))
(define sccp-env : SccpEnv
  (SccpEnv (__tl_make-array SccpValue 1) 1))
(define sccp-exec : SccpFlags
  (SccpFlags (__tl_make-array bool 1) 1))

;; Per-function view of the corpus, set by sccp-function before it runs.
(define sccp-frame : i64
  0)
(define sccp-nparams : i64
  0)
(define sccp-nblocks : i64
  0)
(define sccp-ninstr : i64
  0)
(define sccp-param-base : i64
  0)
(define sccp-succ-base : i64
  0)
(define sccp-phi-base : i64
  0)
(define sccp-block-base : i64
  0)
(define sccp-instr-base : i64
  0)
(define sccp-idmask : i64
  0)

;; The `changed` field of OptSccpState, plus the totals the self-check pins.
(define sccp-changed : bool
  false)
(define sccp-self-check-ok : bool
  true)
(define sccp-sweeps : i64
  0)
(define sccp-consts : i64
  0)
(define sccp-dead : i64
  0)
(define sccp-subs : i64
  0)
(define sccp-branches : i64
  0)
(define sccp-dropped : i64
  0)

(define (sccp-mix [hash : i64] [value : i64]) : i64
  (* (bit-xor hash value) sccp-hash-prime))

(define (sccp-byte-at [text : (& text str)] [n : i64] [i : i64]) : i64
  (if (< i n)
    (cast (string.string-ref text i) : i64)
    -1))

(define (sccp-digit? [byte : i64]) : bool
  (and (>= byte 48) (<= byte 57)))

;; Whitespace-separated decimal integers, with `#` starting a comment that runs
;; to the end of its line.
(define (sccp-scan-ints [text : (& text str)] [out : (&mut out i64vec.Vec)]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [count : i64 0]
    (begin
      (while (< i n)
        (let
          [byte : i64 (sccp-byte-at text n i)]
          (cond
            [(= byte 35)
              (while (and (< i n) (not (= (sccp-byte-at text n i) 10)))
                (set! i (+ i 1)))]
            [(or (sccp-digit? byte) (= byte 45))
              (let
                [negative : bool (= byte 45)]
                [value : i64 0]
                (begin
                  (when negative (set! i (+ i 1)))
                  (while (sccp-digit? (sccp-byte-at text n i))
                    (begin
                      (set!
                        value
                        (+ (* value 10) (- (sccp-byte-at text n i) 48)))
                      (set! i (+ i 1))))
                  (i64vec.set-ref!
                    out
                    count
                    (if negative
                      (- 0 value)
                      value))
                  (set! count (+ count 1))))]
            [else (set! i (+ i 1))])))
      count)))

;; --- type predicates (opt-integer-type? and friends) -------------------------
(define (sccp-class-of [ty : i64]) : i64
  (sccp-ref sccp-type-class ty))

;; opt-int-width: 64/32/16/8 for the integer and char types.
(define (sccp-int-width [ty : i64]) : i64
  (sccp-ref sccp-type-width ty))

(define (sccp-integer-type? [ty : i64]) : bool
  (let
    [klass : i64 (sccp-class-of ty)]
    (or (= klass sccp-class-sint) (= klass sccp-class-uint))))

(define (sccp-int-or-char-type? [ty : i64]) : bool
  (let
    [klass : i64 (sccp-class-of ty)]
    (or
      (= klass sccp-class-sint)
      (= klass sccp-class-uint)
      (= klass sccp-class-char))))

(define (sccp-signed-integer-type? [ty : i64]) : bool
  (= (sccp-class-of ty) sccp-class-sint))

(define (sccp-unsigned-integer-type? [ty : i64]) : bool
  (= (sccp-class-of ty) sccp-class-uint))

(define (sccp-bool-type? [ty : i64]) : bool
  (= (sccp-class-of ty) sccp-class-bool))

;; opt-normalize-int-to-i64: wrap to the result width, then sign- or
;; zero-extend back to i64. Char is the 8-bit unsigned code unit.
(define (sccp-normalize-int-to-i64 [value : i64] [ty : i64]) : i64
  (let
    [klass : i64 (sccp-class-of ty)]
    (cond
      [(= klass sccp-class-sint)
        (let
          [width : i64 (sccp-int-width ty)]
          (if (= width 64)
            value
            (shr (shl value (- 64 width)) (- 64 width))))]
      [(= klass sccp-class-uint)
        (let
          [width : i64 (sccp-int-width ty)]
          (if (= width 64)
            value
            (bit-and value (- (shl 1 width) 1))))]
      [(= klass sccp-class-char) (bit-and value 255)]
      [else value])))

;; --- the lattice environment (OptSccpEnv) ------------------------------------
;; opt-sccp-env-fill-unknown!: the compiler allocates a fresh array per function
;; and writes Unknown into every slot; the array here is allocated once at the
;; corpus maximum and the same fill runs over [0, frame).
(define (sccp-env-fill-unknown! [env : (&mut e SccpEnv)] [n : i64] [i : i64]) : unit
  (if (>= i n)
    unit
    (begin
      (set! (array-ref env.slots i) (SccpValue.Unknown))
      (sccp-env-fill-unknown! env n (+ i 1)))))

;; opt-sccp-env-lookup: an out-of-range var reads Unknown, the same default the
;; original assoc list gave for an unbound var.
(define (sccp-env-lookup-in [env : (& e SccpEnv)] [var : i64]) : SccpValue
  (if (and (>= var 0) (< var env.cap))
    (clone (array-ref env.slots var))
    (SccpValue.Unknown)))

;; The lattice tag alone, read in place: 0 Unknown, 1 Const, 2 Overdefined.
(define (sccp-env-tag-in [env : (& e SccpEnv)] [var : i64]) : i64
  (if (and (>= var 0) (< var env.cap))
    (match (array-ref env.slots var)
      [(SccpValue.Unknown) 0]
      [(SccpValue.Const _ _ _) 1]
      [(SccpValue.Overdefined) 2])
    0))

;; The Const payload field `field` (0 kind, 1 value, 2 type), read in place.
(define (sccp-env-const-field-in
  [env : (& e SccpEnv)]
  [var : i64]
  [field : i64]) : i64
  (match (array-ref env.slots var)
    [(SccpValue.Const kind value ty)
      (cond [(= field 0) kind] [(= field 1) value] [else ty])]
    [_ 0]))

;; opt-sccp-env-make sizes a fresh array to the function frame; the array here
;; is allocated once at the corpus maximum, so the capacity the range checks
;; see is re-stamped per function.
(define (sccp-env-set-cap! [_env : (&mut e SccpEnv)] [cap : i64]) : unit
  (set! _env.cap cap))

;; opt-sccp-env-set: out-of-range writes are silently dropped.
(define (sccp-env-set-in!
  [env : (&mut e SccpEnv)]
  [var : i64]
  [value : SccpValue]) : unit
  (if (and (>= var 0) (< var env.cap))
    (set! (array-ref env.slots var) value)
    unit))

;; opt-sccp-env-any-const?: read once at analysis end; when false the whole
;; rewrite is the identity and the caller skips it.
(define (sccp-env-any-const-in? [env : (& e SccpEnv)] [index : i64]) : bool
  (if (>= index env.cap)
    false
    (if (= (sccp-env-tag-in env index) 1)
      true
      (sccp-env-any-const-in? env (+ index 1)))))

(defmacro (sccp-env-lookup [var : Expr]) : Expr
  `(sccp-env-lookup-in (& sccp-env) ,var))

(defmacro (sccp-env-tag [var : Expr]) : Expr
  `(sccp-env-tag-in (& sccp-env) ,var))

(defmacro (sccp-env-const-field [var : Expr] [field : Expr]) : Expr
  `(sccp-env-const-field-in (& sccp-env) ,var ,field))

(defmacro (sccp-env-set! [var : Expr] [value : Expr]) : Expr
  `(sccp-env-set-in! (&mut sccp-env) ,var ,value))

(define (sccp-exec-ref-in [flags : (& f SccpFlags)] [id : i64]) : bool
  (array-ref flags.slots id))

(define (sccp-exec-set-in! [flags : (&mut f SccpFlags)] [id : i64]) : unit
  (set! (array-ref flags.slots id) true))

(define (sccp-exec-clear-in! [flags : (&mut f SccpFlags)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref flags.slots i) false)
        (set! i (+ i 1))))))

(defmacro (sccp-exec-ref [id : Expr]) : Expr
  `(sccp-exec-ref-in (& sccp-exec) ,id))

;; --- opt-sccp-value-eq / opt-sccp-join ---------------------------------------
(define (sccp-value-eq [a : (& a SccpValue)] [b : (& b SccpValue)]) : bool
  (match a
    [(SccpValue.Unknown)
      (match b
        [(SccpValue.Unknown) true]
        [_ false])]
    [(SccpValue.Overdefined)
      (match b
        [(SccpValue.Overdefined) true]
        [_ false])]
    [(SccpValue.Const ak av aty)
      (match b
        [(SccpValue.Const bk bv bty)
          (and
            (= (deref ak) (deref bk))
            (= (deref av) (deref bv))
            (= (deref aty) (deref bty)))]
        [_ false])]))

(define (sccp-join [old : (& o SccpValue)] [new : (& n SccpValue)]) : SccpValue
  (match old
    [(SccpValue.Unknown)
      (match new
        [(SccpValue.Unknown) (SccpValue.Unknown)]
        [(SccpValue.Overdefined) (SccpValue.Overdefined)]
        [(SccpValue.Const nk nv nty)
          (SccpValue.Const (deref nk) (deref nv) (deref nty))])]
    [(SccpValue.Overdefined) (SccpValue.Overdefined)]
    [(SccpValue.Const ok ov oty)
      (match new
        [(SccpValue.Unknown)
          (SccpValue.Const (deref ok) (deref ov) (deref oty))]
        [(SccpValue.Overdefined) (SccpValue.Overdefined)]
        [(SccpValue.Const nk nv nty)
          (if (and
            (= (deref ok) (deref nk))
            (= (deref ov) (deref nv))
            (= (deref oty) (deref nty)))
            (SccpValue.Const (deref ok) (deref ov) (deref oty))
            (SccpValue.Overdefined))])]))

;; opt-sccp-state-bind: join the incoming value onto the slot; when the join
;; moves the slot, record it and raise the changed flag.
(define (sccp-state-bind [var : i64] [value : SccpValue]) : unit
  (let
    [old : SccpValue (sccp-env-lookup var)]
    [merged : SccpValue (sccp-join (& old) (& value))]
    (if (sccp-value-eq (& old) (& merged))
      unit
      (begin
        (sccp-env-set! var merged)
        (set! sccp-changed true)))))

;; --- the label index (opt-cfg-index-id) --------------------------------------
;; opt-cfg-index-id-map-capacity: the next power of two at or above 2 * count,
;; so a probe that misses always terminates on an empty slot.
(define (sccp-id-map-capacity [count : i64]) : i64
  (let
    [size : i64 2]
    (begin
      (while (< size (* count 2))
        (set! size (* size 2)))
      size)))

;; opt-cfg-index-id-slot: fold the high bits down, then mask.
(define (sccp-id-slot [label : i64] [mask : i64]) : i64
  (bit-and (bit-xor label (shr label 5)) mask))

;; opt-cfg-index-fill-id-map!: ids inserted in block order, an occupied slot
;; whose label matches left alone, so a duplicate label resolves to its first
;; block.
(define (sccp-cfg-index-build) : unit
  (let
    [cap : i64 (sccp-id-map-capacity sccp-nblocks)]
    [mask : i64 (- cap 1)]
    [i : i64 0]
    (begin
      (set! sccp-idmask mask)
      (while (< i cap)
        (begin
          (sccp-set! sccp-idmap i 0)
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i sccp-nblocks)
        (begin
          (sccp-set!
            sccp-labels
            i
            (sccp-ref sccp-tokens (+ sccp-block-base (* i 5))))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i sccp-nblocks)
        (let
          [label : i64 (sccp-ref sccp-labels i)]
          [slot : i64 (sccp-id-slot label mask)]
          [placed : bool false]
          (begin
            (while (not placed)
              (let
                [entry : i64 (sccp-ref sccp-idmap slot)]
                (if (= entry 0)
                  (begin
                    (sccp-set! sccp-idmap slot (+ i 1))
                    (set! placed true))
                  (if (= (sccp-ref sccp-labels (- entry 1)) label)
                    (set! placed true)
                    (set! slot (bit-and (+ slot 1) mask))))))
            (set! i (+ i 1))))))))

;; opt-cfg-index-id: -1 stands for option_i64.None.
(define (sccp-cfg-index-id [label : i64]) : i64
  (let
    [mask : i64 sccp-idmask]
    [slot : i64 (sccp-id-slot label mask)]
    [out : i64 -2]
    (begin
      (while (= out -2)
        (let
          [entry : i64 (sccp-ref sccp-idmap slot)]
          (if (= entry 0)
            (set! out -1)
            (if (= (sccp-ref sccp-labels (- entry 1)) label)
              (set! out (- entry 1))
              (set! slot (bit-and (+ slot 1) mask))))))
      out)))

;; opt-sccp-state-mark-executable.
(define (sccp-state-mark-executable [label : i64]) : unit
  (let
    [id : i64 (sccp-cfg-index-id label)]
    (if (and (>= id 0) (< id sccp-nblocks))
      (if (sccp-exec-ref id)
        unit
        (begin
          (sccp-exec-set-in! (&mut sccp-exec) id)
          (set! sccp-changed true)))
      unit)))

;; --- constants and the folder ------------------------------------------------
;; opt-normalize-const, with NoConst already mapped to the Overdefined that
;; opt-sccp-immediate turns it into.
(define (sccp-normalize-const [kind : i64] [value : i64] [ty : i64]) : SccpValue
  (let
    [klass : i64 (sccp-class-of ty)]
    (cond
      [(or (= klass sccp-class-sint) (= klass sccp-class-uint))
        (if (= kind sccp-vk-int)
          (SccpValue.Const sccp-vk-int (sccp-normalize-int-to-i64 value ty) ty)
          (SccpValue.Overdefined))]
      [(= klass sccp-class-char)
        (if (= kind sccp-vk-int)
          (SccpValue.Const sccp-vk-int (bit-and value 255) sccp-ty-char)
          (SccpValue.Overdefined))]
      [(= klass sccp-class-bool)
        (if (= kind sccp-vk-bool)
          (SccpValue.Const sccp-vk-bool value sccp-ty-bool)
          (SccpValue.Overdefined))]
      [else (SccpValue.Overdefined)])))

;; opt-sccp-immediate over opt-default-immediate-type.
(define (sccp-immediate [kind : i64] [value : i64] [ty : i64]) : SccpValue
  (let
    [fallback : i64
      (cond
        [(= kind sccp-vk-int)
          (if (sccp-int-or-char-type? ty)
            ty
            sccp-ty-i64)]
        [(= kind sccp-vk-bool) sccp-ty-bool]
        [else ty])]
    (sccp-normalize-const kind value fallback)))

;; opt-sccp-value.
(define (sccp-value [kind : i64] [payload : i64] [ty : i64]) : SccpValue
  (cond
    [(= kind sccp-vk-var) (sccp-env-lookup payload)]
    [(= kind sccp-vk-none) (SccpValue.Unknown)]
    [else (sccp-immediate kind payload ty)]))

;; opt-binop-operand-type.
(define (sccp-binop-operand-type
  [op : i64]
  [lhs-ty : i64]
  [rhs-ty : i64]
  [result-ty : i64]) : i64
  (cond
    [(or
        (= op sccp-op-eq)
        (= op sccp-op-ne)
        (= op sccp-op-lt)
        (= op sccp-op-le)
        (= op sccp-op-gt)
        (= op sccp-op-ge))
      (if (= lhs-ty sccp-ty-i64)
        rhs-ty
        (if (and (= lhs-ty sccp-ty-f64) (= rhs-ty sccp-ty-f32))
          rhs-ty
          lhs-ty))]
    [(or
        (= op sccp-op-bit-and)
        (= op sccp-op-bit-or)
        (= op sccp-op-bit-xor)
        (= op sccp-op-shl)
        (= op sccp-op-shr))
      lhs-ty]
    [else result-ty]))

;; opt-unsigned-lt? / opt-typed-lt?: only U64 needs the unsigned comparison;
;; every narrower unsigned value is already zero-extended.
(define (sccp-typed-lt? [a : i64] [b : i64] [ty : i64]) : bool
  (if (and (sccp-unsigned-integer-type? ty) (= (sccp-int-width ty) 64))
    (< (cast a : u64) (cast b : u64))
    (< a b)))

(define (sccp-fold-compare [op : i64] [a : i64] [b : i64] [ty : i64]) : bool
  (cond
    [(= op sccp-op-eq) (= a b)]
    [(= op sccp-op-ne) (not (= a b))]
    [(= op sccp-op-lt) (sccp-typed-lt? a b ty)]
    [(= op sccp-op-le) (or (= a b) (sccp-typed-lt? a b ty))]
    [(= op sccp-op-gt) (sccp-typed-lt? b a ty)]
    [else (or (= a b) (sccp-typed-lt? b a ty))]))

;; opt-signed-min for the divide/remainder refusal.
(define (sccp-signed-min [ty : i64]) : i64
  (let
    [width : i64 (sccp-int-width ty)]
    (if (= width 64)
      (- (- 0 9223372036854775807) 1)
      (- 0 (shl 1 (- width 1))))))

;; opt-divmod-valid?.
(define (sccp-divmod-valid? [a : i64] [b : i64] [ty : i64]) : bool
  (if (= b 0)
    false
    (if (sccp-signed-integer-type? ty)
      (not (and (= a (sccp-signed-min ty)) (= b -1)))
      true)))

;; opt-fold-div-value / opt-fold-mod-value: the operands arrive normalized to
;; the operand type, so the i64 (signed) or u64 (unsigned) operation is the
;; width-w one.
(define (sccp-fold-div-value [a : i64] [b : i64] [ty : i64]) : i64
  (if (sccp-signed-integer-type? ty)
    (/ a b)
    (cast (/ (cast a : u64) (cast b : u64)) : i64)))

(define (sccp-fold-mod-value [a : i64] [b : i64] [ty : i64]) : i64
  (if (sccp-signed-integer-type? ty)
    (% a b)
    (cast (% (cast a : u64) (cast b : u64)) : i64)))

;; opt-fold-shr-value: arithmetic for the signed widths, logical otherwise.
(define (sccp-fold-shr-value [a : i64] [count : i64] [ty : i64]) : i64
  (if (sccp-signed-integer-type? ty)
    (shr a count)
    (cast (shr (cast a : u64) (cast count : u64)) : i64)))

;; opt-shift-count-valid?.
(define (sccp-shift-count-valid? [count : i64] [count-ty : i64] [width : i64]) : bool
  (cond
    [(not (sccp-integer-type? count-ty)) false]
    [(sccp-signed-integer-type? count-ty) (and (>= count 0) (< count width))]
    [(= (sccp-int-width count-ty) 64) (< (cast count : u64) (cast width : u64))]
    [else (< count width)]))

;; opt-fold-shift.
(define (sccp-fold-shift
  [op : i64]
  [a : i64]
  [rhs-kind : i64]
  [rhs-value : i64]
  [rhs-ty : i64]
  [operand-ty : i64]
  [ty : i64]) : SccpValue
  (if (not (and (sccp-int-or-char-type? rhs-ty) (= rhs-kind sccp-vk-int)))
    (SccpValue.Overdefined)
    (let
      [count : i64 (sccp-normalize-int-to-i64 rhs-value rhs-ty)]
      (if (not
        (sccp-shift-count-valid? count rhs-ty (sccp-int-width operand-ty)))
        (SccpValue.Overdefined)
        (SccpValue.Const
          sccp-vk-int
          (sccp-normalize-int-to-i64
            (if (= op sccp-op-shl)
              (shl a count)
              (sccp-fold-shr-value a count operand-ty))
            operand-ty)
          ty)))))

;; opt-fold-bool.
(define (sccp-fold-bool
  [op : i64]
  [lhs-kind : i64]
  [lhs-value : i64]
  [rhs-kind : i64]
  [rhs-value : i64]
  [ty : i64]) : SccpValue
  (if (not (and (= lhs-kind sccp-vk-bool) (= rhs-kind sccp-vk-bool)))
    (SccpValue.Overdefined)
    (let
      [a : bool (not (= lhs-value 0))]
      [b : bool (not (= rhs-value 0))]
      (cond
        [(= op sccp-op-and)
          (SccpValue.Const
            sccp-vk-bool
            (if (and a b)
              1
              0)
            ty)]
        [(= op sccp-op-or)
          (SccpValue.Const
            sccp-vk-bool
            (if (or a b)
              1
              0)
            ty)]
        [(= op sccp-op-eq)
          (SccpValue.Const
            sccp-vk-bool
            (if (= lhs-value rhs-value)
              1
              0)
            ty)]
        [(= op sccp-op-ne)
          (SccpValue.Const
            sccp-vk-bool
            (if (= lhs-value rhs-value)
              0
              1)
            ty)]
        [else (SccpValue.Overdefined)]))))

;; opt-fold-int-char-binop's arithmetic arms: every one of these is gated on
;; `opt-integer-type?`, so `char` operands fall through to Overdefined.
(define (sccp-fold-int-arith
  [op : i64]
  [a : i64]
  [b : i64]
  [operand-ty : i64]
  [ty : i64]) : SccpValue
  (if (not (sccp-integer-type? operand-ty))
    (SccpValue.Overdefined)
    (cond
      [(= op sccp-op-add)
        (SccpValue.Const
          sccp-vk-int
          (sccp-normalize-int-to-i64 (+ a b) operand-ty)
          ty)]
      [(= op sccp-op-sub)
        (SccpValue.Const
          sccp-vk-int
          (sccp-normalize-int-to-i64 (- a b) operand-ty)
          ty)]
      [(= op sccp-op-mul)
        (SccpValue.Const
          sccp-vk-int
          (sccp-normalize-int-to-i64 (* a b) operand-ty)
          ty)]
      [(= op sccp-op-bit-and)
        (SccpValue.Const
          sccp-vk-int
          (sccp-normalize-int-to-i64 (bit-and a b) operand-ty)
          ty)]
      [(= op sccp-op-bit-or)
        (SccpValue.Const
          sccp-vk-int
          (sccp-normalize-int-to-i64 (bit-or a b) operand-ty)
          ty)]
      [(= op sccp-op-bit-xor)
        (SccpValue.Const
          sccp-vk-int
          (sccp-normalize-int-to-i64 (bit-xor a b) operand-ty)
          ty)]
      [(or (= op sccp-op-div) (= op sccp-op-safe-div))
        (if (sccp-divmod-valid? a b operand-ty)
          (SccpValue.Const sccp-vk-int (sccp-fold-div-value a b operand-ty) ty)
          (SccpValue.Overdefined))]
      [(or (= op sccp-op-mod) (= op sccp-op-safe-mod))
        (if (sccp-divmod-valid? a b operand-ty)
          (SccpValue.Const sccp-vk-int (sccp-fold-mod-value a b operand-ty) ty)
          (SccpValue.Overdefined))]
      [else (SccpValue.Overdefined)])))

;; opt-fold-int-char-binop.
(define (sccp-fold-int-char-binop
  [op : i64]
  [lhs-kind : i64]
  [lhs-value : i64]
  [rhs-kind : i64]
  [rhs-value : i64]
  [operand-ty : i64]
  [rhs-ty : i64]
  [ty : i64]) : SccpValue
  (if (not (and (sccp-int-or-char-type? operand-ty) (= lhs-kind sccp-vk-int)))
    (SccpValue.Overdefined)
    (let
      [a : i64 (sccp-normalize-int-to-i64 lhs-value operand-ty)]
      (if (or (= op sccp-op-shl) (= op sccp-op-shr))
        (sccp-fold-shift op a rhs-kind rhs-value rhs-ty operand-ty ty)
        (if (not (= rhs-kind sccp-vk-int))
          (SccpValue.Overdefined)
          (let
            [b : i64 (sccp-normalize-int-to-i64 rhs-value operand-ty)]
            (cond
              [(or
                  (= op sccp-op-eq)
                  (= op sccp-op-ne)
                  (= op sccp-op-lt)
                  (= op sccp-op-le)
                  (= op sccp-op-gt)
                  (= op sccp-op-ge))
                (SccpValue.Const
                  sccp-vk-bool
                  (if (sccp-fold-compare op a b operand-ty)
                    1
                    0)
                  ty)]
              [(= op sccp-op-bit-test-eq)
                (SccpValue.Const
                  sccp-vk-bool
                  (if (= (bit-and a b) 0)
                    1
                    0)
                  ty)]
              [(= op sccp-op-bit-test-ne)
                (SccpValue.Const
                  sccp-vk-bool
                  (if (= (bit-and a b) 0)
                    0
                    1)
                  ty)]
              [else (sccp-fold-int-arith op a b operand-ty ty)])))))))

;; opt-fold-binop. Float operand types reach the Overdefined arm (see DROPPED).
(define (sccp-fold-binop
  [op : i64]
  [lhs-kind : i64]
  [lhs-value : i64]
  [lhs-ty : i64]
  [rhs-kind : i64]
  [rhs-value : i64]
  [rhs-ty : i64]
  [ty : i64]
  [rhs-ty-field : i64]) : SccpValue
  (let
    [operand-ty : i64 (sccp-binop-operand-type op lhs-ty rhs-ty ty)]
    (cond
      [(sccp-bool-type? operand-ty)
        (sccp-fold-bool op lhs-kind lhs-value rhs-kind rhs-value ty)]
      [(sccp-int-or-char-type? operand-ty)
        (sccp-fold-int-char-binop
          op
          lhs-kind
          lhs-value
          rhs-kind
          rhs-value
          operand-ty
          rhs-ty-field
          ty)]
      [else (SccpValue.Overdefined)])))

;; opt-sccp-fold-binop-value.
(define (sccp-fold-binop-value
  [op : i64]
  [lhs : (& l SccpValue)]
  [rhs : (& r SccpValue)]
  [ty : i64]
  [rhs-ty-field : i64]) : SccpValue
  (match lhs
    [(SccpValue.Const lk lv lty)
      (match rhs
        [(SccpValue.Const rk rv rty)
          (sccp-fold-binop
            op
            (deref lk)
            (deref lv)
            (deref lty)
            (deref rk)
            (deref rv)
            (deref rty)
            ty
            rhs-ty-field)]
        [(SccpValue.Unknown) (SccpValue.Unknown)]
        [(SccpValue.Overdefined) (SccpValue.Overdefined)])]
    [(SccpValue.Unknown) (SccpValue.Unknown)]
    [(SccpValue.Overdefined) (SccpValue.Overdefined)]))

;; opt-fold-unop.
(define (sccp-fold-unop [op : i64] [kind : i64] [value : i64] [ty : i64]) : SccpValue
  (cond
    [(= op sccp-op-neg)
      (if (and (sccp-integer-type? ty) (= kind sccp-vk-int))
        (SccpValue.Const
          sccp-vk-int
          (sccp-normalize-int-to-i64
            (- 0 (sccp-normalize-int-to-i64 value ty))
            ty)
          ty)
        (SccpValue.Overdefined))]
    [(= op sccp-op-not)
      (if (and (sccp-bool-type? ty) (= kind sccp-vk-bool))
        (SccpValue.Const
          sccp-vk-bool
          (if (= value 0)
            1
            0)
          ty)
        (SccpValue.Overdefined))]
    [(= op sccp-op-bitnot)
      (if (and (sccp-integer-type? ty) (= kind sccp-vk-int))
        (SccpValue.Const
          sccp-vk-int
          (sccp-normalize-int-to-i64
            (bit-not (sccp-normalize-int-to-i64 value ty))
            ty)
          ty)
        (SccpValue.Overdefined))]
    [else (SccpValue.Overdefined)]))

;; opt-sccp-fold-unop-value.
(define (sccp-fold-unop-value [op : i64] [src : (& s SccpValue)] [ty : i64]) : SccpValue
  (match src
    [(SccpValue.Const kind value _)
      (sccp-fold-unop op (deref kind) (deref value) ty)]
    [(SccpValue.Unknown) (SccpValue.Unknown)]
    [(SccpValue.Overdefined) (SccpValue.Overdefined)]))

;; opt-fold-cast over compiler-finite-cast-fold's integer arms.
(define (sccp-fold-cast
  [kind : i64]
  [value : i64]
  [from-ty : i64]
  [to-ty : i64]) : SccpValue
  (if (not (and (sccp-int-or-char-type? from-ty) (= kind sccp-vk-int)))
    (SccpValue.Overdefined)
    (if (not (sccp-int-or-char-type? to-ty))
      (SccpValue.Overdefined)
      (SccpValue.Const
        sccp-vk-int
        (sccp-normalize-int-to-i64
          (sccp-normalize-int-to-i64 value from-ty)
          to-ty)
        to-ty))))

;; opt-sccp-fold-cast-value.
(define (sccp-fold-cast-value
  [src : (& s SccpValue)]
  [from-ty : i64]
  [to-ty : i64]) : SccpValue
  (match src
    [(SccpValue.Const kind value _)
      (sccp-fold-cast (deref kind) (deref value) from-ty to-ty)]
    [(SccpValue.Unknown) (SccpValue.Unknown)]
    [(SccpValue.Overdefined) (SccpValue.Overdefined)]))

;; --- phis --------------------------------------------------------------------
;; opt-sccp-phi-input-value: an input from a predecessor that is not executable
;; contributes Unknown.
(define (sccp-phi-input-value
  [pred : i64]
  [kind : i64]
  [value : i64]
  [ty : i64]) : SccpValue
  (let
    [id : i64 (sccp-cfg-index-id pred)]
    (if (and (>= id 0) (< id sccp-nblocks) (sccp-exec-ref id))
      (sccp-value kind value ty)
      (SccpValue.Unknown))))

;; opt-sccp-phi-value: join(first, phi-value(rest)), Unknown at the end.
(define (sccp-phi-value [base : i64] [count : i64] [ty : i64]) : SccpValue
  (if (<= count 0)
    (SccpValue.Unknown)
    (let
      [at : i64 (+ sccp-phi-base (* base 3))]
      [head : SccpValue
        (sccp-phi-input-value
          (sccp-ref sccp-tokens at)
          (sccp-ref sccp-tokens (+ at 1))
          (sccp-ref sccp-tokens (+ at 2))
          ty)]
      [rest : SccpValue (sccp-phi-value (+ base 1) (- count 1) ty)]
      (sccp-join (& head) (& rest)))))

;; --- terminators -------------------------------------------------------------
;; opt-sccp-mark-branch-targets: a Const bool marks only the taken successor, a
;; Const of any other shape and Overdefined mark both, Unknown marks none.
(define (sccp-mark-branch-targets
  [kind : i64]
  [payload : i64]
  [true-label : i64]
  [false-label : i64]) : unit
  (match (sccp-value kind payload sccp-ty-bool)
    [(SccpValue.Const value-kind value _)
      (if (= value-kind sccp-vk-bool)
        (if (= value 0)
          (sccp-state-mark-executable false-label)
          (sccp-state-mark-executable true-label))
        (begin
          (sccp-state-mark-executable true-label)
          (sccp-state-mark-executable false-label)))]
    [(SccpValue.Overdefined)
      (begin
        (sccp-state-mark-executable true-label)
        (sccp-state-mark-executable false-label))]
    [(SccpValue.Unknown) unit]))

;; opt-sccp-mark-switch-targets, over the block's successor row (index 0 is the
;; default label, which opt-sccp-process-instr marks first).
(define (sccp-mark-switch-targets [base : i64] [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (sccp-state-mark-executable
          (sccp-ref sccp-tokens (+ sccp-succ-base (+ base index))))
        (set! index (+ index 1))))))

;; --- the per-instruction dispatch (opt-sccp-process-instr) -------------------
(define (sccp-process-instr [succ-base : i64] [succ-count : i64] [row : i64]) : unit
  (let
    [at : i64 (+ sccp-instr-base (* row 8))]
    [op : i64 (sccp-ref sccp-tokens at)]
    [dst : i64 (sccp-ref sccp-tokens (+ at 1))]
    [ty : i64 (sccp-ref sccp-tokens (+ at 2))]
    [ty2 : i64 (sccp-ref sccp-tokens (+ at 3))]
    [a : i64 (sccp-ref sccp-tokens (+ at 4))]
    [akind : i64 (sccp-ref sccp-tokens (+ at 5))]
    [b : i64 (sccp-ref sccp-tokens (+ at 6))]
    [bkind : i64 (sccp-ref sccp-tokens (+ at 7))]
    (cond
      [(= op sccp-op-mov) (sccp-state-bind dst (sccp-value akind a ty))]
      [(= op sccp-op-overdef) (sccp-state-bind dst (SccpValue.Overdefined))]
      [(= op sccp-op-cast)
        (let
          [src : SccpValue (sccp-value akind a ty2)]
          (sccp-state-bind dst (sccp-fold-cast-value (& src) ty2 ty)))]
      [(= op sccp-op-phi) (sccp-state-bind dst (sccp-phi-value a b ty))]
      [(= op sccp-op-jump)
        (sccp-state-mark-executable
          (sccp-ref sccp-tokens (+ sccp-succ-base succ-base)))]
      [(= op sccp-op-branch)
        (sccp-mark-branch-targets
          akind
          a
          (sccp-ref sccp-tokens (+ sccp-succ-base succ-base))
          (sccp-ref sccp-tokens (+ sccp-succ-base (+ succ-base 1))))]
      [(= op sccp-op-switch) (sccp-mark-switch-targets succ-base succ-count)]
      [(or (= op sccp-op-other) (= op sccp-op-bounds)) unit]
      [(or
          (= op sccp-op-neg)
          (= op sccp-op-not)
          (= op sccp-op-bitnot)
          (= op sccp-op-sqrt))
        (let
          [src : SccpValue (sccp-value akind a ty)]
          (sccp-state-bind dst (sccp-fold-unop-value op (& src) ty)))]
      [else
        (let
          [lhs : SccpValue (sccp-value akind a ty)]
          [rhs : SccpValue (sccp-value bkind b ty2)]
          (sccp-state-bind
            dst
            (sccp-fold-binop-value op (& lhs) (& rhs) ty ty2)))])))

;; opt-sccp-process-instr-seq-from.
(define (sccp-process-instr-seq-from
  [succ-base : i64]
  [succ-count : i64]
  [row : i64]
  [last : i64]) : unit
  (if (>= row last)
    unit
    (begin
      (sccp-process-instr succ-base succ-count row)
      (sccp-process-instr-seq-from succ-base succ-count (+ row 1) last))))

;; opt-sccp-process-block: only executable blocks are walked.
(define (sccp-process-block [block : i64]) : unit
  (if (sccp-exec-ref block)
    (let
      [at : i64 (+ sccp-block-base (* block 5))]
      [succ-base : i64 (sccp-ref sccp-tokens (+ at 1))]
      [succ-count : i64 (sccp-ref sccp-tokens (+ at 2))]
      [first : i64 (sccp-ref sccp-tokens (+ at 3))]
      [count : i64 (sccp-ref sccp-tokens (+ at 4))]
      (sccp-process-instr-seq-from succ-base succ-count first (+ first count)))
    unit))

;; opt-sccp-process-blocks-from.
(define (sccp-process-blocks-from [block : i64]) : unit
  (if (>= block sccp-nblocks)
    unit
    (begin
      (sccp-process-block block)
      (sccp-process-blocks-from (+ block 1)))))

;; opt-sccp-analyze-fixed: sweep while something changed, bounded by
;; nblocks + 8 + 2 * ninstr.
(define (sccp-analyze-fixed [remaining : i64]) : unit
  (if (<= remaining 0)
    unit
    (begin
      (set! sccp-changed false)
      (set! sccp-sweeps (+ sccp-sweeps 1))
      (sccp-process-blocks-from 0)
      (if sccp-changed
        (sccp-analyze-fixed (- remaining 1))
        unit))))

;; opt-sccp-env-from-params-at: every parameter starts Overdefined.
(define (sccp-env-from-params-at [position : i64]) : unit
  (if (>= position sccp-nparams)
    unit
    (begin
      (sccp-env-set!
        (sccp-ref sccp-tokens (+ sccp-param-base (* position 2)))
        (SccpValue.Overdefined))
      (sccp-env-from-params-at (+ position 1)))))

;; --- the counted rewrite -----------------------------------------------------
;; opt-sccp-rewrite-value: a Var operand whose lattice slot is Const is
;; substituted; the kernel counts the substitution instead of building IR.
(define (sccp-rewrite-substitutes? [kind : i64] [payload : i64]) : bool
  (if (= kind sccp-vk-var)
    (= (sccp-env-tag payload) 1)
    false))

;; opt-sccp-instr-changes-successors?: the rewritten condition is a Bool
;; literal, so the branch becomes a jump.
(define (sccp-instr-changes-successors? [kind : i64] [payload : i64]) : bool
  (cond
    [(= kind sccp-vk-bool) true]
    [(= kind sccp-vk-var)
      (if (= (sccp-env-tag payload) 1)
        (= (sccp-env-const-field payload 0) sccp-vk-bool)
        false)]
    [else false]))

;; The i64 a rewritten bounds-check operand ends up being, or a sentinel.
(define (sccp-rewritten-i64 [kind : i64] [payload : i64] [miss : i64]) : i64
  (cond
    [(= kind sccp-vk-int) payload]
    [(= kind sccp-vk-var)
      (if (= (sccp-env-tag payload) 1)
        (if (and
          (= (sccp-env-const-field payload 0) sccp-vk-int)
          (sccp-integer-type? (sccp-env-const-field payload 2)))
          (sccp-env-const-field payload 1)
          miss)
        miss)]
    [else miss]))

;; opt-sccp-bounds-check-in-range?: only the in-range case is dropped, so an
;; out-of-range literal keeps its check and still traps.
(define (sccp-bounds-check-in-range?
  [akind : i64]
  [a : i64]
  [bkind : i64]
  [b : i64]) : bool
  (let
    [index : i64 (sccp-rewritten-i64 akind a -1)]
    [length : i64 (sccp-rewritten-i64 bkind b -1)]
    (and (>= index 0) (>= length 0) (< index length))))

(define (sccp-rewrite-phi [base : i64] [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (let
        [at : i64 (+ sccp-phi-base (* (+ base index) 3))]
        (begin
          (when
            (sccp-rewrite-substitutes?
              (sccp-ref sccp-tokens (+ at 1))
              (sccp-ref sccp-tokens (+ at 2)))
            (set! sccp-subs (+ sccp-subs 1)))
          (set! index (+ index 1)))))))

;; opt-sccp-rewrite-blocks / -rewrite-instr-seq / -blocks-change-successors?,
;; counted rather than materialised: every block is walked, executable or not.
(define (sccp-rewrite-rows [row : i64]) : unit
  (if (>= row sccp-ninstr)
    unit
    (let
      [at : i64 (+ sccp-instr-base (* row 8))]
      [op : i64 (sccp-ref sccp-tokens at)]
      [a : i64 (sccp-ref sccp-tokens (+ at 4))]
      [akind : i64 (sccp-ref sccp-tokens (+ at 5))]
      [b : i64 (sccp-ref sccp-tokens (+ at 6))]
      [bkind : i64 (sccp-ref sccp-tokens (+ at 7))]
      (begin
        (if (= op sccp-op-phi)
          (sccp-rewrite-phi a b)
          (begin
            (when
              (sccp-rewrite-substitutes? akind a)
              (set! sccp-subs (+ sccp-subs 1)))
            (when
              (sccp-rewrite-substitutes? bkind b)
              (set! sccp-subs (+ sccp-subs 1)))
            (cond
              [(= op sccp-op-branch)
                (when
                  (sccp-instr-changes-successors? akind a)
                  (set! sccp-branches (+ sccp-branches 1)))]
              [(= op sccp-op-bounds)
                (when
                  (sccp-bounds-check-in-range? akind a bkind b)
                  (set! sccp-dropped (+ sccp-dropped 1)))]
              [else unit])))
        (sccp-rewrite-rows (+ row 1))))))

;; --- one function ------------------------------------------------------------
;; opt-sccp-blocks-with-context-result-raw: build the label index, seed the
;; state, run the fixpoint, then rewrite only when the lattice holds a Const.
(define (sccp-function) : i64
  (let
    [hash : i64 sccp-hash-basis]
    [i : i64 0]
    [consts : i64 0]
    [dead : i64 0]
    [sweeps-before : i64 sccp-sweeps]
    (begin
      (sccp-cfg-index-build)
      (sccp-env-set-cap! (&mut sccp-env) sccp-frame)
      (sccp-env-fill-unknown! (&mut sccp-env) sccp-frame 0)
      (sccp-exec-clear-in! (&mut sccp-exec) sccp-nblocks)
      (sccp-env-from-params-at 0)
      (when (> sccp-nblocks 0) (sccp-exec-set-in! (&mut sccp-exec) 0))
      (set! sccp-changed true)
      (sccp-analyze-fixed (+ (+ sccp-nblocks 8) (* 2 sccp-ninstr)))
      (while (< i sccp-frame)
        (begin
          (when
            (= (sccp-env-tag i) 1)
            (begin
              (set! consts (+ consts 1))
              (set! hash (sccp-mix hash i))
              (set! hash (sccp-mix hash (sccp-env-const-field i 0)))
              (set! hash (sccp-mix hash (sccp-env-const-field i 1)))
              (set! hash (sccp-mix hash (sccp-env-const-field i 2)))))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i sccp-nblocks)
        (begin
          (when (not (sccp-exec-ref i)) (set! dead (+ dead 1)))
          (set!
            hash
            (sccp-mix
              hash
              (if (sccp-exec-ref i)
                1
                0)))
          (set! i (+ i 1))))
      (set! sccp-consts (+ sccp-consts consts))
      (set! sccp-dead (+ sccp-dead dead))
      (when (sccp-env-any-const-in? (& sccp-env) 0) (sccp-rewrite-rows 0))
      (set! hash (sccp-mix hash consts))
      (set! hash (sccp-mix hash dead))
      (set! hash (sccp-mix hash (- sccp-sweeps sweeps-before)))
      (set! hash (sccp-mix hash sccp-subs))
      (set! hash (sccp-mix hash sccp-branches))
      (sccp-mix hash sccp-dropped))))

(define (sccp-bench [path : String] [rounds : i64]) : i64
  (let
    [text : String (byte_buf.to-string (io.read-file path))]
    [capacity : i64 (+ (/ (string.string-length text) 2) 8)]
    [ntypes : i64 0]
    [functions : i64 0]
    [cursor : i64 0]
    [expect-base : i64 0]
    [max-frame : i64 1]
    [max-blocks : i64 1]
    [max-idmap : i64 2]
    [round : i64 0]
    [start : i64 0]
    [acc : i64 sccp-hash-basis]
    (begin
      (set! sccp-tokens (sccp-zero-vec capacity))
      (set! acc (sccp-mix acc (sccp-scan-ints text (&mut sccp-tokens))))
      (set! ntypes (sccp-ref sccp-tokens 0))
      (set! sccp-type-class (sccp-zero-vec (+ ntypes 1)))
      (set! sccp-type-width (sccp-zero-vec (+ ntypes 1)))
      (let
        [t : i64 0]
        (while (< t ntypes)
          (begin
            (sccp-set! sccp-type-class t (sccp-ref sccp-tokens (+ 1 (* t 2))))
            (sccp-set! sccp-type-width t (sccp-ref sccp-tokens (+ 2 (* t 2))))
            (set! t (+ t 1)))))
      (set! expect-base (+ 1 (* ntypes 2)))
      (set! cursor (+ expect-base 5))
      (set! functions (sccp-ref sccp-tokens cursor))
      (set! cursor (+ cursor 1))
      (set! sccp-offsets (sccp-zero-vec (+ functions 1)))
      (let
        [f : i64 0]
        (while (< f functions)
          (let
            [frame : i64 (sccp-ref sccp-tokens cursor)]
            [nparams : i64 (sccp-ref sccp-tokens (+ cursor 1))]
            [nblocks : i64 (sccp-ref sccp-tokens (+ cursor 2))]
            [nsucc : i64 (sccp-ref sccp-tokens (+ cursor 3))]
            [nphi : i64 (sccp-ref sccp-tokens (+ cursor 4))]
            [ninstr : i64 (sccp-ref sccp-tokens (+ cursor 5))]
            (begin
              (sccp-set! sccp-offsets f cursor)
              (when (> frame max-frame) (set! max-frame frame))
              (when (> nblocks max-blocks) (set! max-blocks nblocks))
              (set!
                cursor
                (+
                  cursor
                  (+
                    6
                    (+
                      (+ (* nparams 2) nsucc)
                      (+ (* nphi 3) (+ (* nblocks 5) (* ninstr 8)))))))
              (set! f (+ f 1))))))
      (set! max-idmap (sccp-id-map-capacity max-blocks))
      (set! sccp-env (SccpEnv (__tl_make-array SccpValue max-frame) max-frame))
      (set! sccp-exec (SccpFlags (__tl_make-array bool max-blocks) max-blocks))
      (set! sccp-labels (sccp-zero-vec (+ max-blocks 1)))
      (set! sccp-idmap (sccp-zero-vec (+ max-idmap 1)))
      (while (< round rounds)
        (let
          [step : i64 0]
          [index : i64 0]
          [offset : i64 0]
          (begin
            (set! acc (sccp-mix acc round))
            (while (< step functions)
              (begin
                (set! index (+ start step))
                (when (>= index functions) (set! index (- index functions)))
                (set! offset (sccp-ref sccp-offsets index))
                (set! sccp-frame (sccp-ref sccp-tokens offset))
                (set! sccp-nparams (sccp-ref sccp-tokens (+ offset 1)))
                (set! sccp-nblocks (sccp-ref sccp-tokens (+ offset 2)))
                (set! sccp-ninstr (sccp-ref sccp-tokens (+ offset 5)))
                (set! sccp-param-base (+ offset 6))
                (set! sccp-succ-base (+ sccp-param-base (* sccp-nparams 2)))
                (set!
                  sccp-phi-base
                  (+ sccp-succ-base (sccp-ref sccp-tokens (+ offset 3))))
                (set!
                  sccp-block-base
                  (+ sccp-phi-base (* (sccp-ref sccp-tokens (+ offset 4)) 3)))
                (set! sccp-instr-base (+ sccp-block-base (* sccp-nblocks 5)))
                (set! acc (sccp-mix acc (sccp-function)))
                (set! step (+ step 1))))
            (set! start (+ start 1))
            (when (>= start functions) (set! start 0))
            (set! round (+ round 1)))))
      (set! acc (sccp-mix acc sccp-consts))
      (set! acc (sccp-mix acc sccp-dead))
      (set! acc (sccp-mix acc sccp-subs))
      (set! acc (sccp-mix acc sccp-branches))
      (set! acc (sccp-mix acc sccp-dropped))
      (if (and
        (= sccp-consts (* (sccp-ref sccp-tokens expect-base) rounds))
        (= sccp-dead (* (sccp-ref sccp-tokens (+ expect-base 1)) rounds))
        (= sccp-subs (* (sccp-ref sccp-tokens (+ expect-base 2)) rounds))
        (= sccp-branches (* (sccp-ref sccp-tokens (+ expect-base 3)) rounds))
        (= sccp-dropped (* (sccp-ref sccp-tokens (+ expect-base 4)) rounds)))
        acc
        (begin
          (set! sccp-self-check-ok false)
          acc)))))

(define (main) : i64
  (let
    [path : String (io.arg 1)]
    [rounds : i64 (string.>int (io.arg 2))]
    [value : i64 (sccp-bench path rounds)]
    (begin
      (io.println "{}" value)
      (if sccp-self-check-ok
        0
        1))))