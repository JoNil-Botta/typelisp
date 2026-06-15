;# Lifetime-preserving string caller-result APIs (#1913/#1962).
;#
;# This module stays separate from `string.tl` while the compatibility wrapper
;# keeps the owned `String` API. It exposes helpers that may return
;# caller-provided text without copying.
(module stdlib.string_caller_result)

(import stdlib.string as string_mod)

;: Result for lifetime-preserving string replacement.
;:
;: `borrowed` is tied to the input text lifetime. The result also
;: conservatively carries the `old` and `new` caller lifetimes because the
;: current checker cannot yet prove the owned replacement branch is independent
;: of those owned string arguments.
(defstruct StringReplaceResult
  (:lifetimes text old replacement)
  (borrowed (& text str))
  (old-text (& old str))
  (replacement-text (& replacement str))
  (owned String)
  (is-owned bool))

;: True when `result` carries the caller input text borrow.
(define (string-replace-result-borrowed?
  [result : (StringReplaceResult text old replacement)]) : bool
  (not (struct-get result is-owned)))

;: True when `result` carries owned replacement output.
(define (string-replace-result-owned?
  [result : (StringReplaceResult text old replacement)]) : bool
  (struct-get result is-owned))

;: Construct a no-match replacement result that borrows the caller input text.
(define (string-replace-borrowed-result
  [text : (& text str)]
  [old : (& old str)]
  [new : (& replacement str)]) : (StringReplaceResult text old replacement)
  (let
    [empty : String ""]
    (StringReplaceResult text old new empty false)))

;: Construct an owned replacement result while preserving caller lifetimes.
(define (string-replace-owned-result-like
  [text : (& text str)]
  [old : (& old str)]
  [new : (& replacement str)]
  [owned : String]) : (StringReplaceResult text old replacement)
  (StringReplaceResult text old new owned true))

;: Materialize a result as an owned `String`. Borrowed branches are copied at
;: this explicit compatibility boundary.
(define (string-replace-result-string
  [result : (StringReplaceResult text old replacement)]) : String
  (if (stdlib.string_caller_result.string-replace-result-owned? result)
    (struct-get result owned)
    (string_mod.substring-borrowed
      (struct-get result borrowed)
      0
      (string-length (struct-get result borrowed)))))

;: Return the first index of `old` in `s`, or `-1` when no match is present.
(define (string-replace-find-index [s : (& s str)] [old : (& old str)]) : i64
  (let
    [hlen : i64 (string-length s)]
    [olen : i64 (string-length old)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (<= i (- hlen olen)))
        (let
          [j : i64 0]
          [ok : bool true]
          (begin
            (while (and ok (< j olen))
              (if (string_mod.char-eq (string-ref s (+ i j)) (string-ref old j))
                (set! j (+ j 1))
                (set! ok false)))
            (if ok
              (set! found true)
              (set! i (+ i 1))))))
      (if found
        i
        -1))))

;: Build owned replacement text for a known match at `index`.
(define (string-replace-owned-at
  [s : (& s str)]
  [old : (& old str)]
  [new : (& replacement str)]
  [index : i64]) : String
  (let
    [hlen : i64 (string-length s)]
    [olen : i64 (string-length old)]
    [prefix : String (string_mod.substring-borrowed s 0 index)]
    [prefix-new : String (string_mod.string-append-borrowed (& prefix) new)]
    [suffix : String
      (string_mod.substring-borrowed s (+ index olen) (- (- hlen index) olen))]
    (string_mod.string-append prefix-new suffix)))

;: Replace the first occurrence of `old` in `text`, returning a no-match borrow
;: tied to `text` or fresh active-arena owned text when a replacement is made.
(define (string-replace-result
  [text : (& text str)]
  [old : (& old str)]
  [new : (& replacement str)]) : (StringReplaceResult text old replacement)
  (if (= (stdlib.string_caller_result.string-replace-find-index text old) -1)
    (stdlib.string_caller_result.string-replace-borrowed-result text old new)
    (stdlib.string_caller_result.string-replace-owned-result-like
      text
      old
      new
      (stdlib.string_caller_result.string-replace-owned-at
        text
        old
        new
        (stdlib.string_caller_result.string-replace-find-index text old)))))

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
(export
  (value string-replace-result-borrowed?)
  (value string-replace-result-owned?)
  (value string-replace-borrowed-result)
  (value string-replace-owned-result-like)
  (value string-replace-result-string)
  (value string-replace-find-index)
  (value string-replace-owned-at)
  (value string-replace-result)
  (type StringReplaceResult)
  (constructor StringReplaceResult)
  (field StringReplaceResult borrowed)
  (field StringReplaceResult old-text)
  (field StringReplaceResult replacement-text)
  (field StringReplaceResult owned)
  (field StringReplaceResult is-owned))