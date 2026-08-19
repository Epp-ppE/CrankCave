-- main.lua
-- Prototype test scene: crank -> charge/light/noise loop, first-person
-- grid-based corridor movement and rendering, inside one fixed test
-- layout (no real cave generation, no enemies yet). Step 2 of the build
-- order in CLAUDE.md -- validate crank/light/noise feel in isolation, on
-- real hardware, before cave.lua adds more variables to test against.
--
-- Camera is first-person (see CLAUDE.md "Camera / rendering" section) --
-- not the top-down view this file started as. Movement is grid-based
-- and facing-relative: up/down step forward/backward, left/right turn
-- 90 degrees. Rendering is a nested-rectangle corridor perspective, not
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
-- facingDX/DY: unit vector, one of N/E/S/W. rightDX/DY: 90-degree
-- clockwise rotation of facing, used to find the tiles to either side.
local player = {
    tileX = 2, tileY = 2,
    pixelX = 0, pixelY = 0,
    targetPixelX = 0, targetPixelY = 0,
    moving = false,
    facingDX = 1, facingDY = 0, -- start facing East
    rightDX = 0, rightDY = 1,
}

local function tileToPixelCenter(tx, ty)
    return tx * tileSize + tileSize / 2, ty * tileSize + tileSize / 2
end

player.pixelX, player.pixelY = tileToPixelCenter(player.tileX, player.tileY)
player.targetPixelX, player.targetPixelY = player.pixelX, player.pixelY

local function setFacing(dx, dy)
    player.facingDX, player.facingDY = dx, dy
    -- 90-degree clockwise rotation of facing, in screen space (y+ down).
    player.rightDX, player.rightDY = -dy, dx
end

local function turnLeft()
    if player.moving then return end
    setFacing(player.facingDY, -player.facingDX) -- counter-clockwise
end

local function turnRight()
    if player.moving then return end
    setFacing(-player.facingDY, player.facingDX) -- clockwise
end

-- Attempts to step forward (sign = 1) or backward (sign = -1) along the
-- direction faced. No-ops if already mid-move or the target tile is a
-- wall.
local function tryStep(sign)
    if player.moving then return end
    local nx = player.tileX + player.facingDX * sign
    local ny = player.tileY + player.facingDY * sign
    if isWall(nx, ny) then return end
    player.tileX, player.tileY = nx, ny
    player.targetPixelX, player.targetPixelY = tileToPixelCenter(nx, ny)
    player.moving = true
end

local function updateMovement(dt)
    if pd.buttonJustPressed(pd.kButtonLeft) then
        turnLeft()
    elseif pd.buttonJustPressed(pd.kButtonRight) then
        turnRight()
    end

    if pd.buttonIsPressed(pd.kButtonUp) then
        tryStep(1)
    elseif pd.buttonIsPressed(pd.kButtonDown) then
        tryStep(-1)
    end

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
    local cx = player.tileX + player.facingDX * d
    local cy = player.tileY + player.facingDY * d
    local camTileX = player.pixelX / tileSize
    local camTileY = player.pixelY / tileSize
    return (cx - camTileX) * player.facingDX + (cy - camTileY) * player.facingDY
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
        local cx = player.tileX + player.facingDX * d
        local cy = player.tileY + player.facingDY * d
        local leftWall = isWall(cx - player.rightDX, cy - player.rightDY)
        local rightWall = isWall(cx + player.rightDX, cy + player.rightDY)
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
