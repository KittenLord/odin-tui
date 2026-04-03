package tui

import "core:fmt"
import px "core:sys/posix"
import lx "core:sys/linux"
import "core:os"
import "core:math"
import "core:slice"

import str "core:strings"
import utf8 "core:unicode/utf8"

import "core:log"


// TODO: figure out terminology. Component should be an element structure that constantly gets cloned,
// basically a prefab, while <something> is an element structure that has a single instance and is
// assigned to a layer when needed. At this point I will use "component" for the letter, but this is
// to be changed
Component :: enum u64 {
    MessageBox,

    COUNT,
}



EnvironmentLayer :: struct {
    id : int,
    returnFocusTo : int, // NOTE: which layer added this one (and to whom return focus after own deletion)

    align : [2]RectAlignmentMode,

    root  : ^Element,
    focus : ^Element,

    // TODO: Does focus affect anything apart from receiving inputs?
    focused : bool,
}

Environment :: struct {
    quit : bool,
    availableLayerId : int,

    components : map[u64][dynamic]^Element,

    layers : [dynamic]EnvironmentLayer,
}

// NOTE: component can be anything castable to u64, as to allow extensibility
env_addComponent :: proc (env : ^Environment, component : $ty, element : ^Element) -> int {
    list, ok := &env.components[u64(component)]

    if !ok {
        env.components[u64(component)] = {}
        list = &env.components[u64(component)]
    }

    append(list, element)
    return len(list)
}

env_getComponent :: proc (env : ^Environment, component : $ty, $cty : typeid, index : int = 0) -> ^cty {
    return cast(^cty)env.components[u64(component)][index]
}

env_input :: proc (env : ^Environment, input : rune) {
    // #reverse for layer in env.layers {
    for layer in env.layers {
        if !layer.focused { continue }

        input_internal :: proc (e : ^Element, r : ^Element, input : rune) {
            if e != r { e->input(input) }
            for c in e.children {
                input_internal(c, r, input)
            }
        }

        input_internal(layer.root, layer.focus, input)

        if layer.focus != nil {
            layer.focus->inputFocus(input)
        }
    }
}

env_addLayer :: proc (env : ^Environment, root : ^Element, align : [2]RectAlignmentMode, autofocus : bool, focused : bool = true, returnFocusTo : int = 0) -> (layerId : int) {
    env.availableLayerId += 1 // NOTE: 0 is thus not a valid id
    layer := EnvironmentLayer{
        id = env.availableLayerId,
        returnFocusTo = returnFocusTo,

        align = align,

        root = root,
        focus = nil,

        focused = focused,
    }

    if focused {
        for &layer in env.layers {
            layer.focused = false
        }
    }

    append(&env.layers, layer)



    root.environment = env
    element_assignParentRecurse(root)
    if autofocus {
        element_focus(root)
    }



    return layer.id
}

env_getLayer :: proc (env : ^Environment, id : int) -> (layer : ^EnvironmentLayer, index : int, found : bool = false) {
    for &l, i in env.layers {
        if l.id == id {
            layer = &l
            index = i
            found = true
            return
        }
    }

    return
}

env_removeLayer :: proc (env : ^Environment, layerId : int) {
    toRemove, toRemoveIndex, ok := env_getLayer(env, layerId)
    if !ok { return }

    giveFocusToId := toRemove.returnFocusTo
    focusValue := toRemove.focused

    // TODO: the elements are allocated by the user prior to creating the layer,
    // but we probably still need to come up with some way to free elements, if
    // we ever need to create prefabs or smth like that
    ordered_remove(&env.layers, toRemoveIndex)

    giveFocus, _, okf := env_getLayer(env, giveFocusToId)
    if !okf { return }

    giveFocus.focused = focusValue
    return
}

env_render :: proc (env : ^Environment, ctx : ^RenderingContext, rect : Rect) {
    for layer, i in env.layers {
        element_assignParentRecurse(layer.root)

        elementSize := element_negotiate(layer.root, Constraints{ preferredSize = rect.zw / 2, maxSize = rect.zw, widthByHeightPriceRatio = 1 })
        // TODO: now that I think about it, maybe this should just be handled entirely by the Box element?
        // It will need these features either way
        elementRect := rect_align({ 0, 0, elementSize.x, elementSize.y }, rect, layer.align)

        if i != 0 {
            cc_fill(ctx.commandBuffer, elementRect)
            buffer_reset(ctx.bufferBoxes, BoxCellData{ {}, FontStyle_default, -1 })
        }

        element_render(layer.root, ctx, elementRect)
        cc_resolveBoxBuffer(ctx.commandBuffer, ctx.bufferBoxes)
    }
}
