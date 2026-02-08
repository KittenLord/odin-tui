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

// TODO: we will need to be able to execute commands not only on stdout, but also on arbitrary 2d buffer (e.g. scrolling)

CommandBuffer :: struct {
    builder : str.Builder,
}

c_appendRune :: proc (cb : ^CommandBuffer, r : rune) {
    str.write_rune(&cb.builder, r)
}

c_appendString :: proc (cb : ^CommandBuffer, s : string) {
    str.write_string(&cb.builder, s)
}

c_clear :: proc (cb : ^CommandBuffer) {
    c_appendString(cb, "\e[2J")
}

c_goto :: proc (cb : ^CommandBuffer, p : Pos) {
    buffer : [32]u8
    s := fmt.bprintf(buffer[:], "\e[%v;%vH", p.y + 1, p.x + 1)
    c_appendString(cb, s)
}

c_bufferPresent :: proc (cb : ^CommandBuffer, buffer : Buffer(rune)) {
    consecutive := true
    c_goto(cb, buffer.rect.xy)

    for y in 0..<buffer.rect.w {
        for x in 0..<buffer.rect.z {
            r := buffer_get(buffer, { x, y }) or_continue
            if r == '\x00' {
                consecutive = false
                continue
            }

            if !consecutive {
                c_goto(cb, { x, y })
                consecutive = true
            }

            c_appendRune(cb, r)
        }

        // NOTE: unless buffer is the width of the screen
        consecutive = false
    }
}

c_fill :: proc (cb : ^CommandBuffer, rect : Rect, char : rune = ' ') {
    for y in rect.y ..= (rect.y + rect.w - 1) {
        c_goto(cb, { rect.x, y })
        for x in rect.x ..= (rect.x + rect.z - 1) {
            c_appendRune(cb, char)
        }
    }
}



Writer :: struct {
    rect : Rect,
    pos  : Pos,

    render : bool,
    commandBuffer : ^CommandBuffer,
}

writer_start :: proc (r : ^Writer) {
    if r.render { c_goto(r.commandBuffer, r.pos) }
}

writer_done :: proc (r : Writer) -> bool {
    return writer_remaining(r).y <= 0
}

writer_newline :: proc (r : ^Writer, offset : i16 = 0) -> (ok : bool = false) {
    if writer_done(r^) { return }
    if offset >= r.rect.z { return }

    r.pos.y += 1
    r.pos.x = r.rect.x + offset

    if r.render { c_goto(r.commandBuffer, r.pos) }

    ok = true
    return
}

writer_remaining :: proc (r : Writer) -> Pos {
    return r.rect.xy + r.rect.zw - r.pos
}

// NOTE: Does NOT add a newline on the end

// 0, text, false
// n, rem, true
writer_writeOnCurrentLine :: proc (r : ^Writer, text : string) -> (written : i16 = 0, remaining : string, ok : bool = false) {
    remaining = text
    if writer_done(r^) { return }

    rm := writer_remaining(r^)
    l := math.min(cast(int)rm.x, len(text))

    taken, _ := str.substring_to(text, l)
    written = cast(i16)len(taken)
    remaining, _ = substring_from(text, l)

    if r.render {
        c_appendString(r.commandBuffer, taken)
    }

    r.pos.x += cast(i16)l

    ok = true
    return
}

writer_write :: proc (r : ^Writer, text : string) -> (written : i16 = 0, remaining : string) {
    remaining = text

    for !writer_done(r^) && len(remaining) > 0 {
        w : i16
        w, remaining, _ = writer_writeOnCurrentLine(r, remaining)
        written += w
        writer_newline(r, 0)
    }

    return
}

writer_writeRuneOnCurrentLine :: proc (r : ^Writer, c : rune) -> (ok : bool = false) {
    if writer_done(r^) { return }
    if writer_remaining(r^).x <= 0 { return }

    if r.render {
        c_appendRune(r.commandBuffer, c)
    }

    r.pos.x += 1
    ok = true
    return
}
