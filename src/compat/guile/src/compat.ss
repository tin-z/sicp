;;; Copyright 2020 Mitchell Kember. Subject to the MIT License.

#!r6rs

(library (src compat)
  (export current-output-port extended-define-syntax format make-mutex
          open-output-string parallel-execute parameterize random
          run-with-short-timeout runtime seed-rng string-contains?
          syntax->location with-output-to-string)
  (import (rnrs base (6))
          (only (guile)
                *random-state* current-output-port gettimeofday
                open-output-string parameterize random
                random-state-from-platform source-property string-contains
                syntax-source with-output-to-string usleep)
          (only (ice-9 threads)
                call-with-new-thread cancel-thread join-thread lock-mutex
                unlock-mutex)
          (only (system syntax) syntax-sourcev)
          (prefix (only (guile) format) guile-)
          (prefix (only (ice-9 threads) make-mutex) guile-))

;; Guile does not support the `(define-syntax (foo x) ...)` syntax.
(define-syntax extended-define-syntax
  (syntax-rules ()
    ((_ (name x) e* ...) (define-syntax name (lambda (x) e* ...)))
    ((_ e* ...) (define-syntax e* ...))))

(define (syntax->location s)
  ;; For some reason Guile 3.0.8 drops source information for lists in syntax
  ;; objects. To work around this, we get the source location of the first atom
  ;; instead, and fake the column number assuming the atom is on the same line.
  (let loop ((s s) (col-delta 0))
    (if (pair? s)
        (loop (car s) (- col-delta 1))
        (let ((source (syntax-sourcev s)))
          (if source
              (values (vector-ref source 0)
                      (+ 1 (vector-ref source 1))
                      (+ 1 col-delta (vector-ref source 2)))
              ;; In some rare cases there is no syntax information.
              (values "unknown" 0 0))))))

(define (format . args)
  (apply guile-format #f args))

(define (runtime)
  (let ((t (gettimeofday)))
    (+ (car t) (/ (cdr t) 1e6))))

(define (seed-rng)
  (set! *random-state* (random-state-from-platform)))

(define (string-contains? s1 s2)
  (number? (string-contains s1 s2)))

(define (make-mutex)
  (let ((mutex (guile-make-mutex)))
    (lambda (op)
      (cond ((eq? op 'acquire) (lock-mutex mutex))
            ((eq? op 'release) (unlock-mutex mutex))
            (else (error 'make-mutex "unknown operation" op))))))

(define (parallel-execute . thunks)
  (define (spawn proc)
    (call-with-new-thread
     (lambda ()
       ;; Sleep for up to 1ms to ensure nondeterminism shows up.
       (usleep (random 1000))
       (proc))))
  (for-each join-thread (map spawn thunks)))

(define (run-with-short-timeout thunk)
  (let* ((result '())
         (thread (call-with-new-thread
                  (lambda () (set! result (list (thunk)))))))
    (usleep 1000)
    (cancel-thread thread)
    result))

) ; end of library
