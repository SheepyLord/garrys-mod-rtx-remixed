-- Remove entities on map load
hook.Add("InitPostEntity", "RemoveReflectiveGlass", function()
    -- Find all func_reflective_glass entities
    for _, ent in ipairs(ents.FindByClass("func_reflective_glass")) do
        -- Remove the entity
        ent:Remove()
    end
    
    print("[Remove Entities] Removed all func_reflective_glass entities")
end)

-- game.CleanUpMap (loading a save of the current map, the spawn menu's clean-up) creates the
-- map's entities again, and a save made while one existed pastes it back afterwards. Their
-- planar reflection pass takes the world out of the Remix frame, so remove them as they come.
hook.Add("OnEntityCreated", "RemoveReflectiveGlass", function(ent)
    if ent:GetClass() ~= "func_reflective_glass" then return end
    timer.Simple(0, function()
        if IsValid(ent) then ent:Remove() end
    end)
end)
