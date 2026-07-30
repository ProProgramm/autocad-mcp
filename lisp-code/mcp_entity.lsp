;;; mcp_entity.lsp — entity creation, query and modification
;;;
;;; Part of the AutoCAD MCP dispatcher. Loaded by mcp_dispatch.lsp.
;;; Commands register themselves at the bottom of this file, so adding
;;; one touches only this module — there is no central dispatch table.

(defun mcp-cmd-create-line (params / x1 y1 x2 y2 layer)
  (setq x1 (mcp-json-get-number params "x1"))
  (setq y1 (mcp-json-get-number params "y1"))
  (setq x2 (mcp-json-get-number params "x2"))
  (setq y2 (mcp-json-get-number params "y2"))
  (setq layer (mcp-json-get-string params "layer"))
  (if layer
    (progn (ensure_layer_exists layer "white" "CONTINUOUS") (set_current_layer layer))
  )
  (command "_LINE" (list x1 y1 0.0) (list x2 y2 0.0) "")
  (cons T (strcat "{\"entity_type\":\"LINE\",\"handle\":\"" (cdr (assoc 5 (entget (entlast)))) "\"}"))
)

(defun mcp-cmd-create-circle (params / cx cy radius layer)
  (setq cx (mcp-json-get-number params "cx"))
  (setq cy (mcp-json-get-number params "cy"))
  (setq radius (mcp-json-get-number params "radius"))
  (setq layer (mcp-json-get-string params "layer"))
  (if layer
    (progn (ensure_layer_exists layer "white" "CONTINUOUS") (set_current_layer layer))
  )
  (command "_CIRCLE" (list cx cy 0.0) radius)
  (cons T (strcat "{\"entity_type\":\"CIRCLE\",\"handle\":\"" (cdr (assoc 5 (entget (entlast)))) "\"}"))
)

(defun mcp-cmd-create-polyline (params / pts-str closed layer pairs pt-str cx cy)
  (setq pts-str (mcp-json-get-string params "points_str"))
  (setq closed (mcp-json-get-string params "closed"))
  (setq layer (mcp-json-get-string params "layer"))
  (if layer (progn (ensure_layer_exists layer "white" "CONTINUOUS") (set_current_layer layer)))
  (if (not pts-str)
    (cons nil "points_str required (format: x1,y1;x2,y2;...)")
    (progn
      (command "_PLINE")
      (setq pairs (mcp-split-string pts-str ";"))
      (foreach pt-str pairs
        (setq cx (atof (car (mcp-split-string pt-str ","))))
        (setq cy (atof (cadr (mcp-split-string pt-str ","))))
        (command (list cx cy 0.0))
      )
      (if (= closed "1") (command "_C") (command ""))
      (cons T (strcat "{\"entity_type\":\"LWPOLYLINE\",\"handle\":\""
                      (cdr (assoc 5 (entget (entlast)))) "\"}"))
    )
  )
)

(defun mcp-cmd-create-rectangle (params / x1 y1 x2 y2 layer)
  (setq x1 (mcp-json-get-number params "x1"))
  (setq y1 (mcp-json-get-number params "y1"))
  (setq x2 (mcp-json-get-number params "x2"))
  (setq y2 (mcp-json-get-number params "y2"))
  (setq layer (mcp-json-get-string params "layer"))
  (if layer
    (progn (ensure_layer_exists layer "white" "CONTINUOUS") (set_current_layer layer))
  )
  (command "_RECTANG" (list x1 y1 0.0) (list x2 y2 0.0))
  (cons T (strcat "{\"entity_type\":\"LWPOLYLINE\",\"handle\":\"" (cdr (assoc 5 (entget (entlast)))) "\"}"))
)

(defun mcp-cmd-entity-count (params / layer count ent ent-data)
  (setq layer (mcp-json-get-string params "layer"))
  (setq count 0 ent (entnext))
  (while ent
    (setq ent-data (entget ent))
    (if (or (not layer) (= (cdr (assoc 8 ent-data)) layer))
      (setq count (1+ count))
    )
    (setq ent (entnext ent))
  )
  (cons T (strcat "{\"count\":" (itoa count) "}"))
)

(defun mcp-cmd-entity-list (params / layer type-filter types limit offset
                                   bx1 by1 bx2 by2 use-bbox tmp
                                   entities ent ent-data etype handle elayer pt
                                   total emitted)
  "List entities with layer/type/bbox filters and a hard result cap.

   Walking the whole database is cheap; building one JSON string for every
   entity is not — strcat is O(n^2) and a 10k-entity drawing blows both the
   IPC timeout and the caller's token budget. So we always count every match
   but only serialize the requested window, and report `total` so the caller
   knows what it did not see."
  (setq layer       (mcp-json-get-string params "layer"))
  (setq type-filter (mcp-json-get-string params "type"))
  (setq limit       (mcp-json-get-number params "limit"))
  (setq offset      (mcp-json-get-number params "offset"))
  (setq bx1 (mcp-json-get-number params "bx1")
        by1 (mcp-json-get-number params "by1")
        bx2 (mcp-json-get-number params "bx2")
        by2 (mcp-json-get-number params "by2"))

  (if limit  (setq limit  (fix limit))  (setq limit 200))
  (if offset (setq offset (fix offset)) (setq offset 0))
  (if (< limit 0)  (setq limit 0))
  (if (< offset 0) (setq offset 0))

  ;; Accept any two opposite corners
  (setq use-bbox (and bx1 by1 bx2 by2))
  (if use-bbox
    (progn
      (if (> bx1 bx2) (progn (setq tmp bx1) (setq bx1 bx2) (setq bx2 tmp)))
      (if (> by1 by2) (progn (setq tmp by1) (setq by1 by2) (setq by2 tmp)))
    )
  )

  ;; "INSERT,TEXT" or "insert, text" -> ("INSERT" "TEXT")
  (if type-filter
    (setq types (mapcar '(lambda (s) (vl-string-trim " " s))
                        (mcp-split-string (strcase type-filter) ",")))
  )

  (setq entities "" total 0 emitted 0 ent (entnext))
  (while ent
    (setq ent-data (entget ent))
    (setq etype  (cdr (assoc 0 ent-data)))
    (setq handle (cdr (assoc 5 ent-data)))
    (setq elayer (cdr (assoc 8 ent-data)))
    (setq pt     (cdr (assoc 10 ent-data)))
    (if (and (or (not layer) (= elayer layer))
             (or (not types) (member etype types))
             ;; bbox tests the base/insertion point, not true extents —
             ;; entities without a group-10 point are excluded when filtering
             (or (not use-bbox)
                 (and pt
                      (>= (car pt) bx1) (<= (car pt) bx2)
                      (>= (cadr pt) by1) (<= (cadr pt) by2))))
      (progn
        (setq total (1+ total))
        (if (and (> total offset) (< emitted limit))
          (progn
            (if (> (strlen entities) 0) (setq entities (strcat entities ",")))
            (setq entities
              (strcat entities
                "{\"type\":\"" etype
                "\",\"handle\":\"" handle
                "\",\"layer\":\"" (mcp-escape-string elayer) "\""
                (if pt
                  (strcat ",\"pt\":[" (rtos (car pt) 2 3) "," (rtos (cadr pt) 2 3) "]")
                  "")
                "}"))
            (setq emitted (1+ emitted))
          )
        )
      )
    )
    (setq ent (entnext ent))
  )
  (cons T (strcat "{\"entities\":[" entities "]"
                  ",\"returned\":" (itoa emitted)
                  ",\"offset\":" (itoa offset)
                  ",\"total\":" (itoa total)
                  ",\"truncated\":" (if (> total (+ offset emitted)) "true" "false")
                  "}"))
)

(defun mcp-cmd-entity-erase (params / entity-id ent)
  (setq entity-id (mcp-json-get-string params "entity_id"))
  (if (= entity-id "last")
    (progn
      (setq ent (entlast))
      (if ent (progn (entdel ent) (cons T "\"erased last entity\""))
        (cons nil "No entity to erase")))
    (progn
      (setq ent (handent entity-id))
      (if ent (progn (entdel ent) (cons T (strcat "\"erased " entity-id "\"")))
        (cons nil (strcat "Entity not found: " entity-id))))
  )
)

(defun mcp-cmd-entity-move (params / entity-id dx dy ent)
  (setq entity-id (mcp-json-get-string params "entity_id"))
  (setq dx (mcp-json-get-number params "dx"))
  (setq dy (mcp-json-get-number params "dy"))
  (if (= entity-id "last")
    (setq ent (entlast))
    (setq ent (handent entity-id))
  )
  (if ent
    (progn
      (command "_.MOVE" ent "" '(0 0 0) (list dx dy 0))
      (cons T "\"moved\""))
    (cons nil "Entity not found")
  )
)

(defun mcp-cmd-create-arc (params / cx cy radius sa ea layer)
  (setq cx (mcp-json-get-number params "cx"))
  (setq cy (mcp-json-get-number params "cy"))
  (setq radius (mcp-json-get-number params "radius"))
  (setq sa (mcp-json-get-number params "start_angle"))
  (setq ea (mcp-json-get-number params "end_angle"))
  (setq layer (mcp-json-get-string params "layer"))
  (if layer (progn (ensure_layer_exists layer "white" "CONTINUOUS") (set_current_layer layer)))
  (command "_ARC" "_C" (list cx cy 0.0) (list (+ cx radius) cy 0.0) "_A" (- ea sa))
  (cons T (strcat "{\"entity_type\":\"ARC\",\"handle\":\"" (cdr (assoc 5 (entget (entlast)))) "\"}"))
)

(defun mcp-cmd-create-ellipse (params / cx cy mx my ratio layer)
  (setq cx (mcp-json-get-number params "cx"))
  (setq cy (mcp-json-get-number params "cy"))
  (setq mx (mcp-json-get-number params "major_x"))
  (setq my (mcp-json-get-number params "major_y"))
  (setq ratio (mcp-json-get-number params "ratio"))
  (setq layer (mcp-json-get-string params "layer"))
  (if layer (progn (ensure_layer_exists layer "white" "CONTINUOUS") (set_current_layer layer)))
  (command "_ELLIPSE" "_C" (list cx cy 0.0) (list mx my 0.0) ratio)
  (cons T (strcat "{\"entity_type\":\"ELLIPSE\",\"handle\":\"" (cdr (assoc 5 (entget (entlast)))) "\"}"))
)

(defun mcp-cmd-create-mtext (params / x y width text height layer)
  (setq x (mcp-json-get-number params "x"))
  (setq y (mcp-json-get-number params "y"))
  (setq width (mcp-json-get-number params "width"))
  (setq text (mcp-json-get-string params "text"))
  (setq height (mcp-json-get-number params "height"))
  (if (not height) (setq height 2.5))
  (setq layer (mcp-json-get-string params "layer"))
  (if layer (progn (ensure_layer_exists layer "white" "CONTINUOUS") (set_current_layer layer)))
  (command "_MTEXT" (list x y 0.0) "_H" height "_W" width text "")
  (cons T (strcat "{\"entity_type\":\"MTEXT\",\"handle\":\"" (cdr (assoc 5 (entget (entlast)))) "\"}"))
)

(defun mcp-cmd-create-hatch (params / entity-id pattern ent)
  (setq entity-id (mcp-json-get-string params "entity_id"))
  (setq pattern (mcp-json-get-string params "pattern"))
  (if (not pattern) (setq pattern "ANSI31"))
  (if (= entity-id "last")
    (setq ent (entlast))
    (setq ent (handent entity-id))
  )
  (if ent
    (progn
      (command "_HATCH" "_P" pattern "" "_S" ent "" "")
      (cons T (strcat "{\"entity_type\":\"HATCH\",\"handle\":\"" (cdr (assoc 5 (entget (entlast)))) "\"}")))
    (cons nil "Entity not found for hatching")
  )
)

(defun mcp-cmd-entity-get (params / entity-id ent ent-data etype handle elayer
                                  result pts n closed)
  (setq entity-id (mcp-json-get-string params "entity_id"))
  (if (= entity-id "last")
    (setq ent (entlast))
    (setq ent (handent entity-id))
  )
  (if (not ent)
    (cons nil (strcat "Entity not found: " entity-id))
    (progn
      (setq ent-data (entget ent))
      (setq etype (cdr (assoc 0 ent-data)))
      (setq handle (cdr (assoc 5 ent-data)))
      (setq elayer (cdr (assoc 8 ent-data)))
      (setq result (strcat "{\"type\":\"" etype "\",\"handle\":\"" handle
                           "\",\"layer\":\"" (mcp-escape-string elayer) "\""))
      ;; Add type-specific info
      (cond
        ((= etype "LINE")
         (setq result (strcat result
           ",\"start\":" (mcp-pt-json (cdr (assoc 10 ent-data)))
           ",\"end\":"   (mcp-pt-json (cdr (assoc 11 ent-data))))))

        ((= etype "CIRCLE")
         (setq result (strcat result
           ",\"center\":" (mcp-pt-json (cdr (assoc 10 ent-data)))
           ",\"radius\":" (mcp-num-json (cdr (assoc 40 ent-data)) 0.0))))

        ((= etype "ARC")
         (setq result (strcat result
           ",\"center\":"      (mcp-pt-json (cdr (assoc 10 ent-data)))
           ",\"radius\":"      (mcp-num-json (cdr (assoc 40 ent-data)) 0.0)
           ",\"start_angle\":" (mcp-deg-json (cdr (assoc 50 ent-data)))
           ",\"end_angle\":"   (mcp-deg-json (cdr (assoc 51 ent-data))))))

        ((= etype "ELLIPSE")
         (setq result (strcat result
           ",\"center\":"     (mcp-pt-json (cdr (assoc 10 ent-data)))
           ",\"major_axis\":" (mcp-pt-json (cdr (assoc 11 ent-data)))
           ",\"ratio\":"      (mcp-num-json (cdr (assoc 40 ent-data)) 1.0))))

        ((= etype "POINT")
         (setq result (strcat result
           ",\"position\":" (mcp-pt-json (cdr (assoc 10 ent-data))))))

        ((or (= etype "TEXT") (= etype "ATTDEF") (= etype "ATTRIB"))
         (setq result (strcat result
           ",\"text\":\""    (mcp-escape-string (cdr (assoc 1 ent-data))) "\""
           ",\"position\":"  (mcp-pt-json (cdr (assoc 10 ent-data)))
           ",\"height\":"    (mcp-num-json (cdr (assoc 40 ent-data)) 0.0)
           ",\"rotation\":"  (mcp-deg-json (cdr (assoc 50 ent-data)))
           (if (assoc 2 ent-data)
             (strcat ",\"tag\":\"" (mcp-escape-string (cdr (assoc 2 ent-data))) "\"")
             ""))))

        ((= etype "MTEXT")
         (setq result (strcat result
           ",\"text\":\""   (mcp-escape-string (mcp-mtext-string ent-data)) "\""
           ",\"position\":" (mcp-pt-json (cdr (assoc 10 ent-data)))
           ",\"height\":"   (mcp-num-json (cdr (assoc 40 ent-data)) 0.0)
           ",\"width\":"    (mcp-num-json (cdr (assoc 41 ent-data)) 0.0)
           ",\"rotation\":" (mcp-deg-json (cdr (assoc 50 ent-data))))))

        ((= etype "INSERT")
         (setq result (strcat result
           ",\"name\":\""     (mcp-escape-string (cdr (assoc 2 ent-data))) "\""
           ",\"position\":"   (mcp-pt-json (cdr (assoc 10 ent-data)))
           ",\"xscale\":"     (mcp-num-json (cdr (assoc 41 ent-data)) 1.0)
           ",\"yscale\":"     (mcp-num-json (cdr (assoc 42 ent-data)) 1.0)
           ",\"rotation\":"   (mcp-deg-json (cdr (assoc 50 ent-data)))
           ",\"has_attributes\":"
             (if (and (assoc 66 ent-data) (= (cdr (assoc 66 ent-data)) 1)) "true" "false"))))

        ((or (= etype "LWPOLYLINE") (= etype "POLYLINE"))
         ;; Vertices are repeated group-10 entries; cap the serialized list so a
         ;; survey polyline with thousands of points cannot blow the result up.
         (setq pts "" n 0)
         (foreach itm ent-data
           (if (= (car itm) 10)
             (progn
               (if (< n 200)
                 (progn
                   (if (> n 0) (setq pts (strcat pts ",")))
                   (setq pts (strcat pts (mcp-pt-json (cdr itm))))
                 )
               )
               (setq n (1+ n))
             )
           )
         )
         (setq closed (and (assoc 70 ent-data)
                           (= 1 (logand 1 (cdr (assoc 70 ent-data))))))
         (setq result (strcat result
           ",\"vertices\":[" pts "]"
           ",\"vertex_count\":" (itoa n)
           ",\"vertices_truncated\":" (if (> n 200) "true" "false")
           ",\"closed\":" (if closed "true" "false"))))
      )
      (setq result (strcat result "}"))
      (cons T result)
    )
  )
)

(defun mcp-cmd-entity-copy (params / entity-id dx dy ent new-handle)
  (setq entity-id (mcp-json-get-string params "entity_id"))
  (setq dx (mcp-json-get-number params "dx"))
  (setq dy (mcp-json-get-number params "dy"))
  (if (= entity-id "last") (setq ent (entlast)) (setq ent (handent entity-id)))
  (if ent
    (progn
      (command "_.COPY" ent "" '(0 0 0) (list dx dy 0))
      (setq new-handle (cdr (assoc 5 (entget (entlast)))))
      (cons T (strcat "{\"handle\":\"" new-handle "\"}")))
    (cons nil "Entity not found")
  )
)

(defun mcp-cmd-entity-rotate (params / entity-id cx cy angle ent)
  (setq entity-id (mcp-json-get-string params "entity_id"))
  (setq cx (mcp-json-get-number params "cx"))
  (setq cy (mcp-json-get-number params "cy"))
  (setq angle (mcp-json-get-number params "angle"))
  (if (= entity-id "last") (setq ent (entlast)) (setq ent (handent entity-id)))
  (if ent
    (progn (command "_.ROTATE" ent "" (list cx cy 0) angle) (cons T "\"rotated\""))
    (cons nil "Entity not found")
  )
)

(defun mcp-cmd-entity-scale (params / entity-id cx cy factor ent)
  (setq entity-id (mcp-json-get-string params "entity_id"))
  (setq cx (mcp-json-get-number params "cx"))
  (setq cy (mcp-json-get-number params "cy"))
  (setq factor (mcp-json-get-number params "factor"))
  (if (= entity-id "last") (setq ent (entlast)) (setq ent (handent entity-id)))
  (if ent
    (progn (command "_.SCALE" ent "" (list cx cy 0) factor) (cons T "\"scaled\""))
    (cons nil "Entity not found")
  )
)

(defun mcp-cmd-entity-mirror (params / entity-id x1 y1 x2 y2 ent new-handle)
  (setq entity-id (mcp-json-get-string params "entity_id"))
  (setq x1 (mcp-json-get-number params "x1"))
  (setq y1 (mcp-json-get-number params "y1"))
  (setq x2 (mcp-json-get-number params "x2"))
  (setq y2 (mcp-json-get-number params "y2"))
  (if (= entity-id "last") (setq ent (entlast)) (setq ent (handent entity-id)))
  (if ent
    (progn
      (command "_.MIRROR" ent "" (list x1 y1 0) (list x2 y2 0) "_N")
      (setq new-handle (cdr (assoc 5 (entget (entlast)))))
      (cons T (strcat "{\"handle\":\"" new-handle "\"}")))
    (cons nil "Entity not found")
  )
)

(defun mcp-cmd-entity-offset (params / entity-id distance ent new-handle)
  (setq entity-id (mcp-json-get-string params "entity_id"))
  (setq distance (mcp-json-get-number params "distance"))
  (if (= entity-id "last") (setq ent (entlast)) (setq ent (handent entity-id)))
  (if ent
    (progn
      (command "_.OFFSET" distance ent (list 0 0 0) "")
      (setq new-handle (cdr (assoc 5 (entget (entlast)))))
      (cons T (strcat "{\"handle\":\"" new-handle "\"}")))
    (cons nil "Entity not found")
  )
)

(defun mcp-cmd-entity-array (params / entity-id rows cols row-dist col-dist ent)
  (setq entity-id (mcp-json-get-string params "entity_id"))
  (setq rows (fix (mcp-json-get-number params "rows")))
  (setq cols (fix (mcp-json-get-number params "cols")))
  (setq row-dist (mcp-json-get-number params "row_dist"))
  (setq col-dist (mcp-json-get-number params "col_dist"))
  (if (= entity-id "last") (setq ent (entlast)) (setq ent (handent entity-id)))
  (if ent
    (progn
      (command "_.ARRAY" ent "" "_R" rows cols row-dist col-dist)
      (cons T (strcat "{\"rows\":" (itoa rows) ",\"cols\":" (itoa cols) "}")))
    (cons nil "Entity not found")
  )
)

(defun mcp-cmd-entity-fillet (params / id1 id2 radius ent1 ent2)
  (setq id1 (mcp-json-get-string params "id1"))
  (setq id2 (mcp-json-get-string params "id2"))
  (setq radius (mcp-json-get-number params "radius"))
  (setq ent1 (handent id1))
  (setq ent2 (handent id2))
  (if (and ent1 ent2)
    (progn
      (command "_.FILLET" "_R" radius)
      (command "_.FILLET" ent1 ent2)
      (cons T "\"filleted\""))
    (cons nil "One or both entities not found")
  )
)

(defun mcp-cmd-entity-chamfer (params / id1 id2 dist1 dist2 ent1 ent2)
  (setq id1 (mcp-json-get-string params "id1"))
  (setq id2 (mcp-json-get-string params "id2"))
  (setq dist1 (mcp-json-get-number params "dist1"))
  (setq dist2 (mcp-json-get-number params "dist2"))
  (setq ent1 (handent id1))
  (setq ent2 (handent id2))
  (if (and ent1 ent2)
    (progn
      (command "_.CHAMFER" "_D" dist1 dist2)
      (command "_.CHAMFER" ent1 ent2)
      (cons T "\"chamfered\""))
    (cons nil "One or both entities not found")
  )
)

;; --- command registration ---

(mcp-register "create-arc" 'mcp-cmd-create-arc)
(mcp-register "create-circle" 'mcp-cmd-create-circle)
(mcp-register "create-ellipse" 'mcp-cmd-create-ellipse)
(mcp-register "create-hatch" 'mcp-cmd-create-hatch)
(mcp-register "create-line" 'mcp-cmd-create-line)
(mcp-register "create-mtext" 'mcp-cmd-create-mtext)
(mcp-register "create-polyline" 'mcp-cmd-create-polyline)
(mcp-register "create-rectangle" 'mcp-cmd-create-rectangle)
(mcp-register "entity-array" 'mcp-cmd-entity-array)
(mcp-register "entity-chamfer" 'mcp-cmd-entity-chamfer)
(mcp-register "entity-copy" 'mcp-cmd-entity-copy)
(mcp-register "entity-count" 'mcp-cmd-entity-count)
(mcp-register "entity-erase" 'mcp-cmd-entity-erase)
(mcp-register "entity-fillet" 'mcp-cmd-entity-fillet)
(mcp-register "entity-get" 'mcp-cmd-entity-get)
(mcp-register "entity-list" 'mcp-cmd-entity-list)
(mcp-register "entity-mirror" 'mcp-cmd-entity-mirror)
(mcp-register "entity-move" 'mcp-cmd-entity-move)
(mcp-register "entity-offset" 'mcp-cmd-entity-offset)
(mcp-register "entity-rotate" 'mcp-cmd-entity-rotate)
(mcp-register "entity-scale" 'mcp-cmd-entity-scale)

(princ "\n  mcp_entity loaded (21 commands)")
(princ)
