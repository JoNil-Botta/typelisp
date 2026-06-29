(import stdlib.serialize)
(import "serialize_missing_sequence_hook_format.tl" module serialize_missing_sequence_hook_format as bad)

(defstruct Sample
  (items (Array i64 2)))

(import (serialize.serialize bad Sample) as sample_ser)

(define (main) : i64
  0)