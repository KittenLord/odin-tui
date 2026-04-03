package tui

import "core:fmt"
import px "core:sys/posix"
import lx "core:sys/linux"

import "core:os"
import "core:io"

import "core:math"
import "core:slice"
import "core:time"

import str "core:strings"
import utf8 "core:unicode/utf8"

import "core:log"

import "core:prof/spall"
import "base:runtime"
import "core:sync"




when ODIN_DEBUG {
    spall_ctx: spall.Context
    @(thread_local) spall_buffer: spall.Buffer

    // Automatic profiling of every procedure:

    @(instrumentation_enter)
    spall_enter :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
    	spall._buffer_begin(&spall_ctx, &spall_buffer, "", "", loc)
    }

    @(instrumentation_exit)
    spall_exit :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
    	spall._buffer_end(&spall_ctx, &spall_buffer)
    }
}








// TODO: Rect -> Pos, rect is kinda bad for buffers in retrospect

// NOTE: data is sequential rows
Buffer :: struct($Item : typeid) {
    rect : Rect,
    data : []Item,
}

buffer_create :: proc (r : Rect, $ty : typeid, allocator := context.allocator) -> (buffer : Buffer(ty), ok : bool = false) {
    size := r.z * r.w
    buffer = Buffer(ty){ rect = r, data = make([]ty, size, allocator) }
    ok = true
    return
}

buffer_free :: proc (buffer : Buffer($ty)) {
    delete(buffer.data)
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

drawBoxCell :: proc (buffer : Buffer(BoxCellData), pos : Pos, box : BoxCellData) {
    v, _ := buffer_get(buffer, pos)
    buffer_set(buffer, pos, BoxCellData{ v.masks | box.masks, box.style, box.layer })
}

drawBox :: proc (buffer : Buffer(BoxCellData), rect : Rect, box : BoxType, style : FontStyle, layer : int) {
    br := br_from_rect(rect)

    for x in (rect.x + 1)..<(br.x - 1) {
        drawBoxCell(buffer, Pos{ x,   rect.y }, BoxCellData{ { {}, { box }, {}, { box } }, style, layer })
        drawBoxCell(buffer, Pos{ x, br.y - 1 }, BoxCellData{ { {}, { box }, {}, { box } }, style, layer })
    }

    for y in (rect.y + 1)..<(br.y - 1) {
        drawBoxCell(buffer, Pos{ rect.x,   y }, BoxCellData{ { { box }, {}, { box }, {} }, style, layer })
        drawBoxCell(buffer, Pos{ br.x - 1, y }, BoxCellData{ { { box }, {}, { box }, {} }, style, layer })
    }

    // tl tr br bl
    drawBoxCell(buffer, Pos{ rect.x,   rect.y   }, BoxCellData{ { {},      { box }, { box }, {}      }, style, layer })
    drawBoxCell(buffer, Pos{ br.x - 1, rect.y   }, BoxCellData{ { {},      {},      { box }, { box } }, style, layer })
    drawBoxCell(buffer, Pos{ br.x - 1, br.y - 1 }, BoxCellData{ { { box }, {},      {},      { box } }, style, layer })
    drawBoxCell(buffer, Pos{ rect.x,   br.y - 1 }, BoxCellData{ { { box }, { box }, {},      {}      }, style, layer })
}

drawLine :: proc (buffer : Buffer(BoxCellData), rect : Rect, box : BoxType, style : FontStyle, layer : int) {
    if rect.z != 1 && rect.w != 1 { return }
    
    mask : [4]BoxTypeMask = rect.z == 1 ? { { box }, {}, { box }, {} } : { {}, { box }, {}, { box } }

    br := br_from_rect(rect)
    for y in (rect.y)..<(br.y) {
        for x in (rect.x)..<(br.x) {
            drawBoxCell(buffer, { x, y }, BoxCellData{ mask, style, layer })
        }
    }

    // NOTE: ehhhh idk this is kinda jank but it works for reasonable cases
    if rect.z == 1 {
        drawBoxCell(buffer, { rect.x, rect.y - 1 }, BoxCellData{ { {}, {}, { box }, {} }, style, layer })
        drawBoxCell(buffer, { rect.x, br.y },       BoxCellData{ { { box }, {}, {}, {} }, style, layer })
    }
    else {
        drawBoxCell(buffer, { rect.x - 1, rect.y }, BoxCellData{ { {}, { box }, {}, {} }, style, layer })
        drawBoxCell(buffer, { br.x,       rect.y }, BoxCellData{ { {}, {}, {}, { box } }, style, layer })
    }
}

cc_resolveBoxBuffer :: proc (cb : ^CommandBuffer, buffer : Buffer(BoxCellData)) {
    for y in 0..<buffer.rect.w {
        consecutive := false

        for x in 0..<buffer.rect.z {
            box := buffer_get(buffer, { x, y }) or_continue
            if box.masks == {} {
                consecutive = false
                continue
            }


            candidate : BoxCharacter
            for c in BoxCharacters {
                if (box.masks[0] & c.masks[0] == {} && box.masks[0] | c.masks[0] != {}) ||
                   (box.masks[1] & c.masks[1] == {} && box.masks[1] | c.masks[1] != {}) ||
                   (box.masks[2] & c.masks[2] == {} && box.masks[2] | c.masks[2] != {}) ||
                   (box.masks[3] & c.masks[3] == {} && box.masks[3] | c.masks[3] != {}) { continue }

                candidate = c
                break
            }


            if !consecutive {
                consecutive = true
                c_goto(cb, { x, y } + buffer.rect.xy)
            }
            c_style(cb, box.style)
            c_appendRune(cb, candidate.character)
        }
    }
}

// TODO: should we just render one line at a time and align it right away, so as to not
// calculate alignments beforehand (and not rendering twice)?
drawTextBetter :: proc (ctx : ^RenderingContext, text : string, rect : Rect, align : Alignment, wrap : Wrapping, rendering : bool = true, ll_list : []i16 = nil) -> (actualRect : Rect, truncated : bool) {
    ll_list := ll_list

    if rect.z == 0 || rect.w == 0 {
        // TODO: text is all whitespace?
        return { 0, 0, 0, 0 }, (len(text) != 0)
    }

    if rendering {
        ll_list = make([]i16, rect.w)
        drawTextBetter(ctx, text, rect, align, wrap, false, ll_list)
    }

    defer if rendering {
        delete(ll_list)
    }

    ll_new :: proc (writer : ^Writer, ll_list : []i16, ll_off : i16, ll_cur : ^i16, ll_spacebar : ^i16, minOffset : ^i16, align : Alignment) -> bool {
        if writer_remaining(writer^).y <= 1 { return false }

        precalculatedLength := ll_list != nil ? ll_list[writer.pos.y + ll_off + 1] : 0
        // TODO: calculate offset based off alignment
        offset := precalculatedLength == 0 ? 0 : (precalculatedLength * 0)
        if offset < minOffset^ { minOffset^ = offset }

        writer_newline(writer, offset)

        if ll_list != nil { ll_list[writer.pos.y + ll_off] = 0 }

        ll_cur^ = 0
        ll_spacebar^ = 0

        return true
    }

    ll_add :: proc (value : i16, writer : Writer, ll_list : []i16, ll_off : i16, ll_cur : ^i16, ll_max : ^i16) {
        if ll_list != nil {
            ll_list[writer.pos.y + ll_off] += value
        }

        ll_cur^ += value
        if ll_cur^ > ll_max^ { ll_max^ = ll_cur^ }
    }

    State :: enum {
        SkippingWhitespace,
        CollectingShortWord,
        DumpingLargeWord,
    }

    state : State = .SkippingWhitespace

    minOffset : i16 = 0

    sw_lo  := 0
    sw_hi  := 0
    sw_len : i16 = 0

    ll_max : i16 = 0
    ll_cur : i16 = 0
    ll_spacebar : i16 = 0
    ll_off := -rect.y

    // TODO: the first line should be aligned and minOffset assigned
    writer := Writer{ rect, rect.xy, rendering, ctx == nil ? nil : ctx.commandBuffer }
    writer_start(&writer)

    num := 0
    l := len(text)
    // NOTE: i is byte offset
    outerLoop: for c, i in text {
        cs := utf8.rune_size(c)
        eof := (num + 1 >= l)

        switchState := true
        mainLoop: for switchState {
            switchState = false

            switch state {
            case .SkippingWhitespace: {
                if !str.is_space(c) {
                    switchState = true
                    state = .CollectingShortWord
                    continue mainLoop
                }

                continue mainLoop
            }
            case .CollectingShortWord: {
                if sw_len == 0 {
                    sw_lo = i
                    sw_hi = i
                    sw_len = 0
                }

                if !str.is_space(c) {
                    sw_hi = i + cs
                    sw_len += 1
                }
                
                if sw_len > rect.z {
                    switchState = true
                    state = .DumpingLargeWord
                    continue mainLoop
                }

                if str.is_space(c) || eof {
                    if (ll_spacebar + sw_len) <= writer_remaining(writer).x {
                        if ll_spacebar == 1 {
                            writer_writeOnCurrentLine(&writer, " ")
                            ll_add(1, writer, ll_list, ll_off, &ll_cur, &ll_max)
                        }

                        writer_writeOnCurrentLine(&writer, text[sw_lo:sw_hi])
                        ll_add(sw_len, writer, ll_list, ll_off, &ll_cur, &ll_max)
                        ll_spacebar = 1
                        sw_len = 0

                        // NOTE: if !str.is_space then we are at eof and we should consume the last character
                        switchState = str.is_space(c)
                        state = .SkippingWhitespace
                        continue mainLoop
                    }

                    switch wrap {
                    case .NoWrapping: {
                        ll_new(&writer, ll_list, ll_off, &ll_cur, &ll_spacebar, &minOffset, align) or_break outerLoop

                        // NOTE: the word is guaranteed to fit into the newly opened line, we can reuse the short word code
                        switchState = true
                        state = .CollectingShortWord
                        continue mainLoop
                    }
                    case .Wrapping: {
                        switchState = true
                        state = .DumpingLargeWord
                        continue mainLoop
                    }
                    }
                }
            }
            case .DumpingLargeWord: {
                if ll_spacebar == 1 {
                    if writer_remaining(writer).x < 1 {
                        ll_new(&writer, ll_list, ll_off, &ll_cur, &ll_spacebar, &minOffset, align) or_break outerLoop
                    }
                    else {
                        writer_writeOnCurrentLine(&writer, " ")
                        ll_add(1, writer, ll_list, ll_off, &ll_cur, &ll_max)
                    }

                    ll_spacebar = 0
                }

                if sw_len > 0 {
                    sw_len = 0
                    remaining : string = text[sw_lo:sw_hi]

                    for len(remaining) > 0 {
                        written : i16
                        written, remaining, _ = writer_writeOnCurrentLine(&writer, remaining)
                        ll_add(written, writer, ll_list, ll_off, &ll_cur, &ll_max)

                        ll_new(&writer, ll_list, ll_off, &ll_cur, &ll_spacebar, &minOffset, align) or_break outerLoop
                    }
                }


                if str.is_space(c) {
                    switchState = true
                    state = .SkippingWhitespace
                    continue mainLoop
                }

                ok := writer_writeRuneOnCurrentLine(&writer, c)
                if ok {
                    ll_add(1, writer, ll_list, ll_off, &ll_cur, &ll_max)
                }
                else {
                    ll_new(&writer, ll_list, ll_off, &ll_cur, &ll_spacebar, &minOffset, align) or_break outerLoop
                    writer_writeRuneOnCurrentLine(&writer, c)
                    ll_add(1, writer, ll_list, ll_off, &ll_cur, &ll_max)
                }
            }
            }
        }

        // NOTE: if we break in the outerLoop this will be less than length (hence no defer)
        num += 1
    }

    if ll_cur != 0 { writer_newline(&writer) }

    truncated = (num < l)
    actualRect = Rect{ rect.x, rect.y, ll_max, writer.pos.y - rect.y }

    return
}





divideBetween :: proc (value : u64, coefficients : []u64, values : []u64, gap : u64 = 0, maxValues : []u64 = nil) {
    gaps := (cast(u64)len(coefficients) - 1) * gap
    if gaps >= value { return }

    value := value - gaps

    one : f64 = 0
    for c in coefficients { one += f64(c) }
    if one == 0 { return }

    total : u64 = 0
    for c, i in coefficients {
        v  := u64(f64(value) * (f64(c) / one))
        mv := maxValues != nil ? maxValues[i] : v
        v = math.min(v, mv)

        values[i] = v
        total += v
    }

    if total >= value { return }

    // TODO: I'm not sure if this is adequate, we need to prioritize larger coefficients and probably do it without a loop
    rest := value - total
    prest := rest + 1
    for rest > 0 && prest != rest {
        prest = rest

        for c, i in coefficients {
            if rest == 0 { break }
            if c == 0 { continue }
            if maxValues != nil && values[i] >= maxValues[i] { continue }

            values[i] += 1
            rest -= 1
        }
    }
}



TerminalState :: struct {
    termios : px.termios,
}

interactiveEnable :: proc () -> (state : TerminalState, ok : bool = false) {
    if px.tcgetattr(px.STDIN_FILENO, &state.termios) != .OK { return }

    term := state.termios
    term.c_lflag -= { .ECHO, .ICANON }

    if px.tcsetattr(px.STDIN_FILENO, .TCSANOW, &term) != .OK { return }

    // Disable cursor
    os.write_string(os.stdout, "\e[?25l")
    // Enable alternative buffer
    os.write_string(os.stdout, "\e[?1049h")

    return
}

interactiveDisable :: proc (state : TerminalState) {
    state := state
    px.tcsetattr(px.STDIN_FILENO, .TCSANOW, &state.termios)

    // Disable alternative buffer
    os.write_string(os.stdout, "\e[?1049l")
    // Enable cursor
    os.write_string(os.stdout, "\e[?25h")
}



RenderingContext :: struct {
    screenRect : Rect,
    commandBuffer : ^CommandBuffer,

    bufferBoxes : Buffer(BoxCellData),
    // TODO: remove, this isnt needed with new box rendering
    sharedBoxLayer : int,
    uniqueBoxLayer : int,
}

run :: proc () -> bool {
    // when ODIN_DEBUG {
        logFile, _ := os.open("./log.txt", { .Write, .Create })
        context.logger = log.create_file_logger(logFile, .Debug, { .Level, .Short_File_Path, .Line })
    // }



    p20scroll := scroll({ false, true }, { false, true }, true,
        linear(.Vertical, {}, { { priority = 1, fill = .MinimalPossible }, {}, {} }, {
            label("[1:1] In the beginning when God created the heavens and the earth,"),
            label("[1:2] the earth was a formless void and darkness covered the face of the deep, while a wind from God swept over the face of the waters."),
            label("[1:3] Then God said, \"Let there be light\"; and there was light."),
            label("[1:4] And God saw that the light was good; and God separated the light from the darkness."),
            label("[1:5] God called the light Day, and the darkness he called Night. And there was evening and there was morning, the first day."),
            label("[1:6] And God said, \"Let there be a dome in the midst of the waters, and let it separate the waters from the waters.\""),
            label("[1:7] So God made the dome and separated the waters that were under the dome from the waters that were above the dome. And it was so."),
            label("[1:8] God called the dome Sky. And there was evening and there was morning, the second day."),
            label("[1:9] And God said, \"Let the waters under the sky be gathered together into one place, and let the dry land appear.\" And it was so."),
            label("[1:10] God called the dry land Earth, and the waters that were gathered together he called Seas. And God saw that it was good."),
            label("[1:11] Then God said, \"Let the earth put forth vegetation: plants yielding seed, and fruit trees of every kind on earth that bear fruit with the seed in it.\" And it was so."),
            label("[1:12] The earth brought forth vegetation: plants yielding seed of every kind, and trees of every kind bearing fruit with the seed in it. And God saw that it was good."),
            label("[1:13] And there was evening and there was morning, the third day."),
            label("[1:14] And God said, \"Let there be lights in the dome of the sky to separate the day from the night; and let them be for signs and for seasons and for days and years,"),
            label("[1:15] and let them be lights in the dome of the sky to give light upon the earth.\" And it was so."),
            label("[1:16] God made the two great lights - the greater light to rule the day and the lesser light to rule the night - and the stars."),
            label("[1:17] God set them in the dome of the sky to give light upon the earth,"),
            label("[1:18] to rule over the day and over the night, and to separate the light from the darkness. And God saw that it was good."),
            label("[1:19] And there was evening and there was morning, the fourth day."),
            label("[1:20] And God said, \"Let the waters bring forth swarms of living creatures, and let birds fly above the earth across the dome of the sky.\""),
            label("[1:21] So God created the great sea monsters and every living creature that moves, of every kind, with which the waters swarm, and every winged bird of every kind. And God saw that it was good."),
            label("[1:22] God blessed them, saying, \"Be fruitful and multiply and fill the waters in the seas, and let birds multiply on the earth.\""),
            label("[1:23] And there was evening and there was morning, the fifth day."),
            label("[1:24] And God said, \"Let the earth bring forth living creatures of every kind: cattle and creeping things and wild animals of the earth of every kind.\" And it was so."),
            label("[1:25] God made the wild animals of the earth of every kind, and the cattle of every kind, and everything that creeps upon the ground of every kind. And God saw that it was good."),
            label("[1:26] Then God said, \"Let us make humankind in our image, according to our likeness; and let them have dominion over the fish of the sea, and over the birds of the air, and over the cattle, and over all the wild animals of the earth, and over every creeping thing that creeps upon the earth.\""),
            label("[1:27] So God created humankind in his image, in the image of God he created them; male and female he created them."),
            label("[1:28] God blessed them, and God said to them, \"Be fruitful and multiply, and fill the earth and subdue it; and have dominion over the fish of the sea and over the birds of the air and over every living thing that moves upon the earth.\""),
            label("[1:29] God said, \"See, I have given you every plant yielding seed that is upon the face of all the earth, and every tree with seed in its fruit; you shall have them for food."),
            label("[1:30] And to every beast of the earth, and to every bird of the air, and to everything that creeps on the earth, everything that has the breath of life, I have given every green plant for food.\" And it was so."),
            label("[1:31] God saw everything that he had made, and indeed, it was very good. And there was evening and there was morning, the sixth day. "),
        })
    )


    
    // NOTE: this is still a useful example

    // c : []u64 = { 2, 3, 5 }
    // r : [3]u64
    // divideBetween(cast(u64)width, c, r[:], 1)
    //
    // rectA, lineAB, rectBC := rect_splitVerticalLineGap(content, cast(i16)r[0], 1)
    // rectB, lineBC, rectC := rect_splitVerticalLineGap(rectBC, cast(i16)r[1], 1)
    //
    // drawBlock(ctx.bufferBoxes, lineAB, .SingleCurve)
    // drawBlock(ctx.bufferBoxes, lineBC, .SingleCurve)
    //
    // element_render(self.children[0], ctx, rectA)
    // element_render(self.children[1], ctx, rectB)
    // element_render(self.children[2], ctx, rectC)


    root :=
        box(.SingleCurve, {}, {},
            linear(.Horizontal, .Double, { { priority = 1, fill = .MinimalPossible }, {
                // TODO: the result is kinda what we expected, but there's not really a way
                // to split a container proportionally, unless all elements take the same
                // amount of space prior to getting stretched
                Stretching{ .Expand, 1 },
                Stretching{ .Expand, 3 },
                Stretching{ .Expand, 5 },
            }, {} }, {

                linear(.Vertical, .Single, { { priority = 1, fill = .MinimalPossible }, {
                    Stretching{ .MinimalPossible, 1 },
                    Stretching{ .Expand, 5 }
                }, {} }, {
                    label("ELF Header"),
                    table({ 2, 2 }, { .Single, {} }, { { { .Expand, 1 }, { Stretching{ .MinimalNecessary, 1 }, Stretching{ .Expand, 1 } }, {} }, { { .MinimalPossible, 1 }, {}, {} } }, {
                        label("Magic:"), label("7f 45 4c 46"),
                        label("Type:"),  label("Shared Object"), 
                    })
                }),
                label("Test"),
                p20scroll,
            })
        )

    element_retrieve(Element, root, { 0, 0, 1, 1 }).interact = proc(self : ^Element) {
        log.debugf("magic")

        env := element_getEnvironment(self)
        mbox := env_getComponent(env, Component.MessageBox, Element)
        env_addLayer(env, mbox, { .Expand1, .Expand1 }, true, returnFocusTo = element_getLayer(self).id)
    }

    // TODO: are there even cases where we do NOT watch stretching (when rendering)?
    element_retrieve(Element_Linear, root, { 0 }).stretch.x = true
    element_retrieve(Element_Linear, root, { 0, 0 }).stretch.y = true
    element_retrieve(Element_Table,  root, { 0, 0, 1 }).stretch.x = true

    textPopup := 
        box(.Double, {}, {},
            linear(.Vertical, .None, { { priority = 1, fill = .MinimalNecessary }, {}, {} }, {
                label("Information idk"),
                linear(.Horizontal, .None, { { priority = 1, fill = .MinimalNecessary }, {}, {} }, {
                    box(.Single, {}, {}, 
                        label("YES")
                    ),
                    box(.Single, {}, {}, 
                        label("NO")
                    ),
                })
            })
        )

    element_retrieve(Element, textPopup, { 0, 1 }).stretch.x = true
    element_retrieve(Element, textPopup, { 0, 1, 0, 0 }).interact = proc(self : ^Element) {
        log.debugf("YES")

        env := element_getEnvironment(self)
        env_removeLayer(env, element_getLayer(self).id)
    }

    element_retrieve(Element, textPopup, { 0, 1, 1, 0 }).interact = proc(self : ^Element) {
        log.debugf("NO")

        env := element_getEnvironment(self)
        env_removeLayer(env, element_getLayer(self).id)
    }


    env : Environment

    env_addComponent(&env, Component.MessageBox, textPopup)

    env_addLayer(&env, root, { .Fill, .Fill }, true)
    // env_addLayer(&env, textPopup, { .Expand1, .Expand1 }, true)











    box : Buffer(BoxCellData)
    cb : CommandBuffer = CommandBuffer_Stdout{
        builder = str.builder_make_none(),
        style = FontStyle_default,
    }



    sw : time.Stopwatch




    tstate, _ := interactiveEnable()
    defer interactiveDisable(tstate)
    inputStream := os.to_stream(os.stdin)

    for !env.quit {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)





        screenRect := getScreenRect() or_return

        if box.data == nil || box.rect != screenRect {
            buffer_free(box)
            box = buffer_create(screenRect, BoxCellData) or_return
        }

        buffer_reset(box, BoxCellData{ {}, FontStyle_default, -1 })
        c_reset(&cb)





        c_styleClear(&cb)
        c_clear(&cb)

        // TODO: im not sure, but it might be more useful to delegate context creation to environment
        ctx := RenderingContext{
            screenRect = screenRect,
            commandBuffer = &cb,

            bufferBoxes = box,
            sharedBoxLayer = 0,
            uniqueBoxLayer = 100000,
        }


        env_render(&env, &ctx, ctx.screenRect)




        os.write_string(os.stdout, str.to_string(cb.(CommandBuffer_Stdout).builder))





        time.stopwatch_stop(&sw)
        log.debugf("DRAW TIME: %v", time.stopwatch_duration(sw))




        // TODO: are there any cases where non-unicode input is needed? raw bytes?
        c, _, err := io.read_rune(inputStream)

        env_input(&env, c)
    }


    return true
}

main :: proc () {
    when ODIN_DEBUG {
        spall_ctx = spall.context_create("trace_test.spall")
        defer spall.context_destroy(&spall_ctx)

        buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
        defer delete(buffer_backing)

        spall_buffer = spall.buffer_create(buffer_backing, u32(sync.current_thread_id()))
        defer spall.buffer_destroy(&spall_ctx, &spall_buffer)

        spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)
    }





    run()
}
