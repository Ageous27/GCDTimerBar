local defaults = {
    locked = false,
    hideOutOfCombat = false,
    showQueueOverlay = true,
    width = 220,
    height = 18,
    alpha = 1.0,
    r = 0.15,
    g = 0.75,
    b = 0.20,
    x = 0,
    y = 0,
    moved = false,
}

local state = {
    inCombat = false,
    gcdDuration = nil,
    gcdEnd = nil,
    previewDuration = 1.50,
    hasQueueDeps = false,
    pressWindowSec = 0.15,
    lastLatencySample = 0,
    latencyAvgMs = nil,
    latencyJitterMs = 0,
    lastQueueSettingsSample = 0,
    spellQueued = false,
}

local eventFrame = CreateFrame("Frame", "GCDTimerBar_EventFrame", UIParent)
local bar = CreateFrame("Frame", "GCDTimerBar_BarFrame", UIParent)
local options = nil
local controls = {}

local function Modulo(a, b)
    if type(math.fmod) == "function" then
        return math.fmod(a, b)
    end
    if type(math.mod) == "function" then
        return math.mod(a, b)
    end
    return a - (math.floor(a / b) * b)
end

local function Clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

local function IsPreviewActive()
    return options and options:IsShown()
end

local function EndActiveGCD()
    state.gcdDuration = nil
    state.gcdEnd = nil
    state.spellQueued = false
end

local function HasNampowerQueueSupport()
    local windowCvar
    if not SUPERWOW_VERSION then
        return false
    end
    if type(GetNampowerVersion) ~= "function" then
        return false
    end
    if type(GetCVar) ~= "function" then
        return false
    end
    windowCvar = GetCVar("NP_SpellQueueWindowMs")
    if windowCvar == nil or windowCvar == "" then
        return false
    end
    return true
end

local function UpdatePressWindowFromNampower(now)
    local queueEnabled, queueWindowMs
    if (now - state.lastQueueSettingsSample) < 0.30 then
        return
    end
    state.lastQueueSettingsSample = now

    queueEnabled = tostring(GetCVar("NP_QueueInstantSpells") or "1")
    if queueEnabled == "0" then
        state.pressWindowSec = 0
        return
    end

    queueWindowMs = tonumber(GetCVar("NP_SpellQueueWindowMs") or "")
    if not queueWindowMs then
        queueWindowMs = 400
    end
    if queueWindowMs < 0 then
        queueWindowMs = 0
    end
    -- Queue window is the true server-side early-press window when Nampower queueing is active.
    -- Clamp to practical bounds for GCD visuals in 1.12.
    state.pressWindowSec = Clamp(queueWindowMs / 1000, 0.02, 0.90)
end

local function UpdatePressWindowFromLatency(now)
    local _, _, latencyMs
    local diff, windowMs

    if (now - state.lastLatencySample) < 0.50 then
        return
    end
    state.lastLatencySample = now

    if type(GetNetStats) ~= "function" then
        return
    end

    _, _, latencyMs = GetNetStats()
    latencyMs = tonumber(latencyMs)
    if not latencyMs or latencyMs <= 0 then
        return
    end

    if not state.latencyAvgMs then
        state.latencyAvgMs = latencyMs
        state.latencyJitterMs = 0
    else
        diff = math.abs(latencyMs - state.latencyAvgMs)
        state.latencyAvgMs = (state.latencyAvgMs * 0.80) + (latencyMs * 0.20)
        state.latencyJitterMs = (state.latencyJitterMs * 0.80) + (diff * 0.20)
    end

    windowMs = state.latencyAvgMs + (state.latencyJitterMs * 1.50) + 50
    state.pressWindowSec = Clamp(windowMs / 1000, 0.08, 0.35)
end

local function UpdatePressWindow(now)
    if state.hasQueueDeps then
        UpdatePressWindowFromNampower(now)
    else
        UpdatePressWindowFromLatency(now)
    end
end

local function UpdateQueueOverlay(referenceDuration)
    local ratio, width

    if not GCDTimerBarDB.showQueueOverlay then
        bar.queueOverlay:Hide()
        return
    end

    if not referenceDuration or referenceDuration <= 0 or state.pressWindowSec <= 0 then
        bar.queueOverlay:Hide()
        return
    end

    ratio = Clamp(state.pressWindowSec / referenceDuration, 0, 0.95)
    width = math.floor((GCDTimerBarDB.width * ratio) + 0.5)
    if width < 1 then
        bar.queueOverlay:Hide()
        return
    end

    bar.queueOverlay:SetWidth(width)
    if state.spellQueued then
        bar.queueOverlay:SetVertexColor(0.72, 0.35, 0.95, 0.95)
    else
        bar.queueOverlay:SetVertexColor(0.60, 0.25, 0.88, 0.75)
    end
    bar.queueOverlay:Show()
end

local function EnsureDB()
    if type(GCDTimerBarDB) ~= "table" then
        GCDTimerBarDB = {}
    end

    if GCDTimerBarDB.locked == nil then GCDTimerBarDB.locked = defaults.locked end
    if GCDTimerBarDB.hideOutOfCombat == nil then GCDTimerBarDB.hideOutOfCombat = defaults.hideOutOfCombat end
    if GCDTimerBarDB.showQueueOverlay == nil then GCDTimerBarDB.showQueueOverlay = defaults.showQueueOverlay end
    if type(GCDTimerBarDB.width) ~= "number" then GCDTimerBarDB.width = defaults.width end
    if type(GCDTimerBarDB.height) ~= "number" then GCDTimerBarDB.height = defaults.height end
    if type(GCDTimerBarDB.alpha) ~= "number" then GCDTimerBarDB.alpha = defaults.alpha end
    if type(GCDTimerBarDB.r) ~= "number" then GCDTimerBarDB.r = defaults.r end
    if type(GCDTimerBarDB.g) ~= "number" then GCDTimerBarDB.g = defaults.g end
    if type(GCDTimerBarDB.b) ~= "number" then GCDTimerBarDB.b = defaults.b end
    if type(GCDTimerBarDB.x) ~= "number" then GCDTimerBarDB.x = defaults.x end
    if type(GCDTimerBarDB.y) ~= "number" then GCDTimerBarDB.y = defaults.y end
    if GCDTimerBarDB.moved == nil then
        GCDTimerBarDB.moved = defaults.moved
    end

    -- One-time migration from the old default anchor (0, -180) to center.
    if not GCDTimerBarDB.moved and GCDTimerBarDB.x == 0 and GCDTimerBarDB.y == -180 then
        GCDTimerBarDB.x = 0
        GCDTimerBarDB.y = 0
    end

    if GCDTimerBarDB.width < 80 then GCDTimerBarDB.width = 80 end
    if GCDTimerBarDB.width > 800 then GCDTimerBarDB.width = 800 end
    if GCDTimerBarDB.height < 6 then GCDTimerBarDB.height = 6 end
    if GCDTimerBarDB.height > 80 then GCDTimerBarDB.height = 80 end
    if GCDTimerBarDB.alpha < 0.10 then GCDTimerBarDB.alpha = 0.10 end
    if GCDTimerBarDB.alpha > 1.00 then GCDTimerBarDB.alpha = 1.00 end
end

local function SetBarFillRatio(ratio, forceSpark)
    local w
    if ratio < 0 then ratio = 0 end
    if ratio > 1 then ratio = 1 end
    w = math.floor((GCDTimerBarDB.width * ratio) + 0.5)
    if w < 0 then w = 0 end
    bar.fill:SetWidth(w)

    if w <= 0 then
        bar.spark:Hide()
        return
    end

    bar.spark:ClearAllPoints()
    bar.spark:SetPoint("CENTER", bar, "LEFT", w, 0)
    if forceSpark then
        bar.spark:Show()
    elseif state.gcdEnd and state.gcdEnd > GetTime() then
        bar.spark:Show()
    else
        bar.spark:Hide()
    end
end

local function UpdateBarVisuals()
    bar:SetWidth(GCDTimerBarDB.width)
    bar:SetHeight(GCDTimerBarDB.height)
    bar.fill:SetHeight(GCDTimerBarDB.height)
    bar.spark:SetHeight(GCDTimerBarDB.height + 14)
    bar.fill:SetVertexColor(GCDTimerBarDB.r, GCDTimerBarDB.g, GCDTimerBarDB.b, 1)
    bar:SetAlpha(GCDTimerBarDB.alpha)
    SetBarFillRatio(1)
    UpdateQueueOverlay(state.gcdDuration or state.previewDuration)
end

local function SaveBarPosition()
    local cx, cy = bar:GetCenter()
    local ux, uy = UIParent:GetCenter()
    if not cx or not cy or not ux or not uy then
        return
    end
    GCDTimerBarDB.x = math.floor((cx - ux) + 0.5)
    GCDTimerBarDB.y = math.floor((cy - uy) + 0.5)
    GCDTimerBarDB.moved = true
end

local function UpdateBarPosition()
    bar:ClearAllPoints()
    bar:SetPoint("CENTER", UIParent, "CENTER", GCDTimerBarDB.x, GCDTimerBarDB.y)
end

local function UpdateBarInteraction()
    if GCDTimerBarDB.locked then
        bar:SetFrameStrata("MEDIUM")
        bar:EnableMouse(false)
    else
        bar:SetFrameStrata("TOOLTIP")
        bar:EnableMouse(true)
    end
end

local function UpdateBarVisibility()
    if IsPreviewActive() then
        bar:Show()
        return
    end

    if GCDTimerBarDB.hideOutOfCombat and not state.inCombat then
        bar:Hide()
        bar.spark:Hide()
        bar.queueOverlay:Hide()
        return
    end

    if state.gcdEnd and state.gcdEnd > GetTime() then
        bar:Show()
    else
        bar:Hide()
        bar.spark:Hide()
        bar.queueOverlay:Hide()
    end
end

local function BeginGCD(startTime, duration)
    if not startTime or not duration or duration <= 0 then
        return
    end
    state.gcdDuration = duration
    state.gcdEnd = startTime + duration
    SetBarFillRatio(1)
    UpdateQueueOverlay(duration)
    UpdateBarVisibility()
end

local function ConsiderCooldownCandidate(startTime, duration, now, best)
    local ending
    if not startTime or not duration then return best end
    if duration < 0.75 or duration > 2.0 then return best end
    if startTime <= 0 then return best end

    ending = startTime + duration
    if ending <= (now + 0.01) then return best end

    if (not best) or (ending < best.ending) then
        return {
            start = startTime,
            duration = duration,
            ending = ending,
        }
    end
    return best
end

local function FindGCDCandidate()
    local now = GetTime()
    local best = nil
    local slot

    for slot = 1, 120 do
        local startTime, duration, enabled = GetActionCooldown(slot)
        if enabled == 1 then
            best = ConsiderCooldownCandidate(startTime, duration, now, best)
        end
    end

    if best then
        return best.start, best.duration, best.ending
    end

    if type(GetNumSpellTabs) ~= "function" or type(GetSpellTabInfo) ~= "function" then
        return nil, nil, nil
    end

    local tabs = GetNumSpellTabs()
    local tab = 1
    while tab <= tabs do
        local _, _, offset, numSpells = GetSpellTabInfo(tab)
        if numSpells and numSpells > 0 then
            local i = offset + 1
            local max = offset + numSpells
            while i <= max do
                local startTime, duration, enabled = GetSpellCooldown(i, BOOKTYPE_SPELL)
                if enabled == 1 then
                    best = ConsiderCooldownCandidate(startTime, duration, now, best)
                end
                i = i + 1
            end
        end
        tab = tab + 1
    end

    if best then
        return best.start, best.duration, best.ending
    end
    return nil, nil, nil
end

local function RefreshGCDFromCooldowns()
    local startTime, duration, ending = FindGCDCandidate()
    local now = GetTime()

    if not ending then
        return
    end
    if ending <= now then
        return
    end

    if state.gcdEnd and state.gcdEnd > now then
        if ending <= (state.gcdEnd + 0.02) then
            return
        end
    end

    BeginGCD(startTime, duration)
end

local function CreateBar()
    bar:SetClampedToScreen(true)
    bar:SetMovable(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function()
        if GCDTimerBarDB.locked then
            return
        end
        bar:StartMoving()
    end)
    bar:SetScript("OnDragStop", function()
        bar:StopMovingOrSizing()
        SaveBarPosition()
    end)

    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints(bar)
    bar.bg:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar.bg:SetVertexColor(0, 0, 0, 0.45)

    bar.fill = bar:CreateTexture(nil, "ARTWORK")
    bar.fill:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar.fill:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
    bar.fill:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
    bar.fill:SetWidth(defaults.width)

    bar.queueOverlay = bar:CreateTexture(nil, "OVERLAY")
    bar.queueOverlay:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    -- Left-edge zone: bar drains right->left, so this marks the "safe to queue now" segment.
    bar.queueOverlay:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
    bar.queueOverlay:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
    bar.queueOverlay:SetWidth(0)
    bar.queueOverlay:SetVertexColor(0.60, 0.25, 0.88, 0.75)
    bar.queueOverlay:Hide()

    bar.border = bar:CreateTexture(nil, "BORDER")
    bar.border:SetTexture("Interface\\Tooltips\\UI-StatusBar-Border")
    bar.border:SetPoint("TOPLEFT", bar, "TOPLEFT", -2, 2)
    bar.border:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 2, -2)
    bar.border:SetVertexColor(0.65, 0.65, 0.65, 1)

    bar.spark = bar:CreateTexture(nil, "OVERLAY")
    bar.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    bar.spark:SetBlendMode("ADD")
    bar.spark:SetWidth(16)
    bar.spark:SetHeight(defaults.height + 14)
    bar.spark:Hide()
end

local function CreateCheckButton(parent, name, label, x, y, clickFunc)
    local btn = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    _G[name .. "Text"]:SetText(label)
    btn:SetScript("OnClick", clickFunc)
    return btn
end

local function CreateSlider(parent, name, label, minVal, maxVal, step, x, y, valueFunc)
    local slider = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    slider:SetWidth(240)
    slider:SetHeight(16)
    slider:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step)
    if slider.SetObeyStepOnDrag then
        slider:SetObeyStepOnDrag(true)
    end
    _G[name .. "Text"]:SetText(label)
    _G[name .. "Low"]:SetText(tostring(minVal))
    _G[name .. "High"]:SetText(tostring(maxVal))
    slider:SetScript("OnValueChanged", valueFunc)
    return slider
end

local function SetEditBoxEnabled(editBox, enabled)
    if not editBox then return end

    if enabled then
        if editBox.Enable then
            editBox:Enable()
        end
        editBox:EnableMouse(true)
        if editBox.EnableKeyboard then
            editBox:EnableKeyboard(true)
        end
    else
        if editBox.Disable then
            editBox:Disable()
        end
        editBox:EnableMouse(false)
        if editBox.EnableKeyboard then
            editBox:EnableKeyboard(false)
        end
        editBox:ClearFocus()
    end
end

local function SyncOptionsFromDB()
    local queueWindowMs
    if not options then return end
    controls.lock:SetChecked(GCDTimerBarDB.locked and 1 or nil)
    controls.hideOOC:SetChecked(GCDTimerBarDB.hideOutOfCombat and 1 or nil)
    controls.showQueueOverlay:SetChecked(GCDTimerBarDB.showQueueOverlay and 1 or nil)
    controls.width:SetValue(GCDTimerBarDB.width)
    controls.height:SetValue(GCDTimerBarDB.height)
    controls.opacity:SetValue(GCDTimerBarDB.alpha)
    controls.colorSwatch:SetVertexColor(GCDTimerBarDB.r, GCDTimerBarDB.g, GCDTimerBarDB.b, 1)

    if controls.queueWindowInput then
        if state.hasQueueDeps then
            queueWindowMs = tonumber(GetCVar("NP_SpellQueueWindowMs") or "")
            if not queueWindowMs then
                queueWindowMs = 400
            end
            SetEditBoxEnabled(controls.queueWindowInput, true)
            controls.queueWindowInput:SetText(tostring(math.floor(queueWindowMs + 0.5)))
            controls.queueWindowInput:SetTextColor(1, 1, 1)
            if controls.queueWindowLabel then
                controls.queueWindowLabel:SetTextColor(1, 1, 1)
            end
        else
            controls.queueWindowInput:SetText("N/A")
            SetEditBoxEnabled(controls.queueWindowInput, false)
            controls.queueWindowInput:SetTextColor(0.55, 0.55, 0.55)
            if controls.queueWindowLabel then
                controls.queueWindowLabel:SetTextColor(0.55, 0.55, 0.55)
            end
        end
    end
end

local function OpenColorPicker()
    local previous = {
        r = GCDTimerBarDB.r,
        g = GCDTimerBarDB.g,
        b = GCDTimerBarDB.b,
    }

    ColorPickerFrame.hasOpacity = false
    ColorPickerFrame.opacity = nil
    ColorPickerFrame.previousValues = previous
    ColorPickerFrame.func = function()
        local r, g, b = ColorPickerFrame:GetColorRGB()
        GCDTimerBarDB.r = r
        GCDTimerBarDB.g = g
        GCDTimerBarDB.b = b
        controls.colorSwatch:SetVertexColor(r, g, b, 1)
        UpdateBarVisuals()
    end
    ColorPickerFrame.cancelFunc = function()
        GCDTimerBarDB.r = previous.r
        GCDTimerBarDB.g = previous.g
        GCDTimerBarDB.b = previous.b
        controls.colorSwatch:SetVertexColor(previous.r, previous.g, previous.b, 1)
        UpdateBarVisuals()
    end
    ColorPickerFrame:SetColorRGB(GCDTimerBarDB.r, GCDTimerBarDB.g, GCDTimerBarDB.b)
    ShowUIPanel(ColorPickerFrame)
end

local function CreateOptions()
    options = CreateFrame("Frame", "GCDTimerBar_OptionsFrame", UIParent)
    options:SetWidth(330)
    options:SetHeight(340)
    options:SetPoint("CENTER", UIParent, "CENTER", 0, 140)
    options:SetMovable(true)
    options:EnableMouse(true)
    options:RegisterForDrag("LeftButton")
    options:SetScript("OnDragStart", function() options:StartMoving() end)
    options:SetScript("OnDragStop", function() options:StopMovingOrSizing() end)
    options:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    options:SetFrameStrata("DIALOG")
    options:Hide()
    options:SetScript("OnHide", function()
        -- Covers closing via X / ESC / external hide calls.
        SetBarFillRatio(0, false)
        UpdateQueueOverlay(nil)
        UpdateBarVisibility()
    end)

    options.title = options:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    options.title:SetPoint("TOP", options, "TOP", 0, -18)
    options.title:SetText("GCD Timer Options")

    options.close = CreateFrame("Button", nil, options, "UIPanelCloseButton")
    options.close:SetPoint("TOPRIGHT", options, "TOPRIGHT", -6, -6)

    controls.lock = CreateCheckButton(
        options,
        "GCDTimerBar_Opt_Lock",
        "Lock Bar",
        22,
        -48,
        function()
            GCDTimerBarDB.locked = controls.lock:GetChecked() and true or false
            UpdateBarInteraction()
            UpdateBarVisibility()
        end
    )

    controls.hideOOC = CreateCheckButton(
        options,
        "GCDTimerBar_Opt_HideOOC",
        "Hide Out Of Combat",
        22,
        -76,
        function()
            GCDTimerBarDB.hideOutOfCombat = controls.hideOOC:GetChecked() and true or false
            UpdateBarVisibility()
        end
    )

    controls.showQueueOverlay = CreateCheckButton(
        options,
        "GCDTimerBar_Opt_ShowQueueOverlay",
        "Latency/Spell Queue Overlay",
        22,
        -104,
        function()
            GCDTimerBarDB.showQueueOverlay = controls.showQueueOverlay:GetChecked() and true or false
            UpdateQueueOverlay(state.gcdDuration or state.previewDuration)
        end
    )

    controls.queueWindowLabel = options:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    controls.queueWindowLabel:SetPoint("TOPLEFT", options, "TOPLEFT", 206, -108)
    controls.queueWindowLabel:SetText("NP SQW")

    controls.queueWindowInput = CreateFrame("EditBox", "GCDTimerBar_Opt_QueueWindowInput", options, "InputBoxTemplate")
    controls.queueWindowInput:SetWidth(64)
    controls.queueWindowInput:SetHeight(20)
    controls.queueWindowInput:SetAutoFocus(false)
    controls.queueWindowInput:SetMaxLetters(4)
    controls.queueWindowInput:SetPoint("TOPLEFT", options, "TOPLEFT", 248, -104)
    controls.queueWindowInput:SetScript("OnEnterPressed", function()
        local value
        if not state.hasQueueDeps then
            this:ClearFocus()
            return
        end
        value = tonumber(this:GetText() or "")
        if not value then
            SyncOptionsFromDB()
            this:ClearFocus()
            return
        end
        value = math.floor(value + 0.5)
        value = Clamp(value, 50, 1200)
        SetCVar("NP_SpellQueueWindowMs", tostring(value))
        state.lastQueueSettingsSample = 0
        UpdatePressWindowFromNampower(GetTime())
        UpdateQueueOverlay(state.gcdDuration or state.previewDuration)
        this:SetText(tostring(value))
        this:ClearFocus()
    end)
    controls.queueWindowInput:SetScript("OnEscapePressed", function()
        SyncOptionsFromDB()
        this:ClearFocus()
    end)
    controls.queueWindowInput:SetScript("OnEditFocusLost", function()
        SyncOptionsFromDB()
    end)

    controls.width = CreateSlider(
        options,
        "GCDTimerBar_Opt_Width",
        "Bar Width",
        80,
        800,
        1,
        22,
        -150,
        function()
            GCDTimerBarDB.width = math.floor(controls.width:GetValue() + 0.5)
            UpdateBarVisuals()
            UpdateBarPosition()
        end
    )

    controls.height = CreateSlider(
        options,
        "GCDTimerBar_Opt_Height",
        "Bar Height",
        6,
        80,
        1,
        22,
        -204,
        function()
            GCDTimerBarDB.height = math.floor(controls.height:GetValue() + 0.5)
            UpdateBarVisuals()
            UpdateBarPosition()
        end
    )

    controls.opacity = CreateSlider(
        options,
        "GCDTimerBar_Opt_Opacity",
        "Bar Opacity",
        0.10,
        1.00,
        0.05,
        22,
        -258,
        function()
            local alpha = controls.opacity:GetValue()
            alpha = math.floor((alpha * 100) + 0.5) / 100
            GCDTimerBarDB.alpha = alpha
            UpdateBarVisuals()
        end
    )

    options.colorLabel = options:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    options.colorLabel:SetPoint("TOPLEFT", options, "TOPLEFT", 22, -286)
    options.colorLabel:SetText("Bar Color")

    controls.colorBtn = CreateFrame("Button", "GCDTimerBar_Opt_ColorBtn", options)
    controls.colorBtn:SetWidth(42)
    controls.colorBtn:SetHeight(22)
    controls.colorBtn:SetPoint("TOPLEFT", options, "TOPLEFT", 95, -291)
    controls.colorBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    controls.colorBtn:SetBackdropColor(0, 0, 0, 1)
    controls.colorBtn:SetBackdropBorderColor(0.7, 0.7, 0.7, 1)
    controls.colorBtn:SetScript("OnClick", OpenColorPicker)

    controls.colorSwatch = controls.colorBtn:CreateTexture(nil, "ARTWORK")
    controls.colorSwatch:SetAllPoints(controls.colorBtn)
    controls.colorSwatch:SetTexture("Interface\\Buttons\\WHITE8x8")
end

local function ApplyAllSettings()
    UpdateBarVisuals()
    UpdateBarPosition()
    UpdateBarInteraction()
    UpdateBarVisibility()
    SyncOptionsFromDB()
end

local function ToggleOptionsWindow()
    if not options then return end
    if options:IsShown() then
        options:Hide()
    else
        SyncOptionsFromDB()
        options:Show()
        UpdateBarVisibility()
    end
end

bar:SetScript("OnUpdate", function()
    local now, remaining, ratio, phase

    now = GetTime()
    UpdatePressWindow(now)

    if IsPreviewActive() then
        phase = Modulo(now, state.previewDuration)
        remaining = state.previewDuration - phase
        ratio = remaining / state.previewDuration
        SetBarFillRatio(ratio, true)
        UpdateQueueOverlay(state.previewDuration)
        if not bar:IsShown() then
            bar:Show()
        end
        return
    end

    if not state.gcdEnd then
        UpdateQueueOverlay(nil)
        if bar:IsShown() then
            UpdateBarVisibility()
        end
        return
    end

    if now >= state.gcdEnd then
        EndActiveGCD()
        SetBarFillRatio(0)
        UpdateQueueOverlay(nil)
        UpdateBarVisibility()
        return
    end

    if GCDTimerBarDB.hideOutOfCombat and not state.inCombat then
        bar:Hide()
        bar.spark:Hide()
        bar.queueOverlay:Hide()
        return
    end

    remaining = state.gcdEnd - now
    ratio = remaining / state.gcdDuration
    SetBarFillRatio(ratio)
    UpdateQueueOverlay(state.gcdDuration)
    if not bar:IsShown() then
        bar:Show()
    end
end)

eventFrame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        EnsureDB()
        state.hasQueueDeps = HasNampowerQueueSupport()
        CreateBar()
        CreateOptions()
        state.inCombat = UnitAffectingCombat("player") and true or false
        state.spellQueued = false
        if state.hasQueueDeps then
            eventFrame:RegisterEvent("SPELL_QUEUE_EVENT")
        end
        ApplyAllSettings()
    elseif event == "PLAYER_ENTERING_WORLD" then
        state.inCombat = UnitAffectingCombat("player") and true or false
        UpdateBarVisibility()
    elseif event == "PLAYER_REGEN_DISABLED" then
        state.inCombat = true
        UpdateBarVisibility()
    elseif event == "PLAYER_REGEN_ENABLED" then
        state.inCombat = false
        UpdateBarVisibility()
    elseif event == "SPELL_UPDATE_COOLDOWN" or event == "ACTIONBAR_UPDATE_COOLDOWN" then
        if GCDTimerBarDB then
            RefreshGCDFromCooldowns()
        end
    elseif event == "SPELL_QUEUE_EVENT" then
        local eventCode = arg1
        if eventCode == 0 or eventCode == 2 or eventCode == 4 then
            state.spellQueued = true
        elseif eventCode == 1 or eventCode == 3 or eventCode == 5 then
            state.spellQueued = false
        end
    end
end)

SLASH_GCDTIMERBAR1 = "/gcd"
SlashCmdList["GCDTIMERBAR"] = function()
    if GCDTimerBarDB == nil then
        return
    end
    ToggleOptionsWindow()
end

eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
