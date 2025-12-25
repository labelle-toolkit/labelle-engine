// Example: Item types for the task engine
//
// This enum defines the item types that can flow through the task engine.
// Items move through storages and are processed at workstations.

/// Item types used in the task engine
pub const ItemType = enum {
    // Raw materials
    Flour,
    Water,
    Yeast,

    // Intermediate products
    Dough,

    // Final products
    Bread,
    Cake,

    // Other resources
    Wood,
    Stone,
    Iron,
};
