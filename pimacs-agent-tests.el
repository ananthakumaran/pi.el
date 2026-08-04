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

(provide 'pimacs-agent-tests)

;;; pimacs-agent-tests.el ends here
