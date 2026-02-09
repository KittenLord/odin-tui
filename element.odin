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


NavDirection :: enum {
    N, E, S, W,
}

Pos_from_NavDirection :: proc (n : NavDirection) -> Pos {
    switch n {
    case .N: return { 0, -1 }
    case .E: return { 1, 0 }
    case .S: return { 0, 1 }
    case .W: return { -1, 0 }
    }

    panic("bad")
}

Element :: struct {
    kind : string,

    children : []^Element,
    parent : ^Element,
    stretch : [2]bool,

    focused : bool,
    lastRenderedRect : Rect,

    render     : proc (self : ^Element, ctx : ^RenderingContext, rect : Rect),
    negotiate  : proc (self : ^Element, constraints : Constraints) -> (size : Pos),

    input      : proc (self : ^Element, input : rune),
    inputFocus : proc (self : ^Element, input : rune),

    focus      : proc (self : ^Element),
    navigate   : proc (self : ^Element, dir : NavDirection),
}

render_default :: proc (self : ^Element, ctx : ^RenderingContext, rect : Rect) {
    return
}

negotiate_default :: proc (self : ^Element, constraints : Constraints) -> (size : Pos) {
    return constraints.preferredSize
}

input_default :: proc (self : ^Element, input : rune) {
    return
}

inputFocus_default :: proc (self : ^Element, input : rune) {
    switch input {
    case 'h':
        self->navigate(.W)
    case 'j':
        self->navigate(.S)
    case 'k':
        self->navigate(.N)
    case 'l':
        self->navigate(.E)
    case:
        break
    }
}

focus_default :: proc (self : ^Element) {
    return
}

navigate_default :: proc (self : ^Element, dir : NavDirection) {
    if element_isRoot(self) { return }
    self.parent->navigate(dir)
    return
}






element_render :: proc (e : ^Element, ctx : ^RenderingContext, rect : Rect) {
    oldStyle := c_styleGet(ctx.commandBuffer)

    e->render(ctx, rect)
    e.lastRenderedRect = rect

    if c_styleGet(ctx.commandBuffer) != oldStyle {
        c_style(ctx.commandBuffer, oldStyle)
    }
}

element_negotiate :: proc (e : ^Element, constraints : Constraints) -> (size : Pos) {
    r := e->negotiate(constraints)
    r = { math.min(r.x, constraints.maxSize.x), math.min(r.y, constraints.maxSize.y) }
    return r
}

element_input :: proc (e : ^Element, input : rune) {
    if e.focused { e->inputFocus(input) }
    else         { e->input(input) }

    for c in e.children {
        element_input(c, input)
    }
}

element_focus :: proc (e : ^Element) {
    e.focused = true

    e->focus()
}

element_unfocus :: proc (e : ^Element) {
    e.focused = false
}





element_findFocus :: proc (e : ^Element) -> (focus : ^Element, found : bool = false) {
    if e.focused { return e, true }
    for c in e.children {
        focus, found = element_findFocus(c)
        if found { break }
    }

    return
}


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

Wrapping :: enum {
    Wrapping,       // word gets cut at the end of the line, gets continued immediately on the next one
    NoWrapping,     // if word doesn't fit on the current line move it to the second. If it doesn't fit there either fall back to Wrapping
    // Hyphenation,    // Wrapping, but with hyphens
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





element_isRoot :: proc (e : ^Element) -> bool {
    return e.parent == nil || e.parent == e
}

element_root :: proc (e : ^Element) -> (root : ^Element) {
    if element_isRoot(e) { return e }
    return element_root(e.parent)
}

element_assignParentRecurse :: proc (root : ^Element) {
    for e in root.children {
        e.parent = root
        element_assignParentRecurse(e)
    }
}

element_getParentIndex :: proc (target : ^Element) -> int {
    if element_isRoot(target) { return 0 }

    // NOTE: should never return -1 if set up correctly
    i, s := slice.linear_search(target.parent.children, target)
    if !s {
        panic("element_assignParentRecurse")
    }
    return i
}

element_getParentIndexSameKind :: proc (target : ^Element) -> int {
    if element_isRoot(target) { return 0 }

    i := 0
    for e in target.parent.children {
        if e == target { return i }
        if e.kind == target.kind { i += 1 }
    }

    panic("element_assignParentRecurse")
}

element_getFullKindName :: proc (target : ^Element) -> string {
    b, _ := str.builder_make_none()
    l : [dynamic]^Element

    target := target
    append(&l, target)
    for target.parent != nil && target.parent != target {
        target = target.parent
        append(&l, target)
    }

    slice.reverse(l[:])

    for e, i in l {
        if i != 0 {
            fmt.sbprint(&b, " / ")
        }

        fmt.sbprintf(&b, "%v #%v", e.kind, element_getParentIndexSameKind(e))
    }

    return str.to_string(b)
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

Element_Linear :: struct {
    using base : Element,
}


Element_default :: Element{
    kind = "Element",

    render = render_default,
    negotiate = negotiate_default,
    input = input_default,
    inputFocus = inputFocus_default,
    focus = focus_default,
    navigate = navigate_default,
}

Element_Label_default :: Element_Label{
    kind = "Label",

    render = proc (self : ^Element, ctx : ^RenderingContext, rect : Rect) {
        self := cast(^Element_Label)self

        if self.focused {
            c_style(ctx.commandBuffer, FontStyle{ fg = FontColor_Standard.Black, bg = FontColor_Standard.White })
            cc_fill(ctx.commandBuffer, rect)
        }

        name := element_getFullKindName(self)
        defer delete(name)

        drawText(ctx, self.text, rect, { .Left, .Top }, .NoWrapping)
    },

    negotiate = proc (self : ^Element, constraints : Constraints) -> (size : Pos) {
        self := cast(^Element_Label)self

        name := element_getFullKindName(self)
        defer delete(name)

        referenceRect := constraints.preferredSize
        rect, truncated := drawText(nil, self.text, { 0, 0, referenceRect.x, referenceRect.y }, { .Left, .Top }, .NoWrapping, rendering = false)
        increment := Pos{ 0, 0 }

        for truncated && (rect.zw + increment) != constraints.maxSize {
            // TODO: increase increment
            increment = buyIncrement(rect.zw, increment, constraints.maxSize, constraints.widthByHeightPriceRatio)

            _, truncated = drawText(nil, self.text, { 0, 0, rect.z + increment.x, rect.w + increment.y }, { .Left, .Top }, .NoWrapping, rendering = false)
        }
        
        return rect.zw + increment
    },

    input = input_default,
    inputFocus = inputFocus_default,
    focus = focus_default,
    navigate = navigate_default,
}


Element_Table_default :: Element_Table{
    kind = "Table",

    render = proc (self : ^Element, ctx : ^RenderingContext, rect : Rect) {
        Element_Table_internalRender(self, rect, ctx, true)
    },

    negotiate = proc (self : ^Element, constraints : Constraints) -> (size : Pos) {
        return Element_Table_internalRender(self, Rect{ 0, 0, constraints.maxSize.x, constraints.maxSize.y }, nil, false)
    },

    input = input_default,
    inputFocus = inputFocus_default,
    focus = proc (self : ^Element) {
        self := cast(^Element_Table)self

        n, _ := buffer_get(self.configuration, { 0, 0 })
        e := self.children[n]

        element_unfocus(self)
        element_focus(e)
    },
    navigate = proc (self : ^Element, dir : NavDirection) {
        self := cast(^Element_Table)self

        focus, found := element_findFocus(self)
        if !found || focus == self { return }

        for focus.parent != self {
            focus = focus.parent
        }

        for x in 0..<self.configuration.rect.z {
            for y in 0..<self.configuration.rect.w {
                n := buffer_get(self.configuration, { x, y }) or_continue
                e := self.children[n]
                if e != focus { continue }

                if e == focus {
                    pos := Pos{ x, y } + Pos_from_NavDirection(dir)
                    n := buffer_get(self.configuration, pos) or_continue
                    e := self.children[n]

                    element_unfocus(focus)
                    element_focus(e)
                }
            }
        }
    },
}

Element_Table_internalRender :: proc (self : ^Element, rect : Rect, ctx : ^RenderingContext, render : bool) -> (size : Pos) {
    self := cast(^Element_Table)self

    maxCols := make([]i16, self.configuration.rect.z)
    maxRows := make([]i16, self.configuration.rect.w)
    limCols := make([]i16, self.configuration.rect.z)
    limRows := make([]i16, self.configuration.rect.w)
    defer delete(maxCols)
    defer delete(maxRows)
    defer delete(limCols)
    defer delete(limRows)

    capCols := make([]u64, self.configuration.rect.z)
    capRows := make([]u64, self.configuration.rect.w)
    defer delete(capCols)
    defer delete(capRows)


    deltaCols := make([]i64, self.configuration.rect.z)
    deltaRows := make([]i64, self.configuration.rect.w)
    defer delete(deltaCols)
    defer delete(deltaRows)



    priorityCols := make([]u64, self.configuration.rect.z)
    priorityRows := make([]u64, self.configuration.rect.w)
    defer delete(priorityCols)
    defer delete(priorityRows)

    for s, i in self.stretchingCols {
        priorityCols[i] = calculatePriority(s)
    }

    for s, i in self.stretchingRows {
        priorityRows[i] = calculatePriority(s)
    }



    calculatePriority :: proc (s : Stretching, subtract : bool = false) -> u64 {
        m : u64 = math.max(cast(u64)s.priority, 1)
        switch s.fill {
        case .MinimalPossible:
            m = 1
        case .MinimalNecessary:
            m *= 10
        case .Expand:
            m *= 50
        }

        return m
    }


    for &l in limCols { l = rect.z }
    for &l in limRows { l = rect.w }


    lastIteration :: 1
    for iteration in 0 ..= lastIteration {

        for &m, i in maxCols { m = 0 }
        for &m, i in maxRows { m = 0 }



        // TODO: loop in order of multiplicative preference
        for x in 0..<self.configuration.rect.z {
            for y in 0..<self.configuration.rect.w {
                n := buffer_get(self.configuration, { x, y }) or_continue
                e := self.children[n]

                maxSize := Pos{ limCols[x], limRows[y] }

                preferredSize := Pos{ math.min(maxSize.x, rect.z / self.configuration.rect.z), math.min(maxSize.y, rect.w / self.configuration.rect.w) }
                if self.stretchingCols[x].fill == .MinimalPossible { preferredSize.x = 1 }
                if self.stretchingRows[y].fill == .MinimalPossible { preferredSize.y = 1 }

                // TODO: still not sure about this
                wbhRatio := (f64(rect.z)) / (f64(rect.w))

                size := element_negotiate(e, Constraints{ maxSize = maxSize, preferredSize = preferredSize, widthByHeightPriceRatio = wbhRatio })
                maxCols[x] = math.max(maxCols[x], size.x)
                maxRows[y] = math.max(maxRows[y], size.y)
            }
        }

        totalCols := math.sum(maxCols)
        totalRows := math.sum(maxRows)

        // NOTE: unless this is the last iteration, elements should get as much space as possible
        dc := rect.z - totalCols
        if iteration == lastIteration && dc > 0 && !self.stretch.x { dc = 0 }

        dr := rect.w - totalRows
        if iteration == lastIteration && dr > 0 && !self.stretch.y { dr = 0 }

        lc := dc < 0 ? capCols : nil
        lr := dr < 0 ? capRows : nil

        for &c, i in capCols { c = cast(u64)math.abs(maxCols[i]) }
        for &c, i in capRows { c = cast(u64)math.abs(maxRows[i]) }

        divideBetween(cast(u64)math.abs(dc), priorityCols, transmute([]u64)deltaCols, maxValues = lc)
        divideBetween(cast(u64)math.abs(dr), priorityRows, transmute([]u64)deltaRows, maxValues = lr)

        for d, i in deltaCols {
            limCols[i] = maxCols[i] + (sign_i16(dc) * cast(i16)d)
        }

        for d, i in deltaRows {
            limRows[i] = maxRows[i] + (sign_i16(dr) * cast(i16)d)
        }
    }

    totalCols := math.sum(limCols)
    totalRows := math.sum(limRows)

    size = { totalCols, totalRows }

    if !render { return }




    offset := rect.xy
    for x in 0..<self.configuration.rect.z {
        for y in 0..<self.configuration.rect.w {
            n := buffer_get(self.configuration, { x, y }) or_continue
            e := self.children[n]

            msize := Pos{ limCols[x], limRows[y] }
            element_render(e, ctx, { offset.x, offset.y, msize.x, msize.y })

            offset.y += msize.y
        }

        offset.y = rect.y
        offset.x += (limCols[x])
    }

    return
}
