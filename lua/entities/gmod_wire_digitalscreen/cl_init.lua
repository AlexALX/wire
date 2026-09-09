include("shared.lua")

local dsDrawRate = CreateConVar("wire_digitalscreen_draw_rate", 1, { FCVAR_REPLICATED, FCVAR_ARCHIVE }, "Draw rate for digital screen", 0.1, 1000)

function ENT:SendData()
	net.Start("wire_interactiveprop_action")

	local data	= WireLib.GetInteractiveModel(self:GetModel()).widgets
	net.WriteEntity(self)
	for i=1, #data do
		net.WriteFloat(self.InteractiveData[i])
	end
	net.SendToServer()
end

function ENT:GetPanel()
	if not self.IsInteractive then return end
	local data	= WireLib.GetInteractiveModel(self:GetModel())
	return WireLib.GetInteractiveWidgetBody(self, data)
end


function ENT:AddButton(id,button)
	if not self.IsInteractive then return end
	self.Buttons[id] = button
end

function ENT:Initialize()
	self.Memory1 = {}
	self.Memory2 = {}

	self.InteractiveData = {}
	self.LastButtons = {}
	self.Buttons = {}
	local interactive_model = WireLib.GetInteractiveModel(self:GetModel())
	self.IsInteractive = false
	if interactive_model then
		self.IsInteractive = true
		for i=1, #WireLib.GetInteractiveModel(self:GetModel()).widgets do
			self.InteractiveData[i] = 0
		end
	end

	self.LastClk = true
	self.NewClk = true
	self.Memory1[1048575] = 1
	self.Memory2[1048575] = 1
	self.NeedRefresh = true
	self.IsClear = true
	self.ClearQueued = false
	self.ClearColor = 0 -- Screen fill color buffer
	self.RefreshPixels = {}
	self.RefreshRows = {}
	self.ShiftX = 0
	self.ShiftY = 0
    self.ShiftRT = GetRenderTargetEx("DigitalScreen_Shift_" .. self:EntIndex(), 1024, 1024, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, 256, 0, 12)

	self.ScreenWidth = 32
	self.ScreenHeight = 32

	for i=1,self.ScreenHeight do
		self.RefreshRows[i] = i-1
	end

	--0..786431 - RGB data

	--1048566 - HW Shift Y
	--1048567 - HW Shift X
	--1048568 - Clear / BG color (does not support color mode 1)
	--1048569 - Color mode (0: RGBXXX; 1: R G B; 2: 24 bit RGB; 3: RRRGGGBBB; 4: XXX; 5: RGB 565 format (2 bytes); 6: RGB 332 format (1 byte))
	--1048570 - Clear row
	--1048571 - Clear column
	--1048572 - Screen Height
	--1048573 - Screen Width
	--1048574 - Hardware Clear Screen
	--1048575 - CLK

	self.GPU = WireGPU(self)

	self.buffer = {}

	WireLib.netRegister(self)
end

function ENT:OnRemove()
	self.GPU:Finalize()
	self.NeedRefresh = true
end

local function stringToNumber(index, str, bytes)
	local n = 0
	local mult = 1

	-- Read bytes directly from the original string using absolute offset (index + j).
	-- This eliminates string allocations from str:sub() and prevents Garbage Collector spikes.
	for j = 0, bytes - 1 do
		n = n + str:byte(index + j) * mult
		mult = mult * 256 -- Multiplication is faster than math.pow / exponentiation (256^j)
	end

	return n, index + bytes
end

local pixelbits = {3, 1, 3, 4, 1}
net.Receive("wire_digitalscreen", function()
	local ent = Entity(net.ReadUInt(16))

	if IsValid(ent) and ent.Memory1 and ent.Memory2 then
		local pixelbit = pixelbits[net.ReadUInt(5)]
		local len = net.ReadUInt(32)
		local datastr = util.Decompress(net.ReadData(len))
		if #datastr>0 then
			ent:AddBuffer(datastr,pixelbit)
		end
	end
end)

function ENT:AddBuffer(datastr,pixelbit)
	self.buffer[#self.buffer+1] = {datastr=datastr,readIndex=1,pixelbit=pixelbit}
end
function ENT:ProcessBuffer()
	if not self.buffer[1] then return end

	local datastr = self.buffer[1].datastr
	local readIndex = self.buffer[1].readIndex
	local pixelbit = self.buffer[1].pixelbit

	local length
	length, readIndex = stringToNumber(readIndex,datastr,3)
	if length == 0 then
		table.remove( self.buffer, 1 )
		return false
	end
	local address
	address, readIndex = stringToNumber(readIndex,datastr,3)

	for i = address, address + length - 1 do
		if i>=1048500 and i~=1048568 then
			local data
			data, readIndex = stringToNumber(readIndex,datastr,2)
			self:WriteCell(i, data)
		else
			local data
			data, readIndex = stringToNumber(readIndex,datastr,pixelbit)
			self:WriteCell(i, data)
		end

		coroutine.yield(true)
	end

	self.buffer[1].readIndex = readIndex
	return false
end

function ENT:Think()
	if self.buffer[1] ~= nil then
		local maxtime = SysTime() + RealFrameTime() * (0.05*dsDrawRate:GetFloat()) -- do more depending on client FPS. Higher fps = more work

		while SysTime() < maxtime and self.buffer[1] do
			if not self.co or coroutine.status(self.co) == "dead" then
				self.co = coroutine.create( function()
					 self:ProcessBuffer()
				end )
			end

			coroutine.resume(self.co)
		end
	end

	self:NextThink(CurTime()+0.1)
	return true
end

function ENT:ReadCell(Address,value)
	Address = math.floor(Address)
	if Address < 0 then return nil end
	if Address >= 1048577 then return nil end

	return self.Memory2[Address]
end

function ENT:WriteCell(Address,value)
	Address = math.floor(Address)
	if Address < 0 then return false end
	if Address >= 1048577 then return false end

	if Address == 1048575 then
		self.NewClk = value ~= 0
	elseif Address < 1048500 then
		self.IsClear = false
	end

	if (self.NewClk) then
		self.Memory1[Address] = value -- visible buffer
		self.NeedRefresh = true
		if self.Memory1[1048569] == 1 then -- R G B mode
			local pixelno = math.floor(Address/3)
			if self.RefreshPixels[#self.RefreshPixels] ~= pixelno then
				self.RefreshPixels[#self.RefreshPixels+1] = pixelno
			end
		else -- other modes
			self.RefreshPixels[#self.RefreshPixels+1] = Address
		end
	end
	self.Memory2[Address] = value -- invisible buffer

	if Address == 1048566 then -- Shift Y command
		-- Restore signed integer from unsigned uint16 network transmission
		local rawVal = value > 32767 and value - 65536 or value
		local dy = rawVal % self.ScreenHeight
		if dy > self.ScreenHeight / 2 then dy = dy - self.ScreenHeight end
		if dy < -self.ScreenHeight / 2 then dy = dy + self.ScreenHeight end
		
		if dy ~= 0 then
			local w, h = self.ScreenWidth, self.ScreenHeight
			local colormode = self.Memory2[1048569] or 0
			local stride = (colormode == 1) and 3 or 1
			
			local newMem = {}
			for addr = 1048500, 1048575 do
				newMem[addr] = self.Memory2[addr]
			end
			
			if stride == 3 then
				for y = 0, h - 1 do
					local srcY = y - dy
					if srcY >= 0 and srcY < h then
						local dstRow = y * w
						local srcRow = srcY * w
						for x = 0, w - 1 do
							local dstIdx = (dstRow + x) * 3
							local srcIdx = (srcRow + x) * 3
							newMem[dstIdx]     = self.Memory2[srcIdx]
							newMem[dstIdx + 1] = self.Memory2[srcIdx + 1]
							newMem[dstIdx + 2] = self.Memory2[srcIdx + 2]
						end
					end
				end
			else
				for y = 0, h - 1 do
					local srcY = y - dy
					if srcY >= 0 and srcY < h then
						local dstRow = y * w
						local srcRow = srcY * w
						for x = 0, w - 1 do
							newMem[dstRow + x] = self.Memory2[srcRow + x]
						end
					end
				end
			end
			
			self.Memory2 = newMem
			if self.NewClk then
				self.Memory1 = table.Copy(newMem)
			end
		end
		
		self.ShiftY = self.ShiftY + rawVal
		self.NeedRefresh = true

	elseif Address == 1048567 then -- Shift X command
		-- Restore signed integer from unsigned uint16 network transmission
		local rawVal = value > 32767 and value - 65536 or value
		local dx = rawVal % self.ScreenWidth
		if dx > self.ScreenWidth / 2 then dx = dx - self.ScreenWidth end
		if dx < -self.ScreenWidth / 2 then dx = dx + self.ScreenWidth end
        
		if dx ~= 0 then
			local w, h = self.ScreenWidth, self.ScreenHeight
			local colormode = self.Memory2[1048569] or 0
			local stride = (colormode == 1) and 3 or 1
			
			local newMem = {}
			for addr = 1048500, 1048575 do
				newMem[addr] = self.Memory2[addr]
			end
			
			if stride == 3 then
				for y = 0, h - 1 do
					local rowOffset = y * w
					for x = 0, w - 1 do
						local srcX = x - dx
						if srcX >= 0 and srcX < w then
							local dstIdx = (rowOffset + x) * 3
							local srcIdx = (rowOffset + srcX) * 3
							newMem[dstIdx]     = self.Memory2[srcIdx]
							newMem[dstIdx + 1] = self.Memory2[srcIdx + 1]
							newMem[dstIdx + 2] = self.Memory2[srcIdx + 2]
						end
					end
				end
			else
				for y = 0, h - 1 do
					local rowOffset = y * w
					for x = 0, w - 1 do
						local srcX = x - dx
						if srcX >= 0 and srcX < w then
							newMem[rowOffset + x] = self.Memory2[rowOffset + srcX]
						end
					end
				end
			end
			
			self.Memory2 = newMem
			if self.NewClk then
				self.Memory1 = table.Copy(newMem)
			end
		end

		self.ShiftX = self.ShiftX + rawVal
		self.NeedRefresh = true
	elseif Address == 1048568 then -- Custom dedicated address for Fill/Clear Color
		-- store raw value, so will be properly synced with colormode
		self.ClearColor = value
	elseif Address == 1048574 then -- Hardware Clear Screen
		local mem1,mem2 = {},{}
		for addr = 1048500,1048575 do
			mem1[addr] = self.Memory1[addr]
			mem2[addr] = self.Memory2[addr]
		end
		self.Memory1,self.Memory2 = mem1,mem2
		self.IsClear = true
		self.ClearQueued = true
		self.NeedRefresh = true
		self.RefreshRows = {}
	elseif Address == 1048572 then
		self.ScreenHeight = value
		if not self.IsClear then
			self.NeedRefresh = true
			for i = 1,self.ScreenHeight do
				self.RefreshRows[i] = i-1
			end
		end
	elseif Address == 1048573 then
		self.ScreenWidth = value
		if not self.IsClear then
			self.NeedRefresh = true
			for i = 1,self.ScreenHeight do
				self.RefreshRows[i] = i-1
			end
		end
	end

	if self.LastClk ~= self.NewClk then
		-- swap the memory if clock changes
		self.LastClk = self.NewClk
		self.Memory1 = table.Copy(self.Memory2)

		self.NeedRefresh = true
		for i=1,self.ScreenHeight do
			self.RefreshRows[i] = i-1
		end
	end
	return true
end

local transformcolor = {}
transformcolor[0] = function(c) -- RGBXXX
	local crgb = math.floor(c / 1000)
	local cgray = c - math.floor(c / 1000)*1000

	return cgray+28*math.fmod(math.floor(crgb / 100), 10), cgray+28*math.fmod(math.floor(crgb / 10), 10), cgray+28*math.fmod(crgb, 10)
end
transformcolor[2] = function(c) -- 24 bit mode
	return math.fmod(math.floor(c / 65536), 256), math.fmod(math.floor(c / 256), 256), math.fmod(c, 256)
end
transformcolor[3] = function(c) -- RRRGGGBBB
	return math.fmod(math.floor(c / 1e6), 1000), math.fmod(math.floor(c / 1e3), 1000), math.fmod(c, 1000)
end
transformcolor[4] = function(c) -- XXX
	return c, c, c
end
transformcolor[5] = function(c) -- RGB 565 format (5-bit R, 6-bit G, 5-bit B) - saves network bandwidth by packing 16-bit color values
    -- Extract individual color components using bitwise-equivalent math operations
    local r = math.floor(c / 2048) % 32
    local g = math.floor(c / 32) % 64
    local b = c % 32
    
    -- Scale the components from their native ranges (0-31, 0-63) up to the standard 0-255 color range
    return math.floor(r * 255 / 31), math.floor(g * 255 / 63), math.floor(b * 255 / 31)
end
transformcolor[6] = function(c) -- 8-bit RGB 332 format (3-bit R, 3-bit G, 2-bit B) - maximum network and memory economy (1 byte per pixel)
    -- Extract individual color components using bitwise-equivalent math operations
    local r = math.floor(c / 32) % 8
    local g = math.floor(c / 4) % 8
    local b = c % 4
    
    -- Scale the components from their native ranges (0-7, 0-3) up to the standard 0-255 color range
    return math.floor(r * 255 / 7), math.floor(g * 255 / 7), math.floor(b * 255 / 3)
end

function ENT:RedrawPixel(a)
	if a >= self.ScreenWidth*self.ScreenHeight then return end

	local cr,cg,cb

	local x = a % self.ScreenWidth
	local y = math.floor(a / self.ScreenWidth)

	local colormode = self.Memory1[1048569] or 0

	if colormode == 1 then
		cr = self.Memory1[a*3  ] or 0
		cg = self.Memory1[a*3+1] or 0
		cb = self.Memory1[a*3+2] or 0
	else
		local c = self.Memory1[a] or 0
		cr, cg, cb = (transformcolor[colormode] or transformcolor[0])(c)
	end


	surface.SetDrawColor(cr,cg,cb,255)
	surface.DrawRect( x, y, 1, 1 )
end

function ENT:RedrawRow(y)
	if y >= self.ScreenHeight then return end
	local a = y*self.ScreenWidth

	local colormode = self.Memory1[1048569] or 0

	for x = 0,self.ScreenWidth-1 do
		local cr,cg,cb

		if (colormode == 1) then
			cr = self.Memory1[(a+x)*3  ] or 0
			cg = self.Memory1[(a+x)*3+1] or 0
			cb = self.Memory1[(a+x)*3+2] or 0
		else
			local c = self.Memory1[a+x] or 0
			cr, cg, cb = (transformcolor[colormode] or transformcolor[0])(c)
		end

		surface.SetDrawColor(cr,cg,cb,255)
		surface.DrawRect( x, y, 1, 1 )
	end
end

local VECTOR_1_1_1 = Vector(1, 1, 1)
function ENT:Draw(flags)
	self:DrawModel(flags)

	local tone = render.GetToneMappingScaleLinear()
	render.SetToneMappingScaleLinear(VECTOR_1_1_1)

	if self.NeedRefresh then
		self.NeedRefresh = false
		local maxtime = SysTime() + RealFrameTime() * (0.01*dsDrawRate:GetFloat())
        
        if (self.ShiftX and self.ShiftX ~= 0) or (self.ShiftY and self.ShiftY ~= 0) then
            -- 1. Capture the client's actual monitor resolution BEFORE entering the GPULib render context.
            -- This is required to calculate dynamic scale coefficients matching the player's specific screen (e.g., 1920x1080).
            local realW, realH = ScrW(), ScrH()
            local scaleX = realW / 1024
            local scaleY = realH / 1024
            
            local targetX = self.ShiftX
            local targetY = self.ShiftY

            -- 2. Clamp the shift offset within the boundaries of the current virtual screen resolution
            -- to prevent the canvas from drifting infinitely.
            local sx = math.Clamp(math.floor(targetX), -self.ScreenWidth, self.ScreenWidth)
            local sy = math.Clamp(math.floor(targetY), -self.ScreenHeight, self.ScreenHeight)

            -- 3. Calculate the proper background color to fill empty areas revealed during the shift.
            local cr, cg, cb
            local colormode = self.Memory1[1048569] or 0
            if colormode == 1 then
                cr, cg, cb = 0, 0, 0
            else
                cr, cg, cb = (transformcolor[colormode] or transformcolor[0])(self.ClearColor or 0)
            end
            
            -- 4. Switch to the GPU's virtual render target context (1024x1024 texture space).
            self.GPU:RenderToGPU(function()
                -- A. Snapshot the current frame into a secondary buffer (ShiftRT),
                -- because the GPU cannot simultaneously read from and write to the same RenderTarget (Feedback Loop).
                render.CopyTexture(self.GPU.RT, self.ShiftRT)

                -- B. Clear the main buffer with the background color (fills empty gaps created by the shift).
                render.Clear(cr, cg, cb, 255)

                -- C. Hard-disable bilinear filtering/interpolation 
                -- to keep pixels and text crystal sharp without blurriness.
                render.PushFilterMag(TEXFILTER.POINT)
                render.PushFilterMin(TEXFILTER.POINT)

                    -- D. Bind the snapshot texture and set it as the active material for drawing.
                    WireGPU_matBuffer:SetTexture("$basetexture", self.ShiftRT)
                    render.SetMaterial(WireGPU_matBuffer)

                    -- E. Draw the screen quad with the shift offset (sx, sy) and monitor scale.
                    -- The scaleX/scaleY coefficients compensate for the Source Engine viewport proportions in this hook.
                    render.DrawScreenQuadEx(sx, sy, 1024 * scaleX, 1024 * scaleY)

                -- F. Restore previous filtering settings.
                render.PopFilterMag()
                render.PopFilterMin()

                -- G. Reset shift triggers for the next frame.
                self.ShiftX = 0
                self.ShiftY = 0
            end)
        end

		self.GPU:RenderToGPU(function()
			local idx = 0

			if self.ClearQueued then
                local cr, cg, cb
                local colormode = self.Memory1[1048569] or 0
                if colormode==1 then
                    cr, cg, cb = 0,0,0
                else
                    cr, cg, cb = (transformcolor[colormode] or transformcolor[0])(self.ClearColor)
                end
            
				surface.SetDrawColor(cr,cg,cb,255)
				surface.DrawRect(0,0, 1024,1024)
				self.ClearQueued = false
				return
			end

			if (#self.RefreshRows > 0) then
				idx = #self.RefreshRows
				while ((idx > 0) and (SysTime() < maxtime)) do
					self:RedrawRow(self.RefreshRows[idx])
					self.RefreshRows[idx] = nil
					idx = idx - 1
				end
			else
				idx = #self.RefreshPixels
				while ((idx > 0) and (SysTime() < maxtime)) do
					self:RedrawPixel(self.RefreshPixels[idx])
					self.RefreshPixels[idx] = nil
					idx = idx - 1
				end
			end
			if idx ~= 0 then
				self.NeedRefresh = true
			end
		end)
	end

	self.GPU:Render(0,0,1024,1024,nil,-(1024-self.ScreenWidth)/1024,-(1024-self.ScreenHeight)/1024)
	render.SetToneMappingScaleLinear(tone)
	Wire_Render(self)
end

function ENT:IsTranslucent()
	return true
end
