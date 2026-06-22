;# Lifetime-preserving I/O caller-result APIs (#1913/#1962).
;#
;# This module stays separate from `io.tl` while the compatibility wrapper keeps
;# the owned `String` API. It exposes helpers that may return caller-provided
;# fallback text without copying.
(module stdlib.io_caller_result)

(import stdlib.io)
(import stdlib.string)

;: Result for `read-file-or-result`.
;:
;: `fallback` is tied to the caller fallback lifetime. When `is-owned` is false,
;: callers should observe `fallback`; when `is-owned` is true, `owned` stores
;: fresh active-arena file contents from the success branch.
(defstruct ReadFileOrResult
  (:lifetimes fallback)
  (fallback (& fallback str))
  (owned String)
  (is-owned bool))

;: True when `result` carries the caller fallback borrow.
(define (read-file-or-result-borrowed? [result : (ReadFileOrResult fallback)]) : bool
  (not (struct-get result is-owned)))

;: True when `result` carries owned file contents from a successful read.
(define (read-file-or-result-owned? [result : (ReadFileOrResult fallback)]) : bool
  (struct-get result is-owned))

;: Construct a borrowed fallback result.
(define (read-file-or-borrowed-result [fallback : (& fallback str)]) : (ReadFileOrResult
    fallback)
  (let
    [empty : String ""]
    (ReadFileOrResult fallback empty false)))

;: Construct an owned result while preserving the fallback lifetime parameter.
(define (read-file-or-owned-result-like
  [fallback : (& fallback str)]
  [owned : String]) : (ReadFileOrResult fallback)
  (ReadFileOrResult fallback owned true))

;: Materialize a result as an owned `String`. Borrowed branches are copied at
;: this explicit compatibility boundary.
(define (read-file-or-result-string [result : (ReadFileOrResult fallback)]) : String
  (if (read-file-or-result-owned? result)
    (struct-get result owned)
    (string.string-copy-borrowed (struct-get result fallback))))

;: Read `path`, returning fresh active-arena contents on success or a borrow of
;: `fallback` on any structured read error.
(define (read-file-or-result
  [path : (& path str)]
  [fallback : (& fallback str)]) : (ReadFileOrResult fallback)
  (let
    [result : (ReadFileOrResult fallback)
      (read-file-or-borrowed-result fallback)]
    (begin
      (match (io.try-read-file path)
        [(io.OkIoString contents)
          (set! result (read-file-or-owned-result-like fallback contents))]
        [(io.ErrIoString _) unit])
      result)))

;: Inline test helper that forces an IO caller-result test failure.
(define (io-caller-result-test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test assertion for owned string equality.
(define (io-caller-result-test-string-eq [actual : String] [expected : String]) : unit
  (if (string.string-eq actual expected)
    unit
    (io-caller-result-test-fail)))

(test
  io-caller-result-api
  (let
    [fallback : String "fallback"]
    [owned : String "contents"]
    [missing-path : String "target/stdlib-inline-io-caller-result-missing.txt"]
    [direct : (ReadFileOrResult fallback)
      (read-file-or-result (& missing-path) (& fallback))]
    [manual-owned : (ReadFileOrResult fallback)
      (read-file-or-owned-result-like (& fallback) owned)]
    [manual-borrowed : (ReadFileOrResult fallback)
      (read-file-or-borrowed-result (& fallback))]
    (begin
      (if (read-file-or-result-borrowed? direct)
        unit
        (io-caller-result-test-fail))
      (if (read-file-or-result-owned? manual-owned)
        unit
        (io-caller-result-test-fail))
      (if (read-file-or-result-borrowed? manual-borrowed)
        unit
        (io-caller-result-test-fail))
      (io-caller-result-test-string-eq
        (read-file-or-result-string direct)
        "fallback")
      (io-caller-result-test-string-eq
        (read-file-or-result-string manual-owned)
        "contents"))))

(export
  (value read-file-or-result-borrowed?)
  (value read-file-or-result-owned?)
  (value read-file-or-borrowed-result)
  (value read-file-or-owned-result-like)
  (value read-file-or-result-string)
  (value read-file-or-result)
  (type ReadFileOrResult)
  (constructor ReadFileOrResult)
  (field ReadFileOrResult fallback)
  (field ReadFileOrResult owned)
  (field ReadFileOrResult is-owned))