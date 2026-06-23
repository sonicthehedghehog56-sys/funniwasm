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
local FRAMEBUFFER_ADDR = 6632176 -- 320x200 palette-indexed framebuffer
local PALETTE_ADDR = 5277180 -- 256 RGBA entries (4 bytes each)
local WASM_PAGE_SIZE = 65536

-- Pre-allocate the pixel buffer (320*200*4 = 256000 bytes)
local pixelBuffer = buffer.create(SCREEN_WIDTH * SCREEN_HEIGHT * 4)

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

-- Reference to WASM memory for js_draw_screen
local wasmMemory = memory

-- js_draw_screen implementation using EditableImage + WritePixelsBuffer
-- I_FinishUpdate already converts the palette-indexed framebuffer to RGBA
-- and writes it to the address passed as the argument.
-- Layout: pixel (x,y) RGBA is a 32-bit LE value at addr + y*5120 + x*8
local function js_draw_screen(addr)
	if not editableImage then return end

	local mem = wasmMemory.data
	local pxBuf = pixelBuffer

	for y = 0, SCREEN_HEIGHT - 1 do
		local srcRow = addr + y * 5120
		local dstRow = y * 1280

		-- Unrolled: process 8 pixels per iteration (320 / 8 = 40, no remainder)
		local x = 0
		while x < 320 do
			local si = srcRow + x * 8
			local di = dstRow + x * 4
			buffer.writeu32(pxBuf, di,      buffer.readu32(mem, si))
			buffer.writeu32(pxBuf, di + 4,  buffer.readu32(mem, si + 8))
			buffer.writeu32(pxBuf, di + 8,  buffer.readu32(mem, si + 16))
			buffer.writeu32(pxBuf, di + 12, buffer.readu32(mem, si + 24))
			buffer.writeu32(pxBuf, di + 16, buffer.readu32(mem, si + 32))
			buffer.writeu32(pxBuf, di + 20, buffer.readu32(mem, si + 40))
			buffer.writeu32(pxBuf, di + 24, buffer.readu32(mem, si + 48))
			buffer.writeu32(pxBuf, di + 28, buffer.readu32(mem, si + 56))
			x = x + 8
		end
	end

	editableImage:WritePixelsBuffer(Vector2.new(0, 0), Vector2.new(SCREEN_WIDTH, SCREEN_HEIGHT), pxBuf)
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

-- Mouse state
local mouseDeltaX = 0
local mouseDeltaY = 0
local mouseTurnDir = 0  -- 0=none, 1=right, -1=left
local mouseTurnTics = 0
local MOUSE_SENSITIVITY = 3 -- pixels of delta per tic of turning
UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter

-- Mouse button DOOM key mapping
local mouseButtonDoomKey = {
	[Enum.UserInputType.MouseButton1] = KEY_RCTRL,  -- Left click = fire
	[Enum.UserInputType.MouseButton2] = 32,          -- Right click = use/open
	[Enum.UserInputType.MouseButton3] = KEY_RALT,   -- Middle click = strafe
}

UserInputService.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		mouseDeltaX = mouseDeltaX + input.Delta.X
		mouseDeltaY = mouseDeltaY + input.Delta.Y
	end
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	-- Keyboard
	local doomKey = keyMap[input.KeyCode]
	if doomKey then
		inputState[doomKey] = true
		table.insert(pendingEvents, { type = EV_KEYDOWN, key = doomKey })
		return
	end
	-- Mouse buttons
	local mKey = mouseButtonDoomKey[input.UserInputType]
	if mKey then
		inputState[mKey] = true
		table.insert(pendingEvents, { type = EV_KEYDOWN, key = mKey })
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
	local mKey = mouseButtonDoomKey[input.UserInputType]
	if mKey then
		inputState[mKey] = false
		table.insert(pendingEvents, { type = EV_KEYUP, key = mKey })
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
			["js_draw_screen"] = js_draw_screen,
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

-- ========== WAD Boot System ==========
local doomRunning = false
local customWadBuffer = nil
local customWadSize = 0
local CUSTOM_FD_BASE = 1000
local customOpenFiles = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function readWasmString(addr)
	local mem = wasmMemory.data
	local chars = {}
	local offset = addr
	for _ = 1, 512 do
		local b = buffer.readu8(mem, offset)
		if b == 0 then break end
		table.insert(chars, string.char(b))
		offset = offset + 1
	end
	return table.concat(chars)
end

local function isWadPath(path)
	return path:lower():sub(-4) == ".wad"
end

local function hookFilesystem(doom)
	if not customWadBuffer then return end
	local origOpen = doom.func_list["open"]
	local origRead = doom.func_list["read"]
	local origLseek = doom.func_list["lseek"]
	local origClose = doom.func_list["close"]
	local origAccess = doom.func_list["access"]
	local origFstat = doom.func_list["fstat"]
	local nextFd = CUSTOM_FD_BASE

	doom.func_list["open"] = function(pathPtr, flags, mode)
		local path = readWasmString(pathPtr)
		if isWadPath(path) then
			local fd = nextFd
			nextFd = nextFd + 1
			customOpenFiles[fd] = {pos = 0}
			print("[WAD] Opened custom WAD as fd", fd, "path:", path)
			return fd
		end
		return origOpen(pathPtr, flags, mode)
	end

	doom.func_list["read"] = function(fd, bufPtr, count)
		local file = customOpenFiles[fd]
		if file then
			local remaining = customWadSize - file.pos
			local toRead = math.min(count, remaining)
			if toRead > 0 then
				buffer.copy(wasmMemory.data, bufPtr, customWadBuffer, file.pos, toRead)
				file.pos = file.pos + toRead
			end
			return toRead
		end
		return origRead(fd, bufPtr, count)
	end

	doom.func_list["lseek"] = function(fd, offset, whence)
		local file = customOpenFiles[fd]
		if file then
			if whence == 0 then file.pos = offset
			elseif whence == 1 then file.pos = file.pos + offset
			elseif whence == 2 then file.pos = customWadSize + offset
			end
			file.pos = math.clamp(file.pos, 0, customWadSize)
			return file.pos
		end
		return origLseek(fd, offset, whence)
	end

	doom.func_list["close"] = function(fd)
		if customOpenFiles[fd] then
			customOpenFiles[fd] = nil
			return 0
		end
		return origClose(fd)
	end

	doom.func_list["access"] = function(pathPtr, mode)
		local path = readWasmString(pathPtr)
		if isWadPath(path) then return 0 end
		return origAccess(pathPtr, mode)
	end

	doom.func_list["fstat"] = function(fd, statPtr)
		local file = customOpenFiles[fd]
		if file then
			for i = 0, 143 do
				buffer.writeu8(wasmMemory.data, statPtr + i, 0)
			end
			buffer.writeu16(wasmMemory.data, statPtr + 24, 0x8124)
			buffer.writeu32(wasmMemory.data, statPtr + 60, customWadSize)
			return 0
		end
		return origFstat(fd, statPtr)
	end

	print("[WAD] Filesystem hooks installed")
end

local function setupChatHandler()
	local player = Players.LocalPlayer
	player.Chatted:Connect(function(message)
		local msg = message:match("^!bootwad%s+(.+)$")
		if msg then
			print("[WAD] Boot WAD command received, URL:", msg)
			local DownloadWad = ReplicatedStorage:FindFirstChild("DownloadWad")
			if DownloadWad then
				DownloadWad:FireServer(msg)
			else
				warn("[WAD] DownloadWad RemoteEvent not found")
			end
		end
	end)
end

local function setupWadReceiver()
	local WadChunk = ReplicatedStorage:WaitForChild("WadChunk")
	local WadReady = ReplicatedStorage:WaitForChild("WadReady")
	local chunks = {}
	local totalChunks = 0

	WadChunk.OnClientEvent:Connect(function(chunkIndex, numChunks, data)
		if chunkIndex == -1 then
			warn("[WAD] Download error:", data)
			chunks = {}
			return
		end
		totalChunks = numChunks
		chunks[chunkIndex] = data
	end)

	WadReady.OnClientEvent:Connect(function(wadSize)
		if totalChunks == 0 or #chunks == 0 then
			warn("[WAD] No chunks received")
			return
		end
		local wadString = {}
		for i = 0, totalChunks - 1 do
			if chunks[i] then
				table.insert(wadString, chunks[i])
			else
				warn("[WAD] Missing chunk", i)
				return
			end
		end
		local fullData = table.concat(wadString)
		chunks = {}
		customWadSize = #fullData
		customWadBuffer = buffer.create(customWadSize)
		buffer.writestring(customWadBuffer, 0, fullData)
		print("[WAD] Custom WAD loaded:", customWadSize, "bytes")
		doomRunning = false
	end)
end

setupChatHandler()
setupWadReceiver()

-- Require and initialize the DOOM module
local DOOM = require(game.ReplicatedStorage.DOOM)

local function runDoomSession()
	-- Reset state for new session
	customOpenFiles = {}
	local doom = DOOM(wasm)

	-- Install filesystem hooks if custom WAD is loaded
	hookFilesystem(doom)

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

	doomRunning = true

	-- Game loop
	while doomRunning do
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

		-- Convert mouse delta to arrow key turning
		if mouseDeltaX ~= 0 then
			local tics = math.clamp(math.floor(math.abs(mouseDeltaX) / MOUSE_SENSITIVITY), 1, 12)
			local newDir = mouseDeltaX > 0 and 1 or -1

			if mouseTurnDir ~= 0 and mouseTurnDir ~= newDir and addBrowserEvent then
				addBrowserEvent(EV_KEYUP, mouseTurnDir == 1 and KEY_RIGHTARROW or KEY_LEFTARROW)
			end

			mouseTurnDir = newDir
			mouseTurnTics = tics

			if addBrowserEvent then
				addBrowserEvent(EV_KEYDOWN, newDir == 1 and KEY_RIGHTARROW or KEY_LEFTARROW)
			end

			mouseDeltaX = 0
		end
		mouseDeltaY = 0

		if mouseTurnTics > 0 then
			mouseTurnTics = mouseTurnTics - 1
			if mouseTurnTics == 0 and mouseTurnDir ~= 0 and addBrowserEvent then
				addBrowserEvent(EV_KEYUP, mouseTurnDir == 1 and KEY_RIGHTARROW or KEY_LEFTARROW)
				mouseTurnDir = 0
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

-- Watch for restart requests (when custom WAD is loaded)
while true do
	if customWadBuffer and not doomRunning then
		print("[WAD] Restarting DOOM with custom WAD...")
		-- Re-create WASM memory for a clean state
		memoryData = buffer.create(memoryPages * WASM_PAGE_SIZE)
		memory.data = memoryData
		wasmMemory = memory
		runDoomSession()
	end
	task.wait(0.5)
end