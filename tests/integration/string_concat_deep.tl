;; string_concat_deep.tl - deep string concat trees stay bounded in the lowerer.
;;
;; Keep both associativity directions at sixteen leaves through the public
;; stdlib surface; the lowerer must not rebuild this tree recursively.
(import stdlib.string)

(define (left-nested) : String
  (string.append
    (string.append
      (string.append
        (string.append
          (string.append
            (string.append
              (string.append
                (string.append
                  (string.append
                    (string.append
                      (string.append
                        (string.append
                          (string.append
                            (string.append (string.append "a" "b") "c")
                            "d")
                          "e")
                        "f")
                      "g")
                    "h")
                  "i")
                "j")
              "k")
            "l")
          "m")
        "n")
      "o")
    "p"))

(define (right-nested) : String
  (string.concat
    "a"
    (string.concat
      "b"
      (string.concat
        "c"
        (string.concat
          "d"
          (string.concat
            "e"
            (string.concat
              "f"
              (string.concat
                "g"
                (string.concat
                  "h"
                  (string.concat
                    "i"
                    (string.concat
                      "j"
                      (string.concat
                        "k"
                        (string.concat
                          "l"
                          (string.concat
                            "m"
                            (string.concat "n" (string.concat "o" "p"))))))))))))))))

(define (main) : i64
  (let
    [left : String (left-nested)]
    [right : String (right-nested)]
    (if (and
      (string.eq left "abcdefghijklmnop")
      (string.eq right "abcdefghijklmnop"))
      42
      1)))