;; compiler_profile_summary.tl - bounded deterministic compile-profile reports.
(import stdlib.hash)
(import stdlib.io)
(import stdlib.string)

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

(define (compiler-profile-summary-reset!) : unit
  (let
    [scope : i64 0]
    (while (< scope compiler-profile-summary-scope-count)
      (begin
        (array-set! compiler-profile-summary-counts scope 0)
        (array-set! compiler-profile-summary-total-elapsed scope 0)
        (array-set! compiler-profile-summary-total-calls scope 0)
        (set! scope (+ scope 1))))))

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

(define (compiler-profile-summary-note-key!
  [scope : i64]
  [key : i64]
  [name : String]
  [elapsed : i64]) : unit
  (let
    [count : i64 (array-ref compiler-profile-summary-counts scope)]
    [found : i64 (compiler-profile-summary-find scope count key)]
    (begin
      (array-set!
        compiler-profile-summary-total-elapsed
        scope
        (+ (array-ref compiler-profile-summary-total-elapsed scope) elapsed))
      (array-set!
        compiler-profile-summary-total-calls
        scope
        (+ (array-ref compiler-profile-summary-total-calls scope) 1))
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
              (+ (array-ref compiler-profile-summary-calls index) 1))
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
              (array-set! compiler-profile-summary-calls index 1)
              (if (< count compiler-profile-summary-top-count)
                (array-set! compiler-profile-summary-counts scope (+ count 1))
                unit)
              (compiler-profile-summary-bubble! scope rank))
            unit))))))

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
  (let
    [count : i64 (array-ref compiler-profile-summary-counts scope)]
    [rank : i64 0]
    [shown-elapsed : i64 0]
    [shown-calls : i64 0]
    (begin
      (while (< rank count)
        (let
          [index : i64 (compiler-profile-summary-offset scope rank)]
          (begin
            (compiler-profile-summary-line
              scope-name
              kind
              (+ rank 1)
              (if (string.eq kind "module")
                (compiler-profile-summary-module
                  (array-ref compiler-profile-summary-names index))
                (array-ref compiler-profile-summary-names index))
              (array-ref compiler-profile-summary-elapsed index)
              (array-ref compiler-profile-summary-calls index))
            (set!
              shown-elapsed
              (+
                shown-elapsed
                (array-ref compiler-profile-summary-elapsed index)))
            (set!
              shown-calls
              (+ shown-calls (array-ref compiler-profile-summary-calls index)))
            (set! rank (+ rank 1)))))
      (compiler-profile-summary-line
        scope-name
        kind
        0
        "<remainder>"
        (-
          (array-ref compiler-profile-summary-total-elapsed scope)
          shown-elapsed)
        (- (array-ref compiler-profile-summary-total-calls scope) shown-calls)))))