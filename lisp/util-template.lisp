(roswell:include "util" "util-template")
(ql:quickload '(:uiop :djula) :silent t)
(defpackage :roswell.util.template
  (:use :cl :roswell.util)
  (:export
   :template-init
   :template-list
   :template-set-default
   :template-rm
   :template-add
   :template-apply))

(in-package :roswell.util.template)

(defun sanitize (name)
  (remove-if (lambda (x) (find x "./\\")) name))

(defun template-path (name)
  (merge-pathnames (format nil "templates/~A/" name)
                   (first ql:*local-project-directories*)))

(defun enc-string (str)
  (format nil "~{%~36r~}" (loop for i across str collect (char-code i))))

(defun dec-string (str)
  (with-input-from-string (s (substitute #\Space #\% str))
    (coerce
     (loop with *read-base* = 36
           with *read-eval*
           for i = (read s nil nil)
           while i
           collect (code-char i)) 'string)))

(defun copy-file (src dest params)
  (declare (ignore params))
  (when (probe-file dest)
    (error "file exits ~A" dest))
  (uiop:copy-file src dest))

(defun apply-djula (template-string stream params)
  (apply 'djula::render-template* (djula::compile-string template-string) stream params))

(defun djula (src dest params)
  (with-open-file (o dest :direction :output)
    (apply-djula (uiop:read-file-string src) o params)))

(defvar *template-function-plist*
  '(nil copy-file
    :djula djula))

(defun key (string)
  (when string
    (let (*read-eval*)
      (read-from-string (format nil ":~A" string)))))

(defun octal (string)
  (parse-integer string :radix 8))

(defun template-apply (template-name args info)
  (declare (ignorable template-name args info))
  ;; tbd after-hook
  (setf args `(:name ,(first args)
                     ,@(loop for i on (rest args) by #'cddr
                             while (string-equal (first i) "--" :end1 2)
                             collect (key (subseq (first i) 2))
                             collect (second i))))
  (loop for i in (getf info :files)
        for from = (merge-pathnames (format nil "~A/~A" template-name (enc-string (getf i :name))) (template-path template-name))
        for to = (ensure-directories-exist (merge-pathnames (if (getf i :rename)
                                                                (apply-djula (getf i :rename) nil args)
                                                                (getf i :name))
                                                            *default-pathname-defaults*))
        do (funcall (getf *template-function-plist* (key (getf i :method))) from to args)
           (when (getf i :chmod)
             #+sbcl(sb-posix:chmod to (octal (getf i :chmod))))))

(defun write-template (name &key
                              (path (template-path name))
                              list)
  (with-open-file (o (merge-pathnames (format nil "roswell.init.~A.asd" name) path)
                     :direction :output
                     :if-exists :supersede
                     :if-does-not-exist :create)
    (let ((package (read-from-string (format nil ":roswell.init.~A" name)))
          (*package* (find-package :roswell.util.template)))
      (format o "~{~S~%~}"
              `((defpackage ,package
                  (:use :cl))
                (in-package ,package)
                (defvar *params* '(,@list))
                (defun ,(read-from-string name) (_ &rest r)
                  (roswell:include "util-template")
                  (funcall (read-from-string "roswell.util.template:template-apply") _ r *params*)))))))

(defun read-template (name &key (path (template-path name)))
  (let ((package)
        read/)
    (with-open-file (o (merge-pathnames (format nil "roswell.init.~A.asd" name) path)
                       :direction :input
                       :if-does-not-exist :error)
      (setq read/ (read o))
      (unless (and
               (eql 'defpackage (first read/))
               (string-equal "ROSWELL.INIT." (symbol-name (setq package (second read/))) :end2 13))
        (error "not init template ~A~%" read/))
      (setq read/ (read o))
      (unless (and
               (eql 'in-package (first read/))
               (eql (second read/) package))
        (error "not init template ~A~%" read/))
      (setq read/ (read o))
      (unless (and (eql 'defvar (first read/))
                   (string-equal  '*params* (second read/))) 
        (error "not init template ~S~%" (list read/)))
      (second (third read/)))))

(defun template-init (names)
  (let* ((name (sanitize (first names)))
         (path (template-path name)))
    (when (probe-file (merge-pathnames ".git/" path))
      (format *error-output* "already exist ~A~%" path)
      (ros:quit 0))
    (ensure-directories-exist path)
    (uiop:chdir path)
    (uiop:run-program "git init" :output :interactive :error-output :interactive)
    (write-template name :path path)))

(defun list-templates (&key filter name)
  (let* ((* (directory (merge-pathnames "**/.git/" (first ql:*local-project-directories*))))
         (* (mapcar (lambda (x) (directory (merge-pathnames "../*.asd" x))) *))
         (* (apply #'append *))
         (* (remove-if-not (lambda (x) (ignore-errors (string-equal "roswell.init." (pathname-name x) :end2 13))) *))
         (* (cons (merge-pathnames "init-default.lisp" (ros:opt "lispdir")) *))
         (* (if filter
                (remove-if-not (lambda (x)
                                 (find (pathname-name x)
                                       (list (format nil "roswell.init.~A" filter)
                                             (format nil "init-~A" filter))
                                       :test 'equal))
                               *)
                *)))
    (cond
      (name
       (mapcar (lambda (x)
                 (subseq (pathname-name x)
                         (1+ (position-if
                              (lambda (x) (find x ".-"))
                              (pathname-name x) :from-end t))))
               *))
      (t *))))

(defun template-dir (name)
  (merge-pathnames (format nil "~A/" name) (make-pathname :defaults (first (list-templates :filter name)) :type nil :name nil)))

(defun list-in-template (name)
  (mapcar (lambda (x) (dec-string (file-namestring x)))
          (directory (merge-pathnames "*" (template-dir name)))))

(defun template-list (_)
  "List the installed templates"
  (cond
    ((or (first _)
         (and (config "init.default")
              (not (equal (config "init.default") "default"))))
     (let* ((name (or (sanitize (first _))
                      (config "init.default")))
            (path (first (list-templates :filter name))))
       (when (and path (equal (pathname-type path) "asd"))
         (print (mapcar (lambda (x) (dec-string (file-namestring x))) (directory (merge-pathnames (format nil "~A/*" name) (make-pathname :defaults path :type nil :name nil))))))))
    ((not _)
     (format t "~{~A~%~}" (list-templates :name t)))))

(defun template-set-default (_)
  (let ((name (sanitize (first _))))
    (when name
      (let ((path (list-templates :filter name)))
        (if path
            (setf (config "init.default") name)
            (format *error-output* "template: ~S not found.~%" name))))))

(defun template-add-file (template-name file-name path-copy-from)
  (let ((info (read-template template-name)))
    (uiop:copy-file path-copy-from
                    (merge-pathnames (enc-string file-name) (template-dir template-name)))
    (unless (find file-name (getf info :files) :key (lambda (x) (getf x :name)))
      (push (list :name file-name) (getf info :files)))
    (write-template template-name :list info)))

(defun template-add (_)
  ;; care windows someday
  (let ((name (config "init.default")))
    (unless (and name
                 (not (equal name "default")))
      (setf name (sanitize (first _))
            _ (rest _)))
    (if (and (list-templates :filter name)
             (not (equal name "default")))
        (loop for i in _
              do (template-add-file name i i))
        (format *error-output* "template ~S is not editable.~%" name))))

(defun template-remove-file (template-name file-name)
  (let ((info (read-template template-name)))
    (uiop:delete-file-if-exists
     (merge-pathnames (enc-string file-name) (template-dir template-name)))
    (when (find file-name (getf info :files) :key (lambda (x) (getf x :name)) :test 'equal)
      (setf (getf info :files)
            (remove file-name (getf info :files)
                    :key (lambda (x) (getf x :name)) :test 'equal))
      (write-template template-name :list info))))

(defun template-rm (_)
  "Remove (delete) files from template."
  (let ((name (config "init.default")))
    (unless (and name
                 (not (equal name "default")))
      (setf name (sanitize (first _))
            _ (rest _)))
    (if (and (list-templates :filter name)
             (not (equal name "default")))
        (loop for i in _
              do (template-remove-file name i))
        (format *error-output* "template ~S is not editable.~%" name))))