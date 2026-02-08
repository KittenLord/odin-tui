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

FontModeOption :: enum {
    Bold,
    Dim,
    Italic,
    Underline,
    Blinking,
    Inverse,
    Hidden,
    Strikethrough,
}

FontMode :: bit_set[FontModeOption]

FontColor_Standard :: enum {
    Black,
    Red,
    Green,
    Yellow,
    Blue,
    Magenta,
    Cyan,
    White,
    Default,
}

FontColor_Bright :: enum {
    Black,
    Red,
    Green,
    Yellow,
    Blue,
    Magenta,
    Cyan,
    White,
}

FontColor_256 :: struct {
    id : u8,
}

FontColor_rgb :: struct {
    r : u8,
    g : u8,
    b : u8,
}

FontColor :: union {
    FontColor_Standard,
    FontColor_Bright,
    FontColor_256,
    FontColor_rgb,
}


FontStyle :: struct {
    bg : FontColor,
    fg : FontColor,

    mode : FontMode,
}





// TODO: i still have very little clue on how we're going to handle wide characters (japanese and chinese), if at all

CommandBuffer :: union {
    CommandBuffer_Stdout,
    CommandBuffer_Buffer,
}


CommandBuffer_Stdout :: struct {
    builder : str.Builder,
}

CellData :: struct {
    r : rune,

    style : FontStyle,
}

// NOTE: there is no latency to copying into user memory as compared to writing to stdout, so we just immediately execute all commands
CommandBuffer_Buffer :: struct {
    buffer : Buffer(CellData),

    pos : Pos,
}



// NOTE: 
// c_   : fundamental command (needs to be implemented for both Stdout and Buffer)
// cc_  : derived command (is defined in terms of other c_ or cc_ commands)

c_reset :: proc (cbb : ^CommandBuffer) {
    switch cb in cbb {
    case CommandBuffer_Stdout:
        // NOTE: oh my fucking goooooooood
        cbc := cb
        str.builder_reset(&cbc.builder)
        cbb^ = cbc
    case CommandBuffer_Buffer:
        buffer_reset(cb.buffer, CellData{ r = '\x00' })
    }
}

c_appendRune :: proc (cbb : ^CommandBuffer, r : rune) {
    switch cb in cbb {
    case CommandBuffer_Stdout:
        cbc := cb
        defer cbb^ = cbc
        
        str.write_rune(&cbc.builder, r)
    case CommandBuffer_Buffer:
        cbc := cb
        defer cbb^ = cbc

        buffer_set(cbc.buffer, cbc.pos, CellData{ r = r })
        cbc.pos.x += 1
        if cbc.pos.x >= cbc.buffer.rect.x + cbc.buffer.rect.z {
            cbc.pos.x = cbc.buffer.rect.x
            cbc.pos.y += 1
        }
    }
}

c_appendString :: proc (cbb : ^CommandBuffer, s : string) {
    switch cb in cbb {
    case CommandBuffer_Stdout:
        cbc := cb
        defer cbb^ = cbc

        str.write_string(&cbc.builder, s)
    case CommandBuffer_Buffer:
        for c in s {
            c_appendRune(cbb, c)
        }
    }
}

c_clear :: proc (cbb : ^CommandBuffer) {
    switch cb in cbb {
    case CommandBuffer_Stdout:
        c_appendString(cbb, "\e[2J")
    case CommandBuffer_Buffer:
        buffer_reset(cb.buffer, CellData{ r = '\x00' })
    }
}

c_goto :: proc (cbb : ^CommandBuffer, p : Pos) {
    switch cb in cbb {
    case CommandBuffer_Stdout:
        buffer : [32]u8
        s := fmt.bprintf(buffer[:], "\e[%v;%vH", p.y + 1, p.x + 1)
        c_appendString(cbb, s)
    case CommandBuffer_Buffer:
        cbc := cb
        defer cbb^ = cbc

        cbc.pos = p
    }
}

cc_bufferPresent :: proc (cb : ^CommandBuffer, buffer : Buffer(rune)) {
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

cc_fill :: proc (cb : ^CommandBuffer, rect : Rect, char : rune = ' ') {
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
