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
