package tui

import "core:fmt"
import px "core:sys/posix"
import lx "core:sys/linux"
import os "core:os/os2"

Pos     :: [2]i16 // col, row
Rect    :: [4]i16 // col, row, width, height
ORIGIN :: Pos{ 1, 1 }

// TODO: maybe replace with south east north west?
BoxStyle :: struct {
    left        : rune,
    right       : rune,
    top         : rune,
    bot         : rune,

    topLeft     : rune,
    topRight    : rune,
    botLeft     : rune,
    botRight    : rune,
}

BoxType :: enum u8 {
    None,

    Single,
    SingleHeavy,
    SingleCurve,
    Double,

    Dash2,
    Dash2Heavy,
    Dash3,
    Dash3Heavy,
    Dash4,
    Dash4Heavy,
}

BoxTypeMask :: bit_set[BoxType]

BoxCharacter :: struct {
    character : rune,
    masks : [4]BoxTypeMask,
    type : BoxTypeMask,
}

// TODO: some connectors obviously don't work (there's no horizontal line Single-Double), gotta come up with something

// NORTH    EAST    SOUTH    WEST
BoxTypeMask_Light : BoxTypeMask : { .Single, .SingleCurve, .Dash2, .Dash3, .Dash4 }
BoxTypeMask_Heavy : BoxTypeMask : { .SingleHeavy, .Dash2Heavy, .Dash3Heavy, .Dash4Heavy }
BoxTypeMask_1 : BoxTypeMask : { .Single, .SingleHeavy, .SingleCurve, .Dash2, .Dash2Heavy, .Dash3, .Dash3Heavy, .Dash4, .Dash4Heavy }
BoxTypeMask_2 : BoxTypeMask : { .Double }
BoxCharacters : []BoxCharacter = {
    { '─', { { .None }, BoxTypeMask_Light, { .None }, BoxTypeMask_Light }, { .Single, .SingleCurve } },
    { '━', { { .None }, BoxTypeMask_Heavy, { .None }, BoxTypeMask_Heavy }, { .SingleHeavy } },
    { '│', { BoxTypeMask_Light, { .None }, BoxTypeMask_Light, { .None } }, { .Single, .SingleCurve } },
    { '┃', { BoxTypeMask_Heavy, { .None }, BoxTypeMask_Heavy, { .None } }, { .SingleHeavy } },
    { '┄', { { .None }, BoxTypeMask_Light, { .None }, BoxTypeMask_Light }, { .Dash3 } },
    { '┅', { { .None }, BoxTypeMask_Heavy, { .None }, BoxTypeMask_Heavy }, { .Dash3Heavy } },
    { '┆', { BoxTypeMask_Light, { .None }, BoxTypeMask_Heavy, { .None } }, { .Dash3 } },
    { '┇', { BoxTypeMask_Heavy, { .None }, BoxTypeMask_Heavy, { .None } }, { .Dash3Heavy } },
    { '┈', { { .None }, BoxTypeMask_Light, { .None }, BoxTypeMask_Light }, { .Dash4 } },
    { '┉', { { .None }, BoxTypeMask_Heavy, { .None }, BoxTypeMask_Heavy }, { .Dash4Heavy } },
    { '┊', { BoxTypeMask_Light, { .None }, BoxTypeMask_Light, { .None } }, { .Dash4 } },
    { '┋', { BoxTypeMask_Heavy, { .None }, BoxTypeMask_Heavy, { .None } }, { .Dash4Heavy } },
    { '┌', { { .None }, BoxTypeMask_Light, BoxTypeMask_Light, { .None } }, { .Single } },
    { '┍', { { .None }, BoxTypeMask_Heavy, BoxTypeMask_Light, { .None } }, { .Single, .SingleHeavy } },
    { '┎', { { .None }, BoxTypeMask_Light, BoxTypeMask_Heavy, { .None } }, { .Single, .SingleHeavy } },
    { '┏', { { .None }, BoxTypeMask_Heavy, BoxTypeMask_Heavy, { .None } }, { .SingleHeavy } },
    { '┐', { { .None }, { .None }, BoxTypeMask_Light, BoxTypeMask_Light }, { .Single } },
    { '┑', { { .None }, { .None }, BoxTypeMask_Light, BoxTypeMask_Heavy }, { .Single, .SingleHeavy } },
    { '┒', { { .None }, { .None }, BoxTypeMask_Heavy, BoxTypeMask_Light }, { .Single, .SingleHeavy } },
    { '┓', { { .None }, { .None }, BoxTypeMask_Heavy, BoxTypeMask_Heavy }, { .SingleHeavy } },
    { '└', { BoxTypeMask_Light, BoxTypeMask_Light, { .None }, { .None } }, { .Single } },
    { '┕', { BoxTypeMask_Light, BoxTypeMask_Heavy, { .None }, { .None } }, { .Single, .SingleHeavy }},
    { '┖', { BoxTypeMask_Heavy, BoxTypeMask_Light, { .None }, { .None } }, { .Single, .SingleHeavy }},
    { '┗', { BoxTypeMask_Heavy, BoxTypeMask_Heavy, { .None }, { .None } }, { .SingleHeavy } },
    { '┘', { BoxTypeMask_Light, { .None }, { .None }, BoxTypeMask_Light }, { .Single } },
    { '┙', { BoxTypeMask_Light, { .None }, { .None }, BoxTypeMask_Heavy }, { .Single, .SingleHeavy } },
    { '┚', { BoxTypeMask_Heavy, { .None }, { .None }, BoxTypeMask_Light }, { .Single, .SingleHeavy } },
    { '┛', { BoxTypeMask_Heavy, { .None }, { .None }, BoxTypeMask_Heavy }, { .SingleHeavy } },
    { '├', { BoxTypeMask_Light, BoxTypeMask_Light, BoxTypeMask_Light, { .None } }, { .Single } },
    { '┝', { BoxTypeMask_Light, BoxTypeMask_Heavy, BoxTypeMask_Light, { .None } }, { .Single, .SingleHeavy } },
    { '┞', { BoxTypeMask_Heavy, BoxTypeMask_Light, BoxTypeMask_Light, { .None } }, { .Single, .SingleHeavy } },
    { '┟', { BoxTypeMask_Light, BoxTypeMask_Light, BoxTypeMask_Heavy, { .None } }, { .Single, .SingleHeavy } },
    { '┠', { BoxTypeMask_Heavy, BoxTypeMask_Light, BoxTypeMask_Heavy, { .None } }, { .Single, .SingleHeavy } },
    { '┡', { BoxTypeMask_Heavy, BoxTypeMask_Heavy, BoxTypeMask_Light, { .None } }, { .Single, .SingleHeavy } },
    { '┢', { BoxTypeMask_Light, BoxTypeMask_Heavy, BoxTypeMask_Heavy, { .None } }, { .Single, .SingleHeavy } },
    { '┣', { BoxTypeMask_Heavy, BoxTypeMask_Heavy, BoxTypeMask_Heavy, { .None } }, { .SingleHeavy } },

    { '┤', { BoxTypeMask_Light, { .None }, BoxTypeMask_Light, BoxTypeMask_Light }, { .Single } },
    { '┥', { BoxTypeMask_Light, { .None }, BoxTypeMask_Light, BoxTypeMask_Heavy }, { .Single, .SingleHeavy } },
    { '┦', { BoxTypeMask_Heavy, { .None }, BoxTypeMask_Light, BoxTypeMask_Light }, { .Single, .SingleHeavy } },
    { '┧', { BoxTypeMask_Light, { .None }, BoxTypeMask_Heavy, BoxTypeMask_Light }, { .Single, .SingleHeavy } },
    { '┨', { BoxTypeMask_Heavy, { .None }, BoxTypeMask_Heavy, BoxTypeMask_Light }, { .Single, .SingleHeavy } },
    { '┩', { BoxTypeMask_Heavy, { .None }, BoxTypeMask_Heavy, BoxTypeMask_Light }, { .Single, .SingleHeavy } },
    { '┪', { BoxTypeMask_Light, { .None }, BoxTypeMask_Heavy, BoxTypeMask_Heavy }, { .Single, .SingleHeavy } },
    { '┫', { BoxTypeMask_Heavy, { .None }, BoxTypeMask_Heavy, BoxTypeMask_Heavy }, { .SingleHeavy } },

    { '┬', { { .None }, BoxTypeMask_Light, BoxTypeMask_Light, BoxTypeMask_Light }, { .Single } },
    { '┭', { { .None }, BoxTypeMask_Light, BoxTypeMask_Light, BoxTypeMask_Heavy }, { .Single, .SingleHeavy } },
    { '┮', { { .None }, BoxTypeMask_Heavy, BoxTypeMask_Light, BoxTypeMask_Light }, { .Single, .SingleHeavy } },
    { '┯', { { .None }, BoxTypeMask_Heavy, BoxTypeMask_Light, BoxTypeMask_Heavy }, { .Single, .SingleHeavy } },
    { '┰', { { .None }, BoxTypeMask_Light, BoxTypeMask_Heavy, BoxTypeMask_Light }, { .Single, .SingleHeavy } },
    { '┱', { { .None }, BoxTypeMask_Light, BoxTypeMask_Heavy, BoxTypeMask_Heavy }, { .Single, .SingleHeavy } },
    { '┲', { { .None }, BoxTypeMask_Heavy, BoxTypeMask_Heavy, BoxTypeMask_Light }, { .Single, .SingleHeavy } },
    { '┳', { { .None }, BoxTypeMask_Heavy, BoxTypeMask_Heavy, BoxTypeMask_Heavy }, { .SingleHeavy } },

    { '┴', { BoxTypeMask_Light, BoxTypeMask_Light, { .None }, BoxTypeMask_Light }, { .Single } },
    { '┵', { BoxTypeMask_Light, BoxTypeMask_Light, { .None }, BoxTypeMask_Heavy }, { .Single, .SingleHeavy } },
    { '┶', { BoxTypeMask_Light, BoxTypeMask_Heavy, { .None }, BoxTypeMask_Light }, { .Single, .SingleHeavy } },
    { '┷', { BoxTypeMask_Light, BoxTypeMask_Heavy, { .None }, BoxTypeMask_Heavy }, { .Single, .SingleHeavy } },
    { '┸', { BoxTypeMask_Heavy, BoxTypeMask_Light, { .None }, BoxTypeMask_Light }, { .Single, .SingleHeavy } },
    { '┹', { BoxTypeMask_Heavy, BoxTypeMask_Light, { .None }, BoxTypeMask_Heavy }, { .Single, .SingleHeavy } },
    { '┺', { BoxTypeMask_Heavy, BoxTypeMask_Heavy, { .None }, BoxTypeMask_Light }, { .Single, .SingleHeavy } },
    { '┻', { BoxTypeMask_Heavy, BoxTypeMask_Heavy, { .None }, BoxTypeMask_Heavy }, { .SingleHeavy } },

    { '┼', { BoxTypeMask_Light, BoxTypeMask_Light, BoxTypeMask_Light, BoxTypeMask_Light }, { .Single } },
    { '┽', { BoxTypeMask_Light, BoxTypeMask_Light, BoxTypeMask_Light, BoxTypeMask_Heavy }, { .Single, .SingleHeavy } },
    { '┾', { BoxTypeMask_Light, BoxTypeMask_Heavy, BoxTypeMask_Light, BoxTypeMask_Light }, { .Single, .SingleHeavy } },
    { '┿', { BoxTypeMask_Light, BoxTypeMask_Heavy, BoxTypeMask_Light, BoxTypeMask_Heavy }, { .Single, .SingleHeavy } },
    { '╀', { BoxTypeMask_Heavy, BoxTypeMask_Light, BoxTypeMask_Light, BoxTypeMask_Light }, { .Single, .SingleHeavy } },
    { '╁', { BoxTypeMask_Light, BoxTypeMask_Light, BoxTypeMask_Heavy, BoxTypeMask_Light }, { .Single, .SingleHeavy } },
    { '╂', { BoxTypeMask_Heavy, BoxTypeMask_Light, BoxTypeMask_Heavy, BoxTypeMask_Light }, { .Single, .SingleHeavy } },
    { '╃', { BoxTypeMask_Heavy, BoxTypeMask_Light, BoxTypeMask_Light, BoxTypeMask_Heavy }, { .Single, .SingleHeavy } },
    { '╄', { BoxTypeMask_Heavy, BoxTypeMask_Heavy, BoxTypeMask_Light, BoxTypeMask_Light }, { .Single, .SingleHeavy } },
    { '╅', { BoxTypeMask_Light, BoxTypeMask_Light, BoxTypeMask_Heavy, BoxTypeMask_Heavy }, { .Single, .SingleHeavy } },
    { '╆', { BoxTypeMask_Light, BoxTypeMask_Heavy, BoxTypeMask_Heavy, BoxTypeMask_Light }, { .Single, .SingleHeavy } },
    { '╇', { BoxTypeMask_Heavy, BoxTypeMask_Heavy, BoxTypeMask_Light, BoxTypeMask_Heavy }, { .Single, .SingleHeavy } },
    { '╈', { BoxTypeMask_Light, BoxTypeMask_Heavy, BoxTypeMask_Heavy, BoxTypeMask_Heavy }, { .Single, .SingleHeavy } },
    { '╉', { BoxTypeMask_Heavy, BoxTypeMask_Light, BoxTypeMask_Heavy, BoxTypeMask_Heavy }, { .Single, .SingleHeavy } },
    { '╊', { BoxTypeMask_Heavy, BoxTypeMask_Heavy, BoxTypeMask_Heavy, BoxTypeMask_Light }, { .Single, .SingleHeavy } },
    { '╋', { BoxTypeMask_Heavy, BoxTypeMask_Heavy, BoxTypeMask_Heavy, BoxTypeMask_Heavy }, { .SingleHeavy } },

    { '╌', { { .None }, BoxTypeMask_Light, { .None }, BoxTypeMask_Light }, { .Dash2 } },
    { '╍', { { .None }, BoxTypeMask_Heavy, { .None }, BoxTypeMask_Heavy }, { .Dash2Heavy } },
    { '╎', { BoxTypeMask_Light, { .None }, BoxTypeMask_Light, { .None } }, { .Dash2 } },
    { '╏', { BoxTypeMask_Heavy, { .None }, BoxTypeMask_Heavy, { .None } }, { .Dash2Heavy } },

    { '═', { { .None }, BoxTypeMask_2, { .None }, BoxTypeMask_2 }, { .Double } },
    { '║', { BoxTypeMask_2, { .None }, BoxTypeMask_2, { .None } }, { .Double } },
    { '╒', { { .None }, BoxTypeMask_2, BoxTypeMask_1, { .None } }, { .Single, .SingleCurve, .Double } },
    { '╓', { { .None }, BoxTypeMask_1, BoxTypeMask_2, { .None } }, { .Single, .SingleCurve, .Double } },
    { '╔', { { .None }, BoxTypeMask_2, BoxTypeMask_2, { .None } }, { .Double } },
    { '╕', { { .None }, { .None }, BoxTypeMask_1, BoxTypeMask_2 }, { .Single, .SingleCurve, .Double } },
    { '╖', { { .None }, { .None }, BoxTypeMask_2, BoxTypeMask_1 }, { .Single, .SingleCurve, .Double } },
    { '╗', { { .None }, { .None }, BoxTypeMask_2, BoxTypeMask_2 }, { .Double } },
    { '╘', { BoxTypeMask_1, BoxTypeMask_2, { .None }, { .None } }, { .Single, .SingleCurve, .Double } },
    { '╙', { BoxTypeMask_2, BoxTypeMask_1, { .None }, { .None } }, { .Single, .SingleCurve, .Double } },
    { '╚', { BoxTypeMask_2, BoxTypeMask_2, { .None }, { .None } }, { .Double } },
    { '╛', { BoxTypeMask_1, { .None }, { .None }, BoxTypeMask_2 }, { .Single, .SingleCurve, .Double } },
    { '╜', { BoxTypeMask_2, { .None }, { .None }, BoxTypeMask_1 }, { .Single, .SingleCurve, .Double } },
    { '╝', { BoxTypeMask_2, { .None }, { .None }, BoxTypeMask_2 }, { .Double } },

    { '╞', { BoxTypeMask_1, BoxTypeMask_2, BoxTypeMask_1, { .None } }, { .Single, .SingleCurve, .Double } },
    { '╟', { BoxTypeMask_2, BoxTypeMask_1, BoxTypeMask_2, { .None } }, { .Single, .SingleCurve, .Double } },
    { '╠', { BoxTypeMask_2, BoxTypeMask_2, BoxTypeMask_2, { .None } }, { .Double } },
    { '╡', { BoxTypeMask_1, { .None }, BoxTypeMask_1, BoxTypeMask_2 }, { .Single, .SingleCurve, .Double } },
    { '╢', { BoxTypeMask_2, { .None }, BoxTypeMask_2, BoxTypeMask_1 }, { .Single, .SingleCurve, .Double } },
    { '╣', { BoxTypeMask_2, { .None }, BoxTypeMask_2, BoxTypeMask_2 }, { .Double } },
    { '╤', { { .None }, BoxTypeMask_2, BoxTypeMask_1, BoxTypeMask_2 }, { .Single, .SingleCurve, .Double } },
    { '╥', { { .None }, BoxTypeMask_1, BoxTypeMask_2, BoxTypeMask_1 }, { .Single, .SingleCurve, .Double } },
    { '╦', { { .None }, BoxTypeMask_2, BoxTypeMask_2, BoxTypeMask_2 }, { .Double } },
    { '╧', { BoxTypeMask_1, BoxTypeMask_2, { .None }, BoxTypeMask_2 }, { .Single, .SingleCurve, .Double } },
    { '╨', { BoxTypeMask_2, BoxTypeMask_1, { .None }, BoxTypeMask_1 }, { .Single, .SingleCurve, .Double } },
    { '╩', { BoxTypeMask_2, BoxTypeMask_2, { .None }, BoxTypeMask_2 }, { .Double } },
    { '╪', { BoxTypeMask_1, BoxTypeMask_2, BoxTypeMask_1, BoxTypeMask_2 }, { .Single, .SingleCurve, .Double } },
    { '╫', { BoxTypeMask_2, BoxTypeMask_1, BoxTypeMask_2, BoxTypeMask_1 }, { .Single, .SingleCurve, .Double } },
    { '╬', { BoxTypeMask_2, BoxTypeMask_2, BoxTypeMask_2, BoxTypeMask_2 }, { .Double } },

    { '╭', { { .None }, BoxTypeMask_Light, BoxTypeMask_Light, { .None } }, { .SingleCurve } },
    { '╮', { { .None }, { .None }, BoxTypeMask_Light, BoxTypeMask_Light }, { .SingleCurve } },
    { '╯', { BoxTypeMask_Light, { .None }, { .None }, BoxTypeMask_Light }, { .SingleCurve } },
    { '╰', { BoxTypeMask_Light, BoxTypeMask_Light, { .None }, { .None } }, { .SingleCurve } },

    { '╴', { { .None }, { .None }, { .None }, BoxTypeMask_Light }, { .Single, .SingleCurve } },
    { '╵', { BoxTypeMask_Light, { .None }, { .None }, { .None } }, { .Single, .SingleCurve } },
    { '╶', { { .None }, BoxTypeMask_Light, { .None }, { .None } }, { .Single, .SingleCurve } },
    { '╷', { { .None }, { .None }, BoxTypeMask_Light, { .None } }, { .Single, .SingleCurve } },
    { '╸', { { .None }, BoxTypeMask_Heavy, { .None }, { .None } }, { .SingleHeavy } },
    { '╹', { BoxTypeMask_Heavy, { .None }, { .None }, { .None } }, { .SingleHeavy } },
    { '╺', { { .None }, BoxTypeMask_Heavy, { .None }, { .None } }, { .SingleHeavy } },
    { '╻', { { .None }, { .None }, BoxTypeMask_Heavy, { .None } }, { .SingleHeavy } },
    { '╼', { { .None }, BoxTypeMask_Heavy, { .None }, BoxTypeMask_Light }, { .Single, .SingleHeavy, .SingleCurve } },
    { '╽', { BoxTypeMask_Light, { .None }, BoxTypeMask_Heavy, { .None } }, { .Single, .SingleHeavy, .SingleCurve } },
    { '╾', { { .None }, BoxTypeMask_Light, { .None }, BoxTypeMask_Heavy }, { .Single, .SingleHeavy, .SingleCurve } },
    { '╿', { BoxTypeMask_Heavy, { .None }, BoxTypeMask_Light, { .None } }, { .Single, .SingleHeavy, .SingleCurve } },
}

// NOTE: these are i16 so that underflow won't happen when subtracting
winsize :: struct {
    ws_row      : i16,
    ws_col      : i16,
    ws_xpixel   : i16,
    ws_ypixel   : i16,
}

getScreenRect :: proc () -> (r : Rect, ok : bool) {
    w : winsize
    ok = lx.ioctl(px.STDIN_FILENO, lx.TIOCGWINSZ, cast(uintptr)&w) == 0
    r = rect_from_pos({ 0, 0 }, { w.ws_col - 1, w.ws_row - 1 })
    return
}

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

// https://en.wikipedia.org/wiki/Box-drawing_characters
c_drawBox :: proc (r : Rect, s : BoxStyle, fill : bool = false) {
    if r.z <= 1 || r.w <= 1 do return

    c_goto({ r.x, r.y })
    os.write_rune(os.stdout, s.topLeft)

    c_goto({ r.x, r.y + r.w - 1 })
    os.write_rune(os.stdout, s.botLeft)

    c_goto({ r.x + r.z - 1, r.y })
    os.write_rune(os.stdout, s.topRight)

    c_goto({ r.x + r.z - 1, r.y + r.w - 1 })
    os.write_rune(os.stdout, s.botRight)

    c_goto({ r.x + 1, r.y })
    for x in (r.x + 1)..=(r.x + r.z - 2) {
        os.write_rune(os.stdout, s.top)
    }

    c_goto({ r.x + 1, r.y + r.w - 1 })
    for x in (r.x + 1)..=(r.x + r.z - 2) {
        os.write_rune(os.stdout, s.bot)
    }

    for y in (r.y + 1)..=(r.y + r.w - 2) {
        c_goto({ r.x, y })
        os.write_rune(os.stdout, s.left)

        if fill {
            for _ in 0..<(r.w - 2) {
                os.write_rune(os.stdout, ' ')
            }
            os.write_rune(os.stdout, s.right)
        }
        else {
            c_goto({ r.x + r.z - 1, y })
            os.write_rune(os.stdout, s.right)
        }
    }
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

c_drawBoxBuffer :: proc (buffer : Buffer(BoxType), rect : Rect, type : BoxType) {
    // if !rect_within_rect(rect, buffer.rect) { return }
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
                if n not_in c.masks[0] {
                    continue
                }
                if e not_in c.masks[1] {
                    continue
                }
                if s not_in c.masks[2] {
                    continue
                }
                if w not_in c.masks[3] {
                    continue
                }

                candidate = c
                if type in c.type { break }
            }

            fmt.printfln("NESW: [%v, %v, %v, %v], result: %v", n, e, s, w, candidate)

            buffer_set(out, { x, y }, candidate.character)
        }
    }
}




rect_from_pos :: proc (tl : Pos, br : Pos) -> Rect {
    return Rect{ tl.x, tl.y, br.x - tl.x + 1, br.y - tl.y + 1 }
}

br_from_rect :: proc (rect : Rect) -> Pos {
    return Pos{ rect.x + rect.z, rect.y + rect.w }
}

rectInner :: proc (r : Rect) -> Rect {
    return fixRect(r + { 1, 1, -2, -2 })
}

fixRect :: proc (r : Rect) -> (s : Rect) {
    s = r
    if s.z < 0 do s.z = 0
    if s.w < 0 do s.w = 0
    return
}

rect_within_rect :: proc (inner, outer : Rect) -> bool {
    if inner.x < outer.x || inner.y < outer.y { return false }

    x := outer.x - inner.x
    y := outer.y - inner.y
    inner := Rect{ x, y, inner.z - x, inner.w - y }

    if inner.z > outer.z || inner.w > outer.w { return false }

    return true
}


Element :: struct {
    children : [3]^Element,

    render : proc (self : ^Element),
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
    os.flush(os.stdout)

    defer {
        os.write_string(os.stdout, "\e[?25h")
        os.write_string(os.stdout, "\e[?1049l")
        os.flush(os.stdout)
    }

    s1 := BoxStyle{
        left        = '│',
        right       = '│',
        top         = '─',
        bot         = '─',

        topLeft     = '╭',
        topRight    = '╮',
        botLeft     = '╰',
        botRight    = '╯',
    }

    s2 := BoxStyle{
        left        = '║',
        right       = '║',
        top         = '═',
        bot         = '═',

        topLeft     = '╔',
        topRight    = '╗',
        botLeft     = '╚',
        botRight    = '╝',
    }



    p20 := Element{

    }

    p30 := Element{

    }

    p50 := Element{

    }

    root := Element{
        children = { &p20, &p30, &p50 },
    }



    screen := buffer_create(getScreenRect() or_return, rune) or_return
    box := buffer_create(getScreenRect() or_return, BoxType) or_return

    c_drawBoxBuffer(box, { 2, 2, 5, 5 }, .SingleCurve)
    c_drawBoxBuffer(box, box.rect, .SingleCurve)
    c_resolveBoxBuffer(box, screen)

    for _ in 0..<10 {
        c_clear()
        r := getScreenRect() or_break
        // os.write_string(os.stdout, "\e[41m")

        for r in screen.data {
            if r != '\x00' {
                os.write_rune(os.stdout, r)
            }
            else {
                os.write_rune(os.stdout, ' ')
            }
        }
        // c_drawBox({ 2, 2, 10, 10 }, s1, true)
        // c_drawBox({ 3, 3, 8, 3 }, s1)
        // c_drawBox({ 3, 6, 8, 3 }, s1)

        buffer : [32]u8
        n, err := os.read_at_least(os.stdin, buffer[:], 1)
    }


    return true
}

main :: proc () {
    run()
}
