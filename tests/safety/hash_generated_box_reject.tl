(import stdlib.hash)

(defstruct UnsupportedHashKey
  (value i64)
  (indirect (Box i64)))

(import (hash.hash UnsupportedHashKey) as unsupported_hash)

(define (main) : i64
  (unsupported_hash.hash (UnsupportedHashKey 1 (box 2))))