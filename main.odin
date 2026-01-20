package tui

import "core:fmt"
import px "core:sys/posix"
import lx "core:sys/linux"
import os "core:os/os2"

Pos     :: [2]u16 // col, row
Rect    :: [4]u16 // col, row, width, height


winsize :: struct {
    ws_row      : u16,
    ws_col      : u16,
    ws_xpixel   : u16,
    ws_ypixel   : u16,
}

getSize :: proc () -> (size : Pos, ok : bool) {
    w : winsize
    ok = lx.ioctl(px.STDIN_FILENO, lx.TIOCGWINSZ, cast(uintptr)&w) == 0
    size = { w.ws_col, w.ws_row }
    return
}


// TODO: we will replace os.write_string to writing into a
// temporary buffer

c_clear :: proc() {
    os.write_string(os.stdout, "\e[2J")
}

c_goto :: proc(p : Pos) {
    buffer : [32]u8
    s := fmt.bprintf(buffer[:], "\e[%v;%vH", p.y, p.x)
    os.write_string(os.stdout, s)
}

// https://en.wikipedia.org/wiki/Box-drawing_characters
c_drawBox :: proc(r : Rect) {
    if r.z <= 1 || r.w <= 1 do return

    c_goto({ r.x, r.y })
    os.write_string(os.stdout, "╭")

    c_goto({ r.x, r.y + r.w - 1 })
    os.write_string(os.stdout, "╰")

    c_goto({ r.x + r.z - 1, r.y })
    os.write_string(os.stdout, "╮")

    c_goto({ r.x + r.z - 1, r.y + r.w - 1 })
    os.write_string(os.stdout, "╯")

    c_goto({ r.x + 1, r.y })
    for x in (r.x + 1)..=(r.x + r.z - 2) {
        os.write_string(os.stdout, "─")
    }

    c_goto({ r.x + 1, r.y + r.w - 1 })
    for x in (r.x + 1)..=(r.x + r.z - 2) {
        os.write_string(os.stdout, "─")
    }

    for y in (r.y + 1)..=(r.y + r.w - 2) {
        c_goto({ r.x, y })
        os.write_string(os.stdout, "│")

        c_goto({ r.x + r.z - 1, y })
        os.write_string(os.stdout, "│")
    }
}



main :: proc () {
    term : px.termios
    _ = px.tcgetattr(px.STDIN_FILENO, &term)
    termRestore := term
    defer px.tcsetattr(px.STDIN_FILENO, .TCSANOW, &termRestore)

    term.c_lflag -= { .ECHO, .ICANON }

    px.tcsetattr(px.STDIN_FILENO, .TCSANOW, &term)

    os.write_string(os.stdout, "\e[?25l")

    for {
        c_clear()
        c_drawBox({ 2, 2, 5, 5 })

        buffer : [32]u8
        n, err := os.read_at_least(os.stdin, buffer[:], 1)

        fmt.println(n)
    }

    fmt.println("Hello, World!")
}
