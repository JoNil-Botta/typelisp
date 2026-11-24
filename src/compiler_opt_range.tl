;; compiler_opt_range.tl - Dominator-scoped Value-Range + KnownBits / CVP pass.
;;
;; Forward dominator-tree abstract interpretation tracking:
;;   1. Strictly wrapping-safe signed 64-bit closed intervals [lo, hi]
;;      (never assumes nsw; any arithmetic overflow falls back to Top).
;;   2. Per-bit (known_zero, known_one) masks tightened bidirectionally
;;      against [lo, hi].
;;   3. Scoped relational upper-bound facts (v < u, v <= u, passed checks).
;;
;; Rewrites preserve block labels and CFG edges (decided branches rewrite their
;; condition to a Bool literal rather than changing terminators), so the
;; caller's OptCfgContext stays valid for downstream sccp/cfg passes.
(import compiler_ast_types as ast)
(import compiler_backend_div_magic as be_div)
(import compiler_ir_types as ir)
(import stdlib.arena)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as opt_i64_i64_map)
(import stdlib.iterator)
(import stdlib.option)
(import (option.option i64) as option_i64)

(define opt-range-i64-max : i64
  9223372036854775807)
(define opt-range-i64-min : i64
  (- (- 0 9223372036854775807) 1))
(define opt-range-u64-all-ones : u64
  (cast (- 0 1) : u64))
(define opt-range-u64-sign-bit : u64
  (shl (cast 1 : u64) 63))
(define opt-range-kind-top : i64
  0)
(define opt-range-kind-known : i64
  1)
(define opt-range-kind-bottom : i64
  2)

(defstruct OptRangeVal
  (lo i64)
  (hi i64)
  (kz u64)
  (ko u64)
  (kind i64))

(defenum OptRangeResult
  (Result ir.CompilerIrBlockList bool))

(defstruct OptRangeTrailEntry
  (var i64)
  (val OptRangeVal))

;; Scoped relational fact: lhs + offset < rhs (strict? = true) or <= rhs.
;; For a passed bounds check `bounds_check idx, len`: when `len` is a runtime
;; length (<= INT64_MAX), `idx` is in [0, len - 1] so we record `idx < len`.
;; `kind = 0`: `lhs < rhs` (signed, with `lhs >= 0` tracked separately or checked)
;; `kind = 1`: `lhs <= rhs` (signed)
;; `kind = 2`: passed `bounds_check (lhs + offset), rhs` (offset >= 0)
(defstruct OptRangeRelFact
  (kind i64)
  (lhs i64)
  (rhs i64)
  (offset i64))

;; Compact per-var definition metadata collected in one pre-scan over the
;; function's blocks (allocated in the per-function scratch arena).
;; `def-kind`:
;;   0 = none / unsupported / multi-def / addr-taken
;;   1 = Mov (arg0 = src var, or -1)
;;   2 = BinOp (block = block-id, pos = instr-pos)
;;   3 = UnOp (block = block-id, pos = instr-pos)
;;   4 = Cast (block = block-id, pos = instr-pos)
;;   5 = Phi (block = block-id, pos = instr-pos)
;;   6 = Word (block = block-id, pos = instr-pos)
;;   7 = Select (block = block-id, pos = instr-pos)
;;   8 = Load (block = block-id, pos = instr-pos)
;;   9 = Gep (block = block-id, pos = instr-pos)
;; `var-flags` bits: 1=desc-handle 2=len-slot-ptr 4=shift-count-var 8=loop-header-phi 16=addr-taken
(defstruct OptRangeState
  (outer-arena arena.Arena)
  (type-segment-bases i64)
  (frame i64)
  (block-count i64)
  (vals (__tl_dyn-array OptRangeVal))
  (def-count (__tl_dyn-array i64))
  (def-kind (__tl_dyn-array i64))
  (def-block (__tl_dyn-array i64))
  (def-pos (__tl_dyn-array i64))
  (var-width (__tl_dyn-array i64))
  (copy-src (__tl_dyn-array i64))
  (var-flags (__tl_dyn-array i64))
  (trail (__tl_dyn-array OptRangeTrailEntry))
  (trail-len i64)
  (trail-cap i64)
  (rels (__tl_dyn-array OptRangeRelFact))
  (rel-len i64)
  (rel-cap i64)
  (block-dead (__tl_dyn-array bool))
  (dom-child-off (__tl_dyn-array i64))
  (dom-child-ids (__tl_dyn-array i64))
  (out-blocks (__tl_dyn-array ir.CompilerIrBlock))
  (out-changed (__tl_dyn-array bool))
  (any-changed bool))

(define (opt-range-i64-arr [n : i64]) : (__tl_dyn-array i64)
  (__tl_make-array i64 n))

(define (opt-range-bool-arr [n : i64]) : (__tl_dyn-array bool)
  (__tl_make-array bool n))

(define (opt-range-val-arr [n : i64]) : (__tl_dyn-array OptRangeVal)
  (__tl_make-array OptRangeVal n))

(define (opt-range-val-copy [v : (& OptRangeVal)]) : OptRangeVal
  (OptRangeVal v.lo v.hi v.kz v.ko v.kind))

(define (opt-range-trail-copy [te : (& OptRangeTrailEntry)]) : OptRangeTrailEntry
  (OptRangeTrailEntry te.var (opt-range-val-copy (& te.val))))

(define (opt-range-rel-copy [rf : (& OptRangeRelFact)]) : OptRangeRelFact
  (OptRangeRelFact rf.kind rf.lhs rf.rhs rf.offset))

(define (opt-range-flag? [st : (& OptRangeState)] [var : i64] [bit : i64]) : bool
  (and
    (>= var 0)
    (< var st.frame)
    (!= (bit-and (array-ref st.var-flags var) bit) 0)))

(define (opt-range-flag-set!
  [st : (&mut OptRangeState)]
  [var : i64]
  [bit : i64]) : unit
  (when
    (and (>= var 0) (< var st.frame))
    (set!
      (array-ref st.var-flags var)
      (bit-or (array-ref st.var-flags var) bit))))

;; --- Wrapping-safe arithmetic helpers ----------------------------------------
(define (opt-range-min-i64 [a : i64] [b : i64]) : i64
  (if (< a b)
    a
    b))

(define (opt-range-max-i64 [a : i64] [b : i64]) : i64
  (if (> a b)
    a
    b))

(define (opt-range-safe-add [a : i64] [b : i64]) : option_i64.Option
  (cond
    [(and (> b 0) (> a (- opt-range-i64-max b))) (None)]
    [(and (< b 0) (< a (- opt-range-i64-min b))) (None)]
    [else (Some (+ a b))]))

(define (opt-range-safe-sub [a : i64] [b : i64]) : option_i64.Option
  (cond
    [(and (< b 0) (> a (+ opt-range-i64-max b))) (None)]
    [(and (> b 0) (< a (+ opt-range-i64-min b))) (None)]
    [else (Some (- a b))]))

(define (opt-range-safe-mul [a : i64] [b : i64]) : option_i64.Option
  (cond
    [(or (= a 0) (= b 0)) (Some 0)]
    [(= a 1) (Some b)]
    [(= b 1) (Some a)]
    [(and (= a opt-range-i64-min) (= b -1)) (None)]
    [(and (= b opt-range-i64-min) (= a -1)) (None)]
    [(or (= a opt-range-i64-min) (= b opt-range-i64-min)) (None)]
    [else
      (let
        [neg? : bool (not (= (< a 0) (< b 0)))]
        [aa : i64
          (if (< a 0)
            (- 0 a)
            a)]
        [bb : i64
          (if (< b 0)
            (- 0 b)
            b)]
        (if (<= aa (/ opt-range-i64-max bb))
          (Some (* a b))
          (if (and
            neg?
            (= (* (cast aa : u64) (cast bb : u64)) opt-range-u64-sign-bit))
            (Some opt-range-i64-min)
            (None))))]))

(define (opt-range-u64-fill-right [x : u64]) : u64
  (let
    [v : u64 x]
    (set! v (bit-or v (shr v 1)))
    (set! v (bit-or v (shr v 2)))
    (set! v (bit-or v (shr v 4)))
    (set! v (bit-or v (shr v 8)))
    (set! v (bit-or v (shr v 16)))
    (set! v (bit-or v (shr v 32)))
    v))

(define (opt-range-u64-low-mask [bits : i64]) : u64
  (cond
    [(<= bits 0) (cast 0 : u64)]
    [(>= bits 64) opt-range-u64-all-ones]
    [else (- (shl (cast 1 : u64) bits) (cast 1 : u64))]))

;; --- Range constructors & cross-tightening -----------------------------------
(define (opt-range-top) : OptRangeVal
  (OptRangeVal
    opt-range-i64-min
    opt-range-i64-max
    (cast 0 : u64)
    (cast 0 : u64)
    opt-range-kind-top))

(define (opt-range-bottom) : OptRangeVal
  (OptRangeVal
    0
    -1
    opt-range-u64-all-ones
    opt-range-u64-all-ones
    opt-range-kind-bottom))

(define (opt-range-const [c : i64]) : OptRangeVal
  (let
    [u : u64 (cast c : u64)]
    (OptRangeVal c c (bit-not u) u opt-range-kind-known)))

(define (opt-range-tighten
  [lo-in : i64]
  [hi-in : i64]
  [kz-in : u64]
  [ko-in : u64]) : OptRangeVal
  (if (or (> lo-in hi-in) (not (= (bit-and kz-in ko-in) (cast 0 : u64))))
    (opt-range-bottom)
    (let
      [lo : i64 lo-in]
      [hi : i64 hi-in]
      [kz : u64 kz-in]
      [ko : u64 ko-in]
      ;; Derive known prefix bits when [lo, hi] stays in one sign half.
      (when
        (or (>= lo 0) (< hi 0))
        (let
          [lu : u64 (cast lo : u64)]
          [hu : u64 (cast hi : u64)]
          [diff : u64 (bit-xor lu hu)]
          [same-mask : u64 (bit-not (opt-range-u64-fill-right diff))]
          (set! kz (bit-or kz (bit-and same-mask (bit-not lu))))
          (set! ko (bit-or ko (bit-and same-mask lu)))))
      (when
        (not (= (bit-and kz ko) (cast 0 : u64)))
        (return (opt-range-bottom)))
      ;; Tighten [lo, hi] from known sign bit and known zero/one masks.
      (when
        (or
          (not (= (bit-and kz opt-range-u64-sign-bit) (cast 0 : u64)))
          (not (= (bit-and ko opt-range-u64-sign-bit) (cast 0 : u64))))
        (let
          [bit-lo : i64 (cast ko : i64)]
          [bit-hi : i64 (cast (bit-not kz) : i64)]
          (when (> bit-lo lo) (set! lo bit-lo))
          (when (< bit-hi hi) (set! hi bit-hi))))
      (if (> lo hi)
        (opt-range-bottom)
        (if (and
          (= lo opt-range-i64-min)
          (= hi opt-range-i64-max)
          (= kz (cast 0 : u64))
          (= ko (cast 0 : u64)))
          (opt-range-top)
          (OptRangeVal lo hi kz ko opt-range-kind-known))))))

(define (opt-range-interval [lo : i64] [hi : i64]) : OptRangeVal
  (opt-range-tighten lo hi (cast 0 : u64) (cast 0 : u64)))

(define (opt-range-bits [kz : u64] [ko : u64]) : OptRangeVal
  (opt-range-tighten opt-range-i64-min opt-range-i64-max kz ko))

(define (opt-range-is-const? [r : (& OptRangeVal)]) : bool
  (and (= r.kind opt-range-kind-known) (= r.lo r.hi)))

(define (opt-range-meet [a : (& OptRangeVal)] [b : (& OptRangeVal)]) : OptRangeVal
  (cond
    [(or (= a.kind opt-range-kind-bottom) (= b.kind opt-range-kind-bottom))
      (opt-range-bottom)]
    [(= a.kind opt-range-kind-top) (OptRangeVal b.lo b.hi b.kz b.ko b.kind)]
    [(= b.kind opt-range-kind-top) (OptRangeVal a.lo a.hi a.kz a.ko a.kind)]
    [else
      (opt-range-tighten
        (opt-range-max-i64 a.lo b.lo)
        (opt-range-min-i64 a.hi b.hi)
        (bit-or a.kz b.kz)
        (bit-or a.ko b.ko))]))

(define (opt-range-join [a : (& OptRangeVal)] [b : (& OptRangeVal)]) : OptRangeVal
  (cond
    [(= a.kind opt-range-kind-bottom) (OptRangeVal b.lo b.hi b.kz b.ko b.kind)]
    [(= b.kind opt-range-kind-bottom) (OptRangeVal a.lo a.hi a.kz a.ko a.kind)]
    [(or (= a.kind opt-range-kind-top) (= b.kind opt-range-kind-top))
      (opt-range-top)]
    [else
      (opt-range-tighten
        (opt-range-min-i64 a.lo b.lo)
        (opt-range-max-i64 a.hi b.hi)
        (bit-and a.kz b.kz)
        (bit-and a.ko b.ko))]))

(define (opt-range-subset? [sub : (& OptRangeVal)] [sup : (& OptRangeVal)]) : bool
  (cond
    [(= sub.kind opt-range-kind-bottom) true]
    [(= sup.kind opt-range-kind-top) true]
    [(or (= sub.kind opt-range-kind-top) (= sup.kind opt-range-kind-bottom))
      false]
    [else
      (and
        (>= sub.lo sup.lo)
        (<= sub.hi sup.hi)
        (= (bit-and sup.kz (bit-not sub.kz)) (cast 0 : u64))
        (= (bit-and sup.ko (bit-not sub.ko)) (cast 0 : u64)))]))

(define (opt-range-eq? [a : (& OptRangeVal)] [b : (& OptRangeVal)]) : bool
  (and
    (= a.kind b.kind)
    (= a.lo b.lo)
    (= a.hi b.hi)
    (= a.kz b.kz)
    (= a.ko b.ko)))

;; --- Type classification helpers ---------------------------------------------
(define (opt-range-type-signed? [ty : (& ast.AstType)]) : bool
  (match ty
    [(or (I64) (I32) (I16) (I8)) true]
    [_ false]))

(define (opt-range-type-unsigned? [ty : (& ast.AstType)]) : bool
  (match ty
    [(or (U64) (U32) (U16) (U8) (Bool) (Char)) true]
    [_ false]))

(define (opt-range-type-int-width [ty : (& ast.AstType)]) : i64
  (match ty
    [(or (I64) (U64)) 64]
    [(or (I32) (U32) (Char)) 32]
    [(or (I16) (U16)) 16]
    [(or (I8) (U8)) 8]
    [(Bool) 1]
    [_ 0]))

(define (opt-range-type-is-i64? [ty : (& ast.AstType)]) : bool
  (match ty
    [(I64) true]
    [_ false]))

(define (opt-range-type-is-u64? [ty : (& ast.AstType)]) : bool
  (match ty
    [(U64) true]
    [_ false]))

(define (opt-range-range-for-type [ty : (& ast.AstType)]) : OptRangeVal
  (match ty
    [(Bool) (opt-range-interval 0 1)]
    [(U8) (opt-range-interval 0 255)]
    [(U16) (opt-range-interval 0 65535)]
    [(U32) (opt-range-interval 0 4294967295)]
    [(I8) (opt-range-interval -128 127)]
    [(I16) (opt-range-interval -32768 32767)]
    [(I32) (opt-range-interval -2147483648 2147483647)]
    [(Char) (opt-range-interval 0 1114111)]
    [_ (opt-range-top)]))

(define (opt-range-descriptor-handle-type?
  [type-segment-bases : i64]
  [ty : (& ast.AstType)]) : bool
  (match ty
    [(or (String) (Str) (Bytes) (DynArray _) (Slice _)) true]
    [(or (Ref _ inner) (MutRef _ inner))
      (or
        (ast.ast-type-segment-bases-fat-referent? type-segment-bases inner)
        (opt-range-descriptor-handle-type?
          type-segment-bases
          (& (ast.ast-type-segment-bases-get type-segment-bases inner))))]
    [(Region _ inner)
      (opt-range-descriptor-handle-type?
        type-segment-bases
        (& (ast.ast-type-segment-bases-get type-segment-bases inner)))]
    [_ false]))

;; --- Scoped state & undo trail -----------------------------------------------
(define (opt-range-addr-taken? [st : (& OptRangeState)] [var : i64]) : bool
  (or (< var 0) (>= var st.frame) (opt-range-flag? st var 16)))

(define (opt-range-var-trackable? [st : (& OptRangeState)] [var : i64]) : bool
  (and
    (>= var 0)
    (< var st.frame)
    (not (opt-range-addr-taken? st var))
    (<= (array-ref st.def-count var) 1)))

(define (opt-range-var-get [st : (& OptRangeState)] [var : i64]) : OptRangeVal
  (if (not (opt-range-var-trackable? st var))
    (opt-range-top)
    (opt-range-val-copy (& (array-ref st.vals var)))))

(define (opt-range-trail-grow! [st : (&mut OptRangeState)]) : unit
  (let
    [old-cap : i64 st.trail-cap]
    [new-cap : i64
      (if (< old-cap 64)
        64
        (* old-cap 2))]
    [nt : (__tl_dyn-array OptRangeTrailEntry)
      (__tl_make-array OptRangeTrailEntry new-cap)]
    (for [i (iterator.range 0 st.trail-len)]
      (set! (array-ref nt i) (opt-range-trail-copy (& (array-ref st.trail i)))))
    (set! st.trail nt)
    (set! st.trail-cap new-cap)))

(define (opt-range-var-set!
  [st : (&mut OptRangeState)]
  [var : i64]
  [val : (& OptRangeVal)]) : unit
  (when
    (opt-range-var-trackable? st var)
    (let
      [old : OptRangeVal (opt-range-val-copy (& (array-ref st.vals var)))]
      (when
        (or
          (!= old.kind val.kind)
          (!= old.lo val.lo)
          (!= old.hi val.hi)
          (!= old.kz val.kz)
          (!= old.ko val.ko))
        (when (>= st.trail-len st.trail-cap) (opt-range-trail-grow! st))
        (let
          [idx : i64 st.trail-len]
          (set! (array-ref st.trail idx) (OptRangeTrailEntry var old))
          (set! st.trail-len (+ idx 1)))
        (set! (array-ref st.vals var) (opt-range-val-copy val))))))

(define (opt-range-var-refine!
  [st : (&mut OptRangeState)]
  [var : i64]
  [bound : (& OptRangeVal)]) : unit
  (when
    (opt-range-var-trackable? st var)
    (let
      [cur : OptRangeVal (opt-range-var-get st var)]
      [next : OptRangeVal (opt-range-meet (& cur) bound)]
      (opt-range-var-set! st var (& next)))))

(define (opt-range-trail-rollback! [st : (&mut OptRangeState)] [mark : i64]) : unit
  (while (> st.trail-len mark)
    (let
      [idx : i64 (- st.trail-len 1)]
      [te : OptRangeTrailEntry
        (opt-range-trail-copy (& (array-ref st.trail idx)))]
      (set! (array-ref st.vals te.var) te.val)
      (set! st.trail-len idx))))

(define (opt-range-rel-push!
  [st : (&mut OptRangeState)]
  [kind : i64]
  [lhs : i64]
  [rhs : i64]
  [offset : i64]) : unit
  (when
    (and
      (>= lhs 0)
      (>= rhs 0)
      (opt-range-var-trackable? st lhs)
      (opt-range-var-trackable? st rhs))
    (when
      (>= st.rel-len st.rel-cap)
      (let
        [old-cap : i64 st.rel-cap]
        [new-cap : i64
          (if (< old-cap 32)
            32
            (* old-cap 2))]
        [nr : (__tl_dyn-array OptRangeRelFact)
          (__tl_make-array OptRangeRelFact new-cap)]
        (for [i (iterator.range 0 st.rel-len)]
          (set! (array-ref nr i) (opt-range-rel-copy (& (array-ref st.rels i)))))
        (set! st.rels nr)
        (set! st.rel-cap new-cap)))
    (let
      [idx : i64 st.rel-len]
      (set! (array-ref st.rels idx) (OptRangeRelFact kind lhs rhs offset))
      (set! st.rel-len (+ idx 1)))))

(define (opt-range-resolve-copy [st : (& OptRangeState)] [var : i64]) : i64
  (let
    [cur : i64 var]
    [steps : i64 0]
    (while (and (>= cur 0) (< cur st.frame) (< steps 16))
      (let
        [src : i64 (array-ref st.copy-src cur)]
        (if (and (>= src 0) (opt-range-var-trackable? st cur))
          (begin
            (set! cur src)
            (+= steps 1))
          (set! steps 16))))
    cur))

(define (opt-range-value-get
  [st : (& OptRangeState)]
  [nonneg-globals : (& opt_i64_i64_map.Map)]
  [val : (& ir.CompilerIrValue)]) : OptRangeVal
  (match val
    [(I64 c) (opt-range-const c)]
    [(Bool b)
      (opt-range-const
        (if b
          1
          0))]
    [(Char ch) (opt-range-const (cast ch : i64))]
    [(Var v)
      (let
        [r1 : OptRangeVal (opt-range-var-get st v)]
        [root : i64 (opt-range-resolve-copy st v)]
        (if (= root v)
          r1
          (let
            [r2 : OptRangeVal (opt-range-var-get st root)]
            (opt-range-meet (& r1) (& r2)))))]
    [(Global sym)
      (match (opt_i64_i64_map.get nonneg-globals sym)
        [(LookupFound _) (opt-range-interval 0 opt-range-i64-max)]
        [(LookupMissing) (opt-range-top)])]
    [_ (opt-range-top)]))

;; --- Transfer functions (strictly wrapping-safe) -----------------------------
(define (opt-range-u64-bounds [r : (& OptRangeVal)]) : OptRangeVal
  ;; Reuse OptRangeVal.lo / hi bits to carry unsigned [ulo, uhi] as kz/ko:
  ;; kz = ulo, ko = uhi.
  (cond
    [(= r.kind opt-range-kind-bottom)
      (OptRangeVal
        0
        0
        opt-range-u64-all-ones
        (cast 0 : u64)
        opt-range-kind-bottom)]
    [(= r.kind opt-range-kind-top)
      (OptRangeVal 0 0 (cast 0 : u64) opt-range-u64-all-ones opt-range-kind-top)]
    [(or (>= r.lo 0) (< r.hi 0))
      (let
        [ulo : u64 (cast r.lo : u64)]
        [uhi : u64 (cast r.hi : u64)]
        (OptRangeVal 0 0 ulo uhi opt-range-kind-known))]
    [else
      (let
        [ulo : u64 r.ko]
        [uhi : u64 (bit-not r.kz)]
        (OptRangeVal 0 0 ulo uhi opt-range-kind-known))]))

(define (opt-range-clamp-unsigned [r : (& OptRangeVal)] [w : i64]) : OptRangeVal
  (let
    [mask : u64 (opt-range-u64-low-mask w)]
    [kz : u64 (bit-or r.kz (bit-not mask))]
    [ko : u64 (bit-and r.ko mask)]
    [max-u : i64 (cast mask : i64)]
    (if (and (= r.kind opt-range-kind-known) (>= r.lo 0) (<= r.hi max-u))
      (opt-range-tighten r.lo r.hi kz ko)
      (opt-range-tighten 0 max-u kz ko))))

(define (opt-range-clamp-signed [r : (& OptRangeVal)] [ty : (& ast.AstType)]) : OptRangeVal
  (let
    [type-r : OptRangeVal (opt-range-range-for-type ty)]
    (if (and
      (= r.kind opt-range-kind-known)
      (>= r.lo type-r.lo)
      (<= r.hi type-r.hi))
      (opt-range-val-copy r)
      type-r)))

(define (opt-range-eval-cast
  [r : (& OptRangeVal)]
  [from-ty : (& ast.AstType)]
  [to-ty : (& ast.AstType)]) : OptRangeVal
  (let
    [fw : i64 (opt-range-type-int-width from-ty)]
    [tw : i64 (opt-range-type-int-width to-ty)]
    (cond
      [(or (= fw 0) (= tw 0)) (opt-range-top)]
      [(= r.kind opt-range-kind-bottom) (opt-range-bottom)]
      [(and (= fw 64) (= tw 64)) (opt-range-val-copy r)]
      [(and (< fw 64) (>= tw fw) (opt-range-type-unsigned? from-ty))
        (opt-range-clamp-unsigned r fw)]
      [(and (< fw 64) (>= tw fw) (opt-range-type-signed? from-ty))
        (opt-range-clamp-signed r from-ty)]
      [(and (< tw 64) (opt-range-type-unsigned? to-ty))
        (opt-range-clamp-unsigned r tw)]
      [(and (< tw 64) (opt-range-type-signed? to-ty))
        (opt-range-clamp-signed r to-ty)]
      [else (opt-range-range-for-type to-ty)])))

(define (opt-range-eval-add [a : (& OptRangeVal)] [b : (& OptRangeVal)]) : OptRangeVal
  (if (or (= a.kind opt-range-kind-bottom) (= b.kind opt-range-kind-bottom))
    (opt-range-bottom)
    (let
      ;; Trailing zeros: if low k bits are known 0 in both, they remain 0 in sum.
      [low-z : u64
        (let
          [both-unk : u64 (bit-or (bit-not a.kz) (bit-not b.kz))]
          (if (= both-unk (cast 0 : u64))
            opt-range-u64-all-ones
            (- (bit-and both-unk (- (cast 0 : u64) both-unk)) (cast 1 : u64))))]
      (match (opt-range-safe-add a.lo b.lo)
        [(Some lo)
          (match (opt-range-safe-add a.hi b.hi)
            [(Some hi) (opt-range-tighten lo hi low-z (cast 0 : u64))]
            [(None) (opt-range-bits low-z (cast 0 : u64))])]
        [(None) (opt-range-bits low-z (cast 0 : u64))]))))

(define (opt-range-eval-sub [a : (& OptRangeVal)] [b : (& OptRangeVal)]) : OptRangeVal
  (if (or (= a.kind opt-range-kind-bottom) (= b.kind opt-range-kind-bottom))
    (opt-range-bottom)
    (match (opt-range-safe-sub a.lo b.hi)
      [(Some lo)
        (match (opt-range-safe-sub a.hi b.lo)
          [(Some hi) (opt-range-interval lo hi)]
          [(None) (opt-range-top)])]
      [(None) (opt-range-top)])))

(define (opt-range-eval-mul [a : (& OptRangeVal)] [b : (& OptRangeVal)]) : OptRangeVal
  (if (or (= a.kind opt-range-kind-bottom) (= b.kind opt-range-kind-bottom))
    (opt-range-bottom)
    (match (opt-range-safe-mul a.lo b.lo)
      [(None) (opt-range-top)]
      [(Some p1)
        (match (opt-range-safe-mul a.lo b.hi)
          [(None) (opt-range-top)]
          [(Some p2)
            (match (opt-range-safe-mul a.hi b.lo)
              [(None) (opt-range-top)]
              [(Some p3)
                (match (opt-range-safe-mul a.hi b.hi)
                  [(None) (opt-range-top)]
                  [(Some p4)
                    (let
                      [lo : i64
                        (opt-range-min-i64
                          (opt-range-min-i64 p1 p2)
                          (opt-range-min-i64 p3 p4))]
                      [hi : i64
                        (opt-range-max-i64
                          (opt-range-max-i64 p1 p2)
                          (opt-range-max-i64 p3 p4))]
                      (opt-range-interval lo hi))])])])])))

(define (opt-range-eval-div
  [a : (& OptRangeVal)]
  [b : (& OptRangeVal)]
  [ty : (& ast.AstType)]) : OptRangeVal
  (cond
    [(or (= a.kind opt-range-kind-bottom) (= b.kind opt-range-kind-bottom))
      (opt-range-bottom)]
    [(opt-range-type-signed? ty)
      (if (> b.lo 0)
        (let
          [lo : i64
            (if (>= a.lo 0)
              (/ a.lo b.hi)
              (/ a.lo b.lo))]
          [hi : i64
            (if (>= a.hi 0)
              (/ a.hi b.lo)
              (/ a.hi b.hi))]
          (opt-range-interval lo hi))
        (opt-range-top))]
    [(opt-range-type-is-u64? ty)
      (let
        [ua : OptRangeVal (opt-range-u64-bounds a)]
        [ub : OptRangeVal (opt-range-u64-bounds b)]
        [ublo : u64 ub.kz]
        [ubhi : u64 ub.ko]
        (if (>= ublo (cast 2 : u64))
          (opt-range-interval
            (cast (/ ua.kz ubhi) : i64)
            (cast (/ ua.ko ublo) : i64))
          (if (and (= ublo (cast 1 : u64)) (>= a.lo 0))
            (opt-range-interval (cast (/ ua.kz ubhi) : i64) a.hi)
            (opt-range-top))))]
    [else (opt-range-top)]))

(define (opt-range-eval-mod
  [a : (& OptRangeVal)]
  [b : (& OptRangeVal)]
  [ty : (& ast.AstType)]) : OptRangeVal
  (cond
    [(or (= a.kind opt-range-kind-bottom) (= b.kind opt-range-kind-bottom))
      (opt-range-bottom)]
    [(opt-range-type-signed? ty)
      (cond
        [(and (> b.lo 0) (opt-range-is-const? a) (opt-range-is-const? b))
          (opt-range-const (% a.lo b.lo))]
        [(and (> b.lo 0) (>= a.lo 0) (< a.hi b.lo)) (opt-range-val-copy a)]
        [(or (> b.lo 0) (and (< b.hi 0) (> b.lo opt-range-i64-min)))
          (let
            [max-r : i64
              (if (> b.lo 0)
                (- b.hi 1)
                (- (- 0 b.lo) 1))]
            [lo : i64
              (if (>= a.lo 0)
                0
                (opt-range-max-i64 a.lo (- 0 max-r)))]
            [hi : i64
              (if (<= a.hi 0)
                0
                (opt-range-min-i64 a.hi max-r))]
            (opt-range-interval lo hi))]
        [else (opt-range-top)])]
    [(opt-range-type-is-u64? ty)
      (if (> b.lo 0)
        (let
          [max-r : i64 (- b.hi 1)]
          [hi : i64
            (if (>= a.lo 0)
              (opt-range-min-i64 a.hi max-r)
              max-r)]
          (opt-range-interval 0 hi))
        (opt-range-top))]
    [else (opt-range-top)]))

(define (opt-range-eval-bitand [a : (& OptRangeVal)] [b : (& OptRangeVal)]) : OptRangeVal
  (if (or (= a.kind opt-range-kind-bottom) (= b.kind opt-range-kind-bottom))
    (opt-range-bottom)
    (let
      [kz : u64 (bit-or a.kz b.kz)]
      [ko : u64 (bit-and a.ko b.ko)]
      [lo : i64 opt-range-i64-min]
      [hi : i64 opt-range-i64-max]
      (when
        (or (>= a.lo 0) (>= b.lo 0))
        (set! lo 0)
        (when (>= a.lo 0) (set! hi (opt-range-min-i64 hi a.hi)))
        (when (>= b.lo 0) (set! hi (opt-range-min-i64 hi b.hi))))
      (opt-range-tighten lo hi kz ko))))

(define (opt-range-eval-bitor [a : (& OptRangeVal)] [b : (& OptRangeVal)]) : OptRangeVal
  (if (or (= a.kind opt-range-kind-bottom) (= b.kind opt-range-kind-bottom))
    (opt-range-bottom)
    (let
      [kz : u64 (bit-and a.kz b.kz)]
      [ko : u64 (bit-or a.ko b.ko)]
      [lo : i64
        (if (and (>= a.lo 0) (>= b.lo 0))
          (opt-range-max-i64 a.lo b.lo)
          opt-range-i64-min)]
      (opt-range-tighten lo opt-range-i64-max kz ko))))

(define (opt-range-eval-bitxor [a : (& OptRangeVal)] [b : (& OptRangeVal)]) : OptRangeVal
  (if (or (= a.kind opt-range-kind-bottom) (= b.kind opt-range-kind-bottom))
    (opt-range-bottom)
    (let
      [kz : u64 (bit-or (bit-and a.kz b.kz) (bit-and a.ko b.ko))]
      [ko : u64 (bit-or (bit-and a.kz b.ko) (bit-and a.ko b.kz))]
      (opt-range-bits kz ko))))

(define (opt-range-eval-shl
  [a : (& OptRangeVal)]
  [b : (& OptRangeVal)]
  [ty : (& ast.AstType)]) : OptRangeVal
  (let
    [w : i64 (opt-range-type-int-width ty)]
    (cond
      [(or (= a.kind opt-range-kind-bottom) (= b.kind opt-range-kind-bottom))
        (opt-range-bottom)]
      [(and (= w 64) (opt-range-is-const? b) (>= b.lo 0) (< b.lo 64))
        (let
          [s : i64 b.lo]
          [kz : u64 (bit-or (shl a.kz s) (opt-range-u64-low-mask s))]
          [ko : u64 (shl a.ko s)]
          (if (= s 0)
            (OptRangeVal a.lo a.hi a.kz a.ko a.kind)
            (if (and (>= a.lo 0) (<= a.hi (shr opt-range-i64-max s)))
              (opt-range-tighten (shl a.lo s) (shl a.hi s) kz ko)
              (opt-range-bits kz ko))))]
      [(and (= w 64) (= b.kind opt-range-kind-known) (>= b.lo 0) (< b.hi 64))
        (let
          [kz : u64 (opt-range-u64-low-mask b.lo)]
          (if (and (>= a.lo 0) (<= a.hi (shr opt-range-i64-max b.hi)))
            (opt-range-tighten
              (shl a.lo b.lo)
              (shl a.hi b.hi)
              kz
              (cast 0 : u64))
            (opt-range-bits kz (cast 0 : u64))))]
      [else (opt-range-range-for-type ty)])))

(define (opt-range-eval-shr
  [a : (& OptRangeVal)]
  [b : (& OptRangeVal)]
  [ty : (& ast.AstType)]) : OptRangeVal
  (let
    [w : i64 (opt-range-type-int-width ty)]
    (cond
      [(or (= a.kind opt-range-kind-bottom) (= b.kind opt-range-kind-bottom))
        (opt-range-bottom)]
      [(and (opt-range-is-const? b) (>= b.lo 0) (< b.lo w))
        (let
          [s : i64 b.lo]
          (if (opt-range-type-signed? ty)
            ;; Arithmetic right shift: never wraps on signed integers.
            (let
              [top-mask : u64
                (if (= s 0)
                  (cast 0 : u64)
                  (bit-not (opt-range-u64-low-mask (- 64 s))))]
              [kz : u64
                (bit-or
                  (shr a.kz s)
                  (if (not
                    (= (bit-and a.kz opt-range-u64-sign-bit) (cast 0 : u64)))
                    top-mask
                    (cast 0 : u64)))]
              [ko : u64
                (bit-or
                  (shr a.ko s)
                  (if (not
                    (= (bit-and a.ko opt-range-u64-sign-bit) (cast 0 : u64)))
                    top-mask
                    (cast 0 : u64)))]
              (opt-range-tighten (shr a.lo s) (shr a.hi s) kz ko))
            ;; Logical right shift on unsigned width w.
            (let
              [wmask : u64 (opt-range-u64-low-mask w)]
              [akz : u64 (bit-or a.kz (bit-not wmask))]
              [ako : u64 (bit-and a.ko wmask)]
              [top-mask : u64
                (if (= s 0)
                  (bit-not wmask)
                  (bit-not (opt-range-u64-low-mask (- 64 s))))]
              [kz : u64 (bit-or (shr akz s) top-mask)]
              [ko : u64 (shr ako s)]
              (if (and (= w 64) (>= a.lo 0))
                (opt-range-tighten (shr a.lo s) (shr a.hi s) kz ko)
                (opt-range-bits kz ko)))))]
      [else (opt-range-range-for-type ty)])))

;; --- Comparison evaluation (returns -1 unknown, 0 false, 1 true) -------------
(define (opt-range-rel-holds?
  [st : (& OptRangeState)]
  [want-strict? : bool]
  [lhs-v : i64]
  [rhs-v : i64]) : bool
  (let
    [cl : i64 (opt-range-resolve-copy st lhs-v)]
    [cr : i64 (opt-range-resolve-copy st rhs-v)]
    [i : i64 (- st.rel-len 1)]
    [found : bool false]
    (while (and (>= i 0) (not found))
      (let
        [rf : OptRangeRelFact (opt-range-rel-copy (& (array-ref st.rels i)))]
        (when
          (and (= rf.lhs cl) (= rf.rhs cr))
          (cond
            [(and (= rf.kind 0) (= rf.offset 0)) (set! found true)]
            [(and (= rf.kind 1) (= rf.offset 0) (not want-strict?))
              (set! found true)]
            [(and
                (= rf.kind 2)
                (>= rf.offset 0)
                (>= (array-ref st.vals cl).lo 0))
              (set! found true)]
            [else unit])))
      (-= i 1))
    found))

(define (opt-range-val-rel?
  [st : (& OptRangeState)]
  [strict? : bool]
  [lhs : (& ir.CompilerIrValue)]
  [rhs : (& ir.CompilerIrValue)]) : bool
  (match lhs
    [(Var lv)
      (match rhs
        [(Var rv) (opt-range-rel-holds? st strict? lv rv)]
        [_ false])]
    [_ false]))

(define (opt-range-eval-compare
  [st : (& OptRangeState)]
  [nonneg-globals : (& opt_i64_i64_map.Map)]
  [op : (& ir.CompilerIrBinOp)]
  [lhs : (& ir.CompilerIrValue)]
  [rhs : (& ir.CompilerIrValue)]
  [ty : (& ast.AstType)]) : i64
  (let
    [a : OptRangeVal (opt-range-value-get st nonneg-globals lhs)]
    [b : OptRangeVal (opt-range-value-get st nonneg-globals rhs)]
    [signed? : bool (opt-range-type-signed? ty)]
    [unsigned? : bool (opt-range-type-unsigned? ty)]
    (cond
      [(or (= a.kind opt-range-kind-bottom) (= b.kind opt-range-kind-bottom))
        -1]
      [(not (or signed? unsigned?)) -1]
      [else
        (match op
          [(Eq)
            (cond
              [(and (opt-range-is-const? (& a)) (opt-range-is-const? (& b)))
                (if (= a.lo b.lo)
                  1
                  0)]
              [(or
                  (< a.hi b.lo)
                  (< b.hi a.lo)
                  (not (= (bit-and a.ko b.kz) (cast 0 : u64)))
                  (not (= (bit-and a.kz b.ko) (cast 0 : u64))))
                0]
              [else -1])]
          [(Ne)
            (let
              [r : i64
                (opt-range-eval-compare st nonneg-globals (& (Eq)) lhs rhs ty)]
              (if (< r 0)
                -1
                (- 1 r)))]
          [(BitTestEq)
            (cond
              [(= (bit-and (bit-not a.kz) (bit-not b.kz)) (cast 0 : u64)) 1]
              [(not (= (bit-and a.ko b.ko) (cast 0 : u64))) 0]
              [else -1])]
          [(BitTestNe)
            (let
              [r : i64
                (opt-range-eval-compare
                  st
                  nonneg-globals
                  (& (BitTestEq))
                  lhs
                  rhs
                  ty)]
              (if (< r 0)
                -1
                (- 1 r)))]
          [(or (Lt) (Le))
            (let
              [strict? : bool
                (match op
                  [(Lt) true]
                  [_ false])]
              (if signed?
                (cond
                  [(if strict?
                      (< a.hi b.lo)
                      (<= a.hi b.lo))
                    1]
                  [(if strict?
                      (>= a.lo b.hi)
                      (> a.lo b.hi))
                    0]
                  [(opt-range-val-rel? st strict? lhs rhs) 1]
                  [(opt-range-val-rel? st (not strict?) rhs lhs) 0]
                  [else -1])
                (let
                  [ua : OptRangeVal (opt-range-u64-bounds (& a))]
                  [ub : OptRangeVal (opt-range-u64-bounds (& b))]
                  (cond
                    [(if strict?
                        (< ua.ko ub.kz)
                        (<= ua.ko ub.kz))
                      1]
                    [(if strict?
                        (>= ua.kz ub.ko)
                        (> ua.kz ub.ko))
                      0]
                    [else -1]))))]
          [(Gt) (opt-range-eval-compare st nonneg-globals (& (Lt)) rhs lhs ty)]
          [(Ge) (opt-range-eval-compare st nonneg-globals (& (Le)) rhs lhs ty)]
          [_ -1])])))

;; --- Mask simplification queries ---------------------------------------------
;; Returns 0 = no fold, 1 = fold to lhs, 2 = fold to rhs, 3 = fold to 0.
(define (opt-range-mask-fold-kind
  [op : (& ir.CompilerIrBinOp)]
  [a : (& OptRangeVal)]
  [b : (& OptRangeVal)]
  [ty : (& ast.AstType)]) : i64
  (let
    [w : i64 (opt-range-type-int-width ty)]
    (if (or
      (= w 0)
      (= a.kind opt-range-kind-bottom)
      (= b.kind opt-range-kind-bottom))
      0
      (let
        [wmask : u64 (opt-range-u64-low-mask w)]
        (match op
          [(BitAnd)
            (cond
              [(=
                  (bit-and wmask (bit-and (bit-not a.kz) (bit-not b.kz)))
                  (cast 0 : u64))
                3]
              [(=
                  (bit-and wmask (bit-and (bit-not b.ko) (bit-not a.kz)))
                  (cast 0 : u64))
                1]
              [(=
                  (bit-and wmask (bit-and (bit-not a.ko) (bit-not b.kz)))
                  (cast 0 : u64))
                2]
              [else 0])]
          [(BitOr)
            (cond
              [(=
                  (bit-and wmask (bit-and (bit-not b.kz) (bit-not a.ko)))
                  (cast 0 : u64))
                1]
              [(=
                  (bit-and wmask (bit-and (bit-not a.kz) (bit-not b.ko)))
                  (cast 0 : u64))
                2]
              [else 0])]
          [(BitXor)
            (cond
              [(= (bit-and wmask (bit-not b.kz)) (cast 0 : u64)) 1]
              [(= (bit-and wmask (bit-not a.kz)) (cast 0 : u64)) 2]
              [else 0])]
          [_ 0])))))

;; --- Instruction evaluation (pure read of state) -----------------------------
(define (opt-range-val-eq-var? [val : (& ir.CompilerIrValue)] [var : i64]) : bool
  (match val
    [(Var v) (= v var)]
    [_ false]))

(define (opt-range-val-same?
  [st : (& OptRangeState)]
  [a : (& ir.CompilerIrValue)]
  [b : (& ir.CompilerIrValue)]) : bool
  (match a
    [(Var av)
      (match b
        [(Var bv)
          (= (opt-range-resolve-copy st av) (opt-range-resolve-copy st bv))]
        [_ false])]
    [(I64 ac)
      (match b
        [(I64 bc) (= ac bc)]
        [_ false])]
    [_ false]))

(define (opt-range-eval-select
  [st : (& OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [nonneg-globals : (& opt_i64_i64_map.Map)]
  [mask : (& ir.CompilerIrValue)]
  [on-true : (& ir.CompilerIrValue)]
  [on-false : (& ir.CompilerIrValue)]) : OptRangeVal
  (let
    [mr : OptRangeVal (opt-range-value-get st nonneg-globals mask)]
    [tr : OptRangeVal (opt-range-value-get st nonneg-globals on-true)]
    [fr : OptRangeVal (opt-range-value-get st nonneg-globals on-false)]
    (cond
      [(and (opt-range-is-const? (& mr)) (!= mr.lo 0)) tr]
      [(and (opt-range-is-const? (& mr)) (= mr.lo 0)) fr]
      [else
        ;; Check scalar min/max select idiom: `select (lt/le x y) x y` -> min(x, y),
        ;; `select (gt/ge x y) x y` -> max(x, y).
        (let
          [special : OptRangeVal (opt-range-join (& tr) (& fr))]
          (match mask
            [(Var mv)
              (let
                [rmv : i64 (opt-range-resolve-copy st mv)]
                (if (and
                  (>= rmv 0)
                  (< rmv st.frame)
                  (= (array-ref st.def-kind rmv) 2))
                  (let
                    [db : i64 (array-ref st.def-block rmv)]
                    [dp : i64 (array-ref st.def-pos rmv)]
                    (match (& (array-ref block-dense db))
                      [(Block _ instrs)
                        (match (ir.compiler-ir-instr-seq-borrow instrs dp)
                          [(BinOp _ cop cl cr cty)
                            (if (and
                              (opt-range-type-signed? (& cty))
                              (!= tr.kind opt-range-kind-bottom)
                              (!= fr.kind opt-range-kind-bottom))
                              (let
                                [is-lt? : bool
                                  (match (& cop)
                                    [(or (Lt) (Le)) true]
                                    [_ false])]
                                [is-gt? : bool
                                  (match (& cop)
                                    [(or (Gt) (Ge)) true]
                                    [_ false])]
                                [same-dir? : bool
                                  (and
                                    (opt-range-val-same? st (& cl) on-true)
                                    (opt-range-val-same? st (& cr) on-false))]
                                [swap-dir? : bool
                                  (and
                                    (opt-range-val-same? st (& cl) on-false)
                                    (opt-range-val-same? st (& cr) on-true))]
                                (cond
                                  [(or
                                      (and is-lt? same-dir?)
                                      (and is-gt? swap-dir?))
                                    (opt-range-interval
                                      (opt-range-min-i64 tr.lo fr.lo)
                                      (opt-range-min-i64 tr.hi fr.hi))]
                                  [(or
                                      (and is-gt? same-dir?)
                                      (and is-lt? swap-dir?))
                                    (opt-range-interval
                                      (opt-range-max-i64 tr.lo fr.lo)
                                      (opt-range-max-i64 tr.hi fr.hi))]
                                  [else special]))
                              special)]
                          [_ special])]))
                  special))]
            [_ special]))])))

(define (opt-range-eval-instr
  [st : (& OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [nonneg-globals : (& opt_i64_i64_map.Map)]
  [instr : (& ir.CompilerIrInstr)]) : OptRangeVal
  (match instr
    [(Mov _ src ty)
      (let
        [r : OptRangeVal (opt-range-value-get st nonneg-globals (& src))]
        [tr : OptRangeVal (opt-range-range-for-type (& ty))]
        (opt-range-meet (& r) (& tr)))]
    [(Cast _ src from-ty to-ty)
      (let
        [r : OptRangeVal (opt-range-value-get st nonneg-globals (& src))]
        (opt-range-eval-cast (& r) (& from-ty) (& to-ty)))]
    [(Word _ src idx ty)
      (if (and
        (= idx 1)
        (opt-range-type-is-i64? (& ty))
        (match (& src)
          [(Var sv) (opt-range-flag? st (opt-range-resolve-copy st sv) 1)]
          [_ false]))
        (opt-range-interval 0 opt-range-i64-max)
        (opt-range-range-for-type (& ty)))]
    [(Load _ ptr ty)
      (if (and
        (opt-range-type-is-i64? (& ty))
        (match (& ptr)
          [(Var pv) (opt-range-flag? st (opt-range-resolve-copy st pv) 2)]
          [_ false]))
        (opt-range-interval 0 opt-range-i64-max)
        (opt-range-range-for-type (& ty)))]
    [(UnOp _ op src ty)
      (let
        [r : OptRangeVal (opt-range-value-get st nonneg-globals (& src))]
        (match (& op)
          [(Neg)
            (if (opt-range-type-is-i64? (& ty))
              (opt-range-eval-sub (& (opt-range-const 0)) (& r))
              (opt-range-range-for-type (& ty)))]
          [(Not)
            (if (and (= r.kind opt-range-kind-known) (>= r.lo 0) (<= r.hi 1))
              (opt-range-interval (- 1 r.hi) (- 1 r.lo))
              (opt-range-interval 0 1))]
          [(BitNot)
            (if (and
              (= (opt-range-type-int-width (& ty)) 64)
              (= r.kind opt-range-kind-known))
              (opt-range-tighten (- -1 r.hi) (- -1 r.lo) r.ko r.kz)
              (opt-range-range-for-type (& ty)))]
          [(BitLength) (opt-range-interval 0 64)]
          [_ (opt-range-range-for-type (& ty))]))]
    [(BinOp _ op lhs rhs ty)
      (if (ir.compiler-ir-binop-compare? (& op))
        (let
          [cmp : i64
            (opt-range-eval-compare
              st
              nonneg-globals
              (& op)
              (& lhs)
              (& rhs)
              (& ty))]
          (cond
            [(= cmp 1) (opt-range-const 1)]
            [(= cmp 0) (opt-range-const 0)]
            [else (opt-range-interval 0 1)]))
        (let
          [a : OptRangeVal (opt-range-value-get st nonneg-globals (& lhs))]
          [b : OptRangeVal (opt-range-value-get st nonneg-globals (& rhs))]
          [tr : OptRangeVal (opt-range-range-for-type (& ty))]
          (match (& op)
            [(or (Add) (Sub) (Mul))
              (if (opt-range-type-is-i64? (& ty))
                (match (& op)
                  [(Add) (opt-range-eval-add (& a) (& b))]
                  [(Sub) (opt-range-eval-sub (& a) (& b))]
                  [_ (opt-range-eval-mul (& a) (& b))])
                tr)]
            [(or (Div) (SafeDiv)) (opt-range-eval-div (& a) (& b) (& ty))]
            [(or (Mod) (SafeMod)) (opt-range-eval-mod (& a) (& b) (& ty))]
            [(or (BitAnd) (BitOr) (BitXor))
              (let
                [r : OptRangeVal
                  (match (& op)
                    [(BitAnd) (opt-range-eval-bitand (& a) (& b))]
                    [(BitOr) (opt-range-eval-bitor (& a) (& b))]
                    [_ (opt-range-eval-bitxor (& a) (& b))])]
                (opt-range-meet (& r) (& tr)))]
            [(Shl _) (opt-range-eval-shl (& a) (& b) (& ty))]
            [(Shr _) (opt-range-eval-shr (& a) (& b) (& ty))]
            [(or (And) (Or))
              (let
                [is-and? : bool
                  (match (& op)
                    [(And) true]
                    [_ false])]
                [ac : bool (opt-range-is-const? (& a))]
                [bc : bool (opt-range-is-const? (& b))]
                [a-abs : bool
                  (and
                    ac
                    (if is-and?
                      (= a.lo 0)
                      (!= a.lo 0)))]
                [b-abs : bool
                  (and
                    bc
                    (if is-and?
                      (= b.lo 0)
                      (!= b.lo 0)))]
                (cond
                  [(or a-abs b-abs)
                    (opt-range-const
                      (if is-and?
                        0
                        1))]
                  [(and ac bc)
                    (opt-range-const
                      (if is-and?
                        1
                        0))]
                  [else (opt-range-interval 0 1)]))]
            [_ tr])))]
    [(Select payload)
      (if (= payload.lanes 1)
        (opt-range-eval-select
          st
          block-dense
          nonneg-globals
          (& payload.mask)
          (& payload.on-true)
          (& payload.on-false))
        (opt-range-top))]
    [_ (opt-range-top)]))

;; --- Edge refinement (Branch, Switch, and backward def refinement) -----------
(define (opt-range-refine-var-both!
  [st : (&mut OptRangeState)]
  [var : i64]
  [bound : (& OptRangeVal)]) : unit
  (opt-range-var-refine! st var bound)
  (let
    [root : i64 (opt-range-resolve-copy st var)]
    (when (!= root var) (opt-range-var-refine! st root bound))))

;; Backward refinement through defining expressions when a variable is refined:
;;   - `u = cast x : i64 to u64` (or u64 to i64): 64-bit bit-identical reinterpret
;;     => refine `x` with `u`'s range (recovers `0 <= x < N` from `u <u N` range checks)
;;   - `q = div N, w` (N > 0, w >= 1) and `q >= c` (c >= 1) => `w <= N / c`
;;   - `d = sub x, k` (k > 0) and `d in [dlo, dhi]` with `d <= x` or `x >= 0`
;;     => `x in [dlo + k, dhi + k]` (when addition does not wrap)
(define (opt-range-back-refine!
  [st : (&mut OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [nonneg-globals : (& opt_i64_i64_map.Map)]
  [var : i64]) : unit
  (let
    [rvar : i64 (opt-range-resolve-copy st var)]
    (when
      (and (>= rvar 0) (< rvar st.frame))
      (let
        [dk : i64 (array-ref st.def-kind rvar)]
        [rv : OptRangeVal (opt-range-var-get st rvar)]
        (when
          (and (= rv.kind opt-range-kind-known) (or (= dk 4) (= dk 2)))
          (let
            [db : i64 (array-ref st.def-block rvar)]
            [dp : i64 (array-ref st.def-pos rvar)]
            (match (& (array-ref block-dense db))
              [(Block _ instrs)
                (match (ir.compiler-ir-instr-seq-borrow instrs dp)
                  [(Cast _ src from-ty to-ty)
                    (when
                      (and
                        (= (opt-range-type-int-width (& from-ty)) 64)
                        (= (opt-range-type-int-width (& to-ty)) 64))
                      (match (& src)
                        [(Var sv) (opt-range-refine-var-both! st sv (& rv))]
                        [_ unit]))]
                  [(BinOp _ op lhs rhs ty)
                    (when
                      (opt-range-type-is-i64? (& ty))
                      (match (& op)
                        [(or (Div) (SafeDiv))
                          (when
                            (>= rv.lo 1)
                            (match (& lhs)
                              [(I64 n)
                                (when
                                  (> n 0)
                                  (match (& rhs)
                                    [(Var wv)
                                      (let
                                        [wr : OptRangeVal
                                          (opt-range-value-get
                                            st
                                            nonneg-globals
                                            (& rhs))]
                                        (when
                                          (>= wr.lo 1)
                                          (opt-range-refine-var-both!
                                            st
                                            wv
                                            (&
                                              (opt-range-interval 1 (/ n rv.lo))))))]
                                    [_ unit]))]
                              [_ unit]))]
                        [(Sub)
                          (match (& lhs)
                            [(Var xv)
                              (match (& rhs)
                                [(I64 k)
                                  (when
                                    (> k 0)
                                    (let
                                      [xr : OptRangeVal
                                        (opt-range-value-get
                                          st
                                          nonneg-globals
                                          (& lhs))]
                                      (when
                                        (or
                                          (>= xr.lo 0)
                                          (opt-range-rel-holds?
                                            st
                                            false
                                            rvar
                                            xv))
                                        (match (opt-range-safe-add rv.lo k)
                                          [(Some xlo)
                                            (match (opt-range-safe-add rv.hi k)
                                              [(Some xhi)
                                                (opt-range-refine-var-both!
                                                  st
                                                  xv
                                                  (&
                                                    (opt-range-interval xlo xhi)))]
                                              [(None) unit])]
                                          [(None) unit]))))]
                                [_ unit])]
                            [_ unit])]
                        [_ unit]))]
                  [_ unit])])))))))

(define (opt-range-refine-ne-var!
  [st : (&mut OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [nonneg-globals : (& opt_i64_i64_map.Map)]
  [val : (& ir.CompilerIrValue)]
  [r : (& OptRangeVal)]
  [c : (& OptRangeVal)]) : unit
  (when
    (opt-range-is-const? c)
    (match val
      [(Var v)
        (when
          (and (= r.lo c.lo) (< r.lo opt-range-i64-max))
          (opt-range-refine-var-both!
            st
            v
            (& (opt-range-interval (+ r.lo 1) r.hi)))
          (opt-range-back-refine! st block-dense nonneg-globals v))
        (when
          (and (= r.hi c.lo) (> r.hi opt-range-i64-min))
          (opt-range-refine-var-both!
            st
            v
            (& (opt-range-interval r.lo (- r.hi 1))))
          (opt-range-back-refine! st block-dense nonneg-globals v))]
      [_ unit])))

(define (opt-range-refine-cmp-signed!
  [st : (&mut OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [nonneg-globals : (& opt_i64_i64_map.Map)]
  [op : (& ir.CompilerIrBinOp)]
  [lhs : (& ir.CompilerIrValue)]
  [rhs : (& ir.CompilerIrValue)]) : unit
  (let
    [a : OptRangeVal (opt-range-value-get st nonneg-globals lhs)]
    [b : OptRangeVal (opt-range-value-get st nonneg-globals rhs)]
    (match op
      [(or (Lt) (Le))
        (let
          [strict? : bool
            (match op
              [(Lt) true]
              [_ false])]
          [delta : i64
            (if strict?
              1
              0)]
          (match lhs
            [(Var lv)
              (when
                (or (not strict?) (> b.hi opt-range-i64-min))
                (opt-range-refine-var-both!
                  st
                  lv
                  (& (opt-range-interval opt-range-i64-min (- b.hi delta))))
                (opt-range-back-refine! st block-dense nonneg-globals lv))
              (match rhs
                [(Var rv)
                  (opt-range-rel-push!
                    st
                    (if strict?
                      0
                      1)
                    (opt-range-resolve-copy st lv)
                    (opt-range-resolve-copy st rv)
                    0)]
                [_ unit])]
            [_ unit])
          (match rhs
            [(Var rv)
              (when
                (or (not strict?) (< a.lo opt-range-i64-max))
                (opt-range-refine-var-both!
                  st
                  rv
                  (& (opt-range-interval (+ a.lo delta) opt-range-i64-max)))
                (opt-range-back-refine! st block-dense nonneg-globals rv))]
            [_ unit]))]
      [(Gt)
        (opt-range-refine-cmp-signed!
          st
          block-dense
          nonneg-globals
          (& (Lt))
          rhs
          lhs)]
      [(Ge)
        (opt-range-refine-cmp-signed!
          st
          block-dense
          nonneg-globals
          (& (Le))
          rhs
          lhs)]
      [(Eq)
        (let
          [m : OptRangeVal (opt-range-meet (& a) (& b))]
          (match lhs
            [(Var lv)
              (opt-range-refine-var-both! st lv (& m))
              (opt-range-back-refine! st block-dense nonneg-globals lv)]
            [_ unit])
          (match rhs
            [(Var rv)
              (opt-range-refine-var-both! st rv (& m))
              (opt-range-back-refine! st block-dense nonneg-globals rv)]
            [_ unit]))]
      [(Ne)
        (opt-range-refine-ne-var! st block-dense nonneg-globals lhs (& a) (& b))
        (opt-range-refine-ne-var! st block-dense nonneg-globals rhs (& b) (& a))]
      [_ unit])))

(define (opt-range-refine-cmp-unsigned!
  [st : (&mut OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [nonneg-globals : (& opt_i64_i64_map.Map)]
  [op : (& ir.CompilerIrBinOp)]
  [lhs : (& ir.CompilerIrValue)]
  [rhs : (& ir.CompilerIrValue)]) : unit
  (let
    [b : OptRangeVal (opt-range-value-get st nonneg-globals rhs)]
    (match op
      [(or (Lt) (Le))
        (let
          [strict? : bool
            (match op
              [(Lt) true]
              [_ false])]
          (when
            (and (>= b.lo 0) (or (not strict?) (> b.hi 0)))
            (match lhs
              [(Var lv)
                (opt-range-refine-var-both!
                  st
                  lv
                  (&
                    (opt-range-interval
                      0
                      (if strict?
                        (- b.hi 1)
                        b.hi))))
                (opt-range-back-refine! st block-dense nonneg-globals lv)
                (match rhs
                  [(Var rv)
                    (opt-range-rel-push!
                      st
                      (if strict?
                        0
                        1)
                      (opt-range-resolve-copy st lv)
                      (opt-range-resolve-copy st rv)
                      0)]
                  [_ unit])]
              [_ unit])
            (when
              strict?
              (match rhs
                [(Var rv)
                  (opt-range-refine-var-both!
                    st
                    rv
                    (& (opt-range-interval 1 b.hi)))]
                [_ unit]))))]
      [(Gt)
        (opt-range-refine-cmp-unsigned!
          st
          block-dense
          nonneg-globals
          (& (Lt))
          rhs
          lhs)]
      [(Ge)
        (opt-range-refine-cmp-unsigned!
          st
          block-dense
          nonneg-globals
          (& (Le))
          rhs
          lhs)]
      [(or (Eq) (Ne))
        (opt-range-refine-cmp-signed! st block-dense nonneg-globals op lhs rhs)]
      [_ unit])))

(define (opt-range-flip-cmp [op : (& ir.CompilerIrBinOp)]) : ir.CompilerIrBinOp
  (match op
    [(Lt) (Ge)]
    [(Le) (Gt)]
    [(Gt) (Le)]
    [(Ge) (Lt)]
    [(Eq) (Ne)]
    [(Ne) (Eq)]
    [(BitTestEq) (BitTestNe)]
    [(BitTestNe) (BitTestEq)]
    [_ (Eq)]))

(define (opt-range-refine-cond!
  [st : (&mut OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [nonneg-globals : (& opt_i64_i64_map.Map)]
  [cond-val : (& ir.CompilerIrValue)]
  [taken : bool]
  [depth : i64]) : unit
  (when
    (> depth 0)
    (match cond-val
      [(Var cv)
        (opt-range-refine-var-both!
          st
          cv
          (&
            (opt-range-const
              (if taken
                1
                0))))
        (let
          [rv : i64 (opt-range-resolve-copy st cv)]
          (when
            (and (>= rv 0) (< rv st.frame))
            (let
              [dk : i64 (array-ref st.def-kind rv)]
              (when
                (or (= dk 2) (= dk 3))
                (let
                  [db : i64 (array-ref st.def-block rv)]
                  [dp : i64 (array-ref st.def-pos rv)]
                  (match (& (array-ref block-dense db))
                    [(Block _ instrs)
                      (match (ir.compiler-ir-instr-seq-borrow instrs dp)
                        [(UnOp _ (Not) inner _)
                          (opt-range-refine-cond!
                            st
                            block-dense
                            nonneg-globals
                            (& inner)
                            (not taken)
                            (- depth 1))]
                        [(BinOp _ op lhs rhs ty)
                          (match (& op)
                            [(or (And) (Or))
                              (let
                                [is-and? : bool
                                  (match (& op)
                                    [(And) true]
                                    [_ false])]
                                (when
                                  (= is-and? taken)
                                  (opt-range-refine-cond!
                                    st
                                    block-dense
                                    nonneg-globals
                                    (& lhs)
                                    taken
                                    (- depth 1))
                                  (opt-range-refine-cond!
                                    st
                                    block-dense
                                    nonneg-globals
                                    (& rhs)
                                    taken
                                    (- depth 1))))]
                            [(or (Lt) (Le) (Gt) (Ge) (Eq) (Ne))
                              (let
                                [fop : ir.CompilerIrBinOp
                                  (opt-range-flip-cmp (& op))]
                                [eff : ir.CompilerIrBinOp
                                  (if taken
                                    (opt-range-flip-cmp (& fop))
                                    fop)]
                                (cond
                                  [(opt-range-type-signed? (& ty))
                                    (opt-range-refine-cmp-signed!
                                      st
                                      block-dense
                                      nonneg-globals
                                      (& eff)
                                      (& lhs)
                                      (& rhs))]
                                  [(opt-range-type-unsigned? (& ty))
                                    (opt-range-refine-cmp-unsigned!
                                      st
                                      block-dense
                                      nonneg-globals
                                      (& eff)
                                      (& lhs)
                                      (& rhs))]
                                  [else unit]))]
                            [(or (BitTestEq) (BitTestNe))
                              (let
                                [want-zero? : bool
                                  (match (& op)
                                    [(BitTestEq) taken]
                                    [_ (not taken)])]
                                (match (& lhs)
                                  [(Var lv)
                                    (match (& rhs)
                                      [(I64 m)
                                        (let
                                          [mu : u64 (cast m : u64)]
                                          (if want-zero?
                                            (opt-range-refine-var-both!
                                              st
                                              lv
                                              (&
                                                (opt-range-bits
                                                  mu
                                                  (cast 0 : u64))))
                                            (when
                                              (and
                                                (!= mu (cast 0 : u64))
                                                (=
                                                  (bit-and
                                                    mu
                                                    (- mu (cast 1 : u64)))
                                                  (cast 0 : u64)))
                                              (opt-range-refine-var-both!
                                                st
                                                lv
                                                (&
                                                  (opt-range-bits
                                                    (cast 0 : u64)
                                                    mu))))))]
                                      [_ unit])]
                                  [_ unit]))]
                            [_ unit])]
                        [_ unit])]))))))]
      [_ unit])))

(define (opt-range-refine-edge!
  [st : (&mut OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [block-labels : (& (__tl_dyn-array i64))]
  [nonneg-globals : (& opt_i64_i64_map.Map)]
  [pred-id : i64]
  [succ-id : i64]) : unit
  (let
    [succ-label : i64 (array-ref block-labels succ-id)]
    (match (& (array-ref block-dense pred-id))
      [(Block _ instrs)
        (let
          [n : i64 (ir.compiler-ir-instr-seq-count (& instrs))]
          (when
            (> n 0)
            (match (ir.compiler-ir-instr-seq-borrow instrs (- n 1))
              [(or (Branch cond-v t-lbl f-lbl)
                   (TotalEnumBranch cond-v t-lbl f-lbl))
                (when
                  (!= t-lbl f-lbl)
                  (cond
                    [(= succ-label t-lbl)
                      (opt-range-refine-cond!
                        st
                        block-dense
                        nonneg-globals
                        (& cond-v)
                        true
                        4)]
                    [(= succ-label f-lbl)
                      (opt-range-refine-cond!
                        st
                        block-dense
                        nonneg-globals
                        (& cond-v)
                        false
                        4)]
                    [else unit]))]
              [(or (Switch discr _ cases def-lbl)
                   (TotalEnumSwitch discr _ cases def-lbl _))
                (match (& discr)
                  [(Var dv)
                    (let
                      [ncases : i64
                        (ir.compiler-ir-switch-case-seq-count (& cases))]
                      [hits : i64 0]
                      [hit-val : i64 0]
                      [is-def? : bool (= succ-label def-lbl)]
                      (for [ci (iterator.range 0 ncases)]
                        (match (ir.compiler-ir-switch-case-seq-borrow
                          (& cases)
                          ci)
                          [(Case cval clbl)
                            (when
                              (= clbl succ-label)
                              (+= hits 1)
                              (set! hit-val cval))]))
                      (cond
                        [(and (= hits 1) (not is-def?))
                          (opt-range-refine-var-both!
                            st
                            dv
                            (& (opt-range-const hit-val)))]
                        [(and (= hits 0) is-def?)
                          ;; Default arm: trim endpoints that match excluded cases.
                          (for [ci (iterator.range 0 ncases)]
                            (match (ir.compiler-ir-switch-case-seq-borrow
                              (& cases)
                              ci)
                              [(Case cval _)
                                (opt-range-refine-cmp-signed!
                                  st
                                  block-dense
                                  nonneg-globals
                                  (& (Ne))
                                  (& discr)
                                  (& (I64 cval)))]))]
                        [else unit]))]
                  [_ unit])]
              [_ unit])))])))

;; --- Dominance & predecessor helpers -----------------------------------------
(define (opt-range-dominates?
  [tin : (& (__tl_dyn-array i64))]
  [tout : (& (__tl_dyn-array i64))]
  [a : i64]
  [b : i64]) : bool
  (and
    (>= a 0)
    (>= b 0)
    (<= (array-ref tin a) (array-ref tin b))
    (<= (array-ref tout b) (array-ref tout a))))

;; Find the unique non-dead, non-backedge predecessor of `bid` if one exists,
;; else -1.
(define (opt-range-unique-live-entry-pred
  [st : (& OptRangeState)]
  [reachable : (& (__tl_dyn-array bool))]
  [tin : (& (__tl_dyn-array i64))]
  [tout : (& (__tl_dyn-array i64))]
  [pred-off : (& (__tl_dyn-array i64))]
  [pred-edges : (& (__tl_dyn-array i64))]
  [bid : i64]) : i64
  (let
    [start : i64 (array-ref pred-off bid)]
    [end : i64 (array-ref pred-off (+ bid 1))]
    [found : i64 -1]
    [count : i64 0]
    (for [e (iterator.range start end)]
      (let
        [pid : i64 (array-ref pred-edges e)]
        (when
          (and
            (array-ref reachable pid)
            (not (array-ref st.block-dead pid))
            (not (opt-range-dominates? tin tout bid pid)))
          (set! found pid)
          (+= count 1))))
    (if (= count 1)
      found
      -1)))

;; Walk up unique live entry edges from `bid` to `stop-id` (idom(bid)),
;; collecting the chain so we can apply edge refinements top-down.
(define (opt-range-apply-entry-chain!
  [st : (&mut OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [block-labels : (& (__tl_dyn-array i64))]
  [reachable : (& (__tl_dyn-array bool))]
  [tin : (& (__tl_dyn-array i64))]
  [tout : (& (__tl_dyn-array i64))]
  [pred-off : (& (__tl_dyn-array i64))]
  [pred-edges : (& (__tl_dyn-array i64))]
  [nonneg-globals : (& opt_i64_i64_map.Map)]
  [stop-id : i64]
  [bid : i64]
  [fuel : i64]) : unit
  (when
    (and (> fuel 0) (!= bid stop-id))
    (let
      [pid : i64
        (opt-range-unique-live-entry-pred
          st
          reachable
          tin
          tout
          pred-off
          pred-edges
          bid)]
      (when
        (>= pid 0)
        (when
          (!= pid stop-id)
          (opt-range-apply-entry-chain!
            st
            block-dense
            block-labels
            reachable
            tin
            tout
            pred-off
            pred-edges
            nonneg-globals
            stop-id
            pid
            (- fuel 1)))
        (opt-range-refine-edge!
          st
          block-dense
          block-labels
          nonneg-globals
          pid
          bid)))))

;; --- BoundsCheck discharge & recording ---------------------------------------
;; Decompose `v` as `(base-var, +k)` with `k >= 0` when `v = add base, k`
;; (or `v = base + 0`). Returns base-var in `out-base[0]`, offset in `out-off[0]`.
(define (opt-range-decompose-add-const
  [st : (& OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [val : (& ir.CompilerIrValue)]
  [out-base : (&mut (__tl_dyn-array i64))]
  [out-off : (&mut (__tl_dyn-array i64))]) : bool
  (match val
    [(Var raw-v)
      (let
        [v : i64 (opt-range-resolve-copy st raw-v)]
        (set! (array-ref out-base 0) v)
        (set! (array-ref out-off 0) 0)
        (when
          (and (>= v 0) (< v st.frame) (= (array-ref st.def-kind v) 2))
          (let
            [db : i64 (array-ref st.def-block v)]
            [dp : i64 (array-ref st.def-pos v)]
            (match (& (array-ref block-dense db))
              [(Block _ instrs)
                (match (ir.compiler-ir-instr-seq-borrow instrs dp)
                  [(BinOp _ (Add) lhs rhs ty)
                    (when
                      (opt-range-type-is-i64? (& ty))
                      (match (& lhs)
                        [(Var bv)
                          (match (& rhs)
                            [(I64 k)
                              (when
                                (> k 0)
                                (set!
                                  (array-ref out-base 0)
                                  (opt-range-resolve-copy st bv))
                                (set! (array-ref out-off 0) k))]
                            [_ unit])]
                        [(I64 k)
                          (match (& rhs)
                            [(Var bv)
                              (when
                                (> k 0)
                                (set!
                                  (array-ref out-base 0)
                                  (opt-range-resolve-copy st bv))
                                (set! (array-ref out-off 0) k))]
                            [_ unit])]
                        [_ unit]))]
                  [_ unit])])))
        true)]
    [_ false]))

;; Check `idx = x & (len - 1)` when `len >= 1`.
(define (opt-range-mask-len-minus-one?
  [st : (& OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [idx : (& ir.CompilerIrValue)]
  [len : (& ir.CompilerIrValue)]
  [len-r : (& OptRangeVal)]) : bool
  (if (< len-r.lo 1)
    false
    (match idx
      [(Var raw-iv)
        (let
          [iv : i64 (opt-range-resolve-copy st raw-iv)]
          (if (and (>= iv 0) (< iv st.frame) (= (array-ref st.def-kind iv) 2))
            (let
              [db : i64 (array-ref st.def-block iv)]
              [dp : i64 (array-ref st.def-pos iv)]
              (match (& (array-ref block-dense db))
                [(Block _ instrs)
                  (match (ir.compiler-ir-instr-seq-borrow instrs dp)
                    [(BinOp _ (BitAnd) lhs rhs _)
                      (or
                        (opt-range-is-len-minus-one? st block-dense (& lhs) len)
                        (opt-range-is-len-minus-one? st block-dense (& rhs) len))]
                    [_ false])]))
            false))]
      [_ false])))

(define (opt-range-is-len-minus-one?
  [st : (& OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [mask : (& ir.CompilerIrValue)]
  [len : (& ir.CompilerIrValue)]) : bool
  (match mask
    [(Var raw-mv)
      (let
        [mv : i64 (opt-range-resolve-copy st raw-mv)]
        (if (and (>= mv 0) (< mv st.frame) (= (array-ref st.def-kind mv) 2))
          (let
            [db : i64 (array-ref st.def-block mv)]
            [dp : i64 (array-ref st.def-pos mv)]
            (match (& (array-ref block-dense db))
              [(Block _ instrs)
                (match (ir.compiler-ir-instr-seq-borrow instrs dp)
                  [(BinOp _ (Sub) a (I64 1) _)
                    (opt-range-val-same? st (& a) len)]
                  [(BinOp _ (Add) a (I64 -1) _)
                    (opt-range-val-same? st (& a) len)]
                  [(BinOp _ (Add) (I64 -1) a _)
                    (opt-range-val-same? st (& a) len)]
                  [_ false])]))
          false))]
    [_ false]))

;; Check if a dominating passed BoundsCheck (base + k2, len) covers (base + k1, len)
;; where 0 <= k1 <= k2 and base >= 0 (so base + k2 cannot wrap into [0, len)
;; because len <= I64_MAX and k2 < 2^63).
(define (opt-range-check-coalesced?
  [st : (& OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [idx : (& ir.CompilerIrValue)]
  [len-v : i64]
  [len-r : (& OptRangeVal)]) : bool
  (if (< len-r.lo 0)
    false
    (let
      [base-box : (__tl_dyn-array i64) (opt-range-i64-arr 1)]
      [off-box : (__tl_dyn-array i64) (opt-range-i64-arr 1)]
      (if (not
        (opt-range-decompose-add-const
          st
          block-dense
          idx
          (&mut base-box)
          (&mut off-box)))
        false
        (let
          [base : i64 (array-ref base-box 0)]
          [off : i64 (array-ref off-box 0)]
          [base-r : OptRangeVal (opt-range-var-get st base)]
          [clen : i64 (opt-range-resolve-copy st len-v)]
          (if (< base-r.lo 0)
            false
            (let
              [i : i64 (- st.rel-len 1)]
              [found : bool false]
              (while (and (>= i 0) (not found))
                (let
                  [rf : OptRangeRelFact
                    (opt-range-rel-copy (& (array-ref st.rels i)))]
                  (when
                    (and
                      (= rf.kind 2)
                      (= rf.lhs base)
                      (= rf.rhs clen)
                      (>= rf.offset off))
                    (set! found true)))
                (-= i 1))
              found)))))))

(define (opt-range-bounds-check-always-traps?
  [idx-r : (& OptRangeVal)]
  [len-r : (& OptRangeVal)]) : bool
  (cond
    [(and (= len-r.kind opt-range-kind-known) (<= len-r.hi 0) (>= len-r.lo 0))
      ;; len == 0: unsigned idx <u 0 is impossible.
      true]
    [(and
        (= idx-r.kind opt-range-kind-known)
        (= len-r.kind opt-range-kind-known)
        (>= len-r.lo 0)
        (or (< idx-r.hi 0) (>= idx-r.lo len-r.hi)))
      true]
    [else false]))

(define (opt-range-is-loop-header-phi?
  [st : (& OptRangeState)]
  [val : (& ir.CompilerIrValue)]) : bool
  (match val
    [(Var iv) (opt-range-flag? st (opt-range-resolve-copy st iv) 8)]
    [_ false]))

(define (opt-range-bounds-check-provable?
  [st : (& OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [idx : (& ir.CompilerIrValue)]
  [len : (& ir.CompilerIrValue)]
  [idx-r : (& OptRangeVal)]
  [len-r : (& OptRangeVal)]) : bool
  (cond
    ;; 1. Interval proof: 0 <= idx.lo <= idx.hi < len.lo (covers (x&0xFFFFFFFF)>>27 < 32).
    ;;    Defer counted-loop header Phi indices so bce_version/fill_call/copy_call
    ;;    keep seeing their guarded loop check.
    [(and
        (= idx-r.kind opt-range-kind-known)
        (= len-r.kind opt-range-kind-known)
        (>= idx-r.lo 0)
        (< idx-r.hi len-r.lo)
        (not (opt-range-is-loop-header-phi? st idx)))
      true]
    ;; 2. Mask by (len - 1) when len >= 1.
    [(opt-range-mask-len-minus-one? st block-dense idx len len-r) true]
    ;; 3. Dominating relational `idx < len` with `idx >= 0` (defer counted-loop
    ;;    header Phi indices so bce_version/fill_call/copy_call see the check first).
    [(and
        (>= idx-r.lo 0)
        (not (opt-range-is-loop-header-phi? st idx))
        (match idx
          [(Var iv)
            (match len
              [(Var lv) (opt-range-rel-holds? st true iv lv)]
              [_ false])]
          [_ false]))
      true]
    ;; 4. Coalesced dominating check `bounds_check (b + k), len` covering `b`.
    [(match len
        [(Var lv) (opt-range-check-coalesced? st block-dense idx lv len-r)]
        [_ false])
      true]
    [else false]))

(define (opt-range-record-passed-check!
  [st : (&mut OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [idx : (& ir.CompilerIrValue)]
  [len : (& ir.CompilerIrValue)]
  [len-r : (& OptRangeVal)]) : unit
  ;; Runtime container lengths satisfy len <= INT64_MAX; after BoundsCheck passes,
  ;; if len >= 0 then 0 <= idx < len and len >= 1.
  (when
    (>= len-r.lo 0)
    (match len
      [(Var lv)
        (opt-range-refine-var-both!
          st
          lv
          (& (opt-range-interval 1 opt-range-i64-max)))
        (let
          [base-box : (__tl_dyn-array i64) (opt-range-i64-arr 1)]
          [off-box : (__tl_dyn-array i64) (opt-range-i64-arr 1)]
          (when
            (opt-range-decompose-add-const
              st
              block-dense
              idx
              (&mut base-box)
              (&mut off-box))
            (opt-range-rel-push!
              st
              2
              (array-ref base-box 0)
              (opt-range-resolve-copy st lv)
              (array-ref off-box 0))))]
      [_ unit])
    (match idx
      [(Var iv)
        (when
          (> len-r.hi 0)
          (opt-range-refine-var-both!
            st
            iv
            (& (opt-range-interval 0 (- len-r.hi 1)))))
        (match len
          [(Var lv)
            (opt-range-rel-push!
              st
              0
              (opt-range-resolve-copy st iv)
              (opt-range-resolve-copy st lv)
              0)]
          [_ unit])]
      [_ unit])))

;; --- Loop-header Phi fixpoint (1-step widening + coupled-IV + verify) --------
(define (opt-range-block-is-loop-header?
  [reachable : (& (__tl_dyn-array bool))]
  [tin : (& (__tl_dyn-array i64))]
  [tout : (& (__tl_dyn-array i64))]
  [pred-off : (& (__tl_dyn-array i64))]
  [pred-edges : (& (__tl_dyn-array i64))]
  [bid : i64]) : bool
  (let
    [start : i64 (array-ref pred-off bid)]
    [end : i64 (array-ref pred-off (+ bid 1))]
    [found : bool false]
    (for [e (iterator.range start end)]
      (let
        [pid : i64 (array-ref pred-edges e)]
        (when
          (and
            (array-ref reachable pid)
            (opt-range-dominates? tin tout bid pid))
          (set! found true))))
    found))

(define (opt-range-label-to-id
  [block-labels : (& (__tl_dyn-array i64))]
  [block-count : i64]
  [label : i64]) : i64
  (let
    [found : i64 -1]
    [i : i64 0]
    (while (and (< i block-count) (< found 0))
      (when (= (array-ref block-labels i) label) (set! found i))
      (+= i 1))
    found))

;; Evaluate a single Phi's joined value over selected predecessors
;; (`only-entry?` = true skips backedges; `only-back?` = true takes ONLY backedges).
(define (opt-range-eval-phi-inputs
  [st : (&mut OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [block-labels : (& (__tl_dyn-array i64))]
  [reachable : (& (__tl_dyn-array bool))]
  [tin : (& (__tl_dyn-array i64))]
  [tout : (& (__tl_dyn-array i64))]
  [nonneg-globals : (& opt_i64_i64_map.Map)]
  [header-id : i64]
  [inputs : (& inputs ir.CompilerIrPhiInputSeq)]
  [ty : (& ast.AstType)]
  [only-entry? : bool]
  [only-back? : bool]) : OptRangeVal
  (let
    [n : i64 (ir.compiler-ir-phi-input-seq-count inputs)]
    [acc : OptRangeVal (opt-range-bottom)]
    [type-r : OptRangeVal (opt-range-range-for-type ty)]
    (for [i (iterator.range 0 n)]
      (let
        [inp (ir.compiler-ir-phi-input-seq-borrow inputs i)]
        [pid : i64
          (opt-range-label-to-id block-labels st.block-count inp.label)]
        (when
          (and
            (>= pid 0)
            (array-ref reachable pid)
            (not (array-ref st.block-dead pid)))
          (let
            [is-back? : bool (opt-range-dominates? tin tout header-id pid)]
            (when
              (and
                (or (not only-entry?) (not is-back?))
                (or (not only-back?) is-back?))
              (let
                [tmark : i64 st.trail-len]
                [rmark : i64 st.rel-len]
                [_ref : unit
                  (opt-range-refine-edge!
                    st
                    block-dense
                    block-labels
                    nonneg-globals
                    pid
                    header-id)]
                [v : OptRangeVal
                  (opt-range-value-get st nonneg-globals (& inp.value))]
                (opt-range-trail-rollback! st tmark)
                (set! st.rel-len rmark)
                (set! acc (opt-range-join (& acc) (& v)))))))))
    (if (= acc.kind opt-range-kind-bottom)
      (opt-range-top)
      (opt-range-meet (& acc) (& type-r)))))

;; Collect natural loop blocks for header `hid` (bounded at 64 blocks) in RPO order.
(define (opt-range-collect-loop-blocks
  [block-count : i64]
  [reachable : (& (__tl_dyn-array bool))]
  [rpo-num : (& (__tl_dyn-array i64))]
  [tin : (& (__tl_dyn-array i64))]
  [tout : (& (__tl_dyn-array i64))]
  [pred-off : (& (__tl_dyn-array i64))]
  [pred-edges : (& (__tl_dyn-array i64))]
  [hid : i64]
  [out-ids : (&mut (__tl_dyn-array i64))]) : i64
  (let
    [in-loop : (__tl_dyn-array bool) (opt-range-bool-arr block-count)]
    [work : (__tl_dyn-array i64) (opt-range-i64-arr 65)]
    [wlen : i64 0]
    [overflow? : bool false]
    (set! (array-ref in-loop hid) true)
    (let
      [ps : i64 (array-ref pred-off hid)]
      [pe : i64 (array-ref pred-off (+ hid 1))]
      (for [e (iterator.range ps pe)]
        (let
          [pid : i64 (array-ref pred-edges e)]
          (when
            (and
              (array-ref reachable pid)
              (opt-range-dominates? tin tout hid pid)
              (not (array-ref in-loop pid)))
            (set! (array-ref in-loop pid) true)
            (if (< wlen 64)
              (begin
                (set! (array-ref work wlen) pid)
                (+= wlen 1))
              (set! overflow? true))))))
    (let
      [wi : i64 0]
      (while (and (< wi wlen) (not overflow?))
        (let
          [cur : i64 (array-ref work wi)]
          [ps : i64 (array-ref pred-off cur)]
          [pe : i64 (array-ref pred-off (+ cur 1))]
          (for [e (iterator.range ps pe)]
            (let
              [pid : i64 (array-ref pred-edges e)]
              (when
                (and
                  (array-ref reachable pid)
                  (opt-range-dominates? tin tout hid pid)
                  (not (array-ref in-loop pid)))
                (set! (array-ref in-loop pid) true)
                (if (< wlen 64)
                  (begin
                    (set! (array-ref work wlen) pid)
                    (+= wlen 1))
                  (set! overflow? true))))))
        (+= wi 1)))
    (if overflow?
      0
      (let
        [cnt : i64 0]
        (set! (array-ref out-ids 0) hid)
        (set! cnt 1)
        (for [i (iterator.range 0 wlen)]
          (set! (array-ref out-ids cnt) (array-ref work i))
          (+= cnt 1))
        ;; Insertion sort by rpo-num so body blocks are simulated in RPO order.
        (for [i (iterator.range 1 cnt)]
          (let
            [key : i64 (array-ref out-ids i)]
            [kr : i64 (array-ref rpo-num key)]
            [j : i64 (- i 1)]
            (while (and
              (>= j 0)
              (> (array-ref rpo-num (array-ref out-ids j)) kr))
              (set! (array-ref out-ids (+ j 1)) (array-ref out-ids j))
              (-= j 1))
            (set! (array-ref out-ids (+ j 1)) key)))
        cnt))))

;; Simulate instructions of loop blocks in RPO order (read-only: no IR rewrites).
;; Edge refinements applied upon entering a body block `bid != hid` are rolled
;; back immediately after simulating `bid`, while SSA definitions produced by
;; `bid` stay live for downstream blocks until the caller rolls back the phase.
(define (opt-range-sim-loop-blocks!
  [st : (&mut OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [block-labels : (& (__tl_dyn-array i64))]
  [reachable : (& (__tl_dyn-array bool))]
  [tin : (& (__tl_dyn-array i64))]
  [tout : (& (__tl_dyn-array i64))]
  [pred-off : (& (__tl_dyn-array i64))]
  [pred-edges : (& (__tl_dyn-array i64))]
  [nonneg-globals : (& opt_i64_i64_map.Map)]
  [hid : i64]
  [loop-ids : (& (__tl_dyn-array i64))]
  [loop-cnt : i64]) : unit
  (for [li (iterator.range 0 loop-cnt)]
    (let
      [bid : i64 (array-ref loop-ids li)]
      [edge-mark : i64 st.trail-len]
      [rmark : i64 st.rel-len]
      [inner-header? : bool
        (and
          (!= bid hid)
          (opt-range-block-is-loop-header?
            reachable
            tin
            tout
            pred-off
            pred-edges
            bid))]
      (when
        (!= bid hid)
        (let
          [pid : i64
            (opt-range-unique-live-entry-pred
              st
              reachable
              tin
              tout
              pred-off
              pred-edges
              bid)]
          (when
            (>= pid 0)
            (opt-range-refine-edge!
              st
              block-dense
              block-labels
              nonneg-globals
              pid
              bid))))
      (let
        [post-edge-mark : i64 st.trail-len]
        (match (& (array-ref block-dense bid))
          [(Block _ instrs)
            (let
              [n : i64 (ir.compiler-ir-instr-seq-count (& instrs))]
              (for [pos (iterator.range 0 n)]
                (match (ir.compiler-ir-instr-seq-borrow instrs pos)
                  [(Phi dst inputs ty)
                    (when
                      (!= bid hid)
                      (let
                        [r : OptRangeVal
                          (if inner-header?
                            (opt-range-range-for-type (& ty))
                            (opt-range-eval-phi-inputs
                              st
                              block-dense
                              block-labels
                              reachable
                              tin
                              tout
                              nonneg-globals
                              bid
                              (& inputs)
                              (& ty)
                              false
                              false))]
                        (opt-range-var-set! st dst (& r))))]
                  [_
                    (let
                      [dst : i64
                        (ir.compiler-ir-instr-dst
                          (ir.compiler-ir-instr-seq-borrow instrs pos))]
                      (when
                        (>= dst 0)
                        (let
                          [r : OptRangeVal
                            (opt-range-eval-instr
                              st
                              block-dense
                              nonneg-globals
                              (ir.compiler-ir-instr-seq-borrow instrs pos))]
                          (opt-range-var-set! st dst (& r)))))])))])
        ;; Undo edge refinements [edge-mark .. post-edge-mark) so facts from
        ;; branch arms never leak into sibling or post-merge blocks in RPO.
        (when
          (!= bid hid)
          (let
            [ti : i64 (- post-edge-mark 1)]
            (while (>= ti edge-mark)
              (let
                [te : OptRangeTrailEntry
                  (opt-range-trail-copy (& (array-ref st.trail ti)))]
                (when
                  (!= (array-ref st.def-block te.var) bid)
                  (set! (array-ref st.vals te.var) te.val)))
              (-= ti 1)))
          (set! st.rel-len rmark))))))

;; Query the upper bound enforced on a positive linear IV's backedge input
;; by the backedge branch guard (e.g. `cmp_lt next_i, ngroup` where `ngroup`
;; is bounded by a dominating precondition). Returns `I64_MAX` if unguarded.
(define (opt-range-phi-backedge-guard-hi
  [st : (&mut OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [block-labels : (& (__tl_dyn-array i64))]
  [reachable : (& (__tl_dyn-array bool))]
  [tin : (& (__tl_dyn-array i64))]
  [tout : (& (__tl_dyn-array i64))]
  [nonneg-globals : (& opt_i64_i64_map.Map)]
  [hid : i64]
  [inputs : (& inputs ir.CompilerIrPhiInputSeq)]
  [min-lo : i64]) : i64
  (let
    [n : i64 (ir.compiler-ir-phi-input-seq-count inputs)]
    [back-cnt : i64 0]
    [back-pid : i64 -1]
    [back-var : i64 -1]
    (for [i (iterator.range 0 n)]
      (let
        [inp (ir.compiler-ir-phi-input-seq-borrow inputs i)]
        [pid : i64
          (opt-range-label-to-id block-labels st.block-count inp.label)]
        (when
          (and
            (>= pid 0)
            (array-ref reachable pid)
            (not (array-ref st.block-dead pid))
            (opt-range-dominates? tin tout hid pid))
          (+= back-cnt 1)
          (set! back-pid pid)
          (match (& inp.value)
            [(Var v) (set! back-var v)]
            [_ (set! back-var -1)]))))
    (if (or (!= back-cnt 1) (< back-pid 0) (< back-var 0))
      opt-range-i64-max
      (let
        [gmark : i64 st.trail-len]
        [grmark : i64 st.rel-len]
        [rvar : i64 (opt-range-resolve-copy st back-var)]
        [wide : OptRangeVal (opt-range-interval min-lo opt-range-i64-max)]
        (opt-range-var-set! st back-var (& wide))
        (when (!= rvar back-var) (opt-range-var-set! st rvar (& wide)))
        (opt-range-refine-edge!
          st
          block-dense
          block-labels
          nonneg-globals
          back-pid
          hid)
        (let
          [gr1 : OptRangeVal (opt-range-var-get st back-var)]
          [gr2 : OptRangeVal (opt-range-var-get st rvar)]
          [gr : OptRangeVal (opt-range-meet (& gr1) (& gr2))]
          (opt-range-trail-rollback! st gmark)
          (set! st.rel-len grmark)
          (if (= gr.kind opt-range-kind-known)
            gr.hi
            opt-range-i64-max))))))

;; Detect whether a header phi `p` has a single backedge input `b = add p, step`
;; with constant `step > 0`. Returns `step` (> 0) or 0 if not a positive linear IV.
(define (opt-range-phi-positive-step
  [st : (& OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [block-labels : (& (__tl_dyn-array i64))]
  [reachable : (& (__tl_dyn-array bool))]
  [tin : (& (__tl_dyn-array i64))]
  [tout : (& (__tl_dyn-array i64))]
  [hid : i64]
  [phi-dst : i64]
  [inputs : (& inputs ir.CompilerIrPhiInputSeq)]) : i64
  (let
    [n : i64 (ir.compiler-ir-phi-input-seq-count inputs)]
    [back-cnt : i64 0]
    [back-var : i64 -1]
    (for [i (iterator.range 0 n)]
      (let
        [inp (ir.compiler-ir-phi-input-seq-borrow inputs i)]
        [pid : i64
          (opt-range-label-to-id block-labels st.block-count inp.label)]
        (when
          (and
            (>= pid 0)
            (array-ref reachable pid)
            (opt-range-dominates? tin tout hid pid))
          (+= back-cnt 1)
          (match (& inp.value)
            [(Var v) (set! back-var (opt-range-resolve-copy st v))]
            [_ (set! back-var -1)]))))
    (if (or
      (!= back-cnt 1)
      (< back-var 0)
      (!= (array-ref st.def-kind back-var) 2))
      0
      (let
        [db : i64 (array-ref st.def-block back-var)]
        [dp : i64 (array-ref st.def-pos back-var)]
        (match (& (array-ref block-dense db))
          [(Block _ instrs)
            (match (ir.compiler-ir-instr-seq-borrow instrs dp)
              [(BinOp _ (Add) lhs rhs ty)
                (if (not (opt-range-type-is-i64? (& ty)))
                  0
                  (cond
                    [(and
                        (opt-range-val-eq-var? (& lhs) phi-dst)
                        (match (& rhs)
                          [(I64 k) (> k 0)]
                          [_ false]))
                      (match (& rhs)
                        [(I64 k) k]
                        [_ 0])]
                    [(and
                        (opt-range-val-eq-var? (& rhs) phi-dst)
                        (match (& lhs)
                          [(I64 k) (> k 0)]
                          [_ false]))
                      (match (& lhs)
                        [(I64 k) k]
                        [_ 0])]
                    [else 0]))]
              [_ 0])])))))

;; Solve all phis at loop header `hid` using 1-step exact join + widening +
;; coupled linear-IV bounds + sound post-fixpoint verification.
(define (opt-range-sim-backedges!
  [st : (&mut OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [block-labels : (& (__tl_dyn-array i64))]
  [reachable : (& (__tl_dyn-array bool))]
  [tin : (& (__tl_dyn-array i64))]
  [tout : (& (__tl_dyn-array i64))]
  [pred-off : (& (__tl_dyn-array i64))]
  [pred-edges : (& (__tl_dyn-array i64))]
  [nonneg-globals : (& opt_i64_i64_map.Map)]
  [hid : i64]
  [instrs : (& ir.CompilerIrInstrSeq)]
  [phi-cnt : i64]
  [phi-dsts : (& (__tl_dyn-array i64))]
  [seed-vals : (& (__tl_dyn-array OptRangeVal))]
  [loop-ids : (& (__tl_dyn-array i64))]
  [loop-cnt : i64]
  [out-back : (&mut (__tl_dyn-array OptRangeVal))]) : unit
  (let
    [mark : i64 st.trail-len]
    [rmark : i64 st.rel-len]
    (for [pi (iterator.range 0 phi-cnt)]
      (opt-range-var-set!
        st
        (array-ref phi-dsts pi)
        (& (array-ref seed-vals pi))))
    (opt-range-sim-loop-blocks!
      st
      block-dense
      block-labels
      reachable
      tin
      tout
      pred-off
      pred-edges
      nonneg-globals
      hid
      loop-ids
      loop-cnt)
    (for [pi (iterator.range 0 phi-cnt)]
      (match (ir.compiler-ir-instr-seq-borrow instrs pi)
        [(Phi _ inputs ty)
          (set!
            (array-ref out-back pi)
            (opt-range-eval-phi-inputs
              st
              block-dense
              block-labels
              reachable
              tin
              tout
              nonneg-globals
              hid
              (& inputs)
              (& ty)
              false
              true))]
        [_ unit]))
    (opt-range-trail-rollback! st mark)
    (set! st.rel-len rmark)))

(define (opt-range-solve-loop-header!
  [st : (&mut OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [block-labels : (& (__tl_dyn-array i64))]
  [reachable : (& (__tl_dyn-array bool))]
  [rpo-num : (& (__tl_dyn-array i64))]
  [tin : (& (__tl_dyn-array i64))]
  [tout : (& (__tl_dyn-array i64))]
  [pred-off : (& (__tl_dyn-array i64))]
  [pred-edges : (& (__tl_dyn-array i64))]
  [nonneg-globals : (& opt_i64_i64_map.Map)]
  [hid : i64]) : unit
  (match (& (array-ref block-dense hid))
    [(Block _ instrs)
      (let
        [n : i64 (ir.compiler-ir-instr-seq-count (& instrs))]
        [phi-cnt : i64 0]
        (while (and
          (< phi-cnt n)
          (match (ir.compiler-ir-instr-seq-borrow instrs phi-cnt)
            [(Phi dst _ _)
              (opt-range-flag-set! st dst 8)
              true]
            [_ false]))
          (+= phi-cnt 1))
        (when
          (> phi-cnt 0)
          (let
            [loop-ids : (__tl_dyn-array i64) (opt-range-i64-arr 65)]
            [loop-cnt : i64
              (opt-range-collect-loop-blocks
                st.block-count
                reachable
                rpo-num
                tin
                tout
                pred-off
                pred-edges
                hid
                (&mut loop-ids))]
            (if (= loop-cnt 0)
              (for [pi (iterator.range 0 phi-cnt)]
                (match (ir.compiler-ir-instr-seq-borrow instrs pi)
                  [(Phi dst _ ty)
                    (opt-range-var-set!
                      st
                      dst
                      (& (opt-range-range-for-type (& ty))))]
                  [_ unit]))
              (let
                [phi-dsts : (__tl_dyn-array i64) (opt-range-i64-arr phi-cnt)]
                [phi-top : (__tl_dyn-array OptRangeVal)
                  (opt-range-val-arr phi-cnt)]
                [entry-vals : (__tl_dyn-array OptRangeVal)
                  (opt-range-val-arr phi-cnt)]
                [step1-vals : (__tl_dyn-array OptRangeVal)
                  (opt-range-val-arr phi-cnt)]
                [cand-vals : (__tl_dyn-array OptRangeVal)
                  (opt-range-val-arr phi-cnt)]
                [back-vals : (__tl_dyn-array OptRangeVal)
                  (opt-range-val-arr phi-cnt)]
                [iv-steps : (__tl_dyn-array i64) (opt-range-i64-arr phi-cnt)]
                [coupled : (__tl_dyn-array bool) (opt-range-bool-arr phi-cnt)]
                [back-edge-cnt : i64
                  (let
                    [ps : i64 (array-ref pred-off hid)]
                    [pe : i64 (array-ref pred-off (+ hid 1))]
                    [bc : i64 0]
                    (for [e (iterator.range ps pe)]
                      (let
                        [pid : i64 (array-ref pred-edges e)]
                        (when
                          (and
                            (array-ref reachable pid)
                            (opt-range-dominates? tin tout hid pid))
                          (+= bc 1))))
                    bc)]
                ;; Phase 0: seed each header phi from live entry edges only.
                (for [pi (iterator.range 0 phi-cnt)]
                  (match (ir.compiler-ir-instr-seq-borrow instrs pi)
                    [(Phi dst inputs ty)
                      (set! (array-ref phi-dsts pi) dst)
                      (set!
                        (array-ref phi-top pi)
                        (opt-range-range-for-type (& ty)))
                      (set!
                        (array-ref iv-steps pi)
                        (opt-range-phi-positive-step
                          st
                          block-dense
                          block-labels
                          reachable
                          tin
                          tout
                          hid
                          dst
                          (& inputs)))
                      (set!
                        (array-ref entry-vals pi)
                        (opt-range-eval-phi-inputs
                          st
                          block-dense
                          block-labels
                          reachable
                          tin
                          tout
                          nonneg-globals
                          hid
                          (& inputs)
                          (& ty)
                          true
                          false))]
                    [_ unit]))
                ;; Phase 1: simulate with entry seeds to get 1st backedge values.
                (opt-range-sim-backedges!
                  st
                  block-dense
                  block-labels
                  reachable
                  tin
                  tout
                  pred-off
                  pred-edges
                  nonneg-globals
                  hid
                  (& instrs)
                  phi-cnt
                  (& phi-dsts)
                  (& entry-vals)
                  (& loop-ids)
                  loop-cnt
                  (&mut back-vals))
                (for [pi (iterator.range 0 phi-cnt)]
                  (set!
                    (array-ref step1-vals pi)
                    (opt-range-join
                      (& (array-ref entry-vals pi))
                      (& (array-ref back-vals pi)))))
                ;; Phase 2: simulate with 1-step joined values & widen candidates.
                (opt-range-sim-backedges!
                  st
                  block-dense
                  block-labels
                  reachable
                  tin
                  tout
                  pred-off
                  pred-edges
                  nonneg-globals
                  hid
                  (& instrs)
                  phi-cnt
                  (& phi-dsts)
                  (& step1-vals)
                  (& loop-ids)
                  loop-cnt
                  (&mut back-vals))
                (for [pi (iterator.range 0 phi-cnt)]
                  (let
                    [bv2 : OptRangeVal (array-ref back-vals pi)]
                    [s1 : OptRangeVal (array-ref step1-vals pi)]
                    [ev : OptRangeVal (array-ref entry-vals pi)]
                    [tr : OptRangeVal (array-ref phi-top pi)]
                    (if (opt-range-subset? (& bv2) (& s1))
                      (set! (array-ref cand-vals pi) s1)
                      (let
                        [step : i64 (array-ref iv-steps pi)]
                        [guard-hi : i64
                          (if (and (> step 0) (= back-edge-cnt 1) (>= ev.lo 0))
                            (match (ir.compiler-ir-instr-seq-borrow instrs pi)
                              [(Phi _ inputs _)
                                (opt-range-phi-backedge-guard-hi
                                  st
                                  block-dense
                                  block-labels
                                  reachable
                                  tin
                                  tout
                                  nonneg-globals
                                  hid
                                  (& inputs)
                                  ev.lo)]
                              [_ opt-range-i64-max])
                            opt-range-i64-max)]
                        [cand : OptRangeVal
                          (cond
                            [(and
                                (> step 0)
                                (= back-edge-cnt 1)
                                (>= ev.lo 0)
                                (< guard-hi opt-range-i64-max)
                                (<= guard-hi (- opt-range-i64-max step)))
                              (opt-range-interval
                                ev.lo
                                (opt-range-max-i64 ev.hi guard-hi))]
                            [(and
                                (= step 0)
                                (= bv2.kind opt-range-kind-known)
                                (or (> bv2.lo tr.lo) (< bv2.hi tr.hi)))
                              (opt-range-join (& s1) (& bv2))]
                            [else
                              (opt-range-interval
                                (if (< bv2.lo s1.lo)
                                  (opt-range-max-i64 tr.lo opt-range-i64-min)
                                  s1.lo)
                                (if (> bv2.hi s1.hi)
                                  (opt-range-min-i64 tr.hi opt-range-i64-max)
                                  s1.hi))])]
                        (set! (array-ref cand-vals pi) cand)))))
                ;; Coupled linear-IV refinement (sound when back-edge-cnt == 1).
                (when
                  (= back-edge-cnt 1)
                  (let
                    [best-k : i64 -1]
                    (for [pi (iterator.range 0 phi-cnt)]
                      (let
                        [sp : i64 (array-ref iv-steps pi)]
                        [ev : OptRangeVal (array-ref entry-vals pi)]
                        [cv : OptRangeVal (array-ref cand-vals pi)]
                        (when
                          (and
                            (> sp 0)
                            (opt-range-is-const? (& ev))
                            (>= ev.lo 0)
                            (= cv.kind opt-range-kind-known)
                            (>= cv.lo ev.lo)
                            (<= cv.hi (- opt-range-i64-max sp)))
                          (let
                            [kmax : i64 (/ (- cv.hi ev.lo) sp)]
                            (when
                              (or (< best-k 0) (< kmax best-k))
                              (set! best-k kmax))))))
                    (when
                      (>= best-k 0)
                      (for [qi (iterator.range 0 phi-cnt)]
                        (let
                          [sq : i64 (array-ref iv-steps qi)]
                          [eq : OptRangeVal (array-ref entry-vals qi)]
                          [cq : OptRangeVal (array-ref cand-vals qi)]
                          (when
                            (and
                              (> sq 0)
                              (= eq.kind opt-range-kind-known)
                              (>= eq.lo 0)
                              (= cq.hi opt-range-i64-max))
                            (match (opt-range-safe-mul best-k sq)
                              [(Some delta)
                                (match (opt-range-safe-add eq.hi delta)
                                  [(Some qhi)
                                    (set!
                                      (array-ref cand-vals qi)
                                      (opt-range-interval eq.lo qhi))
                                    (set! (array-ref coupled qi) true)]
                                  [(None) unit])]
                              [(None) unit])))))))
                ;; Phase 3: sound post-fixpoint verification pass.
                (for [_round (iterator.range 0 2)]
                  (let
                    [all-ok? : bool true]
                    (opt-range-sim-backedges!
                      st
                      block-dense
                      block-labels
                      reachable
                      tin
                      tout
                      pred-off
                      pred-edges
                      nonneg-globals
                      hid
                      (& instrs)
                      phi-cnt
                      (& phi-dsts)
                      (& cand-vals)
                      (& loop-ids)
                      loop-cnt
                      (&mut back-vals))
                    (for [pi (iterator.range 0 phi-cnt)]
                      (when
                        (and
                          (not (array-ref coupled pi))
                          (not
                            (opt-range-subset?
                              (& (array-ref back-vals pi))
                              (& (array-ref cand-vals pi)))))
                        (set! all-ok? false)
                        (set!
                          (array-ref cand-vals pi)
                          (opt-range-val-copy (& (array-ref phi-top pi))))))
                    (when
                      (not all-ok?)
                      (for [qi (iterator.range 0 phi-cnt)]
                        (if (= _round 0)
                          (when
                            (array-ref coupled qi)
                            (set! (array-ref coupled qi) false)
                            (set!
                              (array-ref cand-vals qi)
                              (opt-range-val-copy (& (array-ref phi-top qi)))))
                          (when
                            (not (array-ref coupled qi))
                            (set!
                              (array-ref cand-vals qi)
                              (opt-range-val-copy (& (array-ref phi-top qi))))))))))
                (for [pi (iterator.range 0 phi-cnt)]
                  (opt-range-var-set!
                    st
                    (array-ref phi-dsts pi)
                    (& (array-ref cand-vals pi)))))))))]))

(define (opt-range-val-width
  [st : (& OptRangeState)]
  [val : (& ir.CompilerIrValue)]) : i64
  (match val
    [(I64 _) 64]
    [(Bool _) 1]
    [(Char _) 32]
    [(Var v)
      (if (and (>= v 0) (< v st.frame))
        (array-ref st.var-width v)
        0)]
    [_ 0]))

;; --- Block instruction walk & rewrites ---------------------------------------
(define (opt-range-divmod-op? [op : (& ir.CompilerIrBinOp)]) : bool
  (match op
    [(or (Div) (Mod) (SafeDiv) (SafeMod)) true]
    [_ false]))

(define (opt-range-process-block!
  [st : (&mut OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [block-labels : (& (__tl_dyn-array i64))]
  [reachable : (& (__tl_dyn-array bool))]
  [rpo-num : (& (__tl_dyn-array i64))]
  [tin : (& (__tl_dyn-array i64))]
  [tout : (& (__tl_dyn-array i64))]
  [pred-off : (& (__tl_dyn-array i64))]
  [pred-edges : (& (__tl_dyn-array i64))]
  [nonneg-globals : (& opt_i64_i64_map.Map)]
  [bid : i64]) : unit
  (let
    [is-header? : bool
      (opt-range-block-is-loop-header?
        reachable
        tin
        tout
        pred-off
        pred-edges
        bid)]
    (when
      is-header?
      (opt-range-solve-loop-header!
        st
        block-dense
        block-labels
        reachable
        rpo-num
        tin
        tout
        pred-off
        pred-edges
        nonneg-globals
        bid))
    (match (& (array-ref block-dense bid))
      [(Block label instrs)
        (let
          [n : i64 (ir.compiler-ir-instr-seq-count (& instrs))]
          ;; First evaluate + decide per-instruction action in scratch arena:
          ;;   0 = keep as-is
          ;;   1 = drop (discharged BoundsCheck)
          ;;   2 = fold compare -> Mov dst (Bool true)
          ;;   3 = fold compare -> Mov dst (Bool false)
          ;;   4 = fold branch cond -> true
          ;;   5 = fold branch cond -> false
          ;;   6 = fold select -> Mov dst on-true
          ;;   7 = fold select -> Mov dst on-false
          ;;   8 = fold mask -> Mov dst lhs
          ;;   9 = fold mask -> Mov dst rhs
          ;;  10 = fold mask -> Mov dst (I64 0)
          ;;  11 = retype signed Div/Mod/SafeDiv/SafeMod -> U64
          [actions : (__tl_dyn-array i64) (opt-range-i64-arr n)]
          [changed? : bool false]
          (for [pos (iterator.range 0 n)]
            (match (ir.compiler-ir-instr-seq-borrow instrs pos)
              [(Phi dst inputs ty)
                (when
                  (not is-header?)
                  (let
                    [r : OptRangeVal
                      (opt-range-eval-phi-inputs
                        st
                        block-dense
                        block-labels
                        reachable
                        tin
                        tout
                        nonneg-globals
                        bid
                        (& inputs)
                        (& ty)
                        false
                        false)]
                    (opt-range-var-set! st dst (& r))))]
              [(BoundsCheck idx len _)
                (let
                  [ir-v : OptRangeVal
                    (opt-range-value-get st nonneg-globals (& idx))]
                  [lr-v : OptRangeVal
                    (opt-range-value-get st nonneg-globals (& len))]
                  (cond
                    [(opt-range-bounds-check-always-traps? (& ir-v) (& lr-v))
                      (set! (array-ref st.block-dead bid) true)]
                    [(opt-range-bounds-check-provable?
                      st
                      block-dense
                      (& idx)
                      (& len)
                      (& ir-v)
                      (& lr-v))
                      (set! (array-ref actions pos) 1)
                      (set! changed? true)]
                    [else
                      (opt-range-record-passed-check!
                        st
                        block-dense
                        (& idx)
                        (& len)
                        (& lr-v))]))]
              [(BinOp dst op lhs rhs ty)
                (let
                  [r : OptRangeVal
                    (opt-range-eval-instr
                      st
                      block-dense
                      nonneg-globals
                      (ir.compiler-ir-instr-seq-borrow instrs pos))]
                  (opt-range-var-set! st dst (& r))
                  (cond
                    [(ir.compiler-ir-binop-compare? (& op))
                      (when
                        (and
                          (not (opt-range-addr-taken? st dst))
                          (opt-range-is-const? (& r)))
                        (set!
                          (array-ref actions pos)
                          (if (!= r.lo 0)
                            2
                            3))
                        (set! changed? true))]
                    [(and
                        (not (opt-range-addr-taken? st dst))
                        (opt-range-divmod-op? (& op))
                        (opt-range-type-is-i64? (& ty))
                        (match (& rhs)
                          [(I64 divisor)
                            (be_div.compiler-backend-unsigned-divmod-profitable?
                              divisor)]
                          [_ false]))
                      (let
                        [lr : OptRangeVal
                          (opt-range-value-get st nonneg-globals (& lhs))]
                        (when
                          (>= lr.lo 0)
                          (set! (array-ref actions pos) 11)
                          (set! changed? true)))]
                    [(and
                        (not (opt-range-addr-taken? st dst))
                        (not (opt-range-flag? st dst 4))
                        (match (& op)
                          [(or (BitAnd) (BitOr) (BitXor)) true]
                          [_ false]))
                      (let
                        [ar : OptRangeVal
                          (opt-range-value-get st nonneg-globals (& lhs))]
                        [br : OptRangeVal
                          (opt-range-value-get st nonneg-globals (& rhs))]
                        [mk : i64
                          (opt-range-mask-fold-kind (& op) (& ar) (& br) (& ty))]
                        [tw : i64 (opt-range-type-int-width (& ty))]
                        ;; Preserve operand width: never replace a widening
                        ;; `bit_and %bool, 255 : u64` with `mov %bool : u64`,
                        ;; which would let copy-prop feed a 1-byte var into a
                        ;; 64-bit backend op.
                        (cond
                          [(and
                            (= mk 1)
                            (> tw 0)
                            (= (opt-range-val-width st (& lhs)) tw))
                            (set! (array-ref actions pos) 8)
                            (set! changed? true)]
                          [(and
                            (= mk 2)
                            (> tw 0)
                            (= (opt-range-val-width st (& rhs)) tw))
                            (set! (array-ref actions pos) 9)
                            (set! changed? true)]
                          [(and (= mk 3) (= tw 64))
                            (set! (array-ref actions pos) 10)
                            (set! changed? true)]
                          [else unit]))]
                    [else unit]))]
              [(Select payload)
                (let
                  [r : OptRangeVal
                    (opt-range-eval-instr
                      st
                      block-dense
                      nonneg-globals
                      (ir.compiler-ir-instr-seq-borrow instrs pos))]
                  (opt-range-var-set! st payload.dst (& r))
                  (when
                    (and
                      (= payload.lanes 1)
                      (not (opt-range-addr-taken? st payload.dst)))
                    (let
                      [mr : OptRangeVal
                        (opt-range-value-get st nonneg-globals (& payload.mask))]
                      (when
                        (opt-range-is-const? (& mr))
                        (set!
                          (array-ref actions pos)
                          (if (!= mr.lo 0)
                            6
                            7))
                        (set! changed? true)))))]
              [(or (Branch cond-v _ _) (TotalEnumBranch cond-v _ _))
                (match (& cond-v)
                  [(Var _)
                    (let
                      [cr : OptRangeVal
                        (opt-range-value-get st nonneg-globals (& cond-v))]
                      (when
                        (opt-range-is-const? (& cr))
                        (set!
                          (array-ref actions pos)
                          (if (!= cr.lo 0)
                            4
                            5))
                        (set! changed? true)))]
                  [_ unit])]
              [_
                (let
                  [dst : i64
                    (ir.compiler-ir-instr-dst
                      (ir.compiler-ir-instr-seq-borrow instrs pos))]
                  (when
                    (>= dst 0)
                    (let
                      [r : OptRangeVal
                        (opt-range-eval-instr
                          st
                          block-dense
                          nonneg-globals
                          (ir.compiler-ir-instr-seq-borrow instrs pos))]
                      (opt-range-var-set! st dst (& r)))))]))
          ;; Rebuild the block in the caller's outer arena ONLY when changed.
          (when
            changed?
            (in-arena
              st.outer-arena
              (let
                [builder : ir.CompilerIrInstrBuilder
                  (ir.compiler-ir-instr-builder-with-capacity n)]
                (for [pos (iterator.range 0 n)]
                  (let
                    [act : i64 (array-ref actions pos)]
                    (when
                      (!= act 1)
                      (ir.compiler-ir-instr-builder-push!
                        (&mut builder)
                        (if (= act 0)
                          (ir.compiler-ir-instr-seq-ref (& instrs) pos)
                          (opt-range-rewrite-instr act (& instrs) pos))))))
                (set!
                  (array-ref st.out-blocks bid)
                  (ir.CompilerIrBlock.Block
                    label
                    (ir.compiler-ir-instr-builder-to-seq builder)))
                (set! (array-ref st.out-changed bid) true)
                (set! st.any-changed true)))))])))

(define (opt-range-rewrite-instr
  [act : i64]
  [instrs : (& ir.CompilerIrInstrSeq)]
  [pos : i64]) : ir.CompilerIrInstr
  (match (ir.compiler-ir-instr-seq-ref instrs pos)
    [(BinOp dst op lhs rhs ty)
      (cond
        [(= act 2) (ir.CompilerIrInstr.Mov dst (Bool true) (Bool))]
        [(= act 3) (ir.CompilerIrInstr.Mov dst (Bool false) (Bool))]
        [(= act 8) (ir.CompilerIrInstr.Mov dst lhs ty)]
        [(= act 9) (ir.CompilerIrInstr.Mov dst rhs ty)]
        [(= act 10) (ir.CompilerIrInstr.Mov dst (I64 0) ty)]
        [(= act 11) (ir.CompilerIrInstr.BinOp dst op lhs rhs (U64))]
        [else (ir.CompilerIrInstr.BinOp dst op lhs rhs ty)])]
    [(Branch c t f)
      (cond
        [(= act 4) (ir.CompilerIrInstr.Branch (Bool true) t f)]
        [(= act 5) (ir.CompilerIrInstr.Branch (Bool false) t f)]
        [else (ir.CompilerIrInstr.Branch c t f)])]
    [(TotalEnumBranch c t f)
      (cond
        [(= act 4) (ir.CompilerIrInstr.TotalEnumBranch (Bool true) t f)]
        [(= act 5) (ir.CompilerIrInstr.TotalEnumBranch (Bool false) t f)]
        [else (ir.CompilerIrInstr.TotalEnumBranch c t f)])]
    [(Select payload)
      (let
        [sel : ir.CompilerIrInstrSelectPayload (deref payload)]
        (cond
          [(= act 6) (ir.CompilerIrInstr.Mov sel.dst sel.on-true sel.ty)]
          [(= act 7) (ir.CompilerIrInstr.Mov sel.dst sel.on-false sel.ty)]
          [else (ir.CompilerIrInstr.Select (box sel))]))]
    [_ (ir.compiler-ir-instr-seq-ref instrs pos)]))

;; --- Dominator-tree DFS walk -------------------------------------------------
(define (opt-range-dfs!
  [st : (&mut OptRangeState)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [block-labels : (& (__tl_dyn-array i64))]
  [reachable : (& (__tl_dyn-array bool))]
  [rpo-num : (& (__tl_dyn-array i64))]
  [tin : (& (__tl_dyn-array i64))]
  [tout : (& (__tl_dyn-array i64))]
  [pred-off : (& (__tl_dyn-array i64))]
  [pred-edges : (& (__tl_dyn-array i64))]
  [nonneg-globals : (& opt_i64_i64_map.Map)]
  [bid : i64]) : unit
  (opt-range-process-block!
    st
    block-dense
    block-labels
    reachable
    rpo-num
    tin
    tout
    pred-off
    pred-edges
    nonneg-globals
    bid)
  (let
    [cs : i64 (array-ref st.dom-child-off bid)]
    [ce : i64 (array-ref st.dom-child-off (+ bid 1))]
    (for [ci (iterator.range cs ce)]
      (let
        [cid : i64 (array-ref st.dom-child-ids ci)]
        [tmark : i64 st.trail-len]
        [rmark : i64 st.rel-len]
        (opt-range-apply-entry-chain!
          st
          block-dense
          block-labels
          reachable
          tin
          tout
          pred-off
          pred-edges
          nonneg-globals
          bid
          cid
          6)
        (opt-range-dfs!
          st
          block-dense
          block-labels
          reachable
          rpo-num
          tin
          tout
          pred-off
          pred-edges
          nonneg-globals
          cid)
        (opt-range-trail-rollback! st tmark)
        (set! st.rel-len rmark)))))

;; --- Pre-scan & dom-child CSR builder ----------------------------------------
(define (opt-range-build-dom-children!
  [st : (&mut OptRangeState)]
  [reachable : (& (__tl_dyn-array bool))]
  [rpo-num : (& (__tl_dyn-array i64))]
  [idom : (& (__tl_dyn-array i64))]
  [entry-id : i64]) : unit
  (let
    [bc : i64 st.block-count]
    [counts : (__tl_dyn-array i64) (opt-range-i64-arr bc)]
    (for [id (iterator.range 0 bc)]
      (when
        (and (array-ref reachable id) (!= id entry-id))
        (let
          [p : i64 (array-ref idom id)]
          (when
            (and (>= p 0) (< p bc))
            (set! (array-ref counts p) (+ (array-ref counts p) 1))))))
    (let
      [sum : i64 0]
      (for [id (iterator.range 0 bc)]
        (set! (array-ref st.dom-child-off id) sum)
        (+= sum (array-ref counts id)))
      (set! (array-ref st.dom-child-off bc) sum)
      (set!
        st.dom-child-ids
        (opt-range-i64-arr
          (if (< sum 1)
            1
            sum)))
      (let
        [cursor : (__tl_dyn-array i64) (opt-range-i64-arr bc)]
        (for [id (iterator.range 0 bc)]
          (set! (array-ref cursor id) (array-ref st.dom-child-off id)))
        (for [id (iterator.range 0 bc)]
          (when
            (and (array-ref reachable id) (!= id entry-id))
            (let
              [p : i64 (array-ref idom id)]
              (when
                (and (>= p 0) (< p bc))
                (let
                  [at : i64 (array-ref cursor p)]
                  (set! (array-ref st.dom-child-ids at) id)
                  (set! (array-ref cursor p) (+ at 1)))))))
        ;; Sort each parent's dom children by rpo-num so diamond arms run
        ;; before their merge block.
        (for [p (iterator.range 0 bc)]
          (let
            [cs : i64 (array-ref st.dom-child-off p)]
            [ce : i64 (array-ref st.dom-child-off (+ p 1))]
            (for [i (iterator.range (+ cs 1) ce)]
              (let
                [key : i64 (array-ref st.dom-child-ids i)]
                [kr : i64 (array-ref rpo-num key)]
                [j : i64 (- i 1)]
                (while (and
                  (>= j cs)
                  (> (array-ref rpo-num (array-ref st.dom-child-ids j)) kr))
                  (set!
                    (array-ref st.dom-child-ids (+ j 1))
                    (array-ref st.dom-child-ids j))
                  (-= j 1))
                (set! (array-ref st.dom-child-ids (+ j 1)) key)))))))))

(define (opt-range-prescan-def-ty!
  [st : (&mut OptRangeState)]
  [dst : i64]
  [kind : i64]
  [ty : (& ast.AstType)]
  [set-width? : bool]) : unit
  (when (> kind 0) (set! (array-ref st.def-kind dst) kind))
  (when
    set-width?
    (set! (array-ref st.var-width dst) (opt-range-type-int-width ty)))
  (when
    (opt-range-descriptor-handle-type? st.type-segment-bases ty)
    (opt-range-flag-set! st dst 1)))

(define (opt-range-prescan!
  [st : (&mut OptRangeState)]
  [params : (& ir.CompilerIrParamSeq)]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [reachable : (& (__tl_dyn-array bool))]) : unit
  (let
    [pcount : i64 (ir.compiler-ir-param-seq-count params)]
    (for [pi (iterator.range 0 pcount)]
      (match (ir.compiler-ir-param-seq-borrow params pi)
        [(Param _ ty var)
          (when
            (and (>= var 0) (< var st.frame))
            (set!
              (array-ref st.def-count var)
              (+ (array-ref st.def-count var) 1))
            (opt-range-prescan-def-ty! st var 0 (& ty) true)
            (set! (array-ref st.vals var) (opt-range-range-for-type (& ty))))])))
  (for [bid (iterator.range 0 st.block-count)]
    (when
      (array-ref reachable bid)
      (match (& (array-ref block-dense bid))
        [(Block _ instrs)
          (let
            [n : i64 (ir.compiler-ir-instr-seq-count (& instrs))]
            (for [pos (iterator.range 0 n)]
              (let
                [dst : i64
                  (ir.compiler-ir-instr-dst
                    (ir.compiler-ir-instr-seq-borrow instrs pos))]
                (when
                  (and (>= dst 0) (< dst st.frame))
                  (set!
                    (array-ref st.def-count dst)
                    (+ (array-ref st.def-count dst) 1))
                  (set! (array-ref st.def-block dst) bid)
                  (set! (array-ref st.def-pos dst) pos)
                  (match (ir.compiler-ir-instr-seq-borrow instrs pos)
                    [(Mov _ src ty)
                      (opt-range-prescan-def-ty! st dst 1 (& ty) true)
                      (match (& src)
                        [(Var sv) (set! (array-ref st.copy-src dst) sv)]
                        [_ unit])]
                    [(BinOp _ op _ rhs ty)
                      (set! (array-ref st.def-kind dst) 2)
                      (set!
                        (array-ref st.var-width dst)
                        (if (ir.compiler-ir-binop-compare? (& op))
                          1
                          (opt-range-type-int-width (& ty))))
                      (match (& op)
                        [(or (Shl _) (Shr _))
                          (match (& rhs)
                            [(Var rv) (opt-range-flag-set! st rv 4)]
                            [_ unit])]
                        [_ unit])]
                    [(UnOp _ op _ ty)
                      (set! (array-ref st.def-kind dst) 3)
                      (set!
                        (array-ref st.var-width dst)
                        (match (& op)
                          [(Not) 1]
                          [_ (opt-range-type-int-width (& ty))]))]
                    [(Cast _ src from-ty to-ty)
                      (set! (array-ref st.def-kind dst) 4)
                      (let
                        [tw : i64 (opt-range-type-int-width (& to-ty))]
                        (set! (array-ref st.var-width dst) tw)
                        (when
                          (and
                            (= (opt-range-type-int-width (& from-ty)) 64)
                            (= tw 64))
                          (match (& src)
                            [(Var sv) (set! (array-ref st.copy-src dst) sv)]
                            [_ unit])))]
                    [(Phi _ _ ty)
                      (opt-range-prescan-def-ty! st dst 5 (& ty) true)]
                    [(Word _ _ _ ty)
                      (opt-range-prescan-def-ty! st dst 6 (& ty) true)]
                    [(Select payload)
                      (set! (array-ref st.def-kind dst) 7)
                      (set!
                        (array-ref st.var-width dst)
                        (opt-range-type-int-width (& payload.ty)))]
                    [(Load _ _ ty)
                      (opt-range-prescan-def-ty! st dst 8 (& ty) true)]
                    [(Gep _ _ _ _) (set! (array-ref st.def-kind dst) 9)]
                    [(Pack _ _ ty)
                      (opt-range-prescan-def-ty! st dst 0 (& ty) false)]
                    [(or (Call _ _ _ ty) (CallIndirect _ _ _ ty))
                      (opt-range-prescan-def-ty! st dst 0 (& ty) true)]
                    [_ unit])))))])))
  ;; Invalidate metadata for any multi-def or addr-taken variable.
  (for [v (iterator.range 0 st.frame)]
    (when
      (or (> (array-ref st.def-count v) 1) (opt-range-addr-taken? st v))
      (set! (array-ref st.def-kind v) 0)
      (set! (array-ref st.var-width v) 0)
      (set! (array-ref st.copy-src v) -1)
      (set! (array-ref st.var-flags v) (bit-and (array-ref st.var-flags v) 28))))
  ;; Second pass: mark descriptor length-slot GEPs via def-block/def-pos.
  (for [v (iterator.range 0 st.frame)]
    (when
      (= (array-ref st.def-kind v) 9)
      (match (& (array-ref block-dense (array-ref st.def-block v)))
        [(Block _ instrs)
          (match (ir.compiler-ir-instr-seq-borrow
            instrs
            (array-ref st.def-pos v))
            [(Gep dst base offset elem-ty)
              (match (& base)
                [(Var bv)
                  (when
                    (and
                      (opt-range-flag? st (opt-range-resolve-copy st bv) 1)
                      (match (& offset)
                        [(I64 k)
                          (or
                            (and
                              (= k 1)
                              (or
                                (opt-range-type-is-i64? (& elem-ty))
                                (opt-range-type-is-u64? (& elem-ty))))
                            (and
                              (= k 8)
                              (match (& elem-ty)
                                [(or (I8) (U8)) true]
                                [_ false])))]
                        [_ false]))
                    (opt-range-flag-set! st dst 2))]
                [_ unit])]
            [_ unit])]))))

;; --- Public entry point ------------------------------------------------------
(define (opt-range-cvp-blocks
  [type-segment-bases : i64]
  [params : (& ir.CompilerIrParamSeq)]
  [frame : i64]
  [entry-id : i64]
  [block-count : i64]
  [block-labels : (& (__tl_dyn-array i64))]
  [block-dense : (& (__tl_dyn-array ir.CompilerIrBlock))]
  [reachable : (& (__tl_dyn-array bool))]
  [rpo-num : (& (__tl_dyn-array i64))]
  [idom : (& (__tl_dyn-array i64))]
  [tin : (& (__tl_dyn-array i64))]
  [tout : (& (__tl_dyn-array i64))]
  [pred-off : (& (__tl_dyn-array i64))]
  [pred-edges : (& (__tl_dyn-array i64))]
  [addr-taken-marks : (& (__tl_dyn-array bool))]
  [nonneg-globals : (& opt_i64_i64_map.Map)]
  [blocks : ir.CompilerIrBlockList]) : OptRangeResult
  (if (or
    (<= frame 0)
    (<= block-count 0)
    (< entry-id 0)
    (>= entry-id block-count))
    (Result blocks false)
    (if (not (array-ref reachable entry-id))
      (Result blocks false)
      (let
        [outer : arena.Arena
          (unsafe
            (arena.Arena (arena.raw-handle (arena.current))))]
        [scratch : arena.Arena (arena.make)]
        [out-blocks : (__tl_dyn-array ir.CompilerIrBlock)
          (__tl_make-array ir.CompilerIrBlock block-count)]
        [out-changed : (__tl_dyn-array bool) (opt-range-bool-arr block-count)]
        [any-changed : bool
          (in-arena
            (unsafe
              (arena.Arena (arena.raw-handle scratch)))
            (let
              [vals-arr : (__tl_dyn-array OptRangeVal)
                (opt-range-val-arr frame)]
              [copy-arr : (__tl_dyn-array i64) (opt-range-i64-arr frame)]
              [flags-arr : (__tl_dyn-array i64) (opt-range-i64-arr frame)]
              [top-v : OptRangeVal (opt-range-top)]
              [_init-vars : unit
                (for [v (iterator.range 0 frame)]
                  (set! (array-ref vals-arr v) (opt-range-val-copy (& top-v)))
                  (set! (array-ref copy-arr v) -1)
                  (when
                    (and
                      (< v (array-length addr-taken-marks))
                      (array-ref addr-taken-marks v))
                    (set! (array-ref flags-arr v) 16)))]
              [st : OptRangeState
                (OptRangeState
                  outer
                  type-segment-bases
                  frame
                  block-count
                  vals-arr
                  (opt-range-i64-arr frame)
                  (opt-range-i64-arr frame)
                  (opt-range-i64-arr frame)
                  (opt-range-i64-arr frame)
                  (opt-range-i64-arr frame)
                  copy-arr
                  flags-arr
                  (__tl_make-array OptRangeTrailEntry 64)
                  0
                  64
                  (__tl_make-array OptRangeRelFact 32)
                  0
                  32
                  (opt-range-bool-arr block-count)
                  (opt-range-i64-arr (+ block-count 1))
                  (opt-range-i64-arr 1)
                  out-blocks
                  out-changed
                  false)]
              (opt-range-prescan! (&mut st) params block-dense reachable)
              (opt-range-build-dom-children!
                (&mut st)
                reachable
                rpo-num
                idom
                entry-id)
              (opt-range-dfs!
                (&mut st)
                block-dense
                block-labels
                reachable
                rpo-num
                tin
                tout
                pred-off
                pred-edges
                nonneg-globals
                entry-id)
              (set! out-blocks st.out-blocks)
              (set! out-changed st.out-changed)
              st.any-changed))]
        (arena.destroy-safe! scratch)
        (if (not any-changed)
          (Result blocks false)
          (match (& blocks)
            [(Array bseq)
              (let
                [builder : ir.CompilerIrBlockBuilder
                  (ir.compiler-ir-block-builder-new)]
                [nblocks : i64 (ir.compiler-ir-block-seq-count (& bseq))]
                (for [i (iterator.range 0 nblocks)]
                  (let
                    [blk : ir.CompilerIrBlock
                      (ir.compiler-ir-block-seq-ref (& bseq) i)]
                    (match (& blk)
                      [(Block lbl _)
                        (let
                          [bid : i64
                            (opt-range-label-to-id block-labels block-count lbl)]
                          (if (and
                            (>= bid 0)
                            (< bid block-count)
                            (array-ref out-changed bid))
                            (ir.compiler-ir-block-builder-push!
                              (&mut builder)
                              (replace! (array-ref out-blocks bid) blk))
                            (ir.compiler-ir-block-builder-push!
                              (&mut builder)
                              blk)))])))
                (Result (ir.compiler-ir-block-builder-to-list builder) true))]))))))