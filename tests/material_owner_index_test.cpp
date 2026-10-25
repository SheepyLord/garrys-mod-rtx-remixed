// Regression tests for the tracker's legacy hash -> owner index: a runtime texture
// edit must take the material off the hash it stopped using.
#include "../source/material_owner_index.h"
#include <cstdlib>
#include <iostream>

namespace {

void Check(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

bool Owns(const MaterialOwnerIndex& index, uint64_t hash, const std::string& name) {
    auto it = index.find(hash);
    return it != index.end() && it->second.count(name) != 0;
}

}  // namespace

int main() {
    const uint64_t hashA = 0xA, hashB = 0xB;

    // Material "props/crate" shares texture A with "props/barrel", then is edited to B.
    MaterialOwnerIndex index;
    index[hashA] = {"props/crate", "props/barrel"};
    Check(RemoveMaterialOwner(index, "props/crate") == 1, "one owner entry removed");
    Check(!Owns(index, hashA, "props/crate"), "edited material no longer owns its old hash");
    Check(Owns(index, hashA, "props/barrel"), "the other owner of a shared texture stays");
    index[hashB].insert("props/crate");  // what rediscovery records after the edit
    Check(Owns(index, hashB, "props/crate") && index.size() == 2, "the new hash carries the material");

    // Every recorded spelling of the material goes; similar names do not.
    index = {};
    index[hashA] = {"Materials/Nature/Grass.vmt", "nature/grass_stage1", "nature/grassland"};
    index[hashB] = {"NATURE\\GRASS"};
    Check(RemoveMaterialOwner(index, "nature/grass") == 3, "case, affixes, stage1 and slashes all match");
    Check(index.size() == 1 && Owns(index, hashA, "nature/grassland"), "prefix-sharing names stay");
    Check(index.find(hashB) == index.end(), "hashes left without owners are dropped");

    Check(RemoveMaterialOwner(index, "missing/material") == 0, "unknown material is a no-op");
    Check(MaterialOwnerKey("Materials/A/B_stage1.vmt") == "a/b", "stage1 variant keys to its material");
    std::cout << "material_owner_index tests passed\n";
    return 0;
}
