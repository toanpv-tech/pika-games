-- libs/config — every tunable for Word Maze in one table
-- Resolve: require("libs/config")
--
-- Numbers marked "HTML" are carried unchanged from input/word_maze.html, which is
-- the source of truth for behaviour. Numbers marked "port" exist only on this
-- target and carry the reason inline.

local C = {}

-- ---------------------------------------------------------------------------
-- Frame pacing
-- ---------------------------------------------------------------------------
C.LOGIC_DT_MS = 1000.0 / 30.0  -- fixed logic step (~33.3 ms / 30 Hz)
C.DT_MAX_MS   = 100            -- clamp dt after a stall; HTML does the same (tick(): dt>100 -> 100)
C.MAX_STEPS   = 3              -- catch-up cap so one late frame cannot double the next

-- ---------------------------------------------------------------------------
-- Screen layout (480x320)
-- ---------------------------------------------------------------------------
C.SCREEN_W = 480
C.SCREEN_H = 320
-- 26, not the HTML's 42: the HUD is a SINGLE row of icon+number pairs now
-- (word_racer's layout), so it no longer needs two text lines. The old 42 px was
-- also a lie at the current font size -- two 16 px lines of a diacritic-bearing
-- face measure ~44 px, which overran the rule at HUD_H-2 and clipped the
-- descenders of the second line.
-- 32, not 26: the row content sits 5 px lower (HUD_Y/HUD_TEXT_DY below) and the
-- band had only 1 px of slack left -- the 20 px hearts already ran to y=25 of a
-- 26 px band. Shifting the content alone would have pushed them through the
-- separator rule at HUD_H-2 and 4 px into the maze, so the band grows with it.
-- The +6 (not +5) is the hearts: they are the tallest thing on the row and now
-- end exactly on the rule's top edge at y=30, the tightest the band can be
-- without the art crossing the line. PLAY_H drops to 254, which the 240 px maze
-- still clears (7 px air above and below); rule and maze both follow HUD_H.
C.HUD_H    = 32
C.PANEL_H  = 34                -- HTML sentence panel: fillRect(0,286,W,34)
C.PANEL_Y  = 286               -- HTML
C.PLAY_H   = C.SCREEN_H - C.HUD_H - C.PANEL_H  -- 260 px usable for the maze

-- HUD row geometry. One baseline for every element so icons and numbers cannot
-- drift apart, mirroring word_racer's single y for hud_planet/hud_star/hearts.
--
-- Field order copies word_racer exactly: progress on the LEFT edge (there the
-- planet + stage, here the map + clock), the player's own tally on the RIGHT
-- (star + score, then the hearts furthest out). Two games, one place to look
-- for the same kind of number.
C.HUD_Y      = 10              -- top of the icon row (was 5; whole row sits 5 px lower)
-- Bezel inset, applied at BOTH ends: the map/clock text starts this far in from
-- the left, the hearts end this far in from the right, so the row sits centred
-- between two equal margins. The robot's frame crops a few px each side that the
-- flat 480x320 render cannot see.
C.HUD_PAD_X  = 25
C.HUD_HEART_STEP = 22          -- heart pitch; 20 px art + 2 px air

-- Vertical room reserved between HUD and maze. Zero: the command rail that used
-- to live here is gone, and the 46 px it held went to the maze's fourth row.
--
-- The rail showed the vocabulary word with a direction arrow under it, in a band
-- the child had to look UP to read and that blanked out entirely mid-move
-- (render_chips hid it while S.gliding). Both jobs moved closer to where the eye
-- already is: the arrow onto the destination tile inside the maze, the word into
-- the sentence panel that was already carrying the rule hint.
--
-- Kept as a named constant rather than deleted so layout_maze() still documents
-- the band it centres in, and so restoring a rail is a one-line change.
C.CHIP_ROW_H = 0
-- Opacity of a life already spent. word_racer keeps the heart VISIBLE and dims
-- it (set_opacity(45)) instead of hiding it, so the row never reflows and the
-- child reads "2 of 3", not just "2".
C.HUD_SPENT_OPA = 45

-- Native robot-sized art: 60 px tiles and 44 px actors. Large HTML maps are
-- viewed through a 5x4 camera rather than scaling assets at runtime (unsupported).
-- See VIEW_COLS/VIEW_ROWS below for the camera itself.
C.CELL      = 60
C.ACTOR     = 44               -- actor art box; (CELL-ACTOR)/2 = 8 px margin
C.ACTOR_OFF = (C.CELL - C.ACTOR) // 2

-- ---------------------------------------------------------------------------
-- Wall-mask bits. MUST match the tile atlas frame order produced by the asset
-- pipeline: frame index = mask + (crumb and 16 or 0).
-- ---------------------------------------------------------------------------
C.WALL_T, C.WALL_R, C.WALL_B, C.WALL_L = 1, 2, 4, 8
C.TILE_CRUMB_BASE = 16         -- +16 selects the crumb-bearing variant of a mask

-- Direction table. Index order is HTML's DIRS (up, right, down, left) so that
-- "first open direction" iteration order matches the demo exactly.
C.DIR_UP, C.DIR_RIGHT, C.DIR_DOWN, C.DIR_LEFT = 1, 2, 3, 4
C.DIRS = {
  { dx =  0, dy = -1, bit = C.WALL_T, name = "up" },
  { dx =  1, dy =  0, bit = C.WALL_R, name = "right" },
  { dx =  0, dy =  1, bit = C.WALL_B, name = "down" },
  { dx = -1, dy =  0, bit = C.WALL_L, name = "left" },
}
C.OPP = { C.DIR_DOWN, C.DIR_LEFT, C.DIR_UP, C.DIR_RIGHT }

-- ---------------------------------------------------------------------------
-- Gameplay constants (HTML)
-- ---------------------------------------------------------------------------
C.MAX_LIVES    = 3             -- HTML MAX_LIVES
C.IFRAME_MS    = 1200          -- HTML IFRAME_MS
C.GLIDE_SPEED  = 7.5           -- HTML GLIDE_SPEED, cells/second
C.INTRO_MS     = 2000          -- HTML introUntil = now()+2000
C.CLEAR_MS     = 1800          -- HTML clearUntil = now()+1800
C.MATCH_LOCK_MS = 700          -- HTML matchLockUntil = now()+700
C.CRUMB_CHANCE = 40            -- HTML: Math.random()<0.4 on non-dead-end cells
C.TICK_THRESHOLD_S = 10        -- HTML: timeLeft<=10 -> tick sfx + red clock

-- Score formulas (HTML): step 5*level*combo, crumb 5*combo, kill 40*level*combo,
-- gate (50*level + 2*ceil(timeLeft)) * combo.
C.PTS_STEP      = 5
C.PTS_CRUMB     = 5
C.PTS_KILL      = 40
C.PTS_GATE      = 50
C.PTS_GATE_TIME = 2
C.COMBO_MAX     = 3            -- HTML comboMult: min(3, 1+floor(streak/4))
C.COMBO_EVERY   = 4

-- Monster pacing (HTML): monsterStepMs = max(620, 1050 - (level-1)*55)
C.MON_STEP_BASE = 1050
C.MON_STEP_DEC  = 55
C.MON_STEP_MIN  = 620
C.MON_PLACE_ATTEMPTS = 160     -- HTML placeMonsters attempt cap

-- Time budget (HTML): timeMax = round(16 + COLS*ROWS*timeK)
C.TIME_BASE = 16

-- ---------------------------------------------------------------------------
-- Pools. Fixed size, allocated once in game_start (worst case across all maps).
-- ---------------------------------------------------------------------------
C.MAX_COLS  = 13               -- HTML level 10
C.MAX_ROWS  = 7                -- HTML level 8-10
C.MAX_CELLS = 91               -- logical cells; rendering uses a smaller viewport
C.MAX_MONSTERS = 7             -- HTML endless cap: 6 patrol + 1 chaser
C.MAX_CHIPS = 4                -- a 4-way junction occurs (measured 0.4% of cells)
C.VIEW_COLS = 5                -- 5*60 = 300 px, fits the 480 px robot display
-- 4*60 = 240 px. Fits only because the command rail gave up its 46 px band
-- (CHIP_ROW_H): 26 HUD + 240 maze + 34 panel = 300, leaving 20 px of air.
-- Was 3 while the rail existed, which cropped a row off every map from level 2
-- on -- the whole ladder, since level 1 is the only 3-row map.
C.VIEW_ROWS = 4
C.VIEW_CELLS = C.VIEW_COLS * C.VIEW_ROWS

-- ---------------------------------------------------------------------------
-- Voice / input
-- ---------------------------------------------------------------------------
C.VOICE_SENSITIVITY = 10
C.FIGHT_KEYWORD     = "fight"
-- Re-prompt the current target after this much silence with no progress. Q4:
-- replaces the demo's near-miss hint, which needed an STT transcript the
-- keyword-spotting backend does not provide.
C.NO_MATCH_MS = 6000

-- ---------------------------------------------------------------------------
-- Presentation
-- ---------------------------------------------------------------------------
C.MSG_MS         = 1100        -- default centre-message dwell
C.COL_HUD        = 0x00FC00
C.COL_WARN       = 0xFF5544
C.COL_CHIP       = 0xFFE600
C.COL_CHIP_FIGHT = 0xFF9DB0
C.COL_PANEL      = 0xFFE600
C.COL_HINT       = 0x8A97A6

-- ---------------------------------------------------------------------------
-- Asset paths
-- ---------------------------------------------------------------------------
C.TILE_ATLAS = "assets/runtime/tiles-60.rgb565"
-- One mouse face only: direction is a set_flip flag and the invincible blink is
-- set_opacity, so the per-direction PNGs would only add decode cost.
C.SPR_MOUSE = {
  right = "assets/runtime/mouse-right.png",
}
C.SPR_MONSTER = {
  patrol = "assets/runtime/monster-patrol.png",
  lunge  = "assets/runtime/monster-lunge.png",
  chaser = "assets/runtime/monster-chaser.png",
  fight  = "assets/runtime/monster-fight.png",
}
C.SPR_KEY          = "assets/runtime/key.png"
C.SPR_CHEESE_LOCK  = "assets/runtime/cheese-locked.png"
C.SPR_CHEESE_OPEN  = "assets/runtime/cheese-open.png"

-- HUD icons. An icon needs no translation, which matters with bilingual chrome,
-- but it only works where the thing HAS a picture the child already knows:
--   hud-heart  <- word_racer's own HUD set, copied unchanged so the two games
--                 read as one system
--   hud-crumb  <- extracted from tiles-60.rgb565, where a crumb tile is the
--                 wall mask + TILE_CRUMB_BASE. It is literally the same 9x9
--                 mark the child picks up off the maze floor, at native size:
--                 scaled 2x it turned into a gold slab and stopped matching.
--                 It NAMES THE SCORE -- crumbs are what earn points, so the
--                 mark labels the tally instead of counting crumbs separately.
-- The map/clock fields keep WORDS: there is no picture for either, and two
-- anonymous numbers side by side cannot be told apart.
C.SPR_HUD_HEART    = "assets/runtime/hud-heart.png"
C.SPR_HUD_CRUMB    = "assets/runtime/hud-crumb.png"
-- hud-star <- word_racer's, copied unchanged (18x18). The OVER footer shows it
-- between "NHẤN" and "ĐỂ CHƠI LẠI" instead of naming the button in words: it is
-- the same star moulded on the ENTER key the child actually presses, and the
-- title atlas already prompts with it.
C.SPR_HUD_STAR     = "assets/runtime/hud-star.png"
-- Title is a 2-frame RGB565 atlas, not a PNG: frame 0 carries the "press the
-- star button" prompt, frame 1 blanks that band alone. Blinking the prompt is
-- what tells a child the screen is waiting for input rather than stuck, and
-- baking both states into one atlas keeps the logo pixel-identical across the
-- blink -- an opacity pulse on a single PNG would flash the logo too.
C.SCREEN_TITLE     = "assets/runtime/title-cycle.rgb565"
C.TITLE_FRAMES     = 2
C.TITLE_BLINK_MS   = 500            -- matches word_garden's title cadence
C.SCREEN_INTRO     = "#blank"       -- dynamic scene; never bake level data into art
C.SCREEN_OVER      = "#blank"       -- dynamic score/ranking, unlike the sample PNG

-- Staged tile upload: one set_frame is a validated open + fseek + fread of
-- CELL*CELL*2 bytes. 3 per frame keeps map entry near a third of the budget and
-- finishes in ~8 frames, well inside the 2000 ms intro card.
C.TILES_PER_FRAME = 3

return C
