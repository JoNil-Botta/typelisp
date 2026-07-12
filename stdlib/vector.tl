;# Generated concrete vector family (collections v1).
;#
;# A growable, owned sequence built on the fixed `(Array T)` primitive: a
;# backing array plus a live-element count (`len`). Capacity is the backing array
;# length; `push` doubles the backing array when it is full, copying the live
;# prefix into the larger array. Each generated module has a stable namespace
;# keyed by its element type.
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
;# does not construct iterator, clone/pop, conversion, map/fold, reverse, or
;# contains declarations, so non-cloneable aggregate elements remain usable.
;#
;# Generated family metadata is type-agnostic. Struct and enum element
;# instantiations use the same `(Array T)` storage and `array-ref`/`array-set!`
;# move pattern as scalar and `String` families: `push`/`set!` move the element
;# into a live slot, `pop` moves the last live element out with the shrunk
;# vector, and copying/growth/snapshot helpers move the live prefix into fresh
;# arrays. The same source API works whether aggregate elements occupy handle
;# slots or are stored inline in the backing array.
;#
;# When reading move-only aggregate elements through a shared vector borrow,
;# prefer the generated `get` helper (for example `bvec.get (& balls) i
;# fallback`) or borrow `slots` from a vector place inside the iteration body.
;# A direct `array-ref` through a reference rvalue such as `(& world.balls)`
;# remains region-tagged and cannot be passed by value to another function.
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
;: Local string equality fallback used when bootstrapping with a compiler that
;: does not yet expose private string intrinsics.
(cfg
  (not feature-compiler-private-string-intrinsics)
  (define (string-eq [a : String] [b : String]) : bool
    (let
      [n : i64 (string-length a)]
      [i : i64 0]
      [same : bool (= n (string-length b))]
      (begin
        (while (if same
          (< i n)
          false)
          (begin
            (if (= (string-ref a i) (string-ref b i))
              unit
              (set! same false))
            (set! i (+ i 1))))
        same))))

;: Emit a generated growable vector module for element type `T`.
;:
;: `(vector T)` retains the full vector API. `(vector T core)` emits only
;: `Vec`, `new`, `with-capacity`, `len`, `capacity`, `get`,
;: `set`, and `push` plus their shared storage/growth helpers. Core mode is
;: suitable for append-oriented compiler-private collections and does not
;: instantiate clone-dependent operations such as `pop`.
(defmacro (vector [T : type] [capabilities : Expr ...]) : Module
  (let
    [capability-count : i64 (expr-list-length capabilities)]
    [core-only : bool
      (match capability-count
        [0 false]
        [1
          (match (expr-list-nth capabilities 0)
            [(ExprVar capability)
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
        (string-append
          (if core-only
            "stdlib.vector.generated.core."
            "stdlib.vector.generated.")
          (type-key T)))]
    ;; Construct the append/read/mutate core once, then splice that exact
    ;; declaration list into either capability mode.
    [core-decls : Expr
      `(begin
        (cfg
          feature-compiler-private-dynamic-buffer
          (defstruct Vec
            (slots (__tl_dyn-array ,T))
            (len i64)))
        (cfg
          (not feature-compiler-private-dynamic-buffer)
          (defstruct Vec
            (slots (Array ,T))
            (len i64)))
        (define (slots [v : (& v Vec)]) : (& v (Array ,T))
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
          [dst : (&mut dst (Array ,T))]
          [src : (& src (Array ,T))]
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
            [bigger : (Array ,T) (make-array ,T new-cap)]
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
    (match core-decls
      [(ExprBegin core)
        (if core-only
          `(begin
            (module ,module-name)
            ,@core)
          (let
            [vec-name : Expr (expr-var "Vec")]
            [pop-name : Expr (expr-var "Pop")]
            [pop-empty-name : Expr (expr-var "Pop.Empty")]
            [pop-ok-name : Expr (expr-var "Pop.Ok")]
            [iter-mut-name : Expr (expr-var "IterMut")]
            [iter-mut-next-name : Expr (expr-var "IterMutNext")]
            [iter-mut-done-name : Expr (expr-var "IterMutNext.Done")]
            [iter-mut-item-name : Expr (expr-var "IterMutNext.Item")]
            [kind : String (type-kind T)]
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
            [eq-body : Expr
              (match kind
                ["string"
                  `(cfg
                    feature-compiler-private-string-intrinsics
                    (__tl_string_eq a b)
                    (let
                      [n : i64 (string-length a)]
                      [i : i64 0]
                      [same : bool (= n (string-length b))]
                      (begin
                        (while (if same
                          (< i n)
                          false)
                          (begin
                            (if (= (string-ref a i) (string-ref b i))
                              unit
                              (set! same false))
                            (set! i (+ i 1))))
                        same)))]
                ["i64" `(= a b)]
                ["i32" `(= a b)]
                ["i16" `(= a b)]
                ["i8" `(= a b)]
                ["u64" `(= a b)]
                ["u32" `(= a b)]
                ["u16" `(= a b)]
                ["u8" `(= a b)]
                ["bool" `(= a b)]
                ["char" `(= a b)]
                ["f64" `(= a b)]
                ["f32" `(= a b)]
                [_ `false])]
            [contains-hit : Expr
              (match kind
                ["string"
                  `(cfg
                    feature-compiler-private-string-intrinsics
                    (__tl_string_eq (array-ref (slots v) index) (& x))
                    (let
                      [n : i64 (string-length (array-ref (slots v) index))]
                      [i : i64 0]
                      [same : bool (= n (string-length (& x)))]
                      (begin
                        (while (if same
                          (< i n)
                          false)
                          (begin
                            (if (=
                              (string-ref (array-ref (slots v) index) i)
                              (string-ref (& x) i))
                              unit
                              (set! same false))
                            (set! i (+ i 1))))
                        same)))]
                ["i64" `(value-eq? (array-ref (slots v) index) x)]
                ["i32" `(value-eq? (array-ref (slots v) index) x)]
                ["i16" `(value-eq? (array-ref (slots v) index) x)]
                ["i8" `(value-eq? (array-ref (slots v) index) x)]
                ["u64" `(value-eq? (array-ref (slots v) index) x)]
                ["u32" `(value-eq? (array-ref (slots v) index) x)]
                ["u16" `(value-eq? (array-ref (slots v) index) x)]
                ["u8" `(value-eq? (array-ref (slots v) index) x)]
                ["bool" `(value-eq? (array-ref (slots v) index) x)]
                ["char" `(value-eq? (array-ref (slots v) index) x)]
                ["f64" `(value-eq? (array-ref (slots v) index) x)]
                ["f32" `(value-eq? (array-ref (slots v) index) x)]
                [_ `false])]
            `(begin
              (module ,module-name)
              ,@core
              (defenum ,pop-name
                (Empty)
                (Ok ,T))
              ;; This state owns the vector's exclusive source borrow. `next-mut`
              ;; reborrows one element from that stored reference, so the item keeps
              ;; the vector lifetime rather than the short borrow of the state.
              (defstruct ,iter-mut-name
                (:lifetimes source)
                (slots (&mut source (Array ,T)))
                (len i64)
                (index i64))
              ;; Mutable iteration is lending: an Item keeps the source borrow live,
              ;; so callers must finish with it before asking for the next item.
              (defenum ,iter-mut-next-name
                (:lifetimes source)
                (Done)
                (Item (,iter-mut-borrow-name source ,iter-mut-item-type)))
              (define (slots-mut [v : (&mut v ,vec-name)]) : (&mut v (Array ,T))
                (&mut (struct-get v slots)))
              (define (len-mut [v : (&mut v ,vec-name)]) : i64
                (struct-get v len))
              (define (is-empty? [v : (& v ,vec-name)]) : bool
                (<= (len v) 0))
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
              (define (from-array [src : (& src (Array ,T))] [count : i64]) : ,vec-name
                (let
                  [n : i64
                    (if (< count 0)
                      0
                      count)]
                  [items : (Array ,T)
                    (make-array
                      ,T
                      (if (< n 1)
                        1
                        n))]
                  (begin
                    (copy-range! (&mut items) src 0 n)
                    (,vec-name items n))))
              (define (to-array [v : (& v ,vec-name)]) : (Array ,T)
                (let
                  [n : i64 (len v)]
                  [out : (Array ,T) (make-array ,T n)]
                  (begin
                    (copy-range! (&mut out) (slots v) 0 n)
                    out)))
              (define (extend-from
                [v : (&mut v ,vec-name)]
                [src : (& src (Array ,T))]
                [index : i64]
                [count : i64]) : unit
                (if (>= index count)
                  unit
                  (begin
                    (push v (array-ref src index))
                    (extend-from v src (+ index 1) count))))
              (define (extend
                [v : (&mut v ,vec-name)]
                [src : (& src (Array ,T))]
                [count : i64]) : unit
                (extend-from v src 0 count))
              (define (reverse-range!
                [items : (&mut items (Array ,T))]
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
              (define (value-eq? [a : ,T] [b : ,T]) : bool
                ,eq-body)
              (define (contains-from?
                [v : (& v ,vec-name)]
                [x : ,T]
                [index : i64]) : bool
                (if (>= index (len v))
                  false
                  (if ,contains-hit
                    true
                    (contains-from? v x (+ index 1)))))
              (define (contains? [v : (& v ,vec-name)] [x : ,T]) : bool
                (contains-from? v x 0)))))]
      [_ (comptime-error "vector: internal core declaration shape")])))

;: Emit a named growable vector family for element type `T`.
;:
;: `(family Point PointVec point-vec)` defines `PointVec` plus
;: `point-vec-new`, `point-vec-with-capacity`, `point-vec-push`,
;: `point-vec-len`, `point-vec-capacity`, `point-vec-get`,
;: `point-vec-set!`, and private copy/grow helpers. Reads take `&` and mutators
;: take `&mut`. Unlike `(vector T)`, this compatibility surface does not emit
;: `pop`, so it can store aggregate values that are not cloneable.
(defmacro (family [T : type] [vec-name : Expr] [prefix : Expr]) : Decls
  (match prefix
    [(ExprVar base)
      (match vec-name
        [(ExprVar _)
          (let
            [slots-name : Expr (expr-var (string-append base "-slots"))]
            [len-name : Expr (expr-var (string-append base "-len"))]
            [capacity-name : Expr (expr-var (string-append base "-capacity"))]
            [with-capacity-name : Expr
              (expr-var (string-append base "-with-capacity"))]
            [new-name : Expr (expr-var (string-append base "-new"))]
            [get-name : Expr (expr-var (string-append base "-get"))]
            [set-name : Expr (expr-var (string-append base "-set!"))]
            [copy-range-name : Expr
              (expr-var (string-append base "-copy-range"))]
            [grow-name : Expr (expr-var (string-append base "-grow"))]
            [push-name : Expr (expr-var (string-append base "-push"))]
            `(begin
              (defstruct ,vec-name
                (slots (Array ,T))
                (len i64))
              (define (,slots-name [v : (& v ,vec-name)]) : (& v (Array ,T))
                (& (struct-get v slots)))
              (define (,len-name [v : (& v ,vec-name)]) : i64
                (struct-get v len))
              (define (,capacity-name [v : (& v ,vec-name)]) : i64
                (array-length (,slots-name v)))
              (define (,with-capacity-name [capacity : i64]) : ,vec-name
                (let
                  [cap : i64
                    (if (< capacity 1)
                      1
                      capacity)]
                  (,vec-name (make-array ,T cap) 0)))
              (define (,new-name) : ,vec-name
                (,with-capacity-name 4))
              (define (,get-name
                [v : (& v ,vec-name)]
                [index : i64]
                [fallback : ,T]) : ,T
                (if (if (>= index 0)
                  (< index (,len-name v))
                  false)
                  (array-ref (,slots-name v) index)
                  fallback))
              (define (,set-name
                [v : (&mut v ,vec-name)]
                [index : i64]
                [value : ,T]) : unit
                (if (if (>= index 0)
                  (< index (struct-get v len))
                  false)
                  (array-set! (struct-get v slots) index value)
                  unit))
              (define (,copy-range-name
                [dst : (&mut dst (Array ,T))]
                [src : (& src (Array ,T))]
                [index : i64]
                [count : i64]) : unit
                (if (>= index count)
                  unit
                  (begin
                    (array-set! dst index (array-ref src index))
                    (,copy-range-name dst src (+ index 1) count))))
              (define (,grow-name [v : (&mut v ,vec-name)]) : unit
                (let
                  [n : i64 (struct-get v len)]
                  [old-cap : i64 (array-length (struct-get v slots))]
                  [new-cap : i64
                    (if (< old-cap 1)
                      1
                      (* old-cap 2))]
                  [bigger : (Array ,T) (make-array ,T new-cap)]
                  (begin
                    (,copy-range-name
                      (&mut bigger)
                      (& (struct-get v slots))
                      0
                      n)
                    (set! (struct-get v slots) bigger))))
              (define (,push-name [v : (&mut v ,vec-name)] [value : ,T]) : unit
                (begin
                  (if (< (struct-get v len) (array-length (struct-get v slots)))
                    unit
                    (,grow-name v))
                  (let
                    [index : i64 (struct-get v len)]
                    (begin
                      (array-set! (struct-get v slots) index value)
                      (set! (struct-get v len) (+ index 1))))))))]
        [_ `(begin)])]
    [_ `(begin)]))