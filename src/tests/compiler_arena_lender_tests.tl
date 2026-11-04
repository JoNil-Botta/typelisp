;; Arena lender lane (#9256 G1): typing counts the three committed lender
;; sites, the normalizer mints only in a body with a counted site, and each
;; lane use demands the lenders its value may hold. The R-predicate cases
;; are the p0 witnesses (#9503/#9508): G1 still accepts them, and G2 rejects
;; them from these rows.
(import compiler_typecheck_api as tc_api)
(import compiler_diagnostic as cdiag)
(import stdlib.io)
(import stdlib.string)
(cfg test (import compiler_typecheck_core as tc_core))
(cfg test (import compiler_ownership_normalize as norm))
(cfg test (import compiler_typed_occurrence as typed))
(cfg test (import compiler_typed_occurrence_tests as fixture))
(cfg test (import compiler_intern as ci))
(cfg test (import stdlib.test))

;; Lender kinds (`OwnershipArenaLender.kind`).
(define lender-test-owner : i64
  0)
(define lender-test-scope : i64
  1)
(define lender-test-brand : i64
  2)

;; Typechecks `src` and returns the lanes its own bodies logged
;; (`normalize-lender-test-record!`), or an empty log when typing failed.
(define (lender-test-log [src : String]) : (__tl_dyn-array i64)
  (cfg test (norm.normalize-lender-test-take!))
  ;; G1 types the R-predicate witnesses without the #9612 invalidated-brand
  ;; ordering, which the public checker applies, so the lender assertions run
  ;; on them; #9256 G2 removes this.
  (cfg test (tc_core.tc-invalidated-brand-test-bypass-set! true))
  (let
    [typed : bool
      (match (tc_api.typecheck-compiler-source src)
        [(Ok _) true]
        [(Err _) false])]
    (cfg test (tc_core.tc-invalidated-brand-test-bypass-set! false))
    (unless typed (io.panic "arena lender test source failed to typecheck")))
  (let
    [all : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    (cfg test (set! all (norm.normalize-lender-test-take!)))
    all))

;; The lines of the uses that demand a `kind` lender, into `lines`; returns
;; the number of logged bodies.
(define (lender-test-uses
  [log : (& log (__tl_dyn-array i64))]
  [kind : i64]
  [lines : (&mut lines (__tl_dyn-array i64))]) : i64
  (let
    [at : i64 0]
    [bodies : i64 0]
    (while (< at (array-length log))
      (let
        [count : i64 (array-ref log (+ at 1))]
        [first : i64 (+ at 2)]
        [mask : i64 0]
        [index : i64 0]
        (while (< index count)
          (when
            (= (array-ref log (+ first index)) kind)
            (set! mask (bit-or mask (shl 1 index))))
          (set! index (+ index 1)))
        (set! bodies (+ bodies 1))
        (set! at (+ first count))
        (while (and (< at (array-length log)) (>= (array-ref log at) 0))
          (when
            (and
              (>= (array-ref log (+ at 1)) 0)
              (!= (bit-and (array-ref log (+ at 1)) mask) 0))
            (__tl_array-push! lines (array-ref log at)))
          (set! at (+ at 5)))))
    bodies))

;; The number of `kind` lenders minted.
(define (lender-test-minted [log : (& log (__tl_dyn-array i64))] [kind : i64]) : i64
  (let
    [at : i64 0]
    [minted : i64 0]
    (while (< at (array-length log))
      (let
        [count : i64 (array-ref log (+ at 1))]
        [index : i64 0]
        (while (< index count)
          (when
            (= (array-ref log (+ at 2 index)) kind)
            (set! minted (+ minted 1)))
          (set! index (+ index 1)))
        (set! at (+ at 2 count))
        (while (and (< at (array-length log)) (>= (array-ref log at) 0))
          (set! at (+ at 5)))))
    minted))

;; Whether a use on `line` demands a `kind` lender.
(define (lender-test-demands?
  [log : (& log (__tl_dyn-array i64))]
  [line : i64]
  [kind : i64]) : bool
  (let
    [lines : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [index : i64 0]
    (lender-test-uses log kind (&mut lines))
    (while (< index (array-length lines))
      (when (= (array-ref lines index) line) (return true))
      (set! index (+ index 1)))
    false))

;; Whether a use after `line` (a lender's end) demands a `kind` lender.
(define (lender-test-demands-after?
  [log : (& log (__tl_dyn-array i64))]
  [line : i64]
  [kind : i64]) : bool
  (let
    [lines : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [index : i64 0]
    (lender-test-uses log kind (&mut lines))
    (while (< index (array-length lines))
      (when (> (array-ref lines index) line) (return true))
      (set! index (+ index 1)))
    false))

(define (lender-test-bodies [log : (& log (__tl_dyn-array i64))]) : i64
  (let
    [lines : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    (lender-test-uses log lender-test-owner (&mut lines))))

;; The lenders demanded by the uses on `line` (lender `i` is bit `i`).
(define (lender-test-mask-at [log : (& log (__tl_dyn-array i64))] [line : i64]) : i64
  (let
    [at : i64 0]
    [mask : i64 0]
    (while (< at (array-length log))
      (set! at (+ at 2 (array-ref log (+ at 1))))
      (while (and (< at (array-length log)) (>= (array-ref log at) 0))
        (when
          (and (= (array-ref log at) line) (>= (array-ref log (+ at 1)) 0))
          (set! mask (bit-or mask (array-ref log (+ at 1)))))
        (set! at (+ at 5))))
    mask))

;; The log offset of the first body with a `kind` lender, or -1.
(define (lender-test-body [log : (& log (__tl_dyn-array i64))] [kind : i64]) : i64
  (let
    [at : i64 0]
    (while (< at (array-length log))
      (let
        [count : i64 (array-ref log (+ at 1))]
        [index : i64 0]
        (while (< index count)
          (when (= (array-ref log (+ at 2 index)) kind) (return at))
          (set! index (+ index 1)))
        (set! at (+ at 2 count))
        (while (and (< at (array-length log)) (>= (array-ref log at) 0))
          (set! at (+ at 5)))))
    -1))

;; The mask of body `body`'s `kind` lenders (lender `i` is bit `i`).
(define (lender-test-kind-mask
  [log : (& log (__tl_dyn-array i64))]
  [body : i64]
  [kind : i64]) : i64
  (let
    [mask : i64 0]
    [index : i64 0]
    (while (< index (array-ref log (+ body 1)))
      (when
        (= (array-ref log (+ body 2 index)) kind)
        (set! mask (bit-or mask (shl 1 index))))
      (set! index (+ index 1)))
    mask))

;; The offset of body `body`'s first use or end record.
(define (lender-test-records [log : (& log (__tl_dyn-array i64))] [body : i64]) : i64
  (+ body 2 (array-ref log (+ body 1))))

;; The index in block 0 of body `body`'s first Invalidate after instruction
;; `from` whose place holds a lender of `mask`, or -1.
(define (lender-test-end
  [log : (& log (__tl_dyn-array i64))]
  [body : i64]
  [mask : i64]
  [from : i64]) : i64
  (let
    [at : i64 (lender-test-records log body)]
    (while (and (< at (array-length log)) (>= (array-ref log at) 0))
      (when
        (and
          (< (array-ref log (+ at 1)) 0)
          (= (array-ref log (+ at 2)) 0)
          (> (array-ref log (+ at 3)) from)
          (!= (bit-and (- -2 (array-ref log (+ at 1))) mask) 0))
        (return (array-ref log (+ at 3))))
      (set! at (+ at 5)))
    -1))

;; The exact lenders demanded by body `body`'s uses before instruction `index`
;; of `block`, or -1 when no use is there.
(define (lender-test-demand-at
  [log : (& log (__tl_dyn-array i64))]
  [body : i64]
  [block : i64]
  [index : i64]) : i64
  (let
    [at : i64 (lender-test-records log body)]
    [mask : i64 -1]
    (while (and (< at (array-length log)) (>= (array-ref log at) 0))
      (when
        (and
          (>= (array-ref log (+ at 1)) 0)
          (= (array-ref log (+ at 2)) block)
          (= (array-ref log (+ at 3)) index))
        (set!
          mask
          (if (< mask 0)
            (array-ref log (+ at 1))
            (bit-or mask (array-ref log (+ at 1))))))
      (set! at (+ at 5)))
    mask))

;; The number of body `body`'s uses that demand a lender of `mask` in block 0
;; at an index in [`from`, `to`), or in any other block when `other?`.
(define (lender-test-demands-between
  [log : (& log (__tl_dyn-array i64))]
  [body : i64]
  [mask : i64]
  [from : i64]
  [to : i64]
  [other? : bool]) : i64
  (let
    [at : i64 (lender-test-records log body)]
    [count : i64 0]
    (while (and (< at (array-length log)) (>= (array-ref log at) 0))
      (when
        (and
          (>= (array-ref log (+ at 1)) 0)
          (!= (bit-and (array-ref log (+ at 1)) mask) 0)
          (if (= (array-ref log (+ at 2)) 0)
            (and
              (>= (array-ref log (+ at 3)) from)
              (< (array-ref log (+ at 3)) to))
            other?))
        (set! count (+ count 1)))
      (set! at (+ at 5)))
    count))

;; The place root of body `body`'s Invalidate at block-0 index `index`, or -1.
(define (lender-test-end-place
  [log : (& log (__tl_dyn-array i64))]
  [body : i64]
  [index : i64]) : i64
  (let
    [at : i64 (lender-test-records log body)]
    (while (and (< at (array-length log)) (>= (array-ref log at) 0))
      (when
        (and
          (< (array-ref log (+ at 1)) 0)
          (= (array-ref log (+ at 2)) 0)
          (= (array-ref log (+ at 3)) index))
        (return (array-ref log (+ at 4))))
      (set! at (+ at 5)))
    -1))

;; The number of body `body`'s uses of place root `place` on `line` that
;; demand exactly `mask` in block 0 before instruction `end`.
(define (lender-test-place-uses
  [log : (& log (__tl_dyn-array i64))]
  [body : i64]
  [place : i64]
  [line : i64]
  [mask : i64]
  [end : i64]) : i64
  (let
    [at : i64 (lender-test-records log body)]
    [count : i64 0]
    (while (and (< at (array-length log)) (>= (array-ref log at) 0))
      (when
        (and
          (= (array-ref log at) line)
          (= (array-ref log (+ at 1)) mask)
          (= (array-ref log (+ at 2)) 0)
          (< (array-ref log (+ at 3)) end)
          (= (array-ref log (+ at 4)) place))
        (set! count (+ count 1)))
      (set! at (+ at 5)))
    count))

;; The block-0 index of body `body`'s first use on `line` that demands exactly
;; `mask`, or -1.
(define (lender-test-use-index
  [log : (& log (__tl_dyn-array i64))]
  [body : i64]
  [line : i64]
  [mask : i64]) : i64
  (let
    [at : i64 (lender-test-records log body)]
    (while (and (< at (array-length log)) (>= (array-ref log at) 0))
      (when
        (and
          (= (array-ref log at) line)
          (= (array-ref log (+ at 1)) mask)
          (= (array-ref log (+ at 2)) 0))
        (return (array-ref log (+ at 3))))
      (set! at (+ at 5)))
    -1))

;; Whether typing `src` fails with `want`.
(define (lender-test-error? [src : String] [want : String]) : bool
  (match (tc_api.typecheck-compiler-source src)
    [(Err diag)
      (let
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first (deref diag))]
        (string.eq (cdiag.compiler-diagnostic-message (& first)) want))]
    [(Ok _) false]))

;; With the #9612 ordering on, as the public checker runs it: whether `src` is
;; rejected first with E0210 at `line`:`col`.
(define (lender-test-public-e0210-at? [src : String] [line : i64] [col : i64]) : bool
  (match (tc_api.typecheck-compiler-source src)
    [(Err diag)
      (let
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first (deref diag))]
        (and
          (match (cdiag.compiler-diagnostic-code (& first))
            [(cdiag.CompilerDiagnosticSomeString code) (string.eq code "E0210")]
            [_ false])
          (= (cdiag.compiler-diagnostic-line (& first)) line)
          (= (cdiag.compiler-diagnostic-col (& first)) col)))]
    [(Ok _) false]))

;; Whether the public checker accepts `src`.
(define (lender-test-public-accepts? [src : String]) : bool
  (match (tc_api.typecheck-compiler-source src)
    [(Ok _) true]
    [(Err _) false]))

;; x1: a brand reference passes through a named call; its alias is read after `destroy-safe!` ends the brand.
(define (lender-test-x1-source) : String
  "(import stdlib.arena)
(import stdlib.string)
(define (id [p : (& a i64)]) : (& a i64)
  p)
(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)]) : i64
  (let
    [k : i64 5]
    (let [alias : (& k i64) (id x)]
      (begin
        (arena.destroy-safe! owner)
        (let [fresh : arena.Arena (arena.make)]
          [junk : (Box i64) (in-arena fresh (box 1000))]
          (deref alias))))))
(define (main) : i64
  (let [seed : i64 41] [owner (arena.make)]
    [b (in-arena owner (box seed))]
    (exercise owner (& (deref b)))))")

;; x2: a direct shortened alias, read after the end.
(define (lender-test-x2-source) : String
  "(import stdlib.arena)
(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)]) : i64
  (let
    [k : i64 5]
    (let [alias : (& k i64) x]
      (begin
        (arena.destroy-safe! owner)
        (let [fresh : arena.Arena (arena.make)]
          [junk : (Box i64) (in-arena fresh (box 1000))]
          (deref alias))))))
(define (main) : i64 0)")

;; x4n: a mutable shortened alias, read after the end.
(define (lender-test-x4n-source) : String
  "(import stdlib.arena)
(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (&mut r i64)]) : i64
  (let
    [k : i64 5]
    (let [alias : (&mut k i64) x]
      (begin
        (arena.destroy-safe! owner)
        (deref alias)))))
(define (main) : i64 0)")

;; x6n: a join of the brand reference, read after the end.
(define (lender-test-x6n-source) : String
  "(import stdlib.arena)
(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)] [c : bool]) : i64
  (let
    [k : i64 5]
    (let [alias : (& k i64) (if c x x)]
      (begin
        (arena.destroy-safe! owner)
        (deref alias)))))
(define (main) : i64 0)")

;; p1: a callable result, read after the end.
(define (lender-test-p1-source) : String
  "(import stdlib.arena)
(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)] [f : (-> (& a i64) (& a i64))]) : i64
  (let
    [k : i64 5]
    [alias : (& k i64) (f x)]
    (begin
      (arena.destroy-safe! owner)
      (deref alias))))
(define (main) : i64 0)")

;; f1: a tuple projection of an arena value, read after the end.
(define (lender-test-f1-source) : String
  "(import stdlib.arena)
(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (in r (Tuple (& r i64) i64))]) : i64
  (let
    [k : i64 5]
    [alias : (& k i64) (tuple-ref x 0)]
    (begin
      (arena.destroy-safe! owner)
      (deref alias))))
(define (main) : i64 0)")

;; f2: a field projection, read after the end.
(define (lender-test-f2-source) : String
  "(import stdlib.arena)
(defstruct View
  (:lifetimes a)
  (p (& a i64)))
(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (in r (View r))]) : i64
  (let
    [k : i64 5]
    [alias : (& k i64) x.p]
    (begin
      (arena.destroy-safe! owner)
      (deref alias))))
(define (main) : i64 0)")

;; f4: a dereferenced arena reference, read after the end.
(define (lender-test-f4-source) : String
  "(import stdlib.arena)
(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (in r (& r (& r i64)))]) : i64
  (let
    [k : i64 5]
    [alias : (& k i64) (deref x)]
    (begin
      (arena.destroy-safe! owner)
      (deref alias))))
(define (main) : i64 0)")

;; f5: a constructed view, read after the end.
(define (lender-test-f5-source) : String
  "(import stdlib.arena)
(defstruct Cell
  (:lifetimes a)
  (p (& a i64)))
(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (in r (& r i64))]) : i64
  (let
    [k : i64 5]
    [c : (Cell k) (Cell x)]
    (begin
      (arena.destroy-safe! owner)
      (deref c.p))))
(define (main) : i64 0)")

;; p3: safe: the callable result is read before the end.
(define (lender-test-p3-source) : String
  "(import stdlib.arena)
(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)] [f : (-> (& a i64) (& a i64))]) : i64
  (let
    [k : i64 5]
    [alias : (& k i64) (f x)]
    [v : i64 (deref alias)]
    (begin
      (arena.destroy-safe! owner)
      v)))
(define (main) : i64 0)")

;; b2s: safe: only a phantom position names the ended brand.
(define (lender-test-b2s-source) : String
  "(import stdlib.arena)
(defstruct Phantom (:lifetimes p) (n i64))
(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (& a (Phantom r))]) : i64
  (let
    [k : i64 0]
    [alias : (& k (Phantom k)) x]
    (arena.destroy-safe! owner)
    (deref alias).n))
(define (main) : i64 0)")

;; b2m: safe: `first` names only a phantom position and ends first; `second`
;; ends after the read.
(define (lender-test-b2m-source) : String
  "(import stdlib.arena)
(defstruct View
  (:lifetimes phantom stored)
  (p (& stored i64)))
(define (exercise
  [first : (arena.Arena r) (:invalidate r)]
  [second : (arena.Arena s) (:invalidate s)]
  [x : (& a (View r s))]) : i64
  (let
    [k : i64 0]
    [alias : (& k (View k s)) x]
    (arena.destroy-safe! first)
    (deref alias).p
    (arena.destroy-safe! second)
    0))
(define (main) : i64 0)")

;; n1: safe: every alias is read before the end.
(define (lender-test-n1-source) : String
  "(import stdlib.arena)
(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)] [c : bool]) : i64
  (let
    [k : i64 5]
    [a1 : (& k i64) x]
    [a2 : (& k i64) (if c x (& k))]
    [a3 : (& k i64) (match c [true x] [false x])]
    [v : i64 (+ (deref a1) (+ (deref a2) (deref a3)))]
    (arena.destroy-safe! owner)
    v))
(define (main) : i64 0)")

;; scope: the three scoped forms: with-arena, with-scratch and with-escape, whose body may also exit through `return`.
(define (lender-test-scope-source) : String
  "(import stdlib.arena)
(define (scoped) : i64
  (with-arena r
    (let [b : (Box i64) (box 41)]
      (deref b))))
(define (scratch) : i64
  (with-scratch
    (let [b : (Box i64) (box 41)]
      (deref b))))
(define (escape [home : arena.Arena] [stop : bool]) : i64
  (with-escape home
    (let [b : (Box i64) (box 41)]
      (if stop (return 0) (deref b)))))
(define (main) : i64 0)")

;; nested: nested scopes mint two scope lenders. (A nested arena may not reuse
;; the outer one's name; SPEC 5.16.)
(define (lender-test-nested-source) : String
  "(define (main) : i64
  (with-arena r
    (let [outer : (Box i64) (box 1)]
      (with-arena q
        (let [inner : (Box i64) (box 41)]
          (+ (deref inner) (deref outer)))))))")

;; owner: an owner moved to another binding (bare-owner transport).
(define (lender-test-owner-source) : String
  "(import stdlib.arena)
(define (main) : i64
  (let [owner : arena.Arena (arena.make)]
    [moved : arena.Arena owner]
    [b : (Box i64) (in-arena moved (box 41))]
    (deref b)))")

;; k9: a lambda defined outside `in-arena` and called inside it (K9).
(define (lender-test-k9-source) : String
  "(import stdlib.arena)
(define (main) : i64
  (let [owner : arena.Arena (arena.make)]
    [mk : (-> i64 (Box i64)) (lambda ([n : i64]) : (Box i64) (box n))]
    [b : (Box i64) (in-arena owner (mk 41))]
    (deref b)))")

;; lambda: a lambda store: the lambda body inside the scope mints nothing of its own.
(define (lender-test-lambda-source) : String
  "(define (main) : i64
  (with-arena r
    (let [f : (-> i64 i64) (lambda ([n : i64]) : i64 (+ n 1))]
      (f 41))))")

;; lambda2: a lambda whose own body has a scoped arena mints in its own store.
(define (lender-test-lambda2-source) : String
  "(define (main) : i64
  (let [f : (-> i64 i64)
    (lambda ([n : i64]) : i64
      (with-arena r (let [b : (Box i64) (box n)] (deref b))))]
    (f 41)))")

;; plain: zero-lender control: no lender site, so no lane.
(define (lender-test-plain-source) : String
  "(define (main) : i64
  (let [b : (Box i64) (box 41)] [r : (& b i64) (& (deref b))]
    (deref r)))")

;; The three lender kinds are minted where typing published a site, and a
;; body without one has no lane (zero-lender control).
(cfg
  test
  (test
    arena-lender-mint-kinds
    (let
      [x1 : (__tl_dyn-array i64) (lender-test-log (lender-test-x1-source))]
      [scope : (__tl_dyn-array i64)
        (lender-test-log (lender-test-scope-source))]
      [plain : (__tl_dyn-array i64)
        (lender-test-log (lender-test-plain-source))]
      (test.assert-i64-eq
        (lender-test-minted (& x1) lender-test-brand)
        1
        "brand")
      (test.assert-i64-eq
        (lender-test-minted (& x1) lender-test-owner)
        2
        "owners")
      (test.assert-i64-eq
        (lender-test-minted (& scope) lender-test-scope)
        3
        "with-arena, with-scratch and with-escape scopes")
      (test.assert-i64-eq (array-length plain) 0 "no lane without a site"))))

;; D-C62: "For every R-predicate class, assert that the ended lender reaches
;; the specified unsafe post-end use. For safe controls, assert the expected
;; lender sets and use locations, with no demand on an ended lender after its
;; end."
(cfg
  test
  (test
    arena-lender-r-predicate
    (begin
      (test.assert-true
        (lender-test-demands?
          (& (lender-test-log (lender-test-x1-source)))
          13
          lender-test-brand)
        "x1 named call")
      (test.assert-true
        (lender-test-demands?
          (& (lender-test-log (lender-test-x2-source)))
          10
          lender-test-brand)
        "x2 direct")
      (test.assert-true
        (lender-test-demands?
          (& (lender-test-log (lender-test-x4n-source)))
          8
          lender-test-brand)
        "x4n mutable")
      (test.assert-true
        (lender-test-demands?
          (& (lender-test-log (lender-test-x6n-source)))
          8
          lender-test-brand)
        "x6n join")
      (test.assert-true
        (lender-test-demands?
          (& (lender-test-log (lender-test-p1-source)))
          8
          lender-test-brand)
        "p1 callable result")
      (test.assert-true
        (lender-test-demands?
          (& (lender-test-log (lender-test-f1-source)))
          10
          lender-test-brand)
        "f1 tuple projection")
      (test.assert-true
        (lender-test-demands?
          (& (lender-test-log (lender-test-f2-source)))
          11
          lender-test-brand)
        "f2 field projection")
      (test.assert-true
        (lender-test-demands?
          (& (lender-test-log (lender-test-f4-source)))
          8
          lender-test-brand)
        "f4 deref")
      (test.assert-true
        (lender-test-demands?
          (& (lender-test-log (lender-test-f5-source)))
          11
          lender-test-brand)
        "f5 constructor")
      ;; An interior scalar borrow of an arena value, `(& (deref b))`.
      (test.assert-true
        (lender-test-demands?
          (& (lender-test-log (lender-test-x1-source)))
          17
          lender-test-owner)
        "interior scalar borrow"))))

(cfg
  test
  (test
    arena-lender-safe-controls
    (let
      [p3 : (__tl_dyn-array i64) (lender-test-log (lender-test-p3-source))]
      [b2s : (__tl_dyn-array i64) (lender-test-log (lender-test-b2s-source))]
      [b2m : (__tl_dyn-array i64) (lender-test-log (lender-test-b2m-source))]
      [n1 : (__tl_dyn-array i64) (lender-test-log (lender-test-n1-source))]
      (test.assert-true
        (lender-test-demands? (& p3) 6 lender-test-brand)
        "p3 reads the brand before its end")
      (test.assert-false
        (lender-test-demands-after? (& p3) 8 lender-test-brand)
        "p3 no demand after the end")
      (test.assert-i64-eq
        (lender-test-mask-at (& b2s) 10)
        0
        "b2s phantom brand not demanded")
      (test.assert-false
        (lender-test-demands-after? (& b2s) 9 lender-test-brand)
        "b2s no demand after the end")
      ;; Lender 0 is `first`, lender 1 `second`.
      (test.assert-i64-eq
        (lender-test-mask-at (& b2m) 13)
        2
        "b2m reads only the live brand")
      (test.assert-false
        (lender-test-demands-after? (& b2m) 14 lender-test-brand)
        "b2m no demand after the last end")
      (test.assert-true
        (lender-test-demands? (& n1) 8 lender-test-brand)
        "n1 reads before the end")
      (test.assert-false
        (lender-test-demands-after? (& n1) 9 lender-test-brand)
        "n1 no demand after the end"))))

;; Each scoped form's body demands its scope; nested scopes are two lenders,
;; each demanded by its own allocation.
(cfg
  test
  (test
    arena-lender-scopes
    (let
      [scope : (__tl_dyn-array i64)
        (lender-test-log (lender-test-scope-source))]
      [nested : (__tl_dyn-array i64)
        (lender-test-log (lender-test-nested-source))]
      (test.assert-true
        (lender-test-demands? (& scope) 5 lender-test-scope)
        "with-arena body")
      (test.assert-true
        (lender-test-demands? (& scope) 9 lender-test-scope)
        "with-scratch body")
      (test.assert-true
        (lender-test-demands? (& scope) 13 lender-test-scope)
        "with-escape body with a diverging exit")
      (test.assert-i64-eq
        (lender-test-minted (& nested) lender-test-scope)
        2
        "nested scopes")
      (test.assert-i64-eq
        (lender-test-mask-at (& nested) 6)
        3
        "both scopes read"))))

(cfg
  test
  (test
    arena-lender-owner-transport
    (begin
      (test.assert-true
        (lender-test-demands?
          (& (lender-test-log (lender-test-owner-source)))
          5
          lender-test-owner)
        "a moved bare owner keeps its lender")
      (test.assert-true
        (lender-test-demands?
          (& (lender-test-log (lender-test-k9-source)))
          6
          lender-test-owner)
        "K9: a call result inside `in-arena`"))))

;; A lambda has its own store: copied regions mint nothing, its own scope does.
(cfg
  test
  (test
    arena-lender-lambda-stores
    (let
      [outer : (__tl_dyn-array i64)
        (lender-test-log (lender-test-lambda-source))]
      [inner : (__tl_dyn-array i64)
        (lender-test-log (lender-test-lambda2-source))]
      (test.assert-i64-eq
        (lender-test-bodies (& outer))
        1
        "only the scope's body")
      ;; Each lane logged is the lambda body's (typing may normalize it more
      ;; than once), with its one scope; `main` has none.
      (test.assert-i64-eq
        (lender-test-minted (& inner) lender-test-scope)
        (lender-test-bodies (& inner))
        "the lambda's own scope")
      (test.assert-i64-eq (lender-test-mask-at (& inner) 4) 1 "the lambda body")
      (test.assert-i64-eq (lender-test-mask-at (& inner) 5) 0 "not `main`"))))

;; The normalizer's test-build assertion: a mint without a counted site fails.
(cfg
  test
  (test
    arena-lender-mint-implies-site
    (begin
      (tc_core.tc-lender-test-drop-sites! true)
      (let
        [failed : bool
          (lender-test-error?
            (lender-test-scope-source)
            "typecheck: ownership normalization: an arena lender without a lender site")]
        [plain : bool
          (match (tc_api.typecheck-compiler-source (lender-test-plain-source))
            [(Ok _) true]
            [(Err _) false])]
        (tc_core.tc-lender-test-drop-sites! false)
        (test.assert-true failed "a dropped site is caught")
        (test.assert-true plain "no mint, no failure")))))

;; `lender-sites` starts at zero and survives a rolled-back attempt.
(cfg
  test
  (test
    arena-lender-store-rollback
    (let
      [intern : ci.InternCompatState (ci.intern-compat-state-capture-active)]
      [lease : (typed.TypedBodyLease intern)
        (fixture.typed-test-lease (& intern) (cast 4500 : u64))]
      [store : typed.TypedStore (fixture.typed-test-store (& lease))]
      [fresh : i64 store.lender-sites]
      [attempt : typed.TypedAttemptId
        (fixture.typed-test-attempt!
          (&mut store)
          (& lease)
          typed.TypedMode.Executable)]
      (set! store.lender-sites (+ store.lender-sites 1))
      (fixture.typed-test-finish! (&mut store) (& lease) attempt false)
      (test.assert-i64-eq fresh 0 "a fresh store has no site")
      (test.assert-i64-eq store.lender-sites 1 "rollback keeps the site"))))

;; e1: safe, straight-line: the brand reference is read before the end; a
;; reference parameter's entry loan pairs with no body Assign.
(define (lender-test-e1-source) : String
  "(import stdlib.arena)
(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)]) : i64
  (let
    [k : i64 5]
    [v : i64 (+ k (deref x))]
    (arena.destroy-safe! owner)
    v))
(define (main) : i64 0)")

;; mb: two brands; the live one is read after the other ends, the ended one
;; after its own end.
(define (lender-test-mb-source) : String
  "(import stdlib.arena)
(define (exercise
  [first : (arena.Arena r) (:invalidate r)]
  [second : (arena.Arena s) (:invalidate s)]
  [x : (& r i64)]
  [y : (& s i64)]) : i64
  (let
    [k : i64 0]
    [ax : (& k i64) x]
    [ay : (& k i64) y]
    (arena.destroy-safe! first)
    (let
      [v : i64 (deref ay)]
      [w : i64 (deref ax)]
      (arena.destroy-safe! second)
      (+ v w))))
(define (main) : i64 0)")

;; ob: an aggregate owner of two brands (owner_secondary_brand).
(define (lender-test-ob-source) : String
  "(import stdlib.arena)
(defstruct Owner
  (:lifetimes a b)
  (arena (arena.Arena a))
  (p (& b i64)))
(define (exercise
  [o : (Owner r s) (:invalidate r)]
  [other : (arena.Arena s) (:invalidate s)]) : i64
  (let
    [k : i64 0]
    [moved : (Owner r k) o]
    (arena.destroy-safe! other)
    (let
      [n : i64 (deref moved.p)]
      (arena.destroy-safe! moved.arena)
      n)))
(define (main) : i64 0)")

;; oc: an owner-arena box borrowed into a call that invalidates the owner.
(define (lender-test-oc-source) : String
  "(import stdlib.arena)
(define (take [owner : (arena.Arena r) (:invalidate r)] [x : (&mut r i64)]) : i64
  (let [v : i64 (deref x)] (arena.destroy-safe! owner) v))
(define (main) : i64
  (let [seed : i64 41] [owner (arena.make)]
    [b (in-arena owner (box seed))]
    (take owner (&mut (deref b)))))")

;; kd: a match result whose type holds no lender, defined in each arm from a
;; value that holds the scratch scope, is used at the scope's exit. The first
;; keep-filter draft split only places whose own unsplit row held a lender,
;; so it left this one unsplit and dropped the demand (the definition-value
;; test keeps it; build_cli_core.tl and four other self-compile bodies).
(define (lender-test-kd-source) : String
  "(import stdlib.arena)
(import stdlib.string)
(defenum Outcome (Fail String) (Done String))
(define (mk [n : i64]) : Outcome
  (if (> n 0) (Outcome.Done (string.int->string n)) (Outcome.Fail (string.int->string n))))
(define (pick [n : i64]) : Outcome
  (let [home : arena.Arena (arena.current)]
    (with-scratch
      (match (mk n)
        [(Outcome.Fail message) (in-arena home (Outcome.Fail (string.copy message)))]
        [(Outcome.Done text) (in-arena home (Outcome.Done (string.copy text)))]))))
(define (main) : i64 0)")

;; A reference parameter's entry loan pairs with no body Assign, so the entry
;; makes no use of its referent; the read before the end demands the brand,
;; and nothing demands it after the end (instruction order, block 0).
(cfg
  test
  (test
    arena-lender-parameter-entry-loan
    (let
      [log : (__tl_dyn-array i64) (lender-test-log (lender-test-e1-source))]
      [body : i64 (lender-test-body (& log) lender-test-brand)]
      [brand : i64 (lender-test-kind-mask (& log) body lender-test-brand)]
      [end : i64 (lender-test-end (& log) body brand -1)]
      [read : i64 (lender-test-use-index (& log) body 5 brand)]
      (test.assert-i64-eq
        (lender-test-demands-between (& log) body brand 0 3 false)
        0
        "no entry use of the referent")
      (test.assert-true (> end 0) "destroy-safe! ends the brand")
      (test.assert-true (and (>= read 0) (< read end)) "read before the end")
      (test.assert-i64-eq
        (lender-test-demands-between (& log) body brand (+ end 1) 65536 true)
        0
        "no demand after the end"))))

;; Two brands: after `first` (lender 0) ends, the read of the live brand
;; demands exactly `second` (lender 1), and the shortened `first` alias
;; demands exactly `first`; nothing demands `second` after its own end.
(cfg
  test
  (test
    arena-lender-two-brands
    (let
      [log : (__tl_dyn-array i64) (lender-test-log (lender-test-mb-source))]
      [body : i64 (lender-test-body (& log) lender-test-brand)]
      [first : i64 (lender-test-end (& log) body 1 -1)]
      [second : i64 (lender-test-end (& log) body 2 -1)]
      [live : i64 (lender-test-use-index (& log) body 13 2)]
      [ended : i64 (lender-test-use-index (& log) body 14 1)]
      (test.assert-true (and (> first 0) (> second first)) "end order")
      (test.assert-true
        (and (> live first) (< live second))
        "the live brand alone, between the ends")
      (test.assert-true (> ended first) "the ended brand at its post-end use")
      (test.assert-i64-eq
        (lender-test-demands-between (& log) body 2 (+ second 1) 65536 true)
        0
        "nothing demands the second brand after its end"))))

;; An owner aggregate of two brands (lender 0 `r`, lender 1 `s`), shortened
;; in `s`: the field read after `other` ends `s` demands exactly both.
(cfg
  test
  (test
    arena-lender-owner-aggregate
    (let
      [log : (__tl_dyn-array i64) (lender-test-log (lender-test-ob-source))]
      [body : i64 (lender-test-body (& log) lender-test-brand)]
      [s : i64 (lender-test-end (& log) body 2 -1)]
      [read : i64 (lender-test-use-index (& log) body 14 3)]
      [r : i64 (lender-test-end (& log) body 1 read)]
      (test.assert-true (and (> s 0) (> read s)) "both brands after `s` ends")
      (test.assert-true (> r read) "`r` ends after the read")
      (test.assert-i64-eq
        (lender-test-demands-between (& log) body 3 (+ r 1) 65536 true)
        0
        "nothing demands either brand after the last end"))))

;; An owner-arena box borrowed into a call that invalidates the owner: the
;; call invalidates the owner, then the box. The borrow `(&mut (deref b))`
;; uses the box itself, demanding exactly the owner lender, before the
;; first of those ends (the box's own place, not another use on its line).
(cfg
  test
  (test
    arena-lender-owner-borrow-call
    (let
      [log : (__tl_dyn-array i64) (lender-test-log (lender-test-oc-source))]
      [body : i64 (lender-test-body (& log) lender-test-owner)]
      [owner : i64 (lender-test-kind-mask (& log) body lender-test-owner)]
      [end : i64 (lender-test-end (& log) body owner -1)]
      [box-end : i64 (lender-test-end (& log) body owner end)]
      [box : i64 (lender-test-end-place (& log) body box-end)]
      (test.assert-true (> end 0) "the call ends the owner")
      (test.assert-true (and (> box-end end) (>= box 0)) "then the box")
      (test.assert-i64-eq
        (lender-test-place-uses (& log) body box 7 owner end)
        1
        "the borrow uses the box, demanding exactly the owner, first")
      (test.assert-i64-eq
        (lender-test-demands-between (& log) body owner (+ end 1) 65536 true)
        0
        "no demand after the end"))))

;; The match result's use at the scratch scope's exit (block 1, its join's
;; first instruction) demands exactly the scope.
(cfg
  test
  (test
    arena-lender-definition-value
    (let
      [log : (__tl_dyn-array i64) (lender-test-log (lender-test-kd-source))]
      [body : i64 (lender-test-body (& log) lender-test-scope)]
      (test.assert-i64-eq
        (lender-test-demand-at (& log) body 1 0)
        (lender-test-kind-mask (& log) body lender-test-scope)
        "the scope's exit use"))))

;; #9612 interim (D-C124): the public checker shortens no invalidated brand to
;; a body-local lifetime. Each unsafe R-predicate row is rejected with a
;; located E0210. p3 and n1 are sound and are temporary restrictions that
;; #9256 G2 restores; b2s and b2m, which name the brand only in a phantom
;; position, stay accepted.
(cfg
  test
  (test
    arena-lender-public-interim-rule
    (begin
      (test.assert-true
        (lender-test-public-e0210-at? (lender-test-x1-source) 8 29)
        "x1")
      (test.assert-true
        (lender-test-public-e0210-at? (lender-test-x2-source) 5 29)
        "x2")
      (test.assert-true
        (lender-test-public-e0210-at? (lender-test-x4n-source) 5 32)
        "x4n")
      (test.assert-true
        (lender-test-public-e0210-at? (lender-test-x6n-source) 5 29)
        "x6n")
      (test.assert-true
        (lender-test-public-e0210-at? (lender-test-p1-source) 5 24)
        "p1")
      (test.assert-true
        (lender-test-public-e0210-at? (lender-test-f1-source) 7 24)
        "f1")
      (test.assert-true
        (lender-test-public-e0210-at? (lender-test-f2-source) 8 24)
        "f2")
      (test.assert-true
        (lender-test-public-e0210-at? (lender-test-f4-source) 5 24)
        "f4")
      (test.assert-true
        (lender-test-public-e0210-at? (lender-test-f5-source) 8 19)
        "f5")
      (test.assert-true
        (lender-test-public-e0210-at? (lender-test-mb-source) 9 21)
        "mb")
      (test.assert-true
        (lender-test-public-e0210-at? (lender-test-ob-source) 11 26)
        "ob")
      ;; Temporary restrictions (sound; restored by #9256 G2).
      (test.assert-true
        (lender-test-public-e0210-at? (lender-test-p3-source) 5 24)
        "p3 (temporary restriction)")
      (test.assert-true
        (lender-test-public-e0210-at? (lender-test-n1-source) 5 21)
        "n1 (temporary restriction)")
      (test.assert-true
        (lender-test-public-accepts? (lender-test-b2s-source))
        "b2s")
      (test.assert-true
        (lender-test-public-accepts? (lender-test-b2m-source))
        "b2m"))))