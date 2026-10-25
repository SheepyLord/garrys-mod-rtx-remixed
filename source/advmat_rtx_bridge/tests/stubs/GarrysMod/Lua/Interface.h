#pragma once
// Minimal Lua stack with the slice of ILuaBase that lua_bindings.cpp uses, so the
// provider registration runs without Garry's Mod. Tables are string-keyed maps;
// numeric keys are stored by their decimal spelling.
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace GarrysMod { namespace Lua {
namespace Type { enum { Nil, Bool, Number, String, Table, Function }; }
constexpr int SPECIAL_GLOB = 0;
class ILuaBase;
using CFunction = int (*)(ILuaBase*);

struct Value {
    int type = Type::Nil;
    bool boolean = false;
    double number = 0;
    std::string string;
    std::shared_ptr<std::map<std::string, Value>> table;
    CFunction function = nullptr;
};

class ILuaBase {
public:
    ILuaBase() { globals.type = Type::Table; globals.table = std::make_shared<std::map<std::string, Value>>(); }
    Value globals;
    std::vector<Value> stack;

    Value& At(int index) {
        const auto offset = index > 0 ? static_cast<size_t>(index - 1) : stack.size() + index;
        return stack.at(offset);
    }
    static std::string Key(const Value& key) {
        if (key.type == Type::Number) return std::to_string(static_cast<long long>(key.number));
        return key.string;
    }
    int Top() { return static_cast<int>(stack.size()); }
    void PushSpecial(int value) {
        if (value != SPECIAL_GLOB) throw std::runtime_error("unexpected Lua special table");
        stack.push_back(globals);
    }
    void GetField(int index, const char* name) {
        const auto table = At(index).table;
        if (!table) { stack.push_back({}); return; }
        const auto value = table->find(name);
        stack.push_back(value == table->end() ? Value{} : value->second);
    }
    void SetField(int index, const char* name) { auto table = At(index).table; (*table)[name] = stack.back(); stack.pop_back(); }
    void GetTable(int index) {
        const auto table = At(index).table;
        const std::string key = Key(stack.back());
        stack.pop_back();
        const auto value = table->find(key);
        stack.push_back(value == table->end() ? Value{} : value->second);
    }
    void SetTable(int index) {
        auto table = At(index).table;
        const Value value = stack.back();
        stack.pop_back();
        (*table)[Key(stack.back())] = value;
        stack.pop_back();
    }
    int ObjLen(int index = -1) {
        const auto table = At(index).table;
        int length = 0;
        while (table && table->count(std::to_string(length + 1))) ++length;
        return length;
    }
    void Pop(int count = 1) { while (count-- > 0) stack.pop_back(); }
    bool IsType(int index, int type) { return At(index).type == type; }
    bool GetBool(int index = -1) { return At(index).boolean; }
    double GetNumber(int index = -1) { return At(index).number; }
    void CreateTable() { Value value; value.type = Type::Table; value.table = std::make_shared<std::map<std::string, Value>>(); stack.push_back(value); }
    void PushNumber(double number) { Value value; value.type = Type::Number; value.number = number; stack.push_back(value); }
    void PushBool(bool boolean) { Value value; value.type = Type::Bool; value.boolean = boolean; stack.push_back(value); }
    void PushString(const char* bytes, unsigned int length = 0) { Value value; value.type = Type::String; value.string = length ? std::string(bytes, length) : std::string(bytes); stack.push_back(value); }
    void PushNil() { stack.push_back({}); }
    void PushCFunction(CFunction function) { Value value; value.type = Type::Function; value.function = function; stack.push_back(value); }
    const char* GetString(int index = -1, unsigned int* length = nullptr) { auto& value = At(index); if (length) *length = static_cast<unsigned int>(value.string.size()); return value.string.c_str(); }
};
} }

#define LUA_FUNCTION(name) int name(GarrysMod::Lua::ILuaBase* LUA)
