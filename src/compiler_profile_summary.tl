;; compiler_profile_summary.tl - bounded deterministic compile-profile reports.
(import stdlib.hash)
(import stdlib.io)
(import stdlib.string)
(import stdlib.test)

(define compiler-profile-summary-top-count : i64
  8)
(define compiler-profile-summary-scope-count : i64
  5)
(define compiler-profile-summary-optimizer-pass : i64
  0)
(define compiler-profile-summary-optimizer-function : i64
  1)
(define compiler-profile-summary-optimizer-module : i64
  2)
(define compiler-profile-summary-backend-function : i64
  3)
(define compiler-profile-summary-backend-module : i64
  4)
(define compiler-profile-summary-pass-capacity : i64
  128)
(define compiler-profile-summary-module-capacity : i64
  2048)
(define compiler-profile-summary-pass-table-capacity : i64
  256)
(define compiler-profile-summary-module-table-capacity : i64
  4096)
(define compiler-profile-summary-exact-table-capacity : i64
  8448)

;; Inline fixed arrays live in static global storage. This deliberately avoids
;; arena-owned hash tables and large aggregate-by-value calls in profile hooks.
(define compiler-profile-summary-keys : (Array i64 40)
  (array
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0))
(define compiler-profile-summary-names : (Array String 40)
  (array
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""))
(define compiler-profile-summary-elapsed : (Array i64 40)
  (array
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0))
(define compiler-profile-summary-calls : (Array i64 40)
  (array
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0))
(define compiler-profile-summary-counts : (Array i64 5)
  (array 0 0 0 0 0))
(define compiler-profile-summary-total-elapsed : (Array i64 5)
  (array 0 0 0 0 0))
(define compiler-profile-summary-total-calls : (Array i64 5)
  (array 0 0 0 0 0))

;; Pass and module names recur across many hooks. Retain their full aggregates
;; here, then select the bounded top rows only when the report is emitted. Keep
;; the large tables as runtime-sized arrays: lowering `(init)` for a fixed array
;; expands one initializer expression per element, which made this module's test
;; harness consume more than 5 GiB while compiling only a few thousand slots.
;; `make-array` emits the existing bounded runtime initialization loop instead.
(define compiler-profile-summary-exact-slots : (Array i64)
  (make-array i64 8448))
(define compiler-profile-summary-exact-counts : (Array i64 3)
  (array 0 0 0))
(define compiler-profile-summary-exact-names : (Array String)
  (make-array String 4224))
(define compiler-profile-summary-exact-keys : (Array i64)
  (make-array i64 4224))
(define compiler-profile-summary-exact-elapsed : (Array i64)
  (make-array i64 4224))
(define compiler-profile-summary-exact-calls : (Array i64)
  (make-array i64 4224))
(define compiler-profile-summary-exact-top : (Array i64 24)
  (init))

(define (compiler-profile-summary-exact-scope? [scope : i64]) : bool
  (or
    (= scope compiler-profile-summary-optimizer-pass)
    (= scope compiler-profile-summary-optimizer-module)
    (= scope compiler-profile-summary-backend-module)))

(define (compiler-profile-summary-exact-scope-capacity [scope : i64]) : i64
  (if (= scope compiler-profile-summary-optimizer-pass)
    compiler-profile-summary-pass-capacity
    compiler-profile-summary-module-capacity))

(define (compiler-profile-summary-exact-offset [scope : i64] [index : i64]) : i64
  (+
    (if (= scope compiler-profile-summary-optimizer-pass)
      0
      (if (= scope compiler-profile-summary-optimizer-module)
        compiler-profile-summary-pass-capacity
        (+
          compiler-profile-summary-pass-capacity
          compiler-profile-summary-module-capacity)))
    index))

(define (compiler-profile-summary-record-at!
  [scope : i64]
  [index : i64]
  [elapsed : i64]
  [fresh : bool]) : unit
  (let
    [offset : i64 (compiler-profile-summary-exact-offset scope index)]
    (if fresh
      (begin
        (array-set! compiler-profile-summary-exact-elapsed offset elapsed)
        (array-set! compiler-profile-summary-exact-calls offset 1))
      (begin
        (array-set!
          compiler-profile-summary-exact-elapsed
          offset
          (+ (array-ref compiler-profile-summary-exact-elapsed offset) elapsed))
        (array-set!
          compiler-profile-summary-exact-calls
          offset
          (+ (array-ref compiler-profile-summary-exact-calls offset) 1))))))

(define (compiler-profile-summary-exact-scope-index [scope : i64]) : i64
  (if (= scope compiler-profile-summary-optimizer-pass)
    0
    (if (= scope compiler-profile-summary-optimizer-module)
      1
      2)))

(define (compiler-profile-summary-exact-table-scope-capacity [scope : i64]) : i64
  (if (= scope compiler-profile-summary-optimizer-pass)
    compiler-profile-summary-pass-table-capacity
    compiler-profile-summary-module-table-capacity))

(define (compiler-profile-summary-exact-table-offset [scope : i64]) : i64
  (if (= scope compiler-profile-summary-optimizer-pass)
    0
    (if (= scope compiler-profile-summary-optimizer-module)
      compiler-profile-summary-pass-table-capacity
      (+
        compiler-profile-summary-pass-table-capacity
        compiler-profile-summary-module-table-capacity))))

(define (compiler-profile-summary-note-exact!
  [scope : i64]
  [key : i64]
  [name : String]
  [elapsed : i64]) : unit
  (let
    [scope-index : i64 (compiler-profile-summary-exact-scope-index scope)]
    [table-capacity : i64
      (compiler-profile-summary-exact-table-scope-capacity scope)]
    [table-offset : i64 (compiler-profile-summary-exact-table-offset scope)]
    [dense-offset : i64 (compiler-profile-summary-exact-offset scope 0)]
    [slot : i64 (+ table-offset (% key table-capacity))]
    [probes : i64 0]
    [index : i64 -1]
    [fresh : bool false]
    (begin
      (while (and (< index 0) (< probes table-capacity))
        (let
          [marker : i64 (array-ref compiler-profile-summary-exact-slots slot)]
          (if (= marker 0)
            (begin
              (set!
                index
                (array-ref compiler-profile-summary-exact-counts scope-index))
              (if (>=
                index
                (compiler-profile-summary-exact-scope-capacity scope))
                (io.panic
                  "compile-profile summary exact scope capacity exceeded")
                unit)
              (array-set!
                compiler-profile-summary-exact-names
                (+ dense-offset index)
                name)
              (array-set!
                compiler-profile-summary-exact-keys
                (+ dense-offset index)
                key)
              (array-set! compiler-profile-summary-exact-slots slot (+ index 1))
              (array-set!
                compiler-profile-summary-exact-counts
                scope-index
                (+ index 1))
              (set! fresh true))
            (let
              [candidate : i64 (- marker 1)]
              (if (=
                (array-ref
                  compiler-profile-summary-exact-keys
                  (+ dense-offset candidate))
                key)
                (set! index candidate)
                (begin
                  (set!
                    slot
                    (+
                      table-offset
                      (% (+ (- slot table-offset) 1) table-capacity)))
                  (set! probes (+ probes 1))))))))
      (if (< index 0)
        (io.panic "compile-profile summary exact table is full")
        (compiler-profile-summary-record-at! scope index elapsed fresh)))))

(define (compiler-profile-summary-reset!) : unit
  (let
    [scope : i64 0]
    [slot : i64 0]
    (begin
      (while (< scope compiler-profile-summary-scope-count)
        (begin
          (array-set! compiler-profile-summary-counts scope 0)
          (array-set! compiler-profile-summary-total-elapsed scope 0)
          (array-set! compiler-profile-summary-total-calls scope 0)
          (set! scope (+ scope 1))))
      (while (< slot compiler-profile-summary-exact-table-capacity)
        (begin
          (array-set! compiler-profile-summary-exact-slots slot 0)
          (set! slot (+ slot 1))))
      (array-set! compiler-profile-summary-exact-counts 0 0)
      (array-set! compiler-profile-summary-exact-counts 1 0)
      (array-set! compiler-profile-summary-exact-counts 2 0))))

(define (compiler-profile-summary-offset [scope : i64] [rank : i64]) : i64
  (+ (* scope compiler-profile-summary-top-count) rank))

(define (compiler-profile-summary-better?
  [key : i64]
  [elapsed : i64]
  [other-key : i64]
  [other-elapsed : i64]) : bool
  (or
    (> elapsed other-elapsed)
    (and (= elapsed other-elapsed) (< key other-key))))

(define (compiler-profile-summary-find [scope : i64] [count : i64] [key : i64]) : i64
  (let
    [rank : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< rank count))
        (if (=
          (array-ref
            compiler-profile-summary-keys
            (compiler-profile-summary-offset scope rank))
          key)
          (set! found rank)
          (set! rank (+ rank 1))))
      found)))

(define (compiler-profile-summary-swap!
  [scope : i64]
  [left : i64]
  [right : i64]) : unit
  (let
    [li : i64 (compiler-profile-summary-offset scope left)]
    [ri : i64 (compiler-profile-summary-offset scope right)]
    [key : i64 (array-ref compiler-profile-summary-keys li)]
    [name : String (array-ref compiler-profile-summary-names li)]
    [elapsed : i64 (array-ref compiler-profile-summary-elapsed li)]
    [calls : i64 (array-ref compiler-profile-summary-calls li)]
    (begin
      (array-set!
        compiler-profile-summary-keys
        li
        (array-ref compiler-profile-summary-keys ri))
      (array-set!
        compiler-profile-summary-names
        li
        (array-ref compiler-profile-summary-names ri))
      (array-set!
        compiler-profile-summary-elapsed
        li
        (array-ref compiler-profile-summary-elapsed ri))
      (array-set!
        compiler-profile-summary-calls
        li
        (array-ref compiler-profile-summary-calls ri))
      (array-set! compiler-profile-summary-keys ri key)
      (array-set! compiler-profile-summary-names ri name)
      (array-set! compiler-profile-summary-elapsed ri elapsed)
      (array-set! compiler-profile-summary-calls ri calls))))

(define (compiler-profile-summary-bubble! [scope : i64] [rank : i64]) : unit
  (if (<= rank 0)
    unit
    (let
      [i : i64 (compiler-profile-summary-offset scope rank)]
      [p : i64 (compiler-profile-summary-offset scope (- rank 1))]
      (if (compiler-profile-summary-better?
        (array-ref compiler-profile-summary-keys i)
        (array-ref compiler-profile-summary-elapsed i)
        (array-ref compiler-profile-summary-keys p)
        (array-ref compiler-profile-summary-elapsed p))
        (begin
          (compiler-profile-summary-swap! scope rank (- rank 1))
          (compiler-profile-summary-bubble! scope (- rank 1)))
        unit))))

(define (compiler-profile-summary-consider!
  [scope : i64]
  [key : i64]
  [name : String]
  [elapsed : i64]
  [calls : i64]) : unit
  (let
    [count : i64 (array-ref compiler-profile-summary-counts scope)]
    [found : i64 (compiler-profile-summary-find scope count key)]
    (if (>= found 0)
      (let
        [index : i64 (compiler-profile-summary-offset scope found)]
        (begin
          (array-set!
            compiler-profile-summary-elapsed
            index
            (+ (array-ref compiler-profile-summary-elapsed index) elapsed))
          (array-set!
            compiler-profile-summary-calls
            index
            (+ (array-ref compiler-profile-summary-calls index) calls))
          (compiler-profile-summary-bubble! scope found)))
      (let
        [rank : i64
          (if (< count compiler-profile-summary-top-count)
            count
            (- count 1))]
        [index : i64 (compiler-profile-summary-offset scope rank)]
        (if (or
          (< count compiler-profile-summary-top-count)
          (compiler-profile-summary-better?
            key
            elapsed
            (array-ref compiler-profile-summary-keys index)
            (array-ref compiler-profile-summary-elapsed index)))
          (begin
            (array-set! compiler-profile-summary-keys index key)
            (array-set! compiler-profile-summary-names index name)
            (array-set! compiler-profile-summary-elapsed index elapsed)
            (array-set! compiler-profile-summary-calls index calls)
            (if (< count compiler-profile-summary-top-count)
              (array-set! compiler-profile-summary-counts scope (+ count 1))
              unit)
            (compiler-profile-summary-bubble! scope rank))
          unit)))))

(define (compiler-profile-summary-note-key!
  [scope : i64]
  [key : i64]
  [name : String]
  [elapsed : i64]) : unit
  (begin
    (array-set!
      compiler-profile-summary-total-elapsed
      scope
      (+ (array-ref compiler-profile-summary-total-elapsed scope) elapsed))
    (array-set!
      compiler-profile-summary-total-calls
      scope
      (+ (array-ref compiler-profile-summary-total-calls scope) 1))
    (if (compiler-profile-summary-exact-scope? scope)
      (compiler-profile-summary-note-exact! scope key name elapsed)
      (compiler-profile-summary-consider! scope key name elapsed 1))))

(define (compiler-profile-summary-note!
  [scope : i64]
  [name : String]
  [elapsed : i64]) : unit
  (compiler-profile-summary-note-key! scope (hash.string-key name) name elapsed))

(define (compiler-profile-summary-module [name : String]) : String
  (let
    [length : i64 (string.string-length name)]
    [index : i64 0]
    [last : i64 -1]
    [source-end : i64 -1]
    (begin
      (while (< index length)
        (begin
          (if (and
            (< source-end 0)
            (< (+ index 1) length)
            (= (string.string-ref name index) ':')
            (= (string.string-ref name (+ index 1)) ':'))
            (set! source-end index)
            unit)
          (if (= (string.string-ref name index) '/')
            (set! last index)
            unit)
          (set! index (+ index 1))))
      (if (>= source-end 0)
        (string.substring name 0 source-end)
        (if (< last 0)
          "<root>"
          (string.substring name 0 last))))))

(define (compiler-profile-summary-note-module!
  [scope : i64]
  [name : String]
  [elapsed : i64]) : unit
  (let
    [module : String (compiler-profile-summary-module name)]
    (compiler-profile-summary-note-key!
      scope
      (hash.string-key module)
      name
      elapsed)))

(define (compiler-profile-summary-rank-exact! [scope : i64]) : unit
  (let
    [count : i64
      (array-ref
        compiler-profile-summary-exact-counts
        (compiler-profile-summary-exact-scope-index scope))]
    [dense-offset : i64 (compiler-profile-summary-exact-offset scope 0)]
    [top-offset : i64
      (*
        (compiler-profile-summary-exact-scope-index scope)
        compiler-profile-summary-top-count)]
    [index : i64 0]
    [top-count : i64 0]
    (begin
      (while (< index count)
        (let
          [offset : i64 (+ dense-offset index)]
          [rank : i64 0]
          (begin
            (while (and
              (< rank top-count)
              (let
                [other : i64
                  (array-ref
                    compiler-profile-summary-exact-top
                    (+ top-offset rank))]
                (not
                  (compiler-profile-summary-better?
                    (array-ref compiler-profile-summary-exact-keys offset)
                    (array-ref compiler-profile-summary-exact-elapsed offset)
                    (array-ref
                      compiler-profile-summary-exact-keys
                      (+ dense-offset other))
                    (array-ref
                      compiler-profile-summary-exact-elapsed
                      (+ dense-offset other))))))
              (set! rank (+ rank 1)))
            (if (< rank compiler-profile-summary-top-count)
              (let
                [shift : i64
                  (if (< top-count compiler-profile-summary-top-count)
                    top-count
                    (- compiler-profile-summary-top-count 1))]
                (begin
                  (while (> shift rank)
                    (begin
                      (array-set!
                        compiler-profile-summary-exact-top
                        (+ top-offset shift)
                        (array-ref
                          compiler-profile-summary-exact-top
                          (+ top-offset (- shift 1))))
                      (set! shift (- shift 1))))
                  (array-set!
                    compiler-profile-summary-exact-top
                    (+ top-offset rank)
                    index)
                  (if (< top-count compiler-profile-summary-top-count)
                    (set! top-count (+ top-count 1))
                    unit)))
              unit)
            (set! index (+ index 1)))))
      (array-set! compiler-profile-summary-counts scope top-count))))

(define (compiler-profile-summary-line
  [scope-name : String]
  [kind : String]
  [rank : i64]
  [name : String]
  [elapsed : i64]
  [calls : i64]) : unit
  (io.print-error
    (string.concat5
      "compile-profile-summary|"
      scope-name
      "|"
      kind
      (string.concat5
        "|"
        (string.int->string rank)
        "|"
        name
        (string.concat5
          "|"
          (string.int->string elapsed)
          "|"
          (string.int->string calls)
          "\n")))))

(define (compiler-profile-summary-emit
  [scope : i64]
  [scope-name : String]
  [kind : String]) : unit
  (begin
    (if (compiler-profile-summary-exact-scope? scope)
      (compiler-profile-summary-rank-exact! scope)
      unit)
    (let
      [count : i64 (array-ref compiler-profile-summary-counts scope)]
      [rank : i64 0]
      [shown-elapsed : i64 0]
      [shown-calls : i64 0]
      (begin
        (while (< rank count)
          (let
            [index : i64 (compiler-profile-summary-offset scope rank)]
            [exact-index : i64
              (if (compiler-profile-summary-exact-scope? scope)
                (compiler-profile-summary-exact-offset
                  scope
                  (array-ref
                    compiler-profile-summary-exact-top
                    (+
                      (*
                        (compiler-profile-summary-exact-scope-index scope)
                        compiler-profile-summary-top-count)
                      rank)))
                0)]
            [elapsed : i64
              (if (compiler-profile-summary-exact-scope? scope)
                (array-ref compiler-profile-summary-exact-elapsed exact-index)
                (array-ref compiler-profile-summary-elapsed index))]
            [calls : i64
              (if (compiler-profile-summary-exact-scope? scope)
                (array-ref compiler-profile-summary-exact-calls exact-index)
                (array-ref compiler-profile-summary-calls index))]
            (begin
              (compiler-profile-summary-line
                scope-name
                kind
                (+ rank 1)
                (if (compiler-profile-summary-exact-scope? scope)
                  (if (string.eq kind "module")
                    (compiler-profile-summary-module
                      (array-ref
                        compiler-profile-summary-exact-names
                        exact-index))
                    (array-ref compiler-profile-summary-exact-names exact-index))
                  (array-ref compiler-profile-summary-names index))
                elapsed
                calls)
              (set! shown-elapsed (+ shown-elapsed elapsed))
              (set! shown-calls (+ shown-calls calls))
              (set! rank (+ rank 1)))))
        (compiler-profile-summary-line
          scope-name
          kind
          0
          "<remainder>"
          (-
            (array-ref compiler-profile-summary-total-elapsed scope)
            shown-elapsed)
          (- (array-ref compiler-profile-summary-total-calls scope) shown-calls))))))

(define (compiler-profile-summary-exact-regression [scope : i64]) : unit
  (begin
    (compiler-profile-summary-reset!)
    ;; "target" starts below the retained top eight, is evicted, then re-enters.
    (compiler-profile-summary-note! scope "target" 1)
    (compiler-profile-summary-note! scope "a" 10)
    (compiler-profile-summary-note! scope "b" 10)
    (compiler-profile-summary-note! scope "c" 10)
    (compiler-profile-summary-note! scope "d" 10)
    (compiler-profile-summary-note! scope "e" 10)
    (compiler-profile-summary-note! scope "f" 10)
    (compiler-profile-summary-note! scope "g" 10)
    (compiler-profile-summary-note! scope "h" 10)
    (compiler-profile-summary-note! scope "i" 10)
    (compiler-profile-summary-note! scope "target" 100)
    (compiler-profile-summary-note! scope "target" 100)
    (compiler-profile-summary-rank-exact! scope)
    (let
      [top-offset : i64
        (*
          (compiler-profile-summary-exact-scope-index scope)
          compiler-profile-summary-top-count)]
      [first : i64
        (compiler-profile-summary-exact-offset
          scope
          (array-ref compiler-profile-summary-exact-top top-offset))]
      [rank : i64 0]
      [shown-elapsed : i64 0]
      [shown-calls : i64 0]
      [expected : String "target"]
      (begin
        (test.assert-string-eq
          (& (array-ref compiler-profile-summary-exact-names first))
          (& expected)
          "exact recurring row returns to rank one")
        (test.assert-i64-eq
          (array-ref compiler-profile-summary-exact-elapsed first)
          201
          "exact recurring row retains elapsed time")
        (test.assert-i64-eq
          (array-ref compiler-profile-summary-exact-calls first)
          3
          "exact recurring row retains call count")
        (while (< rank (array-ref compiler-profile-summary-counts scope))
          (let
            [index : i64
              (compiler-profile-summary-exact-offset
                scope
                (array-ref
                  compiler-profile-summary-exact-top
                  (+ top-offset rank)))]
            (begin
              (set!
                shown-elapsed
                (+
                  shown-elapsed
                  (array-ref compiler-profile-summary-exact-elapsed index)))
              (set!
                shown-calls
                (+
                  shown-calls
                  (array-ref compiler-profile-summary-exact-calls index)))
              (set! rank (+ rank 1)))))
        (test.assert-i64-eq
          (-
            (array-ref compiler-profile-summary-total-elapsed scope)
            shown-elapsed)
          20
          "exact recurring scope remainder retains elapsed time")
        (test.assert-i64-eq
          (- (array-ref compiler-profile-summary-total-calls scope) shown-calls)
          2
          "exact recurring scope remainder retains call count")))))

(test
  compiler-profile-summary-exact-eviction-reentry
  (begin
    (compiler-profile-summary-exact-regression
      compiler-profile-summary-optimizer-pass)
    (compiler-profile-summary-exact-regression
      compiler-profile-summary-optimizer-module)
    (compiler-profile-summary-exact-regression
      compiler-profile-summary-backend-module)))