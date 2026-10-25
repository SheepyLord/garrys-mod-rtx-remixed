// The integrated provider must share the AdvMatRTXBridge global with a standalone
// provider in either load order, and unloading must remove only its own table.
#include "advmat_rtx_bridge/lua_bindings.h"

#include <GarrysMod/Lua/Interface.h>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

using GarrysMod::Lua::ILuaBase;
using GarrysMod::Lua::Value;
namespace Type = GarrysMod::Lua::Type;
using advmat::rtx_bridge::RegisterLua;
using advmat::rtx_bridge::UnregisterLua;

namespace {

void Check(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

Value Provider(ILuaBase& lua) {
    const auto it = lua.globals.table->find("AdvMatRTXBridge");
    return it == lua.globals.table->end() ? Value{} : it->second;
}

std::string ProviderName(ILuaBase& lua) {
    const Value provider = Provider(lua);
    if (provider.type != Type::Table) return "";
    const auto it = provider.table->find("PROVIDER");
    return it == provider.table->end() ? "" : it->second.string;
}

void InstallStandaloneTable(ILuaBase& lua) {
    Value provider;
    provider.type = Type::Table;
    provider.table = std::make_shared<std::map<std::string, Value>>();
    Value name;
    name.type = Type::String;
    name.string = "standalone";
    (*provider.table)["PROVIDER"] = name;
    (*lua.globals.table)["AdvMatRTXBridge"] = provider;
}

}  // namespace

int main() {
    const auto root = std::filesystem::temp_directory_path() / "advmat_rtx_lua_registration";
    std::filesystem::remove_all(root);
    std::filesystem::create_directories(root / "rtx-remix" / "mods");
    const auto standaloneDll = root / "garrysmod" / "lua" / "bin" / "gmcl_advmat_rtx_bridge_win64.dll";

    {   // Nothing else present: the integrated provider takes the slot and gives it back.
        ILuaBase lua;
        Check(RegisterLua(&lua, root), "registration succeeds");
        Check(ProviderName(lua) == "RTXFixesBinary", "integrated provider is installed");
        UnregisterLua(&lua);
        Check(Provider(lua).type == Type::Nil, "unload removes the integrated provider");
        Check(lua.stack.empty(), "registration leaves the Lua stack balanced");
    }

    {   // A provider that loaded first keeps the slot, and our unload leaves it alone.
        ILuaBase lua;
        InstallStandaloneTable(lua);
        Check(RegisterLua(&lua, root), "registration defers to an existing provider");
        Check(ProviderName(lua) == "standalone", "existing provider is not replaced");
        UnregisterLua(&lua);
        Check(ProviderName(lua) == "standalone", "unload keeps the other provider");
        Check(lua.stack.empty(), "deferral leaves the Lua stack balanced");
    }

    {   // An installed standalone module is left for the editor to require.
        std::filesystem::create_directories(standaloneDll.parent_path());
        std::ofstream(standaloneDll).put('\0');
        ILuaBase lua;
        Check(RegisterLua(&lua, root), "registration defers to the installed standalone module");
        Check(Provider(lua).type == Type::Nil, "the global stays free for the standalone module");
        InstallStandaloneTable(lua);  // what require("advmat_rtx_bridge") then does
        UnregisterLua(&lua);
        Check(ProviderName(lua) == "standalone", "unload keeps the standalone provider");
        std::filesystem::remove(standaloneDll);
    }

    {   // A standalone provider that replaced ours later survives our unload.
        ILuaBase lua;
        Check(RegisterLua(&lua, root) && ProviderName(lua) == "RTXFixesBinary", "integrated provider first");
        InstallStandaloneTable(lua);
        UnregisterLua(&lua);
        Check(ProviderName(lua) == "standalone", "unload does not remove a table it does not own");
    }

    std::filesystem::remove_all(root);
    std::cout << "lua registration tests passed\n";
    return 0;
}
