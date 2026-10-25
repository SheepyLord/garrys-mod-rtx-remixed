#pragma once
// The slice of Source's IFileSystem that vtf_parser.cpp calls.
typedef void* FileHandle_t;

class IFileSystem {
public:
    virtual ~IFileSystem() = default;
    virtual FileHandle_t Open(const char* fileName, const char* options, const char* pathID = nullptr) = 0;
    virtual void Close(FileHandle_t file) = 0;
    virtual unsigned int Size(FileHandle_t file) = 0;
    virtual int Read(void* output, int size, FileHandle_t file) = 0;
};
