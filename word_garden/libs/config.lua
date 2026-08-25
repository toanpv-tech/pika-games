return {
  W = 480, H = 320, HORIZON = 72,
  PLOTS = 6, PLOT_COLS = 3, MAX_LIVES = 3,
  PLOT_X = { 64, 192, 320, 64, 192, 320 },
  PLOT_Y = { 86, 86, 86, 178, 178, 178 },
  -- Plot art is 80x44, so the pot's horizontal centre is PLOT_X[i] + PLOT_W/2.
  -- The seed word under each pot is centred on that (see LABEL_DY): Text has no
  -- width query, so the centring is done by aligning "top" -- which anchors on
  -- the SCREEN centre -- and offsetting by (pot centre - screen centre).
  PLOT_W = 80,
  PLOT_H = 44,
  LABEL_DY = 48,
  FLOWER_COLS = { 0xFF9EC6, 0xFFD24A, 0xA8D8FF, 0xD8A8FF, 0xFF8A7A, 0x8AF0C0 },
  FIRST_CROW_MS = 5000,
  CLEAR_HOLD_MS = 1900,
  A2A_EXIT_HOLD_MS = 1800,
  VOICE_SENSITIVITY = 10,
  ASSET = "assets/runtime/",
  FLASH_RGB565 = 0xFFFF,
  -- Frames in garden-cycle.rgb565. MUST match the file: set_frame() reads
  -- frame*307200 bytes off the SD card, so an index past the end reads garbage.
  --
  -- Was 32. Each frame is a full 480x320 RGB565 screen = 300 KB, and set_frame
  -- is a blocking open+fseek+fread on the Lua thread WHILE IT HOLDS THE LVGL
  -- LOCK. 32 frames meant 32 such reads per round (one every ~1.9 s); under SD
  -- contention with voice teardown one of them stretched to 2.88 s and blew the
  -- 1.5 s Lua watchdog (crash log 2026-08-25, teardown_fatal on_tick).
  --
  -- 8, not a smaller even sample of the old 32: frames 0-15 of the original were
  -- visually identical (<0.4% of bytes differing), so the whole daylight half
  -- collapses to ONE frame and the remaining 7 walk the real sunset (old frames
  -- 16-31), where every step now carries 14-100% change. Same look, quarter the
  -- reads.
  BG_FRAMES = 8,

  -- TITLE prompt band ("PRESS THE STAR BUTTON / TO START PLAYING"), carved out
  -- of the old title-cycle atlas. These are the exact bounds of the pixels that
  -- differed between its two frames, so the sprite drawn at (PROMPT_X,PROMPT_Y)
  -- over title-still reproduces the old frame 0 exactly.
  PROMPT_W = 209,
  PROMPT_H = 29,
  PROMPT_X = 135,
  PROMPT_Y = 188,
  PROMPT_BLINK_MS = 500,
  -- Ground for the OVER screen, black like word_maze's blank backdrop. The five
  -- OVER lines were contrast-checked against black, so this is what makes those
  -- ratios real rather than a property of whatever art happened to be up.
  BLANK_RGB565 = 0x0000,
  COL_HUD = 0x8AF0C0,
  COL_OVER_TITLE = 0xFF5544,

  -- HUD row geometry. One baseline for every element so the worded cluster, the
  -- score and the lives cannot drift apart -- the single-row layout word_racer
  -- and word_maze both use, so the three games read as one system.
  --
  -- Field order copies them exactly: progress on the LEFT edge (there the map +
  -- clock, here the garden + sun), the player's own tally on the RIGHT (score,
  -- then the lives furthest out).
  --
  -- Widths below are measured from the font's hmtx table at HUD_PX, not
  -- estimated: Tiny TTF gives Lua no width query, so a cluster that has to sit
  -- at a fixed x must have its space reserved from real advances.
  HUD_Y     = 17,     -- top of row 1
  HUD_PAD_X = 21,     -- bezel inset; the panel crops a few px each side
  -- Row 2's top, for reference only -- nothing reads this. Both rows live in
  -- ONE Text joined with "\n", so row 2 is placed by the label's line height,
  -- not by a coordinate. Recorded here because the vertical budget below the
  -- HUD is reasoned about in these terms: HUD_Y + one 16 px line of this face
  -- (~23 px) lands here, and a second line reaches ~63, leaving 23 px to the
  -- first plot row at PLOT_Y = 86.
  HUD_ROW2_Y = 40,
  -- Lives keep their original y while the text rows sit 10 px lower, so they
  -- need their own constant -- they used to read HUD_Y and would have followed
  -- it down. This leaves them slightly above the text baseline, which is
  -- deliberate: it is the position they already had.
  HUD_LIFE_Y = 7,
  -- Screen centre, the x that "VƯỜN n" is centred ON. Row 1 is a single Text
  -- and a Text has one alignment, so the centring is done with padding spaces
  -- measured from the left cluster -- see hud_row1() in main.lua.
  HUD_MID_X = 240,
  -- One space advance at HUD_PX, from the font's hmtx (4.16 px at 16 px). Pads
  -- are quantised to whole spaces, so a centred cluster lands within half a
  -- space of its target -- measured worst case 1.7 px, which the eye reads as
  -- centred.
  HUD_SPACE_ADV = 4.16,
  HUD_LIFE_STEP = 20, -- life pitch; 12 px art + 8 px air
  HUD_LIFE_SHIFT = 8, -- extra left nudge for the whole life row, off the right bezel
  -- Sun bar: sits inline with row 1, immediately after the NẮNG:/SUN: label,
  -- vertically centred on that text line ((23-8)/2 = 7 below HUD_Y).
  --
  -- 100 px wide, not the original 140. The bar has to fit between the label
  -- (ends at x=71.5 in vi) and the centred VƯỜN cluster (starts at x=195.2 in
  -- the worst case, en "GARDEN 24"), which leaves 109 px. The asset was
  -- regenerated at 100x8 from the same rule the shipped 140x8 file follows --
  -- fill = round(frame/32 * W), flat colour, no gradient -- and the generator
  -- was checked by reproducing the original 140 px file byte-for-byte first.
  HUD_BAR_X = 78,
  HUD_BAR_Y = 24,     -- tracks HUD_Y: (23-8)/2 = 7 below the row-1 text top
  HUD_BAR_W = 100,
  -- Opacity of a life already spent. word_racer keeps the icon VISIBLE and dims
  -- it instead of hiding it, so the row never reflows and the child reads
  -- "2 of 3", not just "2".
  HUD_SPENT_OPA = 45,
}
