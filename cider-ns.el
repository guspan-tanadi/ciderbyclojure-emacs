;;; cider-ns.el --- Namespace manipulation functionality -*- lexical-binding: t -*-

;; Copyright © 2013-2025 Bozhidar Batsov, Artur Malabarba and CIDER contributors
;;
;; Author: Bozhidar Batsov <bozhidar@batsov.dev>
;;         Artur Malabarba <bruce.connor.am@gmail.com>

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Smart code refresh functionality based on ideas from:
;; http://thinkrelevance.com/blog/2013/06/04/clojure-workflow-reloaded
;;
;; Note that refresh with clojure.tools.namespace.repl is a smarter way to
;; reload code: the traditional way to reload Clojure code without restarting
;; the JVM is (require ... :reload) or an editor/IDE feature that does the same
;; thing.
;;
;; This has several problems:
;;
;; If you modify two namespaces which depend on each other, you must remember to
;; reload them in the correct order to avoid compilation errors.
;;
;; If you remove definitions from a source file and then reload it, those
;; definitions are still available in memory.  If other code depends on those
;; definitions, it will continue to work but will break the next time you
;; restart the JVM.
;;
;; If the reloaded namespace contains defmulti, you must also reload all of the
;; associated defmethod expressions.
;;
;; If the reloaded namespace contains defprotocol, you must also reload any
;; records or types implementing that protocol and replace any existing
;; instances of those records/types with new instances.
;;
;; If the reloaded namespace contains macros, you must also reload any
;; namespaces which use those macros.
;;
;; If the running program contains functions which close over values in the
;; reloaded namespace, those closed-over values are not updated (This is common
;; in web applications which construct the "handler stack" as a composition of
;; functions.)

;;; Code:

(require 'map)
(require 'seq)
(require 'subr-x)

(require 'cider-client)
(require 'cider-eval)
(require 'cider-popup)
(require 'cider-stacktrace)
(require 'cider-util)

(defcustom cider-ns-save-files-on-refresh 'prompt
  "Controls whether to prompt to save files before refreshing.
If nil, files are not saved.
If 'prompt, the user is prompted to save files if they have been modified.
If t, save the files without confirmation."
  :type '(choice (const :tag "Prompt to save files if they have been modified" prompt)
                 (const :tag "Don't save the files" nil)
                 (const :tag "Save the files without confirmation" t))
  :group 'cider
  :package-version '(cider . "0.15.0"))

(defcustom cider-ns-save-files-on-refresh-modes '(clojure-mode clojure-ts-mode)
  "Controls which files might be saved before refreshing.
If a list of modes, any buffers visiting files on the classpath whose major
mode is derived from any of the modes might be saved.
If t, all buffers visiting files on the classpath might be saved."
  :type '(choice listp
                 (const t))
  :group 'cider
  :package-version '(cider . "0.21.0"))

(defconst cider-ns-refresh-log-buffer "*cider-ns-refresh-log*")

(defcustom cider-ns-refresh-show-log-buffer nil
  "Controls when to display the refresh log buffer.
If non-nil, the log buffer will be displayed every time `cider-ns-refresh' is
called.  If nil, the log buffer will still be written to, but will never be
displayed automatically.  Instead, the most relevant information will be
displayed in the echo area."
  :type '(choice (const :tag "always" t)
                 (const :tag "never" nil))
  :group 'cider
  :package-version '(cider . "0.10.0"))

(defcustom cider-ns-refresh-before-fn nil
  "Clojure function for `cider-ns-refresh' to call before reloading.
If nil, nothing will be invoked before reloading.  Must be a
namespace-qualified function of zero arity.  Any thrown exception will
prevent reloading from occurring."
  :type 'string
  :group 'cider
  :package-version '(cider . "0.10.0"))

(defcustom cider-ns-refresh-after-fn nil
  "Clojure function for `cider-ns-refresh' to call after reloading.
If nil, nothing will be invoked after reloading.  Must be a
namespace-qualified function of zero arity."
  :type 'string
  :group 'cider
  :package-version '(cider . "0.10.0"))

(defcustom cider-ns-code-reload-tool 'tools.namespace
  "Which tool to use for ns refresh.
Current options: tools.namespace and clj-reload."
  :group 'cider
  :type '(choice (const :tag "tools.namespace https://github.com/clojure/tools.namespace" tools.namespace)
                 (const :tag "clj-reload https://github.com/tonsky/clj-reload" clj-reload))
  :package-version '(cider . "1.14.0"))

(defun cider-ns--present-error (error)
  "Render the `ERROR' stacktrace,
and jump to the adequate file/line location,
presenting the error message as an overlay."
  (let* ((buf)
         (jump-args (seq-some (lambda (cause-dict) ;; a dict representing an exception cause
                                (nrepl-dbind-response cause-dict (file-url line column)
                                  (when (and file-url
                                             ;; jars are unlikely sources of user errors, so we favor the next `cause-dict':
                                             (not (string-prefix-p "jar:" file-url))
                                             line)
                                    (setq buf (cider--find-buffer-for-file file-url))
                                    (list buf (cons line column)))))
                              error)))
    (when jump-args
      (apply #'cider-jump-to jump-args)
      (when-let ((message (seq-some (lambda (cause-dict)
                                      (nrepl-dbind-response cause-dict (message)
                                        message))
                                    ;; `reverse' the causes as the first one typically is a CompilerException, which the second one is the actual exception:
                                    (reverse error))))
        (with-current-buffer buf
          (let ((cider-result-use-clojure-font-lock nil)
                (trimmed-err (funcall cider-inline-error-message-function message)))
            (cider--display-interactive-eval-result trimmed-err
                                                    'error
                                                    (save-excursion
                                                      (end-of-defun)
                                                      (point))
                                                    'cider-error-overlay-face)))))
    (cider--render-stacktrace-causes error)
    ;; Select the window displaying the 'culprit' buffer so that the user can immediately fix it,
    ;; as most times the displayed stacktrace doesn't need much inspection:
    (when buf
      (select-window (get-buffer-window buf)))))

(defun cider-ns-refresh--handle-response (response log-buffer)
  "Refresh LOG-BUFFER with RESPONSE."
  (nrepl-dbind-response response (out err reloading progress status error error-ns after before)
    (cl-flet* ((log (message &optional face)
                    (cider-emit-into-popup-buffer log-buffer message face t))

               (log-echo (message &optional face)
                         (log message face)
                         (unless cider-ns-refresh-show-log-buffer
                           (let ((message-truncate-lines t))
                             (message "cider-ns-refresh: %s" message)))))
      (cond
       (out
        (log out))

       (err
        (log err 'font-lock-warning-face))

       ((member "invoking-before" status)
        (log-echo (format "Calling %s\n" before) 'font-lock-string-face))

       ((member "invoked-before" status)
        (log-echo (format "Successfully called %s\n" before) 'font-lock-string-face))

       ((member "invoked-not-resolved" status)
        (log-echo "Could not resolve refresh function\n" 'font-lock-string-face))

       (reloading
        (log-echo (format "Reloading %s\n" reloading) 'font-lock-string-face))

       (progress
        (log-echo progress 'font-lock-string-face))

       ((member "reloading" (nrepl-dict-keys response))
        (log-echo "Nothing to reload\n" 'font-lock-string-face))

       ((member "ok" status)
        (log-echo "Reloading successful\n" 'font-lock-string-face))

       (error-ns
        (log-echo (format "Error reloading %s\n" error-ns) 'font-lock-warning-face))

       ((member "invoking-after" status)
        (log-echo (format "Calling %s\n" after) 'font-lock-string-face))

       ((member "invoked-after" status)
        (log-echo (format "Successfully called %s\n" after) 'font-lock-string-face))))

    (with-selected-window (or (get-buffer-window cider-ns-refresh-log-buffer)
                              (selected-window))
      (with-current-buffer cider-ns-refresh-log-buffer
        (goto-char (point-max))))

    (when (and (member "error" status)
               error)
      (cider-ns--present-error error))))

(defun cider-ns-refresh--save-modified-buffers ()
  "Ensure any relevant modified buffers are saved before refreshing.
Its behavior is controlled by `cider-ns-save-files-on-refresh' and
`cider-ns-save-files-on-refresh-modes'."
  (when cider-ns-save-files-on-refresh
    (let ((dirs (seq-filter #'file-directory-p
                            (cider-classpath-entries))))
      (save-some-buffers
       (not (eq cider-ns-save-files-on-refresh 'prompt))
       (lambda ()
         (and (seq-some #'derived-mode-p cider-ns-save-files-on-refresh-modes)
              (seq-some (lambda (dir)
                          (file-in-directory-p buffer-file-name dir))
                        dirs)))))))

(defun cider-ns--reload-op (op-name)
  "Return the reload operation to use.
Based on OP-NAME and the value of cider-ns-code-reload-tool defcustom."
  (if (eq cider-ns-code-reload-tool 'tools.namespace)
      (cond ((string= op-name "reload")       "refresh")
            ((string= op-name "reload-all")   "refresh-all")
            ((string= op-name "reload-clear") "refresh-clear"))

    (cond ((string= op-name "reload")       "cider.clj-reload/reload")
          ((string= op-name "reload-all")   "cider.clj-reload/reload-all")
          ((string= op-name "reload-clear") "cider.clj-reload/reload-clear"))))

;;;###autoload
(defun cider-ns-reload (&optional prompt)
  "Send a (require 'ns :reload) to the REPL.

With an argument PROMPT, it prompts for a namespace name.  This is the
Clojure out of the box reloading experience and does not rely on
org.clojure/tools.namespace.  See Commentary of this file for a longer list
of differences.  From the Clojure doc: \":reload forces loading of all the
identified libs even if they are already loaded\"."
  (interactive "P")
  (when-let ((ns (if prompt
                     (string-remove-prefix "'" (read-from-minibuffer "Namespace: " (cider-get-ns-name)))
                   (cider-get-ns-name))))
    (cider-interactive-eval (format "(require '%s :reload)" ns))))

;;;###autoload
(defun cider-ns-reload-all (&optional prompt)
  "Send a (require 'ns :reload-all) to the REPL.

With an argument PROMPT, it prompts for a namespace name.  This is the
Clojure out of the box reloading experience and does not rely on
org.clojure/tools.namespace.  See Commentary of this file for a longer list
of differences.  From the Clojure doc: \":reload-all implies :reload and
also forces loading of all libs that the identified libs directly or
indirectly load via require\"."
  (interactive "P")
  (when-let ((ns (if prompt
                     (string-remove-prefix "'" (read-from-minibuffer "Namespace: " (cider-get-ns-name)))
                   (cider-get-ns-name))))
    (cider-interactive-eval (format "(require '%s :reload-all)" ns))))

;;;###autoload
(defun cider-ns-refresh (&optional mode)
  "Reload modified and unloaded namespaces, using the Reloaded Workflow.
Uses the configured 'refresh dirs' \(defaults to the classpath dirs).

With a single prefix argument, or if MODE is `refresh-all', reload all
namespaces on the classpath dirs unconditionally.

With a double prefix argument, or if MODE is `clear', clear the state of
the namespace tracker before reloading.  This is useful for recovering from
some classes of error (for example, those caused by circular dependencies)
that a normal reload would not otherwise recover from.  The trade-off of
clearing is that stale code from any deleted files may not be completely
unloaded.

With a negative prefix argument, or if MODE is `inhibit-fns', prevent any
refresh functions (defined in `cider-ns-refresh-before-fn' and
`cider-ns-refresh-after-fn') from being invoked."
  (interactive "p")
  (cider-ensure-connected)
  (cider-ensure-op-supported "refresh")
  (cider-ensure-op-supported "cider.clj-reload/reload")
  (cider-ns-refresh--save-modified-buffers)
  (let ((clear? (member mode '(clear 16)))
        (all? (member mode '(refresh-all 4)))
        (inhibit-refresh-fns (member mode '(inhibit-fns -1))))
    (cider-map-repls :clj
      (lambda (conn)
        ;; Inside the lambda, so the buffer is not created if we error out.
        (let ((log-buffer (or (get-buffer cider-ns-refresh-log-buffer)
                              (cider-make-popup-buffer cider-ns-refresh-log-buffer))))
          (when cider-ns-refresh-show-log-buffer
            (cider-popup-buffer-display log-buffer))
          (when inhibit-refresh-fns
            (cider-emit-into-popup-buffer log-buffer
                                          "inhibiting refresh functions\n"
                                          nil
                                          t))
          (when clear?
            (cider-nrepl-send-sync-request `("op" ,(cider-ns--reload-op "reload-clear")) conn))
          (cider-nrepl-send-request
           `("op" ,(cider-ns--reload-op (if all? "reload-all" "reload"))
             ,@(cider--nrepl-print-request-plist fill-column)
             ,@(when (and (not inhibit-refresh-fns) cider-ns-refresh-before-fn)
                 `("before" ,cider-ns-refresh-before-fn))
             ,@(when (and (not inhibit-refresh-fns) cider-ns-refresh-after-fn)
                 `("after" ,cider-ns-refresh-after-fn)))
           (lambda (response)
             (cider-ns-refresh--handle-response response log-buffer))
           conn))))))

(provide 'cider-ns)
;;; cider-ns.el ends here
