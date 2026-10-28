(import stdlib.arena)
(import stdlib.string)

(defenum Parsed
  (Ok i64)
  (Err String))

(defenum Word
  (Ok String)
  (Err i64))

(defenum MaybeText
  (Some String)
  (None))

(defenum Words
  (Ok i64)
  (Err (Array i64 2)))

(defenum Empty
  (Ok i64)
  (Err (Array String 0)))

(define (scalar-return [n : i64]) : i64
  (with-arena
    outer
    (with-arena
      inner
      (let
        [text (string.int->string n)]
        (return (string.string-length text)))))
  0)

(define (outer-return [n : i64]) : String
  (let
    [text (string.int->string n)]
    (with-arena phase (return text))
    ""))

(define (program-return [text : (in program String)]) : (in program String)
  (with-arena phase (return text))
  "")

(define (input-return [owner : (arena.Arena source)]) : (in source String)
  (with-arena phase (return (in-arena owner (string.append "caller" "-owned"))))
  (in-arena owner (string.append "unused" "")))

(define (parse [n : i64]) : Parsed
  (if (> n 0)
    (Parsed.Ok n)
    (Parsed.Err (string.int->string n))))

(define (outer-try [n : i64]) : Parsed
  (let
    [result (parse n)]
    [value : i64 (with-arena phase (try result))]
    (Parsed.Ok value)))

(define (read-word [n : i64]) : Word
  (if (> n 0)
    (Word.Ok (string.int->string n))
    (Word.Err n)))

(define (scalar-try [n : i64]) : Word
  (let
    [length : i64
      (with-arena
        phase
        (let
          [text (try (read-word n))]
          (string.string-length text)))]
    (Word.Ok (string.int->string length))))

(define (maybe-text [present : bool]) : MaybeText
  (if present
    (MaybeText.Some (string.append "four" ""))
    MaybeText.None))

(define (option-try [present : bool]) : MaybeText
  (let
    [length : i64
      (with-arena
        phase
        (let
          [text (try (maybe-text present))]
          (string.string-length text)))]
    (MaybeText.Some (string.int->string length))))

(define (word-array [n : i64]) : Words
  (Words.Err (array n (+ n 1))))

(define (array-try [n : i64]) : Words
  (let
    [value : i64 (with-arena phase (try (word-array n)))]
    (Words.Ok value)))

(define (empty-array) : Empty
  (Empty.Err (make-array String 0)))

(define (empty-try) : Empty
  (let
    [value : i64 (with-arena phase (try (empty-array)))]
    (Empty.Ok value)))

(define (main) : i64
  (unless (= (scalar-return -12345) 6) (return 1))
  (unless (= (string.string-length (outer-return -12345)) 6) (return 2))
  (unless (= (string.string-length (program-return "program")) 7) (return 3))
  (let
    [owner (arena.make)]
    [text (input-return owner)]
    (unless (= (string.string-length text) 12) (return 4)))
  (match (outer-try -12345)
    [(Parsed.Ok _) (return 5)]
    [(Parsed.Err text) (unless (= (string.string-length text) 6) (return 6))])
  (match (outer-try 7)
    [(Parsed.Ok n) (unless (= n 7) (return 7))]
    [(Parsed.Err _) (return 8)])
  (match (scalar-try -9)
    [(Word.Ok _) (return 9)]
    [(Word.Err n) (unless (= n -9) (return 10))])
  (match (scalar-try 9)
    [(Word.Ok text) (unless (string.eq (& text) "1") (return 11))]
    [(Word.Err _) (return 12)])
  (match (option-try false)
    [(MaybeText.Some _) (return 13)]
    [(MaybeText.None) unit])
  (match (option-try true)
    [(MaybeText.Some text) (unless (string.eq (& text) "4") (return 14))]
    [(MaybeText.None) (return 15)])
  (match (array-try 41)
    [(Words.Ok _) (return 16)]
    [(Words.Err items)
      (unless (= (+ (array-ref items 0) (array-ref items 1)) 83) (return 17))])
  (match (empty-try)
    [(Empty.Ok _) (return 18)]
    [(Empty.Err items) (unless (= (array-length items) 0) (return 19))])
  42)