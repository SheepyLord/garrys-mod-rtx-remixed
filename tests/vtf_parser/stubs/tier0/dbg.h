#pragma once
// Minimal tier0 logging for compiling vtf_parser.cpp outside the engine.
#include <cstdarg>
#include <cstdio>

inline void Msg(const char* format, ...) {
    va_list args;
    va_start(args, format);
    std::vfprintf(stdout, format, args);
    va_end(args);
}

inline void Warning(const char* format, ...) {
    va_list args;
    va_start(args, format);
    std::vfprintf(stderr, format, args);
    va_end(args);
}
