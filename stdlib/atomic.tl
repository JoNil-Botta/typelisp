;# stdlib/atomic.tl - Sequentially consistent integer atomic buffers.
;#
;# Atomic buffers are owned domain wrappers over private compatibility storage.
;# Public callers create an `AtomicI32Buffer` or `AtomicI64Buffer` and borrow it
;# for each operation; they never declare an unsized array. Helpers are
;# sequentially consistent, bounds checked, and synchronize only the exact
;# addressed element. Ordinary array and buffer writes remain non-atomic.
;#
;# Usage: `(import stdlib.atomic)`
;#
;# ```typelisp
;# (import stdlib.atomic)
;#
;# (define (add-counts
;#   [ix : (Array i64)]
;#   [out : (& out atomic.AtomicI64Buffer)]
;#   [n : i64]) : unit
;#   (foreach
;#     ([i : i64 0 n])
;#     (atomic.atomic-i64-add! out (array-ref ix i) 1)))
;# ```
(import stdlib.array)

;: Owned zero-initialized storage for sequentially consistent `i64` atomics.
(defstruct AtomicI64Buffer
  (slots (__tl_dyn-array i64)))

;: Owned zero-initialized storage for sequentially consistent `i32` atomics.
(defstruct AtomicI32Buffer
  (slots (__tl_dyn-array i32)))

;: Allocate `length` zero-initialized atomic `i64` elements.
(define (i64-buffer [length : i64]) : AtomicI64Buffer
  (AtomicI64Buffer (array.make-array i64 length)))

;: Allocate `length` zero-initialized atomic `i32` elements.
(define (i32-buffer [length : i64]) : AtomicI32Buffer
  (AtomicI32Buffer (array.make-array i32 length)))

;: Number of elements in an `i64` atomic buffer.
(define (i64-buffer-length [items : (& source AtomicI64Buffer)]) : i64
  (array-length (struct-get items slots)))

;: Number of elements in an `i32` atomic buffer.
(define (i32-buffer-length [items : (& source AtomicI32Buffer)]) : i64
  (array-length (struct-get items slots)))

;: Sequentially consistent atomic load of one `i64` buffer element.
(extern (atomic-i64-load [items : (& source AtomicI64Buffer)] [index : i64]) : i64 (:symbol "tl_atomic_i64_load"))

;: Sequentially consistent atomic store of one `i64` buffer element.
(extern (atomic-i64-store!
  [items : (& source AtomicI64Buffer)]
  [index : i64]
  [value : i64]) : unit (:symbol "tl_atomic_i64_store"))

;: Sequentially consistent atomic add to one `i64` buffer element.
(extern (atomic-i64-add!
  [items : (& source AtomicI64Buffer)]
  [index : i64]
  [delta : i64]) : unit (:symbol "tl_atomic_i64_add"))

;: Sequentially consistent atomic fetch-add of one `i64` buffer element.
(extern (atomic-i64-fetch-add!
  [items : (& source AtomicI64Buffer)]
  [index : i64]
  [delta : i64]) : i64 (:symbol "tl_atomic_i64_fetch_add"))

;: Sequentially consistent atomic load of one `i32` buffer element.
(extern (atomic-i32-load [items : (& source AtomicI32Buffer)] [index : i64]) : i32 (:symbol "tl_atomic_i32_load"))

;: Sequentially consistent atomic store of one `i32` buffer element.
(extern (atomic-i32-store!
  [items : (& source AtomicI32Buffer)]
  [index : i64]
  [value : i32]) : unit (:symbol "tl_atomic_i32_store"))

;: Sequentially consistent atomic add to one `i32` buffer element.
(extern (atomic-i32-add!
  [items : (& source AtomicI32Buffer)]
  [index : i64]
  [delta : i32]) : unit (:symbol "tl_atomic_i32_add"))

;: Sequentially consistent atomic fetch-add of one `i32` buffer element.
(extern (atomic-i32-fetch-add!
  [items : (& source AtomicI32Buffer)]
  [index : i64]
  [delta : i32]) : i32 (:symbol "tl_atomic_i32_fetch_add"))