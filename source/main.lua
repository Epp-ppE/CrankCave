-- main.lua
-- Prototype test scene: crank -> charge/light/noise loop, first-person
-- grid-based corridor movement and rendering, inside one fixed test
-- layout (no real cave generation, no enemies yet). Step 2 of the build
-- order in CLAUDE.md -- validate crank/light/noise feel in isolation, on
-- real hardware, before cave.lua adds more variables to test against.
--
-- Camera is first-person (see CLAUDE.md "Camera / rendering" section) --
-- not the top-down view this file started as. Movement is grid-based and
-- facing-relative, but NOT up-to-walk-forward: Left/Right alternate to
-- crawl forward one tile at a time away from junctions, and become a
-- sticky peek (committed via A) once there's an actual choice to make --
-- see the === Player === comment block below for the full control
-- breakdown. Rendering is a nested-rectangle corridor perspective, not
-- true per-pixel raycasting -- a fixed, small number of draw calls per
-- frame regardless of view distance, which is what keeps this cheap
-- enough for Playdate's CPU budget.
-- =============================================================

import "CoreLibs/graphics"
import "CoreLibs/ui"

import "config"
import "light"

local pd <const> = playdate
local gfx <const> = playdate.graphics

local SCREEN_W <const> = 400
local SCREEN_H <const> = 240

-- === Fixed test layout ===
-- '.' = open, anything else (including out of bounds) = wall. Just a
-- placeholder pillared hall to test forward/turn movement and left/
-- right wall detection against -- not real cave geometry.
local testMap <const> = {
    "#########",
    "#.......#",
    "#.#.###.#",
    "#.#.#...#",
    "#.#.###.#",
    "#.#.....#",
    "#.#.###.#",
    "#.......#",
    "#########",
}

local function isWall(cx, cy)
    if cy < 1 or cy > #testMap then return true end
    local row = testMap[cy]
    if cx < 1 or cx > #row then return true end
    return row:sub(cx, cx) ~= "."
end

local tileSize <const> = Config.movement.tileSize

-- === Player ===
-- tileX/tileY: the logical grid tile the player occupies (updates the
-- instant a move starts, same pattern as the old top-down code).
-- pixelX/pixelY: continuous world position that slides toward the tile
-- center over time -- this is what makes movement gradual instead of an
-- instant snap, and it doubles as the camera's continuous depth position
-- for rendering (see continuousDepthAt below).
--
-- facingDX/DY: the player's TRUE facing -- unit vector, one of N/E/S/W.
--
-- viewDX/DY + viewRightDX/DY: what's actually RENDERED this frame. Only
-- diverges from facing while peeking at a junction (see updateMovement).
--
-- CONTROLS (see updateMovement for the actual logic):
--   Away from a junction: Left/Right ALTERNATE to crawl forward one tile
--   per tap -- press the same side twice in a row and the second tap
--   does nothing, forcing left-right-left-right like actual crawling
--   through a tight space, instead of a plain "move forward" button.
--   At a junction (current tile has an open path to either side of
--   facing): Left/Right instead PEEK -- one 90-degree rotation per tap,
--   sticky, cumulative from whatever's currently being viewed, so
--   repeated taps can look all the way around. A commits: turns the true
--   facing to match the current view, then steps into it.
--   Down: instant 180-degree turn-around, no step. This is now the only
--   way to backtrack -- deliberate, not a free instant action.
local player = {
    tileX = 2, tileY = 2,
    pixelX = 0, pixelY = 0,
    targetPixelX = 0, targetPixelY = 0,
    moving = false,
    facingDX = 1, facingDY = 0, -- start facing East
    viewDX = 1, viewDY = 0,
    viewRightDX = 0, viewRightDY = 1,
}

-- Which side crawled last, so Left/Right can enforce alternation. Reset
-- to nil (either side may lead) whenever the player enters a fresh
-- stretch via a junction commit or a turn-around.
local lastCrawlSide = nil

local function tileToPixelCenter(tx, ty)
    return tx * tileSize + tileSize / 2, ty * tileSize + tileSize / 2
end

player.pixelX, player.pixelY = tileToPixelCenter(player.tileX, player.tileY)
player.targetPixelX, player.targetPixelY = player.pixelX, player.pixelY

-- 90-degree rotations of a facing vector, in screen space (y+ down).
local function leftOf(dx, dy)
    return dy, -dx
end

local function rightOf(dx, dy)
    return -dy, dx
end

-- True when the player's CURRENT tile has an open path to either side of
-- the true facing -- i.e. there's an actual choice to make here, not
-- just one way forward. Checked against facing (not view) so peeking
-- around doesn't change what counts as "at a junction."
local function atJunction()
    local rx, ry = rightOf(player.facingDX, player.facingDY)
    local leftOpen = not isWall(player.tileX - rx, player.tileY - ry)
    local rightOpen = not isWall(player.tileX + rx, player.tileY + ry)
    return leftOpen or rightOpen
end

-- The three directions peeking is allowed to land on, in left-to-right
-- order, relative to true facing: [left, straight, right]. "Behind" is
-- never in this list at all -- it's not a peek option, turning around is
-- Down's job. Each slot is either {dx, dy} if that direction is open, or
-- false if it's a wall -- so callers can skip closed slots without
-- losing their place in the ordering.
local function junctionOptions()
    local lx, ly = leftOf(player.facingDX, player.facingDY)
    local rx, ry = rightOf(player.facingDX, player.facingDY)
    local options = { { lx, ly }, { player.facingDX, player.facingDY }, { rx, ry } }
    for i, dir in ipairs(options) do
        if isWall(player.tileX + dir[1], player.tileY + dir[2]) then
            options[i] = false
        end
    end
    return options
end

-- Index of the current view within `options`, or nil if the view isn't
-- one of the three candidates (e.g. it's still sitting on the true
-- facing and that happens to be a wall, as when a junction is first
-- reached looking straight into a blocked passage).
local function currentOptionIndex(options)
    for i, dir in ipairs(options) do
        if dir and dir[1] == player.viewDX and dir[2] == player.viewDY then
            return i
        end
    end
    return nil
end

-- Attempts to step forward one tile along the TRUE facing. No-ops if
-- already mid-move or the target tile is a wall.
local function tryStep()
    if player.moving then return end
    local nx = player.tileX + player.facingDX
    local ny = player.tileY + player.facingDY
    if isWall(nx, ny) then return end
    player.tileX, player.tileY = nx, ny
    player.targetPixelX, player.targetPixelY = tileToPixelCenter(nx, ny)
    player.moving = true
end

-- Instant 180-degree turn -- no step. Guarded against mid-slide like
-- every other facing change.
local function turnAround()
    if player.moving then return end
    player.facingDX, player.facingDY = -player.facingDX, -player.facingDY
    player.viewDX, player.viewDY = player.facingDX, player.facingDY
    lastCrawlSide = nil -- fresh direction, either hand may lead
end

-- Turns the true facing to match whatever's currently being viewed, then
-- attempts to step into it. The turn always takes; the step doesn't if
-- the target tile is a wall (same rule tryStep always had).
local function commitView()
    player.facingDX, player.facingDY = player.viewDX, player.viewDY
    tryStep()
    lastCrawlSide = nil -- fresh direction, either hand may lead
end

local function updateMovement(dt)
    if pd.buttonJustPressed(pd.kButtonDown) then
        turnAround()
    end

    if atJunction() then
        -- Peek: step through {left, straight, right} one OPEN option at
        -- a time, skipping walls, clamped at the ends -- never wraps
        -- onto a wall or onto "behind." No movement happens from
        -- Left/Right here.
        local peekLeft = pd.buttonJustPressed(pd.kButtonLeft)
        local peekRight = pd.buttonJustPressed(pd.kButtonRight)
        if peekLeft or peekRight then
            local options = junctionOptions()
            local idx = currentOptionIndex(options) or 2 -- default: straight
            local from, to, step = idx + 1, 3, 1
            if peekLeft then
                from, to, step = idx - 1, 1, -1
            end
            for i = from, to, step do
                if options[i] then
                    player.viewDX, player.viewDY = options[i][1], options[i][2]
                    break
                end
            end
        end

        -- A only ever moves the player IN CONJUNCTION with a junction --
        -- it's the commit for a peek, not a general "move forward"
        -- button. Gating it here (instead of unconditionally below)
        -- keeps it from silently letting you skip the crawl alternation
        -- in a plain corridor.
        if pd.buttonJustPressed(pd.kButtonA) then
            commitView()
        end
    else
        -- Crawl: alternating taps advance one tile at a time. Repeating
        -- the same side without alternating does nothing. A does
        -- nothing here -- see the junction branch above.
        if pd.buttonJustPressed(pd.kButtonLeft) and lastCrawlSide ~= "left" then
            lastCrawlSide = "left"
            tryStep()
        elseif pd.buttonJustPressed(pd.kButtonRight) and lastCrawlSide ~= "right" then
            lastCrawlSide = "right"
            tryStep()
        end
        -- Not at a junction -- nothing to peek at, keep view synced to
        -- facing so rendering doesn't stay stuck on a stale peek.
        player.viewDX, player.viewDY = player.facingDX, player.facingDY
    end

    player.viewRightDX, player.viewRightDY = rightOf(player.viewDX, player.viewDY)

    if player.moving then
        local step = Config.movement.moveSpeed * dt
        local dx = player.targetPixelX - player.pixelX
        local dy = player.targetPixelY - player.pixelY
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist <= step or dist == 0 then
            player.pixelX, player.pixelY = player.targetPixelX, player.targetPixelY
            player.moving = false
        else
            player.pixelX += dx / dist * step
            player.pixelY += dy / dist * step
        end
    end
end

-- === Rendering ===

-- Screen-space rectangle for the tunnel cross-section at a given
-- CONTINUOUS depth (depth 0 = camera plane = full screen, larger depth
-- shrinks toward a vanishing point at screen center). Continuous (not
-- integer) so the view smoothly grows/shrinks while the player slides
-- between tiles, instead of popping.
local function rectForDepth(depth)
    local scale = 1 / (1 + depth)
    local w, h = SCREEN_W * scale, SCREEN_H * scale
    return (SCREEN_W - w) / 2, (SCREEN_H - h) / 2, w, h
end

-- How far (in fractional tiles) the cell `d` steps ahead of the
-- player's logical tile actually is from the camera's continuous
-- position. This is what makes forward/backward sliding animate the
-- corridor smoothly rather than jumping a full tile at a time.
local function continuousDepthAt(d)
    local cx = player.tileX + player.viewDX * d
    local cy = player.tileY + player.viewDY * d
    local camTileX = player.pixelX / tileSize
    local camTileY = player.pixelY / tileSize
    return (cx - camTileX) * player.viewDX + (cy - camTileY) * player.viewDY
end

-- Sets the fill color/dither for a surface at a given depth, combining
-- THREE things into one continuous 0..1 brightness before a single
-- setDitherPattern call: the charge tier's brightness, distance falloff
-- (near surfaces dense/solid, far surfaces fade toward black), and the
-- surface's own material (Config.materials) -- its intrinsic "color",
-- invisible in the dark, revealed and shaded once light reaches it. This
-- order matters: combining as real numbers first and dithering once
-- avoids double-quantizing two already-dithered patterns together, which
-- looks muddy.
local function setSurfaceDither(depth, material)
    local viewDist = Light.getViewDistance()
    local falloff = math.max(0, 1 - depth / viewDist)
    local brightness = Light.getDither() * falloff * material.dither
    gfx.setColor(gfx.kColorWhite)
    -- setDitherPattern's parameter is ALPHA relative to the current fill
    -- color (white): 0 = fully opaque (solid white), 1 = fully
    -- transparent (background/black shows through). That's the OPPOSITE
    -- direction from brightness, so it needs inverting -- confirmed by
    -- testing: passing brightness straight through made higher charge
    -- render DARKER, which is this bug.
    gfx.setDitherPattern(1 - brightness, gfx.image.kDitherTypeBayer8x8)
end

local function drawCorridor()
    local maxDepth = math.ceil(Light.getViewDistance())
    local prevX, prevY, prevW, prevH = 0, 0, SCREEN_W, SCREEN_H -- depth-0 camera plane

    for d = 1, maxDepth do
        local depth = continuousDepthAt(d)
        if depth <= 0 then break end

        local x, y, w, h = rectForDepth(depth)
        local cx = player.tileX + player.viewDX * d
        local cy = player.tileY + player.viewDY * d
        local leftWall = isWall(cx - player.viewRightDX, cy - player.viewRightDY)
        local rightWall = isWall(cx + player.viewRightDX, cy + player.viewRightDY)
        local ahead = isWall(cx, cy)

        -- Floor and ceiling -- a separate axis from left/right/ahead, so
        -- always present at this depth regardless of what's blocked.
        -- Drawn first so wall fills and the debug outline layer cleanly
        -- on top. Ceiling reuses the floor material for now (no separate
        -- Config.materials.ceiling yet -- split it out if they should
        -- ever look different).
        setSurfaceDither(depth - 0.5, Config.materials.floor)
        gfx.fillPolygon(prevX, prevY + prevH, prevX + prevW, prevY + prevH, x + w, y + h, x, y + h)
        setSurfaceDither(depth - 0.5, Config.materials.floor)
        gfx.fillPolygon(prevX, prevY, prevX + prevW, prevY, x + w, y, x, y)

        -- Floor/ceiling perspective guide at this depth -- ONLY while
        -- there's some light. This used to be unconditional "so the
        -- tunnel reads clearly while tuning," but that meant the corridor
        -- outline was visible in solid white regardless of charge, which
        -- reads as "the light is always on" -- dark needs to actually be
        -- dark for the rest of the design to mean anything.
        if Light.getDither() > 0 then
            gfx.setColor(gfx.kColorWhite)
            gfx.drawRect(x, y, w, h)
        end

        if leftWall then
            setSurfaceDither(depth - 0.5, Config.materials.wall)
            gfx.fillPolygon(prevX, prevY, x, y, x, y + h, prevX, prevY + prevH)
        end

        if rightWall then
            setSurfaceDither(depth - 0.5, Config.materials.wall)
            gfx.fillPolygon(prevX + prevW, prevY, x + w, y, x + w, y + h, prevX + prevW, prevY + prevH)
        end

        if ahead then
            setSurfaceDither(depth, Config.materials.wall)
            gfx.fillRect(x, y, w, h)
            break -- nothing farther down a blocked corridor is visible
        end

        prevX, prevY, prevW, prevH = x, y, w, h
    end
end

-- Screen-space flashlight beam, layered on top of the corridor render.
--
-- IMPORTANT: this can't be drawn as plain shape fills straight onto the
-- live scene -- gfx fill calls (fillCircleAtPoint, fillRect, ...) always
-- FULLY OVERWRITE the pixels they cover with black/white, there's no
-- "leave existing content alone" option. A first attempt that layered
-- circles directly over the corridor blacked out the whole screen on
-- the very first (largest) circle, because that circle's radius covered
-- nearly the entire display -- nothing drawn after it could bring the
-- corridor back, because it was already gone.
--
-- The correct approach: build the vignette shape on a separate, blank
-- offscreen image (safe to layer circles on, since there's no scene
-- content there to destroy), then composite that image onto the real
-- screen using kDrawModeWhiteTransparent -- which treats the image's
-- WHITE pixels as see-through (corridor shows through) and only its
-- BLACK pixels actually paint (darkening the vignette edges).
--
-- Cached per dither value -- there are only 6 possible values (5 charge
-- tiers + the docked override, which collapses onto the "off" tier's
-- 0), so this only ever builds the image once per value, not every
-- frame -- same "precompute once, reuse" rule as everything else here.
local vignetteMaskCache = {}

local function buildVignetteMask(dither)
    local vignetteCfg = Config.vignette
    local centerX, centerY = SCREEN_W / 2, SCREEN_H / 2
    local maxRadius = math.sqrt(centerX * centerX + centerY * centerY)
    local hotspotRadius = maxRadius * vignetteCfg.hotspotFraction * dither

    -- Starts fully black (fully opaque vignette everywhere); we only
    -- need to paint the parts that should lighten toward the hotspot.
    local mask = gfx.image.new(SCREEN_W, SCREEN_H, gfx.kColorBlack)
    gfx.pushContext(mask)
        for i = vignetteCfg.bands, 1, -1 do
            local t = i / vignetteCfg.bands -- 1 (outer, stays near-black) down toward 0 (inner, near-white)
            local radius = hotspotRadius + (maxRadius - hotspotRadius) * t
            gfx.setColor(gfx.kColorWhite)
            -- Same alpha direction as setSurfaceDither: 0 = opaque white,
            -- 1 = transparent (shows this image's black background). The
            -- outer band (t=1) should STAY the black background, i.e.
            -- stay transparent, so it wants the HIGH end -- alpha = t
            -- directly, not 1-t. (The previous 1-t here meant the mask
            -- rendered almost entirely opaque white, so the vignette was
            -- doing effectively nothing -- this is why the ring "went
            -- away.")
            gfx.setDitherPattern(t, gfx.image.kDitherTypeBayer8x8)
            gfx.fillCircleAtPoint(centerX, centerY, radius)
        end
        -- Guaranteed fully clear (solid white, no dithering) at the
        -- very center, regardless of how the banded gradient above reads.
        gfx.setColor(gfx.kColorWhite)
        gfx.fillCircleAtPoint(centerX, centerY, hotspotRadius)
    gfx.popContext()

    return mask
end

local function drawVignette()
    local dither = Light.getDither()

    -- At zero charge, hotspotRadius collapses to 0 -- there's no
    -- guaranteed-clear area left in the mask, so it can paint solid
    -- black over everything, including the corridor's always-visible
    -- debug outline. Skip the vignette entirely here instead: the scene
    -- is already appropriately dark (walls render at 0 brightness), and
    -- this keeps the debug outline visible while genuinely dark, rather
    -- than the vignette accidentally erasing it too.
    if dither <= 0 then return end

    local mask = vignetteMaskCache[dither]
    if not mask then
        mask = buildVignetteMask(dither)
        vignetteMaskCache[dither] = mask
    end

    gfx.setImageDrawMode(gfx.kDrawModeWhiteTransparent)
    mask:draw(0, 0)
    gfx.setImageDrawMode(gfx.kDrawModeCopy) -- reset so later draws (HUD) aren't affected
end

local function drawHUD()
    gfx.setColor(gfx.kColorWhite)
    local text = string.format(
        "charge %d  tier %s  noise %d",
        math.floor(Light.getCharge()), Light.getTierName(), math.floor(Light.getNoise())
    )
    gfx.drawText(text, 4, 4)
end

-- === Main loop ===
function pd.update()
    local dt = pd.getElapsedTime()
    pd.resetElapsedTime()

    Light.update(dt)
    updateMovement(dt)

    gfx.clear(gfx.kColorBlack)
    drawCorridor()
    drawVignette()
    drawHUD()
end
