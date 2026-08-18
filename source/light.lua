-- light.lua
-- Charge -> brightness/noise system. Crank input drives a charge meter,
-- charge maps to a discrete brightness (dither) tier over a fixed view
-- distance, and crank speed drives a noise meter. Every number used here
-- comes from config.lua -- see that file before tuning anything.
--
-- Usage: `import "config"` then `import "light"` (config must load first
-- -- this file reads Config.charge.tiers at load time), then each frame:
--   Light.update(dt)
--   Light.getDither()        -- 0..1, already accounts for crank-docked
--   Light.getTierName()      -- current tier's debug name
--   Light.getCharge()        -- raw 0..100 charge value
--   Light.getNoise()         -- current noise meter value
--   Light.getViewDistance()  -- fixed LOS distance in tiles
-- =============================================================

Light = {}

local pd <const> = playdate

-- Internal state. Not exposed directly -- read through the getters above
-- so callers can't reach in and mutate it out from under the update loop.
local charge = 0
local noise = 0
local currentTier = Config.charge.tiers[#Config.charge.tiers] -- start at "off"

-- Finds the active tier for a given charge value. Config.charge.tiers is
-- listed highest-minCharge-first, so the first match scanning top to
-- bottom is the correct (highest qualifying) tier. The last tier has
-- minCharge = 0, so this always matches something.
local function tierForCharge(c)
    local tiers = Config.charge.tiers
    for i = 1, #tiers do
        if c >= tiers[i].minCharge then
            return tiers[i]
        end
    end
    return tiers[#tiers]
end

-- True when the crank-docked override should force light to 0. Checked
-- in both getters below rather than baked into `charge` itself, so the
-- underlying charge value keeps accumulating/draining normally while
-- docked and un-docking doesn't force a recharge from zero. (Assumption,
-- not spelled out in CLAUDE.md -- flag if that's not the intended feel.)
local function isDockedOverride()
    return Config.charge.dockKillsLightInstantly and pd.isCrankDocked()
end

function Light.update(dt)
    local chargeCfg = Config.charge
    local noiseCfg = Config.noise

    -- Crank input: degrees turned this frame. One-way dynamo -- only
    -- clockwise (positive, per SDK convention) engages the mechanism.
    -- Counter-clockwise contributes nothing to charge OR noise, like a
    -- ratcheting hand-crank flashlight free-spinning backward. If the
    -- sign convention turns out reversed on hardware, flip `> 0` to `< 0`.
    local rawCrankChange = pd.getCrankChange()
    local crankDegrees = rawCrankChange > 0 and rawCrankChange or 0
    local crankSpeed = dt > 0 and (crankDegrees / dt) or 0 -- degrees/sec

    -- --- Charge ---
    charge += crankDegrees * chargeCfg.gainPerCrankDegree
    charge -= chargeCfg.drainPerSecond * dt
    if charge < chargeCfg.min then charge = chargeCfg.min end
    if charge > chargeCfg.max then charge = chargeCfg.max end

    currentTier = tierForCharge(charge)

    -- --- Noise ---
    -- Roughly quadratic in crank speed: slow cranking is disproportionately
    -- quieter than fast cranking is loud.
    if crankSpeed > 0 then
        noise += noiseCfg.crankNoiseCoefficient * (crankSpeed ^ noiseCfg.crankSpeedExponent) * dt
    end
    noise -= noiseCfg.decayPerSecond * dt
    if noise < 0 then noise = 0 end
end

function Light.getDither()
    if isDockedOverride() then return 0 end
    return currentTier.dither
end

function Light.getTierName()
    if isDockedOverride() then return "off" end
    return currentTier.name
end

function Light.getCharge()
    return charge
end

function Light.getNoise()
    return noise
end

function Light.getViewDistance()
    return Config.charge.viewDistance
end
