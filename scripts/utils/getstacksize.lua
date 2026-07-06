return function(item)
    if item and item.replica and item.replica.stackable then
        return item.replica.stackable:StackSize()
    end
    if item and item.components and item.components.stackable then
        return item.components.stackable:StackSize()
    end
    return 1
end