(import stdlib.hash)

(defstruct UnsupportedHashKey
  (value i64)
  (indirect (Box i64)))

;; Hand-written equality lets `hash.gen` reach the unsupported field.
(define (eq-unsupported-hash-key
  [left : (& left UnsupportedHashKey)]
  [right : (& right UnsupportedHashKey)]) : bool
  (= left.value right.value))

(hash.gen UnsupportedHashKey)

(import (hash.hash UnsupportedHashKey) as unsupported_hash)

(define (main) : i64
  (unsupported_hash.hash (& (UnsupportedHashKey 1 (box 2)))))