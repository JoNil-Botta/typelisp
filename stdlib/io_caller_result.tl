;# Lifetime-preserving I/O caller-result APIs (#1913/#1962).
;#
;# This module stays separate from `io.tl` while the compatibility wrapper keeps
;# the owned `String` API. It exposes helpers that may return caller-provided
;# fallback text without copying.
(import "io.tl")

(import "string.tl")

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
    (string-copy-borrowed (struct-get result fallback))))

;: Read `path`, returning fresh active-arena contents on success or a borrow of
;: `fallback` on any structured read error.
(define (read-file-or-result
  [path : (& path str)]
  [fallback : (& fallback str)]) : (ReadFileOrResult fallback)
  (let
    [result : (ReadFileOrResult fallback)
      (read-file-or-borrowed-result fallback)]
    (begin
      (match (try-read-file path)
        [(OkIoString contents)
          (set! result (read-file-or-owned-result-like fallback contents))]
        [(ErrIoString _) unit])
      result)))