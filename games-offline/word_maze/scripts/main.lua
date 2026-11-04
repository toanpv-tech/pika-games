-- Word Maze - Cheese Quest (Pika Engine port of input/word_maze.html)
--
-- Speak the word on a signpost to move the mouse; grab crumbs and the key, say
-- "fight" then a sentence to beat a monster, and open the cheese cage.
--
-- Structure: this file is the wiring layer only. It owns sprites, Text, audio,
-- LED and servo, and translates engine hooks into libs/rules calls. All gameplay
-- lives in libs/rules.lua, which touches no engine API and is smoke-tested
-- headless (see the S4 report).
--
-- Budget held by this file (against the documented 32-sprite / 8-Text ceilings):
--   gameplay 15 tiles + mouse + 7 monsters + key + cage
--            + 3 HUD hearts + 1 HUD crumb + 2 chrome (panel_bg, hud_rule)
--            + 1 hidden blank backdrop                            = 32/32
--   scenes   15 tiles + mouse + 7 monsters + key + cage + backdrop = 26/32
--   Text     2 HUD + 4 chips + panel                              =  7/8
--   Anim     none
-- The HUD icons are paid for exactly: the 4 per-chip background plates that
-- used to sit in ensure_chrome were dropped for them. Chip text lost nothing
-- measurable -- COL_CHIP over the plate was 15.8:1, over the bare tile art it
-- is 15.5:1 -- so the plates were 4 sprites buying 0.3:1 of contrast.
-- The blank backdrop is resident (created once, toggled) because a 480x320
-- Sprite.solid is a 300 KB PSRAM allocation: recreating it per map entry spiked
-- the frame and fragmented the arena.
-- The complete 13x7 logical maze is rendered through a 5x4 camera. The native
-- 60x60 tile and 44x44 actor art fits the 480x320 panel without runtime scaling.
--
-- Engine hooks used: game_start / on_tick / on_input / on_voice_event /
-- on_home / game_end.
--
-- Input: VOICE ONLY during play. on_input serves TITLE and OVER alone (`confirm`
-- = start / play again), the two beats that are not a language target. There is
-- deliberately no button fallback inside the maze, so a dead voice channel is a
-- dead end -- the panel says so rather than offering a control that no longer
-- exists (see render_panel).
--
-- Language: params.language picks vi/en for the CHROME only. The curriculum
-- stays English -- its words and sentences are what the child speaks and what
-- Voice.set_keywords matches on. See libs/i18n.lua.

local CFG = require("libs/config")
local Levels = require("libs/levels")
local Curriculum = require("libs/curriculum")
local Rules = require("libs/rules")
local GameOverUI = require("libs/gameover_ui")
local I18n = require("libs/i18n")

local floor, min, max, ceil = math.floor, math.min, math.max, math.ceil

local S            -- game state (libs/rules)
local view = {}    -- everything engine-owned

-- Ranking.get_result() round-trip budget: back does POST /games/result then
-- GET /games/rank server-side before the rank IPC lands (see ranking_bridge.cpp).
-- If it never lands (offline, BE error) stop polling and keep the placeholder
-- rank instead of calling get_result() forever on the OVER screen.
local RANK_POLL_TIMEOUT_MS = 6000

----------------------------------------------------------------------
-- Engine wrappers: every call guarded, every failure logged with its path
----------------------------------------------------------------------
local function sprite_image(path)
  if not (Sprite and Sprite.image) then return nil end
  local spr = Sprite.image(path)
  if not spr then
    print("word_maze: sprite load failed " .. path)
    return nil
  end
  return spr
end

local function sprite_raw(path, w, h)
  if not (Sprite and Sprite.new) then return nil end
  local spr = Sprite.new(path, w, h)
  if not spr then
    print("word_maze: raw sprite load failed " .. path)
    return nil
  end
  return spr
end

local function text_new(str, x, y)
  if not (Text and Text.new) then return nil end
  local t, err = Text.new(str, x, y)
  if not t then
    print("word_maze: Text.new failed " .. tostring(err))
    return nil
  end
  return t
end

local function sfx(alias)
  if Speaker and Speaker.play then Speaker.play(alias) end
end

-- LED mirrors voice state, following the proven design used by word_racer_02:
-- solid blue while listening, solid red on error, and two white blinks when a
-- keyword arrives. The flash sequence then restores the current base color.
local LED = {
  BLUE = { 0, 0, 255 },
  RED = { 255, 0, 0 },
  WHITE = { 255, 255, 255 },
  FLASH_ON_MS = 120,
  FLASH_OFF_MS = 100,
  FLASH_BLINKS = 2,
}
local led_base = nil
local led_flash = nil
local led_flash_i = 0
local led_flash_deadline = 0
local LED_FLASH_SEQ = {}
for _ = 1, LED.FLASH_BLINKS do
  LED_FLASH_SEQ[#LED_FLASH_SEQ + 1] = { ms = LED.FLASH_ON_MS, rgb = LED.WHITE }
  LED_FLASH_SEQ[#LED_FLASH_SEQ + 1] = { ms = LED.FLASH_OFF_MS, rgb = nil }
end

-- Led.* is a MUTATOR-TOLERANT binding: bad args return false, it never raises.
-- So pcall bought nothing here and cost a protected-call frame on the 120 ms
-- flash path.
local function led_rgb(rgb)
  if rgb and Led and Led.set then Led.set(rgb[1], rgb[2], rgb[3]) end
end
local function led_off()
  if Led and Led.off then Led.off() end
end
local function led_apply_base()
  if led_base then led_rgb(led_base) else led_off() end
end
local function led_set_base(rgb)
  led_base = rgb
  if not led_flash then led_apply_base() end
end
local function led_start_flash()
  if not (Led and Led.set) then return end
  led_flash = LED_FLASH_SEQ
  led_flash_i = 0
  led_flash_deadline = 0
end
local function led_stop()
  led_flash = nil
  led_flash_i = 0
  led_flash_deadline = 0
  led_base = nil
  led_off()
end
local function led_tick(t)
  if not led_flash or t < led_flash_deadline then return end
  led_flash_i = led_flash_i + 1
  local step = led_flash[led_flash_i]
  if not step then
    led_flash = nil
    led_apply_base()
    return
  end
  if step.rgb then led_rgb(step.rgb) else led_off() end
  led_flash_deadline = t + step.ms
end

local function pose(name)
  if Servo and Servo.pose then Servo.pose(name) end
end

----------------------------------------------------------------------
-- Cache-and-compare helpers. A render call takes an LVGL lock shared with the
-- LVGL timer task, so the cheapest call is the one we skip.
----------------------------------------------------------------------
local function place(rec, x, y)
  if rec.spr and (x ~= rec.x or y ~= rec.y) then
    rec.x, rec.y = x, y
    rec.spr:set_pos(x, y)
  end
end

local function show(rec, vis)
  if rec.spr and vis ~= rec.vis then
    rec.vis = vis
    rec.spr:set_visible(vis)
  end
end

local function flip(rec, fh)
  if rec.spr and rec.flip_h ~= fh then
    rec.flip_h = fh
    rec.spr:set_flip(fh, false)
  end
end

-- Returns true when it actually recreated the sprite, so the caller knows to
-- restack it (see call sites): the new sprite is appended after every
-- existing child (tiles, HUD text, other actors) and starts on top
-- regardless of its intended layer -- set_art() cannot assume a fixed layer
-- since it is shared by records in different layers (actors vs. cage).
local function set_art(rec, path)
  if not rec.spr or rec.art == path then return false end
  -- Actor art carries alpha, so it must come from PNG; set_frame only works on
  -- opaque raw sprites. Swapping means destroy + recreate, which is why this is
  -- gated on an actual state change (direction/telegraph), never per frame.
  rec.spr:destroy()
  rec.spr = sprite_image(path)
  rec.art = path
  rec.x, rec.y, rec.vis, rec.flip_h = nil, nil, nil, nil
  if rec.spr then rec.spr:set_visible(false) end
  -- Not a bare `true`: the contract is "recreated, go restack it", which only
  -- holds when there is a sprite to restack. A failed decode (internal heap
  -- exhausted) would otherwise hand the caller nil to index, losing the whole
  -- frame's render -- HUD, chips and panel included.
  return rec.spr ~= nil
end

local function text_set(rec, str)
  if rec.t and rec.s ~= str then
    rec.s = str
    rec.t:set(str)
  end
end

local function text_show(rec, vis)
  if rec.t and rec.vis ~= vis then
    rec.vis = vis
    rec.t:show(vis)
  end
end

local function text_move(rec, x, y)
  if rec.t and (rec.x ~= x or rec.y ~= y) then
    rec.x, rec.y = x, y
    rec.align, rec.adx, rec.ady = nil, nil, nil
    rec.t:move(x, y)
  end
end

local function text_color(rec, col)
  if rec.t and rec.col ~= col then
    rec.col = col
    rec.t:set_color(col)
  end
end

-- vi-bold, not vi-regular: bold holds its diacritics at these sizes over the
-- detailed tile art, and word_racer already proved this face on the panel
-- ("base glyph metrics identical between e/ê and o/ô in LVGL Tiny TTF").
--
-- This copy is NOT byte-identical to word_racer's any more: four arrow outlines
-- were added at U+2190..U+2193 for the chip direction markers (see CHIP_ARROW),
-- taking it from 469 to 473 glyphs and 36300 to 36626 bytes. The original 469
-- were verified unchanged byte-for-byte, so anything word_racer renders with
-- this face still renders identically here.
--
-- Three sizes = three (path,size) faces out of GAME_FONT_SLOTS (4), leaving one
-- slot spare. The cache keys on the PAIR, so every extra size is another face,
-- another ~36 KB resident buffer, and another slot -- adding a fourth would run
-- the game to the edge word_racer is already sitting on.
local FONT_VI = "fonts/vi-bold.ttf"

-- Panel carries the longest strings (a full sentence prompt) and is the one the
-- child reads under time pressure, so it gets the largest face. Chips sit at
-- CHIP_PX; anything below ~14 loses the two-tier Vietnamese marks (ể, ứ).
local HUD_PX   = 16
local CHIP_PX  = 14
local PANEL_PX = 18
-- Fourth and last face: the OVER screen's score, the one number the child
-- actually remembers, at a size nothing else on any screen reaches. Keep the
-- count at four: GAME_FONT_SLOTS is 4, and a fifth size would make
-- font_acquire_slot log "font cache full" and silently leave a label at whatever
-- face it had.
local OVER_SCORE_PX = 26

local function set_font(rec, size)
  if not rec.t then return end
  local ok, err = rec.t:set_font(FONT_VI, size)
  if ok == nil and err then
    print("word_maze: set_font failed " .. tostring(err))
  end
end

----------------------------------------------------------------------
-- Layout: the maze is centred in the band between HUD and sentence panel.
----------------------------------------------------------------------
-- The maze is centred in what is left of the play band AFTER the command rail,
-- not in the whole band. The rail grew a second line for the direction arrows,
-- and centring on the full PLAY_H would have slid the maze up under it.
local function layout_maze()
  view.view_cols = min(CFG.VIEW_COLS, S.cols)
  view.view_rows = min(CFG.VIEW_ROWS, S.rows)
  local band_y = CFG.HUD_H + CFG.CHIP_ROW_H
  local band_h = CFG.PLAY_H - CFG.CHIP_ROW_H
  view.ox = floor((CFG.SCREEN_W - view.view_cols * CFG.CELL) / 2)
  view.oy = band_y + floor((band_h - view.view_rows * CFG.CELL) / 2)
end

local function text_align(rec, where, dx, dy)
  if rec.t and (rec.align ~= where or rec.adx ~= dx or rec.ady ~= dy) then
    rec.align, rec.adx, rec.ady = where, dx, dy
    rec.t:align(where, dx, dy)
    rec.x, rec.y = nil, nil
  end
end

local function cell_px(cx, cy)
  return view.ox + (cx - view.cam_x) * CFG.CELL,
         view.oy + (cy - view.cam_y) * CFG.CELL
end

local function in_view(cx, cy)
  return cx >= view.cam_x and cx < view.cam_x + view.view_cols
     and cy >= view.cam_y and cy < view.cam_y + view.view_rows
end

----------------------------------------------------------------------
-- Sprite pools. Created once in game_start, destroyed once in game_end.
----------------------------------------------------------------------
local function build_pools()
  view.tiles = {}
  for i = 1, CFG.VIEW_CELLS do
    local spr = sprite_raw(CFG.TILE_ATLAS, CFG.CELL, CFG.CELL)
    view.tiles[i] = { spr = spr, frame = -1, x = nil, y = nil, vis = nil }
    if spr then spr:set_visible(false) end
  end

  view.mouse = { spr = sprite_image(CFG.SPR_MOUSE.right), art = CFG.SPR_MOUSE.right }
  if view.mouse.spr then view.mouse.spr:set_visible(false) end

  view.mon = {}
  for i = 1, CFG.MAX_MONSTERS do
    local spr = sprite_image(CFG.SPR_MONSTER.patrol)
    view.mon[i] = { spr = spr, art = CFG.SPR_MONSTER.patrol }
    if spr then spr:set_visible(false) end
  end

  view.key = { spr = sprite_image(CFG.SPR_KEY), art = CFG.SPR_KEY }
  if view.key.spr then view.key.spr:set_visible(false) end

  view.cage = { spr = sprite_image(CFG.SPR_CHEESE_LOCK), art = CFG.SPR_CHEESE_LOCK }
  if view.cage.spr then view.cage.spr:set_visible(false) end

  -- set_z()/move_to_index() places a sprite at that index in the parent's
  -- CURRENT child list -- it is not a durable layer, so setting z while more
  -- sprites are still being created shifts everything created afterwards.
  -- Assign the final stacking order once, here, after every actor above
  -- exists: tiles at the bottom, then key/cage, then mouse/monsters on top.
  for i = 1, CFG.VIEW_CELLS do if view.tiles[i].spr then view.tiles[i].spr:to_front() end end
  if view.key.spr then view.key.spr:to_front() end
  if view.cage.spr then view.cage.spr:to_front() end
  if view.mouse.spr then view.mouse.spr:to_front() end
  for i = 1, CFG.MAX_MONSTERS do if view.mon[i].spr then view.mon[i].spr:to_front() end end

  view.screen = { spr = nil, art = nil, x = nil, y = nil, vis = nil }

  -- Created before the Text pool so the labels, which LVGL appends after it on the
  -- same parent, draw in front of the backdrop.
  --
  -- Stacking against the MAZE is now load-bearing, where it used to be incidental:
  -- choice labels sit on the maze cells themselves, over tiles and sometimes over
  -- the mouse or a monster. Text has no set_z/to_front binding -- creation order
  -- is the only lever -- so every sprite that a label may overlap must exist, and
  -- have taken its to_front() above, BEFORE the first text_new() below.
  view.blank = { spr = nil, x = 0, y = 0, vis = nil }
  if Sprite and Sprite.solid then
    local spr = Sprite.solid(CFG.SCREEN_W, CFG.SCREEN_H, 0x0000)
    if spr then
      spr:set_pos(0, 0)
      spr:set_visible(false)
      view.blank.spr = spr
      view.blank.vis = false
    else
      print("word_maze: blank backdrop alloc failed")
    end
  end

  -- HUD icons, created here so they land after the tiles and before the Text
  -- pool (LVGL draws in creation order on a shared parent). Paid for by the
  -- chrome this row replaced -- see the budget note in the file header.
  view.hud_heart = {}
  for i = 1, CFG.MAX_LIVES do
    local spr = sprite_image(CFG.SPR_HUD_HEART)
    view.hud_heart[i] = { spr = spr, art = CFG.SPR_HUD_HEART }
    if spr then spr:set_visible(false) end
  end
  -- The crumb mark labels the SCORE: it is the thing the child picks up off the
  -- maze floor to earn points, so it names the tally the way the hearts name
  -- lives. It is not a separate crumb counter -- one icon, one number, and the
  -- number is the score.
  view.hud_crumb = { spr = sprite_image(CFG.SPR_HUD_CRUMB), art = CFG.SPR_HUD_CRUMB }
  if view.hud_crumb.spr then view.hud_crumb.spr:set_visible(false) end

  -- OVER footer only: the ENTER button drawn between the two halves of
  -- "NHẤN [*] ĐỂ CHƠI LẠI". Hidden on every other scene.
  view.hud_star = { spr = sprite_image(CFG.SPR_HUD_STAR), art = CFG.SPR_HUD_STAR }
  if view.hud_star.spr then view.hud_star.spr:set_visible(false) end

  -- Two HUD labels: `hud` is the worded map/clock cluster at the left edge,
  -- `hud_right` the score sitting just right of the crumb icon that names it.
  view.hud = { t = text_new("", 6, 7) }
  view.hud_right = { t = text_new("", 378, 7) }
  view.chip = {}
  view.chip_label = {}
  view.chip_dx = {}
  for i = 1, CFG.MAX_CHIPS do
    view.chip[i] = { t = text_new("", 0, 0) }
    view.chip_label[i] = ""
    view.chip_dx[i] = 5
    text_show(view.chip[i], false)
  end
  view.panel = { t = text_new("", 8, CFG.PANEL_Y + 8) }
  -- set_font is a mutator: it returns (nil, msg) on failure and never raises, so
  -- the return is logged rather than guarded.
  local hud_texts = { view.hud, view.hud_right }
  for i = 1, #hud_texts do
    set_font(hud_texts[i], HUD_PX)
  end
  for i = 1, CFG.MAX_CHIPS do
    set_font(view.chip[i], CHIP_PX)
  end
  if view.panel.t then
    view.panel.t:set_color(CFG.COL_PANEL)
    -- Vietnamese-capable face: view.panel doubles as the rank line on
    -- SCENE_OVER, and the engine default (Montserrat) has no diacritic
    -- glyphs for a display_name with dấu.
    set_font(view.panel, PANEL_PX)
  end
  text_show(view.panel, false)
end

local function destroy_pools()
  if view.tiles then
    for i = 1, #view.tiles do
      local r = view.tiles[i]
      if r.spr then r.spr:destroy() end
    end
  end
  local recs = { view.mouse, view.key, view.cage, view.screen, view.blank }
  for i = 1, #recs do
    local r = recs[i]
    if r and r.spr then r.spr:destroy() end
  end
  if view.mon then
    for i = 1, #view.mon do
      if view.mon[i].spr then view.mon[i].spr:destroy() end
    end
  end
  local texts = { view.hud, view.hud_right, view.panel }
  for i = 1, #texts do
    if texts[i] and texts[i].t then texts[i].t:destroy() end
  end
  if view.chip then
    for i = 1, #view.chip do
      if view.chip[i].t then view.chip[i].t:destroy() end
    end
  end
  if view.hud_heart then
    for i = 1, #view.hud_heart do
      if view.hud_heart[i].spr then view.hud_heart[i].spr:destroy() end
    end
  end
  if view.hud_crumb and view.hud_crumb.spr then view.hud_crumb.spr:destroy() end
  if view.hud_star and view.hud_star.spr then view.hud_star.spr:destroy() end
  view.tiles, view.mon, view.chip = nil, nil, nil
  view.mouse, view.key, view.cage = nil, nil, nil
  view.screen, view.blank = nil, nil
  view.hud, view.hud_right, view.panel = nil, nil, nil
  view.hud_heart, view.hud_crumb, view.hud_star = nil, nil, nil
end

local function destroy_chrome()
  if view.panel_bg then view.panel_bg:destroy(); view.panel_bg = nil end
  if view.hud_rule then view.hud_rule:destroy(); view.hud_rule = nil end
end

-- The 4 per-chip background plates this used to allocate are gone, and their
-- slots pay for the HUD icons (3 hearts + star). Measured, not assumed: chip
-- text sits over the near-black tile art (8,12,16) or the blank backdrop, and
-- COL_CHIP on either is 15.5:1 -- against 15.8:1 over the old plate. The plate
-- was buying 0.3:1 of contrast for 4 of the 32 sprites. word_racer's lane words
-- carry no plate either and read fine; selection there is shown by COLOR, which
-- is what render_chips does for a monster chip.
local function ensure_chrome()
  if not (Sprite and Sprite.solid) then return end
  if not view.panel_bg then
    view.panel_bg = Sprite.solid(CFG.SCREEN_W, CFG.PANEL_H, 0x0841)
    if view.panel_bg then
      view.panel_bg:set_pos(0, CFG.PANEL_Y)
      view.panel_bg:set_z(3)
    end
  end
  if not view.hud_rule then
    view.hud_rule = Sprite.solid(CFG.SCREEN_W, 2, 0x258D)
    if view.hud_rule then
      view.hud_rule:set_pos(0, CFG.HUD_H - 2)
      view.hud_rule:set_z(3)
    end
  end
end

----------------------------------------------------------------------
-- Full-screen scene art.
--
-- The blank backdrop behind INTRO and OVER is built once in game_start and only
-- toggled afterwards: a 480x320 Sprite.solid is a 300 KB PSRAM allocation, and
-- destroying/recreating it on every map entry both spiked the frame and churned
-- the arena's largest free block. Only the PNG-backed title screen is transient.
----------------------------------------------------------------------
local function set_screen(path)
  local rec = view.screen
  if path == "#blank" then
    if view.blank.vis ~= true then
      if rec.spr then                -- a scene sprite was up: drop it first
        rec.spr:destroy()
        rec.spr, rec.art = nil, nil
        rec.x, rec.y, rec.vis = nil, nil, nil
        rec.frame = nil
      end
      destroy_chrome()
      show(view.blank, true)
    end
    return
  end

  show(view.blank, false)
  if rec.art == path then
    show(rec, path ~= nil)
    return
  end
  if rec.spr then
    rec.spr:destroy()
    rec.spr = nil
    rec.x, rec.y, rec.vis = nil, nil, nil
    rec.frame = nil
  end
  rec.art = path
  if path then
    destroy_chrome()
    -- The title is a raw multi-frame atlas (Sprite.new + set_frame); any other
    -- scene art stays a decoded PNG.
    if path == CFG.SCREEN_TITLE then
      rec.spr = sprite_raw(path, CFG.SCREEN_W, CFG.SCREEN_H)
      rec.frame = nil              -- force the first title_tick to upload frame 0
    else
      rec.spr = sprite_image(path)
    end
    if rec.spr then
      rec.spr:set_z(5)             -- above the maze; scene art covers everything
      rec.spr:set_pos(0, 0)
      rec.x, rec.y = 0, 0
      rec.vis = true
    end
  end
end

----------------------------------------------------------------------
-- Staged tile upload. set_frame is a validated open + fseek + fread, far too
-- expensive to run 24 times in one frame, so it is spread over several frames
-- behind the intro card.
----------------------------------------------------------------------
local function begin_tile_upload()
  layout_maze()
  view.cam_x, view.cam_y = 1, 1
  view.maze_visible = false
  view.upload_i = 1
end

local function tile_frame_for(logical_i)
  local frame = S.maze.walls[logical_i]
  if S.crumb[logical_i] then frame = frame + CFG.TILE_CRUMB_BASE end
  return frame
end

local function tile_cell(slot)
  local lx = ((slot - 1) % CFG.VIEW_COLS)
  local ly = ((slot - 1) // CFG.VIEW_COLS)
  return view.cam_x + lx, view.cam_y + ly
end

local function pump_tile_upload()
  local i = view.upload_i
  if not i then return end
  local last = min(i + CFG.TILES_PER_FRAME - 1, CFG.VIEW_CELLS)
  for k = i, last do
    local rec = view.tiles[k]
    if rec and rec.spr then
      local cx, cy = tile_cell(k)
      if cx <= S.cols and cy <= S.rows and
         cx < view.cam_x + view.view_cols and cy < view.cam_y + view.view_rows then
        local logical_i = (cy - 1) * S.cols + cx
        local frame = tile_frame_for(logical_i)
        if rec.frame ~= frame then
          rec.frame = frame
          rec.spr:set_frame(CFG.TILE_ATLAS, frame)
        end
        rec.logical_i = logical_i
        local px, py = cell_px(cx, cy)
        place(rec, px, py)
        show(rec, view.maze_visible == true)
      else
        rec.logical_i = nil
        show(rec, false)
      end
    end
  end
  if last >= CFG.VIEW_CELLS then
    view.upload_i = nil
  else
    view.upload_i = last + 1
  end
end

local tile_visibility

local function reveal_tiles(cx, cy)
  view.maze_visible = true
  for k = 1, CFG.VIEW_CELLS do
    local rec = view.tiles[k]
    if rec and rec.logical_i then show(rec, true) end
  end
  if S.fog_on then tile_visibility(cx, cy) end
end

-- A crumb was eaten (or the map changed): repaint that one tile.
local function refresh_tile(i)
  for k = 1, CFG.VIEW_CELLS do
    local rec = view.tiles[k]
    if rec and rec.spr and rec.logical_i == i then
      local frame = tile_frame_for(i)
      if rec.frame ~= frame then
        rec.frame = frame
        rec.spr:set_frame(CFG.TILE_ATLAS, frame)
      end
      return
    end
  end
end

----------------------------------------------------------------------
-- Fog: hide tiles outside a radius around the mouse. Costs no memory and no
-- per-frame work (approved deviation D3 in place of the radial gradient).
----------------------------------------------------------------------
local FOG_RADIUS = 2

tile_visibility = function(cx, cy)
  for k = 1, CFG.VIEW_CELLS do
    local rec = view.tiles[k]
    if rec and rec.logical_i then
      local vis = true
      if S.fog_on then
        local tx = ((rec.logical_i - 1) % S.cols) + 1
        local ty = ((rec.logical_i - 1) // S.cols) + 1
        local dx, dy = tx - cx, ty - cy
        if dx < 0 then dx = -dx end
        if dy < 0 then dy = -dy end
        vis = (dx + dy) <= FOG_RADIUS
      end
      show(rec, vis)
    end
  end
end

----------------------------------------------------------------------
-- Choice labels: up to MAX_CHIPS vocabulary words, each drawn ON the maze cell
-- it leads to. There is no rail above the maze any more -- the band it occupied
-- became the maze's fourth row (CFG.CHIP_ROW_H), and direction is now carried
-- by WHERE the word sits rather than by an arrow glyph under it.
--
-- The same four Text objects are reused by the OVER screen for the rank and
-- board lines, which position themselves through scene_text.
----------------------------------------------------------------------
-- No direction marker any more: a label is drawn ON the cell it leads to, so
-- position carries the direction that an arrow glyph used to spell out.
--
-- fonts/vi-bold.ttf still carries the four arrow outlines that were drawn into
-- it at U+2190..U+2193 (the subset had none of its own -- U+2190..2193,
-- U+25B2/25B6/25BC and the small-triangle block were all checked and absent).
-- They cost +326 bytes of flash and are now unreferenced. Left in the face
-- rather than re-subsetted: regenerating the .ttf to reclaim 326 bytes would
-- re-derive every other glyph the game depends on for no measurable gain.
--
-- Mean glyph advance of vi-bold at CHIP_PX, used to centre a label over its
-- cell. Measured, not derived: Tiny TTF reports no width to Lua.
local CHIP_ADV = 8

-- Widest label allowed on one line, in glyphs.
--
-- Deliberately WIDER than the 60 px cell (7 glyphs), because a label may
-- overhang its cell safely. The four choices sit on the mouse's four
-- neighbours, so two opposing labels are 2*CELL = 120 px apart centre to
-- centre: anything up to 120 px wide cannot collide with its opposite number.
-- 12 glyphs = 96 px leaves 24 px of clearance at the worst case.
--
-- Wrapping at the cell width instead would break 15 of the 143 authored words
-- ("BASKETBALL", "CHOCOLATE", "A SMARTPHONE") into stacked fragments, which is
-- harder to read than a word that simply runs past its tile edge. Only
-- "HIDE AND SEEK" (13) exceeds this and wraps at its space.
local CHIP_CELL_COLS = 12

-- Top inset of a label inside its 60 px cell.
--
-- Labels are TOP-anchored rather than centred: centring would run the text
-- across the middle of the 44 px actor art (ACTOR_OFF = 8) and hide the face of
-- whatever stands there -- and a monster's cell is exactly the one the child
-- most needs to read. Growing downward from a fixed top leaves the art below
-- clear and keeps a wrapped label inside its own cell rather than reaching up
-- into the row above.
local CHIP_CELL_DY = 2

-- Wrap a label to the cell width, breaking on SPACES only.
--
-- Never mid-word: these are the words the child has to say out loud, and a
-- "SMART-\nPHONE" split turns a reading task into a decoding puzzle. A single
-- token longer than the cell (none today; the longest is "BASKETBALL" at 10)
-- is left to overhang rather than broken -- overhang is legible, a broken word
-- is not.
local function chip_wrap(label)
  if utf8.len(label) <= CHIP_CELL_COLS then return label, 1 end
  local lines, cur, n = {}, nil, 0
  for word in label:gmatch("%S+") do
    if not cur then
      cur = word
    elseif utf8.len(cur) + 1 + utf8.len(word) <= CHIP_CELL_COLS then
      cur = cur .. " " .. word
    else
      n = n + 1
      lines[n] = cur
      cur = word
    end
  end
  if cur then
    n = n + 1
    lines[n] = cur
  end
  return table.concat(lines, "\n"), n
end


-- Each choice is labelled ON the tile it leads to, not in a rail above the maze.
--
-- The child reads the word and sees where it goes in one fixation: the label sits
-- on the destination cell, so "which way is A BOOK" stops being a lookup and
-- becomes a glance. A FIGHT choice has no destination -- the monster is adjacent
-- to the mouse -- so it is drawn on the monster's own cell instead.
--
-- Labels are hidden mid-glide exactly as the rail was: the choices they name are
-- stale the moment the mouse leaves, and rebuilding them per frame of travel
-- would be garbage for something nobody can act on.
local function render_chips()
  local show_chips = (S.scene == Rules.SCENE_MAZE) and not S.gliding
  for i = 1, CFG.MAX_CHIPS do
    local rec = view.chip[i]
    local c = i <= S.choice_n and S.choices[i] or nil
    -- in_view: a choice can point at a cell the camera has not scrolled to on a
    -- map wider than the viewport. Drawing it would land the label on whatever
    -- cell happens to occupy those pixels.
    if c and show_chips and in_view(c.tx, c.ty) then
      local px, py = cell_px(c.tx, c.ty)
      text_set(rec, view.chip_label[i])
      text_color(rec, c.kind == Rules.CHOICE_MONSTER and CFG.COL_CHIP_FIGHT or CFG.COL_CHIP)
      -- Centred on the cell horizontally (chip_dx now measures the word against
      -- CELL, not a shared row slot), and sat just above the cell's midline so
      -- the 44 px actor art underneath stays readable.
      text_move(rec, floor(px) + view.chip_dx[i], floor(py) + CHIP_CELL_DY)
      text_show(rec, true)
    else
      text_show(rec, false)
    end
  end
end

-- All target-derived strings are built here, on a target change, so the per-frame
-- path only compares and assigns. Uppercasing chips and a 23-character sentence
-- every tick would be pure garbage on a 512 KB heap.
--
-- Gated on the inputs the strings are derived from: build_choices bumps
-- S.choice_rev (it also fires from inside step(), where no scene change or input
-- is visible to this layer), and the fight/gate prompt follows S.fight and the
-- gate sentence. Cheap enough to call every frame; rebuilds only on a real change.
local function refresh_targets()
  local rev, fight = S.choice_rev, S.fight
  local gate = (S.scene == Rules.SCENE_GATE) and S.gate_sentence or ""
  if view.tgt_rev == rev and view.tgt_fight == fight and view.tgt_gate == gate then
    return
  end
  view.tgt_rev, view.tgt_fight, view.tgt_gate = rev, fight, gate

  for i = 1, CFG.MAX_CHIPS do
    local c = S.choices[i]
    local label
    if i > S.choice_n then
      label = ""
    elseif c.kind == Rules.CHOICE_MONSTER then
      -- FIGHT is the literal keyword the child speaks (CFG.FIGHT_KEYWORD), so
      -- it stays English in both languages.
      label = "! FIGHT"
    else
      label = c.word:upper()
    end
    local wrapped = chip_wrap(label)
    view.chip_label[i] = wrapped
    -- Centre the label over its 60 px cell. The arrow line the rail needed is
    -- gone: the label now sits ON the cell it points to, so the direction is
    -- carried by position instead of a glyph.
    --
    -- Measured on the WIDEST LINE, not the whole string: LVGL left-aligns every
    -- line of a multi-line label, so centring on the total length would shove a
    -- wrapped label off to the left. Width in CODEPOINTS, not bytes -- # counts
    -- bytes and would mis-centre the moment a label is non-ASCII.
    local widest = 0
    for line in (wrapped .. "\n"):gmatch("(.-)\n") do
      local n = utf8.len(line) or #line
      if n > widest then widest = n end
    end
    view.chip_dx[i] = floor((CFG.CELL - widest * CHIP_ADV) / 2)
  end
  -- Lead-in translated, sentence kept: the sentence is the English target the
  -- child must say and the string Voice.set_keywords was handed.
  if S.scene == Rules.SCENE_GATE and S.gate_sentence ~= "" then
    view.prompt = I18n.t("open_lead") .. S.gate_sentence:upper()
  elseif S.fight > 0 then
    view.prompt = I18n.t("say_lead") .. S.mon[S.fight].sentence:upper()
  else
    view.prompt = nil
  end
end

----------------------------------------------------------------------
-- HUD / panel text. Rebuilt only when a displayed value actually changes.
-- (The comment here used to promise a HUD_REFRESH_MS throttle that never
-- existed; word_racer's 150 ms floor is not needed because this HUD is gated on
-- a value change and the only field that ticks unprompted is the clock, at 1 Hz.)
----------------------------------------------------------------------
-- One row, icons instead of field names, laid out like word_racer's HUD:
--
--   4/10   31s              ★ 1250 · 8  x3       ♥♥♡
--   hud (left edge)         star spr + hud_right  3 sprites (right edge)
--
-- Progress hugs the left edge and the player's own tally the right, which is
-- where word_racer puts the same two kinds of number (planet+stage left, star
-- score then hearts right). A child moving between the two games looks in one
-- place for one thing.
--
-- Every element is LEFT-anchored at a FIXED x, including the score. That is
-- deliberate: LVGL gives one alignment per label and Text cannot report a
-- rendered width, so an icon can never be placed relative to the number it
-- labels -- both have to be pinned. Right-anchoring the score cluster would
-- slide it from x=256 (score 99999) to x=382 (score 0) and tear it away from
-- the star naming it. word_racer pins its coin count at a fixed x for exactly
-- this reason and lets long values grow rightwards into open space.
--
-- Colour carries the hierarchy the old all-green row lacked: the score cluster
-- is the bright accent, the clock white until it turns COL_WARN under the tick
-- threshold, and the map counter dimmed as the least urgent field.
local HUD_ICON_Y  = CFG.HUD_Y
local HUD_TEXT_DY = 8          -- was 3; moves with HUD_Y so text and icons stay aligned
-- Right cluster, measured from the right edge inwards so the hearts sit
-- outermost: 3 hearts (20 px art on a 22 px pitch), then the score with the
-- crumb icon naming it. The score x is fixed at its WORST-case width so a
-- five-digit score still clears the hearts; shorter scores leave a wider gap.
local HUD_HEART_W  = 20
local HUD_HEARTS_W = (CFG.MAX_LIVES - 1) * CFG.HUD_HEART_STEP + HUD_HEART_W
local HUD_HEARTS_X = CFG.SCREEN_W - CFG.HUD_PAD_X - HUD_HEARTS_W
-- Widths below are MEASURED from the font's hmtx table, not estimated. The
-- earlier numbers on this row assumed a 9 px mean advance at 16 px, which
-- overshoots badly: the widest left cluster is 222.6 px, not the 243 px that
-- estimate gave. Every reservation here is the real px width of its worst-case
-- string:
--   left cluster  "MÀN: 10/10  GIỜ: 120s  CHÌA"  222.6   (en: 217.9)
--   score         "99999  x3"                     72.5
-- The crumb mark LABELS the score rather than counting crumbs separately: it is
-- the thing the child picks up to earn points, so it names the tally the way the
-- hearts name lives. One icon + one number, 13 px for the icon and its gap. That
-- still clears 61.4 px between the left cluster and the icon.
local HUD_GAP       = 6        -- between clusters
local HUD_CRUMB_W   = 9        -- native size of the mark lifted from the atlas
local HUD_CRUMB_ICON_GAP = 4   -- icon to the number it names: one unit, tight gap
-- A reservation, not a limit: the score is left-anchored, so a value wider than
-- this grows rightwards. Sized for "99999  x3" (72.5 px), the widest the score
-- cluster gets -- a bare number with a live combo.
local HUD_SCORE_W  = 73
local HUD_CRUMB_X  = HUD_HEARTS_X - HUD_GAP
                     - (HUD_CRUMB_W + HUD_CRUMB_ICON_GAP + HUD_SCORE_W)
local HUD_SCORE_X  = HUD_CRUMB_X + HUD_CRUMB_W + HUD_CRUMB_ICON_GAP

local function render_hud_icons()
  -- Hearts never reflow: a spent life dims rather than disappears, so the row
  -- reads "2 of 3" instead of just "2" (word_racer's set_opacity(45) trick).
  if view.hud_heart then
    for i = 1, CFG.MAX_LIVES do
      local rec = view.hud_heart[i]
      if rec and rec.spr then
        place(rec, HUD_HEARTS_X + (i - 1) * CFG.HUD_HEART_STEP, HUD_ICON_Y)
        local lit = i <= S.lives
        if rec.lit ~= lit then
          rec.lit = lit
          rec.spr:set_opacity(lit and 255 or CFG.HUD_SPENT_OPA)
        end
        show(rec, true)
      end
    end
  end
  if view.hud_crumb then
    -- Sits a touch lower than the hearts: it is 9 px tall against their 18, so
    -- aligning tops would leave it floating above the score it names.
    place(view.hud_crumb, HUD_CRUMB_X, HUD_ICON_Y + 5)
    show(view.hud_crumb, true)
  end
end

local function render_hud()
  local secs = max(0, ceil(S.time_left))
  local mult = Rules.combo(S)
  if S.hud_secs == secs and S.hud_score == S.score and S.hud_lives == S.lives
     and S.hud_level == S.level
     and S.hud_has_key == S.has_key and S.hud_mult == mult then
    return
  end
  S.hud_secs, S.hud_score, S.hud_lives = secs, S.score, S.lives
  S.hud_level = S.level
  S.hud_has_key, S.hud_mult = S.has_key, mult

  render_hud_icons()

  -- LEFT: progress, with both fields NAMED. The right-hand cluster gets away
  -- with bare numbers because a star and a row of hearts say what they are; a
  -- map counter and a countdown look like two anonymous numbers side by side,
  -- and there is no icon for either. So they keep their words.
  --
  -- Map counter first because it is the slower-changing of the two, then the
  -- clock. Both share one label, so the clock cannot take its own COL_WARN
  -- colour when time runs low -- the whole left cluster turns instead, which
  -- reads as "this side is urgent" and costs no extra Text slot.
  local left = I18n.t("map") .. ": " .. S.level .. "/" .. Levels.COUNT ..
               "  " .. I18n.t("time") .. ": " .. secs .. "s"
  -- KEY rides here rather than with the score: it is map progress, not a tally,
  -- and the cage sprite already shows the door state, so it appears rarely
  -- enough not to be worth a sprite slot of its own.
  -- Two spaces, not three: with both fields named, the widest left cluster is
  -- "MÀN: 10/10  GIỜ: 120s  CHÌA" at 27 characters, and a third space is what
  -- pushes it into the score. The KEY word only ever appears on a key map.
  if S.has_key then left = left .. "  " .. I18n.t("key") end

  -- RIGHT: the player's tally, as a bare number with no SCORE/ĐIỂM label -- the
  -- crumb icon immediately to its left names it, the way the hearts name lives.
  -- Picture where there is one, word where there is not: dropping the word also
  -- buys room for the combo, which cost 55 px, and "99999  x3" needs 72.5 of the
  -- 73 now reserved.
  local right = tostring(S.score)
  if mult > 1 then right = right .. "  x" .. mult end

  -- Both left-anchored at fixed x: see the note above HUD_ICON_Y for why
  -- nothing in this row may be right-anchored. HUD_PAD_X is the bezel inset --
  -- the robot's frame crops a margin the flat 480x320 render cannot see -- and
  -- it is the SAME value at both ends: the text starts HUD_PAD_X in from the
  -- left, the hearts end HUD_PAD_X in from the right, so the row sits centred
  -- between two equal margins.
  text_align(view.hud, "top_left", CFG.HUD_PAD_X, HUD_TEXT_DY)
  text_align(view.hud_right, "top_left", HUD_SCORE_X, HUD_TEXT_DY)
  text_set(view.hud, left)
  text_set(view.hud_right, right)
  text_color(view.hud, secs <= CFG.TICK_THRESHOLD_S and CFG.COL_WARN or CFG.COL_HUD)
  text_color(view.hud_right, CFG.COL_CHIP)
  text_show(view.hud, true)
  text_show(view.hud_right, true)
end

local function render_panel()
  local str, col
  -- Ahead of view.prompt: voice is the only input now, so a dead channel means
  -- the gate cannot be opened at all. Say that plainly instead of leaving the
  -- sentence prompt up as if speaking would still work.
  if S.scene == Rules.SCENE_GATE and not view.voice_ok then
    str = I18n.t("voice_dead_gate")
    col = CFG.COL_WARN
  elseif view.prompt then
    str = view.prompt
    col = CFG.COL_PANEL
  elseif S.msg ~= "" then
    -- S.msg is an i18n key; S.msg_arg is the one variable part, appended after
    -- the key resolves so word order stays the translation's business.
    str = I18n.t(S.msg)
    if S.msg_arg then str = str .. S.msg_arg end
    col = CFG.COL_CHIP
  else
    local adj = false
    for k = 1, S.choice_n do
      if S.choices[k].kind == Rules.CHOICE_MONSTER then
        adj = true
        break
      end
    end
    if adj then
      str = I18n.t("fight_hint")
      col = CFG.COL_CHIP_FIGHT
    elseif not view.voice_ok then
      str = I18n.t("voice_dead")
      col = CFG.COL_WARN
    else
      str = I18n.t(S.rule_hint)
      col = CFG.COL_HINT
    end
  end
  text_set(view.panel, str)
  text_color(view.panel, col)
  text_align(view.panel, "bottom", 0, -5)
  text_show(view.panel, true)
end

----------------------------------------------------------------------
-- Scene rendering
----------------------------------------------------------------------
local function hide_maze()
  if not view.tiles then return end
  for i = 1, CFG.VIEW_CELLS do show(view.tiles[i], false) end
  show(view.mouse, false)
  show(view.key, false)
  show(view.cage, false)
  for i = 1, CFG.MAX_MONSTERS do show(view.mon[i], false) end
  for i = 1, CFG.MAX_CHIPS do text_show(view.chip[i], false) end
end

-- Icons only. Split out from hide_hud because INTRO and OVER reuse the two HUD
-- LABELS as scene text, so they cannot call hide_hud (it would blank the card
-- they just wrote) -- yet they still have to clear the hearts and the crumb
-- mark, which would otherwise sit on top of that card. That is exactly what
-- happened before this split: the OVER screen showed live HUD icons over it.
local function hide_hud_icons()
  if view.hud_heart then
    for i = 1, CFG.MAX_LIVES do show(view.hud_heart[i], false) end
  end
  if view.hud_crumb then show(view.hud_crumb, false) end
  -- The OVER footer star. Hidden here so every scene that clears the HUD clears
  -- it too; render_over() runs AFTER this on the OVER path and puts it back.
  if view.hud_star then show(view.hud_star, false) end
end

local function hide_hud()
  text_show(view.hud, false)
  text_show(view.hud_right, false)
  hide_hud_icons()
end

local function scene_text(rec, str, y, col)
  text_set(rec, str)
  text_align(rec, "top", 0, y)
  text_color(rec, col)
  text_show(rec, true)
end

local function render_actors()
  local off = CFG.ACTOR_OFF

  -- Mouse: art follows the glide direction; blink while invincible.
  local mcx, mcy = Rules.mouse_pos(S)
  local mpx, mpy = cell_px(mcx, mcy)
  local flip_h = false
  if S.gliding then
    local d = CFG.DIRS[S.glide_dir]
    flip_h = d.dx < 0
  end
  flip(view.mouse, flip_h)
  if view.mouse.spr then
    local opacity = 255
    if S.iframe_ms > 0 and (floor(S.iframe_ms / 90) % 2 == 0) then opacity = 100 end
    if view.mouse.opacity ~= opacity then
      view.mouse.opacity = opacity
      view.mouse.spr:set_opacity(opacity)
    end
  end
  place(view.mouse, floor(mpx) + off, floor(mpy) + off)
  show(view.mouse, true)

  -- Monsters: chaser art, telegraph art while winding up, fight art when engaged.
  for i = 1, CFG.MAX_MONSTERS do
    local rec = view.mon[i]
    local m = S.mon[i]
    if i <= S.mon_n and m.alive then
      local a
      local face_left = false
      if S.fight == i then a = CFG.SPR_MONSTER.fight
      elseif m.lunge then a = CFG.SPR_MONSTER.lunge
      elseif m.chaser then a = CFG.SPR_MONSTER.chaser
      else
        -- Face the way the patrol is heading (HTML flips the eyes). Mirroring the
        -- one patrol PNG costs a flag on the LVGL object; a second PNG would cost
        -- a destroy + decode on every direction change.
        a = CFG.SPR_MONSTER.patrol
        local ni = m.ri + m.rdir
        face_left = ni >= 1 and ni <= m.route_n and m.route_x[ni] < m.x
      end
      if set_art(rec, a) then rec.spr:to_front() end
      flip(rec, face_left)
      local px, py = cell_px(m.x, m.y)
      place(rec, px + off, py + off)
      show(rec, in_view(m.x, m.y))
    else
      show(rec, false)
    end
  end

  -- Key and cage.
  if S.key_i ~= 0 then
    local cx = ((S.key_i - 1) % S.cols) + 1
    local cy = ((S.key_i - 1) // S.cols) + 1
    local px, py = cell_px(cx, cy)
    place(view.key, px + off, py + off)
    show(view.key, in_view(cx, cy))
  else
    show(view.key, false)
  end

  if set_art(view.cage, S.door_locked and CFG.SPR_CHEESE_LOCK or CFG.SPR_CHEESE_OPEN) then
    -- Cage sits below the actors: the recreated sprite lands on top of
    -- everything, so re-front the actors above it to restore that layer.
    if view.mouse.spr then view.mouse.spr:to_front() end
    for i = 1, CFG.MAX_MONSTERS do if view.mon[i].spr then view.mon[i].spr:to_front() end end
  end
  local gx, gy = cell_px(S.cols, S.rows)
  place(view.cage, gx + off, gy + off)
  show(view.cage, in_view(S.cols, S.rows))

  return mpx, mpy
end

-- Intro and game-over lines are constant for the whole scene (the OVER lines
-- change only when rank data lands, which clears the cache), so build them once
-- on entry. render() then only compares already-built strings.
local function cache_scene_text(scene)
  if scene == Rules.SCENE_OVER then
    -- One string per LINE, each on its own label, so every line gets its own
    -- size, colour and centre. The old screen packed title + crumbs + best into
    -- one label and score into another, which forced a single size on unrelated
    -- fields and left the score -- the only number the child remembers -- the
    -- same weight as a tally of zero.
    view.over_hero  = GameOverUI.score_card(floor(S.score))
    view.over_rank  = GameOverUI.rank_line(view.over_rank_n)
    view.over_board = view.over_table or GameOverUI.pending_board()
    view.over_pre   = GameOverUI.footer_pre()
    view.over_post  = GameOverUI.footer_post()
    view.intro_map, view.intro_topic = nil, nil
    view.intro_size, view.intro_time = nil, nil
  elseif scene == Rules.SCENE_INTRO then
    local total_mon = S.mon_n
    view.intro_map = I18n.t("map") .. " " .. S.level
    -- Topic NAME is chrome and gets translated; the words under it do not.
    view.intro_topic = I18n.topic(Curriculum.TOPICS[S.topic].topic)
    view.intro_size = S.cols .. " x " .. S.rows .. "   " ..
      (total_mon > 0 and (total_mon .. I18n.t("monsters")) or I18n.t("no_monsters"))
    view.intro_time = I18n.t("time") .. " " .. ceil(S.time_max) .. "s   " ..
      I18n.t("map") .. " " .. S.level .. "/" .. Levels.COUNT
    view.over_hero = nil
    view.over_rank, view.over_board = nil, nil
    view.over_pre, view.over_post = nil, nil
  else
    view.intro_map, view.intro_topic = nil, nil
    view.intro_size, view.intro_time = nil, nil
    view.over_hero = nil
    view.over_rank, view.over_board = nil, nil
    view.over_pre, view.over_post = nil, nil
  end
end

----------------------------------------------------------------------
-- GAME OVER screen. Four stacked lines, each on its own label so each can take
-- its own size, colour and centre. Reading order is the order of importance:
-- what you scored, where that put you, who else is on the board, how to play
-- again.
--
-- Labels: the four chip labels are idle here (the maze is hidden, so there are
-- no choices to show), which is what pays for the extra lines. No new Text slot
-- is taken -- the pool stays at 7 of 8.
--
-- The "KET THUC" title line is gone. The screen itself already says the run
-- ended -- the maze is off, the score is huge and the footer offers a replay --
-- so a heading only pushed the number the child actually came for further down.
-- The Y values below are unchanged, so the score keeps the position it has
-- always had rather than sliding up into the title's slot.
--
--   y=72   * DIEM 1250         26 px     COL_CHIP     the number they remember
--   y=116  HANG #7             CHIP_PX   0x65F4FF     where it placed them
--   y=150  TOP 5 + rows        CHIP_PX   0xF4F7FF     the board
--   y=-8   NHAN NUT...         CHIP_PX   COL_CHIP     the way out (bottom)
----------------------------------------------------------------------
local OVER_HERO_Y  = 72
local OVER_RANK_Y  = 116
local OVER_BOARD_Y = 150

-- OVER footer: "<NHẤN> [star] <ĐỂ CHƠI LẠI>", the rig word_racer uses. The star
-- is 18x18; the two text halves anchor to its left and right at
-- OVER_FOOTER_GAP from the rig centre (half the star plus 6 px of air), which
-- keeps its spacing fixed no matter how long the strings are.
--
-- The rig centre sits LEFT of the screen centre because the trailing half is far
-- longer than the leading one, so the group would read right-heavy if the star
-- itself were centred. How far left depends on that length difference, which
-- differs per language -- a single constant cannot centre both:
--
--   vi  "NHẤN" 43.2 px / "ĐỂ CHƠI LẠI" 85.0 px  ->  cx 219
--   en  "PRESS" 41.2 px / "TO PLAY AGAIN" 107.7 px  ->  cx 207
--
-- so it is derived rather than tuned. Centring the group means
--   cx + (post_w - pre_w)/2 = SCREEN_W/2
-- because the group spans [cx-GAP-pre_w, cx+GAP+post_w]. Widths come from the
-- table below, measured from the shipped fonts/vi-bold.ttf at CHIP_PX with the
-- same advance sum Tiny TTF renders (sum of hmtx advances * px / unitsPerEm).
--
-- Text still cannot report a width at runtime, which is the whole reason the
-- halves are edge-anchored; this only moves the measuring to author time, where
-- the strings are known. Re-measure if the strings, CHIP_PX or the face change.
local OVER_FOOTER_W = {
  vi = { pre = 43.2, post = 85.0 },
  en = { pre = 41.2, post = 107.7 },
}
local OVER_FOOTER_GAP = 15
-- lv_obj_align offsets are measured from the anchored EDGE, not the centre:
-- bottom_right puts label.right at screen.right + dx (so dx is negative), while
-- bottom_left puts label.left at screen.left + dx. Both derive from the same rig
-- centre so the pair can never drift apart.
local function footer_rig()
  local w = OVER_FOOTER_W[I18n.language()] or OVER_FOOTER_W.vi
  local cx = floor(CFG.SCREEN_W / 2 - (w.post - w.pre) / 2 + 0.5)
  return (cx - OVER_FOOTER_GAP) - CFG.SCREEN_W,  -- dx for the bottom_right half
         cx + OVER_FOOTER_GAP,                   -- dx for the bottom_left half
         cx - 9                                  -- star x; 9 = half the 18 px sprite
end
-- 291, not the 296 the text band's geometric centre works out to: the glyphs
-- have no descenders here, so their visual mass sits above that midpoint and a
-- centred star read low next to them.
local OVER_STAR_Y = 293
-- Every line here is centred, the hero line included. It was left-anchored for
-- one reason only: a star sprite sat beside it, and Text cannot report a
-- rendered width, so a centred line would have drifted away from the pinned
-- star (x=189 for "DIEM 0" against x=160 for "DIEM 99999"). With the star gone
-- the constraint goes with it -- the word DIEM already names the number, and a
-- 26 px line is the largest thing on the screen either way.

-- OVER borrows the score label at a bigger size; every other scene needs it back
-- at HUD_PX. Called on the way in to TITLE / INTRO / gameplay, and gated so the
-- set_font costs nothing on the frames where nothing changed.
local function restore_play_fonts()
  if not view.play_fonts_dirty then return end
  view.play_fonts_dirty = false
  view.over_fonts = false
  set_font(view.hud_right, HUD_PX)
  -- Hand the panel back its own face: render_over borrowed it at CHIP_PX to
  -- match the footer's other half, and the gameplay sentence -- the longest
  -- string in the pack, read under time pressure -- needs PANEL_PX again.
  set_font(view.panel, PANEL_PX)
  -- Also the way OUT of OVER for the footer rig: gameplay reaches neither
  -- hide_hud_icons() nor hide_hud(), so without this the star and the borrowed
  -- chip[3] half would stay up over the maze.
  if view.hud_star then show(view.hud_star, false) end
  text_show(view.chip[3], false)
end

local function render_over()
  -- set_font takes the LVGL lock and re-renders the face, so it runs on scene
  -- ENTRY only -- render() is called every frame. play_fonts_dirty makes the
  -- gameplay sizes get restored the same way when the run starts again.
  if not view.over_fonts then
    view.over_fonts = true
    view.play_fonts_dirty = true
    set_font(view.hud_right, OVER_SCORE_PX)
    -- Both halves of the footer on ONE face. They are a single sentence broken
    -- around the star sprite, so the two must match or "NHAN" reads as a
    -- heading over its own second line. view.panel carries PANEL_PX (18) from
    -- build_pools for the gameplay sentence, chip[3] carries CHIP_PX (14) --
    -- unequal until set here. CHIP_PX is the shared size, not PANEL_PX: chip[3]
    -- is a vocabulary chip during play and cannot take the panel face without a
    -- fifth size, and GAME_FONT_SLOTS is 4.
    set_font(view.panel, CHIP_PX)
  end
  -- The title line is gone: the score is the top line now, and view.hud stays a
  -- gameplay/INTRO label only -- no longer borrowed, so no font swap either.
  text_show(view.hud, false)
  scene_text(view.hud_right, view.over_hero or "", OVER_HERO_Y, CFG.COL_CHIP)

  scene_text(view.chip[1], view.over_rank or "", OVER_RANK_Y, 0x65F4FF)
  scene_text(view.chip[2], view.over_board or "", OVER_BOARD_Y, 0xF4F7FF)

  -- Footer anchored to the BOTTOM, not offset from the board: the board is 1 to
  -- 6 lines tall depending on what the backend returned, so anything measured
  -- from its top would drift with it.
  --
  -- Two halves with the star sprite between them. chip[3] is idle on this screen
  -- (the maze is hidden), so the second half costs no extra Text slot.
  local dx_pre, dx_post, star_x = footer_rig()

  text_set(view.panel, view.over_pre or "")
  text_align(view.panel, "bottom_right", dx_pre, -8)
  text_color(view.panel, CFG.COL_CHIP)
  text_show(view.panel, true)

  text_set(view.chip[3], view.over_post or "")
  text_align(view.chip[3], "bottom_left", dx_post, -8)
  text_color(view.chip[3], CFG.COL_CHIP)
  text_show(view.chip[3], true)

  place(view.hud_star, star_x, OVER_STAR_Y)
  show(view.hud_star, true)

  for i = 4, CFG.MAX_CHIPS do text_show(view.chip[i], false) end
end

-- Blink the title prompt by cycling the 2-frame atlas. Guarded on the frame
-- actually changing: set_frame is an open + fseek + fread of a full 300 KB
-- screen, so running it every frame instead of twice a second would spend the
-- whole budget redrawing a static screen.
local function title_tick()
  local rec = view.screen
  if not rec or not rec.spr or rec.art ~= CFG.SCREEN_TITLE then return end
  local now = (Timer and Timer.millis and Timer.millis()) or 0
  local f = math.floor(now / CFG.TITLE_BLINK_MS) % CFG.TITLE_FRAMES
  if rec.frame == f then return end
  if rec.spr:set_frame(CFG.SCREEN_TITLE, f) then
    rec.frame = f
  end
end

local function render()
  local scene = S.scene
  if scene ~= view.last_scene then
    view.last_scene = scene
    cache_scene_text(scene)
  end

  if scene == Rules.SCENE_TITLE then
    set_screen(CFG.SCREEN_TITLE)
    hide_maze()
    hide_hud()
    restore_play_fonts()
    text_show(view.panel, false)
    title_tick()
    return
  end

  if scene == Rules.SCENE_OVER then
    set_screen(CFG.SCREEN_OVER)
    hide_maze()
    hide_hud_icons()
    render_over()
    return
  end

  if scene == Rules.SCENE_INTRO then
    set_screen(CFG.SCREEN_INTRO)
    -- Upload tile pixels while every maze object stays hidden. Revealing partial
    -- batches here caused the maze/crumbs to bleed through the intro UI.
    hide_maze()
    hide_hud_icons()
    restore_play_fonts()
    scene_text(view.hud, view.intro_map or "", 52, CFG.COL_HUD)
    scene_text(view.hud_right, I18n.t(S.rule_name), 116, 0xC07BFF)
    scene_text(view.chip[3], view.intro_topic or "", 84, CFG.COL_CHIP)
    scene_text(view.chip[1], view.intro_size or "", 150, 0xFFFFFF)
    scene_text(view.chip[2], view.intro_time or "", 176, 0x7FD0FF)
    scene_text(view.panel, I18n.t(S.rule_hint), 208, CFG.COL_HINT)
    -- Tiles stream in behind the card so the maze is ready when it lifts.
    pump_tile_upload()
    return
  end

  set_screen(nil)
  ensure_chrome()
  restore_play_fonts()
  local mcx, mcy = Rules.mouse_pos(S)
  if not view.maze_visible then
    reveal_tiles(floor(mcx + 0.5), floor(mcy + 0.5))
  end
  local max_x = max(1, S.cols - view.view_cols + 1)
  local max_y = max(1, S.rows - view.view_rows + 1)
  local cam_x = min(max(1, floor(mcx) - floor(view.view_cols / 2)), max_x)
  local cam_y = min(max(1, floor(mcy) - floor(view.view_rows / 2)), max_y)
  if cam_x ~= view.cam_x or cam_y ~= view.cam_y then
    view.cam_x, view.cam_y = cam_x, cam_y
    view.upload_i = 1
    view.fog_cx, view.fog_cy = nil, nil
  end
  if view.upload_i then pump_tile_upload() end

  render_actors()
  -- Only the fog case needs per-frame visibility work. Clearing fog on a
  -- non-fog map is handled on map entry instead: EV_MAP_READY -> begin_tile_upload
  -- drops maze_visible, and the reveal_tiles above shows every mapped tile
  -- (skipping tile_visibility when S.fog_on is false).
  if S.fog_on then
    local fog_cx, fog_cy = floor(mcx + 0.5), floor(mcy + 0.5)
    if fog_cx ~= view.fog_cx or fog_cy ~= view.fog_cy then
      view.fog_cx, view.fog_cy = fog_cx, fog_cy
      tile_visibility(fog_cx, fog_cy)
    end
  end

  refresh_targets()                  -- no-op unless a target actually changed
  render_chips()
  render_hud()
  render_panel()
end

----------------------------------------------------------------------
-- Feedback: one place where sound, LED and servo happen (react dispatcher).
----------------------------------------------------------------------
local function react(ev)
  if ev == Rules.EV_STEP then
    sfx("scurry")
  elseif ev == Rules.EV_CRUMB then
    sfx("nom")
    if S.last_pick_i then refresh_tile(S.last_pick_i) end
  elseif ev == Rules.EV_KEY then
    sfx("keyget")
    pose("poke")                     -- J1: embodiment on a reward beat
  elseif ev == Rules.EV_KILL then
    sfx("zap")
    pose("poke")                     -- J1
  elseif ev == Rules.EV_GATE then
    -- The demo plays unlock then cheese 200 ms later. There is one audio channel
    -- here, so a second play would preempt the first: use the longer cheese
    -- fanfare for the map-clear beat and keep unlock for the key-door moment.
    sfx(S.key_on and "unlock" or "cheese")
    pose("cheer_jump")                -- J1: map cleared
  elseif ev == Rules.EV_HURT then
    sfx("hurt")
  elseif ev == Rules.EV_TIMEOUT then
    sfx("fail")
  elseif ev == Rules.EV_OVER then
    sfx("over")
  elseif ev == Rules.EV_FIGHT then
    sfx("growl")
  elseif ev == Rules.EV_LOCKED then
    sfx("miss")
  elseif ev == Rules.EV_GROWL then
    sfx("growl")
  elseif ev == Rules.EV_TICK then
    sfx("tick")
  elseif ev == Rules.EV_NO_MATCH then
    -- "tick", not "miss": staying quiet is not a wrong answer, so the re-prompt
    -- gets an attention cue rather than the failure sting reserved for a locked
    -- cage or a lost life. Rules pairs it with a restated target.
    sfx("tick")
  elseif ev == Rules.EV_MAP_READY then
    begin_tile_upload()
    refresh_targets()
  end
end

local function drain_events()
  local n = S.event_n
  if n == 0 then return end
  for i = 1, n do react(S.events[i]) end
  Rules.clear_events(S)
end

----------------------------------------------------------------------
-- Voice
--
-- Structured to match word_racer's pipeline: one `voice` table owns the started
-- flag, voice_stop() always leads voice_start(), and every vocabulary change goes
-- through the same close-and-reopen cycle rather than a bare set_keywords().
--
-- Cost of that fidelity, specific to this game: word_racer only rotates its
-- vocabulary at a round boundary, where a stop/start lands under a 1400 ms
-- "Round N" card and nobody is speaking. Word Maze rotates mid-play -- entering a
-- fight, reaching the gate, clearing a map -- so each of those beats now carries a
-- short window with KWS down. The fight case is the sharp one: the sentence
-- keyword can only be registered once S.fight is set, which is the same instant
-- the child starts reading. The reopen is therefore issued BEFORE the
-- "SAY THE SENTENCE!" message is raised, putting the dead window under that
-- 900 ms card instead of after it.
----------------------------------------------------------------------
local voice = { started = false }

local kw_buf = {}      -- reused keyword list; Voice.set_keywords copies it

-- Fill kw_buf with the vocabulary for the current target and return its length.
-- Split out of the push so voice_start() builds and pushes exactly once, the way
-- word_racer's build_keywords() feeds its single set_keywords() call.
local function build_keywords()
  local n = 0
  local cores = Curriculum.CORES[S.topic]
  for i = 1, 6 do
    n = n + 1
    kw_buf[n] = cores[i]
  end
  n = n + 1
  kw_buf[n] = CFG.FIGHT_KEYWORD
  -- Sentence targets are single keywords for this backend, so register the exact
  -- phrase the panel is asking for.
  if S.scene == Rules.SCENE_GATE and S.gate_sentence ~= "" then
    n = n + 1
    kw_buf[n] = Curriculum.clean(S.gate_sentence)
  elseif S.fight > 0 then
    n = n + 1
    kw_buf[n] = Curriculum.clean(S.mon[S.fight].sentence)
  end
  for i = n + 1, #kw_buf do kw_buf[i] = nil end
  return n
end

local function voice_stop()
  if voice.started and Voice and Voice.stop then pcall(Voice.stop) end
  voice.started = false
  led_stop()
end

-- Voice is the ONLY control during play: the button paths were removed, so a
-- dead channel means the run cannot advance. voice_ok therefore drives a
-- warning on the panel rather than a fallback mode.
--
-- Voice.is_available() is deliberately NOT consulted here: it reports the engine
-- running flag, which the engine only raises AFTER the pack load that calls
-- game_start, so inside this hook it is always false. Voice.start()'s own return
-- (and the later on_voice_event status) is the real signal.
local function voice_start()
  voice_stop()
  if not (Voice and Voice.set_keywords and Voice.start) then
    print("word_maze: voice binding absent, cannot play")
    led_set_base(LED.RED)
    return false
  end

  build_keywords()
  local ok, reason = Voice.set_keywords(kw_buf, CFG.VOICE_SENSITIVITY)
  if not ok then
    print("word_maze: set_keywords failed " .. tostring(reason))
    led_set_base(LED.RED)
    return false
  end

  ok, reason = Voice.start()
  if not ok then
    -- Keyword spotting needs the backend WebSocket, so no network means the
    -- panel warns from the first frame rather than stalling on speech that
    -- can never be heard.
    print("word_maze: Voice.start failed (" .. tostring(reason) .. "), cannot play")
    led_set_base(LED.RED)
    return false
  end
  voice.started = true
  led_set_base(LED.BLUE)
  return true
end

-- Vocabulary rotation. Every call closes and reopens the KWS session, matching
-- word_racer's round-boundary behaviour. Keeps view.voice_ok in step so a reopen
-- that fails surfaces the panel warning instead of leaving a blue LED over a
-- dead session.
local function push_keywords()
  local ok = voice_start()
  view.voice_ok = ok
  if S then S.voice_ok = ok end
  return ok
end


local function finish_run()
  if view.run_finished then return end
  view.run_finished = true
  if S.score > S.hiscore then S.hiscore = S.score end
  if S.crumbs_taken > S.best_crumbs then S.best_crumbs = S.crumbs_taken end
  -- hiscore/best_crumbs are still tracked: they feed nothing on this screen any
  -- more, but Rules keeps them across runs and a future screen may want them.
  view.over_table = GameOverUI.pending_board()
  view.over_rank_n = nil
  view.last_scene = nil              -- rebuild the OVER strings now hiscore is final
  -- Reported on every round end regardless of launch mode - the only path
  -- that reaches the Robot Game leaderboard (word_maze has no A2A concept).
  -- Only start polling get_result() if the report actually went out
  -- (send_failed / bad_score / payload_too_big all return false, see
  -- bind_ranking.c) - back never kicks off FetchGameRank without a report
  -- landing first, so polling on a failed report would just burn the full
  -- timeout waiting on a rank refresh that was never triggered.
  local reported = false
  if Ranking and Ranking.report then
    local ok, sent = pcall(Ranking.report, { score = S.score })
    reported = ok and sent == true
  end
  view.rank_shown = not reported
  view.rank_poll_deadline = reported
    and ((Timer and Timer.millis and Timer.millis() or 0) + RANK_POLL_TIMEOUT_MS)
    or nil
end

-- Render the same authoritative top-five response used by Word Racer. Never
-- mix server data with demo/sample scores because that can display a false rank.
local function show_rank_result(result)
  local board = GameOverUI.top5_board(result)
  if board then view.over_table = board end
  -- The rank goes to its OWN line now, so store the number and let
  -- cache_scene_text format it -- it no longer gets appended to the score.
  view.over_rank_n = GameOverUI.rank_of(result)
  view.last_scene = nil              -- rebuild the OVER strings with the rank data
end

-- Poll briefly after Ranking.report(), matching Word Racer's game-over flow.
local function update_over_rank()
  if view.rank_shown then return end
  if view.rank_poll_deadline and Timer and Timer.millis
     and Timer.millis() >= view.rank_poll_deadline then
    view.rank_shown = true
    return
  end
  local result = Ranking and Ranking.get_result and Ranking.get_result()
  if not result then return end
  show_rank_result(result)
  view.rank_shown = true
end

----------------------------------------------------------------------
-- Hooks
----------------------------------------------------------------------
-- params.language is a snapshot taken at pack load (the VM is torn down after
-- every game), so reading it once here is enough -- same as word_racer.
function game_start(params)
  local language = I18n.set_language(params and params.language or "vi")
  GameOverUI.set_language(language)

  S = Rules.new_state()
  view.fog_cx, view.fog_cy = nil, nil
  view.over_table = nil
  view.over_rank_n = nil
  view.rank_shown = false
  view.run_finished = false
  view.rank_poll_deadline = nil
  view.upload_i = nil
  view.last_scene = nil
  -- S is fresh (choice_rev back to 0), so the cache keys must not match it.
  view.tgt_rev, view.tgt_fight, view.tgt_gate = nil, nil, nil

  Rules.rng_seed(Timer and Timer.millis and Timer.millis() or 1)
  build_pools()

  view.voice_ok = voice_start()
  S.voice_ok = view.voice_ok

  S.scene = Rules.SCENE_TITLE
  view.acc = 0
  view.last_tick_ms = Timer and Timer.millis and Timer.millis() or nil
  render()
  print("word_maze: started voice=" .. tostring(view.voice_ok) ..
        " lang=" .. I18n.language())
end

function on_tick(dt_ms)
  if not S then return end
  -- The engine hands over its configured period (normally 33 ms), not the elapsed
  -- wall time. Under render overrun on hardware, trusting it makes the clock and
  -- the glide run in slow motion against real time; prefer the monotonic timer and
  -- keep the engine value as the simulator/first-frame fallback.
  local now = (Timer and Timer.millis and Timer.millis()) or 0
  -- Driven first, as word_racer does: the blink advances on its own clock and must
  -- not inherit the timing of whatever the simulation does below it.
  led_tick(now)
  local engine_dt = tonumber(dt_ms) or 0
  if engine_dt < 0 then engine_dt = 0 end
  if engine_dt > CFG.DT_MAX_MS then engine_dt = CFG.DT_MAX_MS end
  local real_dt = now - (view.last_tick_ms or now)
  view.last_tick_ms = now
  local dt = real_dt > 0 and real_dt or engine_dt
  if dt < 0 then dt = 0 end
  if dt > CFG.DT_MAX_MS then dt = CFG.DT_MAX_MS end
  local acc = view.acc + dt
  local steps = 0
  local scene_changed = false
  while acc >= CFG.LOGIC_DT_MS and steps < CFG.MAX_STEPS do
    local before_scene = S.scene
    local was_over = S.scene == Rules.SCENE_OVER
    Rules.step(S, CFG.LOGIC_DT_MS)
    drain_events()
    if S.scene ~= before_scene then
      refresh_targets()
      -- Deferred out of the loop: a vocabulary change is now a full KWS
      -- close/reopen (Voice.stop + a set_keywords IPC round-trip + Voice.start).
      -- The catch-up loop can run MAX_STEPS times in one frame and cross several
      -- scenes, so pushing per iteration would stack up to three reopens on a
      -- single frame -- and the INTRO->MAZE crossing already shares its frame
      -- with the tile upload. Only the final scene needs its vocabulary.
      scene_changed = true
    end
    if S.scene == Rules.SCENE_OVER and not was_over then
      finish_run()
      voice_stop()
    end
    acc = acc - CFG.LOGIC_DT_MS
    steps = steps + 1
  end
  if steps >= CFG.MAX_STEPS then acc = 0 end   -- drop the backlog, never spiral
  view.acc = acc
  -- Never reopen onto the OVER scene: finish_run() already stopped voice there,
  -- and a reopen would relight the LED over a finished run.
  if scene_changed and view.voice_ok and S.scene ~= Rules.SCENE_OVER then
    push_keywords()
  end

  if S.scene == Rules.SCENE_OVER then update_over_rank() end
  render()
end

function on_input(action, phase)
  if not S then return end
  if phase ~= Input.PRESS then return end

  if S.scene == Rules.SCENE_TITLE or S.scene == Rules.SCENE_OVER then
    if action == "confirm" then
      view.run_finished = false
      view.rank_shown = false
      view.rank_poll_deadline = nil
      view.over_table = nil
      view.over_rank_n = nil
      -- Drain any rank result still latched from the previous round: back's
      -- FetchGameRank runs on its own fire-and-forget task per Ranking.report()
      -- call and does not cancel an earlier in-flight fetch, so a reply slower
      -- than RANK_POLL_TIMEOUT_MS can land after this round already gave up
      -- polling. Left unconsumed, this round's first get_result() would read
      -- it and show the previous round's rank under this round's score (see
      -- word_racer_02's start_run() for the same fix).
      if Ranking and Ranking.get_result then Ranking.get_result() end
      Rules.start_run(S)
      drain_events()
      if view.voice_ok then push_keywords() end
      sfx("start")
    end
    return
  end

  -- Every other scene is voice-only: INTRO runs its own two-second card, and
  -- MAZE / GATE / CLEAR resolve exclusively through on_voice_event -> Rules.submit.
  -- `confirm` is kept above for TITLE and OVER because start / play-again are the
  -- only beats that are not a language target.
end

function on_voice_event(e)
  if not S then return end
  if type(e) ~= "table" then
    print("word_maze: raw voice event " .. tostring(e))
    return
  end
  if e.type == "error" then
    view.voice_ok = false
    S.voice_ok = false
    led_set_base(LED.RED)
    return
  end
  -- Only keyword-spotting results carry a command, matching word_racer. The
  -- "unavailable" status below is delivered on this same event type, so the
  -- filter sits above it rather than at the top of the hook.
  if e.type ~= "VOICE_COMMAND" then return end
  local data = e.data
  if type(data) ~= "table" then return end
  if data.status == "unavailable" then
    view.voice_ok = false
    S.voice_ok = false
    print("word_maze: voice unavailable, cannot play")
    led_set_base(LED.RED)
    return
  end
  if not data.keyword then return end

  -- A command arrived, so voice is working after all: clear the warning. This
  -- covers a backend that connects slightly after game_start.
  if not view.voice_ok then
    view.voice_ok = true
    S.voice_ok = true
    view.last_scene = nil            -- drop the voice-error notice from the panel
    print("word_maze: voice active")
    -- Restoring the flag is not enough: every reopen was skipped while it was
    -- false, so the registered vocabulary is whatever was last pushed and may
    -- be several maps stale -- a wrong topic makes all six word chips
    -- unrecognisable, and a gate sentence would never have been registered at
    -- all. Push the set for the state the game is actually in; this also sets
    -- the LED base back to blue, so no separate led_set_base is needed.
    push_keywords()
  end

  led_start_flash()
  local kw = Curriculum.clean(data.keyword)
  local before_scene = S.scene
  if Rules.submit(S, kw) then
    drain_events()
    refresh_targets()
    -- The target changed (new cell, fight opened, gate reached), so refresh the
    -- vocabulary the backend is listening for.
    if S.scene ~= before_scene or S.fight > 0 then
      -- The reopen runs voice_stop() -> led_stop(), which drops the base colour
      -- AND the flash started above. word_racer never hits this because its only
      -- reopen is at a round boundary, far from any acknowledgement blink; here a
      -- reopen fires on the same beat as the keyword. Re-arm the flash afterwards
      -- so the child still gets the "heard you" blink on the beats that matter
      -- most -- moving, entering a fight, opening the gate.
      if push_keywords() then led_start_flash() end
    end
  end
end

function on_home()
  return false                       -- short HOME press exits to the menu
end

function game_end()
  voice_stop()
  if Speaker and Speaker.stop_all then Speaker.stop_all() end
  if Servo and Servo.stop then Servo.stop() end
  destroy_chrome()
  destroy_pools()
  S = nil
  print("word_maze: game_end")
end
