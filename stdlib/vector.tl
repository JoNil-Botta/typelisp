;# Generated concrete vector family (collections v1).
;#
;# A growable, owned sequence with private dynamic backing storage plus a
;# live-element count (`len`). Capacity is the backing buffer length; `push`
;# doubles that buffer when it is full, copying the live prefix into the larger
;# buffer. Each generated module has a stable namespace keyed by its element
;# type.
;#
;# Mutating operations take `&mut Vec`: `set`, `push`, `pop`, and `reverse!`
;# update the backing array in place, while `push` grows that array when needed.
;# Reads are bounds-checked and return a caller-supplied fallback rather than
;# panicking, so the module typechecks on every stage0 regardless of the
;# never-type.
;#
;# `(vector T)` emits the full API. Append-oriented users can import
;# `(vector T core)` to emit only `Vec`, construction, length/capacity,
;# bounds-checked get/set, push, and their storage/growth helpers. Core mode
;# does not construct iterator, clone/pop, map/fold, reverse, or
;# contains declarations, so non-cloneable aggregate elements remain usable.
;# Full mode instantiates `stdlib.eq` structural equality for `contains?`;
;# element types unsupported by generated equality can still use core mode
;# when containment and the other full helpers are not required.
;#
;# Generated family metadata is type-agnostic. Struct and enum element
;# instantiations use the same private dynamic storage and
;# `array-ref`/`array-set!`
;# move pattern as scalar and `String` families: `push`/`set!` move the element
;# into a live slot, `pop` moves the last live element out with the shrunk
;# vector, and growth helpers move the live prefix into fresh storage. The same
;# source API works whether aggregate elements occupy handle slots or are stored
;# inline in the backing buffer.
;#
;# Shared traversal uses the generated `iterator` / `next` pair. Its
;# `IterNext.Item` payload is a borrow of the original vector element, so
;# move-only aggregate elements are read or drawn without a copy or move. The
;# iterator and every yielded item retain a shared source borrow until their
;# final use; mutation, growth, moving, or mutable borrowing of the vector then
;# becomes available again.
;#
;# Consuming traversal uses `into-iterator` / `into-next`. Constructing the
;# iterator moves the vector exactly once, and each `IntoNext.Item` owns its
;# element. An internal live-slot bitmap lets `into-next` extract through
;# `array-take!` without copying or cloning; repeated exhaustion is stable.
;# Cleanup-owning element types select an ownership-safe specialization whose
;# backing arrays contain only constructed elements. `set` cleans replacements,
;# `push-owned` supports consuming expression-style construction, yielded items
;# own their cleanup, and abandoning an iterator drains unvisited live slots.
;# Clone-dependent helpers are omitted from that specialization.
;#
;# Compiler code should use generated vectors for append-heavy private sequences
;# that are not part of the user-facing AST shape, such as IR instructions,
;# tool discovery buffers, or temporary ordered worklists. Recursive enum lists
;# remain the better fit for parser/AST structures where the cons shape is the
;# language model, pattern matching is the main operation, or preserving a stable
;# checked-in recursive representation matters more than append throughput.
;#
;# Usage: import the module-emitting `(vector T)` macro for each concrete
;# element type so every instantiation receives its own module namespace:
;#
;# ```typelisp
;# (import stdlib.vector)
;#
;# (import (vector.vector i64) as ivec)
;# (import (vector.vector String) as svec)
;# (import (vector.vector i64 core) as compact_ivec)
;#
;# (define (main) : i64
;#   (let
;#     [v : ivec.Vec (ivec.new)]
;#     [words : svec.Vec (svec.new)]
;#     (begin
;#       (ivec.push (&mut v) 10)
;#       (ivec.push (&mut v) 32)
;#       (svec.push (&mut words) "x")
;#       (+ (ivec.len (& v)) (svec.len (& words))))))
;# ```
(import stdlib.eq)

;: Emit a generated growable vector module for element type `T`.
;:
;: `(vector T)` retains the full vector API. `(vector T core)` emits only
;: `Vec`, `new`, `with-capacity`, `len`, `capacity`, `get`,
;: `set`, and `push` plus their shared storage/growth helpers. Core mode is
;: suitable for append-oriented compiler-private collections and does not
;: instantiate clone-dependent operations such as `pop` or generated equality
;: for `contains?`.
;: The kind constraint is the complete storable `type-kind` vocabulary.
;: Future kinds must be added here when vector backing storage supports them;
;: `never`, `region`, and unresolved `type-var` are intentionally excluded.
(defmacro (vector
  [T
    : type
    (:kind i64 i32 i16 i8 u64 u32 u16 u8 f64 f32 bool char string unit array dyn-array box function tuple struct enum str ptr mut-ptr ref mut-ref)]
  [capabilities : Expr ...]) : Module
  (let
    [capability-count : i64 (expr-list-length capabilities)]
    [core-only : bool
      (match capability-count
        [0 false]
        [1
          (match (expr-list-nth capabilities 0)
            [(Expr.Var capability)
              (match capability
                ["core" true]
                [_
                  (comptime-error
                    "vector: optional capability must be bare `core`")])]
            [_
              (comptime-error "vector: optional capability must be bare `core`")])]
        [_ (comptime-error "vector: expected at most one capability")])]
    [module-name : Expr
      (expr-var
        (comptime.string-append
          (if core-only
            "stdlib.vector.generated.core."
            "stdlib.vector.generated.")
          (type-key T)))]
    [cleanup-owning : bool (type-cleanup-owning? T)]
    [cleanup-function : String
      (if (type-cleanup-owning? T)
        (type-cleanup-function T)
        "")]
    [cleanup-function-expr : Expr (expr-var cleanup-function)]
    [cleanup-extra-decls : ExprList
      (if core-only
        (expr-list-empty)
        (match `(begin
          (defstruct Iter
            (:lifetimes source)
            (slots (& source (__tl_dyn-array ,T)))
            (len i64)
            (index i64))
          (defenum IterNext
            (:lifetimes source)
            (Done)
            (Item (& source ,T)))
          (defstruct IterMut
            (:lifetimes source)
            (slots (&mut source (__tl_dyn-array ,T)))
            (len i64)
            (index i64))
          (defenum IterMutNext
            (:lifetimes source)
            (Done)
            (Item (&mut source ,T)))
          (defstruct IntoIter
            (:cleanup cleanup-into-iter)
            (vec Vec (:owned))
            (index i64))
          (defenum IntoNext
            (:cleanup cleanup-into-next)
            (Done)
            (Item ,T (:owned)))
          (define (is-empty? [v : (& v Vec)]) : bool
            (<= (len v) 0))
          (define (iterator [v : (& source Vec)]) : (Iter source)
            (Iter
              (& (struct-get (struct-get v state) slots))
              (struct-get v len)
              0))
          (define (next [iter : (&mut state (Iter source))]) : (IterNext source)
            (let
              [index : i64 (struct-get iter index)]
              (if (>= index (struct-get iter len))
                (IterNext.Done)
                (begin
                  (set! (struct-get iter index) (+ index 1))
                  (IterNext.Item (& (array-ref (struct-get iter slots) index)))))))
          (define (iterator-mut [v : (&mut source Vec)]) : (IterMut source)
            (IterMut
              (&mut (struct-get (struct-get v state) slots))
              (struct-get v len)
              0))
          (define (next-mut [iter : (&mut state (IterMut source))]) : (IterMutNext
              source)
            (let
              [index : i64 (struct-get iter index)]
              (if (>= index (struct-get iter len))
                (IterMutNext.Done)
                (begin
                  (set! (struct-get iter index) (+ index 1))
                  (IterMutNext.Item
                    (&mut (array-ref (struct-get iter slots) index)))))))
          (define (into-iterator [v : Vec (:consume)]) : IntoIter
            (IntoIter v 0))
          (define (into-next [iter : (&mut state IntoIter)]) : IntoNext
            (let
              [index : i64 (struct-get iter index)]
              (if (>= index (struct-get (struct-get iter vec) len))
                (IntoNext.Done)
                (let
                  [taken : (Tuple bool ,T)
                    (array-take!
                      (struct-get
                        (struct-get (struct-get iter vec) state)
                        slots)
                      (struct-get (struct-get (struct-get iter vec) state) live)
                      index)]
                  (begin
                    (set! (struct-get iter index) (+ index 1))
                    (if (tuple-ref taken 0)
                      (IntoNext.Item (tuple-ref taken 1))
                      (IntoNext.Done))))))))
          [(Expr.Begin decls) decls]
          [_ (expr-list-empty)]))]
    [cleanup-module-decls : Expr
      `(begin
        (module ,module-name)
        ;; Only constructed elements enter storage. The liveness bitmap is the
        ;; single source of truth for cleanup after consuming extraction.
        (defstruct SlotState
          (slots (__tl_dyn-array ,T))
          (live (__tl_dyn-array bool)))
        (define (cleanup-slot-state [state : SlotState]) : unit
          (let
            [index : i64 0]
            [count : i64 (array-length (struct-get state live))]
            (begin
              (while (< index count)
                (let
                  [taken : (Tuple bool ,T)
                    (array-take!
                      (struct-get state slots)
                      (struct-get state live)
                      index)]
                  (begin
                    (if (tuple-ref taken 0)
                      (,cleanup-function-expr (tuple-ref taken 1))
                      unit)
                    (set! index (+ index 1)))))
              unit)))
        (defstruct Vec
          (:cleanup cleanup-vec)
          (state SlotState (:cleanup cleanup-slot-state))
          (len i64)
          (capacity i64))
        (define (slots [v : (& v Vec)]) : (& v (__tl_dyn-array ,T))
          (& (struct-get (struct-get v state) slots)))
        (define (len [v : (& v Vec)]) : i64
          (struct-get v len))
        (define (capacity [v : (& v Vec)]) : i64
          (struct-get v capacity))
        (define (with-capacity [capacity : i64]) : Vec
          (let
            [cap : i64
              (if (< capacity 1)
                1
                capacity)]
            (Vec (SlotState (make-array ,T 0) (make-array bool 0)) 0 cap)))
        (define (new) : Vec
          (with-capacity 4))
        (define (set [v : (&mut v Vec)] [index : i64] [value : ,T]) : unit
          (if (if (>= index 0)
            (< index (struct-get v len))
            false)
            (let
              [taken : (Tuple bool ,T)
                (array-take!
                  (struct-get (struct-get v state) slots)
                  (struct-get (struct-get v state) live)
                  index)]
              (begin
                (if (tuple-ref taken 0)
                  (,cleanup-function-expr (tuple-ref taken 1))
                  unit)
                (array-set! (struct-get (struct-get v state) slots) index value)
                (array-set! (struct-get (struct-get v state) live) index true)))
            (,cleanup-function-expr value)))
        (define (push [v : (&mut v Vec)] [value : ,T]) : unit
          (let
            [index : i64 (struct-get v len)]
            (begin
              (if (>= index (struct-get v capacity))
                (set!
                  (struct-get v capacity)
                  (if (< (struct-get v capacity) 1)
                    1
                    (* (struct-get v capacity) 2)))
                unit)
              (array-push! (struct-get (struct-get v state) slots) value)
              (array-push! (struct-get (struct-get v state) live) true)
              (set! (struct-get v len) (+ index 1)))))
        (define (push-owned [v : Vec (:consume)] [value : ,T]) : Vec
          (begin
            (push (&mut v) value)
            v))
        ,@cleanup-extra-decls)]
    ;; Construct the append/read/mutate core once, then splice that exact
    ;; declaration list into the generated module.
    [core-decls : Expr
      `(begin
        (defstruct Vec
          (slots (__tl_dyn-array ,T))
          (len i64))
        (define (slots [v : (& v Vec)]) : (& v (__tl_dyn-array ,T))
          (& (struct-get v slots)))
        (define (len [v : (& v Vec)]) : i64
          (struct-get v len))
        (define (capacity [v : (& v Vec)]) : i64
          (array-length (slots v)))
        (define (with-capacity [capacity : i64]) : Vec
          (let
            [cap : i64
              (if (< capacity 1)
                1
                capacity)]
            (Vec (make-array ,T cap) 0)))
        (define (new) : Vec
          (with-capacity 4))
        (define (get [v : (& v Vec)] [index : i64] [fallback : ,T]) : ,T
          (if (if (>= index 0)
            (< index (len v))
            false)
            (array-ref (slots v) index)
            fallback))
        (define (set [v : (&mut v Vec)] [index : i64] [value : ,T]) : unit
          (if (if (>= index 0)
            (< index (struct-get v len))
            false)
            (array-set! (struct-get v slots) index value)
            unit))
        (define (copy-range!
          [dst : (&mut dst (__tl_dyn-array ,T))]
          [src : (& src (__tl_dyn-array ,T))]
          [index : i64]
          [count : i64]) : unit
          (if (>= index count)
            unit
            (begin
              (array-set! dst index (array-ref src index))
              (copy-range! dst src (+ index 1) count))))
        (define (grow [v : (&mut v Vec)]) : unit
          (let
            [n : i64 (struct-get v len)]
            [old-cap : i64 (array-length (struct-get v slots))]
            [new-cap : i64
              (if (< old-cap 1)
                1
                (* old-cap 2))]
            [bigger : (__tl_dyn-array ,T) (make-array ,T new-cap)]
            (begin
              (copy-range! (&mut bigger) (& (struct-get v slots)) 0 n)
              (set! (struct-get v slots) bigger))))
        (define (push [v : (&mut v Vec)] [value : ,T]) : unit
          (begin
            (if (< (struct-get v len) (array-length (struct-get v slots)))
              unit
              (grow v))
            (let
              [index : i64 (struct-get v len)]
              (begin
                (array-set! (struct-get v slots) index value)
                (set! (struct-get v len) (+ index 1)))))))]
    (if cleanup-owning
      cleanup-module-decls
      (match core-decls
        [(Expr.Begin core)
          (if core-only
            `(begin
              (module ,module-name)
              ,@core)
            (let
              [vec-name : Expr (expr-var "Vec")]
              [pop-name : Expr (expr-var "Pop")]
              [pop-empty-name : Expr (expr-var "Pop.Empty")]
              [pop-ok-name : Expr (expr-var "Pop.Ok")]
              [iter-name : Expr (expr-var "Iter")]
              [iter-next-name : Expr (expr-var "IterNext")]
              [iter-done-name : Expr (expr-var "IterNext.Done")]
              [iter-item-name : Expr (expr-var "IterNext.Item")]
              [iter-mut-name : Expr (expr-var "IterMut")]
              [iter-mut-next-name : Expr (expr-var "IterMutNext")]
              [iter-mut-done-name : Expr (expr-var "IterMutNext.Done")]
              [iter-mut-item-name : Expr (expr-var "IterMutNext.Item")]
              [into-iter-name : Expr (expr-var "IntoIter")]
              [into-next-name : Expr (expr-var "IntoNext")]
              [into-done-name : Expr (expr-var "IntoNext.Done")]
              [into-item-name : Expr (expr-var "IntoNext.Item")]
              [kind : String (type-kind T)]
              ;; Borrowed String storage has the public immutable `str` view
              ;; type. Other shared items retain their concrete element type,
              ;; including move-only aggregates.
              [iter-item-type : Expr
                (match kind
                  ["string" (expr-var "str")]
                  [_ `,T])]
              ;; String elements are immutable by language policy, so their iterator
              ;; item is the ordinary borrowed `str` view. Other element kinds yield
              ;; an exclusive reference to their concrete element type.
              [iter-mut-borrow-name : Expr
                (match kind
                  ["string" (expr-var "&")]
                  [_ (expr-var "&mut")])]
              [iter-mut-item-type : Expr
                (match kind
                  ["string" (expr-var "str")]
                  [_ `,T])]
              `(begin
                (module ,module-name)
                (import (eq.eq ,T) as value_eq)
                ,@core
                (defenum ,pop-name
                  (Empty)
                  (Ok ,T))
                ;; Shared iteration retains the vector's source borrow. `next`
                ;; reborrows an element through the stored array reference, so an
                ;; Item keeps the source lifetime rather than the short borrow of
                ;; iterator state.
                (defstruct ,iter-name
                  (:lifetimes source)
                  (slots (& source (__tl_dyn-array ,T)))
                  (len i64)
                  (index i64))
                (defenum ,iter-next-name
                  (:lifetimes source)
                  (Done)
                  (Item (& source ,iter-item-type)))
                ;; This state owns the vector's exclusive source borrow. `next-mut`
                ;; reborrows one element from that stored reference, so the item keeps
                ;; the vector lifetime rather than the short borrow of the state.
                (defstruct ,iter-mut-name
                  (:lifetimes source)
                  (slots (&mut source (__tl_dyn-array ,T)))
                  (len i64)
                  (index i64))
                ;; Mutable iteration is lending: an Item keeps the source borrow live,
                ;; so callers must finish with it before asking for the next item.
                (defenum ,iter-mut-next-name
                  (:lifetimes source)
                  (Done)
                  (Item (,iter-mut-borrow-name source ,iter-mut-item-type)))
                ;; Consuming iteration owns the moved backing storage. The bitmap
                ;; records which live-prefix slots still own values, so each Item
                ;; can move exactly once through `array-take!`.
                (defstruct ,into-iter-name
                  (slots (__tl_dyn-array ,T))
                  (live (__tl_dyn-array bool))
                  (len i64)
                  (index i64))
                (defenum ,into-next-name
                  (Done)
                  (Item ,T))
                (define (slots-mut [v : (&mut v ,vec-name)]) : (&mut
                    v
                    (__tl_dyn-array ,T))
                  (&mut (struct-get v slots)))
                (define (len-mut [v : (&mut v ,vec-name)]) : i64
                  (struct-get v len))
                (define (is-empty? [v : (& v ,vec-name)]) : bool
                  (<= (len v) 0))
                (define (iterator [v : (& source ,vec-name)]) : (,iter-name
                    source)
                  (,iter-name (& (struct-get v slots)) (struct-get v len) 0))
                (define (next [iter : (&mut state (,iter-name source))]) : (,iter-next-name
                    source)
                  (let
                    [index : i64 (struct-get iter index)]
                    (if (>= index (struct-get iter len))
                      (,iter-done-name)
                      (begin
                        (set! (struct-get iter index) (+ index 1))
                        (,iter-item-name
                          (& (array-ref (struct-get iter slots) index)))))))
                (define (iterator-mut [v : (&mut source ,vec-name)]) : (,iter-mut-name
                    source)
                  (,iter-mut-name
                    (&mut (struct-get v slots))
                    (struct-get v len)
                    0))
                (define (next-mut [iter : (&mut state (,iter-mut-name source))]) : (,iter-mut-next-name
                    source)
                  (let
                    [index : i64 (struct-get iter index)]
                    (if (>= index (struct-get iter len))
                      (,iter-mut-done-name)
                      (begin
                        (set! (struct-get iter index) (+ index 1))
                        (,iter-mut-item-name
                          (,iter-mut-borrow-name
                            (array-ref (struct-get iter slots) index)))))))
                (define (into-live-slots [len : i64]) : (__tl_dyn-array bool)
                  (let
                    [live : (__tl_dyn-array bool) (make-array bool len)]
                    [index : i64 0]
                    (begin
                      (while (< index len)
                        (begin
                          (array-set! live index true)
                          (set! index (+ index 1))))
                      live)))
                (define (into-iterator [v : ,vec-name (:consume)]) : ,into-iter-name
                  (let
                    [len : i64 (struct-get v len)]
                    [live : (__tl_dyn-array bool) (into-live-slots len)]
                    [slots : (__tl_dyn-array ,T) (struct-get v slots)]
                    (,into-iter-name slots live len 0)))
                (define (into-next [iter : (&mut state ,into-iter-name)]) : ,into-next-name
                  (let
                    [index : i64 (struct-get iter index)]
                    (if (>= index (struct-get iter len))
                      (,into-done-name)
                      (let
                        [taken : (Tuple bool ,T)
                          (array-take!
                            (struct-get iter slots)
                            (struct-get iter live)
                            index)]
                        (begin
                          (set! (struct-get iter index) (+ index 1))
                          (if (tuple-ref taken 0)
                            (,into-item-name (tuple-ref taken 1))
                            (,into-done-name)))))))
                (define (last [v : (& v ,vec-name)] [fallback : ,T]) : ,T
                  (get v (- (len v) 1) fallback))
                (define (pop [v : (&mut v ,vec-name)]) : ,pop-name
                  (if (<= (struct-get v len) 0)
                    (,pop-empty-name)
                    (let
                      [last-index : i64 (- (struct-get v len) 1)]
                      [value : ,T
                        (clone (array-ref (struct-get v slots) last-index))]
                      (begin
                        (set! (struct-get v len) last-index)
                        (,pop-ok-name value)))))
                (define (reverse-range!
                  [items : (&mut items (__tl_dyn-array ,T))]
                  [lo : i64]
                  [hi : i64]) : unit
                  (if (>= lo hi)
                    unit
                    (let
                      [tmp : ,T (array-ref items lo)]
                      (begin
                        (array-set! items lo (array-ref items hi))
                        (array-set! items hi tmp)
                        (reverse-range! items (+ lo 1) (- hi 1))))))
                (define (reverse! [v : (&mut v ,vec-name)]) : unit
                  (let
                    [last-index : i64 (- (struct-get v len) 1)]
                    (reverse-range! (&mut (struct-get v slots)) 0 last-index)))
                (define (fold-from
                  [v : (& v ,vec-name)]
                  [index : i64]
                  [acc : ,T]
                  [step : (-> ,T ,T ,T)]) : ,T
                  (if (>= index (len v))
                    acc
                    (fold-from
                      v
                      (+ index 1)
                      (step acc (array-ref (slots v) index))
                      step)))
                (define (fold
                  [v : (& v ,vec-name)]
                  [acc : ,T]
                  [step : (-> ,T ,T ,T)]) : ,T
                  (fold-from v 0 acc step))
                (define (map-build-from
                  [v : (& v ,vec-name)]
                  [index : i64]
                  [out : (&mut out ,vec-name)]
                  [mapper : (-> ,T ,T)]) : unit
                  (if (>= index (len v))
                    unit
                    (begin
                      (push out (mapper (array-ref (slots v) index)))
                      (map-build-from v (+ index 1) out mapper))))
                (define (map-from
                  [v : (& v ,vec-name)]
                  [index : i64]
                  [mapper : (-> ,T ,T)]) : ,vec-name
                  (let
                    [out : ,vec-name (new)]
                    (begin
                      (map-build-from v index (&mut out) mapper)
                      out)))
                (define (map [v : (& v ,vec-name)] [mapper : (-> ,T ,T)]) : ,vec-name
                  (map-from v 0 mapper))
                (define (contains-from?
                  [v : (& v ,vec-name)]
                  [x : ,T]
                  [index : i64]) : bool
                  (if (>= index (len v))
                    false
                    (if (value_eq.eq (array-ref (slots v) index) x)
                      true
                      (contains-from? v x (+ index 1)))))
                (define (contains? [v : (& v ,vec-name)] [x : ,T]) : bool
                  (contains-from? v x 0)))))]
        [_ (comptime-error "vector: internal core declaration shape")]))))