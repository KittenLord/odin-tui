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

// NOTE: these are i16 so that underflow won't happen when subtracting
winsize :: struct {
    ws_row      : i16,
    ws_col      : i16,
    ws_xpixel   : i16,
    ws_ypixel   : i16,
}

getScreenSize :: proc () -> (size : Pos, ok : bool) {
    w : winsize
    ok = lx.ioctl(px.STDIN_FILENO, lx.TIOCGWINSZ, cast(uintptr)&w) == 0
    size = { w.ws_col, w.ws_row }
    return
}

getScreenRect :: proc () -> (r : Rect, ok : bool) {
    size : Pos
    size, ok = getScreenSize()
    r = rect_from_pos(ORIGIN, size)
    return
}

CellData :: struct {
    r : rune
}

createBuffer :: proc (r : Rect) -> (buffer : []CellData, ok : bool = false) {
    size := r.z * r.w
    buffer = make([]CellData, size)
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
    s := fmt.bprintf(buffer[:], "\e[%v;%vH", p.y, p.x)
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



Element :: struct {
    children : [3]^Element
}


main :: proc () {
    term : px.termios
    _ = px.tcgetattr(px.STDIN_FILENO, &term)
    termRestore := term
    defer px.tcsetattr(px.STDIN_FILENO, .TCSANOW, &termRestore)

    term.c_lflag -= { .ECHO, .ICANON }

    px.tcsetattr(px.STDIN_FILENO, .TCSANOW, &term)

    os.write_string(os.stdout, "\e[?25l")

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


    for {
        c_clear()
        r := getScreenRect() or_break
        os.write_string(os.stdout, "\e[41m")
        c_drawBox({ 2, 2, 10, 10 }, s1, true)
        c_drawBox({ 3, 3, 8, 3 }, s1)
        c_drawBox({ 3, 6, 8, 3 }, s1)

        buffer : [32]u8
        n, err := os.read_at_least(os.stdin, buffer[:], 1)

        fmt.println(n)
    }

    fmt.println("Hello, World!")
}
