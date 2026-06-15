(import stdlib.env)

(import stdlib.test)

(import stdlib.vector)

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test.assert-string-eq (& actual) (& expected) message))

(define (assert-env-none [value : env.EnvMaybeString] [message : String]) : unit
  (match value
    [(env.EnvNoString) unit]
    [(env.EnvSomeString _) (panic message)]))

(define (assert-env-some
  [value : env.EnvMaybeString]
  [expected : String]
  [message : String]) : unit
  (match value
    [(env.EnvSomeString actual) (assert-owned-string-eq actual expected message)]
    [(env.EnvNoString) (panic message)]))

(define (assert-env-path-none [value : env.EnvMaybeStringList] [message : String]) : unit
  (match value
    [(env.EnvNoStringList) unit]
    [(env.EnvSomeStringList _) (panic message)]))

(define (assert-env-path-vec-none
  [value : env.EnvMaybeStringVec]
  [message : String]) : unit
  (match value
    [(env.EnvNoStringVec) unit]
    [(env.EnvSomeStringVec _) (panic message)]))

(define (assert-env-path-empty [value : env.EnvMaybeStringList] [message : String]) : unit
  (match value
    [(env.EnvSomeStringList items)
      (match items
        [(env.EnvStringNil) unit]
        [_ (panic message)])]
    [(env.EnvNoStringList) (panic message)]))

(define (assert-env-path-vec-empty
  [value : env.EnvMaybeStringVec]
  [message : String]) : unit
  (match value
    [(env.EnvSomeStringVec items) (test.assert-i64-eq (vector.string-vec-len items) 0 message)]
    [(env.EnvNoStringVec) (panic message)]))

(define (assert-env-list3
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
                    (assert-owned-string-eq a first message)
                    (assert-owned-string-eq b second message)
                    (assert-owned-string-eq c third message))]
                [_ (panic message)])]
            [_ (panic message)])]
        [_ (panic message)])]
    [_ (panic message)]))

(define (assert-env-list5
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
                            (assert-owned-string-eq a first message)
                            (assert-owned-string-eq b second message)
                            (assert-owned-string-eq c third message)
                            (assert-owned-string-eq d fourth message)
                            (assert-owned-string-eq e fifth message))]
                        [_ (panic message)])]
                    [_ (panic message)])]
                [_ (panic message)])]
            [_ (panic message)])]
        [_ (panic message)])]
    [_ (panic message)]))

(define (assert-env-vec3
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

(define (assert-env-vec5
  [items : vector.StringVec]
  [first : String]
  [second : String]
  [third : String]
  [fourth : String]
  [fifth : String]
  [message : String]) : unit
  (begin
    (test.assert-i64-eq (vector.string-vec-len items) 5 message)
    (assert-owned-string-eq (vector.string-vec-get items 0 "missing") first message)
    (assert-owned-string-eq (vector.string-vec-get items 1 "missing") second message)
    (assert-owned-string-eq (vector.string-vec-get items 2 "missing") third message)
    (assert-owned-string-eq (vector.string-vec-get items 3 "missing") fourth message)
    (assert-owned-string-eq (vector.string-vec-get items 4 "missing") fifth message)))

(define (assert-env-path3
  [value : env.EnvMaybeStringList]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match value
    [(env.EnvSomeStringList items)
      (assert-env-list3 items first second third message)]
    [(env.EnvNoStringList) (panic message)]))

(define (assert-env-path-vec3
  [value : env.EnvMaybeStringVec]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match value
    [(env.EnvSomeStringVec items)
      (assert-env-vec3 items first second third message)]
    [(env.EnvNoStringVec) (panic message)]))

(define (main) : i64
  (begin
    (let
      [name : String "TYPELISP_STDLIB_TEST_MISSING_854"]
      (assert-env-none (env.env-get (& name)) "env missing"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_EMPTY"]
      (assert-env-some (env.env-get (& name)) "" "env empty"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_VALUE"]
      (assert-env-some (env.env-get (& name)) "env-value-854" "env value"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_MISSING_854"]
      (assert-env-path-none (env.env-path-list (& name)) "env path missing"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_MISSING_854"]
      (assert-env-path-vec-none
        (env.env-path-list-vec (& name))
        "env path vec missing"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_EMPTY"]
      (assert-env-path-empty (env.env-path-list (& name)) "env path empty"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_EMPTY"]
      (assert-env-path-vec-empty
        (env.env-path-list-vec (& name))
        "env path vec empty"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_PATH"]
      (assert-env-path3
        (env.env-path-list (& name))
        "one"
        "two"
        "three"
        "env path list"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_PATH"]
      (assert-env-path-vec3
        (env.env-path-list-vec (& name))
        "one"
        "two"
        "three"
        "env path vec"))
    (let
      [value : String (env.env-var-value "TYPELISP_STDLIB_TEST_PATH")]
      (assert-owned-string-eq
        (env.env-path-join (env.env-path-split (& value)))
        value
        "env path join"))
    (let
      [value : String (env.env-var-value "TYPELISP_STDLIB_TEST_PATH")]
      (assert-owned-string-eq
        (env.env-path-join-vec (env.env-path-split-vec (& value)))
        value
        "env path vec join"))
    (let
      [value : String "a;b;;c;"]
      [separator : String ";"]
      (assert-env-list5
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
      (assert-env-vec5
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
      (assert-owned-string-eq
        (env.env-path-join-with-separator
          (env.env-path-split-with-separator (& value) (& separator))
          (& separator))
        value
        "env semicolon join"))
    (let
      [value : String "a;b;;c;"]
      [separator : String ";"]
      (assert-owned-string-eq
        (env.env-path-join-vec-with-separator
          (env.env-path-split-with-separator-vec (& value) (& separator))
          (& separator))
        value
        "env semicolon join vec"))
    42))