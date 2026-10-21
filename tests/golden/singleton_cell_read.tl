;; Dump-only width controls include unsafe reads wider than their cell. Native
;; behavior, aliases and evaluation order live in integration/singleton_cell_read.
(defmacro (cell-read [value : Expr] [ty : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-cast (__tl_array-data (array ,value)) : (Ptr ,ty)))))

(defstruct Pair
  (a i64)
  (b i64))

(defstruct Word
  (value i64))

(defstruct Padded
  (small u8)
  (large i64))

(define (admit-integer [value : i64])
  (:export-symbol "admit_integer") : u64
  (cell-read value u64))

(define (admit-pointer [value : (Ptr i64)])
  (:export-symbol "admit_pointer") : u64
  (cell-read value u64))

(define (admit-reference [value : (& value i64)])
  (:export-symbol "admit_reference") : u64
  (cell-read value u64))

(define (admit-mut-reference [value : (&mut value i64)])
  (:export-symbol "admit_mut_reference") : (MutPtr i64)
  (cell-read value (MutPtr i64)))

(define (admit-aggregate-reference [value : (& value Pair)])
  (:export-symbol "admit_aggregate_reference") : (Ptr Pair)
  (cell-read value (Ptr Pair)))

(define (admit-string [value : String])
  (:export-symbol "admit_string") : String
  (cell-read value String))

(define (admit-string-reference [value : String])
  (:export-symbol "admit_string_reference") : String
  (cell-read (& value) String))

(define (admit-array [value : (__tl_dyn-array i64)])
  (:export-symbol "admit_array") : (__tl_dyn-array i64)
  (cell-read value (__tl_dyn-array i64)))

(define (admit-array-reference [value : (& value (__tl_dyn-array i64))])
  (:export-symbol "admit_array_reference") : (__tl_dyn-array i64)
  (cell-read value (__tl_dyn-array i64)))

(define (admit-box [value : (Box i64)])
  (:export-symbol "admit_box") : (Box i64)
  (cell-read value (Box i64)))

(define (admit-float [value : f64])
  (:export-symbol "admit_float") : u64
  (cell-read value u64))

(define (admit-bits [value : u64])
  (:export-symbol "admit_bits") : f64
  (cell-read value f64))

(define (outer-read [value : (& value i64)])
  (:export-symbol "outer_read") : i64
  (unsafe
    (ptr-read (cell-read value (Ptr i64)))))

(define (fallback-slice [value : (& value (Slice i64))])
  (:export-symbol "fallback_slice") : (& value (Slice i64))
  (cell-read value (& value (Slice i64))))

(define (fallback-mut-slice [value : (&mut value (Slice i64))])
  (:export-symbol "fallback_mut_slice") : (&mut value (Slice i64))
  (cell-read value (&mut value (Slice i64))))

(define (fallback-bytes [value : (& value bytes)])
  (:export-symbol "fallback_bytes") : (& value bytes)
  (cell-read value (& value bytes)))

(define (fallback-word [value : Word])
  (:export-symbol "fallback_word") : i64
  (cell-read value i64))

(define (fallback-pair [value : Pair])
  (:export-symbol "fallback_pair") : i64
  (cell-read value i64))

(define (fallback-padded [value : Padded])
  (:export-symbol "fallback_padded") : i64
  (cell-read value i64))

(define (fallback-function [value : (-> i64 i64)])
  (:export-symbol "fallback_function") : u64
  (cell-read value u64))

(define (fallback-narrow [value : i32])
  (:export-symbol "fallback_narrow") : i32
  (cell-read value i32))

(define (fallback-partial [value : i64])
  (:export-symbol "fallback_partial") : u8
  (cell-read value u8))

(define (fallback-wide [value : i32])
  (:export-symbol "fallback_wide") : i64
  (cell-read value i64))

(define (fallback-wide-result [value : i64])
  (:export-symbol "fallback_wide_result") : Pair
  (cell-read value Pair))

(define (fallback-unit [value : unit])
  (:export-symbol "fallback_unit") : unit
  (unsafe
    (ptr-read (ptr-cast (__tl_array-data (array value)) : (Ptr unit)))))

(define (fallback-many [value : i64])
  (:export-symbol "fallback_many") : i64
  (unsafe
    (ptr-read (ptr-cast (__tl_array-data (array value 42)) : (Ptr i64)))))

(define (fallback-offset [value : i64])
  (:export-symbol "fallback_offset") : i64
  (unsafe
    (ptr-read
      (ptr-cast (ptr-offset (__tl_array-data (array value 42)) 1) : (Ptr i64)))))

(define (fallback-saved [value : i64])
  (:export-symbol "fallback_saved") : i64
  (let
    [cell : (Array i64 1) (array value)]
    [address : (MutPtr i64)
      (unsafe
        (__tl_array-data cell))]
    (unsafe
      (ptr-write! address 42)
      (ptr-read (ptr-cast address : (Ptr i64))))))

(define (main) : i64
  42)