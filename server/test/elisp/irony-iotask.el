;; -*-no-byte-compile: t; -*-
(load (concat (file-name-directory (or load-file-name
                                       buffer-file-name))
              "test-config"))

;; load irony-iotask
;;
;; XXX: No idea why this is necessary, test-config already adds the directory to
;; the load-path so irony is found...
(unless (require 'irony-iotask nil t)
  (let ((irony-iotask-dir (expand-file-name "../../.." test-dir)))
    (add-to-list 'load-path irony-iotask-dir)
    (require 'irony-iotask)))

;; Note: these tests use process communication with the standard I/O streams.
;; The subprocess used for this communication is Emacs.
;;
;; The following article provides useful information for using Elisp as a
;; scripting language, Emacs as an interpreter, it details how the standard I/O
;; streams works in Elisp scripts:
;; - http://www.lunaryorn.com/2014/08/12/emacs-script-pitfalls.html

(defmacro irony-iotask/with-elisp-process-setup (process-script
                                                 &rest body)
  "Start an Emacs process that runs the given PROCESS-SCRIPT.

The process is setup with `irony-iotask-setup-process'.

It's possible to schedule some iotasks in the BODY for testing.

There is an exposed variable named `process' available for use in
BODY.

Elisp is used as a scripting language because it should be
available on all OSes irony-iotask support."
  (declare (indent 1))
  `(let ((process-connection-type nil)
         (process-adaptive-read-buffering nil)
         process)
     (setq process
           (start-process "emacs-irony-test"
                          "*emacs-irony-test*"
                          (expand-file-name invocation-name
                                            invocation-directory)
                          "-Q"
                          "--batch"
                          "--eval"
                          (prin1-to-string (quote ,process-script))))
     (unwind-protect
         (progn
           (irony-iotask-setup-process process)
           ,@body)
       ;; for the tests, we want to wait the end of the process
       (while (process-live-p process)
         (sit-for 0.05)))))

(defmacro irony-iotask/with-echo-process-setup (&rest body)
  (declare (indent 1))
  `(irony-iotask/with-elisp-process-setup
    (message (read-from-minibuffer ""))
    ,@body))

;; irony-iotask-result

(ert-deftest irony-iotask-result/ready-p-value ()
  (let ((result (irony-iotask-result-create)))
    (should-not (irony-iotask-result-valid-p result))
    (irony-iotask-result-set-value result 1)
    (should (irony-iotask-result-valid-p result))))

(ert-deftest irony-iotask-result/ready-p-error ()
  (let ((result (irony-iotask-result-create)))
    (should-not (irony-iotask-result-valid-p result))
    (irony-iotask-result-set-error result 'irony-iotask-error (list "blah"))
    (should (irony-iotask-result-valid-p result))))

(ert-deftest irony-iotask-result/set-value ()
  (let ((result (irony-iotask-result-create)))
    (irony-iotask-result-set-value result 'blah)
    (should (eq (irony-iotask-result-get result) 'blah))))

(define-error 'irony-iotask-result/test-error "Irony I/O task sample error")

(ert-deftest irony-iotask-result/set-error ()
  (let ((result (irony-iotask-result-create)))
    (irony-iotask-result-set-error result 'irony-iotask-result/test-error)
    (should-error (irony-iotask-result-get result)
                  :type 'irony-iotask-result/test-error)))

(ert-deftest irony-iotask-result/set-error-data ()
  (let ((result (irony-iotask-result-create)))
    (irony-iotask-result-set-error result
                                   'irony-iotask-result/test-error
                                   'foo 'bar 'baz 'qux)
    (condition-case err
        (irony-iotask-result-get result)
      (irony-iotask-result/test-error
       (should (equal (cdr err) '(foo bar baz qux)))))))

(ert-deftest irony-iotask-result/get-empty ()
  (let ((result (irony-iotask-result-create)))
    (should-error (irony-iotask-result-get result)
                  :type 'irony-iotask-result-get-error)))

;; pdata

(ert-deftest irony-iotask/enqueue ()
  (let ((pdata (irony-iotask-pdata-create)))
    (dolist (v '(1 2 3))
      (irony-iotask-pdata-enqueue pdata v))
    (should (equal 1 (pop (irony-iotask-pdata-queue pdata))))
    (should (equal 2 (pop (irony-iotask-pdata-queue pdata))))
    (should (equal 3 (pop (irony-iotask-pdata-queue pdata))))
    (should-not (pop (irony-iotask-pdata-queue pdata)))))

;; filter

(ert-deftest irony-iotask/filter-spurious-message ()
  (let ((pdata (irony-iotask-pdata-create)))
    (should-error (irony-iotask-filter pdata "spurious message\n")
                  :type 'irony-iotask-filter-error)))

;; task

(irony-iotask-define-task irony-iotask/task-start-t
  "doc"
  :start (lambda (ectx &optional value)
           (irony-iotask-ectx-set-result ectx (or value 42))))

(ert-deftest irony-iotask/task-start/simple ()
  (let ((task (irony-iotask-package-task irony-iotask/task-start-t)))
    (irony-iotask/with-elisp-process-setup
     () ;; no-op
     (should (equal 42 (irony-iotask-run process task))))))

(ert-deftest irony-iotask/task-start/with-arguments ()
  (let ((task (irony-iotask-package-task irony-iotask/task-start-t 43)))
    (irony-iotask/with-elisp-process-setup
     () ;; no-op
     (should (equal 43 (irony-iotask-run process task))))))

(irony-iotask-define-task irony-iotask/task-update-t
  "doc"
  :start (lambda (ectx &optional hello)
           (irony-iotask-ectx-write-string ectx
                                           (format "%s\n" (or hello "hello"))))
  :update (lambda (ectx bytes &optional hello)
            (setq hello (or hello "hello"))
            (cond
             ((string= bytes (format "%s\n" hello))
              (irony-iotask-ectx-set-result ectx (format "%s ok" hello)))
             ((>= (length bytes) (1+ (length hello)))
              (throw 'invalid-msg t)))))

(ert-deftest irony-iotask-schedule/task-update/simple ()
  (let ((task (irony-iotask-package-task irony-iotask/task-update-t)))
    (irony-iotask/with-echo-process-setup
     (should (string= "hello ok" (irony-iotask-run process task))))))

(ert-deftest irony-iotask-schedule/task-update/with-arguments ()
  (let ((task (irony-iotask-package-task irony-iotask/task-update-t "bonjour")))
    (irony-iotask/with-echo-process-setup
     (should (string= "bonjour ok" (irony-iotask-run process task))))))

(ert-deftest irony-iotask-schedule/task-update/invalid-msg ()
  (let ((task (irony-iotask-package-task irony-iotask/task-update-t)))
    (irony-iotask/with-elisp-process-setup
     (progn
       (read-from-minibuffer "")
       (message "spurious-output"))
     (should-error (irony-iotask-run process task)
                   :type 'irony-iotask-bad-data))))
