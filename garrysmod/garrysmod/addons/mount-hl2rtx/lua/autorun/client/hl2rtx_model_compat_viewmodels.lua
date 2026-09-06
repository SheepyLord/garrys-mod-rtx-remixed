local mountMarker = ".rtxlauncher-hl2rtx-overlay.json"

local enabled = CreateClientConVar(
    "hl2rtx_model_compat_combined_viewmodels",
    "1",
    true,
    false,
    "Use the combined HL2 viewmodels expected by HL2 RTX for stock HL2 weapons",
    0,
    1
)

local debugEnabled = CreateClientConVar(
    "hl2rtx_model_compat_debug",
    "0",
    true,
    false,
    "Log HL2 RTX model-compatibility overrides",
    0,
    1
)

local combinedViewModels = {
    ["weapon_357"] = "models/weapons/v_357.mdl",
    ["weapon_ar2"] = "models/weapons/v_irifle.mdl",
    ["weapon_bugbait"] = "models/weapons/v_bugbait.mdl",
    ["weapon_crossbow"] = "models/weapons/v_crossbow.mdl",
    ["weapon_crowbar"] = "models/weapons/v_crowbar.mdl",
    ["weapon_frag"] = "models/weapons/v_grenade.mdl",
    ["weapon_physcannon"] = "models/weapons/v_physcannon.mdl",
    ["weapon_pistol"] = "models/weapons/v_pistol.mdl",
    ["weapon_rpg"] = "models/weapons/v_rpg.mdl",
    ["weapon_shotgun"] = "models/weapons/v_shotgun.mdl",
    ["weapon_smg1"] = "models/weapons/v_smg1.mdl",
    ["weapon_stunstick"] = "models/weapons/v_stunbaton.mdl"
}

local function NormalizeModelPath(path)
    return string.lower(string.Replace(path or "", "\\", "/"))
end

local mountAvailable = false
local validModels = {}
local lastRefresh = "not initialized"
local refreshTimer = "HL2RTXModelCompat_Refresh"

-- Mounted-content checks can walk every GAME search path. Keep both positive
-- and negative results out of the render hooks, including the unmapped physgun.
local function RefreshMountedModels(reason)
    timer.Remove(refreshTimer)
    mountAvailable = file.Exists(mountMarker, "GAME")
    validModels = {}
    lastRefresh = reason
    if not mountAvailable then return end

    for _, model in pairs(combinedViewModels) do
        local valid = util.IsValidModel(model)
        validModels[model] = valid
        if valid then util.PrecacheModel(model) end
    end
end

local function QueueMountedModelsRefresh(reason)
    -- Stop using stale availability immediately on unmount/content changes.
    -- A named one-shot coalesces mount bursts; there is no polling timer.
    mountAvailable, validModels = false, {}
    lastRefresh = "pending: " .. reason
    timer.Create(refreshTimer, 0, 1, function() RefreshMountedModels(reason) end)
end

local function GetCombinedViewModel(weapon)
    if not IsValid(weapon) then
        return nil
    end

    local replacement = combinedViewModels[string.lower(weapon:GetClass() or "")]
    if not replacement or not enabled:GetBool() or not mountAvailable then return nil end
    return replacement
end

local changingViewModel = false
local lastDiagnostic

local function LogOverride(weapon, original, replacement, final)
    if not debugEnabled:GetBool() then
        return
    end

    local diagnostic = string.format(
        "%s|%s|%s|%s",
        weapon:GetClass(),
        original,
        replacement,
        final
    )
    if diagnostic == lastDiagnostic then
        return
    end

    lastDiagnostic = diagnostic
    print(string.format(
        "[HL2RTX Model Compat] %s viewmodel: %s -> %s (final: %s)",
        weapon:GetClass(),
        original,
        replacement,
        final
    ))
end

local function ApplyCombinedViewModel(viewModel, weapon)
    if changingViewModel or not IsValid(viewModel) then
        return false
    end

    local replacement = GetCombinedViewModel(weapon)
    if not replacement or not validModels[replacement] then
        return false
    end

    local original = NormalizeModelPath(viewModel:GetModel())
    if original ~= replacement then
        changingViewModel = true
        viewModel:SetWeaponModel(replacement, weapon)
        changingViewModel = false

        LogOverride(
            weapon,
            original,
            replacement,
            NormalizeModelPath(viewModel:GetModel())
        )
    end

    return NormalizeModelPath(viewModel:GetModel()) == replacement
end

hook.Add("OnViewModelChanged", "HL2RTXModelCompat_CombinedViewModelChanged", function(viewModel)
    if changingViewModel or not IsValid(viewModel) then
        return
    end

    local owner = viewModel:GetOwner()
    timer.Simple(0, function()
        if not IsValid(viewModel) or not IsValid(owner) then
            return
        end

        ApplyCombinedViewModel(viewModel, owner:GetActiveWeapon())
    end)
end)

hook.Add("PreDrawViewModel", "HL2RTXModelCompat_CombinedViewModel", function(viewModel, _, weapon)
    ApplyCombinedViewModel(viewModel, weapon)
end)

hook.Add("PlayerSwitchWeapon", "HL2RTXModelCompat_CombinedViewModelSwitch", function(player, _, weapon)
    if player ~= LocalPlayer() then
        return
    end

    timer.Simple(0, function()
        if not IsValid(player) or player:GetActiveWeapon() ~= weapon then
            return
        end

        ApplyCombinedViewModel(player:GetViewModel(0), weapon)
    end)
end)

hook.Add("PreDrawPlayerHands", "HL2RTXModelCompat_HideSeparateHands", function(_, viewModel, _, weapon)
    local replacement = GetCombinedViewModel(weapon)
    if replacement and validModels[replacement] and IsValid(viewModel) and
        NormalizeModelPath(viewModel:GetModel()) == replacement then
        return true
    end
end)

concommand.Add("hl2rtx_model_compat_status", function()
    local player = LocalPlayer()
    local weapon = IsValid(player) and player:GetActiveWeapon() or nil
    local viewModel = IsValid(player) and player:GetViewModel(0) or nil
    local hands = IsValid(player) and player:GetHands() or nil
    local replacement = GetCombinedViewModel(weapon)

    print("[HL2RTX Model Compat] Status")
    print("  mounted (cached): " .. tostring(mountAvailable))
    print("  last refresh: " .. lastRefresh)
    print("  enabled: " .. tostring(enabled:GetBool()))
    print("  weapon: " .. (IsValid(weapon) and weapon:GetClass() or "<invalid>"))
    print("  viewmodel: " .. (IsValid(viewModel) and NormalizeModelPath(viewModel:GetModel()) or "<invalid>"))
    print("  replacement: " .. (replacement or "<none>"))
    print("  replacement valid: " .. tostring(replacement ~= nil and validModels[replacement] == true))
    print("  hands: " .. (IsValid(hands) and NormalizeModelPath(hands:GetModel()) or "<invalid>"))
end)

hook.Add("InitPostEntity", "HL2RTXModelCompat_RefreshMountedModels", function()
    QueueMountedModelsRefresh("InitPostEntity")
end)
hook.Add("GameContentChanged", "HL2RTXModelCompat_RefreshMountedModels", function()
    QueueMountedModelsRefresh("GameContentChanged")
end)
hook.Add("OnReloaded", "HL2RTXModelCompat_RefreshMountedModels", function()
    QueueMountedModelsRefresh("OnReloaded")
end)
concommand.Add("hl2rtx_model_compat_refresh", function()
    RefreshMountedModels("explicit refresh")
end)

RefreshMountedModels("script initialization")
