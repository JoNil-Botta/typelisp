;; compiler_profile_state.tl - job-owned compile-profile storage.
;;
;; The public handle stays one word: profile builds point at a single storage
;; cell, while ordinary builds carry only a zero sentinel and allocate nothing.
;; Profile hooks pass the handle explicitly, so two compiler jobs never select
;; or mutate one process-global counter or summary table. Allocate ranked
;; summary tables only when that reporting mode (or this module's tests) is
;; actually selected.
(cfg test (import stdlib.test))

(define compiler-profile-state-metric-capacity : i64
  (cfg (any compile-profile test) 78 0))
(define compiler-profile-state-summary-row-capacity : i64
  (cfg (any compile-profile-summary test) 40 0))
(define compiler-profile-state-summary-scope-capacity : i64
  (cfg (any compile-profile-summary test) 5 0))
(define compiler-profile-state-summary-exact-table-capacity : i64
  (cfg (any compile-profile-summary test) 8448 0))
(define compiler-profile-state-summary-exact-scope-capacity : i64
  (cfg (any compile-profile-summary test) 3 0))
(define compiler-profile-state-summary-exact-row-capacity : i64
  (cfg (any compile-profile-summary test) 4224 0))
(define compiler-profile-state-summary-exact-top-capacity : i64
  (cfg (any compile-profile-summary test) 24 0))

(cfg
  (any compile-profile compile-profile-summary test)
  (defstruct CompilerProfileStateStorage
    (metrics (__tl_dyn-array i64))
    (summary-keys (__tl_dyn-array i64))
    (summary-names (__tl_dyn-array String))
    (summary-elapsed (__tl_dyn-array i64))
    (summary-calls (__tl_dyn-array i64))
    (summary-counts (__tl_dyn-array i64))
    (summary-total-elapsed (__tl_dyn-array i64))
    (summary-total-calls (__tl_dyn-array i64))
    (summary-exact-slots (__tl_dyn-array i64))
    (summary-exact-counts (__tl_dyn-array i64))
    (summary-exact-names (__tl_dyn-array String))
    (summary-exact-keys (__tl_dyn-array i64))
    (summary-exact-elapsed (__tl_dyn-array i64))
    (summary-exact-calls (__tl_dyn-array i64))
    (summary-exact-top (__tl_dyn-array i64))))

(cfg
  (any compile-profile compile-profile-summary test)
  (defstruct CompilerProfileState
    (storage (__tl_dyn-array CompilerProfileStateStorage))))

;; Hot instrumentation passes this one-word view instead of repeatedly copying
;; the wide profile storage record out of its job-owned array.
(cfg
  (any compile-profile test)
  (defstruct CompilerProfileMetrics
    (values (__tl_dyn-array i64))))

(cfg
  (not (any compile-profile test))
  (defstruct CompilerProfileMetrics
    (disabled i64)))

(cfg
  (not (any compile-profile compile-profile-summary test))
  (defstruct CompilerProfileState
    (disabled i64)))

(define (compiler-profile-state-new) : CompilerProfileState
  (cfg
    (any compile-profile compile-profile-summary test)
    (let
      [storage : (__tl_dyn-array CompilerProfileStateStorage)
        (__tl_make-array CompilerProfileStateStorage 1)]
      (begin
        (set!
          (array-ref storage 0)
          (CompilerProfileStateStorage
            (__tl_make-array i64 compiler-profile-state-metric-capacity)
            (__tl_make-array i64 compiler-profile-state-summary-row-capacity)
            (__tl_make-array String compiler-profile-state-summary-row-capacity)
            (__tl_make-array i64 compiler-profile-state-summary-row-capacity)
            (__tl_make-array i64 compiler-profile-state-summary-row-capacity)
            (__tl_make-array i64 compiler-profile-state-summary-scope-capacity)
            (__tl_make-array i64 compiler-profile-state-summary-scope-capacity)
            (__tl_make-array i64 compiler-profile-state-summary-scope-capacity)
            (__tl_make-array
              i64
              compiler-profile-state-summary-exact-table-capacity)
            (__tl_make-array
              i64
              compiler-profile-state-summary-exact-scope-capacity)
            (__tl_make-array
              String
              compiler-profile-state-summary-exact-row-capacity)
            (__tl_make-array
              i64
              compiler-profile-state-summary-exact-row-capacity)
            (__tl_make-array
              i64
              compiler-profile-state-summary-exact-row-capacity)
            (__tl_make-array
              i64
              compiler-profile-state-summary-exact-row-capacity)
            (__tl_make-array
              i64
              compiler-profile-state-summary-exact-top-capacity)))
        (CompilerProfileState storage)))
    (CompilerProfileState 0)))

(cfg
  (any compile-profile compile-profile-summary test)
  (define (compiler-profile-state-storage [state : CompilerProfileState]) : CompilerProfileStateStorage
    (array-ref state.storage 0)))

(defmacro (compiler-profile-state-metrics [_state : Expr]) : Expr
  (cfg
    (any compile-profile test)
    `(CompilerProfileMetrics
      (__tl-project-field
        (array-ref ,(comptime.expr-struct-get _state "storage") 0)
        metrics))
    `(CompilerProfileMetrics 0)))

(cfg
  (any compile-profile test)
  (defmacro (compiler-profile-metrics-value [metrics : Expr] [metric : Expr]) : Expr
    `(array-ref ,(comptime.expr-struct-get metrics "values") ,metric)))

(cfg
  (any compile-profile test)
  (defmacro (compiler-profile-metrics-set!
    [metrics : Expr]
    [metric : Expr]
    [value : Expr]) : Expr
    `(set!
      (array-ref ,(comptime.expr-struct-get metrics "values") ,metric)
      ,value)))

(cfg
  (any compile-profile test)
  (defmacro (compiler-profile-metrics-add!
    [metrics : Expr]
    [metric : Expr]
    [value : Expr]) : Expr
    `(let
      [values : (__tl_dyn-array i64)
        ,(comptime.expr-struct-get metrics "values")]
      [index : i64 ,metric]
      (set! (array-ref values index) (+ (array-ref values index) ,value)))))

(cfg
  (any compile-profile test)
  (define (compiler-profile-metrics-reset-range!
    [metrics : CompilerProfileMetrics]
    [start : i64]
    [end : i64]) : unit
    (let
      [metric : i64 start]
      (while (< metric end)
        (begin
          (compiler-profile-metrics-set! metrics metric 0)
          (set! metric (+ metric 1)))))))

(cfg
  (any compile-profile test)
  (define (compiler-profile-state-metric-value
    [state : CompilerProfileState]
    [metric : i64]) : i64
    (compiler-profile-metrics-value
      (compiler-profile-state-metrics state)
      metric)))

(cfg
  (any compile-profile test)
  (define (compiler-profile-state-metric-set!
    [state : CompilerProfileState]
    [metric : i64]
    [value : i64]) : unit
    (compiler-profile-metrics-set!
      (compiler-profile-state-metrics state)
      metric
      value)))

(cfg
  (any compile-profile test)
  (define (compiler-profile-state-metric-add!
    [state : CompilerProfileState]
    [metric : i64]
    [value : i64]) : unit
    (compiler-profile-metrics-add!
      (compiler-profile-state-metrics state)
      metric
      value)))

(cfg
  (any compile-profile test)
  (define (compiler-profile-state-metric-reset-range!
    [state : CompilerProfileState]
    [start : i64]
    [end : i64]) : unit
    (compiler-profile-metrics-reset-range!
      (compiler-profile-state-metrics state)
      start
      end)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-keys [state : CompilerProfileState]) : (__tl_dyn-array
      i64)
    (__tl-project-field (compiler-profile-state-storage state) summary-keys)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-names [state : CompilerProfileState]) : (__tl_dyn-array
      String)
    (__tl-project-field (compiler-profile-state-storage state) summary-names)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-elapsed
    [state : CompilerProfileState]) : (__tl_dyn-array i64)
    (__tl-project-field (compiler-profile-state-storage state) summary-elapsed)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-calls [state : CompilerProfileState]) : (__tl_dyn-array
      i64)
    (__tl-project-field (compiler-profile-state-storage state) summary-calls)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-counts [state : CompilerProfileState]) : (__tl_dyn-array
      i64)
    (__tl-project-field (compiler-profile-state-storage state) summary-counts)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-total-elapsed
    [state : CompilerProfileState]) : (__tl_dyn-array i64)
    (__tl-project-field
      (compiler-profile-state-storage state)
      summary-total-elapsed)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-total-calls
    [state : CompilerProfileState]) : (__tl_dyn-array i64)
    (__tl-project-field
      (compiler-profile-state-storage state)
      summary-total-calls)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-exact-slots
    [state : CompilerProfileState]) : (__tl_dyn-array i64)
    (__tl-project-field
      (compiler-profile-state-storage state)
      summary-exact-slots)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-exact-counts
    [state : CompilerProfileState]) : (__tl_dyn-array i64)
    (__tl-project-field
      (compiler-profile-state-storage state)
      summary-exact-counts)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-exact-names
    [state : CompilerProfileState]) : (__tl_dyn-array String)
    (__tl-project-field
      (compiler-profile-state-storage state)
      summary-exact-names)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-exact-keys
    [state : CompilerProfileState]) : (__tl_dyn-array i64)
    (__tl-project-field
      (compiler-profile-state-storage state)
      summary-exact-keys)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-exact-elapsed
    [state : CompilerProfileState]) : (__tl_dyn-array i64)
    (__tl-project-field
      (compiler-profile-state-storage state)
      summary-exact-elapsed)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-exact-calls
    [state : CompilerProfileState]) : (__tl_dyn-array i64)
    (__tl-project-field
      (compiler-profile-state-storage state)
      summary-exact-calls)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-exact-top
    [state : CompilerProfileState]) : (__tl_dyn-array i64)
    (__tl-project-field
      (compiler-profile-state-storage state)
      summary-exact-top)))

(cfg
  test
  (test
    compiler-profile-state-metric-job-isolation
    (let
      [left : CompilerProfileState (compiler-profile-state-new)]
      [right : CompilerProfileState (compiler-profile-state-new)]
      (begin
        (compiler-profile-state-metric-set! left 3 11)
        (compiler-profile-state-metric-set! right 3 29)
        (compiler-profile-state-metric-add! left 3 7)
        (compiler-profile-state-metric-set! left 4 41)
        (compiler-profile-state-metric-set! right 4 43)
        (compiler-profile-state-metric-reset-range! right 3 5)
        (test.assert-i64-eq
          (compiler-profile-state-metric-value left 3)
          18
          "left job keeps interleaved metric")
        (test.assert-i64-eq
          (compiler-profile-state-metric-value left 4)
          41
          "right reset does not erase left range")
        (test.assert-i64-eq
          (compiler-profile-state-metric-value right 3)
          0
          "right reset clears its first metric")
        (test.assert-i64-eq
          (compiler-profile-state-metric-value right 4)
          0
          "right reset clears its second metric")))))