;; Nested `string.append` chains lower to the runtime's fixed
;; `tl_string_concat3` / `4` / `5` exports, which take six to ten arguments.
;; Linked against a prebuilt libstdlib.a, the raw export symbol is the Win64
;; platform entry bridge, so the call must keep the platform convention: its
;; fifth and later arguments travel on the stack, not in RSI/RDI.
(import stdlib.io)
(import stdlib.string)

(define (join3 [a : (& a str)] [b : (& b str)] [c : (& c str)]) : String
  (string.append (string.append a b) c))

(define (join4 [a : (& a str)] [b : (& b str)] [c : (& c str)] [d : (& d str)]) : String
  (string.append (string.append (string.append a b) c) d))

(define (join5
  [a : (& a str)]
  [b : (& b str)]
  [c : (& c str)]
  [d : (& d str)]
  [e : (& e str)]) : String
  (string.append (string.append (string.append (string.append a b) c) d) e))

(define (main) : i64
  (let
    [root : String (string.copy "root")]
    [three : String (join3 (& root) "/" "leaf")]
    [four : String (join4 (& root) "/" "dir" "/")]
    [five : String (join5 (& root) "/" "dir" "/" "leaf.tl")]
    (io.print "{},{},{}\n" three four five)
    (if (and
      (string.eq three "root/leaf")
      (string.eq four "root/dir/")
      (string.eq five "root/dir/leaf.tl"))
      42
      1)))