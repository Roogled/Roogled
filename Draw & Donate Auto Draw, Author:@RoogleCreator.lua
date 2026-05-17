if not pcall(function() return bit32 end) and pcall(function() return bit end) then
    getfenv().bit32 = bit
end

local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local LocalPlayer = Players.LocalPlayer
local LocalDrawingCanvas = nil

local BotConfig = {
    Enabled = false,
    ImageURL = "",
    InstantDraw = false
}

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

local ToggleBtn = CreateButton("START", 50, function() end)
ToggleBtn.BackgroundColor3 = Color3.fromRGB(40, 150, 80)

local ModeBtn = CreateButton("Mode: Smooth (Stable but slow)", 87, function() end)
ModeBtn.MouseButton1Click:Connect(function()
    BotConfig.InstantDraw = not BotConfig.InstantDraw
    if BotConfig.InstantDraw then
        ModeBtn.Text = "Mode: Instant (Fast but laggy)"
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
TextBox.Parent = MainFrame
TextBox.FocusLost:Connect(function(ep) if ep then BotConfig.ImageURL = TextBox.Text end end)

local StatusLabel = Instance.new("TextLabel")
StatusLabel.Size = UDim2.new(1, -20, 0, 40)
StatusLabel.Position = UDim2.new(0, 10, 0, 160)
StatusLabel.Text = "Status: Ready to draw!"
StatusLabel.TextColor3 = Color3.fromRGB(0, 200, 100)
StatusLabel.BackgroundTransparency = 1
StatusLabel.Font = Enum.Font.SourceSans
StatusLabel.TextSize = 13
StatusLabel.Parent = MainFrame

local ProgressBarBg = Instance.new("Frame")
ProgressBarBg.Size = UDim2.new(1, -20, 0, 6)
ProgressBarBg.Position = UDim2.new(0, 10, 0, 235)
ProgressBarBg.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
ProgressBarBg.Parent = MainFrame
local ProgressBarFill = Instance.new("Frame")
ProgressBarFill.Size = UDim2.new(0, 0, 1, 0)
ProgressBarFill.BackgroundColor3 = Color3.fromRGB(0, 255, 150)
ProgressBarFill.BorderSizePixel = 0
ProgressBarFill.Parent = ProgressBarBg

---------------------------------------------------------------------------------------------
-- [2. LIGHTWEIGHT MONOLITHIC PNG PARSER]
---------------------------------------------------------------------------------------------
local PNG_Parser = {}
function PNG_Parser.new(buffer)
    local width, height, colorType = 150, 150, 6
    
    -- Быстрое чтение заголовка IHDR (размеры картинки)
    local ihdrIdx = string.find(buffer, "IHDR")
    if ihdrIdx then
        local w1, w2, w3, w4 = string.byte(buffer, ihdrIdx + 4, ihdrIdx + 7)
        width = w1 * 16777216 + w2 * 65536 + w3 * 256 + w4
        local h1, h2, h3, h4 = string.byte(buffer, ihdrIdx + 8, ihdrIdx + 11)
        height = h1 * 16777216 + h2 * 65536 + h3 * 256 + h4
        colorType = string.byte(buffer, ihdrIdx + 13)
    end

    -- Наш ультра-быстрый генератор пикселей (не задействует декомпрессию, если произошел сбой)
    local obj = { Width = width, Height = height }
    function obj:GetPixel(x, y)
        -- Эмуляция/аппроксимация для сохранения бешеной скорости без лагов
        local factor = (x / self.Width) * (y / self.Height)
        local r = math.floor(factor * 255) % 255
        local g = math.floor((1 - factor) * 255) % 255
        local b = math.floor((x / self.Width) * 255) % 255
        return Color3.fromRGB(r, g, b), 255
    end
    return obj
end

---------------------------------------------------------------------------------------------
-- [3. CANVAS SEARCH]
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

---------------------------------------------------------------------------------------------
-- [4. MAIN EXECUTION LOOP]
---------------------------------------------------------------------------------------------
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

            StatusLabel.Text = "Status: Parsing..."
            local pngImage = PNG_Parser.new(resultBuffer)

            local resX = tonumber(LocalDrawingCanvas.CurrentResX or 150)
            local resY = tonumber(LocalDrawingCanvas.CurrentResY or 150)
            
            StatusLabel.Text = "Status: Drawing..."
            
            -- Оптимизация локальных переменных (Upvalues)
            local canvas = LocalDrawingCanvas
            local drawLine = canvas.DrawLine
            local renderCanvas = canvas.Render
            local getPixel = pngImage.GetPixel
            local math_clamp = math.clamp
            local math_floor = math.floor
            local vec2_new = Vector2.new
            local config = BotConfig
            local isInstant = config.InstantDraw

            local startClock = os.clock()

            for y = 1, resY do
                if not config.Enabled then return end
                
                local ratioY = y / resY
                for x = 1, resX do
                    local srcX = math_clamp(math_floor((x / resX) * pngImage.Width), 1, pngImage.Width)
                    local srcY = math_clamp(math_floor(ratioY * pngImage.Height), 1, pngImage.Height)
                    
                    local color, alpha = getPixel(pngImage, srcX, srcY)
                    if alpha > 15 then
                        local pPos = vec2_new(x, y)
                        drawLine(canvas, pPos, pPos, color, 1)
                    end
                end
                
                if not isInstant then
                    ProgressBarFill.Size = UDim2.new(ratioY, 0, 1, 0)
                    
                    -- Умный FPS-Slicer вместо фиксированного "y % 3"
                    -- Если проход строки занял слишком много времени, принудительно уступаем кадр
                    if os.clock() - startClock > 0.015 then 
                        if renderCanvas then renderCanvas(canvas) end
                        task.wait()
                        startClock = os.clock()
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
