local cooking = require("cooking")

local Scanner = {}

function Scanner.CountIngredients(items, max_per_type, extra_ingredients, bag_counts)
    if not items then return end
    extra_ingredients = extra_ingredients or {}
    bag_counts = bag_counts or {}

    for _, item in pairs(items) do
        if item and item.prefab then
            local is_ingredient = cooking.ingredients[item.prefab] ~= nil
                or extra_ingredients[item.prefab]
            if is_ingredient then
                local count = 1
                if item.replica and item.replica.stackable then
                    count = item.replica.stackable:StackSize()
                elseif item.components and item.components.stackable then
                    count = item.components.stackable:StackSize()
                end
                bag_counts[item.prefab] = math.min((bag_counts[item.prefab] or 0) + count, max_per_type)
            end
        end
    end
    return bag_counts
end

return Scanner