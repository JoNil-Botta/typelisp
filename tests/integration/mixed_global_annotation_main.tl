(import "mixed_global_annotation_provider.tl")
(import "mixed_global_annotation_bridge.tl")

(define (main) : i64
  (+ 1 (mixed-global-annotation-bridge)))