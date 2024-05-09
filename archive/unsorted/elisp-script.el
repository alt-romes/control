#!/usr/bin/env emacs --script

(defun main ()
    (print (version))
    (print (format "I did it. You passed in %s" command-line-args-left))    
)

(main)
