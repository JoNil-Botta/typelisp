(defstruct L0
  (:lifetimes r)
  (value (& r i64)))

(defstruct L1
  (:lifetimes r)
  (value (Tuple (L0 r) (L0 r))))

(defstruct L2
  (:lifetimes r)
  (value (Tuple (L1 r) (L1 r))))

(defstruct L3
  (:lifetimes r)
  (value (Tuple (L2 r) (L2 r))))

(defstruct L4
  (:lifetimes r)
  (value (Tuple (L3 r) (L3 r))))

(defstruct L5
  (:lifetimes r)
  (value (Tuple (L4 r) (L4 r))))

(defstruct L6
  (:lifetimes r)
  (value (Tuple (L5 r) (L5 r))))

(defstruct L7
  (:lifetimes r)
  (value (Tuple (L6 r) (L6 r))))

(defstruct L8
  (:lifetimes r)
  (value (Tuple (L7 r) (L7 r))))

(defstruct L9
  (:lifetimes r)
  (value (Tuple (L8 r) (L8 r))))

(defstruct L10
  (:lifetimes r)
  (value (Tuple (L9 r) (L9 r))))

(defstruct L11
  (:lifetimes r)
  (value (Tuple (L10 r) (L10 r))))

(defstruct L12
  (:lifetimes r)
  (value (Tuple (L11 r) (L11 r))))

(defstruct L13
  (:lifetimes r)
  (value (Tuple (L12 r) (L12 r))))

(defstruct L14
  (:lifetimes r)
  (value (Tuple (L13 r) (L13 r))))

(defstruct L15
  (:lifetimes r)
  (value (Tuple (L14 r) (L14 r))))

(defstruct L16
  (:lifetimes r)
  (value (Tuple (L15 r) (L15 r))))

(defstruct L17
  (:lifetimes r)
  (value (Tuple (L16 r) (L16 r))))

(defstruct L18
  (:lifetimes r)
  (value (Tuple (L17 r) (L17 r))))

(defstruct L19
  (:lifetimes r)
  (value (Tuple (L18 r) (L18 r))))

(defstruct L20
  (:lifetimes r)
  (value (Tuple (L19 r) (L19 r))))

(defstruct L21
  (:lifetimes r)
  (value (Tuple (L20 r) (L20 r))))

(defstruct L22
  (:lifetimes r)
  (value (Tuple (L21 r) (L21 r))))

(defstruct L23
  (:lifetimes r)
  (value (Tuple (L22 r) (L22 r))))

(defstruct L24
  (:lifetimes r)
  (value (Tuple (L23 r) (L23 r))))

(defstruct L25
  (:lifetimes r)
  (value (Tuple (L24 r) (L24 r))))

(defstruct L26
  (:lifetimes r)
  (value (Tuple (L25 r) (L25 r))))

(defstruct L27
  (:lifetimes r)
  (value (Tuple (L26 r) (L26 r))))

(defstruct L28
  (:lifetimes r)
  (value (Tuple (L27 r) (L27 r))))

(defstruct L29
  (:lifetimes r)
  (value (Tuple (L28 r) (L28 r))))

(defstruct L30
  (:lifetimes r)
  (value (Tuple (L29 r) (L29 r))))

(defstruct L31
  (:lifetimes r)
  (value (Tuple (L30 r) (L30 r))))

(defstruct L32
  (:lifetimes r)
  (value (Tuple (L31 r) (L31 r))))

(defstruct L33
  (:lifetimes r)
  (value (Tuple (L32 r) (L32 r))))

(defstruct L34
  (:lifetimes r)
  (value (Tuple (L33 r) (L33 r))))

(defstruct L35
  (:lifetimes r)
  (value (Tuple (L34 r) (L34 r))))

(defstruct L36
  (:lifetimes r)
  (value (Tuple (L35 r) (L35 r))))

(defstruct L37
  (:lifetimes r)
  (value (Tuple (L36 r) (L36 r))))

(defstruct L38
  (:lifetimes r)
  (value (Tuple (L37 r) (L37 r))))

(defstruct L39
  (:lifetimes r)
  (value (Tuple (L38 r) (L38 r))))

(defstruct L40
  (:lifetimes r)
  (value (Tuple (L39 r) (L39 r))))

(define (shorten [x : (L40 program)] [q : (& q i64)]) : (L40 q)
  x)

(define (main) : i64
  0)