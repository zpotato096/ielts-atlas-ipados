#include "MemoryArchive.h"
#include "miniz.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int fail(char *err, size_t len, const char *message) {
    if (len)
        snprintf(err, len, "%s", message);
    return 0;
}
static int join(char *out, size_t cap, const char *a, const char *b) {
    int n = snprintf(out, cap, "%s/%s", a, b);
    return n >= 0 && (size_t)n < cap;
}
static int validPath(const char *p) {
    if (!*p || *p == '/' || strchr(p, '\\'))
        return 0;
    for (const char *s = p; *s;) {
        const char *end = strchr(s, '/');
        size_t n = end ? (size_t)(end - s) : strlen(s);
        if (!n || (n == 1 && s[0] == '.') || (n == 2 && !strncmp(s, "..", 2)))
            return 0;
        if (!end)
            return 1;
        s = end + 1;
    }
    return 0;
}
static int addTree(mz_zip_archive *z, const char *src, const char *rel, char *err, size_t len) {
    DIR *dir = opendir(src);
    if (!dir)
        return fail(err, len, "无法读取已导入的题库");
    struct dirent *entry;
    int ok = 1;
    for (;;) {
        errno = 0;
        entry = readdir(dir);
        if (!entry) {
            if (errno)
                ok = fail(err, len, "无法列出所有题库文件");
            break;
        }
        const char *n = entry->d_name;
        if (!strcmp(n, ".") || !strcmp(n, ".."))
            continue;
        char path[PATH_MAX], name[PATH_MAX];
        struct stat st;
        if (!join(path, sizeof(path), src, n) || !join(name, sizeof(name), rel, n) || !validPath(name) ||
            lstat(path, &st)) {
            ok = fail(err, len, "题库路径无效");
            break;
        }
        if (S_ISDIR(st.st_mode)) {
            ok = addTree(z, path, name, err, len);
        } else if (S_ISREG(st.st_mode)) {
            if (!mz_zip_writer_add_file(z, name, path, NULL, 0, MZ_DEFAULT_COMPRESSION))
                ok = fail(err, len, "未能完整写入题库文件");
        } else
            ok = fail(err, len, "题库包含不可备份的文件类型");
        if (!ok)
            break;
    }
    closedir(dir);
    return ok;
}
typedef struct {
    mz_uint64 bytes;
    mz_ulong crc;
} CheckedEntry;

static size_t checkChunk(void *context, mz_uint64 offset, const void *data, size_t size) {
    CheckedEntry *entry = context;
    if (entry->bytes != offset)
        return 0;
    entry->bytes += size;
    entry->crc = mz_crc32(entry->crc, data, size);
    return size;
}

static int verifyWrittenArchive(const char *path) {
    mz_zip_archive archive = {0};
    if (!mz_zip_reader_init_file(&archive, path, 0))
        return 0;
    int ok = 1;
    for (mz_uint i = 0; i < mz_zip_reader_get_num_files(&archive); i++) {
        mz_zip_archive_file_stat file;
        CheckedEntry entry = {0};
        if (!mz_zip_reader_file_stat(&archive, i, &file) ||
            !mz_zip_reader_extract_to_callback(&archive, i, checkChunk, &entry, 0) ||
            entry.bytes != file.m_uncomp_size || entry.crc != file.m_crc32) {
            ok = 0;
            break;
        }
    }
    mz_zip_reader_end(&archive);
    return ok;
}

int AtlasPack(const char *path, const char *state, const char *materials, char *err, size_t len) {
    mz_zip_archive z = {0};
    if (!mz_zip_writer_init_file_v2(&z, path, 0, MZ_ZIP_FLAG_WRITE_ZIP64))
        return fail(err, len, "无法创建记忆文件");
    int ok = mz_zip_writer_add_file(&z, "atlas-state.json", state, NULL, 0, MZ_BEST_SPEED);
    if (!ok)
        fail(err, len, "无法写入学习记录");
    if (ok)
        ok = addTree(&z, materials, "materials", err, len);
    if (ok && !mz_zip_writer_finalize_archive(&z))
        ok = fail(err, len, "记忆文件未能写完");
    if (!mz_zip_writer_end(&z) && ok)
        ok = fail(err, len, "无法关闭记忆文件");
    if (ok && !verifyWrittenArchive(path))
        ok = fail(err, len, "导出后的文件未通过完整性检查");
    if (!ok)
        unlink(path);
    return ok;
}
static int parents(char *path, size_t base) {
    for (char *p = path + base + 1; *p; ++p) {
        if (*p != '/')
            continue;
        *p = 0;
        int made = mkdir(path, 0700);
        struct stat st;
        int ok = made == 0 || (errno == EEXIST && !lstat(path, &st) && S_ISDIR(st.st_mode));
        *p = '/';
        if (!ok)
            return 0;
    }
    return 1;
}
int AtlasExtract(const char *path, const char *dest, uint64_t available, char *err, size_t len) {
    mz_zip_archive z = {0};
    if (!mz_zip_reader_init_file(&z, path, 0))
        return fail(err, len, "无法识别此记忆文件");
    int ok = 1, found = 0;
    const mz_uint count = mz_zip_reader_get_num_files(&z);
    for (mz_uint i = 0; i < count && ok; i++) {
        mz_zip_archive_file_stat s;
        char name[PATH_MAX], out[PATH_MAX];
        mz_uint need = mz_zip_reader_get_filename(&z, i, name, sizeof(name));
        if (!need || need > sizeof(name) || strlen(name) + 1 != need ||
            !mz_zip_reader_file_stat(&z, i, &s) || !validPath(name) || s.m_is_directory ||
            s.m_is_encrypted || !s.m_is_supported) {
            ok = fail(err, len, "记忆文件内有无效条目");
            break;
        }
        if (!strcmp(name, "atlas-state.json"))
            found++;
        else if (strncmp(name, "materials/", 10)) {
            ok = fail(err, len, "记忆文件结构无效");
            break;
        }
        if (s.m_uncomp_size > available) {
            ok = fail(err, len, "设备的可用空间不足");
            break;
        }
        available -= s.m_uncomp_size;
        if (!join(out, sizeof(out), dest, name) || !parents(out, strlen(dest))) {
            ok = fail(err, len, "无法建立恢复目录");
            break;
        }
        int fd = open(out, O_CREAT | O_EXCL | O_WRONLY, 0600);
        if (fd < 0) {
            ok = fail(err, len, "发现重复文件或存储空间不足");
            break;
        }
        FILE *f = fdopen(fd, "wb");
        if (!f) {
            close(fd);
            ok = fail(err, len, "无法写入恢复文件");
            break;
        }
        int extracted = mz_zip_reader_extract_to_cfile(&z, i, f, 0);
        int closed = fclose(f);
        if (!extracted || closed)
            ok = fail(err, len, "文件损坏或未能写入完整数据");
    }
    mz_zip_reader_end(&z);
    if (ok && found != 1)
        ok = fail(err, len, "缺少学习数据");
    return ok;
}
