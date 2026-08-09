;;; pimacs-agent-tests.el --- Tests for agent RPC support -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'pimacs-agent)

(defun pimacs-agent-tests--events (types)
  (let ((index 0))
    (mapcar (lambda (type)
              (list :type type :index (cl-incf index)))
            types)))

(defun pimacs-agent-tests--dispatch-events (events)
  (let (dispatched)
    (cl-letf (((symbol-function 'pimacs--dispatch)
               (lambda (_process event)
                 (push (list :event event) dispatched)))
              ((symbol-function 'pimacs--dispatch-event-batch)
               (lambda (batch)
                 (push (list :batch batch) dispatched))))
      (pimacs--dispatch-responses nil events))
    (nreverse dispatched)))

(defun pimacs-agent-tests--dispatch-sequence (types)
  (pimacs-agent-tests--dispatch-events (pimacs-agent-tests--events types)))

(defun pimacs-agent-tests--dispatch-types (dispatched)
  (mapcar (lambda (item)
            (cons (car item)
                  (mapcar (lambda (event) (plist-get event :type))
                          (if (eq (car item) :batch)
                              (cadr item)
                            (cdr item)))))
          dispatched))

(defun pimacs-agent-tests--flatten-dispatches (dispatched)
  (apply #'append
         (mapcar (lambda (item)
                   (if (eq (car item) :batch)
                       (cadr item)
                     (cdr item)))
                 dispatched)))

(ert-deftest pimacs-agent-dispatch-responses-without-batchable-events ()
  (should (equal (pimacs-agent-tests--dispatch-types
                  (pimacs-agent-tests--dispatch-sequence
                   '("message_start" "tool_start" "message_end")))
                 '((:event . ("message_start"))
                   (:event . ("tool_start"))
                   (:event . ("message_end"))))))

(ert-deftest pimacs-agent-dispatch-responses-with-one-message-update ()
  (should (equal (pimacs-agent-tests--dispatch-types
                  (pimacs-agent-tests--dispatch-sequence '("message_update")))
                 '((:batch . ("message_update"))))))

(ert-deftest pimacs-agent-dispatch-responses-batches-contiguous-message-updates ()
  (should (equal (pimacs-agent-tests--dispatch-types
                  (pimacs-agent-tests--dispatch-sequence
                   '("message_update" "message_update" "message_update")))
                 '((:batch . ("message_update" "message_update" "message_update"))))))

(ert-deftest pimacs-agent-dispatch-responses-keeps-event-boundaries ()
  (should (equal (pimacs-agent-tests--dispatch-types
                  (pimacs-agent-tests--dispatch-sequence
                   '("message_update" "message_update" "tool_start"
                     "message_update" "message_update")))
                 '((:batch . ("message_update" "message_update"))
                   (:event . ("tool_start"))
                   (:batch . ("message_update" "message_update"))))))

(ert-deftest pimacs-agent-dispatch-responses-batches-exactly-ten-updates ()
  (should (equal (pimacs-agent-tests--dispatch-types
                  (pimacs-agent-tests--dispatch-sequence
                   (make-list 10 "message_update")))
                 (list (cons :batch (make-list 10 "message_update"))))))

(ert-deftest pimacs-agent-dispatch-responses-splits-long-batches ()
  (should (equal (pimacs-agent-tests--dispatch-types
                  (pimacs-agent-tests--dispatch-sequence
                   (make-list 12 "message_update")))
                 (list (cons :batch (make-list 10 "message_update"))
                       (cons :batch (make-list 2 "message_update"))))))

(ert-deftest pimacs-agent-dispatch-responses-batches-independent-sequences ()
  (should (equal (pimacs-agent-tests--dispatch-types
                  (pimacs-agent-tests--dispatch-sequence
                   '("message_update" "message_start" "message_update"
                     "message_update" "message_end" "message_update")))
                 '((:batch . ("message_update"))
                   (:event . ("message_start"))
                   (:batch . ("message_update" "message_update"))
                   (:event . ("message_end"))
                   (:batch . ("message_update"))))))

(ert-deftest pimacs-agent-dispatch-responses-preserves-event-order ()
  (let* ((types '("message_start"
                  "message_update" "message_update"
                  "tool_start"
                  "message_update" "message_update" "message_update" "message_update"
                  "message_update" "message_update" "message_update" "message_update"
                  "message_update" "message_update" "message_update" "message_update"
                  "message_end"))
         (events (pimacs-agent-tests--events types))
         (dispatched (pimacs-agent-tests--dispatch-events events)))
    (should (equal (pimacs-agent-tests--flatten-dispatches dispatched) events))
    (should (equal (pimacs-agent-tests--dispatch-types dispatched)
                   '((:event . ("message_start"))
                     (:batch . ("message_update" "message_update"))
                     (:event . ("tool_start"))
                     (:batch . ("message_update" "message_update" "message_update"
                                "message_update" "message_update" "message_update"
                                "message_update" "message_update" "message_update"
                                "message_update"))
                     (:batch . ("message_update" "message_update"))
                     (:event . ("message_end")))))))

(ert-deftest pimacs-agent-decode-response-decodes-before-dispatch ()
  (with-temp-buffer
    (insert "{}\n{}\n")
    (let ((buffer (current-buffer))
          timeline responses)
      (cl-letf (((symbol-function 'process-buffer)
                 (lambda (_process) buffer))
                ((symbol-function 'pimacs--json-read-object)
                 (lambda ()
                   (search-forward "}")
                   (push :decode timeline)
                   (list :type "message_start" :index (length timeline))))
                ((symbol-function 'pimacs--dispatch-responses)
                 (lambda (_process decoded)
                   (setq responses decoded)
                   (push :dispatch timeline))))
        (pimacs--decode-response 'process))
      (should (equal (nreverse timeline) '(:decode :decode :dispatch)))
      (should (equal responses '((:type "message_start" :index 1)
                                 (:type "message_start" :index 2)))))))

(defmacro pimacs-agent-tests-with-event-listeners (&rest body)
  (declare (indent 0))
  `(let ((pimacs--event-listeners (make-hash-table :test 'equal))
         (pimacs--event-batch-listeners (make-hash-table :test 'equal)))
     (with-temp-buffer
       (setq-local pimacs--project-key 'test-project)
       ,@body)))

(ert-deftest pimacs-agent-event-listeners-support-multiple-subscribers ()
  (pimacs-agent-tests-with-event-listeners
    (let (calls)
      (pimacs--set-event-listener t 'pimacs
                                  (lambda (_event) (push 'all-pimacs calls)))
      (pimacs--set-event-listener t 'extension
                                  (lambda (_event) (push 'all-extension calls)))
      (pimacs--set-event-listener "test" 'pimacs
                                  (lambda (_event) (push 'event-pimacs calls)))
      (pimacs--set-event-listener "test" 'extension
                                  (lambda (_event) (push 'event-extension calls)))
      (pimacs--dispatch-event (list :type "test"))
      (should (equal (nreverse calls)
                     '(all-pimacs all-extension event-pimacs event-extension))))))

(ert-deftest pimacs-agent-event-listener-upsert-preserves-position ()
  (pimacs-agent-tests-with-event-listeners
    (let (calls)
      (pimacs--set-event-listener "test" 'pimacs
                                  (lambda (_event) (push 'old calls)))
      (pimacs--set-event-listener "test" 'extension
                                  (lambda (_event) (push 'extension calls)))
      (pimacs--set-event-listener "test" 'pimacs
                                  (lambda (_event) (push 'new calls)))
      (pimacs--dispatch-event (list :type "test"))
      (should (equal (nreverse calls) '(new extension))))))

(ert-deftest pimacs-agent-event-listener-removal-keeps-other-subscribers ()
  (pimacs-agent-tests-with-event-listeners
    (let (calls)
      (pimacs--set-event-listener "test" 'pimacs
                                  (lambda (_event) (push 'pimacs calls)))
      (pimacs--set-event-listener "test" 'extension
                                  (lambda (_event) (push 'extension calls)))
      (pimacs--remove-event-listener "test" 'pimacs)
      (pimacs--dispatch-event (list :type "test"))
      (should (equal calls '(extension))))))

(ert-deftest pimacs-agent-event-listeners-skip-killed-buffers ()
  (pimacs-agent-tests-with-event-listeners
    (let ((dead-buffer (generate-new-buffer " *pimacs-agent-test*"))
          calls)
      (unwind-protect
          (progn
            (with-current-buffer dead-buffer
              (setq-local pimacs--project-key 'test-project)
              (pimacs--set-event-listener "test" 'dead
                                          (lambda (_event) (error "must not run"))))
            (pimacs--set-event-listener "test" 'live
                                        (lambda (_event) (push 'live calls)))
            (kill-buffer dead-buffer)
            (pimacs--dispatch-event (list :type "test"))
            (should (equal calls '(live))))
        (when (buffer-live-p dead-buffer)
          (kill-buffer dead-buffer))))))

(ert-deftest pimacs-agent-batch-event-listeners-support-multiple-subscribers ()
  (pimacs-agent-tests-with-event-listeners
    (let (calls)
      (pimacs--set-event-listener t 'pimacs
                                  (lambda (event)
                                    (push (list 'all (plist-get event :index)) calls)))
      (pimacs--set-event-batch-listener "test" 'pimacs
                                        (lambda (events)
                                          (push (list 'pimacs (mapcar (lambda (event)
                                                                        (plist-get event :index))
                                                                      events))
                                                calls)))
      (pimacs--set-event-batch-listener "test" 'extension
                                        (lambda (events)
                                          (push (list 'extension (mapcar (lambda (event)
                                                                           (plist-get event :index))
                                                                         events))
                                                calls)))
      (pimacs--dispatch-event-batch (list (list :type "test" :index 1)
                                          (list :type "test" :index 2)))
      (should (equal (nreverse calls)
                     '((all 1) (all 2) (pimacs (1 2)) (extension (1 2))))))))

(provide 'pimacs-agent-tests)

;;; pimacs-agent-tests.el ends here
