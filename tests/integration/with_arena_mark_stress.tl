(import "stdlib/core_macros.tl" module stdlib.core_macros as core)

(import "stdlib/string.tl")

(extern (tl_region_mark) : u64)

(define (scoped-once [n : i64]) : i64
  (with-arena
    scratch
    (let
      [prefix : String "arena:"]
      [suffix : String (int->string n)]
      [left : String (string-append-borrowed (& prefix) (& suffix))]
      [tail : String ":tail"]
      [right : String (string-append-borrowed (& left) (& tail))]
      (string-length right))))

(define (scoped-loop [n : i64] [acc : i64]) : i64
  (if (= n 0)
    acc
    (scoped-loop (- n 1) (+ acc (scoped-once n)))))

(define (main) : i64
  (let
    [anchor : String (string-append "keep" "alive")]
    [before : u64 (tl_region_mark)]
    [total : i64 (scoped-loop 2000 0)]
    [after : u64 (tl_region_mark)]
    (begin
      (core/unless (= before after) (return 1))
      (core/unless (> total 0) (return 2))
      (core/unless (= (string-length anchor) 9) (return 3))
      42)))