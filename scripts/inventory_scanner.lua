-- 食材扫描：从物品栏/背包/容器中统计可烹饪食材数量
local cooking = require("cooking")

local Scanner = {}

function Scanner.CountIngredients(items, max_per_type, device_ingredients, bag_counts)
    if not items then return end
    device_ingredients = device_ingredients or cooking.ingredients
    bag_counts = bag_counts or {}

    for _, item in pairs(items) do
        if item and item.prefab and device_ingredients[item.prefab] then
            local count = 1
            if item.replica and item.replica.stackable then
                count = item.replica.stackable:StackSize()
            elseif item.components and item.components.stackable then
                count = item.components.stackable:StackSize()
            end
            bag_counts[item.prefab] = math.min((bag_counts[item.prefab] or 0) + count, max_per_type)
        end
    end
    return bag_counts
end

return Scanner