package tui

import "core:fmt"
import px "core:sys/posix"
import lx "core:sys/linux"
import os "core:os/os2"




CellData :: struct {
    r : rune
}

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

c_drawString :: proc (rect : Rect, str : string, inner : bool = true) {
    rect := inner ? rectInner(rect) : rect

    pos := Pos{ rect.x, rect.y }
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

        // TODO: some characters take more horizontal space
        os.write_rune(os.stdout, c)
        pos.x += 1
    }
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
    gaps := cast(u64)len(coefficients) * gap
    if gaps >= value { return }

    value := value - gaps

    one : f64 = 0
    for c in coefficients { one += f64(c) }
    if one == 0 { return }

    total : u64 = 0
    for c, i in coefficients {
        v := u64(f64(value) * (f64(c) / f64(one)))
        values[i] = v
        total += v
    }

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






Element :: struct {
    children : [3]^Element,
    render : proc (self : ^Element, ctx : RenderingContext, rect : Rect),
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



    p20 := Element{

    }

    p30 := Element{

    }

    p50 := Element{

    }

    root := Element{
        children = { &p20, &p30, &p50 },
        render = proc (self : ^Element, ctx : RenderingContext, rect : Rect) {
            c_drawBox(ctx.bufferBoxes, ctx.screenRect, .SingleCurve)
            content := rectInner(ctx.screenRect)

            width := content.z

            c : []u64 = { 2, 3, 5 }
            r : [3]u64
            divideBetween(cast(u64)width, c, r[:], 1)

            c_drawBlock(ctx.bufferBoxes, { content.x + cast(i16)r[0], content.y, 1, content.w }, .SingleCurve)
            c_drawBlock(ctx.bufferBoxes, { content.x + cast(i16)r[0] + cast(i16)r[1], content.y, 1, content.w }, .SingleCurve)
        }
    }



    screen := buffer_create(getScreenRect() or_return, rune) or_return
    box := buffer_create(getScreenRect() or_return, BoxType) or_return

    // c_drawBoxBuffer(box, { 2, 2, 5, 5 }, .Dash4Heavy)
    // c_drawBoxBuffer(box, box.rect, .SingleCurve)
    // c_drawBlockBuffer(box, { 9, 9, 6, 6 }, .Dash2)

    for _ in 0..<3 {
        c_clear()

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
