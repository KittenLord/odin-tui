package tui

import "core:fmt"
import px "core:sys/posix"
import lx "core:sys/linux"
import os "core:os/os2"
import os_old "core:os"
import "core:math"
import "core:slice"

import str "core:strings"
import utf8 "core:unicode/utf8"

import "core:log"







/* How the table will work

Negotiating
Each column and row is either MinimalPossible, MinimalNecessary, or Expand
    - MinimalPossible   - preferredSize == 1
    - MinimalNecessary  - preferredSize == rect.z / numCols
    - Expand            - preferredSize == rect.z / numCols

After determining the preferredSize, table negotiates size with each cell,
collecting the results. We calculate the maxCol and maxRow for each column
and row. After that we check whether total of maxCol and total of maxRow
summed up fit and fill the preferredSize and maxSize provided to the table.
    - if it is larger than maxSize, we must subtract from cols and rows with
      the lowest priority (and probably renegotiate with affected cells)
    - if it is different from preferredSize we do not care, since the result
      of negotiate is the minimal comfortable space for the element. The space
      we have calculated is indeed the minimal comfortable

Rendering
The procedure is very similar, the only difference is that we have an explicit
rect to fill. We have three cases - 1. Perfect fit. 2. Too small. 3. Too big
    1. We are done
    2. We add extra space to cols/rows with Expand -> MinimalNecessary ->
       MinimalPossible, additionally adjusted by priority
    3. We remove extra space from Expand -> MinimalNecessary -> MinimalPossible,
       inversely adjusted by priority

*/



MAX_SIZE : Pos : { 1000, 1000 }

Constraints :: struct {
    maxSize : Pos,
    preferredSize : Pos,

    widthByHeightPriceRatio : f64,
}




Filling :: enum {
    MinimalPossible,
    MinimalNecessary,
    Expand,
}

Stretching :: struct {
    priority : int,
    fill : Filling,
}




Wrapping :: enum {
    Wrapping,       // word gets cut at the end of the line, gets continued immediately on the next one
    NoWrapping,     // if word doesn't fit on the current line, move it to the second. If it doesn't fit there either, move back to the first and fall back to Wrapping
    // Hyphenation,    // Wrapping, but with hyphens
}




AlignmentHorizontal :: enum {
    Left,
    Mid,
    Right,
}

AlignmentVertical :: enum {
    Top,
    Mid,
    Bot,
}

Alignment :: struct {
    horizontal : AlignmentHorizontal,
    vertical   : AlignmentVertical,
}




CellData :: struct {
    r : rune
}

// NOTE: data is sequential rows
Buffer :: struct($Item : typeid) {
    rect : Rect,
    data : []Item,
}

buffer_create :: proc (r : Rect, $ty : typeid) -> (buffer : Buffer(ty), ok : bool = false) {
    size := r.z * r.w
    buffer = Buffer(ty){ rect = r, data = make([]ty, size) }
    ok = true
    return
}

buffer_get :: proc (buffer : Buffer($ty), pos : Pos, relative : bool = true) -> (cell : ty, ok : bool = false) {
    rpos := (!relative) ? (pos - buffer.rect.xy) : pos
    if rpos.x < 0 || rpos.y < 0 { return }
    if rpos.x >= buffer.rect.z || rpos.y >= buffer.rect.w { return }

    index := rpos.y * buffer.rect.z + rpos.x
    if index < 0 || cast(int)index >= len(buffer.data) { return }
    return buffer.data[index], true
}

buffer_set :: proc (buffer : Buffer($ty), pos : Pos, value : ty, relative : bool = true) -> (ok : bool = false) {
    rpos := (!relative) ? (pos - buffer.rect.xy) : pos
    if rpos.x < 0 || rpos.y < 0 { return }
    if rpos.x >= buffer.rect.z || rpos.y >= buffer.rect.w { return }
    index := rpos.y * buffer.rect.z + rpos.x
    if index < 0 || cast(int)index >= len(buffer.data) { return }
    buffer.data[index] = value
    ok = true
    return
}

buffer_reset :: proc (buffer : Buffer($ty), value : ty) {
    for i in 0..<(buffer.rect.z * buffer.rect.w) {
        buffer.data[i] = value
    }
}

buffer_copyToBuffer :: proc (dst : Buffer($ty), src : Buffer(ty), offset : Pos = { 0, 0 }) {
    for x in 0..<src.rect.z {
        for y in 0..<src.rect.w {
            buffer_set(dst, { x, y } + src.rect.xy + offset, buffer_get(src, { x, y }) or_continue)
        }
    }
}

buffer_present :: proc (buffer : Buffer(rune)) {
    consecutive := true
    c_goto(buffer.rect.xy)

    for y in 0..<buffer.rect.w {
        for x in 0..<buffer.rect.z {
            r := buffer_get(buffer, { x, y }) or_continue
            if r == '\x00' {
                consecutive = false
                continue
            }

            if !consecutive {
                c_goto({ x, y })
                consecutive = true
            }

            os.write_rune(os.stdout, r)
        }

        // NOTE: unless buffer is the width of the screen
        consecutive = false
    }
}


// TODO: we will replace os.write_string to writing into a
// temporary buffer

c_clear :: proc () {
    os.write_string(os.stdout, "\e[2J")
}

c_goto :: proc (p : Pos) {
    buffer : [32]u8
    s := fmt.bprintf(buffer[:], "\e[%v;%vH", p.y + 1, p.x + 1)
    os.write_string(os.stdout, s)
}

c_drawStringAt :: proc (rect : Rect, str : string, pos : Pos) -> (end : Pos) {
    pos := pos
    c_goto(pos)

    br := br_from_rect(rect)

    for c in str {
        if pos.x >= br.x {
            pos.x = rect.x
            pos.y += 1
            c_goto(pos)
        }

        if pos.y >= br.y {
            break
        }

        if c == '\n' {
            pos.x = rect.x
            pos.y += 1
            c_goto(pos)
        }
        else if c == '\r' {
            pos.x = rect.x
            c_goto(pos)
        }
        else {
            // TODO: some characters take more horizontal space
            os.write_rune(os.stdout, c)
            pos.x += 1
        }
    }

    end = pos
    return
}

c_drawString :: proc (rect : Rect, str : string) {
    c_drawStringAt(rect, str, rect.xy)
}

Recorder :: struct {
    rect : Rect,
    pos  : Pos,

    render : bool,
}

recorder_start :: proc (r : ^Recorder) {
    if r.render { c_goto(r.pos) }
}

recorder_done :: proc (r : Recorder) -> bool {
    return recorder_remaining(r).y <= 0
}

recorder_newline :: proc (r : ^Recorder, offset : i16 = 0) -> (ok : bool = false) {
    if recorder_done(r^) { return }
    if offset >= r.rect.z { return }

    r.pos.y += 1
    r.pos.x = r.rect.x + offset

    if r.render { c_goto(r.pos) }

    ok = true
    return
}

recorder_remaining :: proc (r : Recorder) -> Pos {
    return r.rect.xy + r.rect.zw - r.pos
}

// NOTE: Does NOT add a newline on the end

// 0, text, false
// n, rem, true
recorder_writeOnCurrentLine :: proc (r : ^Recorder, text : string) -> (written : i16 = 0, remaining : string, ok : bool = false) {
    remaining = text
    if recorder_done(r^) { return }

    rm := recorder_remaining(r^)
    l := math.min(cast(int)rm.x, len(text))

    taken, _ := str.substring_to(text, l)
    written = cast(i16)len(taken)
    remaining, _ = substring_from(text, l)

    if r.render { os.write_string(os.stdout, taken) }

    r.pos.x += cast(i16)l

    ok = true
    return
}

recorder_write :: proc (r : ^Recorder, text : string) -> (written : i16 = 0, remaining : string) {
    remaining = text

    for !recorder_done(r^) && len(remaining) > 0 {
        w : i16
        w, remaining, _ = recorder_writeOnCurrentLine(r, remaining)
        written += w
        recorder_newline(r, 0)
    }

    return
}

recorder_writeRuneOnCurrentLine :: proc (r : ^Recorder, c : rune) -> (ok : bool = false) {
    if recorder_done(r^) { return }
    if recorder_remaining(r^).x <= 0 { return }

    if r.render { os.write_rune(os.stdout, c) }

    r.pos.x += 1
    ok = true
    return
}

// TODO: stretching
drawText :: proc (text : string, rect : Rect, align : Alignment, wrap : Wrapping, rendering : bool = true, lineLengths : []i16 = nil) -> (actualRect : Rect, truncated : bool) {
    lineLengths := lineLengths

    if rendering {
        lineLengths = make([]i16, rect.w)
        drawText(text, rect, align, wrap, false, lineLengths)
    }

    defer if rendering {
        delete(lineLengths)
    }

    buffer := make([]u8, rect.z * 4)
    defer delete(buffer)
    
    sb := str.builder_from_bytes(buffer)

    // ALIGN
    r := Recorder{ rect, rect.xy, rendering }
    recorder_start(&r)

    if lineLengths != nil { lineLengths[0] = 0 }

    loff := -rect.y

    currentLine : i16 = 0
    maxLine : i16 = 0
    minOffset : i16 = 0

    newlineAligned :: proc (r : ^Recorder, lineLengths : []i16, loff : i16, currentLine : ^i16, minOffset : ^i16, align : Alignment) -> bool {
        if recorder_remaining(r^).y <= 1 { return false }

        precalculatedLength := lineLengths != nil ? lineLengths[r.pos.y + loff + 1] : 0
        // TODO: calculate offset based off alignment
        offset := precalculatedLength == 0 ? 0 : (precalculatedLength * 0)
        if offset < minOffset^ { minOffset^ = offset }

        recorder_newline(r, offset)

        if lineLengths != nil { lineLengths[r.pos.y + loff] = 0 }
        currentLine^ = 0

        return true
    }

    increaseLineLength :: proc (value : i16, r : Recorder, lineLengths : []i16, loff : i16, currentLine : ^i16, maxLine : ^i16) {
        if lineLengths != nil {
            lineLengths[r.pos.y + loff] += value
        }

        currentLine^ += value
        if currentLine^ > maxLine^ { maxLine^ = currentLine^ }
    }




    State :: enum {
        SkippingWhitespace,
        CollectingShortWord,
        DumpingLargeWord,
    }

    state : State = .SkippingWhitespace



    text := text
    mainLoop: for len(text) > 0 || str.builder_len(sb) > 0 {
        advance := true

        c := utf8.rune_at_pos(text, 0)
        eof := len(text) == 0

        defer if advance {
            text, _ = substring_from(text, 1)
        }

        switch state {
        case .SkippingWhitespace: {
            if !str.is_space(c) {
                advance = false
                state = .CollectingShortWord
                continue mainLoop
            }

            continue mainLoop
        }
        case .CollectingShortWord: {
            if eof || str.is_space(c) {
                advance = false
                state = .SkippingWhitespace
                defer str.builder_reset(&sb)

                spacebar := currentLine != 0 ? 1 : 0

                if recorder_remaining(r).x >= i16(str.builder_len(sb) + spacebar) {
                    increaseLineLength(i16(str.builder_len(sb) + spacebar), r, lineLengths, loff, &currentLine, &maxLine)

                    if spacebar == 1 { recorder_writeOnCurrentLine(&r, " ") }
                    recorder_writeOnCurrentLine(&r, str.to_string(sb))

                    continue mainLoop
                }


                switch wrap {
                case .NoWrapping: {
                    if recorder_remaining(r).x < i16(str.builder_len(sb) + spacebar) {
                        newlineAligned(&r, lineLengths, loff, &currentLine, &minOffset, align) or_break mainLoop
                    }
                    else if spacebar == 1 {
                        recorder_writeOnCurrentLine(&r, " ")
                        increaseLineLength(1, r, lineLengths, loff, &currentLine, &maxLine)
                    }

                    recorder_writeOnCurrentLine(&r, str.to_string(sb))
                    increaseLineLength(cast(i16)len(str.to_string(sb)), r, lineLengths, loff, &currentLine, &maxLine)
                }
                case .Wrapping: {
                    if recorder_remaining(r).x >= 2 {
                        recorder_writeOnCurrentLine(&r, " ")
                        increaseLineLength(1, r, lineLengths, loff, &currentLine, &maxLine)
                    }
                    else {
                        newlineAligned(&r, lineLengths, loff, &currentLine, &minOffset, align) or_break mainLoop
                    }

                    written, remaining, _ := recorder_writeOnCurrentLine(&r, str.to_string(sb))
                    increaseLineLength(written, r, lineLengths, loff, &currentLine, &maxLine)

                    newlineAligned(&r, lineLengths, loff, &currentLine, &minOffset, align) or_break mainLoop

                    // NOTE: 2 writes are guaranteed to be enough
                    written, _, _ = recorder_writeOnCurrentLine(&r, remaining)
                    increaseLineLength(written, r, lineLengths, loff, &currentLine, &maxLine)

                    continue mainLoop
                }
                }
            }
            else {
                str.write_rune(&sb, c)

                if str.builder_len(sb) >= cast(int)rect.z {
                    state = .DumpingLargeWord
                    continue mainLoop
                }
            }
        }
        case .DumpingLargeWord: {
            if str.builder_len(sb) != 0 {
                if currentLine != 0 {
                    if recorder_remaining(r).x >= 2 {
                        recorder_writeOnCurrentLine(&r, " ")
                        increaseLineLength(1, r, lineLengths, loff, &currentLine, &maxLine)
                    }
                    else {
                        newlineAligned(&r, lineLengths, loff, &currentLine, &minOffset, align) or_break mainLoop
                    }
                }

                remaining := str.to_string(sb)

                for len(remaining) > 0 {
                    written : i16
                    written, remaining, _ = recorder_writeOnCurrentLine(&r, remaining)
                    increaseLineLength(written, r, lineLengths, loff, &currentLine, &maxLine)

                    if len(remaining) > 0 {
                        newlineAligned(&r, lineLengths, loff, &currentLine, &minOffset, align) or_break mainLoop
                        written, _, _ = recorder_writeOnCurrentLine(&r, remaining)
                        increaseLineLength(written, r, lineLengths, loff, &currentLine, &maxLine)
                    }
                }

                str.builder_reset(&sb)
            }

            if eof { break mainLoop }

            if str.is_space(c) {
                advance = false
                state = .SkippingWhitespace
                continue mainLoop
            }

            ok := recorder_writeRuneOnCurrentLine(&r, c)
            if !ok {
                newlineAligned(&r, lineLengths, loff, &currentLine, &minOffset, align) or_break mainLoop

                ok = recorder_writeRuneOnCurrentLine(&r, c)
                if !ok { break mainLoop } // NOTE: should never happen
            }
        }
        }
    }

    if currentLine != 0 { recorder_newline(&r) }

    actualRect = { rect.x + minOffset, rect.y, maxLine, math.min(rect.w, r.pos.y - r.rect.y) }
    truncated = (len(text) != 0 || str.builder_len(sb) != 0)

    return
}

c_drawBox :: proc (buffer : Buffer(BoxType), rect : Rect, type : BoxType) {
    br := br_from_rect(rect)

    for x in rect.x..<br.x {
        buffer_set(buffer, Pos{ x,   rect.y }, type)
        buffer_set(buffer, Pos{ x, br.y - 1 }, type)
    }

    for y in (rect.y + 1)..<(br.y - 1) {
        buffer_set(buffer, Pos{ rect.x,   y }, type)
        buffer_set(buffer, Pos{ br.x - 1, y }, type)
    }
}

// NOTE: mostly for drawing lines
c_drawBlock :: proc (buffer : Buffer(BoxType), rect : Rect, type : BoxType) {
    br := br_from_rect(rect)

    for x in rect.x..<br.x {
        for y in rect.y..<br.y {
            buffer_set(buffer, Pos{ x, y }, type)
        }
    }
}

c_resolveBoxBuffer :: proc (buffer : Buffer(BoxType), out : Buffer(rune)) {
    for x in 0..<buffer.rect.z {
        for y in 0..<buffer.rect.w {
            type := buffer_get(buffer, { x, y }) or_continue
            if type == .None { continue }

            n := buffer_get(buffer, { x, y - 1 }) or_else .None
            e := buffer_get(buffer, { x + 1, y }) or_else .None
            s := buffer_get(buffer, { x, y + 1 }) or_else .None
            w := buffer_get(buffer, { x - 1, y }) or_else .None

            candidate : BoxCharacter
            for c in BoxCharacters {
                if n not_in c.masks[0] ||
                   e not_in c.masks[1] ||
                   s not_in c.masks[2] ||
                   w not_in c.masks[3] { continue }

                candidate = c
                if type in c.type { break }
            }

            buffer_set(out, { x, y }, candidate.character)
        }
    }
}





divideBetween :: proc (value : u64, coefficients : []u64, values : []u64, gap : u64 = 0) {
    gaps := (cast(u64)len(coefficients) - 1) * gap
    if gaps >= value { return }

    value := value - gaps

    one : f64 = 0
    for c in coefficients { one += f64(c) }
    if one == 0 { return }

    total : u64 = 0
    for c, i in coefficients {
        v := u64(f64(value) * (f64(c) / one))
        values[i] = v
        total += v
    }

    if total >= value { return }

    // TODO: I'm not sure if this is adequate, we need to prioritize larger coefficients and probably do it without a loop
    rest := value - total
    for rest > 0 {
        for c, i in coefficients {
            if rest == 0 { break }
            if c == 0 { continue }
            values[i] += 1
            rest -= 1
        }
    }
}




negotiate_default :: proc (self : ^Element, constraints : Constraints) -> (size : Pos) {
    return constraints.preferredSize
}

Element :: struct {
    kind : string,

    children : []^Element,
    parent : ^Element,
    stretch : [2]bool,

    render : proc (self : ^Element, ctx : RenderingContext, rect : Rect),
    negotiate : proc (self : ^Element, constraints : Constraints) -> (size : Pos),
}

element_assignParentRecurse :: proc (root : ^Element) {
    for e in root.children {
        e.parent = root
        element_assignParentRecurse(e)
    }
}

element_getParentIndex :: proc (target : ^Element) -> int {
    if target.parent == nil || target.parent == target { return 0 }

    // NOTE: should never return -1 if set up correctly
    i, s := slice.linear_search(target.parent.children, target)
    if !s {
        panic("element_assignParentRecurse")
    }
    return i
}

element_getParentIndexSameKind :: proc (target : ^Element) -> int {
    if target.parent == nil || target.parent == target { return 0 }

    i := 0
    for e in target.parent.children {
        if e == target { return i }
        if e.kind == target.kind { i += 1 }
    }

    panic("element_assignParentRecurse")
}

element_getFullKindName :: proc (target : ^Element) -> string {
    b, _ := str.builder_make_none()
    l : [dynamic]^Element

    target := target
    append(&l, target)
    for target.parent != nil && target.parent != target {
        target = target.parent
        append(&l, target)
    }

    slice.reverse(l[:])

    for e, i in l {
        if i != 0 {
            fmt.sbprint(&b, " > ")
        }

        fmt.sbprintf(&b, "%v #%v", e.kind, element_getParentIndexSameKind(e))
    }

    return str.to_string(b)
}

Element_Table :: struct {
    using base : Element,
    configuration : Buffer(int),

    stretchingCols : []Stretching,
    stretchingRows : []Stretching,
}

Element_Label :: struct {
    using base : Element,
    text : string,
}

// TODO: THIS IS INCORRECT, JUST TEMPORARY
buyIncrement :: proc (base : Pos, old : Pos, max : Pos, widthByHeightPriceRatio : f64) -> (new : Pos) {
    new = old
    if base + old == max { return }

    heightByHeightPriceRatio : f64 = 1

    costH := cast(f64)old.y * heightByHeightPriceRatio
    costW := cast(f64)old.x * widthByHeightPriceRatio

    ncostH := cast(f64)(old.y + 1) * heightByHeightPriceRatio
    ncostW := cast(f64)(old.x + 1) * widthByHeightPriceRatio

    if base.y + old.y + 1 > max.y { ncostH = 99999999999 }
    if base.x + old.x + 1 > max.x { ncostW = 99999999999 }

    if (ncostH + costW) < (costH + ncostW) {
        new.y += 1
    }
    else {
        new.x += 1
    }

    return
}

Element_Label_default :: Element_Label{
    kind = "Label",

    render = proc (self : ^Element, ctx : RenderingContext, rect : Rect) {
        self := cast(^Element_Label)self

        name := element_getFullKindName(self)
        defer delete(name)

        log.debugf("[%v] got rect %v", name, rect)

        drawText(self.text, rect, { .Left, .Top }, .NoWrapping)
    },

    negotiate = proc (self : ^Element, constraints : Constraints) -> (size : Pos) {
        self := cast(^Element_Label)self

        name := element_getFullKindName(self)
        defer delete(name)

        referenceRect := constraints.preferredSize
        rect, truncated := drawText(self.text, { 0, 0, referenceRect.x, referenceRect.y }, { .Left, .Top }, .NoWrapping, rendering = false)
        increment := Pos{ 0, 0 }
        log.debugf("[%v] got constraints %v %v", name, constraints.preferredSize, constraints.maxSize)
        log.debugf("truncated %v", truncated)

        for truncated && (rect.zw + increment) != constraints.maxSize {
            // TODO: increase increment
            increment = buyIncrement(rect.zw, increment, constraints.maxSize, constraints.widthByHeightPriceRatio)
            log.debugf("increment %v", increment)

            _, truncated = drawText(self.text, { 0, 0, rect.z + increment.x, rect.w + increment.y }, { .Left, .Top }, .NoWrapping, rendering = false)
        }

        log.debugf("truncated %v", truncated)
        log.debugf("returned %v", rect.zw + increment)
        
        return rect.zw + increment
    },
}




RenderingContext :: struct {
    bufferBoxes : Buffer(BoxType),
    screenRect : Rect,
}

run :: proc () -> bool {
    // when ODIN_DEBUG
    logFile, _ := os_old.open("./log.txt", os_old.O_CREATE | os_old.O_TRUNC | os_old.O_RDWR)
    context.logger = log.create_file_logger(logFile, .Debug, { .Level, .Short_File_Path, .Line })

    p20table_magic := Element_Label_default
    p20table_magic.text = "Magic:"

    p20table_type := Element_Label_default
    p20table_type.text = "Type:"

    p20table_magicValue := Element_Label_default
    p20table_magicValue.text = "7f 45 4c 46"

    p20table_typeValue := Element_Label_default
    p20table_typeValue.text = "Shared Object"

    p20table := Element_Table{
        kind = "Table",

        children = { &p20table_magic, &p20table_type, &p20table_magicValue, &p20table_typeValue },
        stretch = { true, false },
        configuration = Buffer(int){ rect = { 0, 0, 2, 2 }, data = { 0, 2, 1, 3 } },

        stretchingCols = { Stretching{ priority = 0, fill = .MinimalNecessary }, Stretching{ priority = 1, fill = .Expand } },
        stretchingRows = { Stretching{ priority = 0, fill = .MinimalPossible }, Stretching{ priority = 0, fill = .MinimalPossible } },

        render = proc (self : ^Element, ctx : RenderingContext, rect : Rect) {
            self := cast(^Element_Table)self

            maxCols := make([]i16, self.configuration.rect.z)
            maxRows := make([]i16, self.configuration.rect.w)
            defer delete(maxCols)
            defer delete(maxRows)

            // TODO: loop in order of multiplicative preference
            for x in 0..<self.configuration.rect.z {
                for y in 0..<self.configuration.rect.w {
                    n := buffer_get(self.configuration, { x, y }) or_continue
                    e := self.children[n]

                    preferredSize := Pos{ rect.z / self.configuration.rect.z, rect.w / self.configuration.rect.w }

                    if self.stretchingCols[x].fill == .MinimalPossible { preferredSize.x = 1 }
                    if self.stretchingRows[y].fill == .MinimalPossible { preferredSize.y = 1 }

                    // TODO: still not sure about this
                    wbhRatio := (f64(rect.z)) / (f64(rect.w))

                    size := e->negotiate(Constraints{ maxSize = rect.zw, preferredSize = preferredSize, widthByHeightPriceRatio = wbhRatio })
                    maxCols[x] = maxCols[x] > size.x ? maxCols[x] : size.x
                    maxRows[y] = maxRows[y] > size.y ? maxRows[y] : size.y
                }
            }

            totalCols : i16 = 0
            for n in maxCols {
                totalCols += n
            }

            totalRows : i16 = 0
            for n in maxRows {
                totalRows += n
            }


            // TODO: a lot of doubling
            priorityCols := make([]u64, self.configuration.rect.z)
            priorityRows := make([]u64, self.configuration.rect.w)
            deltaCols := make([]i64, self.configuration.rect.z)
            deltaRows := make([]i64, self.configuration.rect.w)
            defer delete(priorityCols)
            defer delete(priorityRows)
            defer delete(deltaCols)
            defer delete(deltaRows)

            for s, i in self.stretchingCols {
                m : u64 = cast(u64)s.priority * 20
                switch s.fill {
                case .MinimalPossible:
                    m = 1
                case .MinimalNecessary:
                    m *= 1
                case .Expand:
                    m *= 5
                }

                priorityCols[i] = m
            }

            for s, i in self.stretchingRows {
                m : u64 = cast(u64)s.priority * 20
                switch s.fill {
                case .MinimalPossible:
                    m = 1
                case .MinimalNecessary:
                    m *= 1
                case .Expand:
                    m *= 5
                }

                priorityRows[i] = m
            }

            dc := rect.z - totalCols
            if dc > 0 && !self.stretch.x { dc = 0 }

            dr := rect.w - totalRows
            if dr > 0 && !self.stretch.y { dr = 0 }

            divideBetween(cast(u64)math.abs(dc), priorityCols, transmute([]u64)deltaCols)
            divideBetween(cast(u64)math.abs(dr), priorityRows, transmute([]u64)deltaRows)

            sc : i16 = rect.z > totalCols ? 1 : -1
            sr : i16 = rect.w > totalRows ? 1 : -1

            // TODO: this can result in a negative width/height, somehow adjust divideBetween???
            for d, i in deltaCols {
                maxCols[i] += sc * cast(i16)d
            }

            for d, i in deltaRows {
                maxRows[i] += sr * cast(i16)d
            }







            offset := rect.xy
            for x in 0..<self.configuration.rect.z {
                for y in 0..<self.configuration.rect.w {
                    n := buffer_get(self.configuration, { x, y }) or_continue
                    e := self.children[n]

                    msize := Pos{ maxCols[x], maxRows[y] }
                    // TODO: maybe a few renegotiation rounds? idk
                    // size := e->negotiate({ minSize = { 0, 0 }, maxSize = rect.zw, preferredSize = msize, widthByHeightPriceRatio = 1 })
                    e->render(ctx, { offset.x, offset.y, msize.x, msize.y })

                    offset.y += msize.y
                }

                offset.y = rect.y
                offset.x += (maxCols[x])
            }
        }
    }

    p20text := Element_Label_default
    p20text.text = "According to all known laws of aviation, there is no way a bee should be able to fly. Its wings are too small to get its fat little body off the ground. The bee, of course, flies anyway because bees don't care what humans think is impossible."

    p20 := Element{
        kind = "P20",

        children = { &p20table },

        render = proc (self : ^Element, ctx : RenderingContext, rect : Rect) {
            rectTitle, rectLine, rest := rect_splitHorizontalLineGap(rect, 1, 1)

            c_drawString(rectTitle, "ELF Header")
            c_drawBlock(ctx.bufferBoxes, rectLine, .SingleCurve)

            self.children[0]->render(ctx, rest)
        }
    }

    p30 := Element{
        kind = "P30",

        render = proc (self : ^Element, ctx : RenderingContext, rect : Rect) {
            c_drawString({ rect.x, rect.y, rect.z, 1 }, "Program header")
            c_drawBlock(ctx.bufferBoxes, { rect.x, rect.y + 1, rect.z, 1 }, .SingleCurve)
        }
    }

    p50 := Element{
        kind = "P50",

        render = proc (self : ^Element, ctx : RenderingContext, rect : Rect) {
            c_drawString({ rect.x, rect.y, rect.z, 1 }, "Segment content")
            c_drawBlock(ctx.bufferBoxes, { rect.x, rect.y + 1, rect.z, 1 }, .SingleCurve)
        }
    }

    root := Element{
        kind = "Root",

        children = { &p20, &p30, &p50 },
        render = proc (self : ^Element, ctx : RenderingContext, rect : Rect) {
            c_drawBox(ctx.bufferBoxes, ctx.screenRect, .SingleCurve)
            content := rect_inner(ctx.screenRect)

            width := content.z

            c : []u64 = { 2, 3, 5 }
            r : [3]u64
            divideBetween(cast(u64)width, c, r[:], 1)

            rectA, lineAB, rectBC := rect_splitVerticalLineGap(content, cast(i16)r[0], 1)
            rectB, lineBC, rectC := rect_splitVerticalLineGap(rectBC, cast(i16)r[1], 1)

            c_drawBlock(ctx.bufferBoxes, lineAB, .SingleCurve)
            c_drawBlock(ctx.bufferBoxes, lineBC, .SingleCurve)

            self.children[0]->render(ctx, rectA)
            self.children[1]->render(ctx, rectB)
            self.children[2]->render(ctx, rectC)
        }
    }



    term : px.termios
    _ = px.tcgetattr(px.STDIN_FILENO, &term)
    termRestore := term
    defer px.tcsetattr(px.STDIN_FILENO, .TCSANOW, &termRestore)

    term.c_lflag -= { .ECHO, .ICANON }
    px.tcsetattr(px.STDIN_FILENO, .TCSANOW, &term)



    os.write_string(os.stdout, "\e[?25l")
    os.write_string(os.stdout, "\e[?1049h")

    defer {
        os.write_string(os.stdout, "\e[?25h")
        os.write_string(os.stdout, "\e[?1049l")
    }



    screen := buffer_create(getScreenRect() or_return, rune) or_return
    box := buffer_create(getScreenRect() or_return, BoxType) or_return

    for _ in 0..<6 {
        c_clear()

        buffer_reset(box, BoxType.None)
        buffer_reset(screen, '\x00')

        ctx := RenderingContext{
            bufferBoxes = box,
            screenRect = getScreenRect() or_break
        }

        element_assignParentRecurse(&root)
        root->render(ctx, ctx.screenRect)

        c_resolveBoxBuffer(box, screen)
        buffer_present(screen)

        buffer : [32]u8
        n, err := os.read_at_least(os.stdin, buffer[:], 1)
    }


    return true
}

main :: proc () {
    run()
}
