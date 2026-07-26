(import private_intrinsic_provenance_provider as provider)
(import private_intrinsic_provenance_shadow_provider as shadow-provider)

;; These caller-owned definitions must shadow direct calls without capturing
;; identically spelled intrinsic calls in the imported provider's bodies.
(define (__tl_float_sqrt [value : i64]) : i64
  value)

(define (__tl_float_to_bits [value : i64]) : i64
  (+ value 1))

(define (__tl_float_from_bits [value : i64]) : i64
  (+ value 2))

(define (__tl_string_length [value : i64]) : i64
  (+ value 3))

(define (__tl_string_ref [value : i64] [index : i64]) : i64
  (+ value index))

(define (__tl_string_eq [left : i64] [right : i64]) : i64
  (+ left right))

(define (__tl_string_to_int [value : i64]) : i64
  (+ value 4))

(define (main) : i64
  (cond
    ;; Caller-local calls retain ordinary lexical resolution.
    [(not (= (__tl_float_sqrt 1) 1)) 1]
    [(not (= (__tl_float_to_bits 1) 2)) 2]
    [(not (= (__tl_float_from_bits 1) 3)) 3]
    [(not (= (__tl_string_length 1) 4)) 4]
    [(not (= (__tl_string_ref 1 2) 3)) 5]
    [(not (= (__tl_string_eq 1 2) 3)) 6]
    [(not (= (__tl_string_to_int 1) 5)) 7]
    ;; Imported bodies retain their defining-module intrinsic resolution.
    [(not (= (provider.private-sqrt 9.0) 3.0)) 8]
    [(not
        (= (provider.private-float-to-bits 1.0) (cast 0x3ff0000000000000 : u64)))
      9]
    [(not (= (provider.private-float-from-bits 0x3ff0000000000000) 1.0)) 10]
    [(not (= (provider.private-string-length "abc") 3)) 11]
    [(not (= (cast (provider.private-string-ref "abc" 1) : i64) 98)) 12]
    [(not (provider.private-string-eq "same" "same")) 13]
    [(not (= (provider.private-string-to-int "42") 42)) 14]
    ;; A definition in the imported body itself remains an ordinary shadow.
    [(not (= (shadow-provider.private-string-length-shadow 4) 104)) 15]
    [else 42]))