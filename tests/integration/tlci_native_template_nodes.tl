;; Differential corpus for the template node kinds that became native tlci
;; entries in #5605: `return` and `box`/`box-get` inside the `stdlib.json`
;; decode/sequence hooks, a float literal inside `stdlib.math/abs`, and
;; `(set! (struct-get ...) ...)` inside `stdlib.text_buf/append!`. The
;; compile-profile gate compiles this file through the embedded (native) and
;; the source (interpreted) macro routes and requires byte-identical assembly,
;; so any divergence in the reconstructed nodes fails the build.
(import stdlib.json)
(import stdlib.math)
(import stdlib.serialize)
(import stdlib.string)
(import stdlib.text_buf)

(defstruct Sample
  (label String)
  (count i64)
  (active bool)
  (marks (Array i64 3)))

(import (serialize.serialize json Sample) as sample_json)

;; `math/abs` expands a float literal inside a quasiquoted `let`.
(define (abs-score [value : f64]) : f64
  (math.abs value))

;; `text_buf/append!` expands `(set! (struct-get ,buf chunks) ...)` twice.
(define (label-of [sample : Sample]) : String
  (let
    [buf : text_buf.TextBuf (text_buf.empty)]
    (begin
      (text_buf.append! buf (struct-get sample label))
      (text_buf.append! buf "!")
      (text_buf.render buf))))

;; Encoding drives object-field/object-finish/sequence-element/sequence-finish
;; (the `box` template kind); decoding drives expect-object/field-value/
;; decode-bool/decode-string/sequence-length/sequence-element-value (the
;; `return` and `box-get` template kinds).
(define (round-trip [sample : Sample]) : i64
  (match (sample_json.decode (sample_json.encode sample))
    [(sample_json.Ok decoded)
      (if (and
        (string.eq (struct-get decoded label) (struct-get sample label))
        (and
          (= (struct-get decoded count) (struct-get sample count))
          (= (struct-get decoded active) (struct-get sample active))))
        (array-ref (struct-get decoded marks) 2)
        -1)]
    [(sample_json.Err _) -2]))

(define (main) : i64
  (let
    [marks : (Array i64 3) (array 1 2 3)]
    [sample : Sample (Sample "tag" 7 true marks)]
    [rendered : String (label-of sample)]
    (if (and
      (string.eq rendered "tag!")
      (and (= (round-trip sample) 3) (= (abs-score -1.5) 1.5)))
      42
      1)))