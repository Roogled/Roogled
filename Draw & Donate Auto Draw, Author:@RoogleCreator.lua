-- Этот код заливаешь на свой GitHub

local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local LocalDrawingCanvas = nil

local BotConfig = {
    Enabled = false,
    ImageURL = "",
    InstantDraw = false
}

-- Библиотеки объявлены глобально, они придут из загрузчика
local PNG = {}
PNG.__index = PNG

---------------------------------------------------------------------------------------------
-- [1. GUI INTERFACE]
---------------------------------------------------------------------------------------------
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "DrawAndDonateAutoDraw"
ScreenGui.ResetOnSpawn = false
pcall(function() ScreenGui.Parent = CoreGui end)
if not ScreenGui.Parent then ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local MainFrame = Instance.new("Frame")
MainFrame.Size = UDim2.new(0, 250, 0, 260)
MainFrame.Position = UDim2.new(0.05, 0, 0.3, 0)
MainFrame.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Draggable = true
MainFrame.Parent = ScreenGui

local UICorner = Instance.new("UICorner")
UICorner.CornerRadius = UDim.new(0, 2)
UICorner.Parent = MainFrame

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, 0, 0, 40)
Title.Text = "Draw & Donate Auto Draw"
Title.TextColor3 = Color3.fromRGB(255, 255, 255)
Title.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
Title.Font = Enum.Font.SourceSans
Title.TextSize = 14
Title.Parent = MainFrame

local UTCorner = Instance.new("UICorner")
UTCorner.CornerRadius = UDim.new(0, 2)
UTCorner.Parent = Title

local function CreateButton(text, yPos, callback)
    local Btn = Instance.new("TextButton")
    Btn.Size = UDim2.new(1, -20, 0, 32)
    Btn.Position = UDim2.new(0, 10, 0, yPos)
    Btn.Text = text
    Btn.TextColor3 = Color3.fromRGB(240, 240, 240)
    Btn.BackgroundColor3 = Color3.fromRGB(44, 44, 52)
    Btn.Font = Enum.Font.SourceSans
    Btn.TextSize = 14
    Btn.Parent = MainFrame
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 2)
    c.Parent = Btn
    Btn.MouseButton1Click:Connect(callback)
    return Btn
end

local ToggleBtn = CreateButton("Please wait...", 50, function() end)
ToggleBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 75)
ToggleBtn.AutoButtonColor = false

local ModeBtn = CreateButton("Mode: Smooth (Stable but slow)", 87, function() end)

ModeBtn.MouseButton1Click:Connect(function()
    BotConfig.InstantDraw = not BotConfig.InstantDraw
    if BotConfig.InstantDraw then
        ModeBtn.Text = "Mode: Instant (Might lag a bit)"
        ModeBtn.TextColor3 = Color3.fromRGB(255, 215, 0)
    else
        ModeBtn.Text = "Mode: Smooth (Stable but slow)"
        ModeBtn.TextColor3 = Color3.fromRGB(240, 240, 240)
    end
end)

local TextBox = Instance.new("TextBox")
TextBox.Size = UDim2.new(1, -20, 0, 30)
TextBox.Position = UDim2.new(0, 10, 0, 125)
TextBox.Text = "Insert direct .png URL link"
TextBox.TextColor3 = Color3.fromRGB(200, 200, 200)
TextBox.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
TextBox.Font = Enum.Font.SourceSans
TextBox.TextSize = 12
TextBox.TextWrapped = true
TextBox.ClearTextOnFocus = false
TextBox.Parent = MainFrame
local BoxCorner = Instance.new("UICorner")
BoxCorner.CornerRadius = UDim.new(0, 2)
BoxCorner.Parent = TextBox
TextBox.FocusLost:Connect(function(ep) if ep then BotConfig.ImageURL = TextBox.Text end end)

local StatusLabel = Instance.new("TextLabel")
StatusLabel.Size = UDim2.new(1, -20, 0, 40)
StatusLabel.Position = UDim2.new(0, 10, 0, 160)
StatusLabel.Text = "Status: Loading..."
StatusLabel.TextColor3 = Color3.fromRGB(255, 165, 0)
StatusLabel.BackgroundTransparency = 1
StatusLabel.Font = Enum.Font.SourceSans
StatusLabel.TextSize = 13
StatusLabel.TextWrapped = true
StatusLabel.Parent = MainFrame

local AuthorLabel = Instance.new("TextLabel")
AuthorLabel.Size = UDim2.new(1, -20, 0, 20)
AuthorLabel.Position = UDim2.new(0, 10, 0, 205)
AuthorLabel.Text = "Author: @RoogleCreator"
AuthorLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
AuthorLabel.BackgroundTransparency = 1
AuthorLabel.Font = Enum.Font.SourceSans
AuthorLabel.TextSize = 12
AuthorLabel.Parent = MainFrame

local ProgressBarBg = Instance.new("Frame")
ProgressBarBg.Size = UDim2.new(1, -20, 0, 6)
ProgressBarBg.Position = UDim2.new(0, 10, 0, 235)
ProgressBarBg.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
ProgressBarBg.BorderSizePixel = 0
ProgressBarBg.Parent = MainFrame
local ProgressBarFill = Instance.new("Frame")
ProgressBarFill.Size = UDim2.new(0, 0, 1, 0)
ProgressBarFill.BackgroundColor3 = Color3.fromRGB(0, 255, 150)
ProgressBarFill.BorderSizePixel = 0
ProgressBarFill.Parent = ProgressBarBg

---------------------------------------------------------------------------------------------
-- [2. PNG PARSER FUNCTIONS]
---------------------------------------------------------------------------------------------
local function getBytesPerPixel(colorType)
    if colorType == 0 or colorType == 3 then return 1
    elseif colorType == 4 then return 2
    elseif colorType == 2 then return 3
    elseif colorType == 6 then return 4
    else return 0 end
end

local function clampInt(value, min, max)
    local num = tonumber(value) or 0
    num = math.floor(num + 0.5)
    return math.clamp(num, min, max)
end

local function indexBitmap(file, x, y)
    local width = file.Width
    local height = file.Height
    x = clampInt(x, 1, width)
    y = clampInt(y, 1, height)
    local bitmap = file.Bitmap
    local bpp = file.BytesPerPixel
    local i0 = ((x - 1) * bpp) + 1
    local i1 = i0 + bpp
    return bitmap[y], i0, i1
end

function PNG:GetPixel(x, y)
    local row, i0, i1 = indexBitmap(self, x, y)
    if not row then return Color3.new(1,1,1), 0 end
    local colorType = self.ColorType
    local color, alpha
    
    if colorType == 0 then
        local gray = unpack(row, i0, i1)
        color = Color3.fromHSV(0, 0, gray or 0)
        alpha = 255
    elseif colorType == 2 then
        local r, g, b = unpack(row, i0, i1)
        color = Color3.fromRGB(r or 0, g or 0, b or 0)
        alpha = 255
    elseif colorType == 3 then
        local palette = self.Palette
        local alphaData = self.AlphaData
        local index = unpack(row, i0, i1)
        index = (index or 0) + 1
        if palette then color = palette[index] end
        if alphaData then alpha = alphaData[index] end
    elseif colorType == 4 then
        local gray, a = unpack(row, i0, i1)
        color = Color3.fromHSV(0, 0, gray or 0)
        alpha = a
    elseif colorType == 6 then
        local r, g, b, a = unpack(row, i0, i1)
        color = Color3.fromRGB(r or 0, g or 0, b or 0)
        alpha = a
    end
    
    if not color then color = Color3.new(1, 1, 1) end
    if not alpha then alpha = 255 end
    return color, alpha
end

function PNG.new(buffer)
    local reader = BinaryReader.new(buffer)
    local file = { Chunks = {}, Metadata = {}, Reading = true, ZlibStream = "" }
    local header = reader:ReadString(8)
    if header ~= "\137PNG\r\n\26\n" then error("PNG - Input data is not a PNG file.", 2) end
    
    while file.Reading do
        local length = reader:ReadInt32()
        local chunkType = reader:ReadString(4)
        local data, crc
        if length > 0 then
            data = reader:ForkReader(length)
            crc = reader:ReadUInt32()
        end
        local chunk = { Length = length, Type = chunkType, Data = data, CRC = crc }
        local handler = chunks[chunkType]
        if handler then handler(file, chunk) end
        table.insert(file.Chunks, chunk)
    end
    
    local success, response = pcall(function()
        local result = {}
        local index = 0
        
        Deflate:InflateZlib({
            Input = BinaryReader.new(file.ZlibStream),
            Output = function(byte)
                index = index + 1
                result[index] = string.char(byte)
                
                if not BotConfig.InstantDraw and index % 40000 == 0 then
                    task.wait()
                end
            end
        })
        return table.concat(result)
    end)
    
    if not success then error("PNG - Unable to unpack PNG data. " .. tostring(response), 2) end
    
    local width = file.Width
    local height = file.Height
    local bitDepth = file.BitDepth
    local colorType = file.ColorType
    local buffer = BinaryReader.new(response)
    file.ZlibStream = nil
    local bitmap = {}
    file.Bitmap = bitmap
    local channels = getBytesPerPixel(colorType)
    file.NumChannels = channels
    local bpp = math.max(1, channels * (bitDepth / 8))
    file.BytesPerPixel = bpp
    
    for row = 1, height do
        if not BotConfig.InstantDraw and row % 2 == 0 then task.wait() end
        local filterType = buffer:ReadByte()
        local scanline = buffer:ReadBytes(width * bpp, true)
        bitmap[row] = {}
        
        if filterType == 0 then Unfilter:None(scanline, bitmap, bpp, row)
        elseif filterType == 1 then Unfilter:Sub(scanline, bitmap, bpp, row)
        elseif filterType == 2 then Unfilter:Up(scanline, bitmap, bpp, row)
        elseif filterType == 3 then Unfilter:Average(scanline, bitmap, bpp, row)
        elseif filterType == 4 then Unfilter:Paeth(scanline, bitmap, bpp, row) end
    end
    return setmetatable(file, PNG)
end

---------------------------------------------------------------------------------------------
-- [3. Инициализация интерфейса после загрузки]
---------------------------------------------------------------------------------------------
StatusLabel.Text = "Status: Ready to draw!"
StatusLabel.TextColor3 = Color3.fromRGB(0, 200, 100)
ToggleBtn.Text = "START"
ToggleBtn.BackgroundColor3 = Color3.fromRGB(40, 150, 80)
ToggleBtn.AutoButtonColor = true

---------------------------------------------------------------------------------------------
-- [4. CANVAS SEARCH AND VALIDATION]
---------------------------------------------------------------------------------------------
local function FindLocalDrawingCanvas()
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if not playerGui then return nil end
    local canvasFrame = nil
    for _, v in ipairs(playerGui:GetDescendants()) do
        if v:IsA("Frame") and v:FindFirstChild("FastCanvas") then canvasFrame = v break end
    end
    if not canvasFrame then return nil end

    local successGC, registry = pcall(getgc, true)
    if successGC then
        for i = 1, #registry do
            local obj = registry[i]
            if type(obj) == "table" and rawget(obj, "DrawLine") then
                if rawget(obj, "CurrentCanvasFrame") == canvasFrame or tostring(rawget(obj, "CurrentCanvasFrame")) == tostring(canvasFrame) then
                    return obj
                end
            end
        end
    end
    return nil
end

local drawingThread = nil

ToggleBtn.MouseButton1Click:Connect(function()
    if BotConfig.Enabled then
        BotConfig.Enabled = false
        ToggleBtn.Text = "START"
        ToggleBtn.BackgroundColor3 = Color3.fromRGB(40, 150, 80)
        if drawingThread then task.cancel(drawingThread) end
        StatusLabel.Text = "Status: Stopped."
        ProgressBarFill.Size = UDim2.new(0, 0, 1, 0)
    else
        LocalDrawingCanvas = FindLocalDrawingCanvas()
        if not LocalDrawingCanvas then StatusLabel.Text = "Status: Open the easel first!" return end
        if BotConfig.ImageURL == "" or not string.match(BotConfig.ImageURL, "http") then StatusLabel.Text = "Status: Invalid image URL!" return end

        BotConfig.Enabled = true
        ToggleBtn.Text = "STOP"
        ToggleBtn.BackgroundColor3 = Color3.fromRGB(170, 40, 40)
        
        drawingThread = task.spawn(function()
            StatusLabel.Text = "Status: Downloading..."
            local successFetch, resultBuffer = pcall(function() return game:HttpGet(BotConfig.ImageURL) end)
            if not successFetch then StatusLabel.Text = "Status: Download failed!" BotConfig.Enabled = false ToggleBtn.Text = "START" return end

            StatusLabel.Text = "Status: Processing..."
            if not BotConfig.InstantDraw then task.wait() end
            
            local successPng, pngImage = pcall(function() return PNG.new(resultBuffer) end)
            if not successPng or not pngImage then 
                StatusLabel.Text = "Status: Bad image file!" 
                BotConfig.Enabled = false ToggleBtn.Text = "START" return 
            end

            local resX = tonumber(LocalDrawingCanvas.CurrentResX or 150)
            local resY = tonumber(LocalDrawingCanvas.CurrentResY or 150)
            
            StatusLabel.Text = "Status: Drawing..."
            
            local canvas = LocalDrawingCanvas
            local drawLine = canvas.DrawLine
            local renderCanvas = canvas.Render
            local imgWidth = pngImage.Width
            local imgHeight = pngImage.Height
            local getPixel = pngImage.GetPixel
            local math_clamp = math.clamp
            local math_floor = math.floor
            local vec2_new = Vector2.new
            local task_wait = task.wait
            local config = BotConfig
            local isInstant = config.InstantDraw

            for y = 1, resY do
                if not config.Enabled then return end
                
                local ratioY = y / resY
                for x = 1, resX do
                    local srcX = math_clamp(math_floor((x / resX) * imgWidth), 1, imgWidth)
                    local srcY = math_clamp(math_floor(ratioY * imgHeight), 1, imgHeight)
                    
                    local color, alpha = getPixel(pngImage, srcX, srcY)
                    
                    if alpha > 15 then
                        local pPos = vec2_new(x, y)
                        drawLine(canvas, pPos, pPos, color, 1)
                    end
                end
                
                if not isInstant then
                    ProgressBarFill.Size = UDim2.new(ratioY, 0, 1, 0)
                    if y % 3 == 0 then
                        if renderCanvas then renderCanvas(canvas) end
                        task_wait()
                    end
                end
            end
            
            if renderCanvas then renderCanvas(canvas) end
            ProgressBarFill.Size = UDim2.new(1, 0, 1, 0)
            StatusLabel.Text = "Status: Done!"
            BotConfig.Enabled = false
            ToggleBtn.Text = "START"
            ToggleBtn.BackgroundColor3 = Color3.fromRGB(40, 150, 80)
        end)
    end
end)
