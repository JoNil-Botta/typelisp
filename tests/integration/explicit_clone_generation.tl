;; Public `(gen-clone T)` coverage. Dependencies are generated in owner order,
;; and the acronym-bearing root proves deterministic lowercase/kebab naming.
(module explicit_clone_generation)

(import stdlib.string)
(import stdlib.clone as clone_gen)

(defstruct Leaf
  (label String)
  (rank i64))

(clone_gen.gen-clone Leaf)

(defenum Choice
  (Empty)
  (Item Leaf String))

(clone_gen.gen-clone Choice)

(defstruct HTTPPacket
  (leaf Leaf)
  (choice Choice)
  (pair (Tuple String i64))
  (fixed (Array String 2))
  (items (__tl_dyn-array String))
  (boxed (Box Leaf)))

(clone_gen.gen-clone HTTPPacket)

(define (make-packet) : HTTPPacket
  (let
    [items : (__tl_dyn-array String) (__tl_make-array String 2)]
    (begin
      (set! (array-ref items 0) (string.append "dy" "namic"))
      (set! (array-ref items 1) (string.append "ar" "ray"))
      (HTTPPacket
        (Leaf (string.append "le" "af") 7)
        (Choice.Item (Leaf (string.append "en" "um") 9) "payload")
        (tuple (string.append "tu" "ple") 11)
        (array (string.append "fi" "xed") "array")
        items
        (box (Leaf (string.append "bo" "xed") 13))))))

(define (packet-ok? [packet : (& packet HTTPPacket)]) : bool
  (and
    (string.eq packet.leaf.label "leaf")
    (= packet.leaf.rank 7)
    (match packet.choice
      [(Choice.Empty) false]
      [(Choice.Item leaf text)
        (and
          (string.eq leaf.label "enum")
          (= leaf.rank 9)
          (string.eq text "payload"))])
    (string.eq (tuple-ref packet.pair 0) "tuple")
    (= (tuple-ref packet.pair 1) 11)
    (string.eq (array-ref packet.fixed 0) "fixed")
    (string.eq (array-ref packet.fixed 1) "array")
    (string.eq (array-ref packet.items 0) "dynamic")
    (string.eq (array-ref packet.items 1) "array")
    (string.eq (deref packet.boxed).label "boxed")
    (= (deref packet.boxed).rank 13)))

(define (main) : i64
  (let
    [source : HTTPPacket (make-packet)]
    [copy : HTTPPacket (clone-http-packet (& source))]
    [copy-started-valid : bool (packet-ok? (& copy))]
    (begin
      (set! (array-ref copy.items 0) "changed")
      (set! (deref copy.boxed).rank 99)
      (if (and
        copy-started-valid
        (packet-ok? (& source))
        (string.eq (array-ref copy.items 0) "changed"))
        42
        1))))