-- Timing and visual constants, transcribed from final-demo-todo-resized.html.
-- An uncommented number is the demo's own; deviations say why.
local M = {}

M.SCREEN_W, M.SCREEN_H = 480, 320

-- The demo pops nodes in one by one; the map instead shows all at once, in
-- the tick that lays it out (main.lua, reveal_map).

-- The current node's icon `bounce`: 1s beat, 8% amplitude.
M.BREATHE = { PERIOD = 1000, AMP = 0.08, HOP_PX = 6 }

-- Skipped stage. The demo's grey filter has no engine equivalent, so it is
-- baked: a SKIPPED lesson draws map_icon_<cat><ICON_SUFFIX>.png
-- (tools/todo-assets/bake_skip_icons.py) at the demo's opacity .6, which the
-- detail bar's skipped cell shares. The pedestal stays solid.
M.SKIP = { OPA = 153, ICON_SUFFIX = "_skip" }

-- Connector opacity. The dashed (unwalked) run is eased back so the walked
-- part reads as the brighter of the two.
M.DOT = { OPA_TODO = 210, OPA_DONE = 255 }

-- Connector colour (0xRRGGBB), per theme: picked against the backdrop's
-- median (poc_journey geom THEME_LINE_RGB).
M.LINE_RGB = 0x7A3F0C

-- Four corner leaves (map_leaf_tl/tr/bl/br.png), drawn still. Only the sea
-- theme ships them; true costs ~55KB of PSRAM.
M.LEAVES = false

-- ------------------------------------------------------------ "+K" pill (gop)
--
-- .map-gop: 24px tall, 10px padding, 12px radius, Nunito Black 12. The pill is
-- one baked PNG at a fixed width (the engine can neither draw a rounded rect
-- nor stretch a sprite); the text stays live and is centred on it.
--
-- W fits the longest string the pill can show, K being capped at 99 in
-- geom.window. Nunito Black 12 advances ("+" 8, digit 7, tails measured by
-- tools/measure_gop.py) plus 2 * 10 padding:
--   "+99 hoạt động"  = 8 + 2*7 + 69 + 20 = 111
--   "+99 activities" = 8 + 2*7 + 63 + 20 = 105
-- map_chip.png must be W wide. H is the pill; the PNG is 26 tall because the
-- drop shadow hangs 2px below it.
M.CHIP = {
  W = 111,
  H = 24,
  PX = 12,
  COLOR = 0x6B4A2E,
  FONT = "fonts/nunito-black.ttf",
}

M.CHIP_TEXT = { vi = " hoạt động", en = " activities" }

-- ------------------------------------------- category -> icon, hero, label
--
-- The server sends checkpoints[].category; the contract leaves the icon
-- mapping to firmware. Icon, hero, label and backdrop come from ONE row so
-- they cannot disagree. `loai` is the detail screen's category label in the
-- robot's language, upper case written out (string.upper is byte-wise and
-- leaves Vietnamese letters alone). A hero is its icon on the demo's 101px
-- canvas (44 * 2.3), lit and cropped by tools/bake_detail_art.py; `hero` nil
-- shows the pedestal bare.
--
-- `prog` picks the detail backdrop. /journey carries no programme field, so
-- it is derived from the category: talk-led openers on Cambridge, repetition
-- on SGK, discovery on STEM, free talk on Chat.
M.CAT = {
  WARM_UP  = { obj = "map_icon_warm_up",  hero = "det_hero_warm_up",  prog = "cambridge",
               loai = { vi = "KHỞI ĐỘNG",  en = "WARM-UP" } },
  CREATE   = { obj = "map_icon_create",   hero = "det_hero_create",   prog = "cambridge",
               loai = { vi = "TẠO MỚI",    en = "CREATE" } },
  PRACTICE = { obj = "map_icon_practice", hero = "det_hero_practice", prog = "sgk",
               loai = { vi = "THỰC HÀNH",  en = "PRACTICE" } },
  DRILL    = { obj = "map_icon_drill",    hero = "det_hero_drill",    prog = "sgk",
               loai = { vi = "LUYỆN TẬP",  en = "DRILL" } },
  EXPLORE  = { obj = "map_icon_explore",  hero = "det_hero_explore",  prog = "stem",
               loai = { vi = "KHÁM PHÁ",   en = "EXPLORE" } },
  CHAT     = { obj = "map_icon_chat",     hero = "det_hero_chat",     prog = "chat",
               loai = { vi = "TRÒ CHUYỆN", en = "CHAT" } },
  OTHER    = { obj = "map_icon_fallback", hero = "det_hero_fallback", prog = "chat",
               loai = { vi = "HOẠT ĐỘNG",  en = "ACTIVITY" } },
}

-- OTHER, and any category this firmware does not know, draws the fallback.
M.CAT_FALLBACK = "OTHER"

-- Rewards are recognised by category alone (`type` is GAME_AGENT on them too)
-- and have no row above: no hero, no detail screen.
M.CAT_MID_REWARD   = "MID_REWARD"
M.CAT_FINAL_REWARD = "FINAL_REWARD"

-- ---------------------------------------------------------------- detail view
M.D = {
  -- Pedestal centre. det_base.png is the map's stage pedestal at the hero's
  -- scale (bake_map01_detail.py): its art spans -43..+43 around the centre,
  -- so 162 puts its bottom on the text band (CHU.TOP); the hero's top clears
  -- the bar's box (y 54) by ~18px.
  HERO_X = 240, HERO_Y = 162,
  -- Icon centre vs pedestal centre: the map's (OBJ_DY - BASE_DY) = -33.4 at
  -- k 1.65, times 2.3 / 1.65.
  ICON_DY = -47,

  -- The demo's four programme backdrops (CAT[].prog). One is resident at a
  -- time: 450KB each, and a session opens one lesson.
  BG_FMT = "det_bg_%s.png",
  PROG_FALLBACK = "chat",

  -- `.ad-name` text-shadow 0 2px 0 rgba(0,0,0,.3). Text has no opacity, so
  -- the shadow is a second label in the backdrop's colour darkened by .3,
  -- averaged over the text band.
  SHADOW = {
    DY = 2,
    COLOR = { cambridge = 0x2C1F74, chat = 0x267682, sgk = 0x955720, stem = 0x005CB1 },
  },

  -- `.ad-chu`: label + name centred as one block in the band y=206..310.
  -- TOP is the pedestal's visible bottom; BOTTOM is the safe area.
  CHU = { TOP = 206, BOTTOM = 310, GAP = 6, PAD_X = 20 },

  FONT_BLACK = "fonts/nunito-black.ttf",

  -- LINE is the face's line height (1.364 * px for Nunito), and NAME.LINE the
  -- pitch between the two name labels. The name is 32px on one line and
  -- SMALL (26px) when it needs two, the demo's 30-falling-back-to-24 idea:
  --   one line   27 + 6 + 44     = 77px
  --   two lines  27 + 6 + 2 * 35 = 103px   (band 104; at 32 it would be 121)
  -- Five faces in all (12, 14, 20, 26, 32) need GAME_FONT_SLOTS >= 5; with
  -- fewer, a long name is cut to one line (main.lua, probe_small_name_face).
  LOAI  = { PX = 20, LINE = 27 },
  NAME  = { PX = 32, LINE = 44, MAX_LINES = 2,
            SMALL = { PX = 26, LINE = 35 } },
  COLOR = { NAME = 0xFFFFFF, LOAI = 0xFFFFFF },

  -- No text measurement exists, so names wrap on an estimated em width. The
  -- measured average is 0.572; erring wide only costs an early wrap, erring
  -- narrow runs the name off screen.
  AVG_CHAR_K = 0.60,

  -- ------------------------------------------------------------------- bar
  --
  -- `.bar` at the top of the screen, every cell centred on y=34. Cell art is
  -- baked PNGs (no circle/rounded primitives); sizes are measured from them.
  BAR = {
    CY = 34,
    BOX_TOP = 14,
    CELL_GAP = 8, BOX_PAD = 8,
    W_DONE = 24, W_CUR = 30,
    W_GIFT = 32,

    -- The demo's two chip widths (`x >= 10 ? 90 : 82`).
    W_CHIP = 82, W_CHIP_WIDE = 90,
    CHIP_PX = 14,
    CHIP_COLOR = 0x5A3400,
    -- "còn <x> bài": split around the count so no string.format %d can raise
    -- on a float.
    CHIP_TEXT = {
      vi = { pre = "còn ", post = " bài" },
      en = { pre = "",     post = " left" },
    },

    -- The box is two PNG caps around one Sprite.solid. The old middle tile is
    -- a single colour at a single alpha, so solid + object opacity is the same
    -- picture. Sprite.solid takes RGB565, not 0xRRGGBB.
    CAP_W = 20,
    MID_565 = 0x0863,                   -- RGB565 of (9,14,30)
    MID_OPA = 107,
    NUM_GAP = 1,

    -- `.bar .duong`, drawn with Sprite.solid: the map held 7 of the 8 Line
    -- slots when this was written (5 since the six-marker rule). Square ends
    -- instead of a 2px radius.
    RAIL_Y = 32,
    RAIL_H = 4,
    RAIL_565 = 0xFFFF,
    RAIL_OPA = 77,                      -- .3 * 255
  },
}

return M
