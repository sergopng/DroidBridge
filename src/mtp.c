#include <libmtp.h>
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <sys/time.h>

static volatile sig_atomic_t cancelled;
static void cancel(int signal_number) { (void)signal_number; cancelled = 1; }
struct transfer_progress {
    uint64_t completed;
    uint64_t file_size;
    int folder;
};

static int progress(uint64_t sent, uint64_t total, const void *context) {
    const struct transfer_progress *state = context;
    if (state && total) {
        uint64_t current = sent >= total ? state->file_size :
            (uint64_t)((long double)sent * state->file_size / total);
        fprintf(stdout, "P %llu %llu\n", (unsigned long long)(state->completed + current),
                (unsigned long long)(state->folder ? 0 : state->file_size));
        fflush(stdout);
    }
    return cancelled != 0;
}

static int verify_name(LIBMTP_mtpdevice_t *dev, uint32_t id, const char *name) {
    LIBMTP_file_t *metadata = id ? LIBMTP_Get_Filemetadata(dev, id) : NULL;
    int error = !metadata || !metadata->filename || strcmp(metadata->filename, name);
    if (error) fprintf(stderr, "MTP: телефон не сохранил имя «%s».\n", name);
    if (metadata) LIBMTP_destroy_file_t(metadata);
    return error;
}

static void print_text(const char *value) {
    if (!value) return;
    for (const unsigned char *p = (const unsigned char *)value; *p; p++) printf("%02x", *p);
}

static int report(LIBMTP_mtpdevice_t *dev, const char *operation) {
    fprintf(stderr, "%s\n", operation);
    if (dev) LIBMTP_Dump_Errorstack(dev);
    return 1;
}

static int valid_name(const char *name) {
    return name && *name && strcmp(name, ".") && strcmp(name, "..") && !strchr(name, '/');
}

static char *child_path(const char *parent, const char *name) {
    char *path = NULL;
    if (valid_name(name) && asprintf(&path, "%s/%s", parent, name) < 0) return NULL;
    return path;
}

static LIBMTP_file_t *children(LIBMTP_mtpdevice_t *dev, uint32_t storage, uint32_t parent) {
    return LIBMTP_Get_Files_And_Folders(dev, storage, parent ? parent : LIBMTP_FILES_AND_FOLDERS_ROOT);
}

static int pull(LIBMTP_mtpdevice_t *dev, uint32_t storage, uint32_t id, int folder, const char *path, unsigned depth, time_t modified,
                uint64_t size, struct transfer_progress *state) {
    if (cancelled || depth > 256) return 1;
    if (!folder) {
        int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (fd < 0) { perror(path); return 1; }
        state->file_size = size;
        int result = LIBMTP_Get_File_To_File_Descriptor(dev, id, fd, progress, state);
        if (!result) state->completed += size;
        if (!result && modified > 0) {
            struct timeval times[2] = {{modified, 0}, {modified, 0}};
            futimes(fd, times);
        }
        int closed = close(fd);
        if (result || closed) unlink(path);
        return result || closed;
    }
    if (mkdir(path, 0700) < 0) { perror(path); return 1; }
    LIBMTP_file_t *entry = children(dev, storage, id);
    int result = LIBMTP_Get_Errorstack(dev) != NULL;
    while (entry) {
        LIBMTP_file_t *next = entry->next;
        char *child = child_path(path, entry->filename);
        if (!result) result = !child || pull(dev, storage, entry->item_id, entry->filetype == LIBMTP_FILETYPE_FOLDER, child, depth + 1, entry->modificationdate, entry->filesize, state);
        free(child);
        LIBMTP_destroy_file_t(entry);
        entry = next;
    }
    return result;
}

static int push(LIBMTP_mtpdevice_t *dev, uint32_t storage, uint32_t parent, const char *path, const char *name, unsigned depth,
                struct transfer_progress *state) {
    struct stat info;
    if (cancelled || depth > 256 || !valid_name(name)) return 1;
    if (lstat(path, &info)) { perror(path); return 1; }
    if (S_ISDIR(info.st_mode)) {
        DIR *dir = opendir(path);
        if (!dir) { perror(path); return 1; }
        uint32_t folder = LIBMTP_Create_Folder(dev, (char *)name, parent ? parent : UINT32_MAX, storage);
        int result = folder == 0 || verify_name(dev, folder, name);
        while (!result) {
            errno = 0;
            struct dirent *item = readdir(dir);
            if (!item) { result = errno != 0; break; }
            if (!valid_name(item->d_name)) continue;
            char *child = child_path(path, item->d_name);
            result = !child || push(dev, storage, folder, child, item->d_name, depth + 1, state);
            free(child);
        }
        closedir(dir);
        if (result && folder) LIBMTP_Delete_Object(dev, folder);
        return result;
    }
    if (!S_ISREG(info.st_mode)) {
        fprintf(stderr, "MTP: тип файла не поддерживается (%s)\n", path);
        return 1;
    }
    LIBMTP_file_t *file = LIBMTP_new_file_t();
    if (!file) return 1;
    file->filename = strdup(name);
    file->parent_id = parent ? parent : UINT32_MAX;
    file->storage_id = storage;
    file->filesize = (uint64_t)info.st_size;
    file->modificationdate = info.st_mtime;
    file->filetype = LIBMTP_FILETYPE_UNKNOWN;
    state->file_size = file->filesize;
    int result = !file->filename || LIBMTP_Send_File_From_File(dev, path, file, progress, state)
        || cancelled || verify_name(dev, file->item_id, name);
    if (!result) state->completed += file->filesize;
    if (result && file->item_id) LIBMTP_Delete_Object(dev, file->item_id);
    LIBMTP_destroy_file_t(file);
    return result;
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    signal(SIGTERM, cancel);
    signal(SIGINT, cancel);
    LIBMTP_Init();
    LIBMTP_raw_device_t *raw = NULL;
    int count = 0;
    LIBMTP_error_number_t detected = LIBMTP_Detect_Raw_Devices(&raw, &count);
    int detect_only = !strcmp(argv[1], "devices");
    if (detected == LIBMTP_ERROR_NO_DEVICE_ATTACHED && detect_only) return 0;
    if (detected != LIBMTP_ERROR_NONE) return report(NULL, "USB MTP: устройство недоступно. Разблокируйте телефон и выберите «Передача файлов».");
    if (detect_only) {
        for (int i = 0; i < count; i++) {
            printf("D\t%u-%u\t", raw[i].bus_location, raw[i].devnum);
            print_text(raw[i].device_entry.product ? raw[i].device_entry.product : "Android MTP");
            puts("");
        }
        free(raw);
        return 0;
    }
    if (argc < 3) { free(raw); return 2; }
    LIBMTP_mtpdevice_t *dev = NULL;
    for (int i = 0; i < count; i++) {
        char id[40];
        snprintf(id, sizeof(id), "%u-%u", raw[i].bus_location, raw[i].devnum);
        if (!strcmp(id, argv[2])) { dev = LIBMTP_Open_Raw_Device_Uncached(&raw[i]); break; }
    }
    free(raw);
    if (!dev) return report(NULL, "Не удалось открыть MTP. Проверьте режим USB и закройте другие приложения, использующие MTP.");
    int result = 0;
    const char *action = argv[1];
    uint32_t storage = argc > 3 ? (uint32_t)strtoul(argv[3], NULL, 10) : 0;
    uint32_t object = argc > 4 ? (uint32_t)strtoul(argv[4], NULL, 10) : 0;
    if (!strcmp(action, "storage")) {
        result = LIBMTP_Get_Storage(dev, LIBMTP_STORAGE_SORTBY_NOTSORTED);
        for (LIBMTP_devicestorage_t *s = dev->storage; s; s = s->next) {
            printf("S\t%u\t%llu\t%llu\t", s->id, (unsigned long long)s->MaxCapacity, (unsigned long long)s->FreeSpaceInBytes);
            print_text(s->StorageDescription);
            puts("");
        }
    } else if (!strcmp(action, "list") && argc == 5) {
        LIBMTP_file_t *entry = children(dev, storage, object);
        result = LIBMTP_Get_Errorstack(dev) != NULL;
        while (entry) {
            LIBMTP_file_t *next = entry->next;
            printf("F\t%u\t%u\t%llu\t%lld\t", entry->item_id, entry->filetype == LIBMTP_FILETYPE_FOLDER,
                   (unsigned long long)entry->filesize, (long long)entry->modificationdate);
            print_text(entry->filename);
            puts("");
            LIBMTP_destroy_file_t(entry);
            entry = next;
        }
    } else if (!strcmp(action, "pull") && argc == 7) {
        LIBMTP_file_t *metadata = LIBMTP_Get_Filemetadata(dev, object);
        time_t modified = metadata ? metadata->modificationdate : 0;
        uint64_t size = metadata ? metadata->filesize : 0;
        struct transfer_progress state = {.folder = atoi(argv[5])};
        if (metadata) LIBMTP_destroy_file_t(metadata);
        LIBMTP_Clear_Errorstack(dev);
        result = pull(dev, storage, object, state.folder, argv[6], 0, modified, size, &state);
    } else if (!strcmp(action, "push") && argc == 7) {
        struct stat info;
        struct transfer_progress state = {.folder = !lstat(argv[5], &info) && S_ISDIR(info.st_mode)};
        result = push(dev, storage, object, argv[5], argv[6], 0, &state);
    } else if (!strcmp(action, "mkdir") && argc == 6 && valid_name(argv[5])) {
        result = !LIBMTP_Create_Folder(dev, argv[5], object ? object : UINT32_MAX, storage);
    } else if (!strcmp(action, "delete") && argc == 5 && object) {
        result = LIBMTP_Delete_Object(dev, object);
    } else if (!strcmp(action, "rename") && argc == 6 && object && valid_name(argv[5])) {
        result = LIBMTP_Set_Object_Filename(dev, object, argv[5]);
    } else result = 1;
    if (result) report(dev, cancelled ? "Операция MTP прервана." : "Операция MTP не выполнена.");
    LIBMTP_Release_Device(dev);
    return result ? 1 : 0;
}
