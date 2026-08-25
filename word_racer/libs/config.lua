local C = {
  SCREEN_H = 320,

  ROAD_LEFT = 96,
  ROAD_RIGHT = 384,
  -- Centres of the three playable lanes at the player's vertical position.
  -- Their straight trajectories converge at the portal centre.
  -- Measured from background.png at the player's vertical centre (y=251):
  -- road boundaries are x~=57,184,292,422, so these are their lane midpoints.
  LANE_X = { 120, 239, 358 },
  PORTAL_X = 240,
  PORTAL_Y = 92,
  LANE_FOCUS_X = 239,
  LANE_FOCUS_Y = 106,
  LANE_SPREAD_PER_Y = 0.82,
  LANE_W = 160,
  CAR_W = 54,
  CAR_H = 46,
  CAR_Y = 228,

  -- Collision uses a stable inner rectangle, independent of the ship's visual
  -- bob/bank animation. It excludes PIKA's ears, wing tips and engine flames.
  PIKA_HITBOX_W = 36,
  PIKA_HITBOX_H = 34,
  PIKA_HITBOX_YOFF = 8,
  SHIELD_HITBOX_EXPAND = 5,

  -- Item art was authored on a padded 34x30 / 32x30 canvas and the padding was
  -- filled with the road colour (raw RGB565 has no alpha). The blobs are now
  -- cropped to their content, so each kind carries its own size and the frame no
  -- longer stands in for the artwork. ITEM_SPAWN_H is only a spawn/queue pitch.
  ITEM_SPAWN_H = 30,
  -- Collision padding: the coin is 15 px tall, so testing the old 30 px frame
  -- collected it across twice its visible height. 4 px keeps pickup forgiving
  -- (DoD mercy mechanics) without the "collected it without touching" feel.
  PICKUP_GRACE = 4,
  OBSTACLE_GRACE = -2,
  COLLISION_SCALE = {
    obstacle      = 0.78,
    coin          = 0.85,
    crystal       = 0.85,
    magnet        = 0.82,
    shooting_star = 0.82,
    armor         = 0.85,
    heart         = 0.85,
  },

  -- `yoff` = where the artwork used to sit inside its padded canvas. The blob's
  -- top is now the artwork's top, so adding yoff back keeps every item on the
  -- exact same on-screen trajectory (and the same pickup moment) as before the
  -- crop. Without it a coin would ride 8 px higher than it always has.
  ITEM_SIZE = {
    coin          = { w = 20, h = 20, yoff = 0 },
    crystal       = { w = 22, h = 22, yoff = 0 },
    magnet        = { w = 22, h = 31, yoff = 0 },
    shooting_star = { w = 28, h = 28, yoff = 0 },
    armor         = { w = 24, h = 24, yoff = 0 },
    heart         = { w = 24, h = 22, yoff = 0 },
    obstacle      = { w = 44, h = 38, yoff = 0 },
  },

  BASE_SPEED = 46,
  SPEED_PER_ROUND = 3.2,
  FAR_SPEED_K = 0.38,
  SPEED_RAMP_MAX = 0.5,
  SPEED_RAMP_SEC = 450,
  WAVE_MIN_MS = 1800,
  WAVE_MAX_MS = 2800,
  ROUND_WAVES_MIN = 6,
  ROUND_WAVES_RAND = 3,
  CHECKPOINT_RETRY_WAVES_MIN = 3,
  CHECKPOINT_RETRY_WAVES_RAND = 2,
  DEPARTURE_MS = 1400,
  FLIGHT_BOB_PX = 2,
  FLIGHT_BOB_PERIOD_MS = 900,
  FLIGHT_BANK_PX = 3,
  FLIGHT_BANK_MS = 260,
  FLIGHT_PULSE_OPACITY = 8,

  MAX_LIVES = 3,
  INVINCIBLE_MS = 1200,
  MAGNET_MS = 5000,
  A2A_EXIT_HOLD_MS = 1800,

  OBS_POOL = 8,
  COIN_POOL = 5,
  VOICE_SENSITIVITY = 10,
  SFX_ENABLED = true,

  -- SFX arbitration. The engine serves one channel and rejects any play within
  -- GAME_SOUND_PLAY_COOLDOWN_US (80 ms) of the previous one, so back-to-back
  -- events silently lose a sound. Ranking decides which one that is: a louder
  -- event may cut a quieter one, never the reverse. Ties go to whoever asked
  -- first, so a burst of coins does not stutter.
  SFX_COOLDOWN_MS = 80,
  SFX_PRIO = {
    over    = 40, record  = 40,   -- run is ending; nothing outranks it
    crash   = 30,                 -- losing a life must always be heard
    smash   = 20, boss    = 20, start = 20,
    powerup = 15, shield  = 15,
    coin    = 10, lane    = 10, tick = 10,
  },
  SFX_PRIO_DEFAULT = 10,
  -- A high-priority sound blocked by the cooldown is retried for this long
  -- instead of being dropped, so `crash` still lands ~1 frame late rather than
  -- never. Below this rank a blocked sound is simply discarded.
  SFX_RETRY_MIN_PRIO = 30,
  SFX_RETRY_MS = 220,

  ASSET = "assets/runtime/",

  COL_OVER_TITLE = 0xFF4A4A,
  COL_WIN_TITLE = 0x7FD0FF,
}

return C
