(import stdlib.list)

(import stdlib.test)

(import stdlib.vector)

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test.assert-string-eq (& actual) (& expected) message))

(define (assert-string-list-empty [items : list.StringList] [message : String]) : unit
  (match items
    [(list.StringNil) unit]
    [_ (panic message)]))

(define (assert-string-list1
  [items : list.StringList]
  [first : String]
  [message : String]) : unit
  (match items
    [(list.StringCons a rest)
      (match (box-get rest)
        [(list.StringNil) (assert-owned-string-eq a first message)]
        [_ (panic message)])]
    [_ (panic message)]))

(define (assert-string-list3
  [items : list.StringList]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match items
    [(list.StringCons a rest)
      (match (box-get rest)
        [(list.StringCons b more)
          (match (box-get more)
            [(list.StringCons c tail)
              (match (box-get tail)
                [(list.StringNil)
                  (begin
                    (assert-owned-string-eq a first message)
                    (assert-owned-string-eq b second message)
                    (assert-owned-string-eq c third message))]
                [_ (panic message)])]
            [_ (panic message)])]
        [_ (panic message)])]
    [_ (panic message)]))

(define (assert-string-list4
  [items : list.StringList]
  [first : String]
  [second : String]
  [third : String]
  [fourth : String]
  [message : String]) : unit
  (match items
    [(list.StringCons a rest)
      (match (box-get rest)
        [(list.StringCons b more)
          (match (box-get more)
            [(list.StringCons c tail)
              (match (box-get tail)
                [(list.StringCons d end)
                  (match (box-get end)
                    [(list.StringNil)
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
    (test.assert-i64-eq (array-length items) 3 message)
    (assert-owned-string-eq (array-ref items 0) first message)
    (assert-owned-string-eq (array-ref items 1) second message)
    (assert-owned-string-eq (array-ref items 2) third message)))

(define (assert-string-vec3
  [items : vector.StringVec]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (begin
    (test.assert-i64-eq (vector.string-vec-len items) 3 message)
    (assert-owned-string-eq (vector.string-vec-get items 0 "missing") first message)
    (assert-owned-string-eq (vector.string-vec-get items 1 "missing") second message)
    (assert-owned-string-eq (vector.string-vec-get items 2 "missing") third message)))

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
    [built : list.StringList
      (list.string-list-builder-build
        (list.string-list-builder-push
          (list.string-list-builder-push
            (list.string-list-builder-push (list.string-list-builder-empty) "alpha")
            "beta")
          "gamma"))]
    [source : (Array String) (make-source-array)]
    (begin
      (assert-string-list-empty (list.string-list-empty) "string-list empty")
      (assert-string-list1
        (list.string-list-single "one")
        "one"
        "string-list single")
      (test.assert-i64-eq
        (list.string-list-count (list.string-list-empty))
        0
        "string-list empty count")
      (test.assert-i64-eq
        (list.string-list-builder-count
          (list.string-list-builder-push (list.string-list-builder-empty) "one"))
        1
        "builder count")
      (test.assert-i64-eq (list.string-list-count built) 3 "string-list built count")
      (assert-string-list3 built "alpha" "beta" "gamma" "builder order")
      (assert-string-list3
        (list.string-list-reverse
          (list.string-list-cons
            "third"
            (list.string-list-cons "second" (list.string-list-single "first"))))
        "first"
        "second"
        "third"
        "reverse order")
      (assert-string-list3
        (list.string-list-append
          (list.string-list-cons "left" (list.string-list-single "middle"))
          (list.string-list-single "right"))
        "left"
        "middle"
        "right"
        "append order")
      (test.assert-true
        (list.string-list-contains? built "beta")
        "contains reports existing item")
      (test.assert-false
        (list.string-list-contains? built "delta")
        "contains reports missing item")
      (assert-string-list3
        (list.string-list-builder-build-onto
          (list.string-list-builder-push (list.string-list-builder-empty) "head")
          (list.string-list-cons "tail1" (list.string-list-single "tail2")))
        "head"
        "tail1"
        "tail2"
        "build onto")
      (assert-string-list3
        (list.string-list-from-array source 3)
        "red"
        "green"
        "blue"
        "from array")
      (assert-string-list4
        (list.string-list-from-array source 99)
        "red"
        "green"
        "blue"
        "ignored"
        "from array clamp")
      (assert-string-list-empty
        (list.string-list-from-array source -1)
        "from array negative")
      (assert-string-array3
        (list.string-list-to-array built)
        "alpha"
        "beta"
        "gamma"
        "to array")
      (assert-string-vec3
        (list.string-list-to-vec built)
        "alpha"
        "beta"
        "gamma"
        "to vec")
      (assert-string-list3
        (list.string-list-from-vec (list.string-list-to-vec built))
        "alpha"
        "beta"
        "gamma"
        "from vec")
      42)))