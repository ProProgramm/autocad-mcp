;;; mcp_annotation.lsp — text, dimensions, leaders
;;;
;;; Part of the AutoCAD MCP dispatcher. Loaded by mcp_dispatch.lsp.
;;; Commands register themselves at the bottom of this file, so adding
;;; one touches only this module — there is no central dispatch table.

(defun mcp-cmd-create-text (params / x y text height rotation layer pt)
  (setq x (mcp-json-get-number params "x"))
  (setq y (mcp-json-get-number params "y"))
  (setq text (mcp-json-get-string params "text"))
  (setq height (mcp-json-get-number params "height"))
  (setq rotation (mcp-json-get-number params "rotation"))
  (if (not height) (setq height 2.5))
  (if (not rotation) (setq rotation 0.0))
  (setq layer (mcp-json-get-string params "layer"))
  (if layer
    (progn (ensure_layer_exists layer "white" "CONTINUOUS") (set_current_layer layer))
  )
  ;; entmake rather than (command "_TEXT" "J" "M" ...): the prompt sequence for
  ;; _TEXT depends on the current text style — one with a fixed height skips the
  ;; height prompt, so every argument after it lands in the wrong slot — and
  ;; _TEXT keeps asking for further lines until an empty response the IPC
  ;; channel never sends. entmake writes the entity directly, no prompts.
  (setq pt (list x y 0.0))
  (if (entmake (list '(0 . "TEXT")
                     '(100 . "AcDbEntity")
                     (cons 8 (if layer layer (getvar "CLAYER")))
                     '(100 . "AcDbText")
                     (cons 10 pt)
                     (cons 40 height)
                     (cons 1 text)
                     (cons 50 (* pi (/ rotation 180.0)))
                     '(72 . 4)        ; middle justification, as the old form used
                     (cons 11 pt)))
    (cons T (strcat "{\"entity_type\":\"TEXT\",\"handle\":\"" (cdr (assoc 5 (entget (entlast)))) "\"}"))
    (cons nil "entmake rejected the TEXT entity — check the layer and current text style")
  )
)

(defun mcp-cmd-create-dimension-linear (params / x1 y1 x2 y2 dim-x dim-y)
  (setq x1 (mcp-json-get-number params "x1"))
  (setq y1 (mcp-json-get-number params "y1"))
  (setq x2 (mcp-json-get-number params "x2"))
  (setq y2 (mcp-json-get-number params "y2"))
  (setq dim-x (mcp-json-get-number params "dim_x"))
  (setq dim-y (mcp-json-get-number params "dim_y"))
  (command "_.DIMLINEAR" (list x1 y1 0) (list x2 y2 0) (list dim-x dim-y 0))
  (cons T "{\"entity_type\":\"DIMENSION\"}")
)

(defun mcp-cmd-create-dimension-aligned (params / x1 y1 x2 y2 offset)
  (setq x1 (mcp-json-get-number params "x1"))
  (setq y1 (mcp-json-get-number params "y1"))
  (setq x2 (mcp-json-get-number params "x2"))
  (setq y2 (mcp-json-get-number params "y2"))
  (setq offset (mcp-json-get-number params "offset"))
  ;; Place dimension line at offset distance
  (command "_.DIMALIGNED" (list x1 y1 0) (list x2 y2 0)
    (list (+ (/ (+ x1 x2) 2.0) offset) (+ (/ (+ y1 y2) 2.0) offset) 0))
  (cons T "{\"entity_type\":\"DIMENSION\"}")
)

(defun mcp-cmd-create-dimension-angular (params / cx cy x1 y1 x2 y2)
  (setq cx (mcp-json-get-number params "cx"))
  (setq cy (mcp-json-get-number params "cy"))
  (setq x1 (mcp-json-get-number params "x1"))
  (setq y1 (mcp-json-get-number params "y1"))
  (setq x2 (mcp-json-get-number params "x2"))
  (setq y2 (mcp-json-get-number params "y2"))
  (command "_.DIMANGULAR" (list cx cy 0) (list x1 y1 0) (list x2 y2 0) "")
  (cons T "{\"entity_type\":\"DIMENSION\"}")
)

(defun mcp-cmd-create-dimension-radius (params / cx cy radius angle px py)
  (setq cx (mcp-json-get-number params "cx"))
  (setq cy (mcp-json-get-number params "cy"))
  (setq radius (mcp-json-get-number params "radius"))
  (setq angle (mcp-json-get-number params "angle"))
  ;; Need a circle/arc entity first, use entity at center
  (setq px (+ cx (* radius (cos (* angle (/ pi 180.0))))))
  (setq py (+ cy (* radius (sin (* angle (/ pi 180.0))))))
  (command "_.DIMRADIUS" (list px py 0) "")
  (cons T "{\"entity_type\":\"DIMENSION\"}")
)

(defun mcp-cmd-create-leader (params / text pts-str pairs pt-str)
  (setq text (mcp-json-get-string params "text"))
  (setq pts-str (mcp-json-get-string params "points_str"))
  (if (not pts-str)
    (cons nil "points_str required (format: x1,y1;x2,y2;...)")
    (progn
      (command "_.LEADER")
      (setq pairs (mcp-split-string pts-str ";"))
      (foreach pt-str pairs
        (command (list (atof (car (mcp-split-string pt-str ",")))
                       (atof (cadr (mcp-split-string pt-str ","))) 0))
      )
      (command "" text "")
      (cons T "{\"entity_type\":\"LEADER\"}")
    )
  )
)

;; --- command registration ---

(mcp-register "create-dimension-aligned" 'mcp-cmd-create-dimension-aligned)
(mcp-register "create-dimension-angular" 'mcp-cmd-create-dimension-angular)
(mcp-register "create-dimension-linear" 'mcp-cmd-create-dimension-linear)
(mcp-register "create-dimension-radius" 'mcp-cmd-create-dimension-radius)
(mcp-register "create-leader" 'mcp-cmd-create-leader)
(mcp-register "create-text" 'mcp-cmd-create-text)

(princ "\n  mcp_annotation loaded (6 commands)")
(princ)
