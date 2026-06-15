;# Lifetime-preserving I/O caller-result APIs (#1913/#1962).
;#
;# This module stays separate from `io.tl` while the compatibility wrapper keeps
;# the owned `String` API. It exposes helpers that may return caller-provided
;# fallback text without copying.
(module stdlib.io_caller_result)

(import stdlib.io as io_mod)

(import stdlib.string as string_mod)

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
  (if (stdlib.io_caller_result.read-file-or-result-owned? result)
    (struct-get result owned)
    (string_mod.string-copy-borrowed (struct-get result fallback))))

;: Read `path`, returning fresh active-arena contents on success or a borrow of
;: `fallback` on any structured read error.
(define (read-file-or-result
  [path : (& path str)]
  [fallback : (& fallback str)]) : (ReadFileOrResult fallback)
  (let
    [result : (ReadFileOrResult fallback)
      (stdlib.io_caller_result.read-file-or-borrowed-result fallback)]
    (begin
      (match (io_mod.try-read-file path)
        [(io_mod.OkIoString contents)
          (set!
            result
            (stdlib.io_caller_result.read-file-or-owned-result-like
              fallback
              contents))]
        [(io_mod.ErrIoString _) unit])
      result)))

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
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