;# Runnable coverage for the `fs-path-join-many` variadic path join macro.
;# Exercises zero, single, two, three, four, and duplicate-separator joins.
;# Exits 42 on success.
(import "stdlib/fs.tl")
(import "stdlib/string.tl")
(import "stdlib/test.tl")

(define (fs-path-join-many-api-assert
  [got : String]
  [want : String]
  [message : String]) : unit
  (assert-string-eq (& got) (& want) message))

(define (fs-path-join-many-api-expected3 [a : String] [b : String] [c : String]) : String
  (string-append
    (string-append (string-append a (fs-path-separator)) b)
    (string-append (fs-path-separator) c)))

(define (fs-path-join-many-api-expected4
  [a : String]
  [b : String]
  [c : String]
  [d : String]) : String
  (string-append
    (fs-path-join-many-api-expected3 a b c)
    (string-append (fs-path-separator) d)))

(define (main) : i64
  (begin
    (fs-path-join-many-api-assert
      (fs-path-join-many)
      ""
      "fs-path-join-many zero")
    (fs-path-join-many-api-assert
      (fs-path-join-many "solo")
      "solo"
      "fs-path-join-many one")
    (fs-path-join-many-api-assert
      (fs-path-join-many "left path" "right file")
      (string-append
        (string-append "left path" (fs-path-separator))
        "right file")
      "fs-path-join-many two")
    (fs-path-join-many-api-assert
      (fs-path-join-many "left" "middle" "right")
      (fs-path-join-many-api-expected3 "left" "middle" "right")
      "fs-path-join-many three")
    (fs-path-join-many-api-assert
      (fs-path-join-many "left" "middle" "right" "leaf")
      (fs-path-join-many-api-expected4 "left" "middle" "right" "leaf")
      "fs-path-join-many four")
    (fs-path-join-many-api-assert
      (fs-path-join-many "left/" "/right" "leaf")
      (string-append "left/right" (string-append (fs-path-separator) "leaf"))
      "fs-path-join-many duplicate separator")
    42))