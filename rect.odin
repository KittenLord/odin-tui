package tui

import "core:fmt"
import px "core:sys/posix"
import lx "core:sys/linux"
import os "core:os/os2"

Pos     :: [2]i16 // col, row
Rect    :: [4]i16 // col, row, width, height


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



rect_from_pos :: proc (tl : Pos, br : Pos) -> Rect {
    return Rect{ tl.x, tl.y, br.x - tl.x + 1, br.y - tl.y + 1 }
}

br_from_rect :: proc (rect : Rect) -> Pos {
    return Pos{ rect.x + rect.z, rect.y + rect.w }
}

rect_inner :: proc (r : Rect) -> Rect {
    return rect_fix(r + { 1, 1, -2, -2 })
}

rect_fix :: proc (r : Rect) -> (s : Rect) {
    s = r
    if s.z < 0 do s.z = 0
    if s.w < 0 do s.w = 0
    return
}

// TODO: we might want a separate type for Size
pos_fix :: proc (p : Pos) -> (s : Pos) {
    s = p
    if s.x < 0 do s.x = 0
    if s.y < 0 do s.y = 0
    return
}

is_rect_within_rect :: proc (inner, outer : Rect) -> bool {
    if inner.x < outer.x || inner.y < outer.y { return false }

    x := outer.x - inner.x
    y := outer.y - inner.y
    inner := Rect{ x, y, inner.z - x, inner.w - y }

    if inner.z > outer.z || inner.w > outer.w { return false }

    return true
}

rect_splitVerticalLine :: proc (rect : Rect, leftTakes : i16) -> (lhs : Rect, rhs : Rect) {
    if leftTakes <= 0 { return { rect.x, rect.y, 0, rect.w }, rect }
    if leftTakes >= rect.z { return rect, { rect.x + rect.z, rect.y, 0, rect.w } }

    return { rect.x, rect.y, leftTakes, rect.w }, { rect.x + leftTakes, rect.y, rect.z - leftTakes, rect.w }
}

rect_splitVerticalLineGap :: proc (rect : Rect, leftTakes : i16, gapSize : i16) -> (lhs : Rect, gap : Rect, rhs : Rect) {
    lhs, gap = rect_splitVerticalLine(rect, leftTakes)
    gap, rhs = rect_splitVerticalLine(gap, gapSize)
    return
}

rect_splitHorizontalLine :: proc (rect : Rect, topTakes : i16) -> (top : Rect, bot : Rect) {
    if topTakes <= 0 { return { rect.x, rect.y, rect.z, 0 }, rect }
    if topTakes >= rect.w { return rect, { rect.x, rect.y + rect.w, rect.z, 0 } }

    return { rect.x, rect.y, rect.z, topTakes }, { rect.x, rect.y + topTakes, rect.z, rect.w - topTakes }
}

rect_splitHorizontalLineGap :: proc (rect : Rect, topTakes : i16, gapSize : i16) -> (top : Rect, gap : Rect, bot : Rect) {
    top, gap = rect_splitHorizontalLine(rect, topTakes)
    gap, bot = rect_splitHorizontalLine(gap, gapSize)
    return
}

rect_intersection :: proc (a, b : Rect) -> (c : Rect) {
    c.x = (a.x > b.x) ? a.x : b.x
    c.y = (a.y > b.y) ? a.y : b.y

    c.z = (a.x + a.z < b.x + b.z) ? a.z + (a.x - c.x) : b.z + (b.x - c.x)
    c.w = (a.y + a.w < b.y + b.w) ? a.w + (a.y - c.y) : b.w + (b.y - c.y)

    return
}

RectAlignmentMode :: enum {
    Begin,      // rect sticks to the smaller coordinate
    End,        // rect sticks to the bigger coordinate
    Shift0,     // rect is aligned to the center, but if margin is uneven it is closer to the smaller coordinate
    Shift1,     // same as Shift0, but closer to the bigger coordinate
    Expand1,    // if margin is uneven, expand the rect by 1
    Shrink1,    // if margin is uneven, shrink the rect by 1
    Fill,       // dont align, just expand
}

// x - offset
// y - length
axis_align :: proc (inner, outer : Pos, mode : RectAlignmentMode = .Shift0) -> (aligned : Pos) {
    if mode == .Begin { return { outer.x, inner.y } }
    if mode == .Fill  { return outer.xy }
    if mode == .End   { return { outer.x + (outer.y - inner.y), inner.y } }

    doubleOffset := (outer.y - inner.y)
    offset := doubleOffset / 2
    size := inner.y

    if doubleOffset % 2 == 0 { return { outer.x + offset, size } }

    if mode == .Shift1 { offset += 1 }
    if mode == .Expand1 { size += 1 }
    if mode == .Shrink1 {
        offset += 1
        size -= 1
    }

    return { outer.x + offset, size }
}

rect_align :: proc (inner, outer : Rect, mode : [2]RectAlignmentMode = { .Shift0, .Shift0 }) -> (aligned : Rect) {
    x := axis_align(inner.xz, outer.xz, mode.x)
    y := axis_align(inner.yw, outer.yw, mode.y)

    return { x.x, y.x, x.y, y.y }
}
