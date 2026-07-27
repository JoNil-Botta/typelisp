;; compiler_profile_summary.tl - bounded deterministic job-owned reports.
(import compiler_profile_state as profile_state)
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

(define (compiler-profile-summary-keys
  [state : profile_state.CompilerProfileState]) : (Array i64)
  (profile_state.compiler-profile-state-summary-keys state))

(define (compiler-profile-summary-names
  [state : profile_state.CompilerProfileState]) : (Array String)
  (profile_state.compiler-profile-state-summary-names state))

(define (compiler-profile-summary-elapsed
  [state : profile_state.CompilerProfileState]) : (Array i64)
  (profile_state.compiler-profile-state-summary-elapsed state))

(define (compiler-profile-summary-calls
  [state : profile_state.CompilerProfileState]) : (Array i64)
  (profile_state.compiler-profile-state-summary-calls state))

(define (compiler-profile-summary-counts
  [state : profile_state.CompilerProfileState]) : (Array i64)
  (profile_state.compiler-profile-state-summary-counts state))

(define (compiler-profile-summary-total-elapsed
  [state : profile_state.CompilerProfileState]) : (Array i64)
  (profile_state.compiler-profile-state-summary-total-elapsed state))

(define (compiler-profile-summary-total-calls
  [state : profile_state.CompilerProfileState]) : (Array i64)
  (profile_state.compiler-profile-state-summary-total-calls state))

(define (compiler-profile-summary-exact-slots
  [state : profile_state.CompilerProfileState]) : (Array i64)
  (profile_state.compiler-profile-state-summary-exact-slots state))

(define (compiler-profile-summary-exact-counts
  [state : profile_state.CompilerProfileState]) : (Array i64)
  (profile_state.compiler-profile-state-summary-exact-counts state))

(define (compiler-profile-summary-exact-names
  [state : profile_state.CompilerProfileState]) : (Array String)
  (profile_state.compiler-profile-state-summary-exact-names state))

(define (compiler-profile-summary-exact-keys
  [state : profile_state.CompilerProfileState]) : (Array i64)
  (profile_state.compiler-profile-state-summary-exact-keys state))

(define (compiler-profile-summary-exact-elapsed
  [state : profile_state.CompilerProfileState]) : (Array i64)
  (profile_state.compiler-profile-state-summary-exact-elapsed state))

(define (compiler-profile-summary-exact-calls
  [state : profile_state.CompilerProfileState]) : (Array i64)
  (profile_state.compiler-profile-state-summary-exact-calls state))

(define (compiler-profile-summary-exact-top
  [state : profile_state.CompilerProfileState]) : (Array i64)
  (profile_state.compiler-profile-state-summary-exact-top state))

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

(define (compiler-profile-summary-record-at!
  [state : profile_state.CompilerProfileState]
  [scope : i64]
  [index : i64]
  [elapsed : i64]
  [fresh : bool]) : unit
  (let
    [offset : i64 (compiler-profile-summary-exact-offset scope index)]
    [elapsed-values : (Array i64)
      (compiler-profile-summary-exact-elapsed state)]
    [call-values : (Array i64) (compiler-profile-summary-exact-calls state)]
    (if fresh
      (begin
        (array-set! elapsed-values offset elapsed)
        (array-set! call-values offset 1))
      (begin
        (array-set!
          elapsed-values
          offset
          (+ (array-ref elapsed-values offset) elapsed))
        (array-set! call-values offset (+ (array-ref call-values offset) 1))))))

(define (compiler-profile-summary-note-exact!
  [state : profile_state.CompilerProfileState]
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
    [slots : (Array i64) (compiler-profile-summary-exact-slots state)]
    [counts : (Array i64) (compiler-profile-summary-exact-counts state)]
    [names : (Array String) (compiler-profile-summary-exact-names state)]
    [keys : (Array i64) (compiler-profile-summary-exact-keys state)]
    [slot : i64 (+ table-offset (% key table-capacity))]
    [probes : i64 0]
    [index : i64 -1]
    [fresh : bool false]
    (begin
      (while (and (< index 0) (< probes table-capacity))
        (let
          [marker : i64 (array-ref slots slot)]
          (if (= marker 0)
            (begin
              (set! index (array-ref counts scope-index))
              (if (>=
                index
                (compiler-profile-summary-exact-scope-capacity scope))
                (io.panic
                  "compile-profile summary exact scope capacity exceeded")
                unit)
              (array-set! names (+ dense-offset index) name)
              (array-set! keys (+ dense-offset index) key)
              (array-set! slots slot (+ index 1))
              (array-set! counts scope-index (+ index 1))
              (set! fresh true))
            (let
              [candidate : i64 (- marker 1)]
              (if (= (array-ref keys (+ dense-offset candidate)) key)
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
        (compiler-profile-summary-record-at! state scope index elapsed fresh)))))

(define (compiler-profile-summary-reset!
  [state : profile_state.CompilerProfileState]) : unit
  (let
    [counts : (Array i64) (compiler-profile-summary-counts state)]
    [total-elapsed : (Array i64) (compiler-profile-summary-total-elapsed state)]
    [total-calls : (Array i64) (compiler-profile-summary-total-calls state)]
    [exact-slots : (Array i64) (compiler-profile-summary-exact-slots state)]
    [exact-counts : (Array i64) (compiler-profile-summary-exact-counts state)]
    [scope : i64 0]
    [slot : i64 0]
    (begin
      (while (< scope compiler-profile-summary-scope-count)
        (begin
          (array-set! counts scope 0)
          (array-set! total-elapsed scope 0)
          (array-set! total-calls scope 0)
          (set! scope (+ scope 1))))
      (while (< slot compiler-profile-summary-exact-table-capacity)
        (begin
          (array-set! exact-slots slot 0)
          (set! slot (+ slot 1))))
      (array-set! exact-counts 0 0)
      (array-set! exact-counts 1 0)
      (array-set! exact-counts 2 0))))

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

(define (compiler-profile-summary-find
  [state : profile_state.CompilerProfileState]
  [scope : i64]
  [count : i64]
  [key : i64]) : i64
  (let
    [keys : (Array i64) (compiler-profile-summary-keys state)]
    [rank : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< rank count))
        (if (=
          (array-ref keys (compiler-profile-summary-offset scope rank))
          key)
          (set! found rank)
          (set! rank (+ rank 1))))
      found)))

(define (compiler-profile-summary-swap!
  [state : profile_state.CompilerProfileState]
  [scope : i64]
  [left : i64]
  [right : i64]) : unit
  (let
    [keys : (Array i64) (compiler-profile-summary-keys state)]
    [names : (Array String) (compiler-profile-summary-names state)]
    [elapsed-values : (Array i64) (compiler-profile-summary-elapsed state)]
    [call-values : (Array i64) (compiler-profile-summary-calls state)]
    [li : i64 (compiler-profile-summary-offset scope left)]
    [ri : i64 (compiler-profile-summary-offset scope right)]
    [key : i64 (array-ref keys li)]
    [name : String (array-ref names li)]
    [elapsed : i64 (array-ref elapsed-values li)]
    [calls : i64 (array-ref call-values li)]
    (begin
      (array-set! keys li (array-ref keys ri))
      (array-set! names li (array-ref names ri))
      (array-set! elapsed-values li (array-ref elapsed-values ri))
      (array-set! call-values li (array-ref call-values ri))
      (array-set! keys ri key)
      (array-set! names ri name)
      (array-set! elapsed-values ri elapsed)
      (array-set! call-values ri calls))))

(define (compiler-profile-summary-bubble!
  [state : profile_state.CompilerProfileState]
  [scope : i64]
  [rank : i64]) : unit
  (if (<= rank 0)
    unit
    (let
      [keys : (Array i64) (compiler-profile-summary-keys state)]
      [elapsed-values : (Array i64) (compiler-profile-summary-elapsed state)]
      [i : i64 (compiler-profile-summary-offset scope rank)]
      [p : i64 (compiler-profile-summary-offset scope (- rank 1))]
      (if (compiler-profile-summary-better?
        (array-ref keys i)
        (array-ref elapsed-values i)
        (array-ref keys p)
        (array-ref elapsed-values p))
        (begin
          (compiler-profile-summary-swap! state scope rank (- rank 1))
          (compiler-profile-summary-bubble! state scope (- rank 1)))
        unit))))

(define (compiler-profile-summary-consider!
  [state : profile_state.CompilerProfileState]
  [scope : i64]
  [key : i64]
  [name : String]
  [elapsed : i64]
  [calls : i64]) : unit
  (let
    [counts : (Array i64) (compiler-profile-summary-counts state)]
    [keys : (Array i64) (compiler-profile-summary-keys state)]
    [names : (Array String) (compiler-profile-summary-names state)]
    [elapsed-values : (Array i64) (compiler-profile-summary-elapsed state)]
    [call-values : (Array i64) (compiler-profile-summary-calls state)]
    [count : i64 (array-ref counts scope)]
    [found : i64 (compiler-profile-summary-find state scope count key)]
    (if (>= found 0)
      (let
        [index : i64 (compiler-profile-summary-offset scope found)]
        (begin
          (array-set!
            elapsed-values
            index
            (+ (array-ref elapsed-values index) elapsed))
          (array-set! call-values index (+ (array-ref call-values index) calls))
          (compiler-profile-summary-bubble! state scope found)))
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
            (array-ref keys index)
            (array-ref elapsed-values index)))
          (begin
            (array-set! keys index key)
            (array-set! names index name)
            (array-set! elapsed-values index elapsed)
            (array-set! call-values index calls)
            (if (< count compiler-profile-summary-top-count)
              (array-set! counts scope (+ count 1))
              unit)
            (compiler-profile-summary-bubble! state scope rank))
          unit)))))

(define (compiler-profile-summary-note-key!
  [state : profile_state.CompilerProfileState]
  [scope : i64]
  [key : i64]
  [name : String]
  [elapsed : i64]) : unit
  (let
    [total-elapsed : (Array i64) (compiler-profile-summary-total-elapsed state)]
    [total-calls : (Array i64) (compiler-profile-summary-total-calls state)]
    (begin
      (array-set!
        total-elapsed
        scope
        (+ (array-ref total-elapsed scope) elapsed))
      (array-set! total-calls scope (+ (array-ref total-calls scope) 1))
      (if (compiler-profile-summary-exact-scope? scope)
        (compiler-profile-summary-note-exact! state scope key name elapsed)
        (compiler-profile-summary-consider! state scope key name elapsed 1)))))

(define (compiler-profile-summary-note!
  [state : profile_state.CompilerProfileState]
  [scope : i64]
  [name : String]
  [elapsed : i64]) : unit
  (compiler-profile-summary-note-key!
    state
    scope
    (hash.string-key name)
    name
    elapsed))

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
  [state : profile_state.CompilerProfileState]
  [scope : i64]
  [name : String]
  [elapsed : i64]) : unit
  (let
    [module : String (compiler-profile-summary-module name)]
    (compiler-profile-summary-note-key!
      state
      scope
      (hash.string-key module)
      name
      elapsed)))

(define (compiler-profile-summary-rank-exact!
  [state : profile_state.CompilerProfileState]
  [scope : i64]) : unit
  (let
    [counts : (Array i64) (compiler-profile-summary-counts state)]
    [exact-counts : (Array i64) (compiler-profile-summary-exact-counts state)]
    [keys : (Array i64) (compiler-profile-summary-exact-keys state)]
    [elapsed-values : (Array i64)
      (compiler-profile-summary-exact-elapsed state)]
    [top : (Array i64) (compiler-profile-summary-exact-top state)]
    [count : i64
      (array-ref
        exact-counts
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
                [other : i64 (array-ref top (+ top-offset rank))]
                (not
                  (compiler-profile-summary-better?
                    (array-ref keys offset)
                    (array-ref elapsed-values offset)
                    (array-ref keys (+ dense-offset other))
                    (array-ref elapsed-values (+ dense-offset other))))))
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
                        top
                        (+ top-offset shift)
                        (array-ref top (+ top-offset (- shift 1))))
                      (set! shift (- shift 1))))
                  (array-set! top (+ top-offset rank) index)
                  (if (< top-count compiler-profile-summary-top-count)
                    (set! top-count (+ top-count 1))
                    unit)))
              unit)
            (set! index (+ index 1)))))
      (array-set! counts scope top-count))))

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
  [state : profile_state.CompilerProfileState]
  [scope : i64]
  [scope-name : String]
  [kind : String]) : unit
  (begin
    (if (compiler-profile-summary-exact-scope? scope)
      (compiler-profile-summary-rank-exact! state scope)
      unit)
    (let
      [counts : (Array i64) (compiler-profile-summary-counts state)]
      [names : (Array String) (compiler-profile-summary-names state)]
      [elapsed-values : (Array i64) (compiler-profile-summary-elapsed state)]
      [call-values : (Array i64) (compiler-profile-summary-calls state)]
      [exact-names : (Array String)
        (compiler-profile-summary-exact-names state)]
      [exact-elapsed : (Array i64)
        (compiler-profile-summary-exact-elapsed state)]
      [exact-calls : (Array i64) (compiler-profile-summary-exact-calls state)]
      [exact-top : (Array i64) (compiler-profile-summary-exact-top state)]
      [total-elapsed : (Array i64)
        (compiler-profile-summary-total-elapsed state)]
      [total-calls : (Array i64) (compiler-profile-summary-total-calls state)]
      [count : i64 (array-ref counts scope)]
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
                    exact-top
                    (+
                      (*
                        (compiler-profile-summary-exact-scope-index scope)
                        compiler-profile-summary-top-count)
                      rank)))
                0)]
            [elapsed : i64
              (if (compiler-profile-summary-exact-scope? scope)
                (array-ref exact-elapsed exact-index)
                (array-ref elapsed-values index))]
            [calls : i64
              (if (compiler-profile-summary-exact-scope? scope)
                (array-ref exact-calls exact-index)
                (array-ref call-values index))]
            (begin
              (compiler-profile-summary-line
                scope-name
                kind
                (+ rank 1)
                (if (compiler-profile-summary-exact-scope? scope)
                  (if (string.eq kind "module")
                    (compiler-profile-summary-module
                      (array-ref exact-names exact-index))
                    (array-ref exact-names exact-index))
                  (array-ref names index))
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
          (- (array-ref total-elapsed scope) shown-elapsed)
          (- (array-ref total-calls scope) shown-calls))))))

(define (compiler-profile-summary-exact-find
  [state : profile_state.CompilerProfileState]
  [scope : i64]
  [name : String]) : i64
  (let
    [count : i64
      (array-ref
        (compiler-profile-summary-exact-counts state)
        (compiler-profile-summary-exact-scope-index scope))]
    [offset : i64 (compiler-profile-summary-exact-offset scope 0)]
    [names : (Array String) (compiler-profile-summary-exact-names state)]
    [index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< index count))
        (if (string.eq (array-ref names (+ offset index)) name)
          (set! found (+ offset index))
          (set! index (+ index 1))))
      found)))

(define (compiler-profile-summary-exact-regression [scope : i64]) : unit
  (let
    [state : profile_state.CompilerProfileState
      (profile_state.compiler-profile-state-new)]
    (begin
      (compiler-profile-summary-reset! state)
      ;; "target" begins below the retained top eight, then returns to first.
      (compiler-profile-summary-note! state scope "target" 1)
      (compiler-profile-summary-note! state scope "a" 10)
      (compiler-profile-summary-note! state scope "b" 10)
      (compiler-profile-summary-note! state scope "c" 10)
      (compiler-profile-summary-note! state scope "d" 10)
      (compiler-profile-summary-note! state scope "e" 10)
      (compiler-profile-summary-note! state scope "f" 10)
      (compiler-profile-summary-note! state scope "g" 10)
      (compiler-profile-summary-note! state scope "h" 10)
      (compiler-profile-summary-note! state scope "i" 10)
      (compiler-profile-summary-note! state scope "target" 100)
      (compiler-profile-summary-note! state scope "target" 100)
      (compiler-profile-summary-rank-exact! state scope)
      (let
        [target : i64
          (compiler-profile-summary-exact-find state scope "target")]
        [top-offset : i64
          (*
            (compiler-profile-summary-exact-scope-index scope)
            compiler-profile-summary-top-count)]
        [first : i64
          (compiler-profile-summary-exact-offset
            scope
            (array-ref (compiler-profile-summary-exact-top state) top-offset))]
        [exact-names : (Array String)
          (compiler-profile-summary-exact-names state)]
        [rank : i64 0]
        [shown-elapsed : i64 0]
        [shown-calls : i64 0]
        [expected : String "target"]
        (begin
          (test.assert-string-eq
            (& (array-ref exact-names first))
            (& expected)
            "exact recurring row returns to rank one")
          (test.assert-i64-eq
            (array-ref (compiler-profile-summary-exact-elapsed state) target)
            201
            "exact recurring row retains elapsed time")
          (test.assert-i64-eq
            (array-ref (compiler-profile-summary-exact-calls state) target)
            3
            "exact recurring row retains call count")
          (while (<
            rank
            (array-ref (compiler-profile-summary-counts state) scope))
            (let
              [index : i64
                (compiler-profile-summary-exact-offset
                  scope
                  (array-ref
                    (compiler-profile-summary-exact-top state)
                    (+ top-offset rank)))]
              (begin
                (set!
                  shown-elapsed
                  (+
                    shown-elapsed
                    (array-ref
                      (compiler-profile-summary-exact-elapsed state)
                      index)))
                (set!
                  shown-calls
                  (+
                    shown-calls
                    (array-ref
                      (compiler-profile-summary-exact-calls state)
                      index)))
                (set! rank (+ rank 1)))))
          (test.assert-i64-eq
            (-
              (array-ref (compiler-profile-summary-total-elapsed state) scope)
              shown-elapsed)
            20
            "exact recurring scope remainder retains elapsed time")
          (test.assert-i64-eq
            (-
              (array-ref (compiler-profile-summary-total-calls state) scope)
              shown-calls)
            2
            "exact recurring scope remainder retains call count"))))))

(test
  compiler-profile-summary-exact-eviction-reentry
  (begin
    (compiler-profile-summary-exact-regression
      compiler-profile-summary-optimizer-pass)
    (compiler-profile-summary-exact-regression
      compiler-profile-summary-optimizer-module)
    (compiler-profile-summary-exact-regression
      compiler-profile-summary-backend-module)))

(test
  compiler-profile-summary-job-isolation
  (let
    [left : profile_state.CompilerProfileState
      (profile_state.compiler-profile-state-new)]
    [right : profile_state.CompilerProfileState
      (profile_state.compiler-profile-state-new)]
    (begin
      (compiler-profile-summary-reset! left)
      (compiler-profile-summary-reset! right)
      ;; Interleave overlapping optimizer and backend identities.
      (compiler-profile-summary-note!
        left
        compiler-profile-summary-optimizer-pass
        "shared-pass"
        11)
      (compiler-profile-summary-note!
        right
        compiler-profile-summary-optimizer-pass
        "shared-pass"
        3)
      (compiler-profile-summary-note!
        left
        compiler-profile-summary-backend-module
        "shared/module::left"
        7)
      (compiler-profile-summary-note!
        right
        compiler-profile-summary-backend-module
        "shared/module::right"
        19)
      (compiler-profile-summary-note!
        left
        compiler-profile-summary-optimizer-pass
        "shared-pass"
        5)
      (compiler-profile-summary-reset! right)
      (compiler-profile-summary-note!
        right
        compiler-profile-summary-optimizer-pass
        "right-only"
        23)
      (compiler-profile-summary-rank-exact!
        left
        compiler-profile-summary-optimizer-pass)
      (compiler-profile-summary-rank-exact!
        left
        compiler-profile-summary-backend-module)
      (compiler-profile-summary-rank-exact!
        right
        compiler-profile-summary-optimizer-pass)
      (let
        [left-names : (Array String)
          (compiler-profile-summary-exact-names left)]
        [right-names : (Array String)
          (compiler-profile-summary-exact-names right)]
        [left-pass : i64
          (compiler-profile-summary-exact-find
            left
            compiler-profile-summary-optimizer-pass
            "shared-pass")]
        [left-backend : i64
          (compiler-profile-summary-exact-find
            left
            compiler-profile-summary-backend-module
            "shared/module::left")]
        [right-pass : i64
          (compiler-profile-summary-exact-find
            right
            compiler-profile-summary-optimizer-pass
            "right-only")]
        [left-pass-top : i64
          (compiler-profile-summary-exact-offset
            compiler-profile-summary-optimizer-pass
            (array-ref (compiler-profile-summary-exact-top left) 0))]
        [right-pass-top : i64
          (compiler-profile-summary-exact-offset
            compiler-profile-summary-optimizer-pass
            (array-ref (compiler-profile-summary-exact-top right) 0))]
        [left-pass-name : String "shared-pass"]
        [right-pass-name : String "right-only"]
        (begin
          (test.assert-i64-eq
            (array-ref (compiler-profile-summary-exact-elapsed left) left-pass)
            16
            "left optimizer elapsed survives right reset")
          (test.assert-i64-eq
            (array-ref (compiler-profile-summary-exact-calls left) left-pass)
            2
            "left optimizer calls stay independent")
          (test.assert-i64-eq
            (array-ref
              (compiler-profile-summary-exact-elapsed left)
              left-backend)
            7
            "left backend row survives right reset")
          (test.assert-i64-eq
            (compiler-profile-summary-exact-find
              right
              compiler-profile-summary-optimizer-pass
              "shared-pass")
            -1
            "right reset removes only right rows")
          (test.assert-i64-eq
            (array-ref
              (compiler-profile-summary-exact-elapsed right)
              right-pass)
            23
            "right optimizer row remains independent")
          (test.assert-string-eq
            (& (array-ref left-names left-pass-top))
            (& left-pass-name)
            "left top row is ranked from left state")
          (test.assert-string-eq
            (& (array-ref right-names right-pass-top))
            (& right-pass-name)
            "right top row is ranked from right state"))))))