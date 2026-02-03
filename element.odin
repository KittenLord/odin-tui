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



Element :: struct {
    kind : string,

    children : []^Element,
    parent : ^Element,
    stretch : [2]bool,

    render : proc (self : ^Element, ctx : RenderingContext, rect : Rect),
    negotiate : proc (self : ^Element, constraints : Constraints) -> (size : Pos),
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





negotiate_default :: proc (self : ^Element, constraints : Constraints) -> (size : Pos) {
    return constraints.preferredSize
}

element_assignParentRecurse :: proc (root : ^Element) {
    for e in root.children {
        e.parent = root
        element_assignParentRecurse(e)
    }
}

element_getParentIndex :: proc (target : ^Element) -> int {
    if target.parent == nil || target.parent == target { return 0 }

    // NOTE: should never return -1 if set up correctly
    i, s := slice.linear_search(target.parent.children, target)
    if !s {
        panic("element_assignParentRecurse")
    }
    return i
}

element_getParentIndexSameKind :: proc (target : ^Element) -> int {
    if target.parent == nil || target.parent == target { return 0 }

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
            fmt.sbprint(&b, " > ")
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



Element_Label_default :: Element_Label{
    kind = "Label",

    render = proc (self : ^Element, ctx : RenderingContext, rect : Rect) {
        self := cast(^Element_Label)self

        name := element_getFullKindName(self)
        defer delete(name)

        log.debugf("[%v] got rect %v", name, rect)

        drawText(self.text, rect, { .Left, .Top }, .NoWrapping)
    },

    negotiate = proc (self : ^Element, constraints : Constraints) -> (size : Pos) {
        self := cast(^Element_Label)self

        name := element_getFullKindName(self)
        defer delete(name)

        referenceRect := constraints.preferredSize
        rect, truncated := drawText(self.text, { 0, 0, referenceRect.x, referenceRect.y }, { .Left, .Top }, .NoWrapping, rendering = false)
        increment := Pos{ 0, 0 }
        log.debugf("[%v] got constraints %v %v", name, constraints.preferredSize, constraints.maxSize)
        log.debugf("truncated %v", truncated)

        for truncated && (rect.zw + increment) != constraints.maxSize {
            // TODO: increase increment
            increment = buyIncrement(rect.zw, increment, constraints.maxSize, constraints.widthByHeightPriceRatio)
            log.debugf("increment %v", increment)

            _, truncated = drawText(self.text, { 0, 0, rect.z + increment.x, rect.w + increment.y }, { .Left, .Top }, .NoWrapping, rendering = false)
        }

        log.debugf("truncated %v", truncated)
        log.debugf("returned %v", rect.zw + increment)
        
        return rect.zw + increment
    },
}


Element_Table_default :: Element_Table{
    kind = "Table",

    // children = { &p20table_magic, &p20table_type, &p20table_magicValue, &p20table_typeValue },
    // stretch = { true, false },
    // configuration = Buffer(int){ rect = { 0, 0, 2, 2 }, data = { 0, 2, 1, 3 } },

    // stretchingCols = { Stretching{ priority = 0, fill = .MinimalNecessary }, Stretching{ priority = 1, fill = .Expand } },
    // stretchingRows = { Stretching{ priority = 0, fill = .MinimalPossible }, Stretching{ priority = 0, fill = .MinimalPossible } },

    render = proc (self : ^Element, ctx : RenderingContext, rect : Rect) {
        self := cast(^Element_Table)self

        maxCols := make([]i16, self.configuration.rect.z)
        maxRows := make([]i16, self.configuration.rect.w)
        defer delete(maxCols)
        defer delete(maxRows)

        // TODO: loop in order of multiplicative preference
        for x in 0..<self.configuration.rect.z {
            for y in 0..<self.configuration.rect.w {
                n := buffer_get(self.configuration, { x, y }) or_continue
                e := self.children[n]

                preferredSize := Pos{ rect.z / self.configuration.rect.z, rect.w / self.configuration.rect.w }

                if self.stretchingCols[x].fill == .MinimalPossible { preferredSize.x = 1 }
                if self.stretchingRows[y].fill == .MinimalPossible { preferredSize.y = 1 }

                // TODO: still not sure about this
                wbhRatio := (f64(rect.z)) / (f64(rect.w))

                size := e->negotiate(Constraints{ maxSize = rect.zw, preferredSize = preferredSize, widthByHeightPriceRatio = wbhRatio })
                maxCols[x] = maxCols[x] > size.x ? maxCols[x] : size.x
                maxRows[y] = maxRows[y] > size.y ? maxRows[y] : size.y
            }
        }

        totalCols : i16 = 0
        for n in maxCols {
            totalCols += n
        }

        totalRows : i16 = 0
        for n in maxRows {
            totalRows += n
        }


        // TODO: a lot of doubling
        priorityCols := make([]u64, self.configuration.rect.z)
        priorityRows := make([]u64, self.configuration.rect.w)
        deltaCols := make([]i64, self.configuration.rect.z)
        deltaRows := make([]i64, self.configuration.rect.w)
        defer delete(priorityCols)
        defer delete(priorityRows)
        defer delete(deltaCols)
        defer delete(deltaRows)

        for s, i in self.stretchingCols {
            m : u64 = cast(u64)s.priority * 20
            switch s.fill {
            case .MinimalPossible:
                m = 1
            case .MinimalNecessary:
                m *= 1
            case .Expand:
                m *= 5
            }

            priorityCols[i] = m
        }

        for s, i in self.stretchingRows {
            m : u64 = cast(u64)s.priority * 20
            switch s.fill {
            case .MinimalPossible:
                m = 1
            case .MinimalNecessary:
                m *= 1
            case .Expand:
                m *= 5
            }

            priorityRows[i] = m
        }

        dc := rect.z - totalCols
        if dc > 0 && !self.stretch.x { dc = 0 }

        dr := rect.w - totalRows
        if dr > 0 && !self.stretch.y { dr = 0 }

        divideBetween(cast(u64)math.abs(dc), priorityCols, transmute([]u64)deltaCols)
        divideBetween(cast(u64)math.abs(dr), priorityRows, transmute([]u64)deltaRows)

        sc : i16 = rect.z > totalCols ? 1 : -1
        sr : i16 = rect.w > totalRows ? 1 : -1

        // TODO: this can result in a negative width/height, somehow adjust divideBetween???
        for d, i in deltaCols {
            maxCols[i] += sc * cast(i16)d
        }

        for d, i in deltaRows {
            maxRows[i] += sr * cast(i16)d
        }







        offset := rect.xy
        for x in 0..<self.configuration.rect.z {
            for y in 0..<self.configuration.rect.w {
                n := buffer_get(self.configuration, { x, y }) or_continue
                e := self.children[n]

                msize := Pos{ maxCols[x], maxRows[y] }
                // TODO: maybe a few renegotiation rounds? idk
                // size := e->negotiate({ minSize = { 0, 0 }, maxSize = rect.zw, preferredSize = msize, widthByHeightPriceRatio = 1 })
                e->render(ctx, { offset.x, offset.y, msize.x, msize.y })

                offset.y += msize.y
            }

            offset.y = rect.y
            offset.x += (maxCols[x])
        }
    }
}
