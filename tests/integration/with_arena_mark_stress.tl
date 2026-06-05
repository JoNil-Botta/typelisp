(extern tl_region_mark : (-> u64))

(define (scoped-once [n : i64]) : i64
  (with-arena
    scratch
    (let
      [left : String (string-append "arena:" (int->string n))]
      [right : String (string-append left ":tail")]
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
    (if (= before after)
      (if (> total 0)
        (if (= (string-length anchor) 9)
          42
          3)
        2)
      1)))
