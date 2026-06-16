(import "stdlib/list.tl")
(import "stdlib/test.tl")
(import "stdlib/vector.tl")

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (assert-string-eq (& actual) (& expected) message))

(define (assert-string-list-empty [items : StringList] [message : String]) : unit
  (match items
    [(StringNil) unit]
    [_ (panic message)]))

(define (assert-string-list1
  [items : StringList]
  [first : String]
  [message : String]) : unit
  (match items
    [(StringCons a rest)
      (match (box-get rest)
        [(StringNil) (assert-owned-string-eq a first message)]
        [_ (panic message)])]
    [_ (panic message)]))

(define (assert-string-list3
  [items : StringList]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match items
    [(StringCons a rest)
      (match (box-get rest)
        [(StringCons b more)
          (match (box-get more)
            [(StringCons c tail)
              (match (box-get tail)
                [(StringNil)
                  (begin
                    (assert-owned-string-eq a first message)
                    (assert-owned-string-eq b second message)
                    (assert-owned-string-eq c third message))]
                [_ (panic message)])]
            [_ (panic message)])]
        [_ (panic message)])]
    [_ (panic message)]))

(define (assert-string-list4
  [items : StringList]
  [first : String]
  [second : String]
  [third : String]
  [fourth : String]
  [message : String]) : unit
  (match items
    [(StringCons a rest)
      (match (box-get rest)
        [(StringCons b more)
          (match (box-get more)
            [(StringCons c tail)
              (match (box-get tail)
                [(StringCons d end)
                  (match (box-get end)
                    [(StringNil)
                      (begin
                        (assert-owned-string-eq a first message)
                        (assert-owned-string-eq b second message)
                        (assert-owned-string-eq c third message)
                        (assert-owned-string-eq d fourth message))]
                    [_ (panic message)])]
                [_ (panic message)])]
            [_ (panic message)])]
        [_ (panic message)])]
    [_ (panic message)]))

(define (assert-string-array3
  [items : (Array String)]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (begin
    (assert-i64-eq (array-length items) 3 message)
    (assert-owned-string-eq (array-ref items 0) first message)
    (assert-owned-string-eq (array-ref items 1) second message)
    (assert-owned-string-eq (array-ref items 2) third message)))

(define (assert-string-vec3
  [items : StringVec]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (begin
    (assert-i64-eq (string-vec-len items) 3 message)
    (assert-owned-string-eq (string-vec-get items 0 "missing") first message)
    (assert-owned-string-eq (string-vec-get items 1 "missing") second message)
    (assert-owned-string-eq (string-vec-get items 2 "missing") third message)))

(define (make-source-array) : (Array String)
  (let
    [items : (Array String) (make-array String 4)]
    (begin
      (array-set! items 0 "red")
      (array-set! items 1 "green")
      (array-set! items 2 "blue")
      (array-set! items 3 "ignored")
      items)))

(define (main) : i64
  (let
    [built : StringList
      (string-list-builder-build
        (string-list-builder-push
          (string-list-builder-push
            (string-list-builder-push (string-list-builder-empty) "alpha")
            "beta")
          "gamma"))]
    [source : (Array String) (make-source-array)]
    (begin
      (assert-string-list-empty (string-list-empty) "string-list empty")
      (assert-string-list1
        (string-list-single "one")
        "one"
        "string-list single")
      (assert-i64-eq
        (string-list-count (string-list-empty))
        0
        "string-list empty count")
      (assert-i64-eq
        (string-list-builder-count
          (string-list-builder-push (string-list-builder-empty) "one"))
        1
        "builder count")
      (assert-i64-eq (string-list-count built) 3 "string-list built count")
      (assert-string-list3 built "alpha" "beta" "gamma" "builder order")
      (assert-string-list3
        (string-list-reverse
          (string-list-cons
            "third"
            (string-list-cons "second" (string-list-single "first"))))
        "first"
        "second"
        "third"
        "reverse order")
      (assert-string-list3
        (string-list-append
          (string-list-cons "left" (string-list-single "middle"))
          (string-list-single "right"))
        "left"
        "middle"
        "right"
        "append order")
      (assert-true
        (string-list-contains? built "beta")
        "contains reports existing item")
      (assert-false
        (string-list-contains? built "delta")
        "contains reports missing item")
      (assert-string-list3
        (string-list-builder-build-onto
          (string-list-builder-push (string-list-builder-empty) "head")
          (string-list-cons "tail1" (string-list-single "tail2")))
        "head"
        "tail1"
        "tail2"
        "build onto")
      (assert-string-list3
        (string-list-from-array source 3)
        "red"
        "green"
        "blue"
        "from array")
      (assert-string-list4
        (string-list-from-array source 99)
        "red"
        "green"
        "blue"
        "ignored"
        "from array clamp")
      (assert-string-list-empty
        (string-list-from-array source -1)
        "from array negative")
      (assert-string-array3
        (string-list-to-array built)
        "alpha"
        "beta"
        "gamma"
        "to array")
      (assert-string-vec3
        (string-list-to-vec built)
        "alpha"
        "beta"
        "gamma"
        "to vec")
      (assert-string-list3
        (string-list-from-vec (string-list-to-vec built))
        "alpha"
        "beta"
        "gamma"
        "from vec")
      42)))