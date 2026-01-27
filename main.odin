package tui

import "core:fmt"
import px "core:sys/posix"
import lx "core:sys/linux"
import os "core:os/os2"
import "core:math"




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

// c_drawStringGood :: proc (rect : Rect, str : string) -> (truncated : bool) {
//     pos : Pos = rect.xy
//
//     for len(str) > 0 {
//         whitespaceLength := 0
//         for c in str {
//             if !is_space(c) { break }
//             whitespaceLength += 1
//         }
//
//         pos = c_drawStringAt(rect, substring(str, 0, whitespaceLength), pos)
//     }
// }

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



// Table :: struct {
//     colSizes : []i16,
//     rowSizes : []i16,
//
//     rect : Rect,
// }
//
// table_getRect :: proc (table : Table, index : Pos) -> (rect : Rect, ok : bool = false) {
//     if cast(int)index.x >= len(table.colSizes) { return }
//     if cast(int)index.y >= len(table.rowSizes) { return }
//
//     offset := Pos{ 0, 0 }
//     for c in 0..<index.x {
//         offset.x += table.colSizes[c]
//     }
//
//     for r in 0..<index.y {
//         offset.y += table.rowSizes[r]
//     }
//
//     rect = Rect{ table.rect.x + offset.x, table.rect.y + offset.y, table.colSizes[index.x], table.rowSizes[index.y] }
//     rect = rect_intersection(rect, table.rect)
//     ok = true
//     return
// }



negotiate_default :: proc (self : ^Element, constraints : Constraints) -> (size : Pos) {
    return constraints.preferredSize
}

Element :: struct {
    children : []^Element,
    stretch : [2]bool,

    render : proc (self : ^Element, ctx : RenderingContext, rect : Rect),
    negotiate : proc (self : ^Element, constraints : Constraints) -> (size : Pos),
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

Element_Label_default :: Element_Label{
    render = proc (self : ^Element, ctx : RenderingContext, rect : Rect) {
        self := cast(^Element_Label)self
        c_drawString(rect, self.text)
    },

    negotiate = proc (self : ^Element, constraints : Constraints) -> (size : Pos) {
        self := cast(^Element_Label)self
        return { cast(i16)len(self.text), 1 }
    },
}




RenderingContext :: struct {
    bufferBoxes : Buffer(BoxType),
    screenRect : Rect,
}

run :: proc () -> bool {
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


    p20table_magic := Element_Label_default
    p20table_magic.text = "Magic:"

    p20table_type := Element_Label_default
    p20table_type.text = "Type:"

    p20table_magicValue := Element_Label_default
    p20table_magicValue.text = "7f 45 4c 46"

    p20table_typeValue := Element_Label_default
    p20table_typeValue.text = "Shared Object"

    p20table := Element_Table{
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

    p20 := Element{
        children = { &p20table },

        render = proc (self : ^Element, ctx : RenderingContext, rect : Rect) {
            rectTitle, rectLine, rest := rect_splitHorizontalLineGap(rect, 1, 1)

            c_drawString(rectTitle, "ELF Header")
            c_drawBlock(ctx.bufferBoxes, rectLine, .SingleCurve)

            self.children[0]->render(ctx, rest)

            // TODO: i currently have very little clue on how to reasonably determine cell size
            // table := Table{ colSizes = { 9, 30 }, rowSizes = { 1, 1, 1 }, rect = rest }
            //
            // c_drawString(table_getRect(table, { 0, 0 }) or_else {}, "Magic:")
            // c_drawString(table_getRect(table, { 0, 1 }) or_else {}, "Type:")
            // c_drawString(table_getRect(table, { 0, 2 }) or_else {}, "Machine:")
            //
            // c_drawString(table_getRect(table, { 1, 0 }) or_else {}, "7f 45 4c 46 asdvausvdausydvavsdyavsuavysuvvydasvudv")
            // c_drawString(table_getRect(table, { 1, 1 }) or_else {}, "Shared Object")
            // c_drawString(table_getRect(table, { 1, 2 }) or_else {}, "x86-64")
        }
    }

    p30 := Element{
        render = proc (self : ^Element, ctx : RenderingContext, rect : Rect) {
            c_drawString({ rect.x, rect.y, rect.z, 1 }, "Program header")
            c_drawBlock(ctx.bufferBoxes, { rect.x, rect.y + 1, rect.z, 1 }, .SingleCurve)
        }
    }

    p50 := Element{
        render = proc (self : ^Element, ctx : RenderingContext, rect : Rect) {
            c_drawString({ rect.x, rect.y, rect.z, 1 }, "Segment content")
            c_drawBlock(ctx.bufferBoxes, { rect.x, rect.y + 1, rect.z, 1 }, .SingleCurve)
        }
    }

    root := Element{
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

    screen := buffer_create(getScreenRect() or_return, rune) or_return
    box := buffer_create(getScreenRect() or_return, BoxType) or_return

    for _ in 0..<3 {
        c_clear()

        buffer_reset(box, BoxType.None)
        buffer_reset(screen, '\x00')

        ctx := RenderingContext{
            bufferBoxes = box,
            screenRect = getScreenRect() or_break
        }
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
