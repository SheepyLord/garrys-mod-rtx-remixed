#pragma once

#include <algorithm>
#include <cctype>
#include <cstddef>
#include <cstdint>
#include <iterator>
#include <string>
#include <unordered_map>
#include <unordered_set>

// The tracker's legacy hash -> owner-name index (m_hashToMaterials). Categorisation
// still queries it next to MaterialHashLookup, so it must forget owners the same way.
using MaterialOwnerIndex = std::unordered_map<uint64_t, std::unordered_set<std::string>>;

// Owners are recorded with varying case, "materials/" and ".vmt" affixes and the
// displacement "_stage1" pass; this key names the material behind all of them.
inline std::string MaterialOwnerKey(std::string name) {
    std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) {
        return c == '\\' ? '/' : static_cast<char>(std::tolower(c));
    });
    if (name.compare(0, 10, "materials/") == 0) name.erase(0, 10);
    if (name.size() > 4 && name.compare(name.size() - 4, 4, ".vmt") == 0) name.resize(name.size() - 4);
    if (name.size() > 7 && name.compare(name.size() - 7, 7, "_stage1") == 0) name.resize(name.size() - 7);
    return name;
}

// Forget `material` (any recorded spelling) under every hash, so a hash the material
// no longer uses stops listing it; other owners of a shared texture keep their entry.
// Returns the number of owner entries removed.
inline size_t RemoveMaterialOwner(MaterialOwnerIndex& index, const std::string& material) {
    const std::string key = MaterialOwnerKey(material);
    // At most "materials/", "_stage1" and ".vmt" separate a spelling from its key;
    // checking the length first keeps the scan from normalizing every owner name.
    constexpr size_t kMaxAffixes = 10 + 7 + 4;
    size_t removed = 0;
    for (auto hash = index.begin(); hash != index.end();) {
        auto& owners = hash->second;
        for (auto owner = owners.begin(); owner != owners.end();) {
            const bool plausible = owner->size() >= key.size() && owner->size() <= key.size() + kMaxAffixes;
            if (plausible && MaterialOwnerKey(*owner) == key) {
                owner = owners.erase(owner);
                ++removed;
            } else {
                ++owner;
            }
        }
        hash = owners.empty() ? index.erase(hash) : std::next(hash);
    }
    return removed;
}
