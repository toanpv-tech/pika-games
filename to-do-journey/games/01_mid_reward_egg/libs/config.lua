-- Egg scene: layout, timing and data tables. Geometry is the v3 demo's
-- (screen/map-lab.html); the source art is 256px, halved to the demo's 128 box.
local M = {}

M.SCREEN_H = 320
M.CENTER_X = 240 -- middle egg, and where the chosen one lands

-- Eggs: 128px boxes centred on EGG_CX, top at EGG_TOP. The star egg's body sits
-- 11px right of its box centre (EGG_LECH), so the focus FX and the settle follow
-- the body, not the box.
M.EGG_BOX = 128
M.EGG_TOP = 140
M.EGG_CX = { 110, 240, 370 }
M.EGG_LECH = { 11, 0, 0 }

-- The two halves the crack splits each egg into (tools/egg-assets/convert_v3_eggs.py)
-- and their offsets in the box. Whole pixels on purpose: set_pos rounds, and a
-- half-pixel dy opens a hairline along the crack.
M.EGGS = {
  { name = "star",
    top = { dx = 19, dy = 4, w = 109, h = 60 },
    bot = { dx = 1, dy = 53, w = 123, h = 70 } },
  { name = "moon",
    top = { dx = 7, dy = 5, w = 117, h = 59 },
    bot = { dx = 1, dy = 53, w = 127, h = 69 } },
  { name = "leaf",
    top = { dx = 6, dy = 5, w = 122, h = 59 },
    bot = { dx = 0, dy = 53, w = 128, h = 70 } },
}

-- The gem art is 96px, the set_scale cap, and is scaled UP to the demo's sizes.
-- The big gem and the 12 flying ones share it (one decoded buffer).
M.REWARD = { ART = 96, CX = 240, CY = 128 }
M.REWARD_K = {
  BIG = 180 / 96,           -- hatched, full size
  PARKED = 180 * 0.53 / 96, -- lifted aside while the total counts
  FLY = 64 / 96,            -- each gem flying into the bag
  GONE = 180 * 0.20 / 96,   -- the last of it, leaving for the bag
}

-- Opaque, so raw RGB565 (Sprite.new reads exactly W*H*2 bytes, no header):
-- 300KB instead of a 450KB PNG. Fades out as the shell splits, then is hidden,
-- which drops a full-screen blit from every frame after.
M.CAVE = { W = 480, H = 320, FILE = "assets/runtime/v3_cave_bg.rgb565", DIM_MS = 350 }

-- FX layers. All are over the 96px transform cap, so they only move and fade.
M.FX_SPOT = { DX = -100, Y = -30 }                                     -- cone over the selected egg
-- The ring's opacity changes only every STEP_MS: each change repaints its
-- 162x125 area through every layer below (log 13/10: browse at ~13 fps).
M.FX_RING = { DX = -81, Y = 194, PERIOD = 1000, MIN = 150, MAX = 255, STEP_MS = 100 } -- pulsing ring at its foot
M.FX_RAYS = { X = 110, Y = -38, IN_MS = 600, BREATH_PERIOD = 2400, BASE = 191, DIP = 140 }
M.FX_FLASH = { X = 155, Y = 44, MS = 550, PEAK_AT = 0.30 }             -- the split
M.FX_SPARK = { X = 302, Y = 143, MS = 700, PEAK_AT = 0.40 }            -- bag full

-- From the egg being chosen (ms).
M.T = {
  GATHER = 520,  -- chosen egg slides to centre, then shakes
  OPEN = 1400,   -- shell splits
  SETTLE = 2600, -- the opened gem is held this long before the bag comes
}

-- The eggs fall in, staggered, settling on the demo's keyframes.
M.DROP = { MS = 620, DELAY = 300, STAGGER = 120, FROM = -300,
           K = { 0.62, 0.78, 0.90, 0.95 },
           V = { 0, -14, 0, -3 } }

-- Rotation is refused on the 109-128px shells, so the demo's wobble and shake
-- are a bob and a sideways shudder.
-- OTHER_PERIOD: the eggs not selected bob slower; every 1px step repaints both
-- halves, and the selected egg's moves matter more.
M.WOBBLE = { PERIOD = 1700, OTHER_PERIOD = 3400, AMP = 3 }
M.SHAKE = { PERIOD = 210, AMP = 5 }
M.HOP = { MS = 300, PX = 10 }        -- the egg the cursor just reached
M.SEL_LIFT = 8                       -- the selected egg sits this much higher
M.GATHER_OUT = { DX = 320, DY = 30 } -- the other two slide off the sides
M.OPEN = { MS = 800, TOP_DX = -44, TOP_DY = -130, BOT_DY = 18 }

-- Idle clocks run from the end of the intro lines or the last press, whichever
-- is later: Pika's reminder, then the selected egg opens by itself.
M.IDLE = { REMIND_MS = 7000, AUTO_MS = 14000 }
-- VOICE_2 follows VOICE_1 after GAP_MS with no press. A line whose end event never
-- arrives (dropped finish, wedged audio) counts as over after MAX_MS.
M.VOICE = { GAP_MS = 3000, MAX_MS = 15000 }
-- The select tick plays at most once per GAP_MS; the cursor still moves on every
-- press. Kept above the engine's 150 ms play cooldown (a refused play after the
-- stop is a silent press) and the ~170 ms pipeline start (stops landing mid-start
-- wait on the speaker lock), so mashing never churns the speaker.
M.SELECT_SFX = { GAP_MS = 250 }
-- "pick" refused by that same cooldown (Enter right after a select tick) is tried
-- again every frame for this long, then dropped: past it the egg is already
-- sliding and the click would no longer belong to the press.
M.PICK_RETRY_MS = 300

M.BAG = {
  X = 323, Y = 163,             -- resting position
  OFF_X = 170,                  -- parked this far right, off screen
  SLIDE_MS = 400,
  MOUTH_X = 397, MOUTH_Y = 225, -- where the flying gems land
}

-- 12 gems along a quadratic curve into the bag. assets/sounds/pour.mp3 is baked
-- for N = 12 and STAGGER_MS = 95 (one ting per gem, 1.94 s), then the demo's cheer
-- (chime + applause + whistle, 2.6 s; tools/egg-assets/make_egg_cheer.py): change
-- N or STAGGER_MS, rebuild it.
M.GEM = {
  N = 12,
  STAGGER_MS = 95,
  FLIGHT_MS = 620,
  FROM_X = 240, FROM_Y = 60, -- the big gem's centre once parked
  ARC = 60,                  -- how far the curve bows above the straight line
  K_FROM = 1.0, K_TO = 0.30, -- scale along the flight, of the 64px flying size
}

-- Nunito Black has tabular figures (34px per digit at 56px), so a number's width
-- is digits * DIGIT_W -- Text cannot report its own width.
M.FONT_NUM = "fonts/nunito-black.ttf"
M.PLUS = { PX = 52, CY = 212, COLOR = 0xFFFFFF } -- "+N" under the big gem
M.COUNT = {                                       -- the week total
  CY = 160, PX = 56, COLOR = 0xFFFFFF, DIGIT_W = 34,
  IN_MS = 350, IN_DY = 10,
  SPAN_MIN_MS = 400, STEP_MIN_MS = 33,
  BUMP_MS = 120, BUMP_PX = 3,
  OUT_MS = 350,
}

-- Gem icon at the head of the total once counting lands; tucked OVERLAP px under
-- the number and DY px lower, because the gem body sits high in its box.
M.ICON = { FILE = "assets/runtime/popa_60.png", W = 60,
           OVERLAP = 4, DY = 3,
           IN_MS = 350, PEAK = 1.15, PEAK_AT = 0.6,
           SHIFT_MS = 250,
           OUT_K = 0.4 }

-- The big gem: bob while shown, entrance (ratios of BIG, overshooting), parked
-- aside for the count, then gone into the bag AT_MS after the last gem leaves.
M.POPA = { FLOAT_PERIOD = 1600, FLOAT_PX = 5 }
M.POPA_IN = { MS = 600, FROM = 0.10, PEAK = 1.06, PEAK_AT = 0.72 }
M.POPA_PARK = { MS = 450, DY = -60 }
M.POPA_GONE = { MS = 350, AT_MS = 60, DX = 60, DY = 20 }

M.T_BAG = {
  SLIDE_IN = 500,  -- bag sliding in, before it opens
  OPEN_HOLD = 250, -- open, before the first gem leaves
  FULL_HOLD = 700, -- full, before it closes
  CLOSE_OUT = 600, -- closed at least this long; it slides away once "pour" is over
  -- The cheer ends ~2.6 s into BAG_OUT; past this, the end event is taken as lost.
  CHEER_MAX_MS = 4000,
}

-- After "pour", with the bag still shut and the total on show, Pika reads the
-- server's cp-5 ("you received N diamonds") then cp-6 ("you now have T"), then
-- the bag leaves. Both are streamed from theme_meta.audio.dynamic[] (TTS made
-- per call, so a cold stream can take a while to start). A line whose end event
-- never arrives counts as over after LINE_MAX_MS.
M.OUTRO = { LINE_MAX_MS = 12000 }

-- "pour" is cued this long before the first gem lands, so it is already running
-- as they arrive. At most 1370 (the bag starts to slide in).
M.POUR_SOUND = { LEAD_MS = 500 }

-- Stand-ins until the journey frame arrives. They keep the animation arithmetic
-- valid but are never shown: without a frame the numbers stay hidden.
M.DEFAULT = { GEMS = 10, WEEK_TOTAL = 1000, BAG = "sao_xanh" }

-- reward_options.equipped_item_id (Pika Shop BACKPACK id) -> art name, i.e.
-- assets/runtime/bag_<name>_{closed,open,full}.png. Missing or unknown id, or
-- art that fails to load -> DEFAULT.BAG.
M.BAGS = {
  backpack_blue_star    = "sao_xanh",
  backpack_morning_star = "sao_cu",
  backpack_explorer     = "tham_hiem",
  backpack_pika         = "pika",
  backpack_moon_bunny   = "tho_trang",
  backpack_gold_star    = "sao_vang",
  backpack_green_dino   = "khung_long",
  backpack_unicorn      = "ky_lan",
  backpack_shark        = "ca_map",
  backpack_giraffe      = "huou",
  backpack_jungle_dino  = "khung_long_rung",
  backpack_kitty        = "meo",
  backpack_robot        = "robot",
  backpack_lion_dance   = "lan",
  backpack_astronaut    = "phi_hanh_gia",
  backpack_koi          = "ca_koi",
  backpack_octopus      = "bach_tuoc",
  backpack_monkey       = "khi",
  backpack_husky        = "husky",
  backpack_race_car     = "xe_dua",
}

return M
