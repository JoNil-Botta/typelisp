;; Mutable pointer type alone does not prove a valid atomic i32 write target.
(import stdlib.runtime)

(define (main) : unit
  (runtime.atomic-i32-store-ptr! (ptr-null : (MutPtr i32)) (cast 0 : i32)))