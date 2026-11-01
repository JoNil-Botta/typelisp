;; A lambda created inside `with-arena` snapshots its `String` capture into
;; that arena; a borrow of the snapshot returned out of the form outlives the
;; rewound copy. Main returned 7 instead of 42 (#9297).
(import stdlib.string)

(define (main) : i64
  (let
    [s : String (string.int->string 1234567890123)]
    [v : (& s str)
      (with-arena
        tmp
        ; Must fail: `(& s)` borrows the lambda's copy of `s`.
        (let
          [f
            (lambda () : (& s str)
              (& s))]
          (f)))]
    [_junk1 : String (string.int->string 9999999999999)]
    [_junk2 : String (string.int->string 8888888888888)]
    (if (string.eq v "1234567890123")
      42
      7)))