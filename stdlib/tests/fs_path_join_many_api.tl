;# Runnable coverage for the `fs-path-join-many` variadic path join macro.
;# Exercises zero, single, two, three, four, and duplicate-separator joins.
;# Exits 42 on success.
(import stdlib.fs)

(import stdlib.string)

(import stdlib.test)

(define (fs-path-join-many-api-assert
  [got : String]
  [want : String]
  [message : String]) : unit
  (test.assert-string-eq (& got) (& want) message))

(define (fs-path-join-many-api-expected3 [a : String] [b : String] [c : String]) : String
  (string.string-append
    (string.string-append (string.string-append a (fs.fs-path-separator)) b)
    (string.string-append (fs.fs-path-separator) c)))

(define (fs-path-join-many-api-expected4
  [a : String]
  [b : String]
  [c : String]
  [d : String]) : String
  (string.string-append
    (fs-path-join-many-api-expected3 a b c)
    (string.string-append (fs.fs-path-separator) d)))

(define (main) : i64
  (begin
    (fs-path-join-many-api-assert
      (fs.fs-path-join-many)
      ""
      "fs-path-join-many zero")
    (fs-path-join-many-api-assert
      (fs.fs-path-join-many "solo")
      "solo"
      "fs-path-join-many one")
    (fs-path-join-many-api-assert
      (fs.fs-path-join-many "left path" "right file")
      (string.string-append
        (string.string-append "left path" (fs.fs-path-separator))
        "right file")
      "fs-path-join-many two")
    (fs-path-join-many-api-assert
      (fs.fs-path-join-many "left" "middle" "right")
      (fs-path-join-many-api-expected3 "left" "middle" "right")
      "fs-path-join-many three")
    (fs-path-join-many-api-assert
      (fs.fs-path-join-many "left" "middle" "right" "leaf")
      (fs-path-join-many-api-expected4 "left" "middle" "right" "leaf")
      "fs-path-join-many four")
    (fs-path-join-many-api-assert
      (fs.fs-path-join-many "left/" "/right" "leaf")
      (string.string-append "left/right" (string.string-append (fs.fs-path-separator) "leaf"))
      "fs-path-join-many duplicate separator")
    42))