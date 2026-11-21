#pragma once
#include <stddef.h>
#include <stdint.h>
int AtlasPack(const char *archivePath, const char *statePath, const char *materials, char *error,
              size_t length);
int AtlasExtract(const char *archivePath, const char *destination, uint64_t available, char *error,
                 size_t length);
