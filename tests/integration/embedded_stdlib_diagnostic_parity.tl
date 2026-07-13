;; Source-root and embedded stdlib modes must report this error identically.
(import stdlib.string)

(define wrong : i64
  (string.string-length 42))