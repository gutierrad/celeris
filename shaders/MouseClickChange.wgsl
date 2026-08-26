struct Globals {
    width: i32,
    height: i32,
    dx: f32,
    dy: f32,
    xClick: f32,
    yClick: f32,
    changeRadius: f32,
    changeAmplitude: f32,
    surfaceToChange: i32,
    changeType: i32,
    base_depth: f32,
    whichPanelisOpen: i32,
    designcomponentToAdd: i32,
    designcomponent_Radius: f32,
    designcomponent_Friction: f32,
    changeSeaLevel_delta: f32,
    // CODEX: Linear-structure bathy/topo edit parameters.
    designcomponent_CrestElev: f32,
    designcomponent_CrestWidth: f32,
    designcomponent_SideSlope: f32,
    designcomponent_StartX: f32,
    designcomponent_StartY: f32,
    designcomponent_EndX: f32,
    designcomponent_EndY: f32,
    designcomponent_AddLinearStructure: i32,
    // CODEX: Mangrove bathy/topo set-elevation (mangroves branch, Phase 2). Used starting Phase 3.
    designcomponent_SetBathy: i32,
    designcomponent_TargetElev: f32,
    designcomponent_EdgeTaper: f32,
};

@group(0) @binding(0) var<uniform> globals: Globals;

@group(0) @binding(1) var txBottom: texture_2d<f32>; 
@group(0) @binding(2) var txBottomFriction: texture_2d<f32>; 
@group(0) @binding(3) var txContSource: texture_2d<f32>; 
@group(0) @binding(4) var txState: texture_2d<f32>; 
@group(0) @binding(5) var txDesignComponents: texture_2d<f32>; 
@group(0) @binding(6) var txtemp_MouseClick: texture_storage_2d<rgba32float, write>;
@group(0) @binding(7) var txtemp_MouseClick2: texture_storage_2d<rgba32float, write>;


fn calc_radial_distance(xloc: f32, yloc: f32, xo: f32, yo: f32) -> f32 {
    let xdiff = xo - xloc;
    let ydiff = yo - yloc;
    let r = sqrt(xdiff*xdiff + ydiff*ydiff);

    return r;
}

fn calc_radial_function(xloc: f32, yloc: f32, xo: f32, yo: f32, k: f32) -> f32 {
    let xdiff = xo - xloc;
    let ydiff = yo - yloc;
    let r = sqrt(xdiff*xdiff + ydiff*ydiff);

    let f = exp( - k * k * r * r);

    return f;
}

fn calc_dH(f: f32, H: f32, B_val: f32) -> f32 {
    var dH = 0.0;
    if (globals.changeType ==1){
        dH = f * H;
    } else if (globals.changeType ==2){
        dH = (H - B_val)*f;
    }

    return dH;
}

// CODEX: Distance from a sample point to the finite linear-structure centerline, giving rounded end caps.
fn calc_segment_distance(xloc: f32, yloc: f32, xstart: f32, ystart: f32, xend: f32, yend: f32) -> f32 {
    let vx = xend - xstart;
    let vy = yend - ystart;
    let wx = xloc - xstart;
    let wy = yloc - ystart;
    let segment_len2 = vx * vx + vy * vy;
    var t = 0.0;
    if (segment_len2 > 1.0e-6) {
        t = clamp((wx * vx + wy * vy) / segment_len2, 0.0, 1.0);
    }
    let closest_x = xstart + t * vx;
    let closest_y = ystart + t * vy;
    return calc_radial_distance(xloc, yloc, closest_x, closest_y);
}

// CODEX: Trapezoidal/capsule linear-structure target elevation, continuous through rounded endpoints.
fn calc_linear_structure_elevation(xloc: f32, yloc: f32) -> f32 {
    if (globals.designcomponent_CrestWidth <= 0.0 || globals.designcomponent_SideSlope <= 0.0) {
        return -1.0e9;
    }
    let r = calc_segment_distance(
        xloc,
        yloc,
        globals.designcomponent_StartX,
        globals.designcomponent_StartY,
        globals.designcomponent_EndX,
        globals.designcomponent_EndY
    );
    let crest_half_width = 0.5 * globals.designcomponent_CrestWidth;
    let side_distance = max(0.0, r - crest_half_width);
    return globals.designcomponent_CrestElev - globals.designcomponent_SideSlope * side_distance;
}

// CODEX: Mangrove bathy/topo set-elevation footprint (mangroves branch, Phase 6; reworked 2026-08-25).
//
// The taper is defined against the *union* of everything painted with this component, not against the
// individual disc of the current stroke. Painting is continuous and discs overlap heavily, so a
// per-disc ring repeatedly cut its own perimeter back down through ground earlier strokes had already
// flattened - visible as grooves and slopes right through the middle of a merged patch. Any per-disc
// rule has that failure mode: a cell can land in the taper ring of every stroke that ever touched it
// and so never reach the target at all.
//
// Working from the component-ID map instead removes the whole class of problem. txDesignComponents.x
// is written by dispatch 1 and copied back before this dispatch runs, so it already includes the
// current stroke. A cell tapers only by its distance to the nearest cell *outside* the footprint, so
// the slope follows the outline of the union and the interior is always exactly the target. The result
// depends only on (ID map, stash, target) - never on the live bed or on stroke order - which makes it
// idempotent, order-independent, and self-healing: each stroke recomputes the entire footprint from
// the stashed pre-edit bed, so a cell that was on the edge earlier is flattened once it becomes interior.
fn footprint_edge_distance(idx: vec2<i32>, ox: f32, oy: f32) -> f32 {
    let taper = globals.designcomponent_EdgeTaper;
    // Window just big enough to cover the taper; capped so a large taper on a fine grid cannot blow up
    // the per-cell cost. Anything further out returns > taper and counts as fully interior anyway.
    let kx = clamp(i32(ceil(taper / max(globals.dx, 1.0e-6))), 1, 12);
    let ky = clamp(i32(ceil(taper / max(globals.dy, 1.0e-6))), 1, 12);
    var best = 1.0e6;
    for (var jj = -ky; jj <= ky; jj = jj + 1) {
        for (var ii = -kx; ii <= kx; ii = ii + 1) {
            let sx = clamp(idx.x + ii, 0, globals.width - 1);
            let sy = clamp(idx.y + jj, 0, globals.height - 1);
            let id_s = i32(0.01 + textureLoad(txDesignComponents, vec2<i32>(sx, sy), 0).x);
            if (id_s != globals.designcomponentToAdd) {
                let ddx = f32(ii) * globals.dx - ox;
                let ddy = f32(jj) * globals.dy - oy;
                best = min(best, sqrt(ddx * ddx + ddy * ddy));
            }
        }
    }
    return best;
}

// (ox, oy) offsets the evaluation point inside the cell, so the north and east face elevations taper
// consistently with the cell centre. Cells outside the footprint are returned unchanged.
fn calc_component_bathy_elevation(idx: vec2<i32>, ox: f32, oy: f32, current_bed: f32, stashed_bed: f32) -> f32 {
    let id_here = i32(0.01 + textureLoad(txDesignComponents, idx, 0).x);
    if (id_here != globals.designcomponentToAdd) {
        return current_bed;
    }
    let target_elev = globals.designcomponent_TargetElev;
    let taper = globals.designcomponent_EdgeTaper;
    if (taper <= 0.0) {
        return target_elev;
    }
    let d = footprint_edge_distance(idx, ox, oy);
    let w = clamp(1.0 - d / taper, 0.0, 1.0);
    return mix(target_elev, stashed_bed, w);
}


@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let idx = vec2<i32>(i32(id.x), i32(id.y));

    var B_here =  vec4<f32>(0.0, 0.0, 0.0, 0.0);
    var B_here2 =  vec4<f32>(0.0, 0.0, 0.0, 0.0);
    var min_val = 0.0;
    if (globals.whichPanelisOpen == 3){  // surface editor
        if (globals.surfaceToChange == 1) {      // bathy topo
            B_here = textureLoad(txBottom, idx, 0);
            min_val = -globals.base_depth;
            B_here2 = textureLoad(txState, idx, 0);
        } else if (globals.surfaceToChange == 2) {   // friction 
            B_here = textureLoad(txBottomFriction, idx, 0);
            min_val = 0.0;
        } else if (globals.surfaceToChange == 3) {   // passive tracer 
            B_here = textureLoad(txContSource, idx, 0);
            min_val = 0.0;
        } else if (globals.surfaceToChange == 4) {   // free surface elevation
            B_here = textureLoad(txState, idx, 0);
            min_val = textureLoad(txBottom, idx, 0).z;
        }
    } else if (globals.whichPanelisOpen == 2){  // design components editors
        // B_here = textureLoad(txDesignComponents, idx, 0);
        // B_here2 = textureLoad(txBottomFriction, idx, 0);
        // min_val = 0.0;
        // CODEX: Linear structures share this panel but edit bathy/topo instead of design-component IDs.
        if (globals.designcomponent_AddLinearStructure == 1) {
            B_here = textureLoad(txBottom, idx, 0);
            B_here2 = textureLoad(txState, idx, 0);
            min_val = -globals.base_depth;
        } else if (globals.designcomponent_SetBathy == 1) {
            // CODEX: Mangrove bathy/topo set-elevation (mangroves branch, Phase 3).
            B_here = textureLoad(txBottom, idx, 0);
            B_here2 = textureLoad(txState, idx, 0);
            min_val = -globals.base_depth;
        } else {
            B_here = textureLoad(txDesignComponents, idx, 0);
            B_here2 = textureLoad(txBottomFriction, idx, 0);
            min_val = 0.0;
        }
    }
    let k = 4.0 / globals.changeRadius;  // will give a guassian that has a visual width of changeRadius
    let H = globals.changeAmplitude;

    var xloc = f32(id.x)*globals.dx;
    var yloc = f32(id.y)*globals.dy;

    let xo = globals.xClick*globals.dx;
    let yo = globals.yClick*globals.dy;
    
    if (globals.whichPanelisOpen == 3){
        if (abs(globals.changeSeaLevel_delta) > 1.0e-5){  // change in sea level
            
            let H_here = B_here2.x - B_here.z;  // eta - B

            // center
            var dH = -globals.changeSeaLevel_delta;
            B_here.z = max(min_val,B_here.z + dH);
            
            // North
            dH = -globals.changeSeaLevel_delta;
            B_here.x = max(min_val,B_here.x + dH);

            // East
            dH = -globals.changeSeaLevel_delta;
            B_here.y = max(min_val,B_here.y + dH);

            if(H_here <= 0.0){B_here2.x = max(0.0,B_here.z);} // maintain zero total water depth, unless new topo elev is negative, then fill
        }
        else if (globals.surfaceToChange == 1) {      // bathy topo
            // center
            var f = calc_radial_function(xloc,yloc,xo,yo,k);
            var dH = calc_dH(f,H,B_here.z);
            B_here.z = max(min_val,B_here.z + dH);
            
            // North
            f = calc_radial_function(xloc,yloc+0.5*globals.dy,xo,yo,k);
            dH = calc_dH(f,H,B_here.x);
            B_here.x = max(min_val,B_here.x + dH);

            // East
            f = calc_radial_function(xloc+0.5*globals.dx,yloc,xo,yo,k);
            dH = calc_dH(f,H,B_here.y);
            B_here.y = max(min_val,B_here.y + dH);

        } else if (globals.surfaceToChange == 2) {   // friction 
            var f = calc_radial_function(xloc,yloc,xo,yo,k);
            var dH = calc_dH(f,H,B_here.x);
            B_here.x = max(min_val,B_here.x + dH);
        } else if (globals.surfaceToChange == 3) {   // passive tracer, right now same as friction, but keep seperate to accomodate future multiple tracers 
            var f = calc_radial_function(xloc,yloc,xo,yo,k);
            var dH = calc_dH(f,H,B_here.x);
            B_here.x = max(min_val,B_here.x + dH);
        } else if (globals.surfaceToChange == 4) {   // water surface elevation, right now same as friction, but keep seperate to accomodate future multiple tracers 
            var f = calc_radial_function(xloc,yloc,xo,yo,k);
            var dH = calc_dH(f,H,B_here.x);
            B_here.x = max(min_val,B_here.x + dH);
        }
    } else if (globals.whichPanelisOpen == 2){
        // var r = calc_radial_distance(xloc,yloc,xo,yo);
        // var dH = 0.0;
        // var f = 0.0;
        // if(r <= 0.5 * globals.designcomponent_Radius) {
        //     f = 1.0;
        // }
        // dH = (f32(globals.designcomponentToAdd) - B_here.x)*f;
        // B_here.x = max(min_val,B_here.x + dH);
        //
        // // change friction to match
        // let k_friction = 4.0 / globals.designcomponent_Radius;
        // f = calc_radial_function(xloc,yloc,xo,yo,k_friction);
        //
        // dH = (globals.designcomponent_Friction - B_here2.x)*f;
        // B_here2.x = max(min_val,B_here2.x + dH);
        // CODEX: Add a linear structure to bathy/topo using a rounded capsule footprint and trapezoidal cross-section.
        if (globals.designcomponent_AddLinearStructure == 1) {
            var target_elev = calc_linear_structure_elevation(xloc, yloc);
            B_here.z = max(B_here.z, max(min_val, target_elev));

            target_elev = calc_linear_structure_elevation(xloc, yloc + 0.5 * globals.dy);
            B_here.x = max(B_here.x, max(min_val, target_elev));

            target_elev = calc_linear_structure_elevation(xloc + 0.5 * globals.dx, yloc);
            B_here.y = max(B_here.y, max(min_val, target_elev));
        } else if (globals.designcomponent_SetBathy == 1) {
            // CODEX: Mangrove bathy/topo set-elevation (mangroves branch, Phase 3/6) - set exactly inside the footprint, tapered near the edge, existing bed outside.
            let stash = textureLoad(txDesignComponents, idx, 0);
            B_here.z = max(min_val, calc_component_bathy_elevation(idx, 0.0, 0.0, B_here.z, stash.y));
            B_here.x = max(min_val, calc_component_bathy_elevation(idx, 0.0, 0.5 * globals.dy, B_here.x, stash.z));
            B_here.y = max(min_val, calc_component_bathy_elevation(idx, 0.5 * globals.dx, 0.0, B_here.y, stash.w));

            // Free-surface fix: keep eta at or above the (possibly raised) bed; zero momentum in cells that just went dry.
            let newly_dry = B_here.z > B_here2.x;
            B_here2.x = max(B_here2.x, B_here.z);
            if (newly_dry) {
                B_here2.y = 0.0;
                B_here2.z = 0.0;
            }
        } else {
            var r = calc_radial_distance(xloc,yloc,xo,yo);
            var dH = 0.0;
            var f = 0.0;
            if(r <= 0.5 * globals.designcomponent_Radius) {
                f = 1.0;
            }
            // CODEX: Mangrove bathy/topo set-elevation (mangroves branch, Phase 5) - on first paint of a cell
            // (component ID transitions from 0 to non-zero), stash the pre-edit bed into the otherwise-unused
            // .y/.z/.w channels of txDesignComponents, so a future taper (Phase 6) can blend against a fixed
            // reference instead of the live bed - blending against a live value that keeps getting rewritten
            // is not idempotent under repeated strokes.
            if (f == 1.0 && B_here.x == 0.0) {
                let original_bed = textureLoad(txBottom, idx, 0);
                B_here.y = original_bed.z;
                B_here.z = original_bed.x;
                B_here.w = original_bed.y;
            }
            dH = (f32(globals.designcomponentToAdd) - B_here.x)*f;
            B_here.x = max(min_val,B_here.x + dH);

            // change friction to match
            let k_friction = 4.0 / globals.designcomponent_Radius;
            f = calc_radial_function(xloc,yloc,xo,yo,k_friction);

            dH = (globals.designcomponent_Friction - B_here2.x)*f;
            B_here2.x = max(min_val,B_here2.x + dH);
        }

    }

    textureStore(txtemp_MouseClick, idx, B_here);
    textureStore(txtemp_MouseClick2, idx, B_here2);
}
