-- config.lua
-- Every tunable number in the game lives here. When you're tuning feel
-- (crank sensitivity, light radius, noise, enemy speed...) this is the
-- only file that should need editing -- other modules read from this
-- table, they shouldn't hardcode their own numbers.
--
-- Usage: `import "config"` once (e.g. from main.lua, before anything that
-- needs it), then reference `Config.whatever` from any file. This is a
-- GLOBAL table, not a local returned from the file -- Playdate's `import`
-- splices source in like #include rather than capturing a return value
-- the way Lua's `require` does, so a `local` + `return` here would leave
-- every other file unable to see it.
-- =============================================================

Config = {}

-- === Charge / Light ===
-- The crank charges a 0-100 meter. Charge does NOT change how far light
-- reaches -- it changes how BRIGHT it is, simulated on the 1-bit display
-- via dither density (ratio of lit/white pixels to dark/black pixels
-- within a fixed view distance). Low charge = sparse dither, mostly dark.
-- Full charge = solid white, fully lit. Tiers are still DISCRETE steps
-- (not a smooth per-frame fade) so the rendered pattern is a fixed,
-- precomputed mask per tier -- cheap, and doesn't shimmer/crawl the way
-- a continuously-changing dither would.
Config.charge = {
    min = 0,
    max = 100,

    -- Charge gained per degree the crank turns (before speed/noise tradeoffs
    -- are applied -- this is just the accumulation rate).
    gainPerCrankDegree = 0.05,

    -- Passive drain per second while any light is showing. This is what
    -- forces the player back to the crank instead of letting them charge
    -- once and coast for the whole level.
    drainPerSecond = 2.5,

    -- How far the line-of-sight raycast ever reaches, in tiles. This is
    -- now a FIXED constant, independent of charge -- per the light.lua
    -- performance note, LOS is only recomputed on tile-change or
    -- tier-change, so it needs one stable bound to compute against.
    -- Charge no longer grows this distance, only the dither/brightness
    -- within it (see tiers below).
    viewDistance = 12,

    -- Brightness tiers. First tier whose minCharge the current charge
    -- meets or exceeds (scanning from the top) wins.
    --   dither = 0    -> fully dark, no light at all (same as no charge)
    --   dither = 1    -> fully lit, solid white, no dithering
    --   in between    -> ordered dither pattern at that white:black ratio
    -- Breakpoints stay front-loaded (15/40/70/100, not evenly spaced) on
    -- purpose: the first faint tier is cheap to reach so you're never
    -- stuck totally blind for long, but the last stretch to full
    -- brightness costs the most charge -- and therefore the most
    -- cranking, and therefore the most noise.
    --
    -- Note: the 0.5 <-> 0.75 boundary straddles the Nocturnal's "keep
    -- light below ~60%" rule (see CLAUDE.md) -- staying at or under the
    -- "dim" tier keeps you under its threshold, "bright" or above breaks it.
    tiers = {
        { name = "full",  minCharge = 80, dither = 1.00 },
        { name = "bright",minCharge = 60,  dither = 0.75 },
        { name = "dim",   minCharge = 40,  dither = 0.50 },
        { name = "faint", minCharge = 15,  dither = 0.25 },
        { name = "off",   minCharge = 0,   dither = 0.00 },
    },

    -- Docking the crank kills light instantly. This is the panic button --
    -- keep this true; it's the single most Playdate-native beat in the
    -- design and shouldn't be softened into a fade-out.
    dockKillsLightInstantly = true,
}

-- === Vignette ===
-- Screen-space circular beam shape layered on top of the corridor render
-- (see main.lua drawVignette) -- separate from the corridor's own
-- distance-based wall dithering. This is what makes it read as a
-- flashlight beam (bright hotspot, darkened edges/corners) rather than
-- just "the tunnel is lit."
Config.vignette = {
    -- Bright hotspot radius as a fraction of the screen's half-diagonal,
    -- scaled by current charge dither (0..1) -- the beam itself shrinks
    -- as charge drops, same as everything else tied to brightness.
    hotspotFraction = 0.35,

    -- Number of concentric dither steps between the hotspot edge and
    -- full darkness at the corners. Kept small and discrete for the same
    -- reason the charge tiers are discrete -- cheap, doesn't shimmer.
    bands = 6,
}

-- === Noise ===
-- Noise is roughly QUADRATIC in crank speed: slow cranking is
-- disproportionately quieter than fast cranking is loud. This is what
-- makes the fast/loud vs slow/quiet tradeoff actually matter.
Config.noise = {
    -- noise = crankNoiseCoefficient * crankSpeed ^ crankSpeedExponent
    crankSpeedExponent = 2.0,
    crankNoiseCoefficient = 0.008,

    -- How fast the noise meter falls back to 0 once the player stops
    -- cranking (units per second).
    decayPerSecond = 40,

    -- One-time noise burst from a shovel dig (see Config.shovel).
    shovelDigNoise = 60,
}

-- === Materials ===
-- Every map tile has its own intrinsic brightness -- a "color" simulated
-- via dither density, independent of light. Invisible in the dark. Where
-- light overlaps a tile, the tile's own brightness MULTIPLIES with the
-- light's brightness (combined as real numbers, then dithered once) --
-- that's what makes different materials read as reflecting the light
-- differently instead of the flashlight painting everything flat white.
Config.materials = {
    floor = { dither = 0.85 }, -- bright, reflective ground
    wall  = { dither = 0.30 }, -- dark, absorbs most light
}

-- === Movement ===
-- D-pad, gradual tile-to-tile motion (not instant snapping). Left hand
-- steers, right hand cranks -- deliberate, so neither input starves the
-- other.
Config.movement = {
    tileSize = 16,     -- pixels per tile
    moveSpeed = 60,    -- pixels/sec while sliding between tiles
}

-- === Shovel ===
-- Digs through blocked rock at a large noise cost (see shovelDigNoise
-- above). Held input, not a tap.
Config.shovel = {
    holdDuration = 1.2, -- seconds A must be held to finish a dig
}

-- === Map memory ===
-- Once a tile is lit, it stays revealed in a dim/wireframe "remembered"
-- state for the rest of the level. This is the core strategic loop:
-- light new ground, memorize it, travel it in the dark to stay quiet.
Config.map = {
    rememberedDimAlpha = 0.35, -- render strength for remembered-but-unlit tiles

    -- Minimum charge-tier dither value (see Config.charge.tiers) a tile
    -- needs to have been seen at before it's committed to permanent
    -- memory. Since brightness no longer has a hard on/off radius edge,
    -- something has to define "lit enough to count" -- anything above
    -- pure dark (0) qualifies by default.
    minDitherToRemember = 0.01,
}

-- === Enemies ===
-- Each enemy teaches exactly one rule. Numbers here are starting points
-- for playtesting, not final.
Config.enemies = {
    stalker = {
        -- Keep your light up. Paths toward the player constantly; retreats
        -- if caught in the player's light.
        spawnDelaySeconds = 20,
        speed = 40,          -- slower than player on purpose
        retreatOnLight = true,
    },

    blind = {
        -- Keep quiet. Paths to the LOCATION of the player's last noise,
        -- not to the player's current position.
        --
        -- Open design question (see CLAUDE.md #2): is this enemy too hard?
        -- Toggle this off to A/B test a two-enemy loop without it rather
        -- than tuning numbers in the abstract.
        enabled = true,
        hearingRadius = 96,  -- pixels; only "hears" noise events within this range
        speed = 50,
    },

    -- Designed but not yet implemented (see CLAUDE.md) -- left as empty
    -- placeholders so the section stays the single source of truth for
    -- tunables as each enemy comes online. Fill in when built.
    sandworm = {},
    nocturnal = {},
    mouth = {},
}
