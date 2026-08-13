;;; pimacs-state-line-tests --- Tests for pimacs-state-line.el -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)

;; development only packages, not declared as a package-dependency
(package-initialize)

(require 'undercover)
(undercover)

(require 'pimacs-state-line)

(ert-deftest pimacs--format-state-line-component-propertizes ()
  (let ((value (pimacs--format-state-line-component
                '(:model (:id "test-model"))
                '(:model face font-lock-function-name-face))))
    (should (equal value "test-model"))
    (should (eq (get-text-property 0 'face value)
                'font-lock-function-name-face))))

(ert-deftest pimacs--format-state-line-custom-function ()
  (let ((pimacs--header-line-state '(:value "custom value")))
    (should (equal (pimacs--format-state-line
                    '((lambda (state) (plist-get state :value))))
                   "custom value"))))

(ert-deftest pimacs--format-state-line-rejects-multiple-spacers ()
  (let ((err (should-error (pimacs--format-state-line '(:spacer :spacer)))))
    (should (string-match-p "only one.*:spacer" (error-message-string err)))))

(ert-deftest pimacs--format-state-line-includes-project-root ()
  (let ((pimacs--project-root "/tmp/project/"))
    (should (equal (pimacs--format-state-line '(:project_root))
                   "/tmp/project/"))))

(ert-deftest pimacs--format-state-line-session-name-falls-back-to-short-id ()
  (should (equal (pimacs--format-state-line-session-name
                  '(:sessionName "named" :sessionStats (:sessionId "12345678-abcdefgh")))
                 "named"))
  (should (equal (pimacs--format-state-line-session-name
                  '(:sessionStats (:sessionId "12345678-abcdefgh")))
                 "abcdefgh")))

(ert-deftest pimacs--format-state-line-cost-rounds-to-six-decimal-places ()
  (should (equal (pimacs--format-state-line-cost
                  '(:sessionStats (:cost 1.23456789)))
                 "1.234568"))
  (should (equal (pimacs--format-state-line-cost
                  '(:sessionStats (:cost 0)))
                 "0")))

(ert-deftest pimacs--format-state-line-spinner ()
  (cl-letf (((symbol-function 'spinner-print) (lambda (_spinner) "spinner")))
    (should (equal (pimacs--format-state-line-spinner
                    '(:spinner spinner :agentState thinking))
                   " spinner"))
    (should (equal (pimacs--format-state-line-spinner '(:spinner spinner))
                   ""))))

(ert-deftest pimacs--format-state-line-cache-hit-percent-uses-literal-percent ()
  (should (equal (pimacs--format-state-line-cache-hit-percent
                  '(:sessionStats (:tokens (:input 50 :cacheRead 50 :cacheWrite 0))))
                 "50%")))

(ert-deftest pimacs--format-state-line-status-component ()
  (let ((pimacs--status-texts (make-hash-table :test 'equal)))
    (puthash "xyz-status" "ready\nnow" pimacs--status-texts)
    (should (equal (pimacs--format-state-line '((:status "xyz-status")))
                   "ready now"))
    (should (equal (pimacs--format-state-line '((:status "missing-status")))
                   ""))
    (puthash "percent-status" "50% ready" pimacs--status-texts)
    (let ((value (pimacs--format-state-line
                  '((:status "percent-status" face font-lock-warning-face)))))
      (should (equal value "50%% ready"))
      (should (eq (get-text-property 2 'face value)
                  'font-lock-warning-face)))))
