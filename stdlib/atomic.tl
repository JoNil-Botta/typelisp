;# stdlib/atomic.tl - Explicit sequentially consistent integer atomics.
;#
;# This module exposes the first safe overlap-tolerant SPMD write surface:
;# atomic operations on one dynamic-array element. Helpers are limited to `i32`
;# and `i64`, have sequentially consistent ordering, and synchronize only the
;# exact addressed element. Ordinary `array-set!` remains non-atomic.
;#
;# Usage: `(import stdlib.atomic)`
;#
;# ```typelisp
;# (import stdlib.atomic)
;#
;# (define (add-counts [ix : (Array i64)] [out : (Array i64)] [n : i64]) : unit
;#   (foreach
;#     ([i : i64 0 n])
;#     (atomic.atomic-i64-add! out (array-ref ix i) 1)))
;# ```
(module stdlib.atomic)

;: Sequentially consistent atomic load of one `i64` array element.
(extern (atomic-i64-load [items : (Array i64)] [index : i64]) : i64 (:symbol "tl_atomic_i64_load"))

;: Sequentially consistent atomic store of one `i64` array element.
(extern (atomic-i64-store! [items : (Array i64)] [index : i64] [value : i64]) : unit (:symbol "tl_atomic_i64_store"))

;: Sequentially consistent atomic add to one `i64` array element.
(extern (atomic-i64-add! [items : (Array i64)] [index : i64] [delta : i64]) : unit (:symbol "tl_atomic_i64_add"))

;: Sequentially consistent atomic fetch-add of one `i64` array element.
(extern (atomic-i64-fetch-add!
  [items : (Array i64)]
  [index : i64]
  [delta : i64]) : i64 (:symbol "tl_atomic_i64_fetch_add"))

;: Sequentially consistent atomic load of one `i32` array element.
(extern (atomic-i32-load [items : (Array i32)] [index : i64]) : i32 (:symbol "tl_atomic_i32_load"))

;: Sequentially consistent atomic store of one `i32` array element.
(extern (atomic-i32-store! [items : (Array i32)] [index : i64] [value : i32]) : unit (:symbol "tl_atomic_i32_store"))

;: Sequentially consistent atomic add to one `i32` array element.
(extern (atomic-i32-add! [items : (Array i32)] [index : i64] [delta : i32]) : unit (:symbol "tl_atomic_i32_add"))

;: Sequentially consistent atomic fetch-add of one `i32` array element.
(extern (atomic-i32-fetch-add!
  [items : (Array i32)]
  [index : i64]
  [delta : i32]) : i32 (:symbol "tl_atomic_i32_fetch_add"))

(export
  (value atomic-i64-load)
  (value atomic-i64-store!)
  (value atomic-i64-add!)
  (value atomic-i64-fetch-add!)
  (value atomic-i32-load)
  (value atomic-i32-store!)
  (value atomic-i32-add!)
  (value atomic-i32-fetch-add!))