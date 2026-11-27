;; Integration coverage for inline 16-byte `{data_ptr, length}` String and ZII (#7962).
(import stdlib.string)
(import stdlib.io)
(import stdlib.iterator)

(defstruct Record
  (tag i64)
  (name String)
  (note String))

(defenum Entry
  (Empty String i64)
  (Tagged String))

(define empty-global : String
  "")
(define const-global : String
  "hello-global")
(define runtime-global : String
  (string.append "run" "time"))

(define (check-empty [s : (& s str)]) : bool
  (let
    [copied : String (string.copy s)]
    [sub : String (string.substring s 0 0)]
    [left : String (string.append s "ok")]
    [right : String (string.append "ok" s)]
    [c (io.c-string s)]
    (and
      (= (string.string-length s) 0)
      (string.eq s "")
      (string.eq (& copied) "")
      (string.eq (& sub) "")
      (string.eq (& left) "ok")
      (string.eq (& right) "ok")
      (string.contains s "")
      (not (string.contains s "a"))
      (= (string.index-of-byte s 0 (cast 97 : u8)) -1)
      (= (string.string-length (string.trim-view s)) 0)
      (= (length c) 1)
      (= (array-ref c 0) 0))))

(define (join-many
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (let
    [ab : String (string.append (& a) (& b))]
    [de : String (string.append (& d) (& e))]
    [cde : String (string.append (& c) (& de))]
    (string.append (& ab) (& cde))))

(define (overwrite-record-name! [slot : (&mut slot Record)] [next : String]) : unit
  (set! (deref slot).name next))

(define (main) : i64
  (when (not (= (comptime (size-of (type String))) 16)) (return 1))
  (when (not (= (comptime (align-of (type String))) 8)) (return 2))
  ;; 1. Zero-initialized fixed array of String.
  (let
    [fixed : (Array String 4) (make-array String 4)]
    (for [i (iterator.range 0 4)]
      (when (not (check-empty (& (array-ref fixed i)))) (return 3)))
    (set! (array-ref fixed 2) "two")
    (when (not (string.eq (& (array-ref fixed 2)) "two")) (return 4))
    (when (not (check-empty (& (array-ref fixed 1)))) (return 5)))
  ;; 2. Zero-initialized struct containing String fields.
  (let
    [recs : (Array Record 3) (make-array Record 3)]
    (for [i (iterator.range 0 3)]
      (when (not (= (array-ref recs i).tag 0)) (return 6))
      (when (not (check-empty (& (array-ref recs i).name))) (return 7))
      (when (not (check-empty (& (array-ref recs i).note))) (return 8)))
    (set! (array-ref recs 1) (Record 7 "alice" ""))
    (when (not (= (array-ref recs 1).tag 7)) (return 9))
    (when (not (string.eq (& (array-ref recs 1).name) "alice")) (return 10))
    (when (not (check-empty (& (array-ref recs 1).note))) (return 11)))
  ;; 3. Zero-initialized enum with String payload in first variant.
  (let
    [entries : (Array Entry 2) (make-array Entry 2)]
    (for [i (iterator.range 0 2)]
      (match (& (array-ref entries i))
        [(Empty s n) (when (not (and (= n 0) (check-empty s))) (return 12))]
        [(Tagged _) (return 13)]))
    (set! (array-ref entries 0) (Tagged "filled"))
    (match (& (array-ref entries 0))
      [(Tagged s) (when (not (string.eq s "filled")) (return 14))]
      [(Empty _ _) (return 15)]))
  ;; 4. Globals: empty, constant non-empty, runtime-initialized.
  (when (not (check-empty (& empty-global))) (return 16))
  (when (not (string.eq (& const-global) "hello-global")) (return 17))
  (when (not (string.eq (& runtime-global) "runtime")) (return 18))
  ;; 5. Loop-enclosed (& s str) borrows + &mut Record field write + rvalue auto-borrow.
  (let
    [acc : String ""]
    [rec : Record (Record 1 "" "")]
    [i : i64 0]
    (while (< i 4)
      (when (not (= (string.string-length (& acc)) i)) (return 19))
      (set! acc (string.append (& acc) "x"))
      (overwrite-record-name! (&mut rec) (string.copy (& acc)))
      (+= i 1))
    (when (not (string.eq (& acc) "xxxx")) (return 20))
    (when (not (string.eq (& rec.name) "xxxx")) (return 25))
    (when (not (check-empty "")) (return 21))
    (when (not (string.eq (string.append "a" "b") "ab")) (return 22)))
  ;; 6. Multi-argument 2-word String ABI (registers + stack args) and closure capture.
  (let
    [joined : String (join-many "a" "" "bc" "d" "ef")]
    [captured : String (string.copy (& joined))]
    [f : (-> String)
      (lambda () : String
        (string.append (& captured) "!"))]
    [out : String (f)]
    (when (not (string.eq (& joined) "abcdef")) (return 23))
    (when (not (string.eq (& out) "abcdef!")) (return 24)))
  42)