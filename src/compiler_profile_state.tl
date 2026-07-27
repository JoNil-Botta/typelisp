;; compiler_profile_state.tl - job-owned compile-profile storage.
;;
;; The public handle stays one word: compact-summary builds point at a single
;; storage cell, while ordinary and full-detail builds carry only a zero
;; sentinel and allocate nothing. Profile hooks pass the handle explicitly, so
;; two compiler jobs never select or mutate one process-global summary table.
(import stdlib.array)

;; Allocate ranked-summary tables only when that reporting mode (or this
;; module's tests) is actually selected.
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
  (any compile-profile-summary test)
  (defstruct CompilerProfileStateStorage
    (summary-keys (Array i64))
    (summary-names (Array String))
    (summary-elapsed (Array i64))
    (summary-calls (Array i64))
    (summary-counts (Array i64))
    (summary-total-elapsed (Array i64))
    (summary-total-calls (Array i64))
    (summary-exact-slots (Array i64))
    (summary-exact-counts (Array i64))
    (summary-exact-names (Array String))
    (summary-exact-keys (Array i64))
    (summary-exact-elapsed (Array i64))
    (summary-exact-calls (Array i64))
    (summary-exact-top (Array i64))))

(cfg
  (any compile-profile-summary test)
  (defstruct CompilerProfileState
    (storage (Array CompilerProfileStateStorage))))

(cfg
  (not (any compile-profile-summary test))
  (defstruct CompilerProfileState
    (disabled i64)))

(define (compiler-profile-state-new) : CompilerProfileState
  (cfg
    (any compile-profile-summary test)
    (let
      [storage : (Array CompilerProfileStateStorage)
        (make-array CompilerProfileStateStorage 1)]
      (begin
        (array-set!
          storage
          0
          (CompilerProfileStateStorage
            (make-array i64 compiler-profile-state-summary-row-capacity)
            (make-array String compiler-profile-state-summary-row-capacity)
            (make-array i64 compiler-profile-state-summary-row-capacity)
            (make-array i64 compiler-profile-state-summary-row-capacity)
            (make-array i64 compiler-profile-state-summary-scope-capacity)
            (make-array i64 compiler-profile-state-summary-scope-capacity)
            (make-array i64 compiler-profile-state-summary-scope-capacity)
            (make-array i64 compiler-profile-state-summary-exact-table-capacity)
            (make-array i64 compiler-profile-state-summary-exact-scope-capacity)
            (make-array
              String
              compiler-profile-state-summary-exact-row-capacity)
            (make-array i64 compiler-profile-state-summary-exact-row-capacity)
            (make-array i64 compiler-profile-state-summary-exact-row-capacity)
            (make-array i64 compiler-profile-state-summary-exact-row-capacity)
            (make-array i64 compiler-profile-state-summary-exact-top-capacity)))
        (CompilerProfileState storage)))
    (CompilerProfileState 0)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-storage [state : CompilerProfileState]) : CompilerProfileStateStorage
    (array-ref (struct-get state storage) 0)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-keys [state : CompilerProfileState]) : (Array
      i64)
    (struct-get (compiler-profile-state-storage state) summary-keys)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-names [state : CompilerProfileState]) : (Array
      String)
    (struct-get (compiler-profile-state-storage state) summary-names)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-elapsed
    [state : CompilerProfileState]) : (Array i64)
    (struct-get (compiler-profile-state-storage state) summary-elapsed)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-calls [state : CompilerProfileState]) : (Array
      i64)
    (struct-get (compiler-profile-state-storage state) summary-calls)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-counts [state : CompilerProfileState]) : (Array
      i64)
    (struct-get (compiler-profile-state-storage state) summary-counts)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-total-elapsed
    [state : CompilerProfileState]) : (Array i64)
    (struct-get (compiler-profile-state-storage state) summary-total-elapsed)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-total-calls
    [state : CompilerProfileState]) : (Array i64)
    (struct-get (compiler-profile-state-storage state) summary-total-calls)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-exact-slots
    [state : CompilerProfileState]) : (Array i64)
    (struct-get (compiler-profile-state-storage state) summary-exact-slots)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-exact-counts
    [state : CompilerProfileState]) : (Array i64)
    (struct-get (compiler-profile-state-storage state) summary-exact-counts)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-exact-names
    [state : CompilerProfileState]) : (Array String)
    (struct-get (compiler-profile-state-storage state) summary-exact-names)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-exact-keys
    [state : CompilerProfileState]) : (Array i64)
    (struct-get (compiler-profile-state-storage state) summary-exact-keys)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-exact-elapsed
    [state : CompilerProfileState]) : (Array i64)
    (struct-get (compiler-profile-state-storage state) summary-exact-elapsed)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-exact-calls
    [state : CompilerProfileState]) : (Array i64)
    (struct-get (compiler-profile-state-storage state) summary-exact-calls)))

(cfg
  (any compile-profile-summary test)
  (define (compiler-profile-state-summary-exact-top
    [state : CompilerProfileState]) : (Array i64)
    (struct-get (compiler-profile-state-storage state) summary-exact-top)))