--!native
-- DOOM Runner with EditableImage Display Backend + Sound Interception
-- Replaces the js_draw_screen framebuffer mechanism with
-- AssetService:CreateEditableImage + WritePixelsBuffer
-- Intercepts S_StartSound to route Doom SFX to Roblox Sound instances

local SoundService = game:GetService("SoundService")
local AssetService = game:GetService("AssetService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

-- ========== SOUND INTERCEPTION SYSTEM ==========
-- 1. Configuration: Map Doom sfx_id (integer) to Roblox rbxassetid:// strings
-- Doom sfx_ids are 0-based indices into the sfxinfo_t array
-- See s_sound.c / sounds.h in the Doom source for the full enum
local DOOM_SOUND_MAPPING = {
	[0]  = "rbxassetid://119126617283151", -- sfx_shotgn 119126617283151
	[1]  = "rbxassetid://196561491", -- sfx_pistol
	[2]  = "rbxassetid://15120932483", -- sfx_sgcock 15120932483
	[3]  = "rbxassetid://0", -- sfx_dshtgn
	[4]  = "rbxassetid://0", -- sfx_dbopn
	[5]  = "rbxassetid://0", -- sfx_dbcls
	[6]  = "rbxassetid://0", -- sfx_dbload
	[7]  = "rbxassetid://0", -- sfx_plasma
	[8]  = "rbxassetid://0", -- sfx_bfg
	[9]  = "rbxassetid://0", -- sfx_sawup
	[10] = "rbxassetid://0", -- sfx_sawidl
	[11] = "rbxassetid://0", -- sfx_sawful
	[12] = "rbxassetid://0", -- sfx_sawhit
	[13] = "rbxassetid://0", -- sfx_rlaunc
	[14] = "rbxassetid://0", -- sfx_rxplod
	[15] = "rbxassetid://0", -- sfx_firxpl
	[16] = "rbxassetid://0", -- sfx_pstart
	[17] = "rbxassetid://0", -- sfx_pstop
	[18] = "rbxassetid://0", -- sfx_doorup
	[19] = "rbxassetid://0", -- sfx_doordn
	[20] = "rbxassetid://0", -- sfx_doropn
	[21] = "rbxassetid://0", -- sfx_dorcls
	[22] = "rbxassetid://0", -- sfx_stnmov
	[23] = "rbxassetid://0", -- sfx_swtchn
	[24] = "rbxassetid://0", -- sfx_swtchx
	[25] = "rbxassetid://0", -- sfx_plpain
	[26] = "rbxassetid://0", -- sfx_dmpain
	[27] = "rbxassetid://0", -- sfx_popain
	[28] = "rbxassetid://0", -- sfx_slop
	[29] = "rbxassetid://0", -- sfx_itemup
	[30] = "rbxassetid://0", -- sfx_wpnup
	[31] = "rbxassetid://0", -- sfx_oof
	[32] = "rbxassetid://0", -- sfx_noway
	[33] = "rbxassetid://0", -- sfx_punch
	[34] = "rbxassetid://0", -- sfx_tink
}

-- 2. Pre-load Roblox Sound instances into a cache folder
local soundFolder = Instance.new("Folder")
soundFolder.Name = "DoomSFX"
soundFolder.Parent = SoundService

local soundCache = {}
for id, assetId in pairs(DOOM_SOUND_MAPPING) do
	if assetId ~= "rbxassetid://0" then
		local sound = Instance.new("Sound")
		sound.Name = "DoomSFX_" .. id
		sound.SoundId = assetId
		sound.Volume = 0.75
		sound.Parent = soundFolder
		soundCache[id] = sound
	end
end

-- 3. Per-SFX volume offsets (multiplier applied on top of engine volume)
-- Adjust these to taste — 1.0 = no change, 0.5 = half, 2.0 = double
local DOOM_SOUND_VOLUME_OFFSETS = {
	[0]  = 1.0,  -- sfx_shotgn
	[1]  = 1.0,  -- sfx_pistol
	[2]  = 1.0,  -- sfx_sgcock
	[3]  = 1.0,  -- sfx_dshtgn
	[4]  = 1.0,  -- sfx_dbopn
	[5]  = 1.0,  -- sfx_dbcls
	[6]  = 1.0,  -- sfx_dbload
	[7]  = 1.0,  -- sfx_plasma
	[8]  = 1.0,  -- sfx_bfg
	[9]  = 1.0,  -- sfx_sawup
	[10] = 1.0,  -- sfx_sawidl
	[11] = 1.0,  -- sfx_sawful
	[12] = 1.0,  -- sfx_sawhit
	[13] = 1.0,  -- sfx_rlaunc
	[14] = 1.0,  -- sfx_rxplod
	[15] = 1.0,  -- sfx_firxpl
	[16] = 1.0,  -- sfx_pstart
	[17] = 1.0,  -- sfx_pstop
	[18] = 1.0,  -- sfx_doorup
	[19] = 1.0,  -- sfx_doordn
	[20] = 1.0,  -- sfx_doropn
	[21] = 1.0,  -- sfx_dorcls
	[22] = 1.0,  -- sfx_stnmov
	[23] = 1.0,  -- sfx_swtchn
	[24] = 1.0,  -- sfx_swtchx
	[25] = 1.0,  -- sfx_plpain
	[26] = 1.0,  -- sfx_dmpain
	[27] = 1.0,  -- sfx_popain
	[28] = 1.0,  -- sfx_slop
	[29] = 1.0,  -- sfx_itemup
	[30] = 1.0,  -- sfx_wpnup
	[31] = 1.0,  -- sfx_oof
	[32] = 1.0,  -- sfx_noway
	[33] = 1.0,  -- sfx_punch
	[34] = 1.0,  -- sfx_tink
}

-- 4. Playback function called by the intercepted S_StartSound
-- sfx_id: the Doom sound effect index (0-based)
-- volume: 0-127 from the engine (we map to Roblox 0-1)
local function playDoomSound(sfx_id, volume)
	local sound = soundCache[sfx_id]
	if not sound then return end
	local offset = DOOM_SOUND_VOLUME_OFFSETS[sfx_id] or 1.0
	sound.Volume = math.clamp((volume or 127) / 127 * offset, 0, 10)
	sound.TimePosition = 0
	sound:Play()
end

-- ========== MUSIC INTERCEPTION SYSTEM ==========
-- Doom musicenum_t indices (from sounds.h)
-- These are the integer IDs passed to S_ChangeMusic
local DOOM_MUSIC_MAPPING = {
	[0]  = "rbxassetid://106638393006046", -- mus_e1m1 "At Doom's Gate" 
	[1]  = "rbxassetid://0", -- mus_e1m2 "Dark Halls"
	[2]  = "rbxassetid://0", -- mus_e1m3 "Unhallowed"
	[3]  = "rbxassetid://0", -- mus_e1m4 "Techbase"
	[4]  = "rbxassetid://0", -- mus_e1m5 "Phobos"
	[5]  = "rbxassetid://0", -- mus_e1m6 "Halls of Hell"
	[6]  = "rbxassetid://0", -- mus_e1m7 "Hell's Bells"
	[7]  = "rbxassetid://0", -- mus_e1m8 "Sign of Evil"
	[8]  = "rbxassetid://0", -- mus_e1m9 "Untitled"
	[9]  = "rbxassetid://0", -- mus_e2m1 "Running Free"
	[10] = "rbxassetid://0", -- mus_e2m2 "The Healer Stalks"
	[11] = "rbxassetid://0", -- mus_e2m3 "Into the Darkness"
	[12] = "rbxassetid://0", -- mus_e2m4 "The Demons Are Here"
	[13] = "rbxassetid://0", -- mus_e2m5 "The March of the Demons"
	[14] = "rbxassetid://0", -- mus_e2m6 "Death's Bells"
	[15] = "rbxassetid://0", -- mus_e2m7 "Into Sandy's City"
	[16] = "rbxassetid://0", -- mus_e2m8 "The Chasm"
	[17] = "rbxassetid://0", -- mus_e2m9 "Spooky"
	[18] = "rbxassetid://0", -- mus_e3m1 "Evil Incarnate"
	[19] = "rbxassetid://0", -- mus_e3m2 "The Catacombs"
	[20] = "rbxassetid://0", -- mus_e3m3 "Nightmare"
	[21] = "rbxassetid://0", -- mus_e3m4 "The Healer"
	[22] = "rbxassetid://0", -- mus_e3m5 "Don't Suffer"
	[23] = "rbxassetid://0", -- mus_e3m6 "Waltz of the Demons"
	[24] = "rbxassetid://0", -- mus_e3m7 "More Evil"
	[25] = "rbxassetid://0", -- mus_e3m8 "The End?"
	[26] = "rbxassetid://0", -- mus_e3m9 "Untitled"
	[27] = "rbxassetid://0", -- mus_inter (intermission)
	[28] = "rbxassetid://115796599337543", -- mus_intro (title screen)
	[29] = "rbxassetid://0", -- mus_victory (victory screen)
	[30] = "rbxassetid://0", -- mus_introa (alternate intro)
}

-- Pre-load Roblox Music Sound instances
local musicFolder = Instance.new("Folder")
musicFolder.Name = "DoomMusic"
musicFolder.Parent = SoundService

local musicCache = {}
local currentMusic = nil
local currentMusicId = -1

for id, assetId in pairs(DOOM_MUSIC_MAPPING) do
	if assetId ~= "rbxassetid://0" then
		local sound = Instance.new("Sound")
		sound.Name = "DoomMusic_" .. id
		sound.SoundId = assetId
		sound.Volume = 0.5
		sound.Looped = true
		sound.Parent = musicFolder
		musicCache[id] = sound
	end
end

-- Title screen protection: the Doom engine plays demo gameplay on the
-- title screen which calls S_ChangeMusic with level music (indices 0-26),
-- overriding the intro. We suppress level music until the player actually
-- enters a level, so the intro theme plays properly on the title screen.
local MUS_INTRO = 28
local playerInGame = false
local lastSuppressedMusic = nil

-- DOOM gamestate constants (address 5277176 in WASM memory)
local GAMESTATE_ADDR = 5277176
local GS_DEMOSCREEN = 0
local GS_LEVEL = 1
local GS_INTERMISSION = 2
local GS_FINALE = 3
local lastGamestate = GS_DEMOSCREEN

-- Play a Doom music track by its musicenum_t index
local function playDoomMusic(music_num, looping)
	local sound = musicCache[music_num]

	-- If the requested track isn't in our Roblox cache, don't stop
	-- whatever is currently playing — just ignore the request.
	if not sound then
		return
	end

	-- Already playing this exact track? Skip.
	if currentMusicId == music_num and currentMusic and currentMusic.IsPlaying then
		return
	end

	-- Title screen protection: if the intro is playing and a level track
	-- (indices 0-26) is requested, it's the title screen demo — ignore it
	-- so the intro keeps playing. Once the player enters a game
	-- (playerInGame = true), level music plays normally.
	if not playerInGame and music_num >= 0 and music_num <= 26 then
		lastSuppressedMusic = music_num
		return false
	end

	-- Stop current music before switching
	if currentMusic and currentMusic.IsPlaying then
		currentMusic:Stop()
	end

	sound.Looped = looping ~= 0
	sound.TimePosition = 0
	sound:Play()
	currentMusic = sound
	currentMusicId = music_num
end

-- Gamestate-driven level music control:
-- Poll the DOOM gamestate each frame to detect level transitions.
-- When gamestate -> GS_LEVEL: player entered a level, enable level music.
-- When gamestate leaves GS_LEVEL: level ended, stop level music.
-- (Function body defined later, after wasmMemory is available)
local pollGamestate

-- ========== DISPLAY SETUP ==========
local part = Instance.new("Part") part.Parent = workspace part.Size = Vector3.new(15, 7.5, 0.25) part.Position = Vector3.new(0, 0, 2) part.Orientation = Vector3.new(0, -180, 0) part.Anchored = true

-- Constants for the DOOM framebuffer
local SCREEN_WIDTH = 320
local SCREEN_HEIGHT = 200
local FRAMEBUFFER_ADDR = 6632176 -- pointer to 320x200 palette-indexed framebuffer (stores a u32 pointer, not the data itself)
local PALETTE_ADDR = 5277180 -- 256 RGBA entries (4 bytes each)
local GAMMA_ADDR = 6375408 -- 5 gamma tables (256 bytes each, palette_num 0-4)
local PALETTE_NUM_ADDR = 6632196 -- current gamma/palette number (0-4)
local WASM_PAGE_SIZE = 65536

-- Pre-allocate the pixel buffer (320*200*4 = 256000 bytes)
local pixelBuffer = buffer.create(SCREEN_WIDTH * SCREEN_HEIGHT * 4)

-- ========== OPTIMIZED RENDERING: PALETTE CACHE ==========
-- Cache the 256-entry RGBA palette as a Lua table for fast lookup.
-- Updated by our replacement I_SetPalette, read by our replacement I_FinishUpdate.
-- This avoids going through WASM rt_load/rt_store wrappers for every pixel.
local paletteCache = table.create(256)
for i = 0, 255 do
	paletteCache[i] = 0xFF000000 -- default: opaque black
end

-- Pre-compute destination row offset table to avoid multiplication in the hot loop
local dstRowOffsets = table.create(SCREEN_HEIGHT)
for y = 0, SCREEN_HEIGHT - 1 do
	dstRowOffsets[y] = y * SCREEN_WIDTH * 4
end

-- Create the display UI
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "DoomScreen"
screenGui.IgnoreGuiInset = true
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

local imageLabel = Instance.new("ImageLabel")
imageLabel.Name = "DoomDisplay"
imageLabel.ScaleType = "Fit"
imageLabel.Size = UDim2.new(1, 0, 1, 0)
imageLabel.Position = UDim2.new(0, 0, 0, 0)
imageLabel.BackgroundColor3 = Color3.new(0, 0, 0)
imageLabel.Parent = screenGui

-- Create the EditableImage (320x200)
local editableImage = AssetService:CreateEditableImage({
	Size = Vector2.new(SCREEN_WIDTH, SCREEN_HEIGHT)
})

if editableImage then
	-- New EditableImage API
	if imageLabel:FindFirstChildWhichIsA("UIAspectRatioConstraint") == nil then
	end

	pcall(function()
		imageLabel.ImageContent = Content.fromObject(editableImage)
	end)
else
	warn("[DOOM] Failed to create EditableImage - display will not work")
end

-- Create WASM memory (256 pages = 16MB, max 512 pages = 32MB)
local memoryPages = 256
local maxPages = 512
local memoryData = buffer.create(memoryPages * WASM_PAGE_SIZE)
local memory = { data = memoryData, max = maxPages }

-- Reference to WASM memory for native rendering
local wasmMemory = memory

-- ========== OPTIMIZED RENDERING: NATIVE I_FinishUpdate ==========
-- Replaces the WASM I_FinishUpdate + js_draw_screen pipeline with a single
-- native Luau function that:
--   1. Reads the palette-indexed framebuffer directly from WASM memory
--   2. Looks up RGBA from the cached palette table (Lua table, faster than buffer reads)
--   3. Writes directly to pixelBuffer (tight 1280-byte stride, no intermediate buffer)
--   4. Calls WritePixelsBuffer once
--
-- This eliminates:
--   - 64,000 WASM rt_load_i32_u8 calls for palette index lookup
--   - 64,000 WASM rt_load_i32 calls for RGBA palette lookup
--   - 256,000 WASM rt_store_i32 calls to the intermediate 5120-stride buffer
--   - 64,000 buffer.readu32 calls in js_draw_screen for stride compaction
--   - 64,000 buffer.writeu32 calls in js_draw_screen for pixel compaction
--   - The entire 1,024,000-byte intermediate buffer write/read cycle

local function nativeFinishUpdate()
	if not editableImage then return end

	local mem = wasmMemory.data
	local pxBuf = pixelBuffer
	local pal = paletteCache

	-- Read the framebuffer pointer from WASM memory.
	-- Address 6632176 stores a POINTER to the palette-indexed framebuffer,
	-- not the data itself (the WASM I_FinishUpdate does rt_load_i32 at this addr).
	local fbPtr = buffer.readu32(mem, FRAMEBUFFER_ADDR)

	for y = 0, SCREEN_HEIGHT - 1 do
		local srcBase = fbPtr + y * SCREEN_WIDTH
		local dstBase = dstRowOffsets[y]

		-- Process 320 pixels per row, unrolled 8x to reduce loop overhead
		local x = 0
		while x < 320 do
			buffer.writeu32(pxBuf, dstBase + x * 4,     pal[buffer.readu8(mem, srcBase + x)])
			buffer.writeu32(pxBuf, dstBase + x * 4 + 4,  pal[buffer.readu8(mem, srcBase + x + 1)])
			buffer.writeu32(pxBuf, dstBase + x * 4 + 8,  pal[buffer.readu8(mem, srcBase + x + 2)])
			buffer.writeu32(pxBuf, dstBase + x * 4 + 12, pal[buffer.readu8(mem, srcBase + x + 3)])
			buffer.writeu32(pxBuf, dstBase + x * 4 + 16, pal[buffer.readu8(mem, srcBase + x + 4)])
			buffer.writeu32(pxBuf, dstBase + x * 4 + 20, pal[buffer.readu8(mem, srcBase + x + 5)])
			buffer.writeu32(pxBuf, dstBase + x * 4 + 24, pal[buffer.readu8(mem, srcBase + x + 6)])
			buffer.writeu32(pxBuf, dstBase + x * 4 + 28, pal[buffer.readu8(mem, srcBase + x + 7)])
			x = x + 8
		end
	end

	editableImage:WritePixelsBuffer(Vector2.new(0, 0), Vector2.new(SCREEN_WIDTH, SCREEN_HEIGHT), pxBuf)
end

-- ========== OPTIMIZED RENDERING: NATIVE I_SetPalette ==========
-- Replaces the WASM I_SetPalette with a native Luau function that:
--   1. Reads the 768-byte RGB palette from WASM memory (3 bytes per entry)
--   2. Converts to 256 RGBA u32 values and stores in paletteCache
--   3. Also writes to the WASM palette at 5277180 for consistency
--
-- This avoids the complex WASM control flow and rt_load/rt_store wrappers.
-- I_SetPalette is called rarely (only on palette changes like pain/pickup flashes),
-- so this isn't a hot path, but keeping it native ensures no WASM overhead.

local function nativeSetPalette(palettePtr)
	local mem = wasmMemory.data
	local pal = paletteCache

	-- Read the current gamma/palette number (0-4)
	local paletteNum = buffer.readu32(mem, PALETTE_NUM_ADDR)
	if paletteNum > 4 then paletteNum = 0 end

	-- Gamma table base address for the current palette number
	local gammaBase = GAMMA_ADDR + paletteNum * 256

	-- DOOM palette: 768 bytes = 256 entries * 3 bytes (R, G, B)
	-- Convert to RGBA u32 values with gamma correction applied
	for i = 0, 255 do
		local r = buffer.readu8(mem, palettePtr + i * 3)
		local g = buffer.readu8(mem, palettePtr + i * 3 + 1)
		local b = buffer.readu8(mem, palettePtr + i * 3 + 2)

		-- Apply gamma correction lookup
		local gr = buffer.readu8(mem, gammaBase + r)
		local gg = buffer.readu8(mem, gammaBase + g)
		local gb = buffer.readu8(mem, gammaBase + b)

		-- RGBA as little-endian u32: R | (G << 8) | (B << 16) | (0xFF << 24)
		local rgba = gr + gg * 256 + gb * 65536 + 0xFF000000
		pal[i] = rgba

		-- Also write to WASM palette memory at 5277180 for consistency
		-- (in case any WASM code reads it directly)
		buffer.writeu32(mem, PALETTE_ADDR + i * 4, rgba)
	end
end

-- DOOM event type constants (from the WASM source port's JavaScript)
-- NOTE: KeyDown=0, KeyUp=1 (NOT 1 and 2 like the original DOOM source)
local EV_KEYDOWN = 0
local EV_KEYUP = 1

-- DOOM key constants matching the WASM source port's doomKeyCode() function
-- Arrow keys use 0xAC-0xAF (NOT 0x80+0x18-0x1B from doomdef.h)
local KEY_LEFTARROW = 0xAC
local KEY_UPARROW = 0xAD
local KEY_RIGHTARROW = 0xAE
local KEY_DOWNARROW = 0xAF
local KEY_RCTRL = 0x80 + 0x1D
local KEY_RALT = 0x80 + 0x38
local KEY_RSHIFT = 0x80 + 0x36
local KEY_BACKSPACE = 127

-- Map Roblox key codes to DOOM key codes
-- Matches the WASM source port's doomKeyCode() JavaScript function exactly
local keyMap = {
	[Enum.KeyCode.Escape] = 27,
	[Enum.KeyCode.ButtonSelect] = 27,
	[Enum.KeyCode.Return] = 13,
	[Enum.KeyCode.ButtonA] = 13,	
	[Enum.KeyCode.Tab] = 9,
	[Enum.KeyCode.ButtonL2] = 9,
	[Enum.KeyCode.Space] = 32,
	[Enum.KeyCode.ButtonB] = 32,
	[Enum.KeyCode.Backspace] = KEY_BACKSPACE,
	[Enum.KeyCode.Up] = KEY_UPARROW,
	[Enum.KeyCode.Down] = KEY_DOWNARROW,
	[Enum.KeyCode.Left] = KEY_LEFTARROW,
	[Enum.KeyCode.Right] = KEY_RIGHTARROW,
	[Enum.KeyCode.DPadUp] = KEY_UPARROW,
	[Enum.KeyCode.DPadDown] = KEY_DOWNARROW,
	[Enum.KeyCode.DPadLeft] = KEY_LEFTARROW,
	[Enum.KeyCode.DPadRight] = KEY_RIGHTARROW,
	[Enum.KeyCode.LeftShift] = KEY_RSHIFT,
	[Enum.KeyCode.RightShift] = KEY_RSHIFT,
	[Enum.KeyCode.ButtonX] = KEY_RSHIFT,
	[Enum.KeyCode.LeftControl] = KEY_RCTRL,
	[Enum.KeyCode.RightControl] = KEY_RCTRL,
	[Enum.KeyCode.ButtonR2] = KEY_RCTRL,
	[Enum.KeyCode.LeftAlt] = KEY_RALT,
	[Enum.KeyCode.ButtonY] = KEY_RALT,
	[Enum.KeyCode.RightAlt] = KEY_RALT,
	[Enum.KeyCode.F1] = 112 + 75,
	[Enum.KeyCode.F2] = 113 + 75,
	[Enum.KeyCode.F3] = 114 + 75,
	[Enum.KeyCode.F4] = 115 + 75,
	[Enum.KeyCode.F5] = 116 + 75,
	[Enum.KeyCode.F6] = 117 + 75,
	[Enum.KeyCode.F7] = 118 + 75,
	[Enum.KeyCode.F8] = 119 + 75,
	[Enum.KeyCode.F9] = 120 + 75,
	[Enum.KeyCode.F10] = 121 + 75,
	[Enum.KeyCode.F11] = 122 + 75,
	[Enum.KeyCode.F12] = 123 + 75,
	[Enum.KeyCode.Equals] = 61,
	[Enum.KeyCode.Minus] = 45,
	[Enum.KeyCode.Pause] = 19,
	[Enum.KeyCode.A] = 97,
	[Enum.KeyCode.B] = 98,
	[Enum.KeyCode.C] = 99,
	[Enum.KeyCode.D] = 100,
	[Enum.KeyCode.E] = 101,
	[Enum.KeyCode.F] = 102,
	[Enum.KeyCode.G] = 103,
	[Enum.KeyCode.H] = 104,
	[Enum.KeyCode.I] = 105,
	[Enum.KeyCode.J] = 106,
	[Enum.KeyCode.K] = 107,
	[Enum.KeyCode.L] = 108,
	[Enum.KeyCode.M] = 109,
	[Enum.KeyCode.N] = 110,
	[Enum.KeyCode.O] = 111,
	[Enum.KeyCode.P] = 112,
	[Enum.KeyCode.Q] = 113,
	[Enum.KeyCode.R] = 114,
	[Enum.KeyCode.S] = 115,
	[Enum.KeyCode.T] = 116,
	[Enum.KeyCode.U] = 117,
	[Enum.KeyCode.V] = 118,
	[Enum.KeyCode.W] = 119,
	[Enum.KeyCode.X] = 120,
	[Enum.KeyCode.Y] = 121,
	[Enum.KeyCode.Z] = 122,
	[Enum.KeyCode.One] = 49,
	[Enum.KeyCode.Two] = 50,
	[Enum.KeyCode.Three] = 51,
	[Enum.KeyCode.Four] = 52,
	[Enum.KeyCode.Five] = 53,
	[Enum.KeyCode.Six] = 54,
	[Enum.KeyCode.Seven] = 55,
	[Enum.KeyCode.Eight] = 56,
	[Enum.KeyCode.Nine] = 57,
	[Enum.KeyCode.Zero] = 48,
	[Enum.KeyCode.Comma] = 44,
	[Enum.KeyCode.ButtonL1] = 44,
	[Enum.KeyCode.Period] = 46,
	[Enum.KeyCode.ButtonR1] = 46,
	[Enum.KeyCode.Slash] = 47,
	[Enum.KeyCode.Semicolon] = 59,
	[Enum.KeyCode.Quote] = 39,
	[Enum.KeyCode.LeftBracket] = 91,
	[Enum.KeyCode.RightBracket] = 93,
	[Enum.KeyCode.BackSlash] = 92,
}

-- Handle input events
local pendingEvents = {}
local inputState = {}



UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	-- Keyboard
	local doomKey = keyMap[input.KeyCode]
	if doomKey then
		inputState[doomKey] = true
		table.insert(pendingEvents, { type = EV_KEYDOWN, key = doomKey })
		return
	end

end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	local doomKey = keyMap[input.KeyCode]
	if doomKey then
		inputState[doomKey] = false
		table.insert(pendingEvents, { type = EV_KEYUP, key = doomKey })
		return
	end

end)

-- Set up the WASM environment
local wasm = {
	["js"] = {
		func_list = {
			["js_milliseconds_since_start"] = function()
				return math.floor(tick() * 1000)
			end,
			["js_console_log"] = function(msg)
				print("[DOOM]", msg)
			end,
			["js_draw_screen"] = function() end, -- no-op: native I_FinishUpdate handles rendering directly
			["js_stdout"] = function(msg)
				print("[DOOM stdout]", msg)
			end,
			["js_stderr"] = function(msg)
				warn("[DOOM stderr]", msg)
			end,
		},
	},
	["env"] = {
		memory_list = {
			["memory"] = memory,
		},
		func_list = {},
		table_list = {},
		global_list = {},
	},
}

-- Define missing Wasynth runtime function (compiler bug: wasm_div_f64 was never defined)
wasm_div_f64 = function(lhs, rhs)
	return lhs / rhs
end



-- Require and initialize the DOOM module
local DOOM = require(game.ReplicatedStorage.DOOM)

local function runDoomSession()
	local doom = DOOM(wasm)

	-- ========== SOUND INTERCEPTION HOOK ==========
	-- Replace S_StartSound (FUNC_LIST[765]) with a wrapper that
	-- also triggers the Roblox sound cache.
	-- FUNC_LIST[765] signature: S_StartSound(origin_ptr, sfx_id)
	-- It internally calls S_StartSoundAtVolume with default volume.
	local FL = doom._FUNC_LIST
	if FL then
		local origSStartSound = FL[765]
		FL[765] = function(origin_ptr, sfx_id)
			-- Fire the Roblox sound (non-blocking)
			local vol = 127 -- default full volume; S_StartSoundAtVolume reads this
			playDoomSound(sfx_id, vol)
			-- Call the original S_StartSound so the engine stays consistent
			return origSStartSound(origin_ptr, sfx_id)
		end

		-- Also hook S_StartSoundAtVolume (FUNC_LIST[761]) for volume accuracy
		-- Signature: S_StartSoundAtVolume(origin_ptr, sfx_id, volume)
		local origSStartSoundAtVol = FL[761]
		FL[761] = function(origin_ptr, sfx_id, volume)
			playDoomSound(sfx_id, volume)
			return origSStartSoundAtVol(origin_ptr, sfx_id, volume)
		end

		print("[DOOM] Sound interception hooks installed")

		-- ========== MUSIC INTERCEPTION HOOK ==========
		-- Hook S_ChangeMusic (FUNC_LIST[695]) to route Doom music to Roblox
		-- Signature: S_ChangeMusic(music_num, looping)
		local origSChangeMusic = FL[695]
		if origSChangeMusic then
			FL[695] = function(music_num, looping)
				playDoomMusic(music_num, looping)
				return origSChangeMusic(music_num, looping)
			end
			print("[DOOM] Music interception hook installed (S_ChangeMusic)")
		end

		-- Also hook S_PlayMusicData (FUNC_LIST[696]) as a fallback
		-- This is the low-level register+play wrapper
		local origSPlayMusicData = FL[696]
		if origSPlayMusicData then
			FL[696] = function(data, looping)
				-- We can't easily determine the music_num from data pointer,
				-- so we rely on the S_ChangeMusic hook above for track ID.
				-- This hook ensures the engine's internal music state stays consistent.
				return origSPlayMusicData(data, looping)
			end
		end
	else
		warn("[DOOM] _FUNC_LIST not exposed — sound hooks not installed")
	end

	-- ========== OPTIMIZED RENDERING HOOKS ==========
	-- Replace WASM I_FinishUpdate (FUNC_LIST[211]) and I_SetPalette (FUNC_LIST[210])
	-- with native Luau implementations that bypass the slow WASM palette conversion
	-- and intermediate buffer, writing directly to the EditableImage pixel buffer.
	local FL = doom._FUNC_LIST
	if FL then
		-- I_FinishUpdate: instead of the WASM palette lookup + intermediate buffer,
		-- our native version reads the framebuffer directly and writes to pixelBuffer.
		FL[211] = nativeFinishUpdate

		-- I_SetPalette: instead of the complex WASM control flow,
		-- our native version reads the 768-byte RGB palette and caches it.
		FL[210] = nativeSetPalette

		print("[DOOM] Optimized rendering hooks installed (native I_FinishUpdate + I_SetPalette)")
	else
		warn("[DOOM] _FUNC_LIST not exposed — rendering hooks not installed")
	end

	local doomMain = doom.func_list["main"]
	local doomLoopStep = doom.func_list["doom_loop_step"]
	local addBrowserEvent = doom.func_list["add_browser_event"]

	-- Initialize the game
	print("[DOOM] Initializing...")
	local ok, err = pcall(function()
		doomMain(0, 0)
	end)
	if not ok then
		warn("[DOOM] Initialization error:", err)
		warn("[DOOM] Traceback:", debug.traceback())
		return
	end
	print("[DOOM] Initialized successfully. Starting game loop...")

	-- Define pollGamestate now that wasmMemory is available
	pollGamestate = function()
		local gs = buffer.readu32(wasmMemory.data, GAMESTATE_ADDR)
		if gs == GS_LEVEL and lastGamestate ~= GS_LEVEL then
			-- Level started
			playerInGame = true
			if lastSuppressedMusic then
				playDoomMusic(lastSuppressedMusic, 1)
				lastSuppressedMusic = nil
			end
		elseif gs ~= GS_LEVEL and lastGamestate == GS_LEVEL then
			-- Level ended (went to intermission, finale, or demo screen)
			playerInGame = false
			-- Stop any playing level music
			if currentMusic and currentMusic.IsPlaying and currentMusicId >= 0 and currentMusicId <= 26 then
				currentMusic:Stop()
				currentMusic = nil
				currentMusicId = -1
			end
		end
		lastGamestate = gs
	end

	-- Game loop
	while true do
		-- Process pending input events
		while #pendingEvents > 0 do
			local event = table.remove(pendingEvents, 1)
			if addBrowserEvent then
				local ok2, err2 = pcall(function()
					addBrowserEvent(event.type, event.key)
				end)
				if not ok2 then
					warn("[DOOM] Input error:", err2)
				end
			end
		end

		-- Poll gamestate for level start/end detection
		pollGamestate()

		-- Run one step of the DOOM game loop
		local ok3, err3 = pcall(doomLoopStep)
		if not ok3 then
			warn("[DOOM] Loop error:", err3)
			task.wait(1)
		end

		task.wait()
	end

	print("[DOOM] Session stopped")
end

-- Start the first session
runDoomSession()
