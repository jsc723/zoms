#pragma once
#include <stdint.h>
#include <stdbool.h>

void* journalStore_init(const char* path);
void  journalStore_deinit(void* handle);
void  journalStore_put(void* handle, const uint8_t* hash, const uint8_t* data, size_t len);
uint32_t  journalStore_commit(void* handle, const uint8_t* current, const uint8_t* last);
void  journalStore_root(void* handle, uint8_t* out);
void  journalStore_rebase(void* handle);


typedef struct {
    const uint8_t* ptr; // ?[*]const u8 (or uint8_t* if mutable)
    size_t len;         // usize
} JournalSlice;

// export fn journalStore_has(handle: ?*anyopaque, key: ?[*]u8) bool
bool journalStore_has(void* handle, const char* key);

// export fn journalStore_get(handle: ?*anyopaque, key: ?[*]u8, out: ?*JournalSlice) void
void journalStore_get(void* handle, const char* key, JournalSlice* out);

void journalStore_getMany(
    void* handle,                 // ?*anyopaque
    char** keys,                  // ?[*]?[*]u8 (array of mutable C-strings)
    JournalSlice* out_slices,     // ?[*]JournalSlice
    size_t len                    // usize
);

void journalStore_hasMany(
    void* handle,                 // ?*anyopaque
    char** keys,                  // ?[*]?[*]u8 (array of mutable C-strings)
    bool* out_has,                // ?[*]bool
    size_t len                    // usize
);