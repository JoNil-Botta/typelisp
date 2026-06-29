(import stdlib.serialize)
(import
  "serialize_missing_object_hook_format.tl"
  module serialize_missing_object_hook_format
  as bad)

(defstruct Sample
  (name String))

(import (serialize.serialize bad Sample) as sample_ser)

(define (main) : i64
  0)
