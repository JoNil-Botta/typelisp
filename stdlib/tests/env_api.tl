(import stdlib.env)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)

(define (env-api-assert-true [condition : bool] [message : String]) : unit
  (if condition
    unit
    (io.panic message)))

(define (env-api-assert-i64-eq
  [actual : i64]
  [expected : i64]
  [message : String]) : unit
  (env-api-assert-true (= actual expected) message))

(define (env-api-assert-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (env-api-assert-true (string.string-eq actual expected) message))

(define (env-api-assert-none [value : env.EnvMaybeString] [message : String]) : unit
  (match value
    [(env.EnvNoString) unit]
    [(env.EnvSomeString _) (io.panic message)]))

(define (env-api-assert-some
  [value : env.EnvMaybeString]
  [expected : String]
  [message : String]) : unit
  (match value
    [(env.EnvSomeString actual)
      (env-api-assert-string-eq actual expected message)]
    [(env.EnvNoString) (io.panic message)]))

(define (env-api-assert-path-none
  [value : env.EnvMaybeStringList]
  [message : String]) : unit
  (match value
    [(env.EnvNoStringList) unit]
    [(env.EnvSomeStringList _) (io.panic message)]))

(define (env-api-assert-path-vec-none
  [value : env.EnvMaybeStringVec]
  [message : String]) : unit
  (match value
    [(env.EnvNoStringVec) unit]
    [(env.EnvSomeStringVec _) (io.panic message)]))

(define (env-api-assert-path-empty
  [value : env.EnvMaybeStringList]
  [message : String]) : unit
  (match value
    [(env.EnvSomeStringList items)
      (match items
        [(env.EnvStringNil) unit]
        [_ (io.panic message)])]
    [(env.EnvNoStringList) (io.panic message)]))

(define (env-api-assert-path-vec-empty
  [value : env.EnvMaybeStringVec]
  [message : String]) : unit
  (match value
    [(env.EnvSomeStringVec items)
      (env-api-assert-i64-eq (vector.string-vec-len items) 0 message)]
    [(env.EnvNoStringVec) (io.panic message)]))

(define (env-api-assert-list3
  [items : env.EnvStringList]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match items
    [(env.EnvStringCons a rest)
      (match (box-get rest)
        [(env.EnvStringCons b tail)
          (match (box-get tail)
            [(env.EnvStringCons c end)
              (match (box-get end)
                [(env.EnvStringNil)
                  (begin
                    (env-api-assert-string-eq a first message)
                    (env-api-assert-string-eq b second message)
                    (env-api-assert-string-eq c third message))]
                [_ (io.panic message)])]
            [_ (io.panic message)])]
        [_ (io.panic message)])]
    [_ (io.panic message)]))

(define (env-api-assert-list5
  [items : env.EnvStringList]
  [first : String]
  [second : String]
  [third : String]
  [fourth : String]
  [fifth : String]
  [message : String]) : unit
  (match items
    [(env.EnvStringCons a rest)
      (match (box-get rest)
        [(env.EnvStringCons b rest2)
          (match (box-get rest2)
            [(env.EnvStringCons c rest3)
              (match (box-get rest3)
                [(env.EnvStringCons d rest4)
                  (match (box-get rest4)
                    [(env.EnvStringCons e end)
                      (match (box-get end)
                        [(env.EnvStringNil)
                          (begin
                            (env-api-assert-string-eq a first message)
                            (env-api-assert-string-eq b second message)
                            (env-api-assert-string-eq c third message)
                            (env-api-assert-string-eq d fourth message)
                            (env-api-assert-string-eq e fifth message))]
                        [_ (io.panic message)])]
                    [_ (io.panic message)])]
                [_ (io.panic message)])]
            [_ (io.panic message)])]
        [_ (io.panic message)])]
    [_ (io.panic message)]))

(define (env-api-assert-vec3
  [items : vector.StringVec]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (begin
    (env-api-assert-i64-eq (vector.string-vec-len items) 3 message)
    (env-api-assert-string-eq
      (vector.string-vec-get items 0 "missing")
      first
      message)
    (env-api-assert-string-eq
      (vector.string-vec-get items 1 "missing")
      second
      message)
    (env-api-assert-string-eq
      (vector.string-vec-get items 2 "missing")
      third
      message)))

(define (env-api-assert-vec5
  [items : vector.StringVec]
  [first : String]
  [second : String]
  [third : String]
  [fourth : String]
  [fifth : String]
  [message : String]) : unit
  (begin
    (env-api-assert-i64-eq (vector.string-vec-len items) 5 message)
    (env-api-assert-string-eq
      (vector.string-vec-get items 0 "missing")
      first
      message)
    (env-api-assert-string-eq
      (vector.string-vec-get items 1 "missing")
      second
      message)
    (env-api-assert-string-eq
      (vector.string-vec-get items 2 "missing")
      third
      message)
    (env-api-assert-string-eq
      (vector.string-vec-get items 3 "missing")
      fourth
      message)
    (env-api-assert-string-eq
      (vector.string-vec-get items 4 "missing")
      fifth
      message)))

(define (env-api-assert-path3
  [value : env.EnvMaybeStringList]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match value
    [(env.EnvSomeStringList items)
      (env-api-assert-list3 items first second third message)]
    [(env.EnvNoStringList) (io.panic message)]))

(define (env-api-assert-path-vec3
  [value : env.EnvMaybeStringVec]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match value
    [(env.EnvSomeStringVec items)
      (env-api-assert-vec3 items first second third message)]
    [(env.EnvNoStringVec) (io.panic message)]))

(test
  env-api
  (begin
    (let
      [name : String "TYPELISP_STDLIB_TEST_MISSING_854"]
      (env-api-assert-none (env.env-get (& name)) "env missing"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_EMPTY"]
      (match (env.env-get (& name))
        [(env.EnvSomeString actual)
          (begin
            (env-api-assert-string-eq actual "" "env empty")
            (env-api-assert-path-empty
              (env.env-path-list (& name))
              "env path empty")
            (env-api-assert-path-vec-empty
              (env.env-path-list-vec (& name))
              "env path vec empty"))]
        [(env.EnvNoString) unit]))
    (let
      [name : String "TYPELISP_STDLIB_TEST_VALUE"]
      (env-api-assert-some (env.env-get (& name)) "env-value-854" "env value"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_MISSING_854"]
      (env-api-assert-path-none (env.env-path-list (& name)) "env path missing"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_MISSING_854"]
      (env-api-assert-path-vec-none
        (env.env-path-list-vec (& name))
        "env path vec missing"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_PATH"]
      (env-api-assert-path3
        (env.env-path-list (& name))
        "one"
        "two"
        "three"
        "env path list"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_PATH"]
      (env-api-assert-path-vec3
        (env.env-path-list-vec (& name))
        "one"
        "two"
        "three"
        "env path vec"))
    (let
      [value : String (env.env-var-value "TYPELISP_STDLIB_TEST_PATH")]
      (env-api-assert-string-eq
        (env.env-path-join (env.env-path-split (& value)))
        value
        "env path join"))
    (let
      [value : String (env.env-var-value "TYPELISP_STDLIB_TEST_PATH")]
      (env-api-assert-string-eq
        (env.env-path-join-vec (env.env-path-split-vec (& value)))
        value
        "env path vec join"))
    (let
      [value : String "a;b;;c;"]
      [separator : String ";"]
      (env-api-assert-list5
        (env.env-path-split-with-separator (& value) (& separator))
        "a"
        "b"
        ""
        "c"
        ""
        "env semicolon split"))
    (let
      [value : String "a;b;;c;"]
      [separator : String ";"]
      (env-api-assert-vec5
        (env.env-path-split-with-separator-vec (& value) (& separator))
        "a"
        "b"
        ""
        "c"
        ""
        "env semicolon split vec"))
    (let
      [value : String "a;b;;c;"]
      [separator : String ";"]
      (env-api-assert-string-eq
        (env.env-path-join-with-separator
          (env.env-path-split-with-separator (& value) (& separator))
          (& separator))
        value
        "env semicolon join"))
    (let
      [value : String "a;b;;c;"]
      [separator : String ";"]
      (env-api-assert-string-eq
        (env.env-path-join-vec-with-separator
          (env.env-path-split-with-separator-vec (& value) (& separator))
          (& separator))
        value
        "env semicolon join vec"))
    unit))